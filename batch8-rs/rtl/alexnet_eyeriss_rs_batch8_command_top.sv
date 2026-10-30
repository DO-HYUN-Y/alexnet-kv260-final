`timescale 1ns/1ps

// Complete command-plane boundary for native-batch-eight pure RS execution.
// It joins the 1,185-pass controller to concrete filter and image micro-op
// sequencers.  AXI/GLB and core adapters consume the decoupled command ports.
module alexnet_eyeriss_rs_batch8_command_top #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       start_valid,
  output logic                       start_ready,
  input  logic [TAG_W-1:0]           start_tag,

  output logic                       gin_cfg_valid,
  output logic                       gin_cfg_ifmap,
  output logic                       gin_cfg_xbus_valid,
  output logic [3:0]                 gin_cfg_xbus_index,
  output logic [4:0]                 gin_cfg_xbus_row_id,
  output logic                       gin_cfg_pe_valid,
  output logic [7:0]                 gin_cfg_pe_index,
  output logic [5:0]                 gin_cfg_pe_col_id,
  output logic                       gin_cfg_pe_enable,

  output logic                       filter_command_valid,
  input  logic                       filter_command_ready,
  output logic [1:0]                 filter_command_cluster,
  output logic [4:0]                 filter_command_row_tag,
  output logic [5:0]                 filter_command_col_tag,
  output logic [7:0]                 filter_command_rf_addr,
  output logic                       filter_source_required,
  output logic [3:0]                 filter_source_layer,
  output logic [12:0]                filter_source_filter,
  output logic [13:0]                filter_source_channel,
  output logic [3:0]                 filter_source_y,
  output logic [3:0]                 filter_source_x,

  output logic                       ifmap_command_valid,
  input  logic                       ifmap_command_ready,
  output logic [4:0]                 ifmap_row_tag,
  output logic [5:0]                 ifmap_col_tag,
  output logic [3:0]                 ifmap_rf_addr,
  output logic                       ifmap_source_required,
  output logic [3:0]                 ifmap_source_layer,
  output logic [2:0]                 ifmap_source_image,
  output logic [13:0]                ifmap_source_channel,
  output logic signed [8:0]          ifmap_source_y,
  output logic signed [8:0]          ifmap_source_x,

  output logic                       op_command_valid,
  input  logic                       op_command_ready,
  output logic [2:0]                 op_cluster_enable,
  output logic [2:0][167:0]          op_mask,
  output logic [7:0]                 op_filter_addr,
  output logic [3:0]                 op_ifmap_addr,
  output logic [4:0]                 op_psum_addr,
  output logic                       op_first,
  output logic                       op_last,
  output logic [TAG_W-1:0]           op_tag,

  output logic                       reduce_command_valid,
  input  logic                       reduce_command_ready,
  input  logic                       reduce_command_done,
  input  logic                       reduce_command_error,
  output logic [1:0]                 reduce_cluster,
  output logic [3:0]                 reduce_rows,
  output logic [3:0]                 reduce_cols,
  output logic [3:0]                 reduce_start_row,
  output logic [3:0]                 reduce_start_col,
  output logic [TAG_W-1:0]           reduce_tag,
  output logic [3:0]                 reduce_output_layer,
  output logic                       reduce_output_psum_first,
  output logic                       reduce_output_psum_final,
  output logic [13:0]                reduce_output_channel_base,
  output logic [12:0]                reduce_output_filter,
  output logic [2:0]                 reduce_output_image,
  output logic [5:0]                 reduce_output_x,
  output logic [5:0]                 reduce_output_y_base,

  output logic                       core_cfg_valid,
  output logic [5:0]                 core_cfg_p,
  output logic [3:0]                 core_cfg_q,
  output logic [3:0]                 core_cfg_s,
  output logic [3:0]                 core_cfg_filter_r,
  output logic [5:0]                 core_cfg_e,
  output logic [2:0]                 core_cfg_stride,
  output logic [3:0]                 core_cfg_set_r,
  output logic [3:0]                 core_cfg_set_t,

  output logic                       layer_complete_valid,
  input  logic                       layer_complete_ready,
  output logic [3:0]                 layer_complete_id,
  output logic                       inference_done,
  input  logic                       inference_done_ready,
  output logic                       fault,
  output logic [15:0]                completed_passes,
  output logic [31:0]                filter_sequences_done,
  output logic [31:0]                image_sequences_done
);

  logic filter_phase_valid, filter_phase_ready;
  logic filter_phase_done, filter_phase_error;
  logic image_phase_valid, image_phase_ready;
  logic [2:0] image_phase_index;
  logic image_phase_done, image_phase_error;
  logic [15:0] active_tag;
  logic [3:0] active_layer_id;
  logic [5:0] active_strip_y, active_strip_rows;
  logic [13:0] active_channel_base;
  logic [7:0] active_channel_count;
  logic [12:0] active_filter_base;
  logic [9:0] active_filter_count;
  logic [5:0] active_output_width;
  logic [3:0] active_filter_r, active_filter_s;
  logic [5:0] active_e, active_p;
  logic [2:0] active_stride;
  logic [3:0] active_q, active_r, active_t;
  logic active_psum_first, active_psum_final;
  logic control_fault;
  logic [31:0] filter_emitted_unused, filter_source_bytes_unused;
  logic [31:0] image_ifmap_commands_unused;
  logic [31:0] image_ifmap_source_bytes_unused;
  logic [31:0] image_op_vectors_unused, image_reductions_unused;
  logic [63:0] image_pe_macs_unused;

  // The active descriptor remains stable for the complete filter/image
  // phase.  Export its layer tag with every memory and result transaction so
  // a board adapter can select the correct DDR/GLB layout.
  assign filter_source_layer = active_layer_id;
  assign ifmap_source_layer = active_layer_id;
  assign reduce_output_layer = active_layer_id;
  assign reduce_output_psum_first = active_psum_first;
  assign reduce_output_psum_final = active_psum_final;
  assign reduce_output_channel_base = active_channel_base;

  alexnet_eyeriss_rs_batch8_control u_control (
    .clk, .rst, .start_valid, .start_ready, .start_tag,
    .gin_cfg_valid, .gin_cfg_ifmap, .gin_cfg_xbus_valid,
    .gin_cfg_xbus_index, .gin_cfg_xbus_row_id,
    .gin_cfg_pe_valid, .gin_cfg_pe_index, .gin_cfg_pe_col_id,
    .gin_cfg_pe_enable,
    .filter_phase_valid, .filter_phase_ready,
    .filter_phase_done, .filter_phase_error,
    .image_phase_valid, .image_phase_ready, .image_phase_index,
    .image_phase_done, .image_phase_error,
    .active_tag, .active_layer_id, .active_strip_y, .active_strip_rows,
    .active_channel_base, .active_channel_count,
    .active_filter_base, .active_filter_count, .active_output_width,
    .active_filter_r, .active_filter_s, .active_e, .active_stride,
    .active_p, .active_q, .active_r, .active_t,
    .active_psum_first, .active_psum_final,
    .layer_complete_valid, .layer_complete_ready, .layer_complete_id,
    .inference_done, .inference_done_ready,
    .fault(control_fault), .completed_passes
  );

  alexnet_eyeriss_rs_filter_load_sequencer u_filter_sequence (
    .clk, .rst,
    .start_valid(filter_phase_valid), .start_ready(filter_phase_ready),
    .channel_base(active_channel_base),
    .channel_count(active_channel_count),
    .filter_base(active_filter_base), .filter_count(active_filter_count),
    .filter_r(active_filter_r), .filter_s(active_filter_s),
    .map_e(active_e), .map_p(active_p), .map_q(active_q),
    .map_r(active_r), .map_t(active_t),
    .command_valid(filter_command_valid),
    .command_ready(filter_command_ready),
    .command_cluster(filter_command_cluster),
    .command_row_tag(filter_command_row_tag),
    .command_col_tag(filter_command_col_tag),
    .command_rf_addr(filter_command_rf_addr),
    .source_required(filter_source_required),
    .source_filter(filter_source_filter),
    .source_channel(filter_source_channel),
    .source_filter_y(filter_source_y),
    .source_filter_x(filter_source_x),
    .done(filter_phase_done), .error(filter_phase_error),
    .emitted_commands(filter_emitted_unused),
    .source_bytes(filter_source_bytes_unused)
  );

  alexnet_eyeriss_rs_image_op_sequencer #(.TAG_W(TAG_W)) u_image_sequence (
    .clk, .rst,
    .start_valid(image_phase_valid), .start_ready(image_phase_ready),
    .start_tag(active_tag), .layer_id(active_layer_id),
    .image_index(image_phase_index),
    .strip_y(active_strip_y), .strip_rows(active_strip_rows),
    .channel_base(active_channel_base),
    .channel_count(active_channel_count),
    .filter_base(active_filter_base), .filter_count(active_filter_count),
    .output_width(active_output_width),
    .filter_r(active_filter_r), .filter_s(active_filter_s),
    .stride(active_stride), .map_e(active_e), .map_p(active_p),
    .map_q(active_q), .map_r(active_r), .map_t(active_t),
    .ifmap_command_valid, .ifmap_command_ready,
    .ifmap_row_tag, .ifmap_col_tag, .ifmap_rf_addr,
    .ifmap_source_required, .ifmap_source_image,
    .ifmap_source_channel, .ifmap_source_y, .ifmap_source_x,
    .op_command_valid, .op_command_ready, .op_cluster_enable, .op_mask,
    .op_filter_addr, .op_ifmap_addr, .op_psum_addr,
    .op_first, .op_last, .op_tag,
    .reduce_command_valid, .reduce_command_ready,
    .reduce_command_done, .reduce_command_error,
    .reduce_cluster, .reduce_rows, .reduce_cols,
    .reduce_start_row, .reduce_start_col, .reduce_tag,
    .reduce_output_filter, .reduce_output_image,
    .reduce_output_x, .reduce_output_y_base,
    .done(image_phase_done), .error(image_phase_error),
    .ifmap_commands(image_ifmap_commands_unused),
    .ifmap_source_bytes(image_ifmap_source_bytes_unused),
    .op_vectors(image_op_vectors_unused),
    .pe_mac_operations(image_pe_macs_unused),
    .reductions(image_reductions_unused)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      filter_sequences_done <= '0;
      image_sequences_done <= '0;
    end else begin
      if (filter_phase_done)
        filter_sequences_done <= filter_sequences_done + 1'b1;
      if (image_phase_done)
        image_sequences_done <= image_sequences_done + 1'b1;
    end
  end

  assign fault = control_fault || filter_phase_error || image_phase_error;
  assign core_cfg_valid = gin_cfg_valid;
  assign core_cfg_p = active_p;
  assign core_cfg_q = active_q;
  assign core_cfg_s = active_filter_s;
  assign core_cfg_filter_r = active_filter_r;
  assign core_cfg_e = active_e;
  assign core_cfg_stride = active_stride;
  assign core_cfg_set_r = active_r;
  assign core_cfg_set_t = active_t;

endmodule
