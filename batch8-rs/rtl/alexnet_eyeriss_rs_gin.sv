`timescale 1ns/1ps

// Configurable two-level multicast Global Input Network (GIN), following
// Fig. 10.  Twelve X-buses carry a row ID and every PE carries a column ID.
// A tagged datum reaches all and only enabled PEs whose two IDs match.
module alexnet_eyeriss_rs_gin #(
  parameter int DATA_W = 32,
  parameter int ROW_ID_W = 5,
  parameter int COL_ID_W = 6
) (
  input  logic                       clk,
  input  logic                       rst,

  input  logic                       cfg_xbus_valid,
  input  logic [3:0]                 cfg_xbus_index,
  input  logic [ROW_ID_W-1:0]        cfg_xbus_row_id,
  input  logic                       cfg_pe_valid,
  input  logic [7:0]                 cfg_pe_index,
  input  logic [COL_ID_W-1:0]        cfg_pe_col_id,
  input  logic                       cfg_pe_enable,

  input  logic                       event_valid,
  output logic                       event_ready,
  input  logic [ROW_ID_W-1:0]        event_row_tag,
  input  logic [COL_ID_W-1:0]        event_col_tag,
  input  logic [DATA_W-1:0]          event_data,
  output logic [167:0]               dest_valid,
  input  logic [167:0]               dest_ready,
  output logic [DATA_W-1:0]          dest_data,

  output logic [8:0]                 multicast_count,
  output logic                       fault
);

  logic [ROW_ID_W-1:0] xbus_row_id [0:11];
  logic [COL_ID_W-1:0] pe_col_id [0:167];
  logic [167:0] pe_enable;
  logic [167:0] match_mask;
  logic any_match;
  logic all_ready;

  integer pe;
  integer row;
  integer count;
  always_comb begin
    match_mask = '0;
    count = 0;
    for (pe = 0; pe < 168; pe = pe + 1) begin
      row = pe / 14;
      if (pe_enable[pe] &&
          (xbus_row_id[row] == event_row_tag) &&
          (pe_col_id[pe] == event_col_tag)) begin
        match_mask[pe] = 1'b1;
        count = count + 1;
      end
    end
    any_match = |match_mask;
    all_ready = &(~match_mask | dest_ready);
    event_ready = any_match && all_ready;
    dest_valid = {168{event_valid && event_ready}} & match_mask;
    dest_data = event_data;
    multicast_count = count[8:0];
  end

  integer idx;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (idx = 0; idx < 12; idx = idx + 1)
        xbus_row_id[idx] <= {ROW_ID_W{1'b1}};
      for (idx = 0; idx < 168; idx = idx + 1) begin
        pe_col_id[idx] <= {COL_ID_W{1'b1}};
        pe_enable[idx] <= 1'b0;
      end
      fault <= 1'b0;
    end else begin
      if (cfg_xbus_valid) begin
        if (cfg_xbus_index < 12)
          xbus_row_id[cfg_xbus_index] <= cfg_xbus_row_id;
        else
          fault <= 1'b1;
      end
      if (cfg_pe_valid) begin
        if (cfg_pe_index < 168) begin
          pe_col_id[cfg_pe_index] <= cfg_pe_col_id;
          pe_enable[cfg_pe_index] <= cfg_pe_enable;
        end else begin
          fault <= 1'b1;
        end
      end
      if (event_valid && !any_match)
        fault <= 1'b1;
    end
  end

endmodule
