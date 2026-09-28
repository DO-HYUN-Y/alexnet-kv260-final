`timescale 1ns/1ps

module tb_alexnet_m8n126_fc_batch8_scheduler;
  logic clk = 1'b0;
  logic rst;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [3:0] start_layer_id, stop_layer_id, fc_batch_size;
  logic [15:0] start_n_base;
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

  longint unsigned useful_macs, physical_slots, weight_transfer_bytes;
  int layer_commands [6:8];
  int layer_barriers;
  bit command_pending;

  alexnet_m8n126_graph_scheduler dut (.*);
  always #2.5 clk = ~clk;

  function automatic int count_mask_bits();
    int count;
    begin
      count = 0;
      for (int bank = 0; bank < 8; bank++)
        for (int lane = 0; lane < 16; lane++)
          count += command_n_lane_mask[bank][lane];
      count_mask_bits = count;
    end
  endfunction

  always @(negedge clk) begin
    command_ready = !command_pending;
    command_done = command_pending;
    command_error = 1'b0;
    layer_complete_ready = layer_complete_valid;
    if (command_pending)
      command_pending = 1'b0;
  end

  always @(posedge clk) begin
    if (!rst && layer_complete_valid && layer_complete_ready)
      layer_barriers++;
    if (!rst && command_valid && command_ready) begin
      if (!command_is_fc || command_mode_split_n64 ||
          command_m_base != 0 || command_m_count != 8 ||
          command_group0_m_count != 8 || command_group1_m_count != 0 ||
          command_bank_enable != 8'h01 ||
          count_mask_bits() != command_n_count ||
          !command_weight_fill || !command_weight_release)
        $fatal(1, "native batch-8 FC descriptor mismatch layer=%0d n=%0d",
               command_layer_id, command_n_base);
      command_pending = 1'b1;
      layer_commands[command_layer_id]++;
      useful_macs += command_m_count * command_n_count * command_k_count;
      physical_slots += 1024 * command_k_count;
      weight_transfer_bytes += 16 * command_k_count;
    end
  end

  initial begin
    rst = 1'b1;
    start_valid = 1'b0;
    start_tag = 16'hb800;
    start_layer_id = 6;
    stop_layer_id = 8;
    fc_batch_size = 8;
    start_n_base = 0;
    start_single_n_tile = 1'b0;
    start_weight_fill_enable = 1'b1;
    start_weight_release_enable = 1'b1;
    start_pool_enable = 1'b1;
    command_ready = 1'b0;
    command_done = 1'b0;
    command_error = 1'b0;
    layer_complete_ready = 1'b0;
    command_pending = 1'b0;
    useful_macs = 0;
    physical_slots = 0;
    weight_transfer_bytes = 0;
    layer_barriers = 0;
    for (int layer = 6; layer <= 8; layer++)
      layer_commands[layer] = 0;

    repeat (6) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
    start_valid = 1'b1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 1'b0;

    for (int timeout = 0; timeout < 20_000; timeout++) begin
      @(negedge clk);
      if (inference_done) begin
        if (inference_failed || fault || completed_commands != 1087 ||
            layer_commands[6] != 768 || layer_commands[7] != 256 ||
            layer_commands[8] != 63 || layer_barriers != 2 ||
            useful_macs != 64'd468975616 ||
            physical_slots != 64'd3753902080 ||
            weight_transfer_bytes != 64'd58654720)
          $fatal(1, "native batch-8 FC accounting mismatch commands=%0d macs=%0d slots=%0d weights=%0d barriers=%0d",
                 completed_commands, useful_macs, physical_slots,
                 weight_transfer_bytes, layer_barriers);
        $display("ALEXNET_M8N126_FC_BATCH8_SCHEDULER_TEST_PASSED commands=1087 macs=468975616 slots=3753902080 weight_bytes=58654720 slot_utilization=12.4930%%");
        $finish;
      end
    end
    $fatal(1, "native batch-8 FC scheduler timeout");
  end
endmodule
