`timescale 1ns/1ps

module tb_pure_rs_scheduler_profile;
  logic clk = 1'b0;
  logic rst = 1'b1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic pass_valid, pass_ready;
  logic [15:0] pass_tag;
  logic [3:0] pass_layer_id;
  logic [5:0] pass_strip_y, pass_strip_rows;
  logic [13:0] pass_channel_base;
  logic [7:0] pass_channel_count;
  logic [12:0] pass_filter_base;
  logic [9:0] pass_filter_count;
  logic [5:0] pass_output_width;
  logic [3:0] pass_filter_r, pass_filter_s;
  logic [5:0] pass_e;
  logic [2:0] pass_stride;
  logic [9:0] pass_m;
  logic [3:0] pass_n;
  logic [5:0] pass_p;
  logic [3:0] pass_q, pass_r, pass_t;
  logic pass_load_ifmap, pass_load_filter, pass_keep_filter_for_batch;
  logic pass_psum_first, pass_psum_final;
  logic [63:0] pass_useful_macs;
  logic [31:0] pass_weight_bytes;
  logic pass_done, pass_error;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic inference_done, inference_done_ready, fault;
  logic [15:0] completed_passes;

  longint unsigned layer_macs [1:8];
  longint unsigned layer_weights [1:8];
  int unsigned layer_passes [1:8];
  bit pass_pending;

  always #2.5 clk = ~clk;

  alexnet_eyeriss_rs_batch8_pass_scheduler dut (.*);

  always @(negedge clk) begin
    pass_ready = !pass_pending;
    pass_done = pass_pending;
    pass_error = 1'b0;
    layer_complete_ready = layer_complete_valid;
    inference_done_ready = 1'b0;
    if (pass_pending)
      pass_pending = 1'b0;
    if (pass_valid && pass_ready)
      pass_pending = 1'b1;
  end

  always @(posedge clk) begin
    if (!rst && pass_valid && pass_ready) begin
      layer_macs[pass_layer_id] += pass_useful_macs;
      layer_weights[pass_layer_id] += pass_weight_bytes;
      layer_passes[pass_layer_id]++;
    end
  end

  initial begin
    bit profile_done;
    profile_done = 1'b0;
    start_valid = 1'b0;
    start_tag = 16'h5253;
    pass_ready = 1'b0;
    pass_done = 1'b0;
    pass_error = 1'b0;
    layer_complete_ready = 1'b0;
    inference_done_ready = 1'b0;
    pass_pending = 1'b0;
    for (int layer = 1; layer <= 8; layer++) begin
      layer_macs[layer] = 0;
      layer_weights[layer] = 0;
      layer_passes[layer] = 0;
    end

    repeat (8) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    for (int timeout = 0; timeout < 20_000; timeout++) begin
      @(negedge clk);
      if (inference_done) begin
        if (fault || completed_passes != 1185)
          $fatal(1, "pure RS scheduler profile failed");
        for (int layer = 1; layer <= 8; layer++)
          $display("RTL_PROFILE,pure_rs,%0d,%0d,%0d,%0d",
                   layer, layer_macs[layer], layer_weights[layer],
                   layer_passes[layer]);
        $display("RTL_PROFILE_DONE,pure_rs,%0d", completed_passes);
        profile_done = 1'b1;
        break;
      end
    end
    if (!profile_done)
      $fatal(1, "pure RS scheduler profile timed out");
    $finish;
  end
endmodule
