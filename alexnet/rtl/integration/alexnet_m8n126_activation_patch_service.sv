`timescale 1ns/1ps

module alexnet_conv_activation_bank64 #(
    parameter int DEPTH = 507,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input logic clk,
    input logic write_enable,
    input logic [ADDR_W-1:0] write_address,
    input logic [63:0] write_data,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_address,
    output logic [63:0] read_data
);
  (* ram_style = "block" *) logic [63:0] memory [0:DEPTH-1];
  always_ff @(posedge clk) begin
    if (write_enable)
      memory[write_address] <= write_data;
    if (read_enable)
      read_data <= memory[read_address];
  end
endmodule

// Cache one completed activation tensor from DDR and assemble the exact
// K-major M16 stream consumed by alexnet_m16_patch_pingpong.
//
// DDR layout is [N8 channel tile][spatial position][8 INT8 lanes].  Conv2-5
// gather windows from that layout.  FC6 converts Pool5's tiled 256x6x6 tensor
// to channel-major K order; FC7/8 read their already-linear N8 tensors.
// Loading once per layer removes the legacy pretransposed patch-tape ABI.
module alexnet_m8n126_activation_patch_service #(
    parameter int MAX_CACHE_BEATS = 4056
) (
    input logic clk,
    input logic rst,

    input  logic request_valid,
    output logic request_ready,
    input  logic [3:0] request_layer_id,
    input  logic [12:0] request_m_base,
    input  logic [13:0] request_k_offset,
    input  logic [12:0] request_k_count,
    input  logic [15:0] request_m_lane_mask,
    input  logic [15:0] request_context_tag,
    input  logic [31:0] activation_a_base,
    input  logic [31:0] activation_b_base,

    output logic dma_command_valid,
    input  logic dma_command_ready,
    output logic [31:0] dma_command_address,
    output logic [25:0] dma_command_length,
    input  logic dma_armed,
    input  logic dma_done,
    input  logic dma_error,

    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,

    output logic [127:0] patch_axis_tdata,
    output logic patch_axis_tvalid,
    input  logic patch_axis_tready,
    output logic patch_axis_tlast,

    output logic busy,
    output logic fault,
    output logic cache_load_active,
    output logic [3:0] cached_layer_id,
    output logic [15:0] active_context_tag,
    output logic [7:0] active_m_count,
    output logic [31:0] cache_loads,
    output logic [31:0] completed_patches,
    output logic [31:0] emitted_patch_words
);
  localparam int CACHE_BANKS = 16;
  localparam int CACHE_BANK_DEPTH = (MAX_CACHE_BEATS + 7) / 8;
  localparam int CACHE_BANK_ADDR_W = $clog2(CACHE_BANK_DEPTH);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_VALIDATE,
    ST_LOAD_COMMAND,
    ST_LOAD_ARM,
    ST_LOAD_STREAM,
    ST_LOAD_DRAIN,
    ST_INIT_POSITION,
    ST_PREPARE_WORD,
    ST_INPUT_COORD,
    ST_SPATIAL_INDEX,
    ST_WORD_INDEX,
    ST_ADDRESS,
    ST_CAPTURE,
    ST_OUTPUT,
    ST_FAILED
  } state_t;

  state_t state_q;
  logic fault_q, cache_valid_q, dma_done_seen_q;
  logic [31:0] cached_base_q;
  logic [3:0] layer_id_q;
  logic [13:0] request_k_offset_q;
  logic [12:0] k_count_q, local_k_q;
  logic [15:0] m_lane_mask_q, context_tag_q;
  logic [4:0] m_count_q;

  logic [11:0] cache_write_index_q;
  logic [127:0] patch_word_q;

  logic [9:0] conv_channel_q;
  logic [2:0] conv_kx_q, conv_ky_q;
  logic [12:0] position_remainder_q;
  logic [7:0] base_output_y_q, base_output_x_q;
  logic [8:0] fc_channel_q;
  logic [5:0] fc_spatial_q;
  logic [12:0] fc_linear_q;

  // Geometry and the 64-bit cache word for every M lane are registered before
  // the BRAM address stage.  Keeping the per-lane coordinate work out of the
  // BRAM address cone avoids a 16-lane carry/mux cascade after implementation.
  logic [7:0] input_h_q, input_w_q;
  logic [9:0] input_channels_q;
  logic [3:0] kernel_q, padding_q;
  logic layer_is_conv_q, layer_is_fc_q, layer_is_conv2_q;
  logic [7:0] prepared_output_y [0:CACHE_BANKS-1];
  logic [7:0] prepared_output_x [0:CACHE_BANKS-1];
  logic [12:0] prepared_spatial_index [0:CACHE_BANKS-1];
  logic [7:0] prepared_input_y [0:CACHE_BANKS-1];
  logic [7:0] prepared_input_x [0:CACHE_BANKS-1];
  logic [12:0] formed_spatial_index [0:CACHE_BANKS-1];
  logic [12:0] prepared_word_index [0:CACHE_BANKS-1];
  logic [2:0] prepared_byte [0:CACHE_BANKS-1];
  logic prepared_valid [0:CACHE_BANKS-1];
  logic [7:0] lane_output_y_q [0:CACHE_BANKS-1];
  logic [7:0] lane_output_x_q [0:CACHE_BANKS-1];
  logic [7:0] lane_input_y_q [0:CACHE_BANKS-1];
  logic [7:0] lane_input_x_q [0:CACHE_BANKS-1];
  logic [12:0] lane_spatial_index_q [0:CACHE_BANKS-1];
  logic [12:0] lane_word_index_q [0:CACHE_BANKS-1];
  logic [2:0] lane_byte_q [0:CACHE_BANKS-1];
  logic lane_valid_q [0:CACHE_BANKS-1];

  logic [CACHE_BANK_ADDR_W-1:0] bank_read_address [0:CACHE_BANKS-1];
  logic [63:0] bank_read_data_q [0:CACHE_BANKS-1];
  logic [3:0] bank_lane [0:CACHE_BANKS-1];
  logic [3:0] bank_lane_q [0:CACHE_BANKS-1];
  logic [2:0] bank_byte [0:CACHE_BANKS-1];
  logic [2:0] bank_byte_q [0:CACHE_BANKS-1];
  logic bank_valid [0:CACHE_BANKS-1];
  logic bank_valid_q [0:CACHE_BANKS-1];
  logic [3:0] cache_write_low_bank, cache_write_high_bank;
  logic [CACHE_BANK_ADDR_W-1:0] cache_write_bank_address;

  logic [7:0] input_h, input_w, output_w;
  logic [12:0] input_spatial;
  logic [9:0] input_channels;
  logic [3:0] kernel, padding;
  logic [31:0] configured_base;
  logic [25:0] configured_bytes;
  logic [11:0] configured_beats;
  logic layer_is_conv, layer_is_fc;

  logic request_fire, command_fire, input_fire, patch_fire;
  logic expected_input_last, request_fields_valid;
  logic [4:0] requested_m_count;

  function automatic logic [4:0] popcount16(input logic [15:0] value);
    logic [4:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 16; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  assign requested_m_count = popcount16(request_m_lane_mask);
  assign request_ready = state_q == ST_IDLE && !fault_q;
  assign request_fire = request_valid && request_ready;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q || dma_error;
  assign cache_load_active = state_q == ST_LOAD_COMMAND ||
      state_q == ST_LOAD_ARM || state_q == ST_LOAD_STREAM ||
      state_q == ST_LOAD_DRAIN;
  assign active_context_tag = context_tag_q;
  assign active_m_count = {3'd0, m_count_q};

  assign dma_command_valid = state_q == ST_LOAD_COMMAND;
  assign dma_command_address = configured_base;
  assign dma_command_length = configured_bytes;
  assign command_fire = dma_command_valid && dma_command_ready;
  assign s_axis_tready = (state_q == ST_LOAD_ARM ||
                          state_q == ST_LOAD_STREAM) &&
                         cache_write_index_q < configured_beats;
  assign input_fire = s_axis_tvalid && s_axis_tready;
  assign expected_input_last = cache_write_index_q + 1'b1 ==
                               configured_beats;
  assign cache_write_low_bank = {cache_write_index_q[2:0], 1'b0};
  assign cache_write_high_bank = {cache_write_index_q[2:0], 1'b1};
  assign cache_write_bank_address = cache_write_index_q[11:3];

  assign patch_axis_tdata = patch_word_q;
  assign patch_axis_tvalid = state_q == ST_OUTPUT;
  assign patch_axis_tlast = local_k_q + 1'b1 == k_count_q;
  assign patch_fire = patch_axis_tvalid && patch_axis_tready;

  always_comb begin
    input_h = 0;
    input_w = 0;
    output_w = 0;
    input_spatial = 0;
    input_channels = 0;
    kernel = 0;
    padding = 0;
    configured_base = 0;
    configured_bytes = 0;
    layer_is_conv = layer_id_q >= 2 && layer_id_q <= 5;
    layer_is_fc = layer_id_q >= 6 && layer_id_q <= 8;
    case (layer_id_q)
      2: begin
        input_h = 27; input_w = 27; output_w = 27;
        input_spatial = 729; input_channels = 64;
        kernel = 5; padding = 2;
        configured_base = activation_a_base;
        configured_bytes = 26'd46656;
      end
      3: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 192;
        kernel = 3; padding = 1;
        configured_base = activation_b_base;
        configured_bytes = 26'd32448;
      end
      4: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 384;
        kernel = 3; padding = 1;
        configured_base = activation_a_base;
        configured_bytes = 26'd64896;
      end
      5: begin
        input_h = 13; input_w = 13; output_w = 13;
        input_spatial = 169; input_channels = 256;
        kernel = 3; padding = 1;
        configured_base = activation_b_base;
        configured_bytes = 26'd43264;
      end
      6: begin
        input_h = 6; input_w = 6; input_spatial = 36;
        input_channels = 256;
        configured_base = activation_a_base;
        configured_bytes = 26'd9216;
      end
      7: begin
        input_spatial = 1; input_channels = 10'd0;
        configured_base = activation_b_base;
        configured_bytes = 26'd4096;
      end
      8: begin
        input_spatial = 1; input_channels = 10'd0;
        configured_base = activation_a_base;
        configured_bytes = 26'd4096;
      end
      default: begin end
    endcase
    configured_beats = configured_bytes[15:4];
  end

  always_comb begin
    request_fields_valid = layer_id_q >= 2 && layer_id_q <= 8 &&
        m_lane_mask_q != 0 &&
        m_lane_mask_q == ((17'b1 << m_count_q) - 1'b1) &&
        k_count_q != 0 && activation_a_base[3:0] == 0 &&
        activation_b_base[3:0] == 0;
    case (layer_id_q)
      2: request_fields_valid &= request_k_offset_q == 0 &&
          k_count_q == 1600 && m_count_q <= 16 &&
          position_remainder_q + m_count_q <= 729;
      3: request_fields_valid &= request_k_offset_q == 0 &&
          k_count_q == 1728 && m_count_q <= 8 &&
          position_remainder_q + m_count_q <= 169;
      4: request_fields_valid &= request_k_offset_q == 0 &&
          k_count_q == 3456 && m_count_q <= 8 &&
          position_remainder_q + m_count_q <= 169;
      5: request_fields_valid &= request_k_offset_q == 0 &&
          k_count_q == 2304 && m_count_q <= 8 &&
          position_remainder_q + m_count_q <= 169;
      6: request_fields_valid &= m_count_q == 1 &&
          position_remainder_q == 0 &&
          ((request_k_offset_q == 0 && k_count_q == 4096) ||
           (request_k_offset_q == 4096 && k_count_q == 4096) ||
           (request_k_offset_q == 8192 && k_count_q == 1024));
      7, 8: request_fields_valid &= m_count_q == 1 &&
          position_remainder_q == 0 && request_k_offset_q == 0 &&
          k_count_q == 4096;
      default: request_fields_valid = 1'b0;
    endcase
  end

  always_comb begin : form_lane_positions
    integer lane_index;
    logic [8:0] lane_linear_x;

    for (lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
      lane_linear_x = {1'b0, base_output_x_q} + lane_index;
      prepared_output_y[lane_index] = base_output_y_q;
      prepared_output_x[lane_index] = lane_linear_x[7:0];
      if (lane_linear_x >= ({1'b0, input_w_q} << 1)) begin
        prepared_output_y[lane_index] = base_output_y_q + 2;
        prepared_output_x[lane_index] =
            lane_linear_x - ({1'b0, input_w_q} << 1);
      end else if (lane_linear_x >= {1'b0, input_w_q}) begin
        prepared_output_y[lane_index] = base_output_y_q + 1'b1;
        prepared_output_x[lane_index] =
            lane_linear_x - {1'b0, input_w_q};
      end
    end
  end

  always_comb begin : form_input_coordinates
    integer lane_index;
    logic [8:0] padded_y;
    logic [8:0] padded_x;
    logic [7:0] input_y_value;
    logic [7:0] input_x_value;

    for (lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
      prepared_spatial_index[lane_index] = '0;
      prepared_input_y[lane_index] = '0;
      prepared_input_x[lane_index] = '0;
      prepared_byte[lane_index] = '0;
      prepared_valid[lane_index] = 1'b0;
      padded_y = {1'b0, lane_output_y_q[lane_index]} + conv_ky_q;
      padded_x = {1'b0, lane_output_x_q[lane_index]} + conv_kx_q;
      input_y_value = padded_y - padding_q;
      input_x_value = padded_x - padding_q;
      if (layer_is_conv_q) begin
        if (lane_index < m_count_q && m_lane_mask_q[lane_index] &&
            padded_y >= padding_q &&
            padded_y < ({1'b0, padding_q} + input_h_q) &&
            padded_x >= padding_q &&
            padded_x < ({1'b0, padding_q} + input_w_q)) begin
          prepared_input_y[lane_index] = input_y_value;
          prepared_input_x[lane_index] = input_x_value;
          prepared_byte[lane_index] = conv_channel_q[2:0];
          prepared_valid[lane_index] = 1'b1;
        end
      end else if (lane_index == 0) begin
        if (layer_id_q == 6) begin
          prepared_spatial_index[lane_index] = fc_spatial_q;
          prepared_byte[lane_index] = fc_channel_q[2:0];
        end else begin
          prepared_spatial_index[lane_index] = fc_linear_q >> 3;
          prepared_byte[lane_index] = fc_linear_q[2:0];
        end
        prepared_valid[lane_index] = layer_is_fc_q;
      end
    end
  end

  always_comb begin : form_spatial_indices
    for (integer lane_index = 0;
         lane_index < CACHE_BANKS; lane_index++) begin
      if (layer_is_conv2_q)
        formed_spatial_index[lane_index] =
            (lane_input_y_q[lane_index] << 4) +
            (lane_input_y_q[lane_index] << 3) +
            (lane_input_y_q[lane_index] << 1) +
            lane_input_y_q[lane_index] + lane_input_x_q[lane_index];
      else
        formed_spatial_index[lane_index] =
            (lane_input_y_q[lane_index] << 3) +
            (lane_input_y_q[lane_index] << 2) +
            lane_input_y_q[lane_index] + lane_input_x_q[lane_index];
    end
  end

  always_comb begin : form_word_indices
    logic [6:0] channel_tile_value;
    channel_tile_value = layer_is_conv_q ?
        (conv_channel_q >> 3) : (fc_channel_q >> 3);
    for (integer lane_index = 0;
         lane_index < CACHE_BANKS; lane_index++) begin
      prepared_word_index[lane_index] =
          lane_spatial_index_q[lane_index];
      if (layer_is_conv2_q)
        prepared_word_index[lane_index] =
            (channel_tile_value << 9) +
            (channel_tile_value << 7) +
            (channel_tile_value << 6) +
            (channel_tile_value << 4) +
            (channel_tile_value << 3) + channel_tile_value +
            lane_spatial_index_q[lane_index];
      else if (layer_is_conv_q)
        prepared_word_index[lane_index] =
            (channel_tile_value << 7) +
            (channel_tile_value << 5) +
            (channel_tile_value << 3) + channel_tile_value +
            lane_spatial_index_q[lane_index];
      else if (layer_id_q == 6)
        prepared_word_index[lane_index] =
            (channel_tile_value << 5) +
            (channel_tile_value << 2) +
            lane_spatial_index_q[lane_index];
    end
  end

  always_comb begin : form_banked_addresses
    integer lane_index;
    integer bank_index;
    logic [3:0] selected_bank;

    for (bank_index = 0; bank_index < CACHE_BANKS; bank_index++) begin
      bank_read_address[bank_index] = '0;
      bank_lane[bank_index] = '0;
      bank_byte[bank_index] = '0;
      bank_valid[bank_index] = 1'b0;
    end
    for (lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
      selected_bank = lane_word_index_q[lane_index][3:0];
      if (lane_valid_q[lane_index]) begin
        bank_read_address[selected_bank] =
            lane_word_index_q[lane_index][12:4];
        bank_lane[selected_bank] = lane_index;
        bank_byte[selected_bank] = lane_byte_q[lane_index];
        bank_valid[selected_bank] = 1'b1;
      end
    end
  end

  generate
    for (genvar bank_gen = 0; bank_gen < CACHE_BANKS; bank_gen++) begin : g_cache_bank
      alexnet_conv_activation_bank64 #(
          .DEPTH(CACHE_BANK_DEPTH), .ADDR_W(CACHE_BANK_ADDR_W)
      ) u_bank (
          .clk,
          .write_enable(input_fire &&
              (cache_write_low_bank == bank_gen ||
               cache_write_high_bank == bank_gen)),
          .write_address(cache_write_bank_address),
          .write_data(cache_write_low_bank == bank_gen ?
                      s_axis_tdata[63:0] : s_axis_tdata[127:64]),
          .read_enable(state_q == ST_ADDRESS),
          .read_address(bank_read_address[bank_gen]),
          .read_data(bank_read_data_q[bank_gen])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      fault_q <= 1'b0;
      cache_valid_q <= 1'b0;
      cached_layer_id <= 0;
      cached_base_q <= 0;
      dma_done_seen_q <= 1'b0;
      layer_id_q <= 0;
      request_k_offset_q <= 0;
      k_count_q <= 0;
      local_k_q <= 0;
      m_lane_mask_q <= 0;
      context_tag_q <= 0;
      m_count_q <= 0;
      cache_write_index_q <= 0;
      patch_word_q <= 0;
      conv_channel_q <= 0;
      conv_kx_q <= 0;
      conv_ky_q <= 0;
      position_remainder_q <= 0;
      base_output_y_q <= 0;
      base_output_x_q <= 0;
      fc_channel_q <= 0;
      fc_spatial_q <= 0;
      fc_linear_q <= 0;
      input_h_q <= 0;
      input_w_q <= 0;
      input_channels_q <= 0;
      kernel_q <= 0;
      padding_q <= 0;
      layer_is_conv_q <= 1'b0;
      layer_is_fc_q <= 1'b0;
      layer_is_conv2_q <= 1'b0;
      for (int lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
        lane_output_y_q[lane_index] <= 0;
        lane_output_x_q[lane_index] <= 0;
        lane_input_y_q[lane_index] <= 0;
        lane_input_x_q[lane_index] <= 0;
        lane_spatial_index_q[lane_index] <= 0;
        lane_word_index_q[lane_index] <= 0;
        lane_byte_q[lane_index] <= 0;
        lane_valid_q[lane_index] <= 1'b0;
      end
      cache_loads <= 0;
      completed_patches <= 0;
      emitted_patch_words <= 0;
    end else begin
      if (dma_done)
        dma_done_seen_q <= 1'b1;

      if (request_fire) begin
        layer_id_q <= request_layer_id;
        request_k_offset_q <= request_k_offset;
        k_count_q <= request_k_count;
        local_k_q <= 0;
        m_lane_mask_q <= request_m_lane_mask;
        context_tag_q <= request_context_tag;
        m_count_q <= requested_m_count;
        conv_channel_q <= 0;
        conv_kx_q <= 0;
        conv_ky_q <= 0;
        case (request_k_offset)
          14'd4096: begin
            fc_channel_q <= 9'd113;
            fc_spatial_q <= 6'd28;
          end
          14'd8192: begin
            fc_channel_q <= 9'd227;
            fc_spatial_q <= 6'd20;
          end
          default: begin
            fc_channel_q <= 0;
            fc_spatial_q <= 0;
          end
        endcase
        fc_linear_q <= request_k_offset[12:0];
        patch_word_q <= 0;
        position_remainder_q <= request_m_base;
        base_output_y_q <= 0;
        base_output_x_q <= 0;
        state_q <= ST_VALIDATE;
      end

      if (state_q == ST_VALIDATE) begin
        if (!request_fields_valid) begin
          fault_q <= 1'b1;
          state_q <= ST_FAILED;
        end else begin
          state_q <= ST_INIT_POSITION;
        end
      end

      if (state_q == ST_INIT_POSITION) begin
        input_h_q <= input_h;
        input_w_q <= input_w;
        input_channels_q <= input_channels;
        kernel_q <= kernel;
        padding_q <= padding;
        layer_is_conv_q <= layer_is_conv;
        layer_is_fc_q <= layer_is_fc;
        layer_is_conv2_q <= layer_id_q == 2;
        if (layer_is_conv && position_remainder_q >= input_w) begin
          position_remainder_q <= position_remainder_q - input_w;
          base_output_y_q <= base_output_y_q + 1'b1;
        end else begin
          base_output_x_q <= position_remainder_q[7:0];
          if (cache_valid_q && cached_layer_id == layer_id_q &&
              cached_base_q == configured_base) begin
            state_q <= ST_PREPARE_WORD;
          end else begin
            cache_valid_q <= 1'b0;
            cache_write_index_q <= 0;
            state_q <= ST_LOAD_COMMAND;
          end
        end
      end

      if (command_fire) begin
        dma_done_seen_q <= 1'b0;
        cache_write_index_q <= 0;
        state_q <= ST_LOAD_ARM;
      end

      if (state_q == ST_LOAD_ARM && dma_armed)
        state_q <= ST_LOAD_STREAM;

      if (input_fire) begin
        cache_write_index_q <= cache_write_index_q + 1'b1;
        if (s_axis_tkeep != 16'hffff ||
            s_axis_tlast != expected_input_last)
          fault_q <= 1'b1;
        if (expected_input_last) begin
          if (dma_done_seen_q || dma_done) begin
            cache_valid_q <= 1'b1;
            cached_layer_id <= layer_id_q;
            cached_base_q <= configured_base;
            cache_loads <= cache_loads + 1'b1;
            state_q <= ST_PREPARE_WORD;
          end else begin
            state_q <= ST_LOAD_DRAIN;
          end
        end
      end

      if (state_q == ST_LOAD_DRAIN && dma_done) begin
        dma_done_seen_q <= 1'b0;
        cache_valid_q <= 1'b1;
        cached_layer_id <= layer_id_q;
        cached_base_q <= configured_base;
        cache_loads <= cache_loads + 1'b1;
        state_q <= ST_PREPARE_WORD;
      end

      if (state_q == ST_PREPARE_WORD) begin
        patch_word_q <= 0;
        for (int lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
          lane_output_y_q[lane_index] <= prepared_output_y[lane_index];
          lane_output_x_q[lane_index] <= prepared_output_x[lane_index];
        end
        state_q <= ST_INPUT_COORD;
      end

      if (state_q == ST_INPUT_COORD) begin
        for (int lane_index = 0; lane_index < CACHE_BANKS; lane_index++) begin
          lane_input_y_q[lane_index] <= prepared_input_y[lane_index];
          lane_input_x_q[lane_index] <= prepared_input_x[lane_index];
          lane_spatial_index_q[lane_index] <=
              prepared_spatial_index[lane_index];
          lane_byte_q[lane_index] <= prepared_byte[lane_index];
          lane_valid_q[lane_index] <= prepared_valid[lane_index];
        end
        state_q <= ST_SPATIAL_INDEX;
      end

      if (state_q == ST_SPATIAL_INDEX) begin
        if (layer_is_conv_q)
          for (int lane_index = 0;
               lane_index < CACHE_BANKS; lane_index++)
            lane_spatial_index_q[lane_index] <=
                formed_spatial_index[lane_index];
        state_q <= ST_WORD_INDEX;
      end

      if (state_q == ST_WORD_INDEX) begin
        for (int lane_index = 0; lane_index < CACHE_BANKS; lane_index++)
          lane_word_index_q[lane_index] <= prepared_word_index[lane_index];
        state_q <= ST_ADDRESS;
      end

      if (state_q == ST_ADDRESS) begin
        for (int bank_index = 0; bank_index < CACHE_BANKS; bank_index++) begin
          bank_lane_q[bank_index] <= bank_lane[bank_index];
          bank_byte_q[bank_index] <= bank_byte[bank_index];
          bank_valid_q[bank_index] <= bank_valid[bank_index];
        end
        state_q <= ST_CAPTURE;
      end

      if (state_q == ST_CAPTURE) begin
        patch_word_q <= 0;
        for (int bank_index = 0; bank_index < CACHE_BANKS; bank_index++) begin
          if (bank_valid_q[bank_index])
            patch_word_q[bank_lane_q[bank_index]*8 +: 8] <=
                bank_read_data_q[bank_index][bank_byte_q[bank_index]*8 +: 8];
        end
        state_q <= ST_OUTPUT;
      end

      if (patch_fire) begin
        emitted_patch_words <= emitted_patch_words + 1'b1;
        if (patch_axis_tlast) begin
          completed_patches <= completed_patches + 1'b1;
          state_q <= ST_IDLE;
        end else begin
          local_k_q <= local_k_q + 1'b1;
          if (layer_is_conv) begin
            if (conv_channel_q + 1'b1 < input_channels_q)
              conv_channel_q <= conv_channel_q + 1'b1;
            else begin
              conv_channel_q <= 0;
              if (conv_kx_q + 1'b1 < kernel_q)
                conv_kx_q <= conv_kx_q + 1'b1;
              else begin
                conv_kx_q <= 0;
                conv_ky_q <= conv_ky_q + 1'b1;
              end
            end
          end else if (layer_id_q == 6) begin
            if (fc_spatial_q == 35) begin
              fc_spatial_q <= 0;
              fc_channel_q <= fc_channel_q + 1'b1;
            end else begin
              fc_spatial_q <= fc_spatial_q + 1'b1;
            end
          end else begin
            fc_linear_q <= fc_linear_q + 1'b1;
          end
          state_q <= ST_PREPARE_WORD;
        end
      end

      if (dma_error) begin
        fault_q <= 1'b1;
        state_q <= ST_FAILED;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (input_fire && cache_write_index_q >= MAX_CACHE_BEATS)
        $fatal(1, "activation patch cache overflow");
      if (state_q == ST_ADDRESS) begin
        for (int bank_index = 0; bank_index < CACHE_BANKS; bank_index++) begin
          if (bank_valid[bank_index] &&
              bank_read_address[bank_index] >= CACHE_BANK_DEPTH)
            $fatal(1, "activation patch cache bank read overflow");
        end
      end
      if (patch_fire && patch_axis_tlast &&
          emitted_patch_words + 1'b1 < k_count_q)
        $fatal(1, "activation patch service retired an early last");
    end
  end
`endif

endmodule
