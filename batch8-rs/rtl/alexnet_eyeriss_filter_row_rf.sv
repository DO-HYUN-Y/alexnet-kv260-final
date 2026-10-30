`timescale 1ns/1ps

// One 224-byte row-local filter RF.  Keeping the memory in its own module
// gives synthesis an unambiguous single-write/asynchronous-read RAM pattern.
module alexnet_eyeriss_filter_row_rf (
  input  logic                 clk,
  input  logic                 write_enable,
  input  logic [7:0]           write_addr,
  input  logic signed [7:0]    write_data,
  input  logic [7:0]           read_addr,
  output logic signed [7:0]    read_data
);

  (* ram_style = "distributed" *) logic signed [7:0] mem [0:223];

  always_ff @(posedge clk) begin
    if (write_enable)
      mem[write_addr] <= write_data;
  end

  assign read_data = mem[read_addr];

endmodule
