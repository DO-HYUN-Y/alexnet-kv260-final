`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_multiset_mapping;
  logic clk = 0;
  logic rst = 1;
  logic pass_valid, pass_ready;
  logic [15:0] pass_tag;
  logic [3:0] pass_layer_id, pass_filter_r;
  logic [5:0] pass_e;
  logic [2:0] pass_stride;
  logic [3:0] pass_set_r, pass_set_t;
  logic gin_cfg_valid, gin_cfg_ifmap, gin_cfg_xbus_valid;
  logic [3:0] gin_cfg_xbus_index;
  logic [4:0] gin_cfg_xbus_row_id;
  logic gin_cfg_pe_valid;
  logic [7:0] gin_cfg_pe_index;
  logic [5:0] gin_cfg_pe_col_id;
  logic gin_cfg_pe_enable;
  logic filter_phase_valid, filter_phase_ready;
  logic filter_phase_done, filter_phase_error;
  logic image_phase_valid, image_phase_ready;
  logic [2:0] image_phase_index;
  logic image_phase_done, image_phase_error;
  logic [15:0] active_tag;
  logic [3:0] active_layer_id;
  logic pass_done, pass_error;
  logic [8:0] configured_active_pes, gin_config_cycles;

  logic [4:0] filter_xbus [0:11];
  logic [4:0] ifmap_xbus [0:11];
  logic [5:0] filter_col [0:167];
  logic [5:0] ifmap_col [0:167];
  logic filter_enable [0:167];
  logic ifmap_enable [0:167];
  logic filter_pending, image_pending;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_batch8_pass_executor dut (.*);

  always_ff @(posedge clk) begin
    filter_phase_done <= 1'b0;
    image_phase_done <= 1'b0;
    if (rst) begin
      filter_pending <= 0;
      image_pending <= 0;
    end else begin
      if (filter_phase_valid && filter_phase_ready)
        filter_pending <= 1'b1;
      if (filter_pending) begin
        filter_phase_done <= 1'b1;
        filter_pending <= 1'b0;
      end
      if (image_phase_valid && image_phase_ready)
        image_pending <= 1'b1;
      if (image_pending) begin
        image_phase_done <= 1'b1;
        image_pending <= 1'b0;
      end
    end
  end

  task automatic run_mapping(input int layer, input int filter_r,
                             input int e, input int stride,
                             input int set_r, input int set_t,
                             input int expected_active);
    int filter_enabled;
    int ifmap_enabled;
    begin
      for (int i = 0; i < 12; i++) begin
        filter_xbus[i] = '1;
        ifmap_xbus[i] = '1;
      end
      for (int i = 0; i < 168; i++) begin
        filter_col[i] = '0;
        ifmap_col[i] = '0;
        filter_enable[i] = 0;
        ifmap_enable[i] = 0;
      end
      pass_layer_id = layer;
      pass_filter_r = filter_r;
      pass_e = e;
      pass_stride = stride;
      pass_set_r = set_r;
      pass_set_t = set_t;
      @(negedge clk); pass_valid = 1;
      do @(posedge clk); while (!pass_ready);
      @(negedge clk); pass_valid = 0;

      while (!pass_done) begin
        @(negedge clk);
        if (gin_cfg_valid && gin_cfg_xbus_valid) begin
          if (gin_cfg_ifmap)
            ifmap_xbus[gin_cfg_xbus_index] = gin_cfg_xbus_row_id;
          else
            filter_xbus[gin_cfg_xbus_index] = gin_cfg_xbus_row_id;
        end
        if (gin_cfg_valid && gin_cfg_pe_valid) begin
          if (gin_cfg_ifmap) begin
            ifmap_col[gin_cfg_pe_index] = gin_cfg_pe_col_id;
            ifmap_enable[gin_cfg_pe_index] = gin_cfg_pe_enable;
          end else begin
            filter_col[gin_cfg_pe_index] = gin_cfg_pe_col_id;
            filter_enable[gin_cfg_pe_index] = gin_cfg_pe_enable;
          end
        end
      end
      filter_enabled = 0;
      ifmap_enabled = 0;
      for (int i = 0; i < 168; i++) begin
        filter_enabled += filter_enable[i];
        ifmap_enabled += ifmap_enable[i];
      end
      if (pass_error || configured_active_pes != expected_active ||
          filter_enabled != expected_active || ifmap_enabled != expected_active)
        $fatal(1, "layer %0d active cfg=%0d filter=%0d ifmap=%0d",
               layer, configured_active_pes, filter_enabled, ifmap_enabled);
      @(negedge clk);
    end
  endtask

  initial begin
    pass_valid = 0;
    pass_tag = 16'h5e75;
    pass_layer_id = 0;
    pass_filter_r = 1;
    pass_e = 1;
    pass_stride = 1;
    pass_set_r = 1;
    pass_set_t = 1;
    filter_phase_ready = 1;
    filter_phase_done = 0;
    filter_phase_error = 0;
    image_phase_ready = 1;
    image_phase_done = 0;
    image_phase_error = 0;
    repeat (6) @(negedge clk);
    rst = 0;

    run_mapping(1, 11, 7, 4, 1, 2, 154);
    if (filter_col[0] != 0 || filter_col[7] != 1 ||
        ifmap_col[0] != 0 || ifmap_col[7] != 0 ||
        ifmap_col[10*14+6] != 34 || ifmap_xbus[10] != 0)
      $fatal(1, "Conv1 horizontal-set mapping mismatch");

    run_mapping(2, 5, 27, 1, 1, 1, 135);
    if (filter_xbus[5] != 0 || ifmap_col[70] != 14 ||
        ifmap_col[138] != 30)
      $fatal(1, "Conv2 folded mapping mismatch");

    run_mapping(3, 3, 13, 1, 1, 4, 156);
    if (filter_xbus[3] != 3 || ifmap_xbus[3] != 0 ||
        ifmap_col[3*14] != 0)
      $fatal(1, "Conv3 vertical filter-set mapping mismatch");

    run_mapping(4, 3, 13, 1, 2, 2, 156);
    if (ifmap_xbus[0] != 0 || ifmap_xbus[3] != 1 ||
        ifmap_xbus[6] != 0 || ifmap_xbus[9] != 1)
      $fatal(1, "Conv4 r/t reuse mapping mismatch");

    run_mapping(6, 1, 1, 1, 12, 14, 168);
    if (filter_col[13] != 13 || ifmap_xbus[11] != 11 ||
        ifmap_col[167] != 0)
      $fatal(1, "FC 12x14 set-grid mapping mismatch");

    $display("ALEXNET_EYERISS_RS_MULTISET_MAPPING_TEST_PASSED conv1=154 conv2=135 conv3=156 conv4=156 fc=168");
    $finish;
  end

endmodule
