`timescale 1ns/1ps

// Pure-RS board boundary through bias/requantization/ReLU.  Before the first
// compute command for a parameter DDR base, the complete 165,504-byte frozen
// AlexNet parameter blob is loaded through the weight MM2S channel into six
// URAMs.  Final accumulated 14-column INT32 vectors then look up one record
// per output filter and leave this boundary as signed INT8 values.
module alexnet_eyeriss_rs_batch8_board_postprocess_top #(
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
  input  logic [63:0]                parameters_base,

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
  output logic signed [7:0]          result_values [0:13],
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
  output logic [63:0]                main_dma_line_errors,
  output logic [31:0]                parameter_blob_loads,
  output logic [63:0]                parameter_lookups,
  output logic [63:0]                requantized_vectors
);
  localparam int PARAMETER_RECORDS = 10344;
  localparam logic [25:0] PARAMETER_BYTES = 26'd165504;

  typedef enum logic [2:0] {
    ST_IDLE, ST_PARAMETER_COMMAND, ST_PARAMETER_STREAM,
    ST_PARAMETER_DRAIN, ST_CORE_START, ST_COMPUTE, ST_FAILED
  } state_t;
  state_t state_q;

  logic [TAG_W-1:0] job_tag_q;
  logic [63:0] input_base_q, activation_a_base_q, activation_b_base_q;
  logic [63:0] weights_base_q, parameters_base_q;
  logic [63:0] cached_parameters_base_q;
  logic parameter_dma_done_seen_q, fault_q;

  logic core_start_valid, core_start_ready;
  logic core_weight_command_valid, core_weight_command_ready;
  logic [31:0] core_weight_command_address;
  logic [25:0] core_weight_command_length;
  logic core_weight_armed, core_weight_done, core_weight_error;
  logic [127:0] core_weight_axis_tdata;
  logic [15:0] core_weight_axis_tkeep;
  logic core_weight_axis_tvalid, core_weight_axis_tready;
  logic core_weight_axis_tlast;

  logic int32_result_valid, int32_result_ready;
  logic [13:0] int32_result_col_valid;
  logic signed [31:0] int32_result_psum [0:13];
  logic [TAG_W-1:0] int32_result_tag;
  logic [3:0] int32_result_layer;
  logic [12:0] int32_result_filter;
  logic [2:0] int32_result_image;
  logic [5:0] int32_result_x, int32_result_y_base;
  logic core_layer_complete_valid, core_layer_complete_ready;
  logic [3:0] core_layer_complete_id;
  logic core_inference_done, core_inference_done_ready;
  logic core_fault;

  logic parameter_load_start_valid, parameter_load_start_ready;
  logic parameter_load_axis_ready, parameter_load_active;
  logic parameter_load_done, parameter_cache_valid, parameter_cache_fault;
  logic parameter_request_valid, parameter_request_ready;
  logic [13:0] parameter_request_index;
  logic parameter_response_valid, parameter_response_ready;
  logic [127:0] parameter_response_data;
  logic postprocess_idle, postprocess_fault;

  assign start_ready = state_q == ST_IDLE && !fault;
  assign core_start_valid = state_q == ST_CORE_START;

  assign parameter_load_start_valid =
      state_q == ST_PARAMETER_COMMAND && parameter_load_start_ready &&
      weight_dma_command_ready;

  always_comb begin
    weight_dma_command_valid = 1'b0;
    weight_dma_command_address = '0;
    weight_dma_command_length = '0;
    core_weight_command_ready = 1'b0;
    core_weight_armed = 1'b0;
    core_weight_done = 1'b0;
    core_weight_error = 1'b0;
    core_weight_axis_tdata = weight_axis_tdata;
    core_weight_axis_tkeep = weight_axis_tkeep;
    core_weight_axis_tvalid = 1'b0;
    core_weight_axis_tlast = weight_axis_tlast;
    weight_axis_tready = 1'b0;

    if (state_q == ST_PARAMETER_COMMAND) begin
      weight_dma_command_valid = parameter_load_start_ready;
      weight_dma_command_address = parameters_base_q[31:0];
      weight_dma_command_length = PARAMETER_BYTES;
    end else if (state_q == ST_PARAMETER_STREAM ||
                 state_q == ST_PARAMETER_DRAIN) begin
      weight_axis_tready = parameter_load_active ?
                           parameter_load_axis_ready : 1'b0;
    end else if (state_q == ST_COMPUTE) begin
      weight_dma_command_valid = core_weight_command_valid;
      weight_dma_command_address = core_weight_command_address;
      weight_dma_command_length = core_weight_command_length;
      core_weight_command_ready = weight_dma_command_ready;
      core_weight_armed = weight_dma_armed;
      core_weight_done = weight_dma_done;
      core_weight_error = weight_dma_error;
      core_weight_axis_tvalid = weight_axis_tvalid;
      weight_axis_tready = core_weight_axis_tready;
    end
  end

  alexnet_eyeriss_rs_batch8_board_dma_top #(.TAG_W(TAG_W)) u_compute (
    .clk, .rst, .start_valid(core_start_valid),
    .start_ready(core_start_ready), .start_tag(job_tag_q),
    .input_base(input_base_q), .activation_a_base(activation_a_base_q),
    .activation_b_base(activation_b_base_q), .weights_base(weights_base_q),
    .weight_dma_command_valid(core_weight_command_valid),
    .weight_dma_command_ready(core_weight_command_ready),
    .weight_dma_command_address(core_weight_command_address),
    .weight_dma_command_length(core_weight_command_length),
    .weight_dma_armed(core_weight_armed), .weight_dma_done(core_weight_done),
    .weight_dma_error(core_weight_error),
    .weight_axis_tdata(core_weight_axis_tdata),
    .weight_axis_tkeep(core_weight_axis_tkeep),
    .weight_axis_tvalid(core_weight_axis_tvalid),
    .weight_axis_tready(core_weight_axis_tready),
    .weight_axis_tlast(core_weight_axis_tlast),
    .main_dma_command_valid, .main_dma_command_ready,
    .main_dma_command_address, .main_dma_command_length,
    .main_dma_armed, .main_dma_done, .main_dma_error,
    .main_axis_tdata, .main_axis_tkeep, .main_axis_tvalid,
    .main_axis_tready, .main_axis_tlast,
    .result_valid(int32_result_valid), .result_ready(int32_result_ready),
    .result_col_valid(int32_result_col_valid),
    .result_psum(int32_result_psum), .result_tag(int32_result_tag),
    .result_layer(int32_result_layer),
    .result_filter(int32_result_filter),
    .result_image(int32_result_image), .result_x(int32_result_x),
    .result_y_base(int32_result_y_base),
    .layer_complete_valid(core_layer_complete_valid),
    .layer_complete_ready(core_layer_complete_ready),
    .layer_complete_id(core_layer_complete_id),
    .inference_done(core_inference_done),
    .inference_done_ready(core_inference_done_ready),
    .fault(core_fault), .completed_passes, .total_mac_count,
    .total_local_psum_hops, .filter_byte_requests, .filter_cache_hits,
    .filter_cache_misses, .filter_dma_line_fetches, .ifmap_byte_requests,
    .ifmap_cache_hits, .ifmap_cache_misses, .ifmap_dma_line_fetches,
    .partial_result_inputs, .accumulator_uram_reads,
    .accumulator_uram_writes, .final_result_outputs,
    .weight_dma_line_commands, .weight_dma_line_errors,
    .main_dma_line_commands, .main_dma_line_errors
  );

  alexnet_eyeriss_rs_parameter_cache #(
    .RECORD_COUNT(PARAMETER_RECORDS)
  ) u_parameter_cache (
    .clk, .rst, .load_start_valid(parameter_load_start_valid),
    .load_start_ready(parameter_load_start_ready),
    .load_axis_tdata(weight_axis_tdata),
    .load_axis_tkeep(weight_axis_tkeep),
    .load_axis_tvalid(weight_axis_tvalid && parameter_load_active),
    .load_axis_tready(parameter_load_axis_ready),
    .load_axis_tlast(weight_axis_tlast), .load_active(parameter_load_active),
    .load_done(parameter_load_done), .cache_valid(parameter_cache_valid),
    .request_valid(parameter_request_valid),
    .request_ready(parameter_request_ready),
    .request_index(parameter_request_index),
    .response_valid(parameter_response_valid),
    .response_ready(parameter_response_ready),
    .response_data(parameter_response_data), .fault(parameter_cache_fault),
    .completed_loads(parameter_blob_loads),
    .completed_lookups(parameter_lookups)
  );

  alexnet_eyeriss_rs_requant14 #(
    .TAG_W(TAG_W), .PARAMETER_RECORDS(PARAMETER_RECORDS)
  ) u_requant (
    .clk, .rst, .input_valid(int32_result_valid),
    .input_ready(int32_result_ready),
    .input_col_valid(int32_result_col_valid),
    .input_psum(int32_result_psum), .input_tag(int32_result_tag),
    .input_layer(int32_result_layer), .input_filter(int32_result_filter),
    .input_image(int32_result_image), .input_x(int32_result_x),
    .input_y_base(int32_result_y_base),
    .parameter_request_valid, .parameter_request_ready,
    .parameter_request_index, .parameter_response_valid,
    .parameter_response_ready, .parameter_response_data,
    .output_valid(result_valid), .output_ready(result_ready),
    .output_col_valid(result_col_valid), .output_values(result_values),
    .output_tag(result_tag), .output_layer(result_layer),
    .output_filter(result_filter), .output_image(result_image),
    .output_x(result_x), .output_y_base(result_y_base),
    .idle(postprocess_idle), .fault(postprocess_fault),
    .accepted_vectors(),
    .emitted_vectors(requantized_vectors)
  );

  assign layer_complete_valid = core_layer_complete_valid &&
                                postprocess_idle;
  assign layer_complete_id = core_layer_complete_id;
  assign core_layer_complete_ready = layer_complete_ready &&
                                     postprocess_idle;
  assign inference_done = core_inference_done && postprocess_idle;
  assign core_inference_done_ready = inference_done_ready &&
                                     postprocess_idle;
  assign fault = fault_q || core_fault || parameter_cache_fault ||
                 postprocess_fault;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      job_tag_q <= '0;
      input_base_q <= '0;
      activation_a_base_q <= '0;
      activation_b_base_q <= '0;
      weights_base_q <= '0;
      parameters_base_q <= '0;
      cached_parameters_base_q <= '1;
      parameter_dma_done_seen_q <= 1'b0;
      fault_q <= 1'b0;
    end else begin
      if ((state_q == ST_PARAMETER_STREAM ||
           state_q == ST_PARAMETER_DRAIN) && weight_dma_done)
        parameter_dma_done_seen_q <= 1'b1;

      if (core_fault || parameter_cache_fault || postprocess_fault ||
          ((state_q == ST_PARAMETER_STREAM ||
            state_q == ST_PARAMETER_DRAIN) && weight_dma_error)) begin
        fault_q <= 1'b1;
        state_q <= ST_FAILED;
      end else begin
        case (state_q)
          ST_IDLE: begin
            if (start_valid && start_ready) begin
              job_tag_q <= start_tag;
              input_base_q <= input_base;
              activation_a_base_q <= activation_a_base;
              activation_b_base_q <= activation_b_base;
              weights_base_q <= weights_base;
              parameters_base_q <= parameters_base;
              parameter_dma_done_seen_q <= 1'b0;
              if (parameters_base[3:0] != 0 ||
                  parameters_base[63:32] != 0) begin
                fault_q <= 1'b1;
                state_q <= ST_FAILED;
              end else if (parameter_cache_valid &&
                           cached_parameters_base_q == parameters_base) begin
                state_q <= ST_CORE_START;
              end else begin
                state_q <= ST_PARAMETER_COMMAND;
              end
            end
          end

          ST_PARAMETER_COMMAND: begin
            if (weight_dma_command_valid && weight_dma_command_ready) begin
              parameter_dma_done_seen_q <= 1'b0;
              state_q <= ST_PARAMETER_STREAM;
            end
          end

          ST_PARAMETER_STREAM: begin
            if (parameter_load_done) begin
              if (parameter_dma_done_seen_q || weight_dma_done) begin
                cached_parameters_base_q <= parameters_base_q;
                parameter_dma_done_seen_q <= 1'b0;
                state_q <= ST_CORE_START;
              end else begin
                state_q <= ST_PARAMETER_DRAIN;
              end
            end
          end

          ST_PARAMETER_DRAIN: begin
            if (parameter_dma_done_seen_q || weight_dma_done) begin
              cached_parameters_base_q <= parameters_base_q;
              parameter_dma_done_seen_q <= 1'b0;
              state_q <= ST_CORE_START;
            end
          end

          ST_CORE_START: begin
            if (core_start_valid && core_start_ready)
              state_q <= ST_COMPUTE;
          end

          ST_COMPUTE: begin
            if (core_inference_done && core_inference_done_ready)
              state_q <= ST_IDLE;
          end

          ST_FAILED: state_q <= ST_FAILED;
          default: begin
            fault_q <= 1'b1;
            state_q <= ST_FAILED;
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && state_q == ST_COMPUTE && !parameter_cache_valid)
      $fatal(1, "pure-RS compute started without a valid parameter cache");
  end
`endif

endmodule
