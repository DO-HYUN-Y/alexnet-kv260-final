`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_channel_accumulator;
  logic clk = 0, rst = 1;
  logic input_valid, input_ready;
  logic [13:0] input_col_valid;
  logic signed [31:0] input_psum [0:13];
  logic [15:0] input_tag;
  logic [3:0] input_layer;
  logic input_psum_first, input_psum_final;
  logic [13:0] input_channel_base;
  logic [12:0] input_filter;
  logic [2:0] input_image;
  logic [5:0] input_x, input_y_base;
  logic output_valid, output_ready;
  logic [13:0] output_col_valid;
  logic signed [31:0] output_psum [0:13];
  logic [15:0] output_tag;
  logic [3:0] output_layer;
  logic [12:0] output_filter;
  logic [2:0] output_image;
  logic [5:0] output_x, output_y_base;
  logic idle;
  logic fault;
  logic [63:0] partial_inputs, uram_reads, uram_writes, final_outputs;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_channel_accumulator #(.MAX_SLOTS(32)) dut (.*);

  task automatic send_vector(
      input int value,
      input logic first,
      input logic final_pass,
      input logic [13:0] channel_base,
      input logic [12:0] filter,
      input logic [13:0] mask);
    begin
      @(negedge clk);
      input_psum_first = first;
      input_psum_final = final_pass;
      input_channel_base = channel_base;
      input_filter = filter;
      input_col_valid = mask;
      for (int lane = 0; lane < 14; lane++)
        input_psum[lane] = value;
      input_valid = 1;
      do @(posedge clk); while (!input_ready);
      @(negedge clk);
      input_valid = 0;
    end
  endtask

  task automatic receive_vector(
      input int expected,
      input logic [12:0] filter,
      input logic [13:0] mask);
    begin
      while (!output_valid) @(negedge clk);
      repeat (2) begin
        @(negedge clk);
        if (!output_valid || output_psum[0] != expected)
          $fatal(1, "output was not held under backpressure");
      end
      if (output_col_valid != mask || output_tag != 16'hacc0 ||
          output_layer != 2 || output_filter != filter ||
          output_image != 3 || output_x != 5 || output_y_base != 7)
        $fatal(1, "output metadata mismatch");
      for (int lane = 0; lane < 14; lane++)
        if (output_psum[lane] != expected)
          $fatal(1, "lane %0d expected %0d got %0d", lane, expected,
                 output_psum[lane]);
      output_ready = 1;
      @(negedge clk);
      output_ready = 0;
    end
  endtask

  initial begin
    input_valid = 0;
    input_col_valid = 0;
    input_tag = 16'hacc0;
    input_layer = 2;
    input_psum_first = 0;
    input_psum_final = 0;
    input_channel_base = 0;
    input_filter = 0;
    input_image = 3;
    input_x = 5;
    input_y_base = 7;
    output_ready = 0;
    for (int lane = 0; lane < 14; lane++) input_psum[lane] = 0;
    repeat (5) @(negedge clk);
    rst = 0;

    // Two ordered slots across first, middle, and final channel passes.
    send_vector(1, 1, 0, 0, 10, 14'h007f);
    send_vector(2, 1, 0, 0, 11, 14'h0003);
    send_vector(10, 0, 0, 4, 10, 14'h007f);
    send_vector(20, 0, 0, 4, 11, 14'h0003);
    send_vector(100, 0, 1, 8, 10, 14'h007f);
    receive_vector(111, 10, 14'h007f);
    send_vector(200, 0, 1, 8, 11, 14'h0003);
    receive_vector(222, 11, 14'h0003);

    // A one-pass tile bypasses URAM while preserving the result contract.
    send_vector(7, 1, 1, 0, 20, 14'h3fff);
    receive_vector(7, 20, 14'h3fff);

    if (fault || partial_inputs != 7 || uram_reads != 4 ||
        uram_writes != 4 || final_outputs != 3)
      $fatal(1, "accumulator counters/fault in=%0d rd=%0d wr=%0d out=%0d fault=%0b",
             partial_inputs, uram_reads, uram_writes, final_outputs, fault);
    $display("ALEXNET_EYERISS_RS_CHANNEL_ACCUMULATOR_TEST_PASSED inputs=7 reads=4 writes=4 outputs=3");
    $finish;
  end
endmodule
