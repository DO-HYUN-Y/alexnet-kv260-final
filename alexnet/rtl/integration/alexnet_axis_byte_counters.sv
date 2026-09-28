`timescale 1ns/1ps

// Free-running payload-byte counters for the four DDR-facing AXI streams.
// A byte is counted only on a completed TVALID/TREADY handshake and only when
// its TKEEP bit is asserted.  The totals reset with PL reset and wrap modulo
// 2^64; software obtains per-job values from before/after snapshots.
module alexnet_axis_byte_counters (
    input  logic clk,
    input  logic rst,

    input  logic [15:0] main_read_tkeep,
    input  logic main_read_tvalid,
    input  logic main_read_tready,
    input  logic [15:0] weight_read_tkeep,
    input  logic weight_read_tvalid,
    input  logic weight_read_tready,
    input  logic [7:0] camera_read_tkeep,
    input  logic camera_read_tvalid,
    input  logic camera_read_tready,
    input  logic [15:0] ddr_write_tkeep,
    input  logic ddr_write_tvalid,
    input  logic ddr_write_tready,

    output logic [63:0] ddr_read_bytes,
    output logic [63:0] ddr_write_bytes,
    output logic [63:0] main_read_bytes,
    output logic [63:0] weight_read_bytes,
    output logic [63:0] camera_read_bytes
);
  logic [5:0] read_byte_increment;

  function automatic logic [3:0] popcount8(input logic [7:0] value);
    logic [3:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 8; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  function automatic logic [4:0] popcount16(input logic [15:0] value);
    logic [4:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 16; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  assign read_byte_increment =
      (main_read_tvalid && main_read_tready ?
           {1'b0, popcount16(main_read_tkeep)} : 6'd0) +
      (weight_read_tvalid && weight_read_tready ?
           {1'b0, popcount16(weight_read_tkeep)} : 6'd0) +
      (camera_read_tvalid && camera_read_tready ?
           {2'b00, popcount8(camera_read_tkeep)} : 6'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      ddr_read_bytes <= 64'd0;
      ddr_write_bytes <= 64'd0;
      main_read_bytes <= 64'd0;
      weight_read_bytes <= 64'd0;
      camera_read_bytes <= 64'd0;
    end else begin
      ddr_read_bytes <= ddr_read_bytes + read_byte_increment;
      if (main_read_tvalid && main_read_tready)
        main_read_bytes <= main_read_bytes + popcount16(main_read_tkeep);
      if (weight_read_tvalid && weight_read_tready)
        weight_read_bytes <= weight_read_bytes +
                             popcount16(weight_read_tkeep);
      if (camera_read_tvalid && camera_read_tready)
        camera_read_bytes <= camera_read_bytes + popcount8(camera_read_tkeep);
      if (ddr_write_tvalid && ddr_write_tready)
        ddr_write_bytes <= ddr_write_bytes + popcount16(ddr_write_tkeep);
    end
  end
endmodule
