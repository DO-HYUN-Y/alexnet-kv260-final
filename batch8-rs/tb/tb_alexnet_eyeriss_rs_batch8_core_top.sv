`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_core_top;
  logic clk = 0;
  logic rst = 1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic filter_request_valid, filter_data_valid, filter_data_ready;
  logic signed [7:0] filter_data;
  logic [3:0] filter_request_layer;
  logic [12:0] filter_request_filter;
  logic [13:0] filter_request_channel;
  logic [3:0] filter_request_y, filter_request_x;
  logic ifmap_request_valid, ifmap_data_valid, ifmap_data_ready;
  logic signed [7:0] ifmap_data;
  logic [3:0] ifmap_request_layer;
  logic [2:0] ifmap_request_image;
  logic [13:0] ifmap_request_channel;
  logic signed [8:0] ifmap_request_y, ifmap_request_x;
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
  logic inference_done, inference_done_ready;
  logic fault;
  logic [15:0] completed_passes;
  logic [63:0] total_mac_count;
  logic [31:0] total_local_psum_hops;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_batch8_core_top dut (.*);

  always_ff @(posedge clk) begin
    if (!rst && filter_request_valid && filter_request_layer != 1)
      $fatal(1, "first-pass filter request layer=%0d", filter_request_layer);
    if (!rst && ifmap_request_valid && ifmap_request_layer != 1)
      $fatal(1, "first-pass ifmap request layer=%0d", ifmap_request_layer);
  end

  initial begin
    bit passed;
    passed = 0;
    start_valid = 0;
    start_tag = 16'hc0e1;
    filter_data_valid = 1;
    filter_data = 1;
    ifmap_data_valid = 1;
    ifmap_data = 1;
    result_ready = 1;
    layer_complete_ready = 1;
    inference_done_ready = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    @(negedge clk); start_valid = 1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk); start_valid = 0;

    for (int timeout = 0; timeout < 30000; timeout++) begin
      @(negedge clk);
      if (result_valid) begin
        if (fault || result_tag != 16'hc0e1 || result_layer != 1 ||
            !result_psum_first || result_psum_final ||
            result_channel_base != 0 ||
            result_filter != 0 ||
            result_image != 0 || result_x != 0 || result_y_base != 0 ||
            result_col_valid != 14'h007f)
          $fatal(1, "first result metadata tag=%h filter=%0d image=%0d x=%0d y=%0d mask=%h fault=%0b",
                 result_tag, result_filter, result_image,
                 result_x, result_y_base, result_col_valid, fault);
        for (int col = 0; col < 7; col++)
          if (result_psum[col] != (col == 0 ? 81 : 99))
            $fatal(1, "Conv1 result col=%0d value=%0d", col,
                   result_psum[col]);
        if (total_mac_count != 3388 || total_local_psum_hops != 70)
          $fatal(1, "first result counters mac=%0d hops=%0d",
                 total_mac_count, total_local_psum_hops);
        $display("ALEXNET_EYERISS_RS_BATCH8_CORE_TOP_TEST_PASSED first_conv1_psum=81,99x6 macs=3388 hops=70");
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "batch8 core top first-result timeout");
    $finish;
  end
endmodule
