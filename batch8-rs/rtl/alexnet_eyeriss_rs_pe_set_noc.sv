`timescale 1ns/1ps

// Functional routing contract for one 12x14 Eyeriss PE cluster.
// Filter rows multicast horizontally, ifmap rows multicast diagonally, and
// partial sums reduce vertically.  The physical transfer implementation is
// split into GIN/GON/local networks in the integrated core; this module is a
// compact, independently verifiable expression of the RS mapping.
module alexnet_eyeriss_rs_pe_set_noc (
  input  logic [3:0]          cfg_filter_r,
  input  logic [5:0]          cfg_e,
  input  logic [2:0]          cfg_stride,

  input  logic                filter_valid,
  input  logic [3:0]          filter_row,
  output logic [167:0]        filter_dest_valid,

  input  logic                ifmap_valid,
  input  logic [6:0]          ifmap_row,
  output logic [167:0]        ifmap_dest_valid,

  input  logic [167:0]        row_psum_valid,
  input  logic signed [31:0]  row_psum [0:167],
  output logic [26:0]         reduced_valid,
  output logic signed [31:0]  reduced_psum [0:26],

  output logic [8:0]          active_pes,
  output logic                route_fault
);

  integer pe;
  integer r_idx;
  integer e_idx;
  integer active_product;
  logic signed [39:0] sum;
  logic all_valid;

  always_comb begin
    filter_dest_valid = '0;
    ifmap_dest_valid  = '0;
    reduced_valid     = '0;
    route_fault       = 1'b0;
    active_product    = 0;
    active_pes        = '0;
    sum               = '0;
    all_valid         = 1'b0;
    for (e_idx = 0; e_idx < 27; e_idx = e_idx + 1)
      reduced_psum[e_idx] = '0;

    active_product = $unsigned(cfg_filter_r) * $unsigned(cfg_e);
    if ((cfg_filter_r < 1) || (cfg_filter_r > 12) ||
        (cfg_e < 1) || (cfg_e > 27) ||
        (cfg_stride < 1) || (cfg_stride > 4) ||
        (active_product > 168) ||
        ((cfg_e > 14) && (($unsigned(cfg_filter_r) << 1) > 12))) begin
      route_fault = 1'b1;
    end else begin
      // Every mapped output row owns exactly R one-dimensional primitives.
      // Compute R*E directly instead of synthesizing a 168-stage popcount.
      active_pes = active_product[8:0];
      // A width above 14 is the paper's segmented set case (Conv2).  The
      // second segment is folded below the first one in the 12x14 cluster.
      for (pe = 0; pe < 168; pe = pe + 1) begin
        r_idx = pe / 14;
        e_idx = pe % 14;
        if (cfg_e <= 14) begin
          if ((r_idx < cfg_filter_r) && (e_idx < cfg_e)) begin
            if (filter_valid && (filter_row == r_idx[3:0]))
              filter_dest_valid[pe] = 1'b1;
            if (ifmap_valid &&
                (ifmap_row == (r_idx + e_idx * cfg_stride[2:0])))
              ifmap_dest_valid[pe] = 1'b1;
          end
        end else begin
          // Segment 0: rows [0,R), output rows [0,14).
          // Segment 1: rows [R,2R), output rows [14,E).
          if ((r_idx < cfg_filter_r) && (e_idx < 14)) begin
            if (filter_valid && (filter_row == r_idx[3:0]))
              filter_dest_valid[pe] = 1'b1;
            if (ifmap_valid &&
                (ifmap_row == (r_idx + e_idx * cfg_stride[2:0])))
              ifmap_dest_valid[pe] = 1'b1;
          end else if ((r_idx >= cfg_filter_r) &&
                       (r_idx < (cfg_filter_r << 1)) &&
                       (e_idx < (cfg_e - 14))) begin
            if (filter_valid &&
                (filter_row == (r_idx - $unsigned(cfg_filter_r))))
              filter_dest_valid[pe] = 1'b1;
            if (ifmap_valid &&
                (ifmap_row == ((r_idx - $unsigned(cfg_filter_r)) +
                               (e_idx + 14) * cfg_stride)))
              ifmap_dest_valid[pe] = 1'b1;
          end
        end
      end

      // Functional equivalent of the vertical local psum network.  Each
      // output row is valid only when every filter row in its segment has a
      // contribution.  The integrated network pipelines the same reduction
      // one neighbor hop at a time.
      for (e_idx = 0; e_idx < 27; e_idx = e_idx + 1) begin
        sum = '0;
        all_valid = 1'b1;
        if (e_idx < cfg_e) begin
          for (r_idx = 0; r_idx < 12; r_idx = r_idx + 1) begin
            if (r_idx < cfg_filter_r) begin
              if (e_idx < 14)
                pe = r_idx * 14 + e_idx;
              else
                pe = (r_idx + cfg_filter_r) * 14 + (e_idx - 14);
              if ((pe >= 0) && (pe < 168)) begin
                all_valid = all_valid && row_psum_valid[pe];
                sum = sum + row_psum[pe];
              end else begin
                all_valid = 1'b0;
              end
            end
          end
          reduced_valid[e_idx] = all_valid;
          reduced_psum[e_idx] = sum[31:0];
        end
      end
    end
  end

endmodule
