`timescale 1ns/1ps

// Connects the 1,185-pass AlexNet scheduler to the native-batch-eight pass
// executor.  Data movement is intentionally exposed as filter/image phases so
// the AXI/GLB operation sequencer can be integrated without changing control.
module alexnet_eyeriss_rs_batch8_control (
  input  logic          clk,
  input  logic          rst,
  input  logic          start_valid,
  output logic          start_ready,
  input  logic [15:0]   start_tag,

  output logic          gin_cfg_valid,
  output logic          gin_cfg_ifmap,
  output logic          gin_cfg_xbus_valid,
  output logic [3:0]    gin_cfg_xbus_index,
  output logic [4:0]    gin_cfg_xbus_row_id,
  output logic          gin_cfg_pe_valid,
  output logic [7:0]    gin_cfg_pe_index,
  output logic [5:0]    gin_cfg_pe_col_id,
  output logic          gin_cfg_pe_enable,

  output logic          filter_phase_valid,
  input  logic          filter_phase_ready,
  input  logic          filter_phase_done,
  input  logic          filter_phase_error,
  output logic          image_phase_valid,
  input  logic          image_phase_ready,
  output logic [2:0]    image_phase_index,
  input  logic          image_phase_done,
  input  logic          image_phase_error,

  output logic [15:0]   active_tag,
  output logic [3:0]    active_layer_id,
  output logic [5:0]    active_strip_y,
  output logic [5:0]    active_strip_rows,
  output logic [13:0]   active_channel_base,
  output logic [7:0]    active_channel_count,
  output logic [12:0]   active_filter_base,
  output logic [9:0]    active_filter_count,
  output logic [5:0]    active_output_width,
  output logic [3:0]    active_filter_r,
  output logic [3:0]    active_filter_s,
  output logic [5:0]    active_e,
  output logic [2:0]    active_stride,
  output logic [5:0]    active_p,
  output logic [3:0]    active_q,
  output logic [3:0]    active_r,
  output logic [3:0]    active_t,
  output logic          active_psum_first,
  output logic          active_psum_final,

  output logic          layer_complete_valid,
  input  logic          layer_complete_ready,
  output logic [3:0]    layer_complete_id,
  output logic          inference_done,
  input  logic          inference_done_ready,
  output logic          fault,
  output logic [15:0]   completed_passes
);

  logic pass_valid;
  logic pass_ready;
  logic [15:0] pass_tag;
  logic [3:0] pass_layer_id;
  logic [5:0] pass_strip_y;
  logic [5:0] pass_strip_rows;
  logic [13:0] pass_channel_base;
  logic [7:0] pass_channel_count;
  logic [12:0] pass_filter_base;
  logic [9:0] pass_filter_count;
  logic [5:0] pass_output_width;
  logic [3:0] pass_filter_r;
  logic [3:0] pass_filter_s;
  logic [5:0] pass_e;
  logic [2:0] pass_stride;
  logic [9:0] pass_m_unused;
  logic [3:0] pass_n_unused;
  logic [5:0] pass_p;
  logic [3:0] pass_q;
  logic [3:0] pass_r;
  logic [3:0] pass_t;
  logic pass_load_ifmap_unused;
  logic pass_load_filter_unused;
  logic pass_keep_filter_unused;
  logic pass_psum_first;
  logic pass_psum_final;
  logic [63:0] pass_useful_macs_unused;
  logic [31:0] pass_weight_bytes_unused;
  logic executor_done;
  logic executor_error;
  logic [8:0] configured_active_pes_unused;
  logic [8:0] gin_config_cycles_unused;
  logic scheduler_fault;

  alexnet_eyeriss_rs_batch8_pass_scheduler u_scheduler (
    .clk,
    .rst,
    .start_valid,
    .start_ready,
    .start_tag,
    .pass_valid,
    .pass_ready,
    .pass_tag,
    .pass_layer_id,
    .pass_strip_y,
    .pass_strip_rows,
    .pass_channel_base,
    .pass_channel_count,
    .pass_filter_base,
    .pass_filter_count,
    .pass_output_width,
    .pass_filter_r,
    .pass_filter_s,
    .pass_e,
    .pass_stride,
    .pass_m(pass_m_unused),
    .pass_n(pass_n_unused),
    .pass_p,
    .pass_q,
    .pass_r,
    .pass_t,
    .pass_load_ifmap(pass_load_ifmap_unused),
    .pass_load_filter(pass_load_filter_unused),
    .pass_keep_filter_for_batch(pass_keep_filter_unused),
    .pass_psum_first,
    .pass_psum_final,
    .pass_useful_macs(pass_useful_macs_unused),
    .pass_weight_bytes(pass_weight_bytes_unused),
    .pass_done(executor_done),
    .pass_error(executor_error),
    .layer_complete_valid,
    .layer_complete_ready,
    .layer_complete_id,
    .inference_done,
    .inference_done_ready,
    .fault(scheduler_fault),
    .completed_passes
  );

  alexnet_eyeriss_rs_batch8_pass_executor u_executor (
    .clk,
    .rst,
    .pass_valid,
    .pass_ready,
    .pass_tag,
    .pass_layer_id,
    .pass_filter_r,
    .pass_e,
    .pass_stride,
    .pass_set_r(pass_r),
    .pass_set_t(pass_t),
    .gin_cfg_valid,
    .gin_cfg_ifmap,
    .gin_cfg_xbus_valid,
    .gin_cfg_xbus_index,
    .gin_cfg_xbus_row_id,
    .gin_cfg_pe_valid,
    .gin_cfg_pe_index,
    .gin_cfg_pe_col_id,
    .gin_cfg_pe_enable,
    .filter_phase_valid,
    .filter_phase_ready,
    .filter_phase_done,
    .filter_phase_error,
    .image_phase_valid,
    .image_phase_ready,
    .image_phase_index,
    .image_phase_done,
    .image_phase_error,
    .active_tag,
    .active_layer_id,
    .pass_done(executor_done),
    .pass_error(executor_error),
    .configured_active_pes(configured_active_pes_unused),
    .gin_config_cycles(gin_config_cycles_unused)
  );

  assign active_strip_y = pass_strip_y;
  assign active_strip_rows = pass_strip_rows;
  assign active_channel_base = pass_channel_base;
  assign active_channel_count = pass_channel_count;
  assign active_filter_base = pass_filter_base;
  assign active_filter_count = pass_filter_count;
  assign active_output_width = pass_output_width;
  assign active_filter_r = pass_filter_r;
  assign active_filter_s = pass_filter_s;
  assign active_e = pass_e;
  assign active_stride = pass_stride;
  assign active_p = pass_p;
  assign active_q = pass_q;
  assign active_r = pass_r;
  assign active_t = pass_t;
  assign active_psum_first = pass_psum_first;
  assign active_psum_final = pass_psum_final;
  assign fault = scheduler_fault || executor_error;

endmodule
