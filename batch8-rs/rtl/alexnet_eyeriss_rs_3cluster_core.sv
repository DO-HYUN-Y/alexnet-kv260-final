`timescale 1ns/1ps

// Three independent 12x14 clusters: 504 architectural MAC PEs.  The packed
// ports let the processing-pass controller assign a different filter group
// to each cluster while all clusters share the same layer configuration.
module alexnet_eyeriss_rs_3cluster_core #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       cfg_valid,
  input  logic [5:0]                 cfg_p,
  input  logic [3:0]                 cfg_q,
  input  logic [3:0]                 cfg_s,
  input  logic [3:0]                 cfg_filter_r,
  input  logic [5:0]                 cfg_e,
  input  logic [2:0]                 cfg_stride,
  input  logic [3:0]                 cfg_set_r,
  input  logic [3:0]                 cfg_set_t,
  input  logic                       gin_cfg_valid,
  input  logic                       gin_cfg_ifmap,
  input  logic                       gin_cfg_xbus_valid,
  input  logic [3:0]                 gin_cfg_xbus_index,
  input  logic [4:0]                 gin_cfg_xbus_row_id,
  input  logic                       gin_cfg_pe_valid,
  input  logic [7:0]                 gin_cfg_pe_index,
  input  logic [5:0]                 gin_cfg_pe_col_id,
  input  logic                       gin_cfg_pe_enable,

  input  logic [2:0]                 filter_event_valid,
  output logic [2:0]                 filter_event_ready,
  input  logic [2:0][3:0]            filter_row,
  input  logic [2:0]                 filter_use_gin,
  input  logic [2:0][4:0]            filter_row_tag,
  input  logic [2:0][5:0]            filter_col_tag,
  input  logic [2:0]                 filter_use_explicit_mask,
  input  logic [2:0][167:0]          filter_explicit_mask,
  input  logic [2:0][7:0]            filter_addr,
  input  logic [2:0][7:0]            filter_value,

  input  logic [2:0]                 ifmap_event_valid,
  output logic [2:0]                 ifmap_event_ready,
  input  logic [2:0][6:0]            ifmap_row,
  input  logic [2:0]                 ifmap_use_gin,
  input  logic [2:0][4:0]            ifmap_row_tag,
  input  logic [2:0][5:0]            ifmap_col_tag,
  input  logic [2:0]                 ifmap_use_explicit_mask,
  input  logic [2:0][167:0]          ifmap_explicit_mask,
  input  logic [2:0][3:0]            ifmap_addr,
  input  logic [2:0][7:0]            ifmap_value,

  input  logic [2:0]                 op_valid,
  output logic [2:0]                 op_ready,
  input  logic [2:0][167:0]          op_mask,
  input  logic [2:0][7:0]            op_filter_addr,
  input  logic [2:0][3:0]            op_ifmap_addr,
  input  logic [2:0][4:0]            op_psum_addr,
  input  logic [2:0]                 op_first,
  input  logic [2:0]                 op_last,
  input  logic [2:0][TAG_W-1:0]      op_tag,

  input  logic [2:0]                 reduce_valid,
  output logic [2:0]                 reduce_ready,
  input  logic [2:0][3:0]            reduce_rows,
  input  logic [2:0][3:0]            reduce_cols,
  input  logic [2:0][3:0]            reduce_start_row,
  input  logic [2:0][3:0]            reduce_start_col,
  input  logic [2:0][TAG_W-1:0]      reduce_tag,
  output logic [2:0]                 result_valid,
  input  logic [2:0]                 result_ready,
  output logic [2:0][13:0]           result_col_valid,
  output logic signed [31:0]         result_psum [0:2][0:13],
  output logic [2:0][TAG_W-1:0]      result_tag,

  output logic [2:0][8:0]            active_pes,
  output logic [2:0]                 cluster_fault,
  output logic [63:0]                total_mac_count,
  output logic [31:0]                total_local_psum_hops
);

  logic [63:0] cluster_mac_count [0:2];
  logic [31:0] cluster_psum_hops [0:2];

  generate
    for (genvar c = 0; c < 3; c = c + 1) begin : g_cluster
      alexnet_eyeriss_rs_cluster #(.TAG_W(TAG_W)) u_cluster (
        .clk,
        .rst,
        .cfg_valid,
        .cfg_p,
        .cfg_q,
        .cfg_s,
        .cfg_filter_r,
        .cfg_e,
        .cfg_stride,
        .cfg_set_r,
        .cfg_set_t,
        .gin_cfg_valid,
        .gin_cfg_ifmap,
        .gin_cfg_xbus_valid,
        .gin_cfg_xbus_index,
        .gin_cfg_xbus_row_id,
        .gin_cfg_pe_valid,
        .gin_cfg_pe_index,
        .gin_cfg_pe_col_id,
        .gin_cfg_pe_enable,
        .filter_event_valid(filter_event_valid[c]),
        .filter_event_ready(filter_event_ready[c]),
        .filter_row(filter_row[c]),
        .filter_use_gin(filter_use_gin[c]),
        .filter_row_tag(filter_row_tag[c]),
        .filter_col_tag(filter_col_tag[c]),
        .filter_use_explicit_mask(filter_use_explicit_mask[c]),
        .filter_explicit_mask(filter_explicit_mask[c]),
        .filter_addr(filter_addr[c]),
        .filter_value(filter_value[c]),
        .ifmap_event_valid(ifmap_event_valid[c]),
        .ifmap_event_ready(ifmap_event_ready[c]),
        .ifmap_row(ifmap_row[c]),
        .ifmap_use_gin(ifmap_use_gin[c]),
        .ifmap_row_tag(ifmap_row_tag[c]),
        .ifmap_col_tag(ifmap_col_tag[c]),
        .ifmap_use_explicit_mask(ifmap_use_explicit_mask[c]),
        .ifmap_explicit_mask(ifmap_explicit_mask[c]),
        .ifmap_addr(ifmap_addr[c]),
        .ifmap_value(ifmap_value[c]),
        .op_valid(op_valid[c]),
        .op_ready(op_ready[c]),
        .op_mask(op_mask[c]),
        .op_filter_addr(op_filter_addr[c]),
        .op_ifmap_addr(op_ifmap_addr[c]),
        .op_psum_addr(op_psum_addr[c]),
        .op_first(op_first[c]),
        .op_last(op_last[c]),
        .op_tag(op_tag[c]),
        .reduce_valid(reduce_valid[c]),
        .reduce_ready(reduce_ready[c]),
        .reduce_rows(reduce_rows[c]),
        .reduce_cols(reduce_cols[c]),
        .reduce_start_row(reduce_start_row[c]),
        .reduce_start_col(reduce_start_col[c]),
        .reduce_tag(reduce_tag[c]),
        .result_valid(result_valid[c]),
        .result_ready(result_ready[c]),
        .result_col_valid(result_col_valid[c]),
        .result_psum(result_psum[c]),
        .result_tag(result_tag[c]),
        .active_pes(active_pes[c]),
        .fault(cluster_fault[c]),
        .cluster_mac_count(cluster_mac_count[c]),
        .local_psum_hops(cluster_psum_hops[c])
      );
    end
  endgenerate

  always_comb begin
    total_mac_count = cluster_mac_count[0] + cluster_mac_count[1] +
                      cluster_mac_count[2];
    total_local_psum_hops = cluster_psum_hops[0] + cluster_psum_hops[1] +
                            cluster_psum_hops[2];
  end

endmodule
