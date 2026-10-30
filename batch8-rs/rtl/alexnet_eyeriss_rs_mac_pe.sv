`timescale 1ns/1ps

// FPGA implementation of one Eyeriss RS MAC lane.
//
// The paper-level PE owns an ifmap window and a psum scratchpad.  Its logical
// filter RF is stored independently in the cluster's vector-BRAM banks, which
// allows simultaneous r x t PE sets to retain different filters without a
// centralized feature-map line buffer.
module alexnet_eyeriss_rs_mac_pe #(
  parameter int TAG_W = 16
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic                 ifmap_load_valid,
  output logic                 ifmap_load_ready,
  input  logic [3:0]           ifmap_load_addr,
  input  logic signed [7:0]    ifmap_load_value,

  input  logic                 op_valid,
  output logic                 op_ready,
  input  logic signed [7:0]    filter_operand,
  input  logic [3:0]           op_ifmap_addr,
  input  logic [4:0]           op_psum_addr,
  input  logic                 op_first,
  input  logic                 op_last,
  input  logic [TAG_W-1:0]     op_tag,

  output logic                 result_valid,
  input  logic                 result_ready,
  output logic signed [31:0]   result_psum,
  output logic [TAG_W-1:0]     result_tag
);

  (* ram_style = "distributed" *) logic signed [7:0] ifmap_spad [0:11];
  (* ram_style = "distributed" *) logic signed [31:0] psum_spad [0:23];

  logic op_fire;
  logic signed [26:0] mult_a;
  logic signed [17:0] mult_b;
  (* use_dsp = "yes" *) logic signed [47:0] mac_reg;
  logic                 pipe_valid;
  logic                 pipe_last;
  logic [4:0]           pipe_psum_addr;
  logic [TAG_W-1:0]     pipe_tag;
  logic signed [31:0]   pipe_accumulated;
  logic signed [47:0]   mac_c_operand;
  logic signed [31:0]   op_base_psum;

  // Address legality is checked once by the cluster.  Removing 504 copies
  // of those comparators is an important FPGA mapping optimization.
  assign ifmap_load_ready = !pipe_valid && !result_valid;
  assign op_ready = (!result_valid || result_ready) &&
                    !(pipe_valid && pipe_last);
  assign op_fire = op_valid && op_ready;

  assign mult_a = {{19{filter_operand[7]}}, filter_operand};
  assign mult_b = {{10{ifmap_spad[op_ifmap_addr][7]}},
                   ifmap_spad[op_ifmap_addr]};
  assign mac_c_operand = {{16{op_base_psum[31]}}, op_base_psum};
  assign pipe_accumulated = mac_reg[31:0];

  always_comb begin
    if (op_first)
      op_base_psum = 32'sd0;
    else if (pipe_valid && (pipe_psum_addr == op_psum_addr))
      op_base_psum = pipe_accumulated;
    else
      op_base_psum = psum_spad[op_psum_addr];
  end

  // One write port allows the psum RF to infer as distributed RAM.
  always_ff @(posedge clk) begin
    if (pipe_valid)
      psum_spad[pipe_psum_addr] <= pipe_accumulated;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      result_valid   <= 1'b0;
      result_psum    <= '0;
      result_tag     <= '0;
      mac_reg        <= '0;
      pipe_valid     <= 1'b0;
      pipe_last      <= 1'b0;
      pipe_psum_addr <= '0;
      pipe_tag       <= '0;
    end else begin
      if (result_valid && result_ready)
        result_valid <= 1'b0;

      if (ifmap_load_valid && ifmap_load_ready)
        ifmap_spad[ifmap_load_addr] <= ifmap_load_value;

      pipe_valid <= op_fire;
      if (op_fire) begin
        // DSP48E2 performs both the INT8 multiply and INT32 accumulation.
        // The P register is also the one-cycle forwarding value.
        mac_reg        <= mult_a * mult_b + mac_c_operand;
        pipe_last      <= op_last;
        pipe_psum_addr <= op_psum_addr;
        pipe_tag       <= op_tag;
      end

      if (pipe_valid && pipe_last) begin
        result_valid <= 1'b1;
        result_psum  <= pipe_accumulated;
        result_tag   <= pipe_tag;
      end
    end
  end

endmodule
