`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_pass_scheduler;
  logic clk = 0;
  logic rst = 1;
  logic start_valid;
  logic start_ready;
  logic [15:0] start_tag;
  logic pass_valid;
  logic pass_ready;
  logic [15:0] pass_tag;
  logic [3:0] pass_layer_id;
  logic [5:0] pass_strip_y;
  logic [5:0] pass_strip_rows;
  logic [13:0] pass_channel_base;
  logic [7:0] pass_channel_count;
  logic [12:0] pass_filter_base;
  logic [9:0] pass_filter_count;
  logic [5:0] pass_output_width;
  logic [3:0] pass_filter_r;
  logic [3:0] pass_filter_s;
  logic [5:0] pass_e;
  logic [2:0] pass_stride;
  logic [9:0] pass_m;
  logic [3:0] pass_n;
  logic [5:0] pass_p;
  logic [3:0] pass_q;
  logic [3:0] pass_r;
  logic [3:0] pass_t;
  logic pass_load_ifmap;
  logic pass_load_filter;
  logic pass_keep_filter_for_batch;
  logic pass_psum_first;
  logic pass_psum_final;
  logic [63:0] pass_useful_macs;
  logic [31:0] pass_weight_bytes;
  logic pass_done;
  logic pass_error;
  logic layer_complete_valid;
  logic layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic inference_done;
  logic inference_done_ready;
  logic fault;
  logic [15:0] completed_passes;

  longint unsigned macs;
  longint unsigned weights;
  int layer_passes [0:7];
  int barriers;
  int delay_q;

  always #2.5 clk = ~clk;

  alexnet_eyeriss_rs_batch8_pass_scheduler dut (.*);

  always_ff @(posedge clk) begin
    if (rst) begin
      pass_ready <= 1'b0;
      pass_done <= 1'b0;
      pass_error <= 1'b0;
      layer_complete_ready <= 1'b1;
      inference_done_ready <= 1'b0;
      macs <= 0;
      weights <= 0;
      barriers <= 0;
      delay_q <= 0;
      for (int i = 0; i < 8; i++)
        layer_passes[i] <= 0;
    end else begin
      pass_ready <= ($urandom_range(0, 3) != 0);
      pass_done <= 1'b0;
      if (delay_q != 0) begin
        delay_q <= delay_q - 1;
        if (delay_q == 1)
          pass_done <= 1'b1;
      end
      if (pass_valid && pass_ready) begin
        if (pass_n != 8 || !pass_load_filter || !pass_keep_filter_for_batch)
          $fatal(1, "batch/filter residency contract broken");
        if (pass_tag != 16'h5253)
          $fatal(1, "tag mismatch");
        // Channel groups must be inner to one fixed filter tile so the URAM
        // result accumulator never needs a complete-layer scratch buffer.
        if (pass_layer_id == 1 && layer_passes[0] < 3 &&
            (pass_filter_base != 0 ||
             pass_channel_base != layer_passes[0]))
          $fatal(1, "Conv1 channel-inner order mismatch pass=%0d c=%0d f=%0d",
                 layer_passes[0], pass_channel_base, pass_filter_base);
        if (pass_layer_id == 2 && layer_passes[1] == 1 &&
            (pass_filter_base != 0 || pass_channel_base != 2))
          $fatal(1, "Conv2 second pass did not advance channel first");
        if (pass_layer_id == 2 && layer_passes[1] == 32 &&
            (pass_filter_base != 48 || pass_channel_base != 0))
          $fatal(1, "Conv2 filter tile did not advance after all channels");
        macs <= macs + pass_useful_macs;
        weights <= weights + pass_weight_bytes;
        layer_passes[pass_layer_id-1] <= layer_passes[pass_layer_id-1] + 1;
        delay_q <= $urandom_range(1, 3);
      end
      if (layer_complete_valid && layer_complete_ready)
        barriers <= barriers + 1;
    end
  end

  initial begin
    bit passed;
    passed = 0;
    start_valid = 0;
    start_tag = 16'h5253;
    repeat (8) @(negedge clk);
    rst = 0;
    @(negedge clk);
    start_valid = 1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 0;

    for (int timeout = 0; timeout < 100000; timeout++) begin
      @(negedge clk);
      if (inference_done) begin
        if (fault) $fatal(1, "scheduler faulted");
        if (completed_passes != 1185) $fatal(1, "pass total %0d", completed_passes);
        if (macs != 64'd5713507840) $fatal(1, "MAC total %0d", macs);
        if (weights != 64'd61253120) $fatal(1, "weight total %0d", weights);
        if (barriers != 8) $fatal(1, "barriers %0d", barriers);
        if (layer_passes[0] != 24 || layer_passes[1] != 128 ||
            layer_passes[2] != 96 || layer_passes[3] != 192 ||
            layer_passes[4] != 129 || layer_passes[5] != 384 ||
            layer_passes[6] != 174 || layer_passes[7] != 58)
          $fatal(1, "per-layer pass totals mismatch");
        $display("ALEXNET_EYERISS_RS_BATCH8_SCHEDULER_TEST_PASSED passes=%0d macs=%0d weights=%0d",
                 completed_passes, macs, weights);
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "scheduler timeout");
    $finish;
  end
endmodule
