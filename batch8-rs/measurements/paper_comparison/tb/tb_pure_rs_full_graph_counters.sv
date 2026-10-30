`timescale 1ns/1ps

// Simulation-only performance monitor for the pure Eyeriss-RS full graph.
//
// This testbench deliberately does not change synthesizable RTL.  It observes
// the existing board-frontend handshakes and internal operation dispatch at
// the module boundary.  The line-memory model accepts a request immediately
// and returns one 128-bit line one cycle later; the result sink is always
// ready.  Reported traffic is accepted AXI-equivalent payload, not physical
// DRAM ACT/PRE traffic.
module tb_pure_rs_full_graph_counters;
  localparam longint unsigned CLOCK_HZ = 185_000_000;
  localparam int unsigned PE_COUNT = 504;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [63:0] input_base, activation_a_base, activation_b_base, weights_base;
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
  logic result_valid, result_ready;
  logic [13:0] result_col_valid;
  logic signed [31:0] result_psum [0:13];
  logic [15:0] result_tag;
  logic [3:0] result_layer;
  logic result_psum_first, result_psum_final;
  logic [13:0] result_channel_base;
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

  longint unsigned total_cycles [1:8];
  longint unsigned issue_cycles [1:8];
  longint unsigned weight_stall_cycles [1:8];
  longint unsigned activation_stall_cycles [1:8];
  longint unsigned result_stall_cycles [1:8];
  longint unsigned other_cycles [1:8];
  longint unsigned input_read_bytes [1:8];
  longint unsigned weight_read_bytes [1:8];
  longint unsigned result_interface_bytes [1:8];
  longint unsigned useful_macs [1:8];
  longint unsigned previous_mac_count;
  longint unsigned simulation_cycles;
  int unsigned active_layer;
  int unsigned stop_after_layer;
  bit job_active;
  bit profile_done;

  always #2.5 clk = ~clk;

  alexnet_eyeriss_rs_batch8_board_frontend_top dut (.*);

  function automatic int unsigned countones14(input logic [13:0] value);
    int unsigned count;
    count = 0;
    for (int bit_index = 0; bit_index < 14; bit_index++)
      count += value[bit_index];
    return count;
  endfunction

  function automatic real utilization_percent(
      input longint unsigned macs,
      input longint unsigned cycles);
    if (cycles == 0)
      return 0.0;
    return 100.0 * real'(macs) / real'(PE_COUNT * cycles);
  endfunction

  function automatic real ratio_percent(
      input longint unsigned numerator,
      input longint unsigned denominator);
    if (denominator == 0)
      return 0.0;
    return 100.0 * real'(numerator) / real'(denominator);
  endfunction

  task automatic print_layer(input int unsigned layer);
    longint unsigned memory_stalls;
    longint unsigned total_payload;
    real latency_us;
    memory_stalls = weight_stall_cycles[layer] +
                    activation_stall_cycles[layer] +
                    result_stall_cycles[layer];
    total_payload = input_read_bytes[layer] + weight_read_bytes[layer];
    latency_us = 1_000_000.0 * real'(total_cycles[layer]) /
                 real'(CLOCK_HZ);
    $display("RTL_COUNTER,pure_rs,%0d,8,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.6f,%0.6f,%0.6f",
             layer, CLOCK_HZ, useful_macs[layer], PE_COUNT,
             input_read_bytes[layer], weight_read_bytes[layer],
             result_interface_bytes[layer], total_payload,
             total_cycles[layer], issue_cycles[layer],
             weight_stall_cycles[layer], activation_stall_cycles[layer],
             result_stall_cycles[layer], memory_stalls,
             other_cycles[layer], utilization_percent(useful_macs[layer],
                                                        total_cycles[layer]),
             ratio_percent(memory_stalls, total_cycles[layer]), latency_us);
  endtask

  // Idealized one-cycle line-return model.  Requests cannot be re-ordered and
  // each cache has at most one outstanding miss, matching the RTL interface.
  always_ff @(posedge clk) begin
    if (rst) begin
      filter_line_response_valid <= 1'b0;
      ifmap_line_response_valid <= 1'b0;
    end else begin
      if (filter_line_response_valid && filter_line_response_ready)
        filter_line_response_valid <= 1'b0;
      if (filter_line_request_valid && filter_line_request_ready)
        filter_line_response_valid <= 1'b1;

      if (ifmap_line_response_valid && ifmap_line_response_ready)
        ifmap_line_response_valid <= 1'b0;
      if (ifmap_line_request_valid && ifmap_line_request_ready)
        ifmap_line_response_valid <= 1'b1;
    end
  end

  // All performance counters below are testbench-only.  Classification is
  // mutually exclusive: a useful array dispatch wins, followed by weight,
  // activation, and result waits; every remaining active cycle is "other".
  always @(posedge clk) begin
    bit op_issue;
    bit weight_wait;
    bit activation_wait;
    bit result_wait;
    if (!rst) begin
      simulation_cycles = simulation_cycles + 1;
      if (start_valid && start_ready) begin
        job_active = 1'b1;
        active_layer = 1;
        previous_mac_count = 0;
      end

      if (job_active) begin
        total_cycles[active_layer] = total_cycles[active_layer] + 1;

        if (filter_line_request_valid && filter_line_request_ready)
          weight_read_bytes[active_layer] =
              weight_read_bytes[active_layer] + 16;
        if (ifmap_line_request_valid && ifmap_line_request_ready)
          input_read_bytes[active_layer] = input_read_bytes[active_layer] + 16;
        if (result_valid && result_ready)
          result_interface_bytes[active_layer] =
              result_interface_bytes[active_layer] +
              4 * countones14(result_col_valid);

        op_issue = dut.u_core.op_buffer_valid_q &&
                   dut.u_core.op_buffer_dispatch_ready;
        weight_wait = dut.u_core.filter_request_valid &&
                      !dut.u_core.filter_data_valid;
        activation_wait = dut.u_core.ifmap_request_valid &&
                          !dut.u_core.ifmap_data_valid;
        result_wait = result_valid && !result_ready;

        if (op_issue)
          issue_cycles[active_layer] = issue_cycles[active_layer] + 1;
        else if (weight_wait)
          weight_stall_cycles[active_layer] =
              weight_stall_cycles[active_layer] + 1;
        else if (activation_wait)
          activation_stall_cycles[active_layer] =
              activation_stall_cycles[active_layer] + 1;
        else if (result_wait)
          result_stall_cycles[active_layer] =
              result_stall_cycles[active_layer] + 1;
        else
          other_cycles[active_layer] = other_cycles[active_layer] + 1;

        if (layer_complete_valid && layer_complete_ready) begin
          useful_macs[active_layer] = total_mac_count - previous_mac_count;
          previous_mac_count = total_mac_count;
          print_layer(active_layer);
          if ((stop_after_layer != 0) &&
              (active_layer >= stop_after_layer)) begin
            profile_done = 1'b1;
            job_active = 1'b0;
          end else if (active_layer < 8) begin
            active_layer = active_layer + 1;
          end
        end

        if (inference_done) begin
          profile_done = 1'b1;
          job_active = 1'b0;
          $display("RTL_COUNTER_DONE,pure_rs,%0d,%0d",
                   completed_passes, simulation_cycles);
        end
      end
    end
  end

  initial begin
    stop_after_layer = 0;
    void'($value$plusargs("STOP_AFTER_LAYER=%d", stop_after_layer));
    start_valid = 1'b0;
    start_tag = 16'h5253;
    input_base = 64'h0000_0000_1000_0000;
    activation_a_base = 64'h0000_0000_2000_0000;
    activation_b_base = 64'h0000_0000_3000_0000;
    weights_base = 64'h0000_0000_4000_0000;
    filter_line_request_ready = 1'b1;
    filter_line_response_valid = 1'b0;
    filter_line_response_data = {16{8'h01}};
    filter_line_response_error = 1'b0;
    ifmap_line_request_ready = 1'b1;
    ifmap_line_response_valid = 1'b0;
    ifmap_line_response_data = {16{8'h01}};
    ifmap_line_response_error = 1'b0;
    result_ready = 1'b1;
    layer_complete_ready = 1'b1;
    inference_done_ready = 1'b0;
    previous_mac_count = 0;
    simulation_cycles = 0;
    active_layer = 1;
    job_active = 1'b0;
    profile_done = 1'b0;
    for (int layer = 1; layer <= 8; layer++) begin
      total_cycles[layer] = 0;
      issue_cycles[layer] = 0;
      weight_stall_cycles[layer] = 0;
      activation_stall_cycles[layer] = 0;
      result_stall_cycles[layer] = 0;
      other_cycles[layer] = 0;
      input_read_bytes[layer] = 0;
      weight_read_bytes[layer] = 0;
      result_interface_bytes[layer] = 0;
      useful_macs[layer] = 0;
    end

    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    while (!profile_done && simulation_cycles < 500_000_000)
      @(negedge clk);
    if (!profile_done)
      $fatal(1, "pure RS full-graph counter simulation timed out");
    repeat (2) @(negedge clk);
    $finish;
  end

  initial begin
    #1;
    $display("RTL_COUNTER_HEADER,design,layer,batch_size,clock_hz,useful_macs,peak_macs_per_cycle,input_read_bytes,weight_read_bytes,result_interface_bytes,total_read_payload_bytes,total_cycles,issue_cycles,weight_stall_cycles,activation_stall_cycles,result_stall_cycles,memory_stall_cycles,other_cycles,pe_utilization_percent,stall_ratio_percent,latency_us");
    $display("RTL_COUNTER_CONDITION,line_return_latency_cycles=1,result_sink=always_ready,traffic_scope=accepted_128bit_line_payload,result_scope=core_interface_not_dram");
  end
endmodule
