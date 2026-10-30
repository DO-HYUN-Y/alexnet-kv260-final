`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_dual_dma_line_adapter;
  logic clk = 0, rst = 1;
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
  logic weight_dma_command_valid, weight_dma_command_ready;
  logic [31:0] weight_dma_command_address;
  logic [25:0] weight_dma_command_length;
  logic weight_dma_armed, weight_dma_done, weight_dma_error;
  logic [127:0] weight_axis_tdata;
  logic [15:0] weight_axis_tkeep;
  logic weight_axis_tvalid, weight_axis_tready, weight_axis_tlast;
  logic main_dma_command_valid, main_dma_command_ready;
  logic [31:0] main_dma_command_address;
  logic [25:0] main_dma_command_length;
  logic main_dma_armed, main_dma_done, main_dma_error;
  logic [127:0] main_axis_tdata;
  logic [15:0] main_axis_tkeep;
  logic main_axis_tvalid, main_axis_tready, main_axis_tlast;
  logic fault;
  logic [63:0] weight_dma_line_commands, weight_dma_line_errors;
  logic [63:0] main_dma_line_commands, main_dma_line_errors;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_dual_dma_line_adapter dut (.*);

  initial begin
    filter_line_request_valid = 0;
    filter_line_request_address = 64'h1000_0000;
    filter_line_response_ready = 0;
    ifmap_line_request_valid = 0;
    ifmap_line_request_address = 64'h2000_0000;
    ifmap_line_response_ready = 0;
    weight_dma_command_ready = 0;
    weight_dma_armed = 0; weight_dma_done = 0; weight_dma_error = 0;
    weight_axis_tdata = {16{8'ha5}}; weight_axis_tkeep = 16'hffff;
    weight_axis_tvalid = 0; weight_axis_tlast = 1;
    main_dma_command_ready = 0;
    main_dma_armed = 0; main_dma_done = 0; main_dma_error = 0;
    main_axis_tdata = {16{8'h3c}}; main_axis_tkeep = 16'hffff;
    main_axis_tvalid = 0; main_axis_tlast = 1;
    repeat (5) @(negedge clk); rst = 0;

    // Accept both independent line requests together.
    @(negedge clk);
    filter_line_request_valid = 1;
    ifmap_line_request_valid = 1;
    do @(posedge clk); while (!(filter_line_request_ready &&
                               ifmap_line_request_ready));
    @(negedge clk);
    filter_line_request_valid = 0;
    ifmap_line_request_valid = 0;

    while (!(weight_dma_command_valid && main_dma_command_valid))
      @(negedge clk);
    if (weight_dma_command_address != 32'h1000_0000 ||
        main_dma_command_address != 32'h2000_0000 ||
        weight_dma_command_length != 16 || main_dma_command_length != 16)
      $fatal(1, "dual adapter command mismatch");
    weight_dma_command_ready = 1;
    main_dma_command_ready = 1;
    @(negedge clk);
    weight_dma_command_ready = 0;
    main_dma_command_ready = 0;

    weight_dma_armed = 1;
    main_dma_armed = 1;
    @(negedge clk);
    weight_dma_armed = 0;
    main_dma_armed = 0;
    weight_axis_tvalid = 1;
    main_axis_tvalid = 1;
    do @(posedge clk); while (!(weight_axis_tready && main_axis_tready));
    @(negedge clk);
    weight_axis_tvalid = 0;
    main_axis_tvalid = 0;
    weight_dma_done = 1;
    main_dma_done = 1;
    @(negedge clk);
    weight_dma_done = 0;
    main_dma_done = 0;

    while (!(filter_line_response_valid && ifmap_line_response_valid))
      @(negedge clk);
    if (filter_line_response_error || ifmap_line_response_error ||
        filter_line_response_data != {16{8'ha5}} ||
        ifmap_line_response_data != {16{8'h3c}})
      $fatal(1, "dual adapter response mismatch");
    filter_line_response_ready = 1;
    ifmap_line_response_ready = 1;
    @(negedge clk);

    if (fault || weight_dma_line_commands != 1 ||
        main_dma_line_commands != 1 || weight_dma_line_errors != 0 ||
        main_dma_line_errors != 0)
      $fatal(1, "dual adapter counters/fault");
    $display("ALEXNET_EYERISS_RS_DUAL_DMA_LINE_ADAPTER_TEST_PASSED weight=1 main=1");
    $finish;
  end
endmodule
