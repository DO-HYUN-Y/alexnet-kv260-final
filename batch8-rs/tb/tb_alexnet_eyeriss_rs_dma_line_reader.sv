`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_dma_line_reader;
  logic clk = 0, rst = 1;
  logic line_request_valid, line_request_ready;
  logic [63:0] line_request_address;
  logic line_response_valid, line_response_ready;
  logic [127:0] line_response_data;
  logic line_response_error;
  logic dma_command_valid, dma_command_ready;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic fault;
  logic [63:0] accepted_requests, issued_commands, accepted_beats;
  logic [63:0] error_responses;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_dma_line_reader dut (.*);

  task automatic request_line(input logic [63:0] address);
    begin
      @(negedge clk);
      line_request_address = address;
      line_request_valid = 1;
      do @(posedge clk); while (!line_request_ready);
      @(negedge clk);
      line_request_valid = 0;
    end
  endtask

  task automatic accept_command(input logic [31:0] expected_address);
    begin
      while (!dma_command_valid) @(negedge clk);
      if (dma_command_address != expected_address || dma_command_length != 16)
        $fatal(1, "DMA command mismatch address=%h length=%0d",
               dma_command_address, dma_command_length);
      repeat (2) @(negedge clk);
      dma_command_ready = 1;
      @(negedge clk);
      dma_command_ready = 0;
    end
  endtask

  task automatic send_beat(
      input logic [127:0] data,
      input logic [15:0] keep,
      input logic last);
    begin
      @(negedge clk);
      s_axis_tdata = data;
      s_axis_tkeep = keep;
      s_axis_tlast = last;
      s_axis_tvalid = 1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk);
      s_axis_tvalid = 0;
    end
  endtask

  task automatic accept_response(
      input logic [127:0] expected_data,
      input logic expected_error);
    begin
      while (!line_response_valid) @(negedge clk);
      repeat (2) begin
        @(negedge clk);
        if (!line_response_valid || line_response_data != expected_data ||
            line_response_error != expected_error)
          $fatal(1, "response changed under backpressure");
      end
      line_response_ready = 1;
      @(negedge clk);
      line_response_ready = 0;
    end
  endtask

  initial begin
    line_request_valid = 0;
    line_request_address = 0;
    line_response_ready = 0;
    dma_command_ready = 0;
    dma_armed = 0;
    dma_done = 0;
    dma_error = 0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 0;
    s_axis_tlast = 0;
    repeat (5) @(negedge clk);
    rst = 0;

    // Stream beat first, DMA done later.
    request_line(64'h0000_0000_1234_5600);
    accept_command(32'h1234_5600);
    @(negedge clk); dma_armed = 1;
    @(negedge clk); dma_armed = 0;
    send_beat(128'h00112233445566778899aabbccddeeff, 16'hffff, 1);
    @(negedge clk); dma_done = 1;
    @(negedge clk); dma_done = 0;
    accept_response(128'h00112233445566778899aabbccddeeff, 0);

    // DMA done first, stream beat later.
    request_line(64'h0000_0000_2000_0010);
    accept_command(32'h2000_0010);
    @(negedge clk); dma_armed = 1; dma_done = 1;
    @(negedge clk); dma_armed = 0; dma_done = 0;
    send_beat(128'hffeeddccbbaa99887766554433221100, 16'hffff, 1);
    accept_response(128'hffeeddccbbaa99887766554433221100, 0);

    // Malformed keep returns an error and latches fault.
    request_line(64'h0000_0000_3000_0020);
    accept_command(32'h3000_0020);
    @(negedge clk); dma_armed = 1;
    @(negedge clk); dma_armed = 0;
    send_beat(128'h55, 16'h00ff, 1);
    @(negedge clk); dma_done = 1;
    @(negedge clk); dma_done = 0;
    accept_response(128'h55, 1);

    if (!fault || accepted_requests != 3 || issued_commands != 3 ||
        accepted_beats != 3 || error_responses != 1)
      $fatal(1, "reader counters/fault req=%0d cmd=%0d beat=%0d err=%0d fault=%0b",
             accepted_requests, issued_commands, accepted_beats,
             error_responses, fault);
    $display("ALEXNET_EYERISS_RS_DMA_LINE_READER_TEST_PASSED requests=3 commands=3 beats=3 errors=1");
    $finish;
  end
endmodule
