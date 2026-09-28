`timescale 1ns/1ps

module tb_alexnet_axis_byte_counters;
  logic clk = 1'b0;
  logic rst;
  logic [15:0] main_read_tkeep, weight_read_tkeep, ddr_write_tkeep;
  logic [7:0] camera_read_tkeep;
  logic main_read_tvalid, main_read_tready;
  logic weight_read_tvalid, weight_read_tready;
  logic camera_read_tvalid, camera_read_tready;
  logic ddr_write_tvalid, ddr_write_tready;
  logic [63:0] ddr_read_bytes, ddr_write_bytes;
  logic [63:0] main_read_bytes, weight_read_bytes, camera_read_bytes;

  alexnet_axis_byte_counters dut (.*);
  always #2.5 clk = ~clk;

  initial begin
    rst = 1'b1;
    main_read_tkeep = 0;
    weight_read_tkeep = 0;
    camera_read_tkeep = 0;
    ddr_write_tkeep = 0;
    main_read_tvalid = 0;
    main_read_tready = 0;
    weight_read_tvalid = 0;
    weight_read_tready = 0;
    camera_read_tvalid = 0;
    camera_read_tready = 0;
    ddr_write_tvalid = 0;
    ddr_write_tready = 0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // All four channels accept a partial/full beat in the same cycle.
    main_read_tkeep = 16'hffff;
    weight_read_tkeep = 16'h00ff;
    camera_read_tkeep = 8'h0f;
    ddr_write_tkeep = 16'h8001;
    main_read_tvalid = 1;
    main_read_tready = 1;
    weight_read_tvalid = 1;
    weight_read_tready = 1;
    camera_read_tvalid = 1;
    camera_read_tready = 1;
    ddr_write_tvalid = 1;
    ddr_write_tready = 1;
    @(posedge clk);
    @(negedge clk);
    if (ddr_read_bytes != 28 || ddr_write_bytes != 2 ||
        main_read_bytes != 16 || weight_read_bytes != 8 ||
        camera_read_bytes != 4)
      $fatal(1, "first byte-count sample mismatch");

    // Backpressured valid beats must not be counted.
    main_read_tready = 0;
    weight_read_tready = 0;
    camera_read_tready = 0;
    ddr_write_tready = 0;
    @(posedge clk);
    @(negedge clk);
    if (ddr_read_bytes != 28 || ddr_write_bytes != 2)
      $fatal(1, "backpressured beat was counted");

    // A second simultaneous set checks the maximum 40-byte read increment.
    main_read_tkeep = 16'hffff;
    weight_read_tkeep = 16'hffff;
    camera_read_tkeep = 8'hff;
    ddr_write_tkeep = 16'hffff;
    main_read_tready = 1;
    weight_read_tready = 1;
    camera_read_tready = 1;
    ddr_write_tready = 1;
    @(posedge clk);
    @(negedge clk);
    if (ddr_read_bytes != 68 || ddr_write_bytes != 18 ||
        main_read_bytes != 32 || weight_read_bytes != 24 ||
        camera_read_bytes != 12 ||
        ddr_read_bytes !=
            main_read_bytes + weight_read_bytes + camera_read_bytes)
      $fatal(1, "second byte-count sample mismatch");

    $display("ALEXNET_AXIS_BYTE_COUNTERS_TEST_PASSED read=%0d write=%0d",
             ddr_read_bytes, ddr_write_bytes);
    $finish;
  end
endmodule
