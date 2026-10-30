`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_memory_frontend;
  logic clk = 0, rst = 1;
  logic [63:0] input_base, activation_a_base, activation_b_base, weights_base;
  logic filter_request_valid;
  logic [3:0] filter_request_layer;
  logic [12:0] filter_request_filter;
  logic [13:0] filter_request_channel;
  logic [3:0] filter_request_y, filter_request_x;
  logic filter_data_valid, filter_data_ready;
  logic [7:0] filter_data;
  logic filter_data_error;
  logic ifmap_request_valid;
  logic [3:0] ifmap_request_layer;
  logic [2:0] ifmap_request_image;
  logic [13:0] ifmap_request_channel;
  logic signed [8:0] ifmap_request_y, ifmap_request_x;
  logic ifmap_data_valid, ifmap_data_ready;
  logic [7:0] ifmap_data;
  logic ifmap_data_error;
  logic filter_line_request_valid, filter_line_request_ready;
  logic [63:0] filter_line_request_address;
  logic filter_line_response_valid, filter_line_response_ready;
  logic [127:0] filter_line_response_data;
  logic filter_line_response_error;
  logic ifmap_line_request_valid, ifmap_line_request_ready;
  logic [63:0] ifmap_line_request_address;
  logic ifmap_line_response_valid, ifmap_line_response_ready;
  logic [127:0] ifmap_line_response_data;
  logic ifmap_line_response_error;
  logic fault;
  logic [63:0] filter_byte_requests, filter_cache_hits;
  logic [63:0] filter_cache_misses, filter_dma_line_fetches;
  logic [63:0] ifmap_byte_requests, ifmap_cache_hits;
  logic [63:0] ifmap_cache_misses, ifmap_dma_line_fetches;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_memory_frontend dut (.*);

  initial begin
    input_base = 64'h2000_0000; activation_a_base = 64'h3000_0000;
    activation_b_base = 64'h4000_0000; weights_base = 64'h1000_0000;
    filter_request_valid = 0; filter_data_ready = 0;
    ifmap_request_valid = 0; ifmap_data_ready = 0;
    filter_line_request_ready = 0; filter_line_response_valid = 0;
    filter_line_response_data = 128'h0; filter_line_response_error = 0;
    ifmap_line_request_ready = 0; ifmap_line_response_valid = 0;
    ifmap_line_response_data = 128'h0; ifmap_line_response_error = 0;
    repeat (5) @(negedge clk); rst = 0;

    // Conv1 filter (N=2,C=1,ky=3,kx=4) is byte offset 840, select 8.
    @(negedge clk);
    filter_request_layer = 1; filter_request_filter = 2;
    filter_request_channel = 1; filter_request_y = 3; filter_request_x = 4;
    filter_request_valid = 1;
    do @(negedge clk); while (!filter_line_request_valid);
    if (filter_line_request_address != weights_base + 64'd832)
      $fatal(1, "filter frontend line=%h", filter_line_request_address);
    filter_line_request_ready = 1; @(negedge clk); filter_line_request_ready = 0;
    filter_line_response_data = 128'h0;
    filter_line_response_data[8*8 +: 8] = 8'ha5;
    filter_line_response_valid = 1;
    do @(posedge clk); while (!filter_line_response_ready);
    @(negedge clk); filter_line_response_valid = 0;
    while (!filter_data_valid) @(negedge clk);
    if (filter_data != 8'ha5 || filter_data_error)
      $fatal(1, "filter frontend data=%h error=%0b", filter_data, filter_data_error);
    filter_data_ready = 1;
    @(negedge clk); filter_request_valid = 0; filter_data_ready = 0;

    // Conv2 ifmap image 7, channel 63, y=x=26.
    @(negedge clk);
    ifmap_request_layer = 2; ifmap_request_image = 7;
    ifmap_request_channel = 63; ifmap_request_y = 26; ifmap_request_x = 26;
    ifmap_request_valid = 1;
    do @(negedge clk); while (!ifmap_line_request_valid);
    if (ifmap_line_request_address !=
        ((activation_a_base + 7*262144 + (7*729+728)*8+7) & ~64'hf))
      $fatal(1, "ifmap frontend line=%h", ifmap_line_request_address);
    ifmap_line_request_ready = 1; @(negedge clk); ifmap_line_request_ready = 0;
    ifmap_line_response_data = {16{8'h3c}};
    ifmap_line_response_valid = 1;
    do @(posedge clk); while (!ifmap_line_response_ready);
    @(negedge clk); ifmap_line_response_valid = 0;
    while (!ifmap_data_valid) @(negedge clk);
    if (ifmap_data != 8'h3c || ifmap_data_error)
      $fatal(1, "ifmap frontend data=%h error=%0b", ifmap_data, ifmap_data_error);
    ifmap_data_ready = 1;
    @(negedge clk); ifmap_request_valid = 0; ifmap_data_ready = 0;

    if (fault || filter_byte_requests != 1 || filter_cache_misses != 1 ||
        filter_dma_line_fetches != 1 || ifmap_byte_requests != 1 ||
        ifmap_cache_misses != 1 || ifmap_dma_line_fetches != 1)
      $fatal(1, "frontend counters/fault");
    $display("ALEXNET_EYERISS_RS_MEMORY_FRONTEND_TEST_PASSED filter_fetch=1 ifmap_fetch=1");
    $finish;
  end
endmodule
