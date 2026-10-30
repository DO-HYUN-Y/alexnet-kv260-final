`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_board_postprocess_top;
  logic clk = 0;
  logic rst = 1;
  always #2.5 clk = ~clk;

  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [63:0] input_base, activation_a_base, activation_b_base;
  logic [63:0] weights_base, parameters_base;
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
  logic result_valid, result_ready;
  logic [13:0] result_col_valid;
  logic signed [7:0] result_values [0:13];
  logic [15:0] result_tag;
  logic [3:0] result_layer;
  logic [12:0] result_filter;
  logic [2:0] result_image;
  logic [5:0] result_x, result_y_base;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic inference_done, inference_done_ready, fault;
  logic [15:0] completed_passes;
  logic [63:0] total_mac_count;
  logic [31:0] total_local_psum_hops;
  logic [63:0] filter_byte_requests, filter_cache_hits;
  logic [63:0] filter_cache_misses, filter_dma_line_fetches;
  logic [63:0] ifmap_byte_requests, ifmap_cache_hits;
  logic [63:0] ifmap_cache_misses, ifmap_dma_line_fetches;
  logic [63:0] partial_result_inputs, accumulator_uram_reads;
  logic [63:0] accumulator_uram_writes, final_result_outputs;
  logic [63:0] weight_dma_line_commands, weight_dma_line_errors;
  logic [63:0] main_dma_line_commands, main_dma_line_errors;
  logic [31:0] parameter_blob_loads;
  logic [63:0] parameter_lookups, requantized_vectors;

  alexnet_eyeriss_rs_batch8_board_postprocess_top dut (.*);

  initial begin
    start_valid = 0;
    start_tag = 16'hcafe;
    input_base = 64'h0100_0000;
    activation_a_base = 64'h0200_0000;
    activation_b_base = 64'h0300_0000;
    weights_base = 64'h0400_0000;
    parameters_base = 64'h0800_0000;
    weight_dma_command_ready = 0;
    weight_dma_armed = 0;
    weight_dma_done = 0;
    weight_dma_error = 0;
    weight_axis_tdata = 0;
    weight_axis_tkeep = 16'hffff;
    weight_axis_tvalid = 0;
    weight_axis_tlast = 0;
    main_dma_command_ready = 0;
    main_dma_armed = 0;
    main_dma_done = 0;
    main_dma_error = 0;
    main_axis_tdata = 0;
    main_axis_tkeep = 0;
    main_axis_tvalid = 0;
    main_axis_tlast = 0;
    result_ready = 1;
    layer_complete_ready = 1;
    inference_done_ready = 1;
    repeat (5) @(posedge clk);
    rst = 0;

    @(negedge clk);
    start_valid = 1;
    while (!start_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    start_valid = 0;

    while (!weight_dma_command_valid) @(posedge clk);
    if (weight_dma_command_address != parameters_base[31:0] ||
        weight_dma_command_length != 165504)
      $fatal(1, "parameter preload command mismatch addr=%h len=%0d",
             weight_dma_command_address, weight_dma_command_length);
    @(negedge clk);
    weight_dma_command_ready = 1;
    @(posedge clk);
    @(negedge clk);
    weight_dma_command_ready = 0;
    weight_dma_armed = 1;
    @(posedge clk);
    @(negedge clk);
    weight_dma_armed = 0;

    for (int record = 0; record < 10344; record++) begin
      @(negedge clk);
      weight_axis_tdata = record;
      weight_axis_tvalid = 1;
      weight_axis_tlast = record == 10343;
      while (!weight_axis_tready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      weight_axis_tvalid = 0;
      weight_axis_tlast = 0;
    end
    weight_dma_done = 1;
    @(posedge clk);
    @(negedge clk);
    weight_dma_done = 0;

    // The next command must be a filter-cache line miss, proving that the
    // parameter blob fully loaded before the compute core was released.
    while (!weight_dma_command_valid) begin
      @(posedge clk);
      if (fault)
        $fatal(1, "postprocess top faulted before first filter request");
    end
    if (weight_dma_command_length != 16 ||
        weight_dma_command_address < weights_base[31:0] ||
        parameter_blob_loads != 1)
      $fatal(1, "first compute weight command/counter mismatch");
    if (completed_passes != 0 || parameter_lookups != 0 ||
        requantized_vectors != 0)
      $fatal(1, "compute/postprocess counters advanced too early");

    $display("ALEXNET_EYERISS_RS_BOARD_POSTPROCESS_TOP_TEST_PASSED parameter_bytes=165504 first_filter_line=16 loads=1");
    $finish;
  end
endmodule
