`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_cluster;
  logic clk = 0;
  logic rst = 1;
  logic cfg_valid;
  logic [5:0] cfg_p;
  logic [3:0] cfg_q, cfg_s, cfg_filter_r;
  logic [5:0] cfg_e;
  logic [2:0] cfg_stride;
  logic [3:0] cfg_set_r, cfg_set_t;
  logic gin_cfg_valid, gin_cfg_ifmap, gin_cfg_xbus_valid;
  logic [3:0] gin_cfg_xbus_index;
  logic [4:0] gin_cfg_xbus_row_id;
  logic gin_cfg_pe_valid;
  logic [7:0] gin_cfg_pe_index;
  logic [5:0] gin_cfg_pe_col_id;
  logic gin_cfg_pe_enable;
  logic filter_event_valid, filter_event_ready;
  logic [3:0] filter_row;
  logic filter_use_gin;
  logic [4:0] filter_row_tag;
  logic [5:0] filter_col_tag;
  logic filter_use_explicit_mask;
  logic [167:0] filter_explicit_mask;
  logic [7:0] filter_addr;
  logic signed [7:0] filter_value;
  logic ifmap_event_valid, ifmap_event_ready;
  logic [6:0] ifmap_row;
  logic ifmap_use_gin;
  logic [4:0] ifmap_row_tag;
  logic [5:0] ifmap_col_tag;
  logic ifmap_use_explicit_mask;
  logic [167:0] ifmap_explicit_mask;
  logic [3:0] ifmap_addr;
  logic signed [7:0] ifmap_value;
  logic op_valid, op_ready;
  logic [167:0] op_mask;
  logic [7:0] op_filter_addr;
  logic [3:0] op_ifmap_addr;
  logic [4:0] op_psum_addr;
  logic op_first, op_last;
  logic [15:0] op_tag;
  logic reduce_valid, reduce_ready;
  logic [3:0] reduce_rows, reduce_cols;
  logic [3:0] reduce_start_row, reduce_start_col;
  logic [15:0] reduce_tag;
  logic result_valid, result_ready;
  logic [13:0] result_col_valid;
  logic signed [31:0] result_psum [0:13];
  logic [15:0] result_tag;
  logic [8:0] active_pes;
  logic fault;
  logic [63:0] cluster_mac_count;
  logic [31:0] local_psum_hops;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_cluster dut (.*);

  task automatic send_filter(input int row, input int value);
    @(negedge clk);
    filter_event_valid = 1;
    filter_row = row;
    filter_row_tag = row;
    filter_col_tag = 0;
    filter_value = value;
    do @(posedge clk); while (!filter_event_ready);
    @(negedge clk);
    filter_event_valid = 0;
  endtask

  task automatic send_filter_tag(input int row_tag, input int col_tag,
                                 input int value);
    @(negedge clk);
    filter_event_valid = 1;
    filter_row = row_tag;
    filter_row_tag = row_tag;
    filter_col_tag = col_tag;
    filter_value = value;
    do @(posedge clk); while (!filter_event_ready);
    @(negedge clk);
    filter_event_valid = 0;
  endtask

  task automatic send_ifmap(input int row, input int value);
    @(negedge clk);
    ifmap_event_valid = 1;
    ifmap_row = row;
    ifmap_row_tag = 0;
    ifmap_col_tag = row;
    ifmap_value = value;
    do @(posedge clk); while (!ifmap_event_ready);
    @(negedge clk);
    ifmap_event_valid = 0;
  endtask

  initial begin
    cfg_valid = 0; cfg_p = 1; cfg_q = 1; cfg_s = 1;
    cfg_filter_r = 3; cfg_e = 3; cfg_stride = 1;
    cfg_set_r = 1; cfg_set_t = 1;
    gin_cfg_valid = 0; gin_cfg_ifmap = 0; gin_cfg_xbus_valid = 0;
    gin_cfg_xbus_index = 0; gin_cfg_xbus_row_id = 0;
    gin_cfg_pe_valid = 0; gin_cfg_pe_index = 0; gin_cfg_pe_col_id = 0;
    gin_cfg_pe_enable = 0;
    filter_event_valid = 0; filter_row = 0;
    filter_use_gin = 1; filter_row_tag = 0; filter_col_tag = 0;
    filter_use_explicit_mask = 0; filter_explicit_mask = 0;
    filter_addr = 0; filter_value = 0;
    ifmap_event_valid = 0; ifmap_row = 0;
    ifmap_use_gin = 1; ifmap_row_tag = 0; ifmap_col_tag = 0;
    ifmap_use_explicit_mask = 0; ifmap_explicit_mask = 0;
    ifmap_addr = 0; ifmap_value = 0;
    op_valid = 0; op_mask = 0; op_filter_addr = 0;
    op_ifmap_addr = 0; op_psum_addr = 0;
    op_first = 1; op_last = 1; op_tag = 16'h0033;
    reduce_valid = 0; reduce_rows = 3; reduce_cols = 3;
    reduce_start_row = 0; reduce_start_col = 0;
    reduce_tag = 16'h0033;
    result_ready = 1;
    repeat (5) @(negedge clk);
    rst = 0;
    @(negedge clk); cfg_valid = 1;
    @(negedge clk); cfg_valid = 0;
    if (active_pes != 9) $fatal(1, "active PE count %0d", active_pes);

    // Filter GIN: X-bus row ID selects the filter row, all active PEs use
    // col ID zero so one tag fans out horizontally.
    for (int r = 0; r < 3; r++) begin
      @(negedge clk);
      gin_cfg_valid = 1; gin_cfg_ifmap = 0; gin_cfg_xbus_valid = 1;
      gin_cfg_xbus_index = r; gin_cfg_xbus_row_id = r;
      @(negedge clk); gin_cfg_valid = 0; gin_cfg_xbus_valid = 0;
    end
    for (int r = 0; r < 3; r++) begin
      for (int c = 0; c < 3; c++) begin
        @(negedge clk);
        gin_cfg_valid = 1; gin_cfg_ifmap = 0; gin_cfg_pe_valid = 1;
        gin_cfg_pe_index = r*14+c; gin_cfg_pe_col_id = 0;
        gin_cfg_pe_enable = 1;
        @(negedge clk); gin_cfg_valid = 0; gin_cfg_pe_valid = 0;
      end
    end

    // Ifmap GIN: all active X-buses share row ID zero; PE col IDs encode
    // r+c, producing the diagonal multicast groups of Fig. 4b.
    for (int r = 0; r < 3; r++) begin
      @(negedge clk);
      gin_cfg_valid = 1; gin_cfg_ifmap = 1; gin_cfg_xbus_valid = 1;
      gin_cfg_xbus_index = r; gin_cfg_xbus_row_id = 0;
      @(negedge clk); gin_cfg_valid = 0; gin_cfg_xbus_valid = 0;
    end
    for (int r = 0; r < 3; r++) begin
      for (int c = 0; c < 3; c++) begin
        @(negedge clk);
        gin_cfg_valid = 1; gin_cfg_ifmap = 1; gin_cfg_pe_valid = 1;
        gin_cfg_pe_index = r*14+c; gin_cfg_pe_col_id = r+c;
        gin_cfg_pe_enable = 1;
        @(negedge clk); gin_cfg_valid = 0; gin_cfg_pe_valid = 0;
      end
    end

    send_filter(0, 1);
    send_filter(1, 2);
    send_filter(2, 3);
    // Input rows 0..4 cover all three diagonals; every PE stores value one.
    for (int row = 0; row < 5; row++) send_ifmap(row, 1);

    for (int r = 0; r < 3; r++)
      for (int c = 0; c < 3; c++)
        op_mask[r*14+c] = 1;
    @(negedge clk); op_valid = 1;
    do @(posedge clk); while (!op_ready);
    @(negedge clk); op_valid = 0;

    // Wait until all active PE outputs are resident, then launch vertical LN.
    repeat (2) @(negedge clk);
    reduce_valid = 1;
    do @(posedge clk); while (!reduce_ready);
    @(negedge clk); reduce_valid = 0;

    while (!result_valid) @(negedge clk);
    if (result_tag != 16'h0033 || result_col_valid != 14'h0007)
      $fatal(1, "result metadata tag=%h mask=%h", result_tag, result_col_valid);
    for (int c = 0; c < 3; c++)
      if (result_psum[c] != 6)
        $fatal(1, "column %0d psum=%0d", c, result_psum[c]);
    if (fault || cluster_mac_count != 9 || local_psum_hops != 6)
      $fatal(1, "cluster status fault=%0b mac=%0d hops=%0d",
             fault, cluster_mac_count, local_psum_hops);
    $display("ALEXNET_EYERISS_RS_CLUSTER_TEST_PASSED active=%0d macs=%0d hops=%0d psum=6,6,6",
             active_pes, cluster_mac_count, local_psum_hops);

    // Two horizontal PE sets must retain different filters while sharing one
    // ifmap.  Reduce them independently and verify that accepting set zero
    // does not release set one's resident result.
    @(negedge clk); rst = 1;
    cfg_filter_r = 1; cfg_e = 1; cfg_set_r = 1; cfg_set_t = 2;
    op_mask = '0; reduce_rows = 1; reduce_cols = 1;
    reduce_start_row = 0; reduce_start_col = 0;
    repeat (4) @(negedge clk);
    rst = 0;
    @(negedge clk); cfg_valid = 1;
    @(negedge clk); cfg_valid = 0;
    if (active_pes != 2) $fatal(1, "multi-set active PE count %0d", active_pes);

    @(negedge clk);
    gin_cfg_valid = 1; gin_cfg_ifmap = 0; gin_cfg_xbus_valid = 1;
    gin_cfg_xbus_index = 0; gin_cfg_xbus_row_id = 0;
    @(negedge clk); gin_cfg_valid = 0; gin_cfg_xbus_valid = 0;
    for (int c = 0; c < 2; c++) begin
      @(negedge clk);
      gin_cfg_valid = 1; gin_cfg_ifmap = 0; gin_cfg_pe_valid = 1;
      gin_cfg_pe_index = c; gin_cfg_pe_col_id = c;
      gin_cfg_pe_enable = 1;
      @(negedge clk); gin_cfg_valid = 0; gin_cfg_pe_valid = 0;
    end
    @(negedge clk);
    gin_cfg_valid = 1; gin_cfg_ifmap = 1; gin_cfg_xbus_valid = 1;
    gin_cfg_xbus_index = 0; gin_cfg_xbus_row_id = 0;
    @(negedge clk); gin_cfg_valid = 0; gin_cfg_xbus_valid = 0;
    for (int c = 0; c < 2; c++) begin
      @(negedge clk);
      gin_cfg_valid = 1; gin_cfg_ifmap = 1; gin_cfg_pe_valid = 1;
      gin_cfg_pe_index = c; gin_cfg_pe_col_id = 0;
      gin_cfg_pe_enable = 1;
      @(negedge clk); gin_cfg_valid = 0; gin_cfg_pe_valid = 0;
    end

    send_filter_tag(0, 0, 2);
    send_filter_tag(0, 1, 3);
    send_ifmap(0, 4);
    op_mask[0] = 1; op_mask[1] = 1;
    op_tag = 16'h0044;
    @(negedge clk); op_valid = 1;
    do @(posedge clk); while (!op_ready);
    @(negedge clk); op_valid = 0;

    reduce_tag = 16'h0044;
    repeat (3) @(negedge clk);
    reduce_start_col = 0; reduce_valid = 1;
    do @(posedge clk); while (!reduce_ready);
    @(negedge clk); reduce_valid = 0;
    while (!result_valid) @(negedge clk);
    if (result_psum[0] != 8)
      $fatal(1, "horizontal set 0 result %0d", result_psum[0]);
    @(negedge clk);

    reduce_start_col = 1; reduce_valid = 1;
    do @(posedge clk); while (!reduce_ready);
    @(negedge clk); reduce_valid = 0;
    while (!result_valid) @(negedge clk);
    if (result_col_valid != 14'h0002 || result_psum[1] != 12)
      $fatal(1, "horizontal set 1 mask=%h result=%0d",
             result_col_valid, result_psum[1]);
    if (fault || cluster_mac_count != 2)
      $fatal(1, "multi-set status fault=%0b macs=%0d",
             fault, cluster_mac_count);
    $display("ALEXNET_EYERISS_RS_MULTISET_CLUSTER_TEST_PASSED filters=2,3 shared_ifmap=4 results=8,12");
    $finish;
  end
endmodule
