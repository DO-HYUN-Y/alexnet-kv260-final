`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_board_frontend_top;
  logic clk = 0;
  logic rst = 1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [63:0] input_base, activation_a_base, activation_b_base, weights_base;
  logic filter_line_request_valid, filter_line_request_ready;
  logic [63:0] filter_line_request_address;
  logic filter_line_response_valid, filter_line_response_ready;
  logic [127:0] filter_line_response_data;
  logic filter_line_response_error;
  logic ifmap_line_request_valid, ifmap_line_request_ready;
  logic [63:0] ifmap_line_request_address;
  logic ifmap_line_response_valid, ifmap_line_response_ready;
  logic [127:0] ifmap_line_response_data;
  logic ifmap_line_response_error;
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
  logic inference_done, inference_done_ready, fault;
  logic [15:0] completed_passes;
  logic [63:0] total_mac_count;
  logic [31:0] total_local_psum_hops;
  logic [63:0] filter_byte_requests, filter_cache_hits;
  logic [63:0] filter_cache_misses, filter_dma_line_fetches;
  logic [63:0] ifmap_byte_requests, ifmap_cache_hits;
  logic [63:0] ifmap_cache_misses, ifmap_dma_line_fetches;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_batch8_board_frontend_top dut (.*);

  always_ff @(posedge clk) begin
    if (rst) begin
      filter_line_response_valid <= 1'b0;
      ifmap_line_response_valid <= 1'b0;
    end else begin
      if (filter_line_response_valid && filter_line_response_ready)
        filter_line_response_valid <= 1'b0;
      if (filter_line_request_valid && filter_line_request_ready) begin
        if (filter_line_request_address[3:0] != 0)
          $fatal(1, "unaligned filter line address %h",
                 filter_line_request_address);
        filter_line_response_valid <= 1'b1;
      end
      if (ifmap_line_response_valid && ifmap_line_response_ready)
        ifmap_line_response_valid <= 1'b0;
      if (ifmap_line_request_valid && ifmap_line_request_ready) begin
        if (ifmap_line_request_address[3:0] != 0)
          $fatal(1, "unaligned ifmap line address %h",
                 ifmap_line_request_address);
        ifmap_line_response_valid <= 1'b1;
      end
    end
  end

  initial begin
    bit passed;
    passed = 0;
    start_valid = 0;
    start_tag = 16'hb04d;
    input_base = 64'h0000_0000_1000_0000;
    activation_a_base = 64'h0000_0000_2000_0000;
    activation_b_base = 64'h0000_0000_3000_0000;
    weights_base = 64'h0000_0000_4000_0000;
    filter_line_request_ready = 1;
    filter_line_response_valid = 0;
    filter_line_response_data = {16{8'h01}};
    filter_line_response_error = 0;
    ifmap_line_request_ready = 1;
    ifmap_line_response_valid = 0;
    ifmap_line_response_data = {16{8'h01}};
    ifmap_line_response_error = 0;
    result_ready = 1;
    layer_complete_ready = 1;
    inference_done_ready = 0;
    repeat (6) @(negedge clk);
    rst = 0;
    @(negedge clk); start_valid = 1;
    do @(posedge clk); while (!start_ready);
    @(negedge clk); start_valid = 0;

    for (int timeout = 0; timeout < 100000; timeout++) begin
      @(negedge clk);
      if (result_valid) begin
        if (fault || result_tag != 16'hb04d || result_layer != 1 ||
            !result_psum_first || result_psum_final ||
            result_channel_base != 0 || result_filter != 0 ||
            result_image != 0 || result_x != 0 || result_y_base != 0 ||
            result_col_valid != 14'h007f)
          $fatal(1, "board frontend result metadata/fault mismatch");
        for (int col = 0; col < 7; col++)
          if (result_psum[col] != (col == 0 ? 81 : 99))
            $fatal(1, "Conv1 result col=%0d value=%0d", col,
                   result_psum[col]);
        if (total_mac_count != 3388 || total_local_psum_hops != 70)
          $fatal(1, "first result counters mac=%0d hops=%0d",
                 total_mac_count, total_local_psum_hops);
        if (filter_byte_requests == 0 || ifmap_byte_requests == 0 ||
            filter_dma_line_fetches == 0 || ifmap_dma_line_fetches == 0 ||
            filter_cache_misses != filter_dma_line_fetches ||
            ifmap_cache_misses != ifmap_dma_line_fetches)
          $fatal(1, "line cache counter contract mismatch");
        $display("ALEXNET_EYERISS_RS_BATCH8_BOARD_FRONTEND_TEST_PASSED filter_bytes=%0d hits=%0d lines=%0d ifmap_bytes=%0d hits=%0d lines=%0d",
                 filter_byte_requests, filter_cache_hits,
                 filter_dma_line_fetches, ifmap_byte_requests,
                 ifmap_cache_hits, ifmap_dma_line_fetches);
        passed = 1;
        break;
      end
    end
    if (!passed)
      $fatal(1, "board frontend first-result timeout");
    $finish;
  end
endmodule
