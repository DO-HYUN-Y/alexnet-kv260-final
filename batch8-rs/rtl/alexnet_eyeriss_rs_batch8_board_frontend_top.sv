`timescale 1ns/1ps

// Board integration boundary for the pure row-stationary engine.  The RS
// core emits logical filter/ifmap coordinates; the memory frontend translates
// them into the frozen AlexNet DDR layout and two aligned 128-bit read ports.
module alexnet_eyeriss_rs_batch8_board_frontend_top #(
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
  output logic [31:0]                total_local_psum_hops,

  output logic [63:0]                filter_byte_requests,
  output logic [63:0]                filter_cache_hits,
  output logic [63:0]                filter_cache_misses,
  output logic [63:0]                filter_dma_line_fetches,
  output logic [63:0]                ifmap_byte_requests,
  output logic [63:0]                ifmap_cache_hits,
  output logic [63:0]                ifmap_cache_misses,
  output logic [63:0]                ifmap_dma_line_fetches
);

  logic filter_request_valid, filter_data_valid, filter_data_ready;
  logic signed [7:0] filter_data;
  logic [3:0] filter_request_layer;
  logic [12:0] filter_request_filter;
  logic [13:0] filter_request_channel;
  logic [3:0] filter_request_y, filter_request_x;

  logic ifmap_request_valid, ifmap_data_valid, ifmap_data_ready;
  logic signed [7:0] ifmap_data;
  logic [3:0] ifmap_request_layer;
  logic [2:0] ifmap_request_image;
  logic [13:0] ifmap_request_channel;
  logic signed [8:0] ifmap_request_y, ifmap_request_x;
  logic filter_data_error, ifmap_data_error;
  logic core_fault, memory_fault;

  alexnet_eyeriss_rs_batch8_core_top #(.TAG_W(TAG_W)) u_core (
    .clk, .rst, .start_valid, .start_ready, .start_tag,
    .filter_request_valid, .filter_data_valid, .filter_data_ready,
    .filter_data, .filter_request_layer, .filter_request_filter,
    .filter_request_channel, .filter_request_y, .filter_request_x,
    .ifmap_request_valid, .ifmap_data_valid, .ifmap_data_ready,
    .ifmap_data, .ifmap_request_layer, .ifmap_request_image,
    .ifmap_request_channel, .ifmap_request_y, .ifmap_request_x,
    .result_valid, .result_ready, .result_col_valid, .result_psum,
    .result_tag, .result_layer, .result_psum_first, .result_psum_final,
    .result_channel_base,
    .result_filter, .result_image, .result_x, .result_y_base,
    .layer_complete_valid, .layer_complete_ready, .layer_complete_id,
    .inference_done, .inference_done_ready, .fault(core_fault),
    .completed_passes, .total_mac_count, .total_local_psum_hops
  );

  alexnet_eyeriss_rs_memory_frontend u_memory (
    .clk, .rst, .input_base, .activation_a_base, .activation_b_base,
    .weights_base,
    .filter_request_valid, .filter_request_layer,
    .filter_request_filter, .filter_request_channel,
    .filter_request_y, .filter_request_x,
    .filter_data_valid, .filter_data_ready, .filter_data,
    .filter_data_error,
    .ifmap_request_valid, .ifmap_request_layer, .ifmap_request_image,
    .ifmap_request_channel, .ifmap_request_y, .ifmap_request_x,
    .ifmap_data_valid, .ifmap_data_ready, .ifmap_data, .ifmap_data_error,
    .filter_line_request_valid, .filter_line_request_ready,
    .filter_line_request_address, .filter_line_response_valid,
    .filter_line_response_ready, .filter_line_response_data,
    .filter_line_response_error,
    .ifmap_line_request_valid, .ifmap_line_request_ready,
    .ifmap_line_request_address, .ifmap_line_response_valid,
    .ifmap_line_response_ready, .ifmap_line_response_data,
    .ifmap_line_response_error, .fault(memory_fault),
    .filter_byte_requests, .filter_cache_hits, .filter_cache_misses,
    .filter_dma_line_fetches, .ifmap_byte_requests, .ifmap_cache_hits,
    .ifmap_cache_misses, .ifmap_dma_line_fetches
  );

  assign fault = core_fault || memory_fault;

endmodule
