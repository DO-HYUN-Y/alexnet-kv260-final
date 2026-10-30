`timescale 1ns/1ps

// Reorder one final, requantized pure-RS image tile into the physical
// N8-tile-major activation layout used by the next AlexNet layer.  The RS
// reduction stream is filter/x/vertical-segment ordered; DDR is
// [N/8][y][x][8].  Eight byte-wide BRAM banks therefore hold one image of one
// scheduler filter tile and are drained in N8 order through a 128-bit S2MM
// stream.
//
// FC filter tiles contain 756 filters, which is four bytes short of an N8
// boundary.  A tiny per-image carry register retains that tail and merges it
// with the head of the following tile.  No partial N8 word is ever written.
module alexnet_eyeriss_rs_result_bram8 #(
  parameter int DEPTH = 4608,
  parameter int ADDR_W = $clog2(DEPTH)
) (
  input  logic              clk,
  input  logic              write_enable,
  input  logic [ADDR_W-1:0] write_address,
  input  logic [7:0]        write_data,
  input  logic              read_enable,
  input  logic [ADDR_W-1:0] read_address,
  output logic [7:0]        read_data
);
  (* ram_style = "block" *) logic [7:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable)
      memory[write_address] <= write_data;
    if (read_enable)
      read_data <= memory[read_address];
  end
endmodule

(* use_dsp = "no" *) module alexnet_eyeriss_rs_n8_result_store #(
  parameter int TAG_W = 16,
  parameter int BANK_DEPTH = 4608,
  parameter logic [63:0] ACTIVATION_IMAGE_STRIDE = 64'd262144
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic [63:0]                activation_a_base,
  input  logic [63:0]                activation_b_base,
  input  logic [63:0]                final_output_base,

  input  logic                       input_valid,
  output logic                       input_ready,
  input  logic [13:0]                input_col_valid,
  input  logic signed [7:0]          input_values [0:13],
  input  logic [TAG_W-1:0]           input_tag,
  input  logic [3:0]                 input_layer,
  input  logic [12:0]                input_filter,
  input  logic [2:0]                 input_image,
  input  logic [5:0]                 input_x,
  input  logic [5:0]                 input_y_base,

  output logic                       dma_command_valid,
  input  logic                       dma_command_ready,
  output logic [31:0]                dma_command_address,
  output logic [25:0]                dma_command_length,
  input  logic                       dma_armed,
  input  logic                       dma_done,
  input  logic                       dma_error,
  output logic [127:0]               m_axis_tdata,
  output logic [15:0]                m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,

  output logic                       idle,
  output logic                       fault,
  output logic [63:0]                accepted_vectors,
  output logic [63:0]                completed_image_tiles,
  output logic [63:0]                s2mm_commands,
  output logic [63:0]                emitted_bytes
);
  localparam int BANK_ADDR_W = $clog2(BANK_DEPTH);

  typedef enum logic [3:0] {
    ST_CAPTURE, ST_CONFIG, ST_CONFIG_COMMIT, ST_WRITE, ST_COMMAND, ST_ARM,
    ST_READ_ISSUE, ST_READ_WAIT, ST_READ_CAPTURE, ST_STREAM, ST_DRAIN,
    ST_FAILED
  } state_t;
  state_t state_q;

  logic [7:0] bank_read_data [0:7];
  logic bank_read_enable, bank_write_enable;
  logic [2:0] bank_write_select;
  logic [BANK_ADDR_W-1:0] bank_read_address, bank_write_address;

  logic tile_active_q;
  logic [TAG_W-1:0] tile_tag_q;
  logic [3:0] tile_layer_q;
  logic [12:0] tile_filter_base_q, tile_filter_count_q;
  logic [9:0] tile_base_group_q, tile_full_groups_q;
  logic [2:0] tile_head_lanes_q, tile_tail_lanes_q;
  logic [9:0] tile_tail_group_q;
  logic [2:0] tile_image_q;
  logic [5:0] tile_strip_y_q, tile_strip_rows_q;
  logic [5:0] tile_width_q, tile_height_q;
  logic [12:0] tile_strip_spatial_q, tile_full_spatial_q;
  logic [15:0] expected_vectors_q, accepted_image_vectors_q;
  logic [63:0] tile_target_base_q;

  logic [13:0] vector_col_valid_q;
  logic signed [7:0] vector_values_q [0:13];
  logic [TAG_W-1:0] vector_tag_q;
  logic [3:0] vector_layer_q;
  logic [12:0] vector_filter_q;
  logic [2:0] vector_image_q;
  logic [5:0] vector_x_q, vector_y_base_q;
  logic [3:0] write_lane_q;

  logic [7:0] carry_value_q [0:7][0:7];
  logic [7:0] carry_valid_q;
  logic [9:0] carry_group_q [0:7];

  logic [9:0] drain_group_q;
  logic [12:0] drain_position_q;
  logic [15:0] command_words_q, words_issued_q;
  logic [63:0] low_word_q;
  logic beat_half_q, dma_done_seen_q;
  logic config_fault_q;
  logic [127:0] axis_data_q;
  logic [15:0] axis_keep_q;
  logic axis_last_q;

  logic [5:0] current_height, current_width, current_map_e;
  logic [12:0] current_filters, current_tile_capacity;
  logic [12:0] current_filter_count;
  logic [5:0] current_strip_rows;
  logic [12:0] current_strip_spatial, current_full_spatial;
  logic [1:0] current_segments;
  logic [15:0] current_expected_vectors;
  logic [2:0] current_head_lanes, current_tail_lanes;
  logic [9:0] current_base_group, current_full_groups;
  logic [9:0] current_tail_group;
  logic [63:0] current_target_base;
  logic [13:0] expected_col_valid;
  logic input_descriptor_valid, configured_descriptor_valid;
  logic [3:0] descriptor_layer;
  logic [12:0] descriptor_filter;
  logic [5:0] descriptor_y_base;
  logic vector_is_last;
  logic write_lane_valid;
  logic [9:0] write_local_group;
  logic [5:0] write_local_y;
  logic [12:0] write_spatial_position;
  logic [13:0] write_address_wide;
  logic [13:0] read_address_wide;
  logic [63:0] selected_read_word;
  logic read_word_is_last;
  logic command_is_grouped;
  logic [63:0] command_byte_address;
  logic [15:0] command_word_count;

  assign descriptor_layer = vector_layer_q;
  assign descriptor_filter = vector_filter_q;
  assign descriptor_y_base = vector_y_base_q;

  always_comb begin
    current_height = 1;
    current_width = 1;
    current_filters = 1;
    current_map_e = 1;
    current_tile_capacity = 13'd756;
    current_target_base = final_output_base;
    case (descriptor_layer)
      1: begin current_height = 55; current_width = 55;
               current_filters = 64; current_map_e = 7;
               current_tile_capacity = 96;
               current_target_base = activation_a_base; end
      2: begin current_height = 27; current_width = 27;
               current_filters = 192; current_map_e = 27;
               current_tile_capacity = 48;
               current_target_base = activation_b_base; end
      3: begin current_height = 13; current_width = 13;
               current_filters = 384; current_map_e = 13;
               current_tile_capacity = 192;
               current_target_base = activation_a_base; end
      4: begin current_height = 13; current_width = 13;
               current_filters = 256; current_map_e = 13;
               current_tile_capacity = 192;
               current_target_base = activation_b_base; end
      5: begin current_height = 13; current_width = 13;
               current_filters = 256; current_map_e = 13;
               current_tile_capacity = 192;
               current_target_base = activation_a_base; end
      6: begin current_filters = 4096; current_target_base = activation_b_base; end
      7: begin current_filters = 4096; current_target_base = activation_a_base; end
      8: begin current_filters = 1000; current_target_base = final_output_base; end
      default: begin end
    endcase

    if (descriptor_filter + current_tile_capacity > current_filters)
      current_filter_count = current_filters - descriptor_filter;
    else
      current_filter_count = current_tile_capacity;
    if (descriptor_y_base + current_map_e > current_height)
      current_strip_rows = current_height - descriptor_y_base;
    else
      current_strip_rows = current_map_e;
    current_strip_spatial = current_strip_rows * current_width;
    current_full_spatial = current_height * current_width;
    current_segments = (current_strip_rows + 13) / 14;
    current_expected_vectors = current_width * current_filter_count *
                               current_segments;
    current_head_lanes = descriptor_filter[2:0];
    current_base_group = descriptor_filter >> 3;
    current_full_groups = (current_head_lanes + current_filter_count) >> 3;
    current_tail_lanes = (current_head_lanes + current_filter_count) & 7;
    current_tail_group = (descriptor_filter + current_filter_count) >> 3;
  end

  always_comb begin
    expected_col_valid = '0;
    for (integer lane = 0; lane < 14; lane = lane + 1)
      if ((input_y_base + lane) >= tile_strip_y_q &&
          (input_y_base + lane) <
              (tile_strip_y_q + tile_strip_rows_q))
        expected_col_valid[lane] = 1'b1;

    input_descriptor_valid = input_layer == tile_layer_q &&
        input_tag == tile_tag_q && input_col_valid != 0 &&
        input_image == tile_image_q &&
        input_filter >= tile_filter_base_q &&
        input_filter < tile_filter_base_q + tile_filter_count_q &&
        input_x < tile_width_q && input_y_base >= tile_strip_y_q &&
        input_y_base < tile_strip_y_q + tile_strip_rows_q &&
        input_col_valid == expected_col_valid;
    if (!tile_active_q)
      input_descriptor_valid = input_layer >= 1 && input_layer <= 8 &&
          input_image == 0 && input_x == 0 && input_col_valid != 0;
    else if (accepted_image_vectors_q == 0 &&
                 tile_head_lanes_q != 0) begin
      input_descriptor_valid = input_descriptor_valid &&
          carry_valid_q[tile_image_q] &&
          carry_group_q[tile_image_q] == tile_base_group_q;
    end

    configured_descriptor_valid = vector_layer_q >= 1 &&
        vector_layer_q <= 8 && vector_image_q == 0 &&
        vector_filter_q < current_filters && vector_x_q == 0 &&
        vector_y_base_q < current_height && vector_col_valid_q != 0 &&
        current_target_base[2:0] == 0 &&
        current_target_base[63:32] == 0;
    if (current_head_lanes != 0)
      configured_descriptor_valid = configured_descriptor_valid &&
          carry_valid_q[0] && carry_group_q[0] == current_base_group;
  end

  assign input_ready = state_q == ST_CAPTURE && !fault;
  assign vector_is_last = accepted_image_vectors_q == expected_vectors_q;
  assign write_lane_valid = vector_col_valid_q[write_lane_q];
  assign write_local_group = (vector_filter_q >> 3) - tile_base_group_q;
  assign write_local_y = vector_y_base_q + write_lane_q - tile_strip_y_q;
  assign write_spatial_position = write_local_y * tile_width_q + vector_x_q;
  assign write_address_wide = write_local_group * tile_strip_spatial_q +
                              write_spatial_position;
  assign bank_write_enable = state_q == ST_WRITE && write_lane_valid;
  assign bank_write_select = vector_filter_q[2:0];
  assign bank_write_address = write_address_wide[BANK_ADDR_W-1:0];

  assign bank_read_enable = state_q == ST_READ_ISSUE;
  assign read_address_wide = drain_group_q * tile_strip_spatial_q +
                             drain_position_q;
  assign bank_read_address = read_address_wide[BANK_ADDR_W-1:0];

  always_comb begin
    selected_read_word = '0;
    for (integer bank = 0; bank < 8; bank = bank + 1) begin
      if (drain_group_q == 0 && tile_head_lanes_q != 0 &&
          bank < tile_head_lanes_q)
        selected_read_word[bank*8 +: 8] =
            carry_value_q[tile_image_q][bank];
      else
        selected_read_word[bank*8 +: 8] = bank_read_data[bank];
    end
  end

  assign command_is_grouped = tile_strip_rows_q != tile_height_q;
  assign command_word_count = command_is_grouped ? tile_strip_spatial_q :
      tile_full_groups_q * tile_strip_spatial_q;
  assign command_byte_address = tile_target_base_q +
      tile_image_q * ACTIVATION_IMAGE_STRIDE +
      (tile_base_group_q + (command_is_grouped ? drain_group_q : 0)) *
          tile_full_spatial_q * 8 +
      tile_strip_y_q * tile_width_q * 8;

  assign dma_command_valid = state_q == ST_COMMAND;
  assign dma_command_address = command_byte_address[31:0];
  assign dma_command_length = command_word_count * 8;
  assign m_axis_tvalid = state_q == ST_STREAM;
  assign m_axis_tdata = axis_data_q;
  assign m_axis_tkeep = axis_keep_q;
  assign m_axis_tlast = axis_last_q;
  assign read_word_is_last = words_issued_q + 1 == command_words_q;
  assign idle = state_q == ST_CAPTURE && !tile_active_q &&
                carry_valid_q == 0;

  generate
    for (genvar bank = 0; bank < 8; bank = bank + 1) begin : g_banks
      alexnet_eyeriss_rs_result_bram8 #(
        .DEPTH(BANK_DEPTH), .ADDR_W(BANK_ADDR_W)
      ) u_bank (
        .clk,
        .write_enable(bank_write_enable && bank_write_select == bank),
        .write_address(bank_write_address),
        .write_data(vector_values_q[write_lane_q]),
        .read_enable(bank_read_enable), .read_address(bank_read_address),
        .read_data(bank_read_data[bank])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_CAPTURE;
      tile_active_q <= 1'b0;
      tile_tag_q <= '0;
      tile_layer_q <= '0;
      tile_filter_base_q <= '0;
      tile_filter_count_q <= '0;
      tile_base_group_q <= '0;
      tile_full_groups_q <= '0;
      tile_head_lanes_q <= '0;
      tile_tail_lanes_q <= '0;
      tile_tail_group_q <= '0;
      tile_image_q <= '0;
      tile_strip_y_q <= '0;
      tile_strip_rows_q <= '0;
      tile_width_q <= '0;
      tile_height_q <= '0;
      tile_strip_spatial_q <= '0;
      tile_full_spatial_q <= '0;
      expected_vectors_q <= '0;
      accepted_image_vectors_q <= '0;
      tile_target_base_q <= '0;
      vector_col_valid_q <= '0;
      vector_tag_q <= '0;
      vector_layer_q <= '0;
      vector_filter_q <= '0;
      vector_image_q <= '0;
      vector_x_q <= '0;
      vector_y_base_q <= '0;
      write_lane_q <= '0;
      carry_valid_q <= '0;
      for (integer image = 0; image < 8; image = image + 1) begin
        carry_group_q[image] <= '0;
        for (integer lane = 0; lane < 8; lane = lane + 1)
          carry_value_q[image][lane] <= '0;
      end
      drain_group_q <= '0;
      drain_position_q <= '0;
      command_words_q <= '0;
      words_issued_q <= '0;
      low_word_q <= '0;
      beat_half_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      config_fault_q <= 1'b0;
      axis_data_q <= '0;
      axis_keep_q <= '0;
      axis_last_q <= 1'b0;
      fault <= 1'b0;
      accepted_vectors <= '0;
      completed_image_tiles <= '0;
      s2mm_commands <= '0;
      emitted_bytes <= '0;
      for (integer lane = 0; lane < 14; lane = lane + 1)
        vector_values_q[lane] <= '0;
    end else begin
      if (dma_done)
        dma_done_seen_q <= 1'b1;
      if (dma_error) begin
        fault <= 1'b1;
        state_q <= ST_FAILED;
      end else begin
        case (state_q)
          ST_CAPTURE: begin
            if (input_valid && input_ready) begin
              if (!input_descriptor_valid) begin
                fault <= 1'b1;
                state_q <= ST_FAILED;
              end else begin
                vector_col_valid_q <= input_col_valid;
                vector_tag_q <= input_tag;
                vector_layer_q <= input_layer;
                vector_filter_q <= input_filter;
                vector_image_q <= input_image;
                vector_x_q <= input_x;
                vector_y_base_q <= input_y_base;
                for (integer lane = 0; lane < 14; lane = lane + 1)
                  vector_values_q[lane] <= input_values[lane];
                if (!tile_active_q) begin
                  state_q <= ST_CONFIG;
                end else begin
                  accepted_image_vectors_q <=
                      accepted_image_vectors_q + 1'b1;
                  accepted_vectors <= accepted_vectors + 1'b1;
                  write_lane_q <= 0;
                  state_q <= ST_WRITE;
                end
              end
            end
          end

          ST_CONFIG: begin
            tile_active_q <= 1'b1;
            tile_tag_q <= vector_tag_q;
            tile_layer_q <= vector_layer_q;
            tile_filter_base_q <= vector_filter_q;
            tile_filter_count_q <= current_filter_count;
            tile_base_group_q <= current_base_group;
            tile_full_groups_q <= current_full_groups;
            tile_head_lanes_q <= current_head_lanes;
            tile_tail_lanes_q <= current_tail_lanes;
            tile_tail_group_q <= current_tail_group;
            tile_image_q <= 0;
            tile_strip_y_q <= vector_y_base_q;
            tile_strip_rows_q <= current_strip_rows;
            tile_width_q <= current_width;
            tile_height_q <= current_height;
            tile_strip_spatial_q <= current_strip_spatial;
            tile_full_spatial_q <= current_full_spatial;
            expected_vectors_q <= current_expected_vectors;
            tile_target_base_q <= current_target_base;
            config_fault_q <= !configured_descriptor_valid;
            state_q <= ST_CONFIG_COMMIT;
          end

          ST_CONFIG_COMMIT: begin
            if (config_fault_q) begin
              fault <= 1'b1;
              state_q <= ST_FAILED;
            end else begin
              accepted_image_vectors_q <= 1;
              accepted_vectors <= accepted_vectors + 1'b1;
              write_lane_q <= 0;
              state_q <= ST_WRITE;
            end
          end

          ST_WRITE: begin
            if (write_lane_valid && tile_tail_lanes_q != 0 &&
                (vector_filter_q >> 3) == tile_tail_group_q)
              carry_value_q[tile_image_q][vector_filter_q[2:0]] <=
                  vector_values_q[write_lane_q];

            if (write_lane_q == 13) begin
              if (vector_is_last) begin
                drain_group_q <= 0;
                drain_position_q <= 0;
                command_words_q <= command_is_grouped ?
                    tile_strip_spatial_q :
                    tile_full_groups_q * tile_strip_spatial_q;
                words_issued_q <= 0;
                beat_half_q <= 1'b0;
                dma_done_seen_q <= 1'b0;
                state_q <= ST_COMMAND;
              end else begin
                state_q <= ST_CAPTURE;
              end
            end else begin
              write_lane_q <= write_lane_q + 1'b1;
            end
          end

          ST_COMMAND: begin
            if (dma_command_valid && dma_command_ready) begin
              s2mm_commands <= s2mm_commands + 1'b1;
              dma_done_seen_q <= 1'b0;
              state_q <= ST_ARM;
            end
          end

          ST_ARM: if (dma_armed) state_q <= ST_READ_ISSUE;

          ST_READ_ISSUE: state_q <= ST_READ_WAIT;
          ST_READ_WAIT: state_q <= ST_READ_CAPTURE;

          ST_READ_CAPTURE: begin
            words_issued_q <= words_issued_q + 1'b1;
            if (!beat_half_q) begin
              low_word_q <= selected_read_word;
              if (read_word_is_last) begin
                axis_data_q <= {64'd0, selected_read_word};
                axis_keep_q <= 16'h00ff;
                axis_last_q <= 1'b1;
                state_q <= ST_STREAM;
              end else begin
                beat_half_q <= 1'b1;
                if (drain_position_q + 1 == tile_strip_spatial_q) begin
                  drain_position_q <= 0;
                  drain_group_q <= drain_group_q + 1'b1;
                end else begin
                  drain_position_q <= drain_position_q + 1'b1;
                end
                state_q <= ST_READ_ISSUE;
              end
            end else begin
              axis_data_q <= {selected_read_word, low_word_q};
              axis_keep_q <= 16'hffff;
              axis_last_q <= read_word_is_last;
              beat_half_q <= 1'b0;
              state_q <= ST_STREAM;
            end
          end

          ST_STREAM: begin
            if (m_axis_tvalid && m_axis_tready) begin
              emitted_bytes <= emitted_bytes +
                  (axis_keep_q == 16'hffff ? 16 : 8);
              if (axis_last_q) begin
                state_q <= ST_DRAIN;
              end else begin
                if (drain_position_q + 1 == tile_strip_spatial_q) begin
                  drain_position_q <= 0;
                  drain_group_q <= drain_group_q + 1'b1;
                end else begin
                  drain_position_q <= drain_position_q + 1'b1;
                end
                state_q <= ST_READ_ISSUE;
              end
            end
          end

          ST_DRAIN: begin
            if (dma_done_seen_q || dma_done) begin
              dma_done_seen_q <= 1'b0;
              if (command_is_grouped &&
                  drain_group_q + 1 < tile_full_groups_q) begin
                drain_group_q <= drain_group_q + 1'b1;
                drain_position_q <= 0;
                words_issued_q <= 0;
                command_words_q <= tile_strip_spatial_q;
                beat_half_q <= 1'b0;
                state_q <= ST_COMMAND;
              end else begin
                completed_image_tiles <= completed_image_tiles + 1'b1;
                if (tile_tail_lanes_q != 0) begin
                  carry_valid_q[tile_image_q] <= 1'b1;
                  carry_group_q[tile_image_q] <= tile_tail_group_q;
                end else if (tile_head_lanes_q != 0) begin
                  carry_valid_q[tile_image_q] <= 1'b0;
                end

                accepted_image_vectors_q <= 0;
                if (tile_image_q == 7) begin
                  tile_active_q <= 1'b0;
                  tile_image_q <= 0;
                end else begin
                  tile_image_q <= tile_image_q + 1'b1;
                end
                state_q <= ST_CAPTURE;
              end
            end
          end

          ST_FAILED: state_q <= ST_FAILED;
          default: begin
            fault <= 1'b1;
            state_q <= ST_FAILED;
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && bank_write_enable && write_address_wide >= BANK_DEPTH)
      $fatal(1, "pure-RS N8 result-store BRAM address overflow");
    if (!rst && state_q == ST_COMMAND && command_byte_address[63:32] != 0)
      $fatal(1, "pure-RS N8 result-store address exceeds DMA width");
  end
`endif

endmodule
