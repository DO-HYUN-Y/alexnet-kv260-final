`timescale 1ns/1ps

// Two independent 16-byte MM2S bridges: filter traffic uses the existing
// weight DMA, while ifmap traffic uses the existing main DMA.
module alexnet_eyeriss_rs_dual_dma_line_adapter (
  input  logic         clk,
  input  logic         rst,

  input  logic         filter_line_request_valid,
  output logic         filter_line_request_ready,
  input  logic [63:0]  filter_line_request_address,
  output logic         filter_line_response_valid,
  input  logic         filter_line_response_ready,
  output logic [127:0] filter_line_response_data,
  output logic         filter_line_response_error,

  input  logic         ifmap_line_request_valid,
  output logic         ifmap_line_request_ready,
  input  logic [63:0]  ifmap_line_request_address,
  output logic         ifmap_line_response_valid,
  input  logic         ifmap_line_response_ready,
  output logic [127:0] ifmap_line_response_data,
  output logic         ifmap_line_response_error,

  output logic         weight_dma_command_valid,
  input  logic         weight_dma_command_ready,
  output logic [31:0]  weight_dma_command_address,
  output logic [25:0]  weight_dma_command_length,
  input  logic         weight_dma_armed,
  input  logic         weight_dma_done,
  input  logic         weight_dma_error,
  input  logic [127:0] weight_axis_tdata,
  input  logic [15:0]  weight_axis_tkeep,
  input  logic         weight_axis_tvalid,
  output logic         weight_axis_tready,
  input  logic         weight_axis_tlast,

  output logic         main_dma_command_valid,
  input  logic         main_dma_command_ready,
  output logic [31:0]  main_dma_command_address,
  output logic [25:0]  main_dma_command_length,
  input  logic         main_dma_armed,
  input  logic         main_dma_done,
  input  logic         main_dma_error,
  input  logic [127:0] main_axis_tdata,
  input  logic [15:0]  main_axis_tkeep,
  input  logic         main_axis_tvalid,
  output logic         main_axis_tready,
  input  logic         main_axis_tlast,

  output logic         fault,
  output logic [63:0]  weight_dma_line_commands,
  output logic [63:0]  weight_dma_line_errors,
  output logic [63:0]  main_dma_line_commands,
  output logic [63:0]  main_dma_line_errors
);

  logic filter_fault, ifmap_fault;
  logic [63:0] filter_requests_unused, filter_beats_unused;
  logic [63:0] ifmap_requests_unused, ifmap_beats_unused;

  alexnet_eyeriss_rs_dma_line_reader u_filter_reader (
    .clk, .rst,
    .line_request_valid(filter_line_request_valid),
    .line_request_ready(filter_line_request_ready),
    .line_request_address(filter_line_request_address),
    .line_response_valid(filter_line_response_valid),
    .line_response_ready(filter_line_response_ready),
    .line_response_data(filter_line_response_data),
    .line_response_error(filter_line_response_error),
    .dma_command_valid(weight_dma_command_valid),
    .dma_command_ready(weight_dma_command_ready),
    .dma_command_address(weight_dma_command_address),
    .dma_command_length(weight_dma_command_length),
    .dma_armed(weight_dma_armed), .dma_done(weight_dma_done),
    .dma_error(weight_dma_error),
    .s_axis_tdata(weight_axis_tdata), .s_axis_tkeep(weight_axis_tkeep),
    .s_axis_tvalid(weight_axis_tvalid), .s_axis_tready(weight_axis_tready),
    .s_axis_tlast(weight_axis_tlast), .fault(filter_fault),
    .accepted_requests(filter_requests_unused),
    .issued_commands(weight_dma_line_commands),
    .accepted_beats(filter_beats_unused),
    .error_responses(weight_dma_line_errors)
  );

  alexnet_eyeriss_rs_dma_line_reader u_ifmap_reader (
    .clk, .rst,
    .line_request_valid(ifmap_line_request_valid),
    .line_request_ready(ifmap_line_request_ready),
    .line_request_address(ifmap_line_request_address),
    .line_response_valid(ifmap_line_response_valid),
    .line_response_ready(ifmap_line_response_ready),
    .line_response_data(ifmap_line_response_data),
    .line_response_error(ifmap_line_response_error),
    .dma_command_valid(main_dma_command_valid),
    .dma_command_ready(main_dma_command_ready),
    .dma_command_address(main_dma_command_address),
    .dma_command_length(main_dma_command_length),
    .dma_armed(main_dma_armed), .dma_done(main_dma_done),
    .dma_error(main_dma_error),
    .s_axis_tdata(main_axis_tdata), .s_axis_tkeep(main_axis_tkeep),
    .s_axis_tvalid(main_axis_tvalid), .s_axis_tready(main_axis_tready),
    .s_axis_tlast(main_axis_tlast), .fault(ifmap_fault),
    .accepted_requests(ifmap_requests_unused),
    .issued_commands(main_dma_line_commands),
    .accepted_beats(ifmap_beats_unused),
    .error_responses(main_dma_line_errors)
  );

  assign fault = filter_fault || ifmap_fault;

endmodule
