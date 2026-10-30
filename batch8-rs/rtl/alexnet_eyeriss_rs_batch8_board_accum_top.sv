`timescale 1ns/1ps

// Pure-RS board boundary including the URAM channel-pass accumulator.  Only
// final INT32 outputs leave this module; partial channel results remain on
// chip.  Layer/inference completion cannot retire while an accumulated output
// is still held under downstream backpressure.
module alexnet_eyeriss_rs_batch8_board_accum_top #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       start_valid,
  output logic                       start_ready,
  input  logic [TAG_W-1:0]           start_tag,
  input  logic [63:0]                input_base,
  input  logic [63:0]                activation_a_base,
  input  logic [63:0]                activation_b_base,
  input  logic [63:0]                weights_base,

  output logic                       filter_line_request_valid,
  input  logic                       filter_line_request_ready,
  output logic [63:0]                filter_line_request_address,
  input  logic                       filter_line_response_valid,
  output logic                       filter_line_response_ready,
  input  logic [127:0]               filter_line_response_data,
  input  logic                       filter_line_response_error,
  output logic                       ifmap_line_request_valid,
  input  logic                       ifmap_line_request_ready,
  output logic [63:0]                ifmap_line_request_address,
  input  logic                       ifmap_line_response_valid,
  output logic                       ifmap_line_response_ready,
  input  logic [127:0]               ifmap_line_response_data,
  input  logic                       ifmap_line_response_error,

  output logic                       result_valid,
  input  logic                       result_ready,
  output logic [13:0]                result_col_valid,
  output logic signed [31:0]         result_psum [0:13],
  output logic [TAG_W-1:0]           result_tag,
  output logic [3:0]                 result_layer,
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
  output logic [31:0]                total_local_psum_hops,
  output logic [63:0]                filter_byte_requests,
  output logic [63:0]                filter_cache_hits,
  output logic [63:0]                filter_cache_misses,
  output logic [63:0]                filter_dma_line_fetches,
  output logic [63:0]                ifmap_byte_requests,
  output logic [63:0]                ifmap_cache_hits,
  output logic [63:0]                ifmap_cache_misses,
  output logic [63:0]                ifmap_dma_line_fetches,
  output logic [63:0]                partial_result_inputs,
  output logic [63:0]                accumulator_uram_reads,
  output logic [63:0]                accumulator_uram_writes,
  output logic [63:0]                final_result_outputs
);

  logic partial_valid, partial_ready;
  logic [13:0] partial_col_valid;
  logic signed [31:0] partial_psum [0:13];
  logic [TAG_W-1:0] partial_tag;
  logic [3:0] partial_layer;
  logic partial_psum_first, partial_psum_final;
  logic [13:0] partial_channel_base;
  logic [12:0] partial_filter;
  logic [2:0] partial_image;
  logic [5:0] partial_x, partial_y_base;
  logic core_layer_complete_valid, core_layer_complete_ready;
  logic [3:0] core_layer_complete_id;
  logic core_inference_done, core_inference_done_ready;
  logic core_fault, accumulator_fault, accumulator_idle;

  alexnet_eyeriss_rs_batch8_board_frontend_top #(.TAG_W(TAG_W)) u_frontend (
    .clk, .rst, .start_valid, .start_ready, .start_tag,
    .input_base, .activation_a_base, .activation_b_base, .weights_base,
    .filter_line_request_valid, .filter_line_request_ready,
    .filter_line_request_address, .filter_line_response_valid,
    .filter_line_response_ready, .filter_line_response_data,
    .filter_line_response_error,
    .ifmap_line_request_valid, .ifmap_line_request_ready,
    .ifmap_line_request_address, .ifmap_line_response_valid,
    .ifmap_line_response_ready, .ifmap_line_response_data,
    .ifmap_line_response_error,
    .result_valid(partial_valid), .result_ready(partial_ready),
    .result_col_valid(partial_col_valid), .result_psum(partial_psum),
    .result_tag(partial_tag), .result_layer(partial_layer),
    .result_psum_first(partial_psum_first),
    .result_psum_final(partial_psum_final),
    .result_channel_base(partial_channel_base),
    .result_filter(partial_filter), .result_image(partial_image),
    .result_x(partial_x), .result_y_base(partial_y_base),
    .layer_complete_valid(core_layer_complete_valid),
    .layer_complete_ready(core_layer_complete_ready),
    .layer_complete_id(core_layer_complete_id),
    .inference_done(core_inference_done),
    .inference_done_ready(core_inference_done_ready),
    .fault(core_fault), .completed_passes, .total_mac_count,
    .total_local_psum_hops, .filter_byte_requests, .filter_cache_hits,
    .filter_cache_misses, .filter_dma_line_fetches,
    .ifmap_byte_requests, .ifmap_cache_hits, .ifmap_cache_misses,
    .ifmap_dma_line_fetches
  );

  alexnet_eyeriss_rs_channel_accumulator #(.TAG_W(TAG_W)) u_accumulator (
    .clk, .rst,
    .input_valid(partial_valid), .input_ready(partial_ready),
    .input_col_valid(partial_col_valid), .input_psum(partial_psum),
    .input_tag(partial_tag), .input_layer(partial_layer),
    .input_psum_first(partial_psum_first),
    .input_psum_final(partial_psum_final),
    .input_channel_base(partial_channel_base),
    .input_filter(partial_filter), .input_image(partial_image),
    .input_x(partial_x), .input_y_base(partial_y_base),
    .output_valid(result_valid), .output_ready(result_ready),
    .output_col_valid(result_col_valid), .output_psum(result_psum),
    .output_tag(result_tag), .output_layer(result_layer),
    .output_filter(result_filter), .output_image(result_image),
    .output_x(result_x), .output_y_base(result_y_base),
    .idle(accumulator_idle), .fault(accumulator_fault),
    .partial_inputs(partial_result_inputs),
    .uram_reads(accumulator_uram_reads),
    .uram_writes(accumulator_uram_writes),
    .final_outputs(final_result_outputs)
  );

  assign layer_complete_valid = core_layer_complete_valid;
  assign layer_complete_id = core_layer_complete_id;
  assign core_layer_complete_ready = layer_complete_ready && accumulator_idle;
  assign inference_done = core_inference_done;
  assign core_inference_done_ready = inference_done_ready && accumulator_idle;
  assign fault = core_fault || accumulator_fault;

endmodule
