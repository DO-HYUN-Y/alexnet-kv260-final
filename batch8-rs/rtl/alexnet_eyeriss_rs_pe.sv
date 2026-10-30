`timescale 1ns/1ps

// Eyeriss-style row-stationary processing element.
//
// A PE owns three logically independent scratchpads, matching Fig. 12 of the
// paper.  A 1-D convolution primitive keeps one filter row and one sliding
// ifmap window local while an INT32 partial sum remains in the psum SPad.
// The storage dimensions are the paper dimensions expressed in INT8/INT32:
//   filter: 224 x 8, ifmap: 12 x 8, psum: 24 x 32.
module alexnet_eyeriss_rs_pe #(
  parameter int TAG_W = 16
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic                 cfg_valid,
  input  logic [5:0]           cfg_p,
  input  logic [3:0]           cfg_q,
  input  logic [3:0]           cfg_s,
  output logic                 configured,

  input  logic                 filter_load_valid,
  output logic                 filter_load_ready,
  input  logic [7:0]           filter_load_addr,
  input  logic signed [7:0]    filter_load_value,

  input  logic                 ifmap_load_valid,
  output logic                 ifmap_load_ready,
  input  logic [3:0]           ifmap_load_addr,
  input  logic signed [7:0]    ifmap_load_value,

  input  logic                 psum_load_valid,
  output logic                 psum_load_ready,
  input  logic [4:0]           psum_load_addr,
  input  logic signed [31:0]   psum_load_value,

  input  logic                 op_valid,
  output logic                 op_ready,
  input  logic [7:0]           op_filter_addr,
  input  logic [3:0]           op_ifmap_addr,
  input  logic [4:0]           op_psum_addr,
  input  logic                 op_first,
  input  logic                 op_last,
  input  logic [TAG_W-1:0]     op_tag,

  output logic                 result_valid,
  input  logic                 result_ready,
  output logic signed [31:0]   result_psum,
  output logic [TAG_W-1:0]     result_tag,

  output logic                 fault,
  output logic [31:0]          mac_count,
  output logic [31:0]          filter_spad_reads,
  output logic [31:0]          ifmap_spad_reads,
  output logic [31:0]          psum_spad_reads,
  output logic [31:0]          psum_spad_writes
);

  (* ram_style = "distributed" *) logic signed [7:0] filter_spad [0:223];
  (* ram_style = "distributed" *) logic signed [7:0] ifmap_spad  [0:11];
  (* ram_style = "distributed" *) logic signed [31:0] psum_spad [0:23];

  logic [5:0] p_q;
  logic [3:0] q_q;
  logic [3:0] s_q;
  logic config_ok;

  logic op_fire;
  logic signed [26:0] mult_a;
  logic signed [17:0] mult_b;
  (* use_dsp = "yes" *) logic signed [44:0] mult_reg;
  logic                 pipe_valid;
  logic                 pipe_last;
  logic [4:0]           pipe_psum_addr;
  logic [TAG_W-1:0]     pipe_tag;
  logic signed [31:0]   pipe_base_psum;
  (* use_dsp = "no" *) logic signed [31:0] pipe_accumulated;
  logic signed [31:0]   op_base_psum;
  logic                 psum_load_fire;

  assign config_ok = (cfg_p >= 1) && (cfg_p <= 24) &&
                     (cfg_q >= 1) && (cfg_q <= 4) &&
                     (cfg_s >= 1) && (cfg_s <= 11) &&
                     ((cfg_p * cfg_q * cfg_s) <= 224) &&
                     ((cfg_q * cfg_s) <= 12) &&
                     (cfg_p <= 24);

  assign filter_load_ready = configured && !result_valid &&
                             (filter_load_addr < 8'd224);
  assign ifmap_load_ready = configured && !result_valid &&
                            (ifmap_load_addr < 4'd12);
  assign psum_load_ready = configured && !result_valid && !op_valid &&
                           !pipe_valid &&
                           (psum_load_addr < 5'd24);
  assign op_ready = configured && !psum_load_valid &&
                    (!result_valid || result_ready) &&
                    !(pipe_valid && pipe_last) &&
                    (op_filter_addr < 8'd224) &&
                    (op_ifmap_addr < 4'd12) &&
                    (op_psum_addr < 5'd24);
  assign op_fire = op_valid && op_ready;

  assign psum_load_fire = psum_load_valid && psum_load_ready;

  // The registered 27x18 multiply is the DSP48E2 boundary.  The following
  // INT32 add writes the local psum SPad.  A one-entry forwarding path keeps
  // consecutive MACs to the same psum address at one operation per cycle.
  always_comb begin
    mult_a = {{19{filter_spad[op_filter_addr][7]}},
              filter_spad[op_filter_addr]};
    mult_b = {{10{ifmap_spad[op_ifmap_addr][7]}},
              ifmap_spad[op_ifmap_addr]};
    if (op_first)
      op_base_psum = 32'sd0;
    else if (pipe_valid && (pipe_psum_addr == op_psum_addr))
      op_base_psum = pipe_accumulated;
    else
      op_base_psum = psum_spad[op_psum_addr];
    pipe_accumulated = pipe_base_psum +
                       {{16{mult_reg[15]}}, mult_reg[15:0]};
  end

  // Exactly one write port is presented to the psum scratchpad.  Keeping
  // this in a dedicated process is required for LUTRAM inference.
  always_ff @(posedge clk) begin
    if (psum_load_fire)
      psum_spad[psum_load_addr] <= psum_load_value;
    else if (pipe_valid)
      psum_spad[pipe_psum_addr] <= pipe_accumulated;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      configured       <= 1'b0;
      p_q              <= '0;
      q_q              <= '0;
      s_q              <= '0;
      result_valid     <= 1'b0;
      result_psum      <= '0;
      result_tag       <= '0;
      fault            <= 1'b0;
      mac_count        <= '0;
      filter_spad_reads <= '0;
      ifmap_spad_reads <= '0;
      psum_spad_reads  <= '0;
      psum_spad_writes <= '0;
      mult_reg         <= '0;
      pipe_valid       <= 1'b0;
      pipe_last        <= 1'b0;
      pipe_psum_addr   <= '0;
      pipe_tag         <= '0;
      pipe_base_psum   <= '0;
    end else begin
      if (result_valid && result_ready)
        result_valid <= 1'b0;

      // A previous operation commits while the next one enters the DSP.
      pipe_valid <= op_fire;
      if (op_fire) begin
        mult_reg       <= mult_a * mult_b;
        pipe_last      <= op_last;
        pipe_psum_addr <= op_psum_addr;
        pipe_tag       <= op_tag;
        pipe_base_psum <= op_base_psum;
        mac_count         <= mac_count + 1'b1;
        filter_spad_reads <= filter_spad_reads + 1'b1;
        ifmap_spad_reads  <= ifmap_spad_reads + 1'b1;
        psum_spad_reads   <= psum_spad_reads + 1'b1;
      end

      if (pipe_valid) begin
        psum_spad_writes <= psum_spad_writes + 1'b1;
        if (pipe_last) begin
          result_valid <= 1'b1;
          result_psum  <= pipe_accumulated;
          result_tag   <= pipe_tag;
        end
      end

      if (cfg_valid) begin
        configured <= config_ok;
        p_q        <= cfg_p;
        q_q        <= cfg_q;
        s_q        <= cfg_s;
        if (!config_ok)
          fault <= 1'b1;
      end

      if (filter_load_valid) begin
        if (filter_load_ready)
          filter_spad[filter_load_addr] <= filter_load_value;
        else
          fault <= 1'b1;
      end

      if (ifmap_load_valid) begin
        if (ifmap_load_ready)
          ifmap_spad[ifmap_load_addr] <= ifmap_load_value;
        else
          fault <= 1'b1;
      end

      if (psum_load_valid) begin
        if (psum_load_ready) begin
          psum_spad_writes <= psum_spad_writes + 1'b1;
        end else begin
          fault <= 1'b1;
        end
      end

      if (op_valid && !op_ready)
        fault <= 1'b1;

    end
  end

endmodule
