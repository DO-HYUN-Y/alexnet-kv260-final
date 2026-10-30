`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_dma_line_cache;
  logic clk = 0;
  logic rst = 1;
  logic byte_request_valid, byte_request_ready;
  logic [63:0] byte_request_address;
  logic byte_response_valid, byte_response_ready;
  logic [7:0] byte_response_data;
  logic byte_response_error;
  logic line_request_valid, line_request_ready;
  logic [63:0] line_request_address;
  logic line_response_valid, line_response_ready;
  logic [127:0] line_response_data;
  logic line_response_error;
  logic [63:0] byte_requests, cache_hits, cache_misses, dma_line_fetches;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_dma_line_cache dut (.*);

  initial begin
    #10000;
    $fatal(1, "line cache timeout state=%0d req_v/r=%0b/%0b line_v/r=%0b/%0b resp_v/r=%0b/%0b",
           dut.state_q, byte_request_valid, byte_request_ready,
           line_request_valid, line_request_ready,
           byte_response_valid, byte_response_ready);
  end

  task automatic send_byte_request(input logic [63:0] address);
    begin
      @(negedge clk);
      byte_request_address = address;
      byte_request_valid = 1;
      do @(posedge clk); while (!byte_request_ready);
      @(negedge clk);
      byte_request_valid = 0;
    end
  endtask

  task automatic send_line_response(
    input logic [127:0] data,
    input logic error
  );
    begin
      @(negedge clk);
      line_response_data = data;
      line_response_error = error;
      line_response_valid = 1;
      do @(posedge clk); while (!line_response_ready);
      @(negedge clk);
      line_response_valid = 0;
    end
  endtask

  task automatic accept_line_request(input logic [63:0] expected);
    begin
      do @(negedge clk); while (!line_request_valid);
      if (line_request_address != expected)
        $fatal(1, "line request got=%h expected=%h",
               line_request_address, expected);
      line_request_ready = 1;
      @(negedge clk);
      line_request_ready = 0;
    end
  endtask

  task automatic consume_byte(input logic [7:0] expected, input logic error);
    begin
      // Block retirement before observing the response; otherwise a
      // zero-latency test consumer can accept the one-cycle response before
      // this task samples it.
      byte_response_ready = 0;
      while (!byte_response_valid) @(negedge clk);
      if (byte_response_data != expected || byte_response_error != error)
        $fatal(1, "byte response data=%h/%h error=%0b/%0b",
               byte_response_data, expected, byte_response_error, error);
      repeat (2) begin
        @(negedge clk);
        if (!byte_response_valid || byte_response_data != expected)
          $fatal(1, "response did not remain stable under backpressure");
      end
      byte_response_ready = 1;
      @(negedge clk);
    end
  endtask

  initial begin
    logic [127:0] first_line;
    first_line = '0;
    for (int byte_index = 0; byte_index < 16; byte_index++)
      first_line[byte_index*8 +: 8] = byte_index;
    byte_request_valid = 0;
    byte_request_address = 0;
    byte_response_ready = 1;
    line_request_ready = 0;
    line_response_valid = 0;
    line_response_data = 0;
    line_response_error = 0;
    repeat (5) @(negedge clk);
    rst = 0;

    send_byte_request(64'h103);
    accept_line_request(64'h100);
    send_line_response(first_line, 0);
    consume_byte(8'h03, 0);

    send_byte_request(64'h10e);
    consume_byte(8'h0e, 0);
    if (line_request_valid)
      $fatal(1, "cache hit issued a DMA request");

    send_byte_request(64'h215);
    accept_line_request(64'h210);
    send_line_response(128'h0, 1);
    consume_byte(8'h00, 1);

    send_byte_request(64'h215);
    accept_line_request(64'h210);
    send_line_response(128'h0000_0000_0000_0000_8877_6655_4433_2211, 0);
    consume_byte(8'h66, 0);

    if (byte_requests != 4 || cache_hits != 1 || cache_misses != 3 ||
        dma_line_fetches != 3)
      $fatal(1, "cache counters req=%0d hit=%0d miss=%0d fetch=%0d",
             byte_requests, cache_hits, cache_misses, dma_line_fetches);
    $display("ALEXNET_EYERISS_RS_DMA_LINE_CACHE_TEST_PASSED requests=4 hits=1 misses=3 fetches=3");
    $finish;
  end
endmodule
