`timescale 1ns/1ps

// Nine logical PE filter RFs packed into one 72-bit-wide BRAM bank.  All PEs
// use the same RF address in a cycle, while byte write enables preserve the
// independent contents required by multiple simultaneous PE sets.
module alexnet_eyeriss_filter_vector_bank #(
  parameter int LANES = 9
) (
  input  logic                         clk,
  input  logic [LANES-1:0]             write_mask,
  input  logic [7:0]                   write_addr,
  input  logic signed [7:0]            write_data,
  input  logic                         read_enable,
  input  logic [7:0]                   read_addr,
  output logic [LANES-1:0][7:0]        read_data
);

  (* ram_style = "block" *)
  logic [LANES*8-1:0] mem [0:223];

  integer lane;
  always_ff @(posedge clk) begin
    for (lane = 0; lane < LANES; lane = lane + 1)
      if (write_mask[lane])
        mem[write_addr][lane*8 +: 8] <= write_data;
    if (read_enable)
      read_data <= mem[read_addr];
  end

endmodule
