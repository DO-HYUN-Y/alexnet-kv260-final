`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_parameter_cache;
  localparam int RECORD_COUNT = 16;
  logic clk = 0;
  logic rst = 1;
  always #2.5 clk = ~clk;

  logic load_start_valid, load_start_ready;
  logic [127:0] load_axis_tdata;
  logic [15:0] load_axis_tkeep;
  logic load_axis_tvalid, load_axis_tready, load_axis_tlast;
  logic load_active, load_done, cache_valid;
  logic request_valid, request_ready;
  logic [$clog2(RECORD_COUNT)-1:0] request_index;
  logic response_valid, response_ready;
  logic [127:0] response_data;
  logic fault;
  logic [31:0] completed_loads;
  logic [63:0] completed_lookups;

  alexnet_eyeriss_rs_parameter_cache #(.RECORD_COUNT(RECORD_COUNT)) dut (
    .clk, .rst, .load_start_valid, .load_start_ready,
    .load_axis_tdata, .load_axis_tkeep, .load_axis_tvalid,
    .load_axis_tready, .load_axis_tlast, .load_active, .load_done,
    .cache_valid, .request_valid, .request_ready, .request_index,
    .response_valid, .response_ready, .response_data, .fault,
    .completed_loads, .completed_lookups
  );

  function automatic logic [127:0] record_value(input int index);
    record_value = {64'h5a5a_0000_0000_0000 + index,
                    64'ha5a5_0000_0000_0000 + index};
  endfunction

  task automatic lookup(input int index, input int stall_cycles);
    begin
      @(negedge clk);
      request_index = index;
      request_valid = 1;
      while (!request_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      request_valid = 0;
      while (!response_valid) @(posedge clk);
      response_ready = 0;
      repeat (stall_cycles) begin
        @(posedge clk);
        if (!response_valid || response_data !== record_value(index))
          $fatal(1, "parameter response changed under backpressure");
      end
      if (response_data !== record_value(index))
        $fatal(1, "lookup %0d mismatch got=%h expected=%h", index,
               response_data, record_value(index));
      @(negedge clk);
      response_ready = 1;
      @(posedge clk);
      @(negedge clk);
      response_ready = 0;
    end
  endtask

  initial begin
    load_start_valid = 0;
    load_axis_tdata = 0;
    load_axis_tkeep = 16'hffff;
    load_axis_tvalid = 0;
    load_axis_tlast = 0;
    request_valid = 0;
    request_index = 0;
    response_ready = 0;
    repeat (4) @(posedge clk);
    rst = 0;

    @(negedge clk);
    load_start_valid = 1;
    while (!load_start_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    load_start_valid = 0;
    for (int record = 0; record < RECORD_COUNT; record++) begin
      @(negedge clk);
      load_axis_tdata = record_value(record);
      load_axis_tlast = record == RECORD_COUNT-1;
      load_axis_tvalid = 1;
      while (!load_axis_tready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      load_axis_tvalid = 0;
    end
    @(posedge clk);
    if (!cache_valid || fault || completed_loads != 1)
      $fatal(1, "parameter cache did not complete a clean load");

    lookup(0, 0);
    lookup(7, 3);
    lookup(15, 1);
    if (fault || completed_lookups != 3)
      $fatal(1, "lookup counters/fault mismatch");

    $display("ALEXNET_EYERISS_RS_PARAMETER_CACHE_TEST_PASSED records=16 lookups=3 uram_geometry=2x1");
    $finish;
  end
endmodule
