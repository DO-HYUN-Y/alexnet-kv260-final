`timescale 1ns/1ps

module tb_alexnet_m8n126_conv_batch8_reuse_scheduler;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag, start_n_base;
  logic [3:0] start_layer_id, stop_layer_id, fc_batch_size;
  logic start_single_n_tile, start_weight_fill_enable;
  logic start_weight_release_enable, start_pool_enable;
  logic command_valid, command_ready;
  logic [3:0] command_layer_id;
  logic command_is_fc, command_mode_split_n64;
  logic [7:0] command_bank_enable;
  logic [15:0] command_n_lane_mask [0:7];
  logic [15:0] command_n_base;
  logic [7:0] command_n_count;
  logic [12:0] command_m_base;
  logic [4:0] command_m_count;
  logic [3:0] command_group0_m_count, command_group1_m_count;
  logic [13:0] command_k_offset;
  logic [12:0] command_k_count;
  logic command_accum_first, command_accum_final;
  logic command_weight_fill, command_weight_release;
  logic command_result_enable, command_layer_last;
  logic [15:0] command_context_tag, command_tile_tag;
  logic command_done, command_error;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic layer_complete_requires_pool;
  logic busy, inference_done, inference_failed, fault;
  logic [3:0] active_layer_id;
  logic [15:0] completed_commands;

  bit command_pending;
  int current_image;
  int launch_commands;
  int total_commands;
  int weight_fills;
  int weight_releases;

  alexnet_m8n126_graph_scheduler dut (.*);
  always #2.5 clk = ~clk;

  always @(negedge clk) begin
    command_ready = !command_pending;
    command_done = command_pending;
    command_error = 1'b0;
    layer_complete_ready = layer_complete_valid;
    if (command_pending)
      command_pending = 1'b0;
    if (command_valid && command_ready)
      command_pending = 1'b1;
  end

  always @(posedge clk) begin
    if (!rst && command_valid && command_ready) begin
      if (command_layer_id != 2 || command_n_base != 64 ||
          command_n_count != 64 || command_k_offset != 0 ||
          command_k_count != 1600)
        $fatal(1, "batch reuse descriptor geometry mismatch");
      if (command_weight_fill !=
          (current_image == 0 && command_m_base == 0))
        $fatal(1, "batch reuse weight-fill policy mismatch image=%0d m=%0d",
               current_image, command_m_base);
      if (command_weight_release !=
          (current_image == 7 &&
           command_m_base + command_m_count == 729))
        $fatal(1, "batch reuse weight-release policy mismatch image=%0d m=%0d",
               current_image, command_m_base);
      if (command_layer_last !=
          (command_m_base + command_m_count == 729))
        $fatal(1, "single-N launch layer-last mismatch");
      launch_commands++;
      total_commands++;
      if (command_weight_fill)
        weight_fills++;
      if (command_weight_release)
        weight_releases++;
    end
    if (!rst && layer_complete_valid && layer_complete_requires_pool)
      $fatal(1, "middle Conv2 N tile incorrectly requested pooling");
  end

  initial begin
    rst = 1'b1;
    start_valid = 1'b0;
    start_tag = 16'hb208;
    start_layer_id = 2;
    stop_layer_id = 2;
    fc_batch_size = 1;
    start_n_base = 64;
    start_single_n_tile = 1'b1;
    start_pool_enable = 1'b0;
    command_ready = 1'b0;
    command_done = 1'b0;
    command_error = 1'b0;
    layer_complete_ready = 1'b0;
    command_pending = 1'b0;
    current_image = 0;
    launch_commands = 0;
    total_commands = 0;
    weight_fills = 0;
    weight_releases = 0;

    repeat (8) @(negedge clk);
    rst = 1'b0;
    for (current_image = 0; current_image < 8; current_image++) begin
      start_weight_fill_enable = current_image == 0;
      start_weight_release_enable = current_image == 7;
      launch_commands = 0;
      @(negedge clk);
      start_valid = 1'b1;
      do @(posedge clk); while (!start_ready);
      @(negedge clk);
      start_valid = 1'b0;
      for (int timeout = 0; timeout < 1000; timeout++) begin
        @(negedge clk);
        if (inference_done)
          break;
        if (timeout == 999 || fault || inference_failed)
          $fatal(1, "batch reuse launch failed image=%0d", current_image);
      end
      if (launch_commands != 46 || completed_commands != 46)
        $fatal(1, "batch reuse command count mismatch image=%0d got=%0d",
               current_image, launch_commands);
    end

    if (total_commands != 368 || weight_fills != 1 || weight_releases != 1)
      $fatal(1, "batch reuse totals mismatch commands=%0d fills=%0d releases=%0d",
             total_commands, weight_fills, weight_releases);
    $display("ALEXNET_M8N126_CONV_BATCH8_REUSE_SCHEDULER_TEST_PASSED commands=%0d fills=%0d releases=%0d",
             total_commands, weight_fills, weight_releases);
    $finish;
  end
endmodule
