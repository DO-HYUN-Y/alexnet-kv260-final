`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_glb;
  logic clk = 0;
  logic rst = 1;
  logic cfg_valid, cfg_ready;
  logic [4:0] cfg_bank;
  logic [1:0] cfg_role;
  logic if_req_valid, if_req_ready, if_req_write;
  logic [14:0] if_req_addr;
  logic [31:0] if_req_wdata;
  logic [3:0] if_req_wstrb;
  logic if_rsp_valid, if_rsp_ready;
  logic [31:0] if_rsp_rdata;
  logic ps_req_valid, ps_req_ready, ps_req_write;
  logic [14:0] ps_req_addr;
  logic [31:0] ps_req_wdata;
  logic [3:0] ps_req_wstrb;
  logic ps_rsp_valid, ps_rsp_ready;
  logic [31:0] ps_rsp_rdata;
  logic [1:0] bank_role [0:31];
  logic fault;
  logic [31:0] ifmap_read_bytes, ifmap_write_bytes;
  logic [31:0] psum_read_bytes, psum_write_bytes;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_glb dut (.*);

  task automatic config_bank(input int bank, input int role);
    @(negedge clk);
    cfg_valid = 1;
    cfg_bank = bank;
    cfg_role = role;
    do @(posedge clk); while (!cfg_ready);
    @(negedge clk);
    cfg_valid = 0;
  endtask

  initial begin
    cfg_valid = 0; cfg_bank = 0; cfg_role = 0;
    if_req_valid = 0; if_req_write = 0; if_req_addr = 0;
    if_req_wdata = 0; if_req_wstrb = 0; if_rsp_ready = 1;
    ps_req_valid = 0; ps_req_write = 0; ps_req_addr = 0;
    ps_req_wdata = 0; ps_req_wstrb = 0; ps_rsp_ready = 1;
    repeat (5) @(negedge clk);
    rst = 0;
    config_bank(0, 1);
    config_bank(1, 2);

    @(negedge clk);
    if_req_valid = 1; if_req_write = 1; if_req_addr = 15'h0003;
    if_req_wdata = 32'h11223344; if_req_wstrb = 4'hf;
    ps_req_valid = 1; ps_req_write = 1; ps_req_addr = 15'h0405;
    ps_req_wdata = 32'ha5a55a5a; ps_req_wstrb = 4'hf;
    do @(posedge clk); while (!if_req_ready || !ps_req_ready);
    @(negedge clk);
    if_req_valid = 0; ps_req_valid = 0;

    @(negedge clk);
    if_req_valid = 1; if_req_write = 0; if_req_addr = 15'h0003;
    ps_req_valid = 1; ps_req_write = 0; ps_req_addr = 15'h0405;
    do @(posedge clk); while (!if_req_ready || !ps_req_ready);
    @(negedge clk);
    if_req_valid = 0; ps_req_valid = 0;
    while (!if_rsp_valid || !ps_rsp_valid) @(negedge clk);
    if (if_rsp_rdata != 32'h11223344 || ps_rsp_rdata != 32'ha5a55a5a)
      $fatal(1, "GLB data mismatch if=%h ps=%h", if_rsp_rdata, ps_rsp_rdata);
    if (fault) $fatal(1, "GLB faulted");
    if (ifmap_write_bytes != 4 || ifmap_read_bytes != 4 ||
        psum_write_bytes != 4 || psum_read_bytes != 4)
      $fatal(1, "GLB counters mismatch");
    $display("ALEXNET_EYERISS_RS_GLB_TEST_PASSED capacity_bytes=131072 ifmap_bytes=%0d psum_bytes=%0d",
             ifmap_read_bytes + ifmap_write_bytes,
             psum_read_bytes + psum_write_bytes);
    $finish;
  end
endmodule
