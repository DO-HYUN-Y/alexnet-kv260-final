`timescale 1ns/1ps

// One paper-shaped 12x14 Eyeriss RS cluster.  Every PE owns a logical
// filter/ifmap/psum RF.  On FPGA, nine logical filter RFs are packed into one
// 72-bit BRAM bank with byte write enables.  This preserves independent PE
// contents for multiple simultaneous PE sets without a central feature-map
// line buffer.  Completed primitives reduce through the vertical local psum
// network.
module alexnet_eyeriss_rs_cluster #(
  parameter int TAG_W = 16
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic                 cfg_valid,
  input  logic [5:0]           cfg_p,
  input  logic [3:0]           cfg_q,
  input  logic [3:0]           cfg_s,
  input  logic [3:0]           cfg_filter_r,
  input  logic [5:0]           cfg_e,
  input  logic [2:0]           cfg_stride,
  input  logic [3:0]           cfg_set_r,
  input  logic [3:0]           cfg_set_t,

  input  logic                 gin_cfg_valid,
  input  logic                 gin_cfg_ifmap,
  input  logic                 gin_cfg_xbus_valid,
  input  logic [3:0]           gin_cfg_xbus_index,
  input  logic [4:0]           gin_cfg_xbus_row_id,
  input  logic                 gin_cfg_pe_valid,
  input  logic [7:0]           gin_cfg_pe_index,
  input  logic [5:0]           gin_cfg_pe_col_id,
  input  logic                 gin_cfg_pe_enable,

  input  logic                 filter_event_valid,
  output logic                 filter_event_ready,
  input  logic [3:0]           filter_row,
  input  logic                 filter_use_gin,
  input  logic [4:0]           filter_row_tag,
  input  logic [5:0]           filter_col_tag,
  input  logic                 filter_use_explicit_mask,
  input  logic [167:0]         filter_explicit_mask,
  input  logic [7:0]           filter_addr,
  input  logic signed [7:0]    filter_value,

  input  logic                 ifmap_event_valid,
  output logic                 ifmap_event_ready,
  input  logic [6:0]           ifmap_row,
  input  logic                 ifmap_use_gin,
  input  logic [4:0]           ifmap_row_tag,
  input  logic [5:0]           ifmap_col_tag,
  input  logic                 ifmap_use_explicit_mask,
  input  logic [167:0]         ifmap_explicit_mask,
  input  logic [3:0]           ifmap_addr,
  input  logic signed [7:0]    ifmap_value,

  input  logic                 op_valid,
  output logic                 op_ready,
  input  logic [167:0]         op_mask,
  input  logic [7:0]           op_filter_addr,
  input  logic [3:0]           op_ifmap_addr,
  input  logic [4:0]           op_psum_addr,
  input  logic                 op_first,
  input  logic                 op_last,
  input  logic [TAG_W-1:0]     op_tag,

  input  logic                 reduce_valid,
  output logic                 reduce_ready,
  input  logic [3:0]           reduce_rows,
  input  logic [3:0]           reduce_cols,
  input  logic [3:0]           reduce_start_row,
  input  logic [3:0]           reduce_start_col,
  input  logic [TAG_W-1:0]     reduce_tag,
  output logic                 result_valid,
  input  logic                 result_ready,
  output logic [13:0]          result_col_valid,
  output logic signed [31:0]   result_psum [0:13],
  output logic [TAG_W-1:0]     result_tag,

  output logic [8:0]           active_pes,
  output logic                 fault,
  output logic [63:0]          cluster_mac_count,
  output logic [31:0]          local_psum_hops
);

  logic [167:0] selected_filter_mask;
  logic [167:0] selected_ifmap_mask;
  logic [167:0] gin_filter_valid;
  logic [167:0] gin_ifmap_valid;
  logic gin_filter_ready;
  logic gin_ifmap_ready;
  logic gin_filter_fault;
  logic gin_ifmap_fault;
  logic [8:0] gin_filter_count;
  logic [8:0] gin_ifmap_count;
  logic gin_filter_data_unused;
  logic gin_ifmap_data_unused;
  logic [167:0] pe_filter_ready;
  logic [167:0] pe_ifmap_ready;
  logic [167:0] pe_op_ready;
  logic [167:0] pe_result_valid;
  logic [167:0] pe_result_ready;
  logic signed [31:0] pe_result_psum [0:167];
  logic [TAG_W-1:0] pe_result_tag [0:167];
  logic route_fault;
  logic config_supported;
  logic [12:0] active_product;

  logic [167:0] filter_load_mask;
  logic filter_storage_ready;
  logic filter_addr_valid;
  logic ifmap_addr_valid;
  logic op_addr_valid;
  logic signed [7:0] filter_read_data [0:167];
  logic op_pipe_valid;
  logic [167:0] op_pipe_mask;
  logic [3:0] op_pipe_ifmap_addr;
  logic [4:0] op_pipe_psum_addr;
  logic op_pipe_first;
  logic op_pipe_last;
  logic [TAG_W-1:0] op_pipe_tag;
  logic op_dispatch_ready;
  logic op_accept;

  assign active_product = cfg_filter_r * cfg_e * cfg_set_r * cfg_set_t;
  assign config_supported = (cfg_p >= 1) && (cfg_p <= 24) &&
                            (cfg_q >= 1) && (cfg_q <= 4) &&
                            (cfg_s >= 1) && (cfg_s <= 11) &&
                            ((cfg_p * cfg_q * cfg_s) <= 224) &&
                            ((cfg_q * cfg_s) <= 12) &&
                            (cfg_filter_r >= 1) && (cfg_filter_r <= 12) &&
                            (cfg_e >= 1) && (cfg_e <= 27) &&
                            (cfg_stride >= 1) && (cfg_stride <= 4) &&
                            (cfg_set_r >= 1) && (cfg_set_t >= 1) &&
                            (active_product <= 168) &&
                            (((cfg_e > 14) && (cfg_set_r == 1) &&
                              (cfg_set_t == 1) &&
                              ((cfg_filter_r << 1) <= 12)) ||
                             ((cfg_e <= 14) &&
                              ((((cfg_filter_r * cfg_set_r) <= 12) &&
                                ((cfg_e * cfg_set_t) <= 14)) ||
                               ((cfg_filter_r * cfg_set_r * cfg_set_t) <= 12))));
  assign active_pes = config_supported ? active_product[8:0] : '0;
  assign route_fault = cfg_valid && !config_supported;

  // Production traffic uses the configurable GIN.  Explicit masks remain
  // available for directed tests and specialized control sequences.
  assign selected_filter_mask = filter_explicit_mask;
  assign selected_ifmap_mask = ifmap_explicit_mask;
  assign filter_addr_valid = (filter_addr < 8'd224);
  assign ifmap_addr_valid = (ifmap_addr < 4'd12);
  assign op_addr_valid = (op_filter_addr < 8'd224) &&
                         (op_ifmap_addr < 4'd12) &&
                         (op_psum_addr < 5'd24);
  assign filter_storage_ready = filter_addr_valid;
  assign pe_filter_ready = {168{filter_storage_ready}};
  assign filter_event_ready = filter_use_gin ? gin_filter_ready :
                              filter_use_explicit_mask && filter_addr_valid &&
                              &(~selected_filter_mask | pe_filter_ready);
  assign ifmap_event_ready = ifmap_use_gin ? gin_ifmap_ready :
                             ifmap_use_explicit_mask && ifmap_addr_valid &&
                             &(~selected_ifmap_mask | pe_ifmap_ready);
  assign op_dispatch_ready = &(~op_pipe_mask | pe_op_ready);
  assign op_ready = op_addr_valid &&
                    (!op_pipe_valid || op_dispatch_ready);
  assign op_accept = op_valid && op_ready;

  assign filter_load_mask = filter_use_gin ? gin_filter_valid :
                            ({168{filter_event_valid && filter_event_ready}} &
                             selected_filter_mask);

  // The 168 logical per-PE filter RFs share an address but retain independent
  // byte contents.  Nineteen 72-bit banks provide enough width for all PEs.
  generate
    for (genvar filter_bank = 0; filter_bank < 19;
         filter_bank = filter_bank + 1) begin : g_filter_bank
      logic [8:0] bank_write_mask;
      logic [8:0][7:0] bank_read_data;
      for (genvar filter_lane = 0; filter_lane < 9;
           filter_lane = filter_lane + 1) begin : g_filter_lane
        localparam int FILTER_PE = filter_bank * 9 + filter_lane;
        if (FILTER_PE < 168) begin : g_used
          assign bank_write_mask[filter_lane] = filter_load_mask[FILTER_PE];
          assign filter_read_data[FILTER_PE] =
            $signed(bank_read_data[filter_lane]);
        end else begin : g_unused
          assign bank_write_mask[filter_lane] = 1'b0;
        end
      end
      alexnet_eyeriss_filter_vector_bank #(.LANES(9)) u_filter_bank (
        .clk,
        .write_mask(bank_write_mask),
        .write_addr(filter_addr),
        .write_data(filter_value),
        .read_enable(op_accept),
        .read_addr(op_filter_addr),
        .read_data(bank_read_data)
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      op_pipe_valid <= 1'b0;
      op_pipe_mask <= '0;
      op_pipe_ifmap_addr <= '0;
      op_pipe_psum_addr <= '0;
      op_pipe_first <= 1'b0;
      op_pipe_last <= 1'b0;
      op_pipe_tag <= '0;
    end else begin
      if (!op_pipe_valid || op_dispatch_ready)
        op_pipe_valid <= op_accept;
      if (op_accept) begin
        op_pipe_mask <= op_mask;
        op_pipe_ifmap_addr <= op_ifmap_addr;
        op_pipe_psum_addr <= op_psum_addr;
        op_pipe_first <= op_first;
        op_pipe_last <= op_last;
        op_pipe_tag <= op_tag;
      end
    end
  end

  alexnet_eyeriss_rs_gin #(.DATA_W(1)) u_filter_gin (
    .clk,
    .rst,
    .cfg_xbus_valid(gin_cfg_valid && !gin_cfg_ifmap && gin_cfg_xbus_valid),
    .cfg_xbus_index(gin_cfg_xbus_index),
    .cfg_xbus_row_id(gin_cfg_xbus_row_id),
    .cfg_pe_valid(gin_cfg_valid && !gin_cfg_ifmap && gin_cfg_pe_valid),
    .cfg_pe_index(gin_cfg_pe_index),
    .cfg_pe_col_id(gin_cfg_pe_col_id),
    .cfg_pe_enable(gin_cfg_pe_enable),
    .event_valid(filter_event_valid && filter_use_gin),
    .event_ready(gin_filter_ready),
    .event_row_tag(filter_row_tag),
    .event_col_tag(filter_col_tag),
    .event_data(1'b0),
    .dest_valid(gin_filter_valid),
    .dest_ready(pe_filter_ready),
    .dest_data(gin_filter_data_unused),
    .multicast_count(gin_filter_count),
    .fault(gin_filter_fault)
  );

  alexnet_eyeriss_rs_gin #(.DATA_W(1)) u_ifmap_gin (
    .clk,
    .rst,
    .cfg_xbus_valid(gin_cfg_valid && gin_cfg_ifmap && gin_cfg_xbus_valid),
    .cfg_xbus_index(gin_cfg_xbus_index),
    .cfg_xbus_row_id(gin_cfg_xbus_row_id),
    .cfg_pe_valid(gin_cfg_valid && gin_cfg_ifmap && gin_cfg_pe_valid),
    .cfg_pe_index(gin_cfg_pe_index),
    .cfg_pe_col_id(gin_cfg_pe_col_id),
    .cfg_pe_enable(gin_cfg_pe_enable),
    .event_valid(ifmap_event_valid && ifmap_use_gin),
    .event_ready(gin_ifmap_ready),
    .event_row_tag(ifmap_row_tag),
    .event_col_tag(ifmap_col_tag),
    .event_data(1'b0),
    .dest_valid(gin_ifmap_valid),
    .dest_ready(pe_ifmap_ready & {168{ifmap_addr_valid}}),
    .dest_data(gin_ifmap_data_unused),
    .multicast_count(gin_ifmap_count),
    .fault(gin_ifmap_fault)
  );

  logic local_reduce_ready;
  logic local_reduce_busy;
  logic local_reduce_fault;
  logic [167:0] reduce_row_valid;
  assign reduce_row_valid = pe_result_valid;
  assign reduce_ready = local_reduce_ready;
  // Keep each PE result stable while the local token walks upward.  A cluster
  // can contain several PE sets, so accepting one reduced set must release
  // only the selected physical row/column window.
  integer ready_row;
  integer ready_col;
  always_comb begin
    pe_result_ready = '0;
    if (result_valid && result_ready) begin
      for (ready_row = 0; ready_row < 12; ready_row = ready_row + 1)
        for (ready_col = 0; ready_col < 14; ready_col = ready_col + 1)
          if ((ready_row >= reduce_start_row) &&
              (ready_row < (reduce_start_row + reduce_rows)) &&
              (ready_col >= reduce_start_col) &&
              (ready_col < (reduce_start_col + reduce_cols))) begin
            pe_result_ready[ready_row * 14 + ready_col] = 1'b1;
          end
    end
  end

  alexnet_eyeriss_rs_local_psum_network #(.TAG_W(TAG_W)) u_local_psum (
    .clk,
    .rst,
    .cfg_rows(reduce_rows),
    .cfg_cols(reduce_cols),
    .cfg_start_row(reduce_start_row),
    .cfg_start_col(reduce_start_col),
    .launch_valid(reduce_valid),
    .launch_ready(local_reduce_ready),
    .launch_tag(reduce_tag),
    .row_valid(reduce_row_valid),
    .row_psum(pe_result_psum),
    .output_valid(result_valid),
    .output_ready(result_ready),
    .output_col_valid(result_col_valid),
    .output_psum(result_psum),
    .output_tag(result_tag),
    .busy(local_reduce_busy),
    .fault(local_reduce_fault),
    .hop_count(local_psum_hops)
  );

  generate
    for (genvar pe = 0; pe < 168; pe = pe + 1) begin : g_pe
      alexnet_eyeriss_rs_mac_pe #(.TAG_W(TAG_W)) u_pe (
        .clk,
        .rst,
        .ifmap_load_valid(ifmap_use_gin ? gin_ifmap_valid[pe] :
                          (ifmap_event_valid && ifmap_event_ready &&
                           selected_ifmap_mask[pe])),
        .ifmap_load_ready(pe_ifmap_ready[pe]),
        .ifmap_load_addr(ifmap_addr),
        .ifmap_load_value(ifmap_value),
        .op_valid(op_pipe_valid && op_dispatch_ready && op_pipe_mask[pe]),
        .op_ready(pe_op_ready[pe]),
        .filter_operand(filter_read_data[pe]),
        .op_ifmap_addr(op_pipe_ifmap_addr),
        .op_psum_addr(op_pipe_psum_addr),
        .op_first(op_pipe_first),
        .op_last(op_pipe_last),
        .op_tag(op_pipe_tag),
        .result_valid(pe_result_valid[pe]),
        .result_ready(pe_result_ready[pe]),
        .result_psum(pe_result_psum[pe]),
        .result_tag(pe_result_tag[pe])
      );
    end
  endgenerate

  function automatic [8:0] countones168(input logic [167:0] value);
    integer i;
    begin
      countones168 = '0;
      for (i = 0; i < 168; i = i + 1)
        countones168 = countones168 + value[i];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      cluster_mac_count <= '0;
      fault <= 1'b0;
    end else begin
      if (op_pipe_valid && op_dispatch_ready)
        cluster_mac_count <= cluster_mac_count + countones168(op_pipe_mask);
      if (route_fault || local_reduce_fault || gin_filter_fault ||
          gin_ifmap_fault)
        fault <= 1'b1;
    end
  end

endmodule
