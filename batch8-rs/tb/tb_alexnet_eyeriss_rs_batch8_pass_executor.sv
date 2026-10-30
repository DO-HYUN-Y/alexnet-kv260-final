`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_pass_executor;
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

  int filter_xbus_cfgs;
  int filter_pe_cfgs;
  int ifmap_xbus_cfgs;
  int ifmap_pe_cfgs;
  int filter_enabled;
  int ifmap_enabled;
  int filter_phases;
  int image_phases;
  logic filter_pending;
  logic image_pending;

  always #2.5 clk = ~clk;

  alexnet_eyeriss_rs_batch8_pass_executor dut (.*);

  always_ff @(posedge clk) begin
    filter_phase_done <= 1'b0;
    image_phase_done <= 1'b0;
    if (rst) begin
      filter_xbus_cfgs <= 0;
      filter_pe_cfgs <= 0;
      ifmap_xbus_cfgs <= 0;
      ifmap_pe_cfgs <= 0;
      filter_enabled <= 0;
      ifmap_enabled <= 0;
      filter_phases <= 0;
      image_phases <= 0;
      filter_pending <= 0;
      image_pending <= 0;
    end else begin
      if (gin_cfg_valid && gin_cfg_xbus_valid) begin
        if (gin_cfg_ifmap) begin
          ifmap_xbus_cfgs <= ifmap_xbus_cfgs + 1;
          if ((gin_cfg_xbus_index < 10) && (gin_cfg_xbus_row_id != 0))
            $fatal(1, "ifmap X-bus row id %0d", gin_cfg_xbus_row_id);
          if ((gin_cfg_xbus_index >= 10) &&
              (gin_cfg_xbus_row_id != 5'h1f))
            $fatal(1, "unused ifmap X-bus row id %0d",
                   gin_cfg_xbus_row_id);
        end else begin
          filter_xbus_cfgs <= filter_xbus_cfgs + 1;
          if (gin_cfg_xbus_index == 5 && gin_cfg_xbus_row_id != 0)
            $fatal(1, "folded filter row 5 id %0d", gin_cfg_xbus_row_id);
        end
      end
      if (gin_cfg_valid && gin_cfg_pe_valid) begin
        if (gin_cfg_ifmap) begin
          ifmap_pe_cfgs <= ifmap_pe_cfgs + 1;
          if (gin_cfg_pe_enable)
            ifmap_enabled <= ifmap_enabled + 1;
          if (gin_cfg_pe_index == 70 && gin_cfg_pe_col_id != 14)
            $fatal(1, "folded diagonal start id %0d", gin_cfg_pe_col_id);
          if (gin_cfg_pe_index == 138 && gin_cfg_pe_col_id != 30)
            $fatal(1, "folded diagonal end id %0d", gin_cfg_pe_col_id);
        end else begin
          filter_pe_cfgs <= filter_pe_cfgs + 1;
          if (gin_cfg_pe_enable)
            filter_enabled <= filter_enabled + 1;
          if (gin_cfg_pe_col_id != 0)
            $fatal(1, "filter column id %0d", gin_cfg_pe_col_id);
        end
      end

      if (filter_phase_valid && filter_phase_ready) begin
        filter_phases <= filter_phases + 1;
        filter_pending <= 1'b1;
      end
      if (filter_pending) begin
        filter_phase_done <= 1'b1;
        filter_pending <= 1'b0;
      end

      if (image_phase_valid && image_phase_ready) begin
        if (image_phase_index != image_phases[2:0])
          $fatal(1, "image order %0d expected %0d",
                 image_phase_index, image_phases);
        image_phases <= image_phases + 1;
        image_pending <= 1'b1;
      end
      if (image_pending) begin
        image_phase_done <= 1'b1;
        image_pending <= 1'b0;
      end
    end
  end

  initial begin
    bit passed;
    passed = 0;
    pass_valid = 0;
    pass_tag = 16'hb808;
    pass_layer_id = 2;
    pass_filter_r = 5;
    pass_e = 27;
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
    @(negedge clk);
    pass_valid = 1;
    do @(posedge clk); while (!pass_ready);
    @(negedge clk);
    pass_valid = 0;

    for (int timeout = 0; timeout < 1000; timeout++) begin
      @(negedge clk);
      if (pass_done) begin
        if (pass_error || active_tag != 16'hb808 || active_layer_id != 2)
          $fatal(1, "completion metadata/error mismatch");
        if (filter_xbus_cfgs != 12 || filter_pe_cfgs != 168 ||
            ifmap_xbus_cfgs != 12 || ifmap_pe_cfgs != 168)
          $fatal(1, "GIN scan totals F=%0d/%0d I=%0d/%0d",
                 filter_xbus_cfgs, filter_pe_cfgs,
                 ifmap_xbus_cfgs, ifmap_pe_cfgs);
        if (filter_enabled != 135 || ifmap_enabled != 135 ||
            configured_active_pes != 135)
          $fatal(1, "active PE totals F=%0d I=%0d cfg=%0d",
                 filter_enabled, ifmap_enabled, configured_active_pes);
        if (filter_phases != 1 || image_phases != 8 ||
            gin_config_cycles != 360)
          $fatal(1, "batch contract filter=%0d images=%0d cfgcycles=%0d",
                 filter_phases, image_phases, gin_config_cycles);
        $display("ALEXNET_EYERISS_RS_BATCH8_EXECUTOR_TEST_PASSED active=135 gin_cycles=360 filter_loads=1 images=8");
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "executor timeout");
    $finish;
  end

endmodule
