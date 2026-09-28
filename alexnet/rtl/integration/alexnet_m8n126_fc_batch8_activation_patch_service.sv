`timescale 1ns/1ps

module alexnet_fc_batch_activation_bank64 #(
    parameter int DEPTH = 576,
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

// Assemble native batch-eight FC activation patches.
//
// FC6 reads the eight non-contiguous Pool5 tensors left by the per-image
// convolution passes.  FC7/8 read the coalescer's compact
// [N8 tile][batch M][8 lanes] tensor.  Once a layer has been cached, every
// N16 weight tile replays it without another DDR access.
module alexnet_m8n126_fc_batch8_activation_patch_service #(
    parameter int MAX_CACHE_BEATS = 4608,
    parameter logic [31:0] IMAGE_SLOT_STRIDE = 32'd262144
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

    input  logic [31:0] pool5_image0_base,
    input  logic [31:0] batch_activation_a_base,
    input  logic [31:0] batch_activation_b_base,

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
    output logic [31:0] cache_load_commands,
    output logic [31:0] completed_patches,
    output logic [31:0] emitted_patch_words
);
  localparam int POOL5_BYTES = 9216;
  localparam int POOL5_BEATS = POOL5_BYTES / 16;
  localparam int BATCH_FC_BYTES = 32768;
  localparam int BATCH_FC_BEATS = BATCH_FC_BYTES / 16;
  localparam int CACHE_BANKS = 16;
  localparam int CACHE_BANK_DEPTH = (MAX_CACHE_BEATS + 7) / 8;
  localparam int CACHE_BANK_ADDR_W = $clog2(CACHE_BANK_DEPTH);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_LOAD_COMMAND,
    ST_LOAD_ARM,
    ST_LOAD_STREAM,
    ST_LOAD_DRAIN,
    ST_PREPARE_WORD,
    ST_ADDRESS,
    ST_CAPTURE,
    ST_OUTPUT,
    ST_FAILED
  } state_t;

  state_t state_q;
  // Two parity banks per image allow both halves of an FC6 DDR beat to be
  // stored together, while eight image banks are read in parallel for every
  // batch-eight patch word.

  logic fault_q, cache_valid_q, dma_done_seen_q;
  logic [3:0] layer_id_q;
  logic [13:0] global_k_q;
  logic [12:0] local_k_q, k_count_q;
  logic [15:0] context_tag_q;
  logic [2:0] load_image_q;
  logic [8:0] fc6_channel_q;
  logic [5:0] fc6_spatial_q;
  logic [11:0] command_beat_q;
  logic [127:0] patch_word_q;
  logic [3:0] cache_write_low_bank, cache_write_high_bank;
  logic [CACHE_BANK_ADDR_W-1:0] cache_write_bank_address;
  logic [CACHE_BANK_ADDR_W-1:0] bank_read_address;
  logic [63:0] bank_read_data_q [0:CACHE_BANKS-1];
  logic bank_read_parity, bank_read_parity_q;
  logic [2:0] bank_read_byte, bank_read_byte_q;

  logic [25:0] configured_bytes;
  logic [11:0] configured_beats;
  logic [31:0] configured_base;
  logic request_fields_valid;
  logic request_fire, command_fire, input_fire, patch_fire;
  logic expected_input_last;

  assign request_ready = state_q == ST_IDLE && !fault_q;
  assign request_fire = request_valid && request_ready;
  assign busy = state_q != ST_IDLE;
  assign fault = fault_q || dma_error;
  assign cache_load_active = state_q == ST_LOAD_COMMAND ||
      state_q == ST_LOAD_ARM || state_q == ST_LOAD_STREAM ||
      state_q == ST_LOAD_DRAIN;

  always_comb begin
    configured_base = 0;
    configured_bytes = 0;
    if (layer_id_q == 6) begin
      configured_base = pool5_image0_base +
                        load_image_q * IMAGE_SLOT_STRIDE;
      configured_bytes = POOL5_BYTES;
    end else if (layer_id_q == 7) begin
      configured_base = batch_activation_b_base;
      configured_bytes = BATCH_FC_BYTES;
    end else if (layer_id_q == 8) begin
      configured_base = batch_activation_a_base;
      configured_bytes = BATCH_FC_BYTES;
    end
    configured_beats = configured_bytes[15:4];
  end

  assign dma_command_valid = state_q == ST_LOAD_COMMAND;
  assign dma_command_address = configured_base;
  assign dma_command_length = configured_bytes;
  assign command_fire = dma_command_valid && dma_command_ready;
  assign s_axis_tready = (state_q == ST_LOAD_ARM ||
                          state_q == ST_LOAD_STREAM) &&
                         command_beat_q < configured_beats;
  assign input_fire = s_axis_tvalid && s_axis_tready;
  assign expected_input_last = command_beat_q + 1'b1 ==
                               configured_beats;

  always_comb begin
    cache_write_low_bank = 0;
    cache_write_high_bank = 1;
    cache_write_bank_address = 0;
    if (layer_id_q == 6) begin
      cache_write_low_bank = {load_image_q, 1'b0};
      cache_write_high_bank = {load_image_q, 1'b1};
      cache_write_bank_address = command_beat_q;
    end else begin
      // Four DDR beats contain the eight image words for one K/8 word.
      cache_write_low_bank = {command_beat_q[1:0], 1'b0,
                              command_beat_q[2]};
      cache_write_high_bank = {command_beat_q[1:0], 1'b1,
                               command_beat_q[2]};
      cache_write_bank_address = command_beat_q >> 3;
    end
  end

  assign patch_axis_tdata = patch_word_q;
  assign patch_axis_tvalid = state_q == ST_OUTPUT;
  assign patch_axis_tlast = local_k_q + 1'b1 == k_count_q;
  assign patch_fire = patch_axis_tvalid && patch_axis_tready;

  always_comb begin
    request_fields_valid = request_layer_id >= 6 &&
        request_layer_id <= 8 && request_m_base == 0 &&
        request_m_lane_mask == 16'h00ff && request_k_count != 0 &&
        pool5_image0_base[3:0] == 0 &&
        batch_activation_a_base[3:0] == 0 &&
        batch_activation_b_base[3:0] == 0;
    case (request_layer_id)
      6: request_fields_valid &=
          (request_k_offset == 0 && request_k_count == 4096) ||
          (request_k_offset == 4096 && request_k_count == 4096) ||
          (request_k_offset == 8192 && request_k_count == 1024);
      7, 8: request_fields_valid &= request_k_offset == 0 &&
             request_k_count == 4096;
      default: request_fields_valid = 1'b0;
    endcase
  end

  // All images use the same logical word address.  Eight independent image
  // banks therefore supply the complete batch word in one RAM read.
  always_comb begin
    bank_read_address = 0;
    bank_read_parity = 0;
    bank_read_byte = 0;
    if (layer_id_q == 6) begin
      bank_read_address = (((fc6_channel_q >> 3) << 5) +
          ((fc6_channel_q >> 3) << 2) + fc6_spatial_q) >> 1;
      bank_read_parity = (((fc6_channel_q >> 3) << 5) +
          ((fc6_channel_q >> 3) << 2) + fc6_spatial_q) & 1;
      bank_read_byte = fc6_channel_q[2:0];
    end else begin
      bank_read_address = global_k_q >> 4;
      bank_read_parity = global_k_q[3];
      bank_read_byte = global_k_q[2:0];
    end
  end

  generate
    for (genvar bank_gen = 0; bank_gen < CACHE_BANKS; bank_gen++) begin : g_cache_bank
      alexnet_fc_batch_activation_bank64 #(
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
          .read_address(bank_read_address),
          .read_data(bank_read_data_q[bank_gen])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      fault_q <= 1'b0;
      cache_valid_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      cached_layer_id <= 0;
      layer_id_q <= 0;
      global_k_q <= 0;
      local_k_q <= 0;
      k_count_q <= 0;
      context_tag_q <= 0;
      load_image_q <= 0;
      fc6_channel_q <= 0;
      fc6_spatial_q <= 0;
      command_beat_q <= 0;
      bank_read_parity_q <= 0;
      bank_read_byte_q <= 0;
      patch_word_q <= 0;
      cache_load_commands <= 0;
      completed_patches <= 0;
      emitted_patch_words <= 0;
    end else begin
      if (dma_done)
        dma_done_seen_q <= 1'b1;

      if (request_fire) begin
        layer_id_q <= request_layer_id;
        global_k_q <= request_k_offset;
        local_k_q <= 0;
        k_count_q <= request_k_count;
        context_tag_q <= request_context_tag;
        patch_word_q <= 0;
        case (request_k_offset)
          14'd4096: begin
            fc6_channel_q <= 9'd113;
            fc6_spatial_q <= 6'd28;
          end
          14'd8192: begin
            fc6_channel_q <= 9'd227;
            fc6_spatial_q <= 6'd20;
          end
          default: begin
            fc6_channel_q <= 0;
            fc6_spatial_q <= 0;
          end
        endcase
        if (!request_fields_valid) begin
          fault_q <= 1'b1;
          state_q <= ST_FAILED;
        end else if (cache_valid_q &&
                     cached_layer_id == request_layer_id) begin
          state_q <= ST_PREPARE_WORD;
        end else begin
          cache_valid_q <= 1'b0;
          load_image_q <= 0;
          state_q <= ST_LOAD_COMMAND;
        end
      end

      if (command_fire) begin
        command_beat_q <= 0;
        dma_done_seen_q <= 1'b0;
        cache_load_commands <= cache_load_commands + 1'b1;
        state_q <= ST_LOAD_ARM;
      end

      if (state_q == ST_LOAD_ARM && dma_armed)
        state_q <= ST_LOAD_STREAM;

      if (input_fire) begin
        command_beat_q <= command_beat_q + 1'b1;
        if (s_axis_tkeep != 16'hffff ||
            s_axis_tlast != expected_input_last)
          fault_q <= 1'b1;
        if (expected_input_last) begin
          if (dma_done_seen_q || dma_done) begin
            dma_done_seen_q <= 1'b0;
            if (layer_id_q == 6 && load_image_q != 7) begin
              load_image_q <= load_image_q + 1'b1;
              state_q <= ST_LOAD_COMMAND;
            end else begin
              cache_valid_q <= 1'b1;
              cached_layer_id <= layer_id_q;
              state_q <= ST_PREPARE_WORD;
            end
          end else begin
            state_q <= ST_LOAD_DRAIN;
          end
        end
      end

      if (state_q == ST_LOAD_DRAIN && dma_done) begin
        dma_done_seen_q <= 1'b0;
        if (layer_id_q == 6 && load_image_q != 7) begin
          load_image_q <= load_image_q + 1'b1;
          state_q <= ST_LOAD_COMMAND;
        end else begin
          cache_valid_q <= 1'b1;
          cached_layer_id <= layer_id_q;
          state_q <= ST_PREPARE_WORD;
        end
      end

      if (state_q == ST_PREPARE_WORD) begin
        patch_word_q <= 0;
        state_q <= ST_ADDRESS;
      end

      if (state_q == ST_ADDRESS) begin
        bank_read_parity_q <= bank_read_parity;
        bank_read_byte_q <= bank_read_byte;
        state_q <= ST_CAPTURE;
      end

      if (state_q == ST_CAPTURE) begin
        patch_word_q <= 0;
        for (int image_index = 0; image_index < 8; image_index++) begin
          patch_word_q[image_index*8 +: 8] <=
              bank_read_data_q[image_index*2 + bank_read_parity_q]
                  [bank_read_byte_q*8 +: 8];
        end
        state_q <= ST_OUTPUT;
      end

      if (patch_fire) begin
        emitted_patch_words <= emitted_patch_words + 1'b1;
        if (patch_axis_tlast) begin
          completed_patches <= completed_patches + 1'b1;
          state_q <= ST_IDLE;
        end else begin
          global_k_q <= global_k_q + 1'b1;
          local_k_q <= local_k_q + 1'b1;
          if (layer_id_q == 6) begin
            if (fc6_spatial_q == 35) begin
              fc6_spatial_q <= 0;
              fc6_channel_q <= fc6_channel_q + 1'b1;
            end else begin
              fc6_spatial_q <= fc6_spatial_q + 1'b1;
            end
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
      if (input_fire && cache_write_bank_address >= CACHE_BANK_DEPTH)
        $fatal(1, "batch8 FC activation cache write overflow");
      if (state_q == ST_ADDRESS && bank_read_address >= CACHE_BANK_DEPTH)
        $fatal(1, "batch8 FC activation cache read overflow");
      if (patch_fire && patch_axis_tlast &&
          local_k_q + 1'b1 != k_count_q)
        $fatal(1, "batch8 FC activation patch ended early");
    end
  end
`endif

endmodule
