`timescale 1ns/1ps

// Command-plane plus three-cluster pure-RS core.  Filter and ifmap source
// channels supply one byte for the currently advertised request metadata.
// Zero-fill commands bypass the source channel and are written immediately.
module alexnet_eyeriss_rs_batch8_core_top #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       start_valid,
  output logic                       start_ready,
  input  logic [TAG_W-1:0]           start_tag,

  output logic                       filter_request_valid,
  input  logic                       filter_data_valid,
  output logic                       filter_data_ready,
  input  logic signed [7:0]          filter_data,
  output logic [3:0]                 filter_request_layer,
  output logic [12:0]                filter_request_filter,
  output logic [13:0]                filter_request_channel,
  output logic [3:0]                 filter_request_y,
  output logic [3:0]                 filter_request_x,

  output logic                       ifmap_request_valid,
  input  logic                       ifmap_data_valid,
  output logic                       ifmap_data_ready,
  input  logic signed [7:0]          ifmap_data,
  output logic [3:0]                 ifmap_request_layer,
  output logic [2:0]                 ifmap_request_image,
  output logic [13:0]                ifmap_request_channel,
  output logic signed [8:0]          ifmap_request_y,
  output logic signed [8:0]          ifmap_request_x,

  output logic                       result_valid,
  input  logic                       result_ready,
  output logic [13:0]                result_col_valid,
  output logic signed [31:0]         result_psum [0:13],
  output logic [TAG_W-1:0]           result_tag,
  output logic [3:0]                 result_layer,
  output logic                       result_psum_first,
  output logic                       result_psum_final,
  output logic [13:0]                result_channel_base,
  output logic [12:0]                result_filter,
  output logic [2:0]                 result_image,
  output logic [5:0]                 result_x,
  output logic [5:0]                 result_y_base,

  output logic                       layer_complete_valid,
  input  logic                       layer_complete_ready,
  output logic [3:0]                 layer_complete_id,
  output logic                       inference_done,
  input  logic                       inference_done_ready,
  output logic                       fault,
  output logic [15:0]                completed_passes,
  output logic [63:0]                total_mac_count,
  output logic [31:0]                total_local_psum_hops
);

  logic gin_cfg_valid, gin_cfg_ifmap, gin_cfg_xbus_valid;
  logic [3:0] gin_cfg_xbus_index;
  logic [4:0] gin_cfg_xbus_row_id;
  logic gin_cfg_pe_valid;
  logic [7:0] gin_cfg_pe_index;
  logic [5:0] gin_cfg_pe_col_id;
  logic gin_cfg_pe_enable;

  logic filter_command_valid, filter_command_ready;
  logic [1:0] filter_command_cluster;
  logic [4:0] filter_command_row_tag;
  logic [5:0] filter_command_col_tag;
  logic [7:0] filter_command_rf_addr;
  logic filter_source_required;
  logic [3:0] filter_source_layer;
  logic [12:0] filter_source_filter;
  logic [13:0] filter_source_channel;
  logic [3:0] filter_source_y, filter_source_x;

  logic ifmap_command_valid, ifmap_command_ready;
  logic [4:0] ifmap_row_tag;
  logic [5:0] ifmap_col_tag;
  logic [3:0] ifmap_rf_addr;
  logic ifmap_source_required;
  logic [3:0] ifmap_source_layer;
  logic [2:0] ifmap_source_image;
  logic [13:0] ifmap_source_channel;
  logic signed [8:0] ifmap_source_y, ifmap_source_x;

  logic op_command_valid, op_command_ready;
  logic [2:0] op_cluster_enable;
  logic [2:0][167:0] command_op_mask;
  logic [7:0] command_op_filter_addr;
  logic [3:0] command_op_ifmap_addr;
  logic [4:0] command_op_psum_addr;
  logic command_op_first, command_op_last;
  logic [TAG_W-1:0] command_op_tag;

  logic reduce_command_valid, reduce_command_ready;
  logic reduce_command_done, reduce_command_error;
  logic [1:0] reduce_cluster;
  logic [3:0] command_reduce_rows, command_reduce_cols;
  logic [3:0] command_reduce_start_row, command_reduce_start_col;
  logic [TAG_W-1:0] command_reduce_tag;
  logic [3:0] reduce_output_layer;
  logic reduce_output_psum_first, reduce_output_psum_final;
  logic [13:0] reduce_output_channel_base;
  logic [12:0] reduce_output_filter;
  logic [2:0] reduce_output_image;
  logic [5:0] reduce_output_x, reduce_output_y_base;

  logic core_cfg_valid;
  logic [5:0] core_cfg_p, core_cfg_e;
  logic [3:0] core_cfg_q, core_cfg_s, core_cfg_filter_r;
  logic [2:0] core_cfg_stride;
  logic [3:0] core_cfg_set_r, core_cfg_set_t;
  logic command_fault;
  logic [31:0] filter_sequences_done_unused;
  logic [31:0] image_sequences_done_unused;

  logic [2:0] core_filter_event_valid, core_filter_event_ready;
  logic [2:0][3:0] core_filter_row;
  logic [2:0] core_filter_use_gin;
  logic [2:0][4:0] core_filter_row_tag;
  logic [2:0][5:0] core_filter_col_tag;
  logic [2:0] core_filter_use_explicit_mask;
  logic [2:0][167:0] core_filter_explicit_mask;
  logic [2:0][7:0] core_filter_addr;
  logic [2:0][7:0] core_filter_value;

  logic filter_buffer_valid_q;
  logic [1:0] filter_buffer_cluster_q;
  logic [4:0] filter_buffer_row_tag_q;
  logic [5:0] filter_buffer_col_tag_q;
  logic [7:0] filter_buffer_addr_q;
  logic signed [7:0] filter_buffer_value_q;
  logic filter_buffer_dispatch_ready;

  logic [2:0] core_ifmap_event_valid, core_ifmap_event_ready;
  logic [2:0][6:0] core_ifmap_row;
  logic [2:0] core_ifmap_use_gin;
  logic [2:0][4:0] core_ifmap_row_tag;
  logic [2:0][5:0] core_ifmap_col_tag;
  logic [2:0] core_ifmap_use_explicit_mask;
  logic [2:0][167:0] core_ifmap_explicit_mask;
  logic [2:0][3:0] core_ifmap_addr;
  logic [2:0][7:0] core_ifmap_value;

  logic ifmap_buffer_valid_q;
  logic [4:0] ifmap_buffer_row_tag_q;
  logic [5:0] ifmap_buffer_col_tag_q;
  logic [3:0] ifmap_buffer_addr_q;
  logic signed [7:0] ifmap_buffer_value_q;
  logic ifmap_buffer_dispatch_ready;

  logic [2:0] core_op_valid, core_op_ready;
  logic [2:0][7:0] core_op_filter_addr;
  logic [2:0][3:0] core_op_ifmap_addr;
  logic [2:0][4:0] core_op_psum_addr;
  logic [2:0] core_op_first, core_op_last;
  logic [2:0][TAG_W-1:0] core_op_tag;

  // One-entry command buffer deliberately breaks the long combinational
  // ready path from all 504 PEs back into the image command sequencer.
  logic op_buffer_valid_q;
  logic [2:0] op_buffer_cluster_enable_q;
  logic [2:0][167:0] op_buffer_mask_q;
  logic [7:0] op_buffer_filter_addr_q;
  logic [3:0] op_buffer_ifmap_addr_q;
  logic [4:0] op_buffer_psum_addr_q;
  logic op_buffer_first_q, op_buffer_last_q;
  logic [TAG_W-1:0] op_buffer_tag_q;
  logic op_buffer_dispatch_ready;

  logic [2:0] core_reduce_valid, core_reduce_ready;
  logic [2:0][3:0] core_reduce_rows, core_reduce_cols;
  logic [2:0][3:0] core_reduce_start_row, core_reduce_start_col;
  logic [2:0][TAG_W-1:0] core_reduce_tag;
  logic [2:0] core_result_valid, core_result_ready;
  logic [2:0][13:0] core_result_col_valid;
  logic signed [31:0] core_result_psum [0:2][0:13];
  logic [2:0][TAG_W-1:0] core_result_tag;
  logic [2:0][8:0] core_active_pes_unused;
  logic [2:0] core_fault;
  logic reduce_buffer_valid_q;
  logic [1:0] reduce_buffer_cluster_q;
  logic [3:0] reduce_buffer_rows_q, reduce_buffer_cols_q;
  logic [3:0] reduce_buffer_start_row_q, reduce_buffer_start_col_q;
  logic [TAG_W-1:0] reduce_buffer_tag_q;
  logic [3:0] reduce_buffer_output_layer_q;
  logic reduce_buffer_output_psum_first_q;
  logic reduce_buffer_output_psum_final_q;
  logic [13:0] reduce_buffer_output_channel_base_q;
  logic [12:0] reduce_buffer_output_filter_q;
  logic [2:0] reduce_buffer_output_image_q;
  logic [5:0] reduce_buffer_output_x_q;
  logic [5:0] reduce_buffer_output_y_base_q;
  logic reduce_buffer_dispatch_ready;
  logic reduce_pending_q;
  logic [1:0] result_cluster_q;
  logic [3:0] result_layer_q;
  logic result_psum_first_q, result_psum_final_q;
  logic [13:0] result_channel_base_q;
  logic [12:0] result_filter_q;
  logic [2:0] result_image_q;
  logic [5:0] result_x_q, result_y_base_q;

  alexnet_eyeriss_rs_batch8_command_top #(.TAG_W(TAG_W)) u_command (
    .clk, .rst, .start_valid, .start_ready, .start_tag,
    .gin_cfg_valid, .gin_cfg_ifmap, .gin_cfg_xbus_valid,
    .gin_cfg_xbus_index, .gin_cfg_xbus_row_id,
    .gin_cfg_pe_valid, .gin_cfg_pe_index, .gin_cfg_pe_col_id,
    .gin_cfg_pe_enable,
    .filter_command_valid, .filter_command_ready,
    .filter_command_cluster, .filter_command_row_tag,
    .filter_command_col_tag, .filter_command_rf_addr,
    .filter_source_required, .filter_source_layer, .filter_source_filter,
    .filter_source_channel, .filter_source_y, .filter_source_x,
    .ifmap_command_valid, .ifmap_command_ready,
    .ifmap_row_tag, .ifmap_col_tag, .ifmap_rf_addr,
    .ifmap_source_required, .ifmap_source_layer, .ifmap_source_image,
    .ifmap_source_channel, .ifmap_source_y, .ifmap_source_x,
    .op_command_valid, .op_command_ready,
    .op_cluster_enable, .op_mask(command_op_mask),
    .op_filter_addr(command_op_filter_addr),
    .op_ifmap_addr(command_op_ifmap_addr),
    .op_psum_addr(command_op_psum_addr),
    .op_first(command_op_first), .op_last(command_op_last),
    .op_tag(command_op_tag),
    .reduce_command_valid, .reduce_command_ready,
    .reduce_command_done, .reduce_command_error,
    .reduce_cluster,
    .reduce_rows(command_reduce_rows), .reduce_cols(command_reduce_cols),
    .reduce_start_row(command_reduce_start_row),
    .reduce_start_col(command_reduce_start_col),
    .reduce_tag(command_reduce_tag),
    .reduce_output_layer, .reduce_output_psum_first,
    .reduce_output_psum_final, .reduce_output_channel_base,
    .reduce_output_filter, .reduce_output_image,
    .reduce_output_x, .reduce_output_y_base,
    .core_cfg_valid, .core_cfg_p, .core_cfg_q, .core_cfg_s,
    .core_cfg_filter_r, .core_cfg_e, .core_cfg_stride,
    .core_cfg_set_r, .core_cfg_set_t,
    .layer_complete_valid, .layer_complete_ready, .layer_complete_id,
    .inference_done, .inference_done_ready,
    .fault(command_fault), .completed_passes,
    .filter_sequences_done(filter_sequences_done_unused),
    .image_sequences_done(image_sequences_done_unused)
  );

  assign filter_request_valid = filter_command_valid &&
                                filter_source_required &&
                                !filter_buffer_valid_q;
  assign filter_request_layer = filter_source_layer;
  assign filter_request_filter = filter_source_filter;
  assign filter_request_channel = filter_source_channel;
  assign filter_request_y = filter_source_y;
  assign filter_request_x = filter_source_x;
  assign filter_data_ready = filter_command_valid &&
                             filter_source_required &&
                             !filter_buffer_valid_q;
  assign filter_command_ready = !filter_buffer_valid_q &&
      (!filter_source_required || filter_data_valid);
  assign filter_buffer_dispatch_ready = filter_buffer_valid_q &&
      core_filter_event_ready[filter_buffer_cluster_q];

  assign ifmap_request_valid = ifmap_command_valid && ifmap_source_required &&
                               !ifmap_buffer_valid_q;
  assign ifmap_request_layer = ifmap_source_layer;
  assign ifmap_request_image = ifmap_source_image;
  assign ifmap_request_channel = ifmap_source_channel;
  assign ifmap_request_y = ifmap_source_y;
  assign ifmap_request_x = ifmap_source_x;
  assign ifmap_data_ready = ifmap_command_valid && ifmap_source_required &&
                            !ifmap_buffer_valid_q;
  assign ifmap_command_ready = !ifmap_buffer_valid_q &&
      (!ifmap_source_required || ifmap_data_valid);
  assign ifmap_buffer_dispatch_ready = ifmap_buffer_valid_q &&
      (&core_ifmap_event_ready);

  always_comb begin
    core_filter_event_valid = '0;
    core_filter_row = '0;
    core_filter_use_gin = '1;
    core_filter_row_tag = '0;
    core_filter_col_tag = '0;
    core_filter_use_explicit_mask = '0;
    core_filter_explicit_mask = '0;
    core_filter_addr = '0;
    core_filter_value = '0;
    for (integer c = 0; c < 3; c = c + 1) begin
      core_filter_row_tag[c] = filter_buffer_row_tag_q;
      core_filter_col_tag[c] = filter_buffer_col_tag_q;
      core_filter_addr[c] = filter_buffer_addr_q;
      core_filter_value[c] = filter_buffer_value_q;
      if (filter_buffer_cluster_q == c)
        core_filter_event_valid[c] = filter_buffer_valid_q;
    end

    core_ifmap_event_valid = {3{ifmap_buffer_valid_q}};
    core_ifmap_row = '0;
    core_ifmap_use_gin = '1;
    core_ifmap_row_tag = '0;
    core_ifmap_col_tag = '0;
    core_ifmap_use_explicit_mask = '0;
    core_ifmap_explicit_mask = '0;
    core_ifmap_addr = '0;
    core_ifmap_value = '0;
    for (integer c = 0; c < 3; c = c + 1) begin
      core_ifmap_row_tag[c] = ifmap_buffer_row_tag_q;
      core_ifmap_col_tag[c] = ifmap_buffer_col_tag_q;
      core_ifmap_addr[c] = ifmap_buffer_addr_q;
      core_ifmap_value[c] = ifmap_buffer_value_q;
    end

    core_op_valid = op_buffer_cluster_enable_q & {3{op_buffer_valid_q}};
    core_op_filter_addr = '0;
    core_op_ifmap_addr = '0;
    core_op_psum_addr = '0;
    core_op_first = {3{op_buffer_first_q}};
    core_op_last = {3{op_buffer_last_q}};
    core_op_tag = '0;
    for (integer c = 0; c < 3; c = c + 1) begin
      core_op_filter_addr[c] = op_buffer_filter_addr_q;
      core_op_ifmap_addr[c] = op_buffer_ifmap_addr_q;
      core_op_psum_addr[c] = op_buffer_psum_addr_q;
      core_op_tag[c] = op_buffer_tag_q;
    end

    core_reduce_valid = '0;
    core_reduce_rows = '0;
    core_reduce_cols = '0;
    core_reduce_start_row = '0;
    core_reduce_start_col = '0;
    core_reduce_tag = '0;
    for (integer c = 0; c < 3; c = c + 1) begin
      core_reduce_rows[c] = reduce_buffer_rows_q;
      core_reduce_cols[c] = reduce_buffer_cols_q;
      core_reduce_start_row[c] = reduce_buffer_start_row_q;
      core_reduce_start_col[c] = reduce_buffer_start_col_q;
      core_reduce_tag[c] = reduce_buffer_tag_q;
      if (reduce_buffer_cluster_q == c)
        core_reduce_valid[c] = reduce_buffer_valid_q;
    end

    core_result_ready = '0;
    if (reduce_pending_q)
      core_result_ready[result_cluster_q] = result_ready;
  end

  assign op_command_ready = !op_buffer_valid_q;
  assign op_buffer_dispatch_ready = !filter_buffer_valid_q &&
      !ifmap_buffer_valid_q &&
      &(~op_buffer_cluster_enable_q | core_op_ready);
  assign reduce_command_ready = !reduce_buffer_valid_q && !reduce_pending_q;
  assign reduce_buffer_dispatch_ready = reduce_buffer_valid_q &&
      core_reduce_ready[reduce_buffer_cluster_q];
  assign result_valid = reduce_pending_q &&
                        core_result_valid[result_cluster_q];
  assign result_col_valid = core_result_col_valid[result_cluster_q];
  assign result_tag = core_result_tag[result_cluster_q];
  assign result_layer = result_layer_q;
  assign result_psum_first = result_psum_first_q;
  assign result_psum_final = result_psum_final_q;
  assign result_channel_base = result_channel_base_q;
  assign result_filter = result_filter_q;
  assign result_image = result_image_q;
  assign result_x = result_x_q;
  assign result_y_base = result_y_base_q;
  assign reduce_command_done = result_valid && result_ready;
  assign reduce_command_error =
      (reduce_buffer_valid_q && core_fault[reduce_buffer_cluster_q]) ||
      (reduce_pending_q && core_fault[result_cluster_q]);

  always_comb begin
    for (integer col = 0; col < 14; col = col + 1)
      result_psum[col] = core_result_psum[result_cluster_q][col];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      filter_buffer_valid_q <= 1'b0;
      filter_buffer_cluster_q <= '0;
      filter_buffer_row_tag_q <= '0;
      filter_buffer_col_tag_q <= '0;
      filter_buffer_addr_q <= '0;
      filter_buffer_value_q <= '0;
      ifmap_buffer_valid_q <= 1'b0;
      ifmap_buffer_row_tag_q <= '0;
      ifmap_buffer_col_tag_q <= '0;
      ifmap_buffer_addr_q <= '0;
      ifmap_buffer_value_q <= '0;
      op_buffer_valid_q <= 1'b0;
      op_buffer_cluster_enable_q <= '0;
      op_buffer_mask_q <= '0;
      op_buffer_filter_addr_q <= '0;
      op_buffer_ifmap_addr_q <= '0;
      op_buffer_psum_addr_q <= '0;
      op_buffer_first_q <= 1'b0;
      op_buffer_last_q <= 1'b0;
      op_buffer_tag_q <= '0;
      reduce_buffer_valid_q <= 1'b0;
      reduce_buffer_cluster_q <= '0;
      reduce_buffer_rows_q <= '0;
      reduce_buffer_cols_q <= '0;
      reduce_buffer_start_row_q <= '0;
      reduce_buffer_start_col_q <= '0;
      reduce_buffer_tag_q <= '0;
      reduce_buffer_output_layer_q <= '0;
      reduce_buffer_output_psum_first_q <= 1'b0;
      reduce_buffer_output_psum_final_q <= 1'b0;
      reduce_buffer_output_channel_base_q <= '0;
      reduce_buffer_output_filter_q <= '0;
      reduce_buffer_output_image_q <= '0;
      reduce_buffer_output_x_q <= '0;
      reduce_buffer_output_y_base_q <= '0;
      reduce_pending_q <= 1'b0;
      result_cluster_q <= '0;
      result_layer_q <= '0;
      result_psum_first_q <= 1'b0;
      result_psum_final_q <= 1'b0;
      result_channel_base_q <= '0;
      result_filter_q <= '0;
      result_image_q <= '0;
      result_x_q <= '0;
      result_y_base_q <= '0;
    end else begin
      if (filter_command_valid && filter_command_ready) begin
        filter_buffer_valid_q <= 1'b1;
        filter_buffer_cluster_q <= filter_command_cluster;
        filter_buffer_row_tag_q <= filter_command_row_tag;
        filter_buffer_col_tag_q <= filter_command_col_tag;
        filter_buffer_addr_q <= filter_command_rf_addr;
        filter_buffer_value_q <= filter_source_required ? filter_data : 8'sd0;
      end else if (filter_buffer_dispatch_ready) begin
        filter_buffer_valid_q <= 1'b0;
      end

      if (ifmap_command_valid && ifmap_command_ready) begin
        ifmap_buffer_valid_q <= 1'b1;
        ifmap_buffer_row_tag_q <= ifmap_row_tag;
        ifmap_buffer_col_tag_q <= ifmap_col_tag;
        ifmap_buffer_addr_q <= ifmap_rf_addr;
        ifmap_buffer_value_q <= ifmap_source_required ? ifmap_data : 8'sd0;
      end else if (ifmap_buffer_dispatch_ready) begin
        ifmap_buffer_valid_q <= 1'b0;
      end

      if (op_command_valid && op_command_ready) begin
        op_buffer_valid_q <= 1'b1;
        op_buffer_cluster_enable_q <= op_cluster_enable;
        op_buffer_mask_q <= command_op_mask;
        op_buffer_filter_addr_q <= command_op_filter_addr;
        op_buffer_ifmap_addr_q <= command_op_ifmap_addr;
        op_buffer_psum_addr_q <= command_op_psum_addr;
        op_buffer_first_q <= command_op_first;
        op_buffer_last_q <= command_op_last;
        op_buffer_tag_q <= command_op_tag;
      end else if (op_buffer_valid_q && op_buffer_dispatch_ready) begin
        op_buffer_valid_q <= 1'b0;
      end

      if (reduce_command_valid && reduce_command_ready) begin
        reduce_buffer_valid_q <= 1'b1;
        reduce_buffer_cluster_q <= reduce_cluster;
        reduce_buffer_rows_q <= command_reduce_rows;
        reduce_buffer_cols_q <= command_reduce_cols;
        reduce_buffer_start_row_q <= command_reduce_start_row;
        reduce_buffer_start_col_q <= command_reduce_start_col;
        reduce_buffer_tag_q <= command_reduce_tag;
        reduce_buffer_output_layer_q <= reduce_output_layer;
        reduce_buffer_output_psum_first_q <= reduce_output_psum_first;
        reduce_buffer_output_psum_final_q <= reduce_output_psum_final;
        reduce_buffer_output_channel_base_q <= reduce_output_channel_base;
        reduce_buffer_output_filter_q <= reduce_output_filter;
        reduce_buffer_output_image_q <= reduce_output_image;
        reduce_buffer_output_x_q <= reduce_output_x;
        reduce_buffer_output_y_base_q <= reduce_output_y_base;
      end else if (reduce_buffer_dispatch_ready) begin
        reduce_buffer_valid_q <= 1'b0;
        reduce_pending_q <= 1'b1;
        result_cluster_q <= reduce_buffer_cluster_q;
        result_layer_q <= reduce_buffer_output_layer_q;
        result_psum_first_q <= reduce_buffer_output_psum_first_q;
        result_psum_final_q <= reduce_buffer_output_psum_final_q;
        result_channel_base_q <= reduce_buffer_output_channel_base_q;
        result_filter_q <= reduce_buffer_output_filter_q;
        result_image_q <= reduce_buffer_output_image_q;
        result_x_q <= reduce_buffer_output_x_q;
        result_y_base_q <= reduce_buffer_output_y_base_q;
      end
      if (reduce_command_done)
        reduce_pending_q <= 1'b0;
    end
  end

  alexnet_eyeriss_rs_3cluster_core #(.TAG_W(TAG_W)) u_core (
    .clk, .rst,
    .cfg_valid(core_cfg_valid), .cfg_p(core_cfg_p), .cfg_q(core_cfg_q),
    .cfg_s(core_cfg_s), .cfg_filter_r(core_cfg_filter_r),
    .cfg_e(core_cfg_e), .cfg_stride(core_cfg_stride),
    .cfg_set_r(core_cfg_set_r), .cfg_set_t(core_cfg_set_t),
    .gin_cfg_valid, .gin_cfg_ifmap, .gin_cfg_xbus_valid,
    .gin_cfg_xbus_index, .gin_cfg_xbus_row_id,
    .gin_cfg_pe_valid, .gin_cfg_pe_index, .gin_cfg_pe_col_id,
    .gin_cfg_pe_enable,
    .filter_event_valid(core_filter_event_valid),
    .filter_event_ready(core_filter_event_ready),
    .filter_row(core_filter_row), .filter_use_gin(core_filter_use_gin),
    .filter_row_tag(core_filter_row_tag),
    .filter_col_tag(core_filter_col_tag),
    .filter_use_explicit_mask(core_filter_use_explicit_mask),
    .filter_explicit_mask(core_filter_explicit_mask),
    .filter_addr(core_filter_addr), .filter_value(core_filter_value),
    .ifmap_event_valid(core_ifmap_event_valid),
    .ifmap_event_ready(core_ifmap_event_ready),
    .ifmap_row(core_ifmap_row), .ifmap_use_gin(core_ifmap_use_gin),
    .ifmap_row_tag(core_ifmap_row_tag),
    .ifmap_col_tag(core_ifmap_col_tag),
    .ifmap_use_explicit_mask(core_ifmap_use_explicit_mask),
    .ifmap_explicit_mask(core_ifmap_explicit_mask),
    .ifmap_addr(core_ifmap_addr), .ifmap_value(core_ifmap_value),
    .op_valid(core_op_valid), .op_ready(core_op_ready),
    .op_mask(op_buffer_mask_q), .op_filter_addr(core_op_filter_addr),
    .op_ifmap_addr(core_op_ifmap_addr), .op_psum_addr(core_op_psum_addr),
    .op_first(core_op_first), .op_last(core_op_last), .op_tag(core_op_tag),
    .reduce_valid(core_reduce_valid), .reduce_ready(core_reduce_ready),
    .reduce_rows(core_reduce_rows), .reduce_cols(core_reduce_cols),
    .reduce_start_row(core_reduce_start_row),
    .reduce_start_col(core_reduce_start_col), .reduce_tag(core_reduce_tag),
    .result_valid(core_result_valid), .result_ready(core_result_ready),
    .result_col_valid(core_result_col_valid),
    .result_psum(core_result_psum), .result_tag(core_result_tag),
    .active_pes(core_active_pes_unused), .cluster_fault(core_fault),
    .total_mac_count, .total_local_psum_hops
  );

  assign fault = command_fault || (|core_fault);

endmodule
