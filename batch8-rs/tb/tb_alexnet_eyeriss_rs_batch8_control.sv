`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_control;
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
  logic filter_phase_valid, filter_phase_ready;
  logic filter_phase_done, filter_phase_error;
  logic image_phase_valid, image_phase_ready;
  logic [2:0] image_phase_index;
  logic image_phase_done, image_phase_error;
  logic [15:0] active_tag;
  logic [3:0] active_layer_id;
  logic [5:0] active_strip_y, active_strip_rows;
  logic [13:0] active_channel_base;
  logic [7:0] active_channel_count;
  logic [12:0] active_filter_base;
  logic [9:0] active_filter_count;
  logic [5:0] active_output_width;
  logic [3:0] active_filter_r, active_filter_s;
  logic [5:0] active_e;
  logic [2:0] active_stride;
  logic [5:0] active_p;
  logic [3:0] active_q, active_r, active_t;
  logic active_psum_first, active_psum_final;
  logic layer_complete_valid, layer_complete_ready;
  logic [3:0] layer_complete_id;
  logic inference_done, inference_done_ready;
  logic fault;
  logic [15:0] completed_passes;

  int gin_cycles;
  int filter_phases;
  int image_phases;
  int barriers;
  logic filter_pending, image_pending;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_batch8_control dut (.*);

  always_ff @(posedge clk) begin
    filter_phase_done <= 1'b0;
    image_phase_done <= 1'b0;
    if (rst) begin
      gin_cycles <= 0;
      filter_phases <= 0;
      image_phases <= 0;
      barriers <= 0;
      filter_pending <= 0;
      image_pending <= 0;
    end else begin
      if (gin_cfg_valid)
        gin_cycles <= gin_cycles + 1;
      if (filter_phase_valid && filter_phase_ready) begin
        filter_phases <= filter_phases + 1;
        filter_pending <= 1'b1;
      end
      if (filter_pending) begin
        filter_phase_done <= 1'b1;
        filter_pending <= 1'b0;
      end
      if (image_phase_valid && image_phase_ready) begin
        if (image_phase_index != (image_phases % 8))
          $fatal(1, "batch index %0d expected %0d",
                 image_phase_index, image_phases % 8);
        image_phases <= image_phases + 1;
        image_pending <= 1'b1;
      end
      if (image_pending) begin
        image_phase_done <= 1'b1;
        image_pending <= 1'b0;
      end
      if (layer_complete_valid && layer_complete_ready)
        barriers <= barriers + 1;
    end
  end

  initial begin
    bit passed;
    passed = 0;
    start_valid = 0;
    start_tag = 16'hc808;
    filter_phase_ready = 1;
    filter_phase_done = 0;
    filter_phase_error = 0;
    image_phase_ready = 1;
    image_phase_done = 0;
    image_phase_error = 0;
    layer_complete_ready = 1;
    inference_done_ready = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    @(negedge clk);
    start_valid = 1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk);
    start_valid = 0;

    for (int timeout = 0; timeout < 50000; timeout++) begin
      @(negedge clk);
      if (inference_done) begin
        if (fault || active_tag != 16'hc808)
          $fatal(1, "control fault/tag mismatch");
        if (completed_passes != 1185 || filter_phases != 1185 ||
            image_phases != 9480 || barriers != 8)
          $fatal(1, "totals passes=%0d filters=%0d images=%0d barriers=%0d",
                 completed_passes, filter_phases, image_phases, barriers);
        // Five mappings: Conv1, Conv2, Conv3, Conv4-5, and FC6-8.
        if (gin_cycles != 1800)
          $fatal(1, "GIN cache cycles %0d", gin_cycles);
        $display("ALEXNET_EYERISS_RS_BATCH8_CONTROL_TEST_PASSED passes=1185 filter_loads=1185 images=9480 gin_cycles=1800");
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "control timeout");
    $finish;
  end

endmodule
