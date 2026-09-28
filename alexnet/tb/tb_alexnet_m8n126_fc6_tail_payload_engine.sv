`timescale 1ns/1ps

// Focused native-batch-8 regression for the three FC6 K chunks.  Starting at
// the final N16 tile keeps the test short while exercising 4096/4096/1024
// weight release, patch replay and accumulator retention boundaries.
module tb_alexnet_m8n126_fc6_tail_payload_engine;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [3:0] start_layer_id, stop_layer_id, fc_batch_size;
  logic [15:0] start_n_base;
  logic start_single_n_tile, start_weight_fill_enable;
  logic start_weight_release_enable, start_pool_enable;

  logic weight_request_valid, weight_request_ready;
  logic [3:0] weight_request_layer_id;
  logic [15:0] weight_request_n_base;
  logic [13:0] weight_request_k_offset;
  logic [12:0] weight_request_k_count;
  logic [7:0] weight_request_bank_enable;
  logic [15:0] weight_request_n_lane_mask [0:7];
  logic [15:0] weight_request_context_tag;
  logic weight_axis_valid, weight_axis_ready;
  logic [127:0] weight_axis_data;
  logic weight_axis_last;

  logic patch_request_valid, patch_request_ready;
  logic [3:0] patch_request_layer_id;
  logic [12:0] patch_request_m_base;
  logic [13:0] patch_request_k_offset;
  logic [12:0] patch_request_k_count;
  logic [15:0] patch_request_m_lane_mask;
  logic [15:0] patch_request_context_tag;
  logic patch_axis_valid, patch_axis_ready;
  logic [127:0] patch_axis_data;
  logic patch_axis_last;

  logic parameter_request_valid, parameter_request_ready;
  logic [3:0] parameter_request_layer_id;
  logic [15:0] parameter_request_n_base;
  logic [15:0] parameter_request_context_tag;
  logic parameter_valid, parameter_ready;
  logic [15:0] parameter_n_base, parameter_context_tag;
  logic signed [31:0] parameter_bias [0:7];
  logic signed [17:0] parameter_multiplier [0:7];
  logic [5:0] parameter_right_shift [0:7];
  logic [7:0] parameter_relu;

  logic result_valid, result_ready;
  logic [63:0] result_values [0:7];
  logic [7:0] result_lane_mask [0:7];
  logic [3:0] result_m_count;
  logic [12:0] result_m_base;
  logic [15:0] result_n_base, result_tile_tag;
  logic result_last_slice;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic layer_complete_requires_pool;

  logic busy, inference_done, inference_failed, fault;
  logic [3:0] active_layer_id;
  logic [15:0] completed_commands;
  logic [31:0] active_cycles, issue_cycles;
  logic [31:0] patch_stall_cycles, weight_stall_cycles;
  logic [31:0] result_stall_cycles;
  logic [31:0] weight_words_loaded, patch_words_loaded;
  logic [31:0] completed_result_slices;
  logic [63:0] useful_mac_count, physical_mac_slot_count;

  int weight_requests, patch_requests, result_slices;

  alexnet_m8n126_graph_payload_engine #(
      .SERVICE_TIMEOUT_CYCLES(200000)
  ) dut (.*);

  always #2.5 clk = ~clk;

  always_comb begin
    weight_request_ready = 1'b1;
    patch_request_ready = 1'b1;
    parameter_request_ready = 1'b1;
    parameter_valid = 1'b1;
    parameter_n_base = parameter_request_n_base;
    parameter_context_tag = parameter_request_context_tag;
    parameter_relu = 8'h00;
    for (int lane = 0; lane < 8; lane++) begin
      parameter_bias[lane] = 0;
      parameter_multiplier[lane] = 18'sd65540;
      parameter_right_shift[lane] = 6'd23;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      result_slices <= 0;
    end else if (result_valid && result_ready) begin
      if (result_m_count != 8 || result_m_base != 0 ||
          result_n_base != 4080 + 8*result_slices ||
          result_lane_mask[0] != 8'hff)
        $fatal(1, "FC6 tail result descriptor mismatch m_count=%0d m_base=%0d n_base=%0d lane0=%0h",
               result_m_count, result_m_base, result_n_base,
               result_lane_mask[0]);
      result_slices <= result_slices + 1;
    end
  end

  initial begin : weight_service
    int count;
    int offset;
    forever begin
      @(posedge clk);
      if (!rst && weight_request_valid && weight_request_ready) begin
        count = weight_request_k_count;
        offset = weight_request_k_offset;
        if (weight_request_layer_id != 6 ||
            weight_request_n_base != 4080 ||
            weight_request_bank_enable != 8'h01 ||
            weight_request_n_lane_mask[0] != 16'hffff ||
            (weight_requests == 0 && (offset != 0 || count != 4096)) ||
            (weight_requests == 1 &&
             (offset != 4096 || count != 4096)) ||
            (weight_requests == 2 &&
             (offset != 8192 || count != 1024)))
          $fatal(1, "FC6 tail weight descriptor mismatch request=%0d offset=%0d count=%0d",
                 weight_requests, offset, count);
        weight_requests++;
        for (int beat = 0; beat < count; beat++) begin
          @(negedge clk);
          weight_axis_valid = 1'b1;
          weight_axis_data = {16{8'sd1}};
          weight_axis_last = beat == count-1;
          do @(posedge clk); while (!weight_axis_ready);
        end
        @(negedge clk);
        weight_axis_valid = 1'b0;
        weight_axis_last = 1'b0;
      end
    end
  end

  initial begin : patch_service
    int count;
    int offset;
    forever begin
      @(posedge clk);
      if (!rst && patch_request_valid && patch_request_ready) begin
        count = patch_request_k_count;
        offset = patch_request_k_offset;
        if (patch_request_layer_id != 6 || patch_request_m_base != 0 ||
            patch_request_m_lane_mask != 16'h00ff ||
            (patch_requests == 0 && (offset != 0 || count != 4096)) ||
            (patch_requests == 1 &&
             (offset != 4096 || count != 4096)) ||
            (patch_requests == 2 &&
             (offset != 8192 || count != 1024)))
          $fatal(1, "FC6 tail patch descriptor mismatch request=%0d offset=%0d count=%0d",
                 patch_requests, offset, count);
        patch_requests++;
        for (int beat = 0; beat < count; beat++) begin
          @(negedge clk);
          patch_axis_valid = 1'b1;
          patch_axis_data = {16{8'sd1}};
          patch_axis_last = beat == count-1;
          do @(posedge clk); while (!patch_axis_ready);
        end
        @(negedge clk);
        patch_axis_valid = 1'b0;
        patch_axis_last = 1'b0;
      end
    end
  end

  initial begin : test
    rst = 1'b1;
    start_valid = 1'b0;
    start_tag = 16'h6b80;
    start_layer_id = 6;
    stop_layer_id = 6;
    fc_batch_size = 8;
    start_n_base = 4080;
    start_single_n_tile = 1'b0;
    start_weight_fill_enable = 1'b1;
    start_weight_release_enable = 1'b1;
    start_pool_enable = 1'b0;
    weight_axis_valid = 1'b0;
    weight_axis_data = '0;
    weight_axis_last = 1'b0;
    patch_axis_valid = 1'b0;
    patch_axis_data = '0;
    patch_axis_last = 1'b0;
    result_ready = 1'b1;
    layer_complete_ready = 1'b1;
    weight_requests = 0;
    patch_requests = 0;
    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    for (int timeout = 0; timeout < 100000; timeout++) begin
      @(negedge clk);
      if (fault || inference_failed)
        $fatal(1, "FC6 tail payload engine faulted commands=%0d", completed_commands);
      if (inference_done) begin
        if (completed_commands != 3 || weight_requests != 3 ||
            patch_requests != 3 || issue_cycles != 9216 ||
            weight_words_loaded != 9216 || patch_words_loaded != 9216 ||
            result_slices != 2)
          $fatal(1, "FC6 tail accounting mismatch commands=%0d weight_req=%0d patch_req=%0d issue=%0d weight_words=%0d patch_words=%0d slices=%0d",
                 completed_commands, weight_requests, patch_requests,
                 issue_cycles, weight_words_loaded, patch_words_loaded,
                 result_slices);
        $display("ALEXNET_M8N126_FC6_TAIL_PAYLOAD_ENGINE_PASS commands=3 issue=9216 slices=2");
        $finish;
      end
    end
    $fatal(1, "FC6 tail payload engine timeout commands=%0d", completed_commands);
  end
endmodule
