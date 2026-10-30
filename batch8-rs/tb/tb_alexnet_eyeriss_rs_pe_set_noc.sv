`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_pe_set_noc;
  logic [3:0] cfg_filter_r;
  logic [5:0] cfg_e;
  logic [2:0] cfg_stride;
  logic filter_valid;
  logic [3:0] filter_row;
  logic [167:0] filter_dest_valid;
  logic ifmap_valid;
  logic [6:0] ifmap_row;
  logic [167:0] ifmap_dest_valid;
  logic [167:0] row_psum_valid;
  logic signed [31:0] row_psum [0:167];
  logic [26:0] reduced_valid;
  logic signed [31:0] reduced_psum [0:26];
  logic [8:0] active_pes;
  logic route_fault;

  alexnet_eyeriss_rs_pe_set_noc dut (.*);

  initial begin
    cfg_filter_r = 3;
    cfg_e = 3;
    cfg_stride = 1;
    filter_valid = 1;
    filter_row = 1;
    ifmap_valid = 1;
    ifmap_row = 2;
    row_psum_valid = '0;
    for (int i = 0; i < 168; i++) row_psum[i] = 0;
    #1;
    if (route_fault || active_pes != 9)
      $fatal(1, "basic mapping active=%0d fault=%0b", active_pes, route_fault);
    if ($countones(filter_dest_valid) != 3 ||
        !filter_dest_valid[14] || !filter_dest_valid[15] || !filter_dest_valid[16])
      $fatal(1, "horizontal filter multicast mismatch");
    if ($countones(ifmap_dest_valid) != 3 ||
        !ifmap_dest_valid[2] || !ifmap_dest_valid[15] || !ifmap_dest_valid[28])
      $fatal(1, "diagonal ifmap multicast mismatch");

    for (int r = 0; r < 3; r++) begin
      for (int e = 0; e < 3; e++) begin
        row_psum_valid[r*14+e] = 1;
        row_psum[r*14+e] = r + 1;
      end
    end
    #1;
    for (int e = 0; e < 3; e++) begin
      if (!reduced_valid[e] || reduced_psum[e] != 6)
        $fatal(1, "vertical psum reduction mismatch col=%0d value=%0d", e, reduced_psum[e]);
    end

    // Conv2 paper mapping: 5x27 set folded as 5x14 + 5x13.
    cfg_filter_r = 5;
    cfg_e = 27;
    filter_row = 4;
    ifmap_valid = 0;
    #1;
    if (route_fault || active_pes != 135)
      $fatal(1, "segmented mapping active=%0d fault=%0b", active_pes, route_fault);
    if ($countones(filter_dest_valid) != 27)
      $fatal(1, "segmented filter fanout %0d", $countones(filter_dest_valid));

    $display("ALEXNET_EYERISS_RS_PE_SET_NOC_TEST_PASSED active_pes=%0d filter_fanout=%0d",
             active_pes, $countones(filter_dest_valid));
    $finish;
  end
endmodule
