`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_requant14;
  logic clk = 0;
  logic rst = 1;
  always #2.5 clk = ~clk;

  logic input_valid, input_ready;
  logic [13:0] input_col_valid;
  logic signed [31:0] input_psum [0:13];
  logic [15:0] input_tag;
  logic [3:0] input_layer;
  logic [12:0] input_filter;
  logic [2:0] input_image;
  logic [5:0] input_x, input_y_base;
  logic parameter_request_valid, parameter_request_ready;
  logic [13:0] parameter_request_index;
  logic parameter_response_valid, parameter_response_ready;
  logic [127:0] parameter_response_data;
  logic output_valid, output_ready;
  logic [13:0] output_col_valid;
  logic signed [7:0] output_values [0:13];
  logic [15:0] output_tag;
  logic [3:0] output_layer;
  logic [12:0] output_filter;
  logic [2:0] output_image;
  logic [5:0] output_x, output_y_base;
  logic idle, fault;
  logic [63:0] accepted_vectors, emitted_vectors;

  alexnet_eyeriss_rs_requant14 dut (.*);

  function automatic integer quantize(
      input integer accumulator, input integer bias,
      input integer multiplier, input integer shift, input bit relu);
    longint signed product;
    longint signed rounding;
    longint signed shifted;
    begin
      product = (accumulator + bias) * multiplier;
      rounding = 64'sd1 <<< (shift-1);
      if (product < 0)
        rounding = rounding - 1;
      shifted = (product + rounding) >>> shift;
      if (relu && shifted < 0)
        quantize = 0;
      else if (shifted > 127)
        quantize = 127;
      else if (shifted < -128)
        quantize = -128;
      else
        quantize = shifted;
    end
  endfunction

  task automatic send_vector(
      input int layer, input int filter, input int bias,
      input int multiplier, input int shift, input bit relu,
      input logic [13:0] mask);
    logic [127:0] record;
    int expected_index;
    begin
      @(negedge clk);
      input_layer = layer;
      input_filter = filter;
      input_col_valid = mask;
      input_valid = 1;
      while (!input_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      input_valid = 0;

      while (!parameter_request_valid) @(posedge clk);
      case (layer)
        1: expected_index = filter;
        8: expected_index = 9344 + filter;
        default: expected_index = -1;
      endcase
      if (parameter_request_index != expected_index)
        $fatal(1, "wrong parameter record index got=%0d expected=%0d",
               parameter_request_index, expected_index);
      @(negedge clk);
      parameter_request_ready = 1;
      @(posedge clk);
      @(negedge clk);
      parameter_request_ready = 0;

      record = 0;
      record[31:0] = bias;
      record[63:32] = multiplier;
      record[69:64] = shift;
      record[72] = relu;
      parameter_response_data = record;
      repeat (2) @(posedge clk);
      @(negedge clk);
      parameter_response_valid = 1;
      while (!parameter_response_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      parameter_response_valid = 0;

      while (!output_valid) @(posedge clk);
      output_ready = 0;
      repeat (3) @(posedge clk);
      if (!output_valid || output_col_valid != mask ||
          output_layer != layer || output_filter != filter ||
          output_tag != 16'h55aa || output_image != 3 ||
          output_x != 9 || output_y_base != 14)
        $fatal(1, "requant metadata/backpressure mismatch");
      for (int lane = 0; lane < 14; lane++) begin
        if (mask[lane] && $signed(output_values[lane]) !==
            quantize(input_psum[lane], bias, multiplier, shift, relu))
          $fatal(1, "requant mismatch lane=%0d got=%0d expected=%0d",
                 lane, $signed(output_values[lane]),
                 quantize(input_psum[lane], bias, multiplier, shift, relu));
        if (!mask[lane] && output_values[lane] != 0)
          $fatal(1, "masked requant lane is nonzero");
      end
      @(negedge clk);
      output_ready = 1;
      @(posedge clk);
      @(negedge clk);
      output_ready = 0;
    end
  endtask

  initial begin
    input_valid = 0;
    input_col_valid = 0;
    input_tag = 16'h55aa;
    input_layer = 0;
    input_filter = 0;
    input_image = 3;
    input_x = 9;
    input_y_base = 14;
    parameter_request_ready = 0;
    parameter_response_valid = 0;
    parameter_response_data = 0;
    output_ready = 0;
    for (int lane = 0; lane < 14; lane++)
      input_psum[lane] = (lane-7) * 128;
    repeat (4) @(posedge clk);
    rst = 0;

    send_vector(1, 12, 64, 65540, 23, 1, 14'h3fff);
    send_vector(8, 999, -64, 65540, 23, 0, 14'h003f);

    if (fault || accepted_vectors != 2 || emitted_vectors != 2 || !idle)
      $fatal(1, "requant status/counters mismatch");
    $display("ALEXNET_EYERISS_RS_REQUANT14_TEST_PASSED vectors=2 lanes=14 dsp=14");
    $finish;
  end
endmodule
