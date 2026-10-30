`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_command_top;
  logic clk = 0;
  logic rst = 1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic gin_cfg_valid, gin_cfg_ifmap, gin_cfg_xbus_valid;
  logic [3:0] gin_cfg_xbus_index;
  logic [4:0] gin_cfg_xbus_row_id;
  logic gin_cfg_pe_valid;
  logic [7:0] gin_cfg_pe_index;
  logic [5:0] gin_cfg_pe_col_id;
  logic gin_cfg_pe_enable;
  logic filter_command_valid, filter_command_ready;
  logic [1:0] filter_command_cluster;
  logic [4:0] filter_command_row_tag;
  logic [5:0] filter_command_col_tag;
  logic [7:0] filter_command_rf_addr;
  logic filter_source_required;
  logic [3:0] filter_source_layer;
  logic [12:0] filter_source_filter;
  logic [13:0] filter_source_channel;
  logic [3:0] filter_source_y, filter_source_x;
  logic ifmap_command_valid, ifmap_command_ready;
  logic [4:0] ifmap_row_tag;
  logic [5:0] ifmap_col_tag;
  logic [3:0] ifmap_rf_addr;
  logic ifmap_source_required;
  logic [3:0] ifmap_source_layer;
  logic [2:0] ifmap_source_image;
  logic [13:0] ifmap_source_channel;
  logic signed [8:0] ifmap_source_y, ifmap_source_x;
  logic op_command_valid, op_command_ready;
  logic [2:0] op_cluster_enable;
  logic [2:0][167:0] op_mask;
  logic [7:0] op_filter_addr;
  logic [3:0] op_ifmap_addr;
  logic [4:0] op_psum_addr;
  logic op_first, op_last;
  logic [15:0] op_tag;
  logic reduce_command_valid, reduce_command_ready;
  logic reduce_command_done, reduce_command_error;
  logic [1:0] reduce_cluster;
  logic [3:0] reduce_rows, reduce_cols;
  logic [3:0] reduce_start_row, reduce_start_col;
  logic [15:0] reduce_tag;
  logic [3:0] reduce_output_layer;
  logic reduce_output_psum_first, reduce_output_psum_final;
  logic [13:0] reduce_output_channel_base;
  logic [12:0] reduce_output_filter;
  logic [2:0] reduce_output_image;
  logic [5:0] reduce_output_x, reduce_output_y_base;
  logic core_cfg_valid;
  logic [5:0] core_cfg_p, core_cfg_e;
  logic [3:0] core_cfg_q, core_cfg_s, core_cfg_filter_r;
  logic [2:0] core_cfg_stride;
  logic [3:0] core_cfg_set_r, core_cfg_set_t;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic inference_done, inference_done_ready;
  logic fault;
  logic [15:0] completed_passes;
  logic [31:0] filter_sequences_done, image_sequences_done;
  logic reduce_pending;
  int filter_commands_seen;
  int ifmap_commands_seen;
  int op_commands_seen;
  int reductions_seen;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_batch8_command_top dut (.*);

  always_ff @(posedge clk) begin
    reduce_command_done <= 1'b0;
    if (rst) begin
      reduce_pending <= 0;
      filter_commands_seen <= 0;
      ifmap_commands_seen <= 0;
      op_commands_seen <= 0;
      reductions_seen <= 0;
    end else begin
      if (filter_command_valid && filter_command_ready) begin
        if (filter_source_layer != 1)
          $fatal(1, "first-pass filter layer tag=%0d", filter_source_layer);
        filter_commands_seen <= filter_commands_seen + 1;
      end
      if (ifmap_command_valid && ifmap_command_ready) begin
        if (ifmap_source_layer != 1)
          $fatal(1, "first-pass ifmap layer tag=%0d", ifmap_source_layer);
        ifmap_commands_seen <= ifmap_commands_seen + 1;
      end
      if (op_command_valid && op_command_ready)
        op_commands_seen <= op_commands_seen + 1;
      if (reduce_command_valid && reduce_command_ready) begin
        if (reduce_output_layer != 1)
          $fatal(1, "first-pass result layer tag=%0d", reduce_output_layer);
        if (!reduce_output_psum_first || reduce_output_psum_final)
          $fatal(1, "first-pass psum boundary first=%0b final=%0b",
                 reduce_output_psum_first, reduce_output_psum_final);
        reductions_seen <= reductions_seen + 1;
        reduce_pending <= 1'b1;
      end
      if (reduce_pending) begin
        reduce_command_done <= 1'b1;
        reduce_pending <= 1'b0;
      end
    end
  end

  initial begin
    bit passed;
    passed = 0;
    start_valid = 0;
    start_tag = 16'hc058;
    filter_command_ready = 1;
    ifmap_command_ready = 1;
    op_command_ready = 1;
    reduce_command_ready = 1;
    reduce_command_done = 0;
    reduce_command_error = 0;
    layer_complete_ready = 1;
    inference_done_ready = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    @(negedge clk); start_valid = 1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk); start_valid = 0;

    for (int timeout = 0; timeout < 120000; timeout++) begin
      @(negedge clk);
      if (image_sequences_done == 1) begin
        if (fault || filter_sequences_done != 1 ||
            filter_commands_seen != 7744 ||
            ifmap_commands_seen != 21175 ||
            op_commands_seen != 9680 || reductions_seen != 3520)
          $fatal(1, "command top counts filter=%0d/%0d ifmap=%0d op=%0d reduce=%0d fault=%0b",
                 filter_sequences_done, filter_commands_seen,
                 ifmap_commands_seen, op_commands_seen,
                 reductions_seen, fault);
        $display("ALEXNET_EYERISS_RS_BATCH8_COMMAND_TOP_TEST_PASSED first_pass_filter=7744 first_image_ifmap=21175 op=9680 reduce=3520");
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "command top timeout");
    $finish;
  end
endmodule
