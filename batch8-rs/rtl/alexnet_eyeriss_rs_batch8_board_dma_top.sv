`timescale 1ns/1ps

// DMA-facing pure-RS boundary for the existing KV260 shell.  Weight MM2S
// services filter lines and main MM2S services ifmap lines; final accumulated
// INT32 results remain decoupled for the postprocess/store path.
module alexnet_eyeriss_rs_batch8_board_dma_top #(
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

  output logic                       weight_dma_command_valid,
  input  logic                       weight_dma_command_ready,
  output logic [31:0]                weight_dma_command_address,
  output logic [25:0]                weight_dma_command_length,
  input  logic                       weight_dma_armed,
  input  logic                       weight_dma_done,
  input  logic                       weight_dma_error,
  input  logic [127:0]               weight_axis_tdata,
  input  logic [15:0]                weight_axis_tkeep,
  input  logic                       weight_axis_tvalid,
  output logic                       weight_axis_tready,
  input  logic                       weight_axis_tlast,

  output logic                       main_dma_command_valid,
  input  logic                       main_dma_command_ready,
  output logic [31:0]                main_dma_command_address,
  output logic [25:0]                main_dma_command_length,
  input  logic                       main_dma_armed,
  input  logic                       main_dma_done,
  input  logic                       main_dma_error,
  input  logic [127:0]               main_axis_tdata,
  input  logic [15:0]                main_axis_tkeep,
  input  logic                       main_axis_tvalid,
  output logic                       main_axis_tready,
  input  logic                       main_axis_tlast,

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
  output logic [63:0]                final_result_outputs,
  output logic [63:0]                weight_dma_line_commands,
  output logic [63:0]                weight_dma_line_errors,
  output logic [63:0]                main_dma_line_commands,
  output logic [63:0]                main_dma_line_errors
);

  logic filter_line_request_valid, filter_line_request_ready;
  logic [63:0] filter_line_request_address;
  logic filter_line_response_valid, filter_line_response_ready;
  logic [127:0] filter_line_response_data;
  logic filter_line_response_error;
  logic ifmap_line_request_valid, ifmap_line_request_ready;
  logic [63:0] ifmap_line_request_address;
  logic ifmap_line_response_valid, ifmap_line_response_ready;
  logic [127:0] ifmap_line_response_data;
  logic ifmap_line_response_error;
  logic compute_fault, dma_adapter_fault;

  alexnet_eyeriss_rs_batch8_board_accum_top #(.TAG_W(TAG_W)) u_compute (
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
    .result_valid, .result_ready, .result_col_valid, .result_psum,
    .result_tag, .result_layer, .result_filter, .result_image,
    .result_x, .result_y_base,
    .layer_complete_valid, .layer_complete_ready, .layer_complete_id,
    .inference_done, .inference_done_ready, .fault(compute_fault),
    .completed_passes, .total_mac_count, .total_local_psum_hops,
    .filter_byte_requests, .filter_cache_hits, .filter_cache_misses,
    .filter_dma_line_fetches, .ifmap_byte_requests, .ifmap_cache_hits,
    .ifmap_cache_misses, .ifmap_dma_line_fetches,
    .partial_result_inputs, .accumulator_uram_reads,
    .accumulator_uram_writes, .final_result_outputs
  );

  alexnet_eyeriss_rs_dual_dma_line_adapter u_dma_adapter (
    .clk, .rst,
    .filter_line_request_valid, .filter_line_request_ready,
    .filter_line_request_address, .filter_line_response_valid,
    .filter_line_response_ready, .filter_line_response_data,
    .filter_line_response_error,
    .ifmap_line_request_valid, .ifmap_line_request_ready,
    .ifmap_line_request_address, .ifmap_line_response_valid,
    .ifmap_line_response_ready, .ifmap_line_response_data,
    .ifmap_line_response_error,
    .weight_dma_command_valid, .weight_dma_command_ready,
    .weight_dma_command_address, .weight_dma_command_length,
    .weight_dma_armed, .weight_dma_done, .weight_dma_error,
    .weight_axis_tdata, .weight_axis_tkeep, .weight_axis_tvalid,
    .weight_axis_tready, .weight_axis_tlast,
    .main_dma_command_valid, .main_dma_command_ready,
    .main_dma_command_address, .main_dma_command_length,
    .main_dma_armed, .main_dma_done, .main_dma_error,
    .main_axis_tdata, .main_axis_tkeep, .main_axis_tvalid,
    .main_axis_tready, .main_axis_tlast,
    .fault(dma_adapter_fault), .weight_dma_line_commands,
    .weight_dma_line_errors, .main_dma_line_commands,
    .main_dma_line_errors
  );

  assign fault = compute_fault || dma_adapter_fault;

endmodule
