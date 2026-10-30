`timescale 1ns/1ps

// Vertical nearest-neighbor partial-sum network.  One token per PE column
// starts at the bottom active row and moves upward one row per cycle, adding
// the resident PE result at every hop.  This is the local network in Fig. 4c,
// not a centralized output accumulator.
module alexnet_eyeriss_rs_local_psum_network #(
  parameter int TAG_W = 16
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic [3:0]           cfg_rows,
  input  logic [3:0]           cfg_cols,
  input  logic [3:0]           cfg_start_row,
  input  logic [3:0]           cfg_start_col,

  input  logic                 launch_valid,
  output logic                 launch_ready,
  input  logic [TAG_W-1:0]     launch_tag,
  input  logic [167:0]         row_valid,
  input  logic signed [31:0]   row_psum [0:167],

  output logic                 output_valid,
  input  logic                 output_ready,
  output logic [13:0]          output_col_valid,
  output logic signed [31:0]   output_psum [0:13],
  output logic [TAG_W-1:0]     output_tag,

  output logic                 busy,
  output logic                 fault,
  output logic [31:0]          hop_count
);

  logic signed [31:0] token [0:13];
  logic [3:0] next_row_q;
  logic [3:0] start_row_q;
  logic [3:0] start_col_q;
  logic [3:0] cols_q;
  logic [TAG_W-1:0] tag_q;
  logic input_complete;

  integer row;
  integer col;
  always_comb begin
    input_complete = 1'b1;
    launch_ready = 1'b0;
    for (row = 0; row < 12; row = row + 1)
      for (col = 0; col < 14; col = col + 1)
        if ((row >= cfg_start_row) &&
            (row < (cfg_start_row + cfg_rows)) &&
            (col >= cfg_start_col) &&
            (col < (cfg_start_col + cfg_cols)))
          input_complete = input_complete && row_valid[row * 14 + col];
    if ((cfg_rows >= 1) && (cfg_rows <= 12) &&
        (cfg_cols >= 1) && (cfg_cols <= 14) &&
        ((cfg_start_row + cfg_rows) <= 12) &&
        ((cfg_start_col + cfg_cols) <= 14))
      launch_ready = !busy && !output_valid && input_complete;
  end

  integer idx;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (idx = 0; idx < 14; idx = idx + 1) begin
        token[idx] <= '0;
        output_psum[idx] <= '0;
      end
      output_col_valid <= '0;
      next_row_q     <= '0;
      start_row_q    <= '0;
      start_col_q    <= '0;
      cols_q         <= '0;
      tag_q          <= '0;
      output_tag     <= '0;
      output_valid   <= 1'b0;
      busy           <= 1'b0;
      fault          <= 1'b0;
      hop_count      <= '0;
    end else begin
      if (output_valid && output_ready) begin
        output_valid <= 1'b0;
        output_col_valid <= '0;
      end

      if (launch_valid && launch_ready) begin
        for (idx = 0; idx < 14; idx = idx + 1) begin
          if ((idx >= cfg_start_col) &&
              (idx < (cfg_start_col + cfg_cols))) begin
            token[idx] <= row_psum[(cfg_start_row + cfg_rows - 1'b1) * 14 +
                                   idx];
          end else begin
            token[idx] <= '0;
          end
        end
        cols_q <= cfg_cols;
        start_row_q <= cfg_start_row;
        start_col_q <= cfg_start_col;
        tag_q <= launch_tag;
        if (cfg_rows == 1) begin
          for (idx = 0; idx < 14; idx = idx + 1) begin
            if ((idx >= cfg_start_col) &&
                (idx < (cfg_start_col + cfg_cols)))
              output_psum[idx] <= row_psum[cfg_start_row * 14 + idx];
            else
              output_psum[idx] <= '0;
          end
          output_col_valid <= (14'h3fff >> (14 - cfg_cols)) <<
                              cfg_start_col;
          output_tag <= launch_tag;
          output_valid <= 1'b1;
          busy <= 1'b0;
        end else begin
          next_row_q <= cfg_start_row + cfg_rows - 2'd2;
          busy <= 1'b1;
        end
      end else if (busy) begin
        for (idx = 0; idx < 14; idx = idx + 1)
          if ((idx >= start_col_q) &&
              (idx < (start_col_q + cols_q)))
            token[idx] <= token[idx] +
                          row_psum[next_row_q * 14 + idx];
        hop_count <= hop_count + cols_q;
        if (next_row_q == start_row_q) begin
          for (idx = 0; idx < 14; idx = idx + 1)
            if ((idx >= start_col_q) &&
                (idx < (start_col_q + cols_q)))
              output_psum[idx] <= token[idx] +
                                  row_psum[next_row_q * 14 + idx];
            else
              output_psum[idx] <= '0;
          output_col_valid <= (14'h3fff >> (14 - cols_q)) << start_col_q;
          output_tag <= tag_q;
          output_valid <= 1'b1;
          busy <= 1'b0;
        end else begin
          next_row_q <= next_row_q - 1'b1;
        end
      end
    end
  end

endmodule
