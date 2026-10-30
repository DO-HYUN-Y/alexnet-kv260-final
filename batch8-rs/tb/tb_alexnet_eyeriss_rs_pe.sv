`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_pe;
  logic clk = 0;
  logic rst = 1;
  logic cfg_valid;
  logic [5:0] cfg_p;
  logic [3:0] cfg_q, cfg_s;
  logic configured;
  logic filter_load_valid, filter_load_ready;
  logic [7:0] filter_load_addr;
  logic signed [7:0] filter_load_value;
  logic ifmap_load_valid, ifmap_load_ready;
  logic [3:0] ifmap_load_addr;
  logic signed [7:0] ifmap_load_value;
  logic psum_load_valid, psum_load_ready;
  logic [4:0] psum_load_addr;
  logic signed [31:0] psum_load_value;
  logic op_valid, op_ready;
  logic [7:0] op_filter_addr;
  logic [3:0] op_ifmap_addr;
  logic [4:0] op_psum_addr;
  logic op_first, op_last;
  logic [15:0] op_tag;
  logic result_valid, result_ready;
  logic signed [31:0] result_psum;
  logic [15:0] result_tag;
  logic fault;
  logic [31:0] mac_count, filter_spad_reads, ifmap_spad_reads;
  logic [31:0] psum_spad_reads, psum_spad_writes;

  always #2.5 clk = ~clk;

  alexnet_eyeriss_rs_pe dut (.*);

  task automatic load_filter(input int addr, input int value);
    @(negedge clk);
    filter_load_valid = 1;
    filter_load_addr = addr;
    filter_load_value = value;
    do @(posedge clk); while (!filter_load_ready);
    @(negedge clk);
    filter_load_valid = 0;
  endtask

  task automatic load_ifmap(input int addr, input int value);
    @(negedge clk);
    ifmap_load_valid = 1;
    ifmap_load_addr = addr;
    ifmap_load_value = value;
    do @(posedge clk); while (!ifmap_load_ready);
    @(negedge clk);
    ifmap_load_valid = 0;
  endtask

  task automatic issue_mac(input int faddr, input int iaddr,
                           input bit first, input bit last, input int tag);
    @(negedge clk);
    op_valid = 1;
    op_filter_addr = faddr;
    op_ifmap_addr = iaddr;
    op_psum_addr = 0;
    op_first = first;
    op_last = last;
    op_tag = tag;
    do @(posedge clk); while (!op_ready);
    @(negedge clk);
    op_valid = 0;
  endtask

  task automatic expect_result(input int expected, input int tag);
    while (!result_valid) @(negedge clk);
    if ($signed(result_psum) != expected || result_tag != tag)
      $fatal(1, "result mismatch got=%0d tag=%0d expected=%0d/%0d",
             $signed(result_psum), result_tag, expected, tag);
    @(posedge clk);
  endtask

  initial begin
    cfg_valid = 0;
    cfg_p = 1;
    cfg_q = 1;
    cfg_s = 3;
    filter_load_valid = 0;
    filter_load_addr = 0;
    filter_load_value = 0;
    ifmap_load_valid = 0;
    ifmap_load_addr = 0;
    ifmap_load_value = 0;
    psum_load_valid = 0;
    psum_load_addr = 0;
    psum_load_value = 0;
    op_valid = 0;
    op_filter_addr = 0;
    op_ifmap_addr = 0;
    op_psum_addr = 0;
    op_first = 0;
    op_last = 0;
    op_tag = 0;
    result_ready = 1;
    repeat (5) @(negedge clk);
    rst = 0;
    @(negedge clk);
    cfg_valid = 1;
    @(negedge clk);
    cfg_valid = 0;
    if (!configured) $fatal(1, "PE did not configure");

    load_filter(0, 1);
    load_filter(1, 2);
    load_filter(2, 3);
    for (int i = 0; i < 5; i++) load_ifmap(i, i + 1);

    for (int x = 0; x < 3; x++) begin
      issue_mac(0, x,   1, 0, x);
      issue_mac(1, x+1, 0, 0, x);
      issue_mac(2, x+2, 0, 1, x);
      expect_result(14 + 6*x, x);
    end

    if (fault) $fatal(1, "PE faulted");
    if (mac_count != 9 || filter_spad_reads != 9 || ifmap_spad_reads != 9 ||
        psum_spad_reads != 9 || psum_spad_writes != 9)
      $fatal(1, "counter mismatch mac=%0d f=%0d i=%0d pr=%0d pw=%0d",
             mac_count, filter_spad_reads, ifmap_spad_reads,
             psum_spad_reads, psum_spad_writes);
    $display("ALEXNET_EYERISS_RS_PE_TEST_PASSED outputs=14,20,26 macs=%0d", mac_count);
    $finish;
  end
endmodule
