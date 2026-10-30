`timescale 1ns/1ps

// One byte-wide bank per N8 lane.  The independent banks allow all eight
// signed INT8 lanes to be captured and compared in parallel while retaining
// a single BRAM read address for the spatial 3x3 window.
module alexnet_eyeriss_rs_pool_byte_bank #(
  parameter int DEPTH = 3025,
  parameter int ADDR_W = 12
) (
  input  logic              clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [7:0]        wr_data,
  input  logic              rd_en,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [7:0]        rd_data
);
  (* ram_style = "block" *) logic [7:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (wr_en)
      memory[wr_addr] <= wr_data;
    if (rd_en)
      rd_data <= memory[rd_addr];
  end
endmodule

// Batch-eight in-place pooling service for the pure-RS graph boundary.
// The raw N8 layout written by the RS result store is read one channel tile
// at a time, pooled with kernel=3/stride=2/padding=0, and written back to the
// beginning of the same per-image buffer.  Eight images are separated by the
// frozen 256-KiB image stride.  The largest on-chip tile is Conv1's
// 55*55*8 = 24,200 bytes; no convolution feature-map line buffer is used.
module alexnet_eyeriss_rs_batch8_inplace_pool_service #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,

  input  logic                       layer_valid,
  output logic                       layer_ready,
  input  logic [3:0]                 layer_id,
  input  logic [TAG_W-1:0]           layer_tag,
  input  logic [31:0]                layer_buffer_base,

  output logic                       dma_command_valid,
  input  logic                       dma_command_ready,
  output logic                       dma_command_s2mm,
  output logic [31:0]                dma_command_address,
  output logic [25:0]                dma_command_length,
  input  logic                       dma_armed,
  input  logic                       dma_done,
  input  logic                       dma_error,

  input  logic [127:0]               s_axis_tdata,
  input  logic [15:0]                s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,

  output logic [127:0]               m_axis_tdata,
  output logic [15:0]                m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,

  output logic                       layer_done,
  output logic                       layer_error,
  output logic                       busy,
  output logic [9:0]                 completed_tiles,
  output logic [31:0]                raw_words_read,
  output logic [31:0]                pooled_words_written,
  output logic [31:0]                mm2s_commands,
  output logic [31:0]                s2mm_commands
);
  localparam int MAX_RAW_WORDS = 3025;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_READ_COMMAND,
    ST_READ_ARM,
    ST_READ_STREAM,
    ST_READ_DRAIN,
    ST_WRITE_COMMAND,
    ST_WRITE_ARM,
    ST_POOL_ISSUE,
    ST_POOL_ACCUM,
    ST_POOL_WORD,
    ST_OUTPUT,
    ST_WRITE_DRAIN,
    ST_FAILED
  } state_t;

  state_t state_q;
  logic [3:0] layer_id_q;
  logic [TAG_W-1:0] layer_tag_q;
  logic [31:0] buffer_base_q;
  logic [2:0] image_index_q;
  logic [5:0] tile_index_q;

  logic [5:0] raw_h, raw_w, stored_h, stored_w, n8_tiles;
  logic [12:0] raw_words_per_tile, stored_words_per_tile;
  logic [11:0] raw_beats_per_tile;
  logic [25:0] raw_bytes_per_tile, stored_bytes_per_tile;
  (* use_dsp = "no" *) logic [31:0] raw_tile_offset;
  (* use_dsp = "no" *) logic [31:0] stored_tile_offset;
  logic [31:0] image_offset;

  logic [127:0] capture_data_q;
  logic [15:0] capture_keep_q;
  logic capture_valid_q, capture_high_q, capture_last_q;
  logic [11:0] capture_beat_index_q;
  logic [11:0] capture_word_index_q;
  logic capture_write;
  logic [63:0] capture_word;

  logic bank_wr_en, bank_rd_en;
  logic [11:0] bank_wr_addr, bank_rd_addr;
  logic [7:0] bank_wr_data [0:7];
  logic [7:0] bank_rd_data [0:7];

  logic [5:0] output_y_q, output_x_q;
  logic [3:0] kernel_index_q;
  logic [1:0] kernel_y, kernel_x;
  logic [5:0] source_y, source_x;
  logic signed [7:0] max_q [0:7];
  logic signed [7:0] next_max [0:7];
  logic [63:0] pooled_word_q;
  logic [63:0] low_word_q;
  logic low_word_valid_q;
  logic [127:0] output_data_q;
  logic [15:0] output_keep_q;
  logic output_valid_q, output_last_q;

  logic dma_done_seen_q, fault_q;
  logic command_fire, input_fire, output_fire;
  logic expected_input_last;
  logic [15:0] expected_input_keep;
  logic last_output_pixel;

  function automatic logic signed [7:0] max2(
      input logic signed [7:0] a,
      input logic signed [7:0] b);
    max2 = (a > b) ? a : b;
  endfunction

  assign layer_ready = state_q == ST_IDLE;
  assign busy = state_q != ST_IDLE;
  assign layer_error = fault_q || dma_error;

  assign dma_command_valid = state_q == ST_READ_COMMAND ||
                             state_q == ST_WRITE_COMMAND;
  assign dma_command_s2mm = state_q == ST_WRITE_COMMAND;
  assign dma_command_address = buffer_base_q + image_offset +
      (dma_command_s2mm ? stored_tile_offset : raw_tile_offset);
  assign dma_command_length = dma_command_s2mm ? stored_bytes_per_tile :
                                                   raw_bytes_per_tile;
  assign command_fire = dma_command_valid && dma_command_ready;

  assign s_axis_tready = state_q == ST_READ_STREAM && !capture_valid_q;
  assign input_fire = s_axis_tvalid && s_axis_tready;
  assign expected_input_last = capture_beat_index_q + 1'b1 ==
                               raw_beats_per_tile;
  assign expected_input_keep = expected_input_last &&
                               raw_words_per_tile[0] ? 16'h00ff : 16'hffff;

  assign capture_write = capture_valid_q;
  assign capture_word = capture_high_q ? capture_data_q[127:64] :
                                         capture_data_q[63:0];
  assign bank_wr_en = capture_write;
  assign bank_wr_addr = capture_word_index_q;
  always_comb begin
    for (int lane = 0; lane < 8; lane++)
      bank_wr_data[lane] = capture_word[lane*8 +: 8];
  end

  assign bank_rd_en = state_q == ST_POOL_ISSUE;
  always_comb begin
    kernel_y = 0;
    kernel_x = 0;
    case (kernel_index_q)
      0: begin kernel_y = 0; kernel_x = 0; end
      1: begin kernel_y = 0; kernel_x = 1; end
      2: begin kernel_y = 0; kernel_x = 2; end
      3: begin kernel_y = 1; kernel_x = 0; end
      4: begin kernel_y = 1; kernel_x = 1; end
      5: begin kernel_y = 1; kernel_x = 2; end
      6: begin kernel_y = 2; kernel_x = 0; end
      7: begin kernel_y = 2; kernel_x = 1; end
      default: begin kernel_y = 2; kernel_x = 2; end
    endcase
    source_y = (output_y_q << 1) + kernel_y;
    source_x = (output_x_q << 1) + kernel_x;
    case (layer_id_q)
      1: bank_rd_addr = (source_y << 5) + (source_y << 4) +
          (source_y << 2) + (source_y << 1) + source_y + source_x;
      2: bank_rd_addr = (source_y << 4) + (source_y << 3) +
          (source_y << 1) + source_y + source_x;
      default: bank_rd_addr = (source_y << 3) + (source_y << 2) +
          source_y + source_x;
    endcase
    for (int lane = 0; lane < 8; lane++)
      next_max[lane] = max2(max_q[lane], $signed(bank_rd_data[lane]));
  end

  assign last_output_pixel = output_y_q + 1'b1 == stored_h &&
                             output_x_q + 1'b1 == stored_w;
  assign m_axis_tdata = output_data_q;
  assign m_axis_tkeep = output_keep_q;
  assign m_axis_tvalid = output_valid_q;
  assign m_axis_tlast = output_last_q;
  assign output_fire = m_axis_tvalid && m_axis_tready;

  assign image_offset = {image_index_q, 18'b0};

  always_comb begin
    raw_h = 0;
    raw_w = 0;
    stored_h = 0;
    stored_w = 0;
    n8_tiles = 0;
    raw_words_per_tile = 0;
    stored_words_per_tile = 0;
    case (layer_id_q)
      1: begin
        raw_h = 55; raw_w = 55; stored_h = 27; stored_w = 27;
        n8_tiles = 8; raw_words_per_tile = 3025;
        stored_words_per_tile = 729;
      end
      2: begin
        raw_h = 27; raw_w = 27; stored_h = 13; stored_w = 13;
        n8_tiles = 24; raw_words_per_tile = 729;
        stored_words_per_tile = 169;
      end
      5: begin
        raw_h = 13; raw_w = 13; stored_h = 6; stored_w = 6;
        n8_tiles = 32; raw_words_per_tile = 169;
        stored_words_per_tile = 36;
      end
      default: begin end
    endcase
    raw_beats_per_tile = (raw_words_per_tile + 1'b1) >> 1;
    raw_bytes_per_tile = {10'd0, raw_words_per_tile, 3'b000};
    stored_bytes_per_tile = {10'd0, stored_words_per_tile, 3'b000};

    case (layer_id_q)
      1: raw_tile_offset = (tile_index_q << 14) +
          (tile_index_q << 12) + (tile_index_q << 11) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 3);
      2: raw_tile_offset = (tile_index_q << 12) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 6) +
          (tile_index_q << 3);
      5: raw_tile_offset = (tile_index_q << 10) +
          (tile_index_q << 8) + (tile_index_q << 6) +
          (tile_index_q << 3);
      default: raw_tile_offset = 0;
    endcase
    case (layer_id_q)
      1: stored_tile_offset = (tile_index_q << 12) +
          (tile_index_q << 10) + (tile_index_q << 9) +
          (tile_index_q << 7) + (tile_index_q << 6) +
          (tile_index_q << 3);
      2: stored_tile_offset = (tile_index_q << 10) +
          (tile_index_q << 8) + (tile_index_q << 6) +
          (tile_index_q << 3);
      5: stored_tile_offset = (tile_index_q << 8) +
          (tile_index_q << 5);
      default: stored_tile_offset = 0;
    endcase
  end

  generate
    for (genvar lane = 0; lane < 8; lane++) begin : g_pool_banks
      alexnet_eyeriss_rs_pool_byte_bank u_bank (
        .clk, .wr_en(bank_wr_en), .wr_addr(bank_wr_addr),
        .wr_data(bank_wr_data[lane]), .rd_en(bank_rd_en),
        .rd_addr(bank_rd_addr), .rd_data(bank_rd_data[lane])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      layer_id_q <= 0;
      layer_tag_q <= 0;
      buffer_base_q <= 0;
      image_index_q <= 0;
      tile_index_q <= 0;
      capture_data_q <= 0;
      capture_keep_q <= 0;
      capture_valid_q <= 1'b0;
      capture_high_q <= 1'b0;
      capture_last_q <= 1'b0;
      capture_beat_index_q <= 0;
      capture_word_index_q <= 0;
      output_y_q <= 0;
      output_x_q <= 0;
      kernel_index_q <= 0;
      for (int lane = 0; lane < 8; lane++)
        max_q[lane] <= 8'sh80;
      pooled_word_q <= 0;
      low_word_q <= 0;
      low_word_valid_q <= 1'b0;
      output_data_q <= 0;
      output_keep_q <= 0;
      output_valid_q <= 1'b0;
      output_last_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
      layer_done <= 1'b0;
      completed_tiles <= 0;
      raw_words_read <= 0;
      pooled_words_written <= 0;
      mm2s_commands <= 0;
      s2mm_commands <= 0;
    end else begin
      layer_done <= 1'b0;
      if (dma_done)
        dma_done_seen_q <= 1'b1;

      if (state_q == ST_IDLE && layer_valid && layer_ready) begin
        layer_id_q <= layer_id;
        layer_tag_q <= layer_tag;
        buffer_base_q <= layer_buffer_base;
        image_index_q <= 0;
        tile_index_q <= 0;
        completed_tiles <= 0;
        raw_words_read <= 0;
        pooled_words_written <= 0;
        mm2s_commands <= 0;
        s2mm_commands <= 0;
        fault_q <= layer_buffer_base[2:0] != 0 ||
                   !(layer_id == 1 || layer_id == 2 || layer_id == 5);
        if (layer_buffer_base[2:0] != 0 ||
            !(layer_id == 1 || layer_id == 2 || layer_id == 5))
          state_q <= ST_FAILED;
        else
          state_q <= ST_READ_COMMAND;
      end

      if (command_fire) begin
        dma_done_seen_q <= 1'b0;
        if (state_q == ST_READ_COMMAND) begin
          capture_valid_q <= 1'b0;
          capture_high_q <= 1'b0;
          capture_beat_index_q <= 0;
          capture_word_index_q <= 0;
          mm2s_commands <= mm2s_commands + 1'b1;
          state_q <= ST_READ_ARM;
        end else begin
          output_y_q <= 0;
          output_x_q <= 0;
          kernel_index_q <= 0;
          for (int lane = 0; lane < 8; lane++)
            max_q[lane] <= 8'sh80;
          low_word_valid_q <= 1'b0;
          output_valid_q <= 1'b0;
          output_last_q <= 1'b0;
          s2mm_commands <= s2mm_commands + 1'b1;
          state_q <= ST_WRITE_ARM;
        end
      end

      if (state_q == ST_READ_ARM && dma_armed)
        state_q <= ST_READ_STREAM;

      if (input_fire) begin
        capture_data_q <= s_axis_tdata;
        capture_keep_q <= s_axis_tkeep;
        capture_last_q <= s_axis_tlast;
        capture_valid_q <= 1'b1;
        capture_high_q <= 1'b0;
        if (s_axis_tkeep != expected_input_keep ||
            s_axis_tlast != expected_input_last)
          fault_q <= 1'b1;
        capture_beat_index_q <= capture_beat_index_q + 1'b1;
      end

      if (capture_write) begin
        capture_word_index_q <= capture_word_index_q + 1'b1;
        if (!capture_high_q && capture_keep_q[15:8] != 0) begin
          capture_high_q <= 1'b1;
        end else begin
          capture_valid_q <= 1'b0;
          capture_high_q <= 1'b0;
          if (capture_last_q) begin
            raw_words_read <= raw_words_read + raw_words_per_tile;
            if (dma_done_seen_q || dma_done)
              state_q <= ST_WRITE_COMMAND;
            else
              state_q <= ST_READ_DRAIN;
          end
        end
      end

      if (state_q == ST_READ_DRAIN && dma_done) begin
        dma_done_seen_q <= 1'b0;
        state_q <= ST_WRITE_COMMAND;
      end

      if (state_q == ST_WRITE_ARM && dma_armed)
        state_q <= ST_POOL_ISSUE;

      if (state_q == ST_POOL_ISSUE)
        state_q <= ST_POOL_ACCUM;

      if (state_q == ST_POOL_ACCUM) begin
        for (int lane = 0; lane < 8; lane++)
          max_q[lane] <= next_max[lane];
        if (kernel_index_q == 8) begin
          for (int lane = 0; lane < 8; lane++)
            pooled_word_q[lane*8 +: 8] <= next_max[lane];
          state_q <= ST_POOL_WORD;
        end else begin
          kernel_index_q <= kernel_index_q + 1'b1;
          state_q <= ST_POOL_ISSUE;
        end
      end

      if (state_q == ST_POOL_WORD) begin
        kernel_index_q <= 0;
        for (int lane = 0; lane < 8; lane++)
          max_q[lane] <= 8'sh80;

        if (low_word_valid_q) begin
          output_data_q <= {pooled_word_q, low_word_q};
          output_keep_q <= 16'hffff;
          output_last_q <= last_output_pixel;
          output_valid_q <= 1'b1;
          low_word_valid_q <= 1'b0;
          state_q <= ST_OUTPUT;
        end else if (last_output_pixel) begin
          output_data_q <= {64'b0, pooled_word_q};
          output_keep_q <= 16'h00ff;
          output_last_q <= 1'b1;
          output_valid_q <= 1'b1;
          state_q <= ST_OUTPUT;
        end else begin
          low_word_q <= pooled_word_q;
          low_word_valid_q <= 1'b1;
          if (output_x_q + 1'b1 == stored_w) begin
            output_x_q <= 0;
            output_y_q <= output_y_q + 1'b1;
          end else begin
            output_x_q <= output_x_q + 1'b1;
          end
          state_q <= ST_POOL_ISSUE;
        end
      end

      if (output_fire) begin
        output_valid_q <= 1'b0;
        pooled_words_written <= pooled_words_written +
                                (output_keep_q == 16'hffff ? 2 : 1);
        if (output_last_q) begin
          if (dma_done_seen_q || dma_done) begin
            completed_tiles <= completed_tiles + 1'b1;
            if (tile_index_q + 1'b1 < n8_tiles) begin
              tile_index_q <= tile_index_q + 1'b1;
              state_q <= ST_READ_COMMAND;
            end else if (image_index_q != 7) begin
              image_index_q <= image_index_q + 1'b1;
              tile_index_q <= 0;
              state_q <= ST_READ_COMMAND;
            end else begin
              layer_done <= 1'b1;
              state_q <= ST_IDLE;
            end
          end else begin
            state_q <= ST_WRITE_DRAIN;
          end
        end else begin
          if (output_x_q + 1'b1 == stored_w) begin
            output_x_q <= 0;
            output_y_q <= output_y_q + 1'b1;
          end else begin
            output_x_q <= output_x_q + 1'b1;
          end
          state_q <= ST_POOL_ISSUE;
        end
      end

      if (state_q == ST_WRITE_DRAIN && dma_done) begin
        completed_tiles <= completed_tiles + 1'b1;
        dma_done_seen_q <= 1'b0;
        if (tile_index_q + 1'b1 < n8_tiles) begin
          tile_index_q <= tile_index_q + 1'b1;
          state_q <= ST_READ_COMMAND;
        end else if (image_index_q != 7) begin
          image_index_q <= image_index_q + 1'b1;
          tile_index_q <= 0;
          state_q <= ST_READ_COMMAND;
        end else begin
          layer_done <= 1'b1;
          state_q <= ST_IDLE;
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
      if (capture_write && capture_word_index_q >= MAX_RAW_WORDS)
        $fatal(1, "batch8 in-place pool tile buffer overflow");
      if (bank_rd_en && bank_rd_addr >= raw_words_per_tile)
        $fatal(1, "batch8 in-place pool read outside raw tile");
      if (command_fire && dma_command_s2mm &&
          tile_index_q + 1'b1 < n8_tiles &&
          stored_tile_offset + stored_bytes_per_tile >
          raw_tile_offset + raw_bytes_per_tile)
        $fatal(1, "batch8 in-place pool write overtook unread raw data");
    end
  end
`endif
endmodule
