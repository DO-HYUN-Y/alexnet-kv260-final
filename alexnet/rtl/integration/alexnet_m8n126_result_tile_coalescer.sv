`timescale 1ns/1ps

module alexnet_result_tile_uram64 #(
    parameter int DEPTH = 3032,
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input  logic clk,
    input  logic write_enable,
    input  logic [ADDR_W-1:0] write_address,
    input  logic [63:0] write_data,
    input  logic [ADDR_W-1:0] read_address,
    output logic [63:0] read_data
);
  (* ram_style = "ultra" *) logic [63:0] memory [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (write_enable)
      memory[write_address] <= write_data;
    read_data <= memory[read_address];
  end
endmodule

// Reorder the payload's M-major N8 slices into the graph's physical
// [N8 tile][spatial/batch M][8 lanes] layout, then write one complete logical
// N tile with a single S2MM command.  This replaces thousands of 8..64-byte
// simple-mode DMA commands with one burst command per scheduler N tile.
module alexnet_m8n126_result_tile_coalescer #(
    parameter int MAX_WORDS = 3032
) (
    input logic clk,
    input logic rst,

    input  logic result_valid,
    output logic result_ready,
    input  logic [3:0] result_layer_id,
    input  logic [3:0] fc_batch_size,
    input  logic [31:0] result_base,
    input  logic [63:0] result_values [0:7],
    input  logic [3:0] result_m_count,
    input  logic [12:0] result_m_base,
    input  logic [15:0] result_n_base,
    input  logic result_last_slice,

    output logic dma_command_valid,
    input  logic dma_command_ready,
    output logic [31:0] dma_command_address,
    output logic [25:0] dma_command_length,
    input  logic dma_armed,
    input  logic dma_done,
    input  logic dma_error,

    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic busy,
    output logic fault,
    output logic [31:0] accepted_slices,
    output logic [31:0] completed_tiles,
    output logic [63:0] emitted_bytes
);
  typedef enum logic [3:0] {
    ST_FILL,
    ST_COMMAND,
    ST_ARM,
    ST_READ_LO,
    ST_CAPTURE_LO,
    ST_READ_HI,
    ST_CAPTURE_HI,
    ST_STREAM,
    ST_DRAIN,
    ST_FAILED
  } state_t;

  state_t state_q;
  // Eight independent 64-bit banks allow all M rows in one result slice to
  // be written together while each bank maps cleanly to one URAM288.
  logic [63:0] tile_read_data [0:7];

  logic fault_q, tile_active_q, dma_done_seen_q;
  logic [3:0] tile_layer_q;
  logic [15:0] tile_n_base_q;
  logic [7:0] tile_n_count_q;
  logic [12:0] tile_m_total_q;
  logic [9:0] tile_words_per_n8_q;
  logic [12:0] expected_slice_count_q;
  logic [12:0] tile_slice_count_q;
  logic [31:0] tile_result_base_q;

  logic [12:0] drain_m_index_q;
  logic [4:0] drain_n8_q;
  logic [63:0] drain_lo_q, drain_hi_q;
  logic [15:0] drain_keep_q;
  logic drain_last_q;
  logic [31:0] command_address_q;
  logic [25:0] command_length_q;

  logic result_fire, command_fire, stream_fire;
  logic [12:0] current_m_total;
  logic [15:0] current_n_total;
  logic [7:0] current_n_tile;
  logic [15:0] current_tile_n_base;
  logic [7:0] current_tile_n_count;
  logic [9:0] current_words_per_n8;
  logic [4:0] current_n8_local;
  logic [9:0] current_m_word;
  (* use_dsp = "no" *) logic [12:0] current_write_address;
  logic [12:0] current_expected_slices;
  (* use_dsp = "no" *) logic [31:0] current_tile_byte_offset;
  (* use_dsp = "no" *) logic [32:0] current_command_address;
  logic descriptor_valid;
  logic tile_finished;

  (* use_dsp = "no" *) logic [12:0] drain_word_address;
  logic [2:0] drain_row_lane;
  logic drain_current_last;

  function automatic logic [12:0] n8_word_offset(
      input logic [3:0] layer_id,
      input logic [4:0] n8_index);
    logic [12:0] wide_index;
    begin
      wide_index = {8'd0, n8_index};
      case (layer_id)
        1: n8_word_offset = (wide_index << 8) +
            (wide_index << 7) - (wide_index << 2) - wide_index;
        2: n8_word_offset = (wide_index << 6) +
            (wide_index << 5) - (wide_index << 2);
        3, 4, 5: n8_word_offset = (wide_index << 4) +
            (wide_index << 2) + (wide_index << 1);
        default: n8_word_offset = wide_index;
      endcase
    end
  endfunction

  function automatic logic [31:0] scale_by_m_total(
      input logic [3:0] layer_id,
      input logic [15:0] value,
      input logic [3:0] batch_size);
    logic [31:0] wide_value;
    begin
      wide_value = {16'd0, value};
      case (layer_id)
        1: scale_by_m_total = (wide_value << 11) +
            (wide_value << 10) - (wide_value << 5) -
            (wide_value << 4) + wide_value;
        2: scale_by_m_total = (wide_value << 9) +
            (wide_value << 7) + (wide_value << 6) +
            (wide_value << 4) + (wide_value << 3) + wide_value;
        3, 4, 5: scale_by_m_total = (wide_value << 7) +
            (wide_value << 5) + (wide_value << 3) + wide_value;
        default: scale_by_m_total = batch_size == 8 ?
            (wide_value << 3) : wide_value;
      endcase
    end
  endfunction

  always_comb begin
    current_m_total = 0;
    current_n_total = 0;
    current_n_tile = 0;
    case (result_layer_id)
      1: begin current_m_total = 3025; current_n_total = 64;
               current_n_tile = 64; end
      2: begin current_m_total = 729; current_n_total = 192;
               current_n_tile = 64; end
      3: begin current_m_total = 169; current_n_total = 384;
               current_n_tile = 112; end
      4, 5: begin current_m_total = 169; current_n_total = 256;
                    current_n_tile = 112; end
      6, 7: begin current_m_total = fc_batch_size;
                    current_n_total = 4096;
                    current_n_tile = 16; end
      8: begin current_m_total = fc_batch_size; current_n_total = 1000;
               current_n_tile = 16; end
      default: begin end
    endcase

    if (result_layer_id <= 2)
      current_tile_n_base = {result_n_base[15:6], 6'b0};
    else if (result_layer_id <= 5) begin
      if (result_n_base < 112)
        current_tile_n_base = 0;
      else if (result_n_base < 224)
        current_tile_n_base = 112;
      else if (result_n_base < 336)
        current_tile_n_base = 224;
      else
        current_tile_n_base = 336;
    end else
      current_tile_n_base = {result_n_base[15:4], 4'b0};

    if (current_tile_n_base + current_n_tile > current_n_total)
      current_tile_n_count = current_n_total - current_tile_n_base;
    else
      current_tile_n_count = current_n_tile;
    current_words_per_n8 = (current_m_total + 7) >> 3;
    current_n8_local = (result_n_base - current_tile_n_base) >> 3;
    current_m_word = result_m_base >> 3;
    current_write_address = n8_word_offset(
        result_layer_id, current_n8_local) + current_m_word;
    current_expected_slices = (current_tile_n_count >> 3) *
                              current_words_per_n8;
    current_tile_byte_offset = scale_by_m_total(
        result_layer_id, current_tile_n_base, fc_batch_size);
    current_command_address = {1'b0, result_base} +
                              current_tile_byte_offset;

    descriptor_valid = result_layer_id >= 1 && result_layer_id <= 8 &&
        result_base[2:0] == 0 && result_n_base[2:0] == 0 &&
        result_n_base < current_n_total && result_m_count != 0 &&
        result_m_count <= 8 && result_m_base[2:0] == 0 &&
        result_m_base + result_m_count <= current_m_total &&
        current_write_address < MAX_WORDS && !current_command_address[32];
    tile_finished = result_last_slice &&
        result_m_base + result_m_count == current_m_total &&
        result_n_base + 8 == current_tile_n_base + current_tile_n_count;

  end

  assign result_ready = state_q == ST_FILL && !fault_q;
  assign result_fire = result_valid && result_ready;
  assign dma_command_valid = state_q == ST_COMMAND;
  assign dma_command_address = command_address_q;
  assign dma_command_length = command_length_q;
  assign command_fire = dma_command_valid && dma_command_ready;

  assign drain_word_address = n8_word_offset(tile_layer_q, drain_n8_q) +
                              (drain_m_index_q >> 3);
  assign drain_row_lane = drain_m_index_q[2:0];
  assign drain_current_last =
      drain_n8_q + 1'b1 == (tile_n_count_q >> 3) &&
      drain_m_index_q + 1'b1 == tile_m_total_q;

  assign m_axis_tvalid = state_q == ST_STREAM;
  assign m_axis_tdata = {drain_hi_q, drain_lo_q};
  assign m_axis_tkeep = drain_keep_q;
  assign m_axis_tlast = drain_last_q;
  assign stream_fire = m_axis_tvalid && m_axis_tready;
  assign busy = state_q != ST_FILL || tile_active_q;
  assign fault = fault_q || dma_error;

  generate
    for (genvar row = 0; row < 8; row++) begin : g_tile_memory
      alexnet_result_tile_uram64 #(
          .DEPTH(MAX_WORDS), .ADDR_W(13)
      ) u_memory (
          .clk,
          // Result descriptors are produced only by the in-core scheduler.
          // Keep the write-enable cone to the ready/valid handshake; folding
          // the full address-range checker into URAM BWE creates a long path
          // through every scheduler address calculation.
          .write_enable(result_fire),
          .write_address(current_write_address),
          .write_data(result_values[row]),
          .read_address(drain_word_address),
          .read_data(tile_read_data[row])
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_FILL;
      fault_q <= 1'b0;
      tile_active_q <= 1'b0;
      dma_done_seen_q <= 1'b0;
      tile_layer_q <= 0;
      tile_n_base_q <= 0;
      tile_n_count_q <= 0;
      tile_m_total_q <= 0;
      tile_words_per_n8_q <= 0;
      expected_slice_count_q <= 0;
      tile_slice_count_q <= 0;
      tile_result_base_q <= 0;
      drain_m_index_q <= 0;
      drain_n8_q <= 0;
      drain_lo_q <= 0;
      drain_hi_q <= 0;
      drain_keep_q <= 0;
      drain_last_q <= 1'b0;
      command_address_q <= 0;
      command_length_q <= 0;
      accepted_slices <= 0;
      completed_tiles <= 0;
      emitted_bytes <= 0;
    end else begin
      if (dma_done)
        dma_done_seen_q <= 1'b1;

      if (result_fire) begin
        accepted_slices <= accepted_slices + 1'b1;
        if (!tile_active_q) begin
          tile_active_q <= 1'b1;
          tile_layer_q <= result_layer_id;
          tile_n_base_q <= current_tile_n_base;
          tile_n_count_q <= current_tile_n_count;
          tile_m_total_q <= current_m_total;
          tile_words_per_n8_q <= current_words_per_n8;
          expected_slice_count_q <= current_expected_slices;
          tile_slice_count_q <= 1;
          tile_result_base_q <= result_base;
          // The command descriptor is invariant for the whole logical N
          // tile.  Capture it on the first slice instead of deriving it on
          // the final slice; this keeps the tile-retirement control path out
          // of the address and length register clock-enables.
          command_address_q <= current_command_address[31:0];
          command_length_q <= scale_by_m_total(
              result_layer_id, {8'd0, current_tile_n_count},
              fc_batch_size);
        end else begin
          tile_slice_count_q <= tile_slice_count_q + 1'b1;
        end

        if (tile_finished)
          state_q <= ST_COMMAND;

      end

      if (command_fire) begin
        dma_done_seen_q <= 1'b0;
        state_q <= ST_ARM;
      end

      if (state_q == ST_ARM && dma_armed) begin
        drain_m_index_q <= 0;
        drain_n8_q <= 0;
        drain_keep_q <= 0;
        drain_last_q <= 1'b0;
        state_q <= ST_READ_LO;
      end

      // Pack consecutive 64-bit result rows across 128-bit stream beats and N8
      // tile boundaries.  Partial TKEEP is therefore used only for the true
      // final eight-byte row, never in the middle of an AXI DMA transfer.
      if (state_q == ST_READ_LO) begin
        state_q <= ST_CAPTURE_LO;
      end

      if (state_q == ST_CAPTURE_LO) begin
        drain_lo_q <= tile_read_data[drain_row_lane];
        if (drain_current_last) begin
          drain_hi_q <= 0;
          drain_keep_q <= 16'h00ff;
          drain_last_q <= 1'b1;
          state_q <= ST_STREAM;
        end else begin
          if (drain_m_index_q + 1'b1 == tile_m_total_q) begin
            drain_m_index_q <= 0;
            drain_n8_q <= drain_n8_q + 1'b1;
          end else begin
            drain_m_index_q <= drain_m_index_q + 1'b1;
          end
          state_q <= ST_READ_HI;
        end
      end

      if (state_q == ST_READ_HI) begin
        state_q <= ST_CAPTURE_HI;
      end

      if (state_q == ST_CAPTURE_HI) begin
        drain_hi_q <= tile_read_data[drain_row_lane];
        drain_keep_q <= 16'hffff;
        drain_last_q <= drain_current_last;
        if (!drain_current_last) begin
          if (drain_m_index_q + 1'b1 == tile_m_total_q) begin
            drain_m_index_q <= 0;
            drain_n8_q <= drain_n8_q + 1'b1;
          end else begin
            drain_m_index_q <= drain_m_index_q + 1'b1;
          end
        end
        state_q <= ST_STREAM;
      end

      if (stream_fire) begin
        emitted_bytes <= emitted_bytes + $countones(m_axis_tkeep);
        if (drain_last_q)
          state_q <= ST_DRAIN;
        else
          state_q <= ST_READ_LO;
      end

      if (state_q == ST_DRAIN && (dma_done_seen_q || dma_done)) begin
        dma_done_seen_q <= 1'b0;
        tile_active_q <= 1'b0;
        tile_slice_count_q <= 0;
        completed_tiles <= completed_tiles + 1'b1;
        state_q <= ST_FILL;
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
      if (result_fire && !descriptor_valid)
        $fatal(1, "result coalescer received an invalid scheduler descriptor");
      if (result_fire && tile_active_q &&
          (tile_layer_q != result_layer_id ||
           tile_n_base_q != current_tile_n_base ||
           tile_result_base_q != result_base))
        $fatal(1, "result coalescer changed tiles before retirement");
      if (result_fire && tile_finished &&
          ((!tile_active_q && current_expected_slices != 1) ||
           (tile_active_q &&
            tile_slice_count_q + 1'b1 != expected_slice_count_q)))
        $fatal(1, "result coalescer tile slice-count mismatch");
      if (m_axis_tvalid && !m_axis_tready)
        assert ($stable({m_axis_tdata, m_axis_tkeep, m_axis_tlast}));
      if (stream_fire && m_axis_tkeep == 0)
        $fatal(1, "result coalescer emitted an empty beat");
    end
  end
`endif

endmodule
