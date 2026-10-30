`timescale 1ns/1ps

// Bridge one aligned 128-bit RS line request to the existing KV260 AXI-DMA
// MM2S command/stream contract.  DMA done may arrive before or after the AXIS
// beat; the response is released only after both have been observed.
module alexnet_eyeriss_rs_dma_line_reader (
  input  logic         clk,
  input  logic         rst,

  input  logic         line_request_valid,
  output logic         line_request_ready,
  input  logic [63:0]  line_request_address,
  output logic         line_response_valid,
  input  logic         line_response_ready,
  output logic [127:0] line_response_data,
  output logic         line_response_error,

  output logic         dma_command_valid,
  input  logic         dma_command_ready,
  output logic [31:0]  dma_command_address,
  output logic [25:0]  dma_command_length,
  input  logic         dma_armed,
  input  logic         dma_done,
  input  logic         dma_error,

  input  logic [127:0] s_axis_tdata,
  input  logic [15:0]  s_axis_tkeep,
  input  logic         s_axis_tvalid,
  output logic         s_axis_tready,
  input  logic         s_axis_tlast,

  output logic         fault,
  output logic [63:0]  accepted_requests,
  output logic [63:0]  issued_commands,
  output logic [63:0]  accepted_beats,
  output logic [63:0]  error_responses
);

  typedef enum logic [1:0] {ST_IDLE, ST_COMMAND, ST_WAIT, ST_RESPONSE} state_t;
  state_t state_q;
  logic [31:0] address_q;
  logic [127:0] response_data_q;
  logic response_error_q;
  logic data_seen_q, done_seen_q, armed_seen_q;
  logic request_address_valid, command_fire, beat_fire;
  logic transfer_complete;

  assign request_address_valid = (line_request_address[63:32] == 0) &&
                                 (line_request_address[3:0] == 0);
  assign line_request_ready = (state_q == ST_IDLE) && !fault;
  assign dma_command_valid = state_q == ST_COMMAND;
  assign dma_command_address = address_q;
  assign dma_command_length = 26'd16;
  assign command_fire = dma_command_valid && dma_command_ready;
  assign s_axis_tready = (state_q == ST_WAIT) && !data_seen_q;
  assign beat_fire = s_axis_tvalid && s_axis_tready;
  assign transfer_complete = (data_seen_q || beat_fire) &&
                             (done_seen_q || dma_done);
  assign line_response_valid = state_q == ST_RESPONSE;
  assign line_response_data = response_data_q;
  assign line_response_error = response_error_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      address_q <= '0;
      response_data_q <= '0;
      response_error_q <= 1'b0;
      data_seen_q <= 1'b0;
      done_seen_q <= 1'b0;
      armed_seen_q <= 1'b0;
      fault <= 1'b0;
      accepted_requests <= '0;
      issued_commands <= '0;
      accepted_beats <= '0;
      error_responses <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (line_request_valid && line_request_ready) begin
            accepted_requests <= accepted_requests + 1'b1;
            response_error_q <= 1'b0;
            data_seen_q <= 1'b0;
            done_seen_q <= 1'b0;
            armed_seen_q <= 1'b0;
            if (!request_address_valid) begin
              response_data_q <= '0;
              response_error_q <= 1'b1;
              fault <= 1'b1;
              error_responses <= error_responses + 1'b1;
              state_q <= ST_RESPONSE;
            end else begin
              address_q <= line_request_address[31:0];
              state_q <= ST_COMMAND;
            end
          end
        end

        ST_COMMAND: begin
          if (command_fire) begin
            issued_commands <= issued_commands + 1'b1;
            state_q <= ST_WAIT;
          end
        end

        ST_WAIT: begin
          if (dma_armed)
            armed_seen_q <= 1'b1;
          if (dma_done)
            done_seen_q <= 1'b1;
          if (beat_fire) begin
            response_data_q <= s_axis_tdata;
            data_seen_q <= 1'b1;
            accepted_beats <= accepted_beats + 1'b1;
            if (s_axis_tkeep != 16'hffff || !s_axis_tlast) begin
              response_error_q <= 1'b1;
              fault <= 1'b1;
              if (!response_error_q)
                error_responses <= error_responses + 1'b1;
            end
          end

          if (dma_error) begin
            response_error_q <= 1'b1;
            fault <= 1'b1;
            error_responses <= error_responses + 1'b1;
            state_q <= ST_RESPONSE;
          end else if (transfer_complete) begin
            if (!armed_seen_q && !dma_armed) begin
              response_error_q <= 1'b1;
              fault <= 1'b1;
              if (!response_error_q &&
                  !(beat_fire &&
                    (s_axis_tkeep != 16'hffff || !s_axis_tlast)))
                error_responses <= error_responses + 1'b1;
            end
            state_q <= ST_RESPONSE;
          end
        end

        ST_RESPONSE: begin
          if (line_response_valid && line_response_ready)
            state_q <= ST_IDLE;
        end

        default: begin
          fault <= 1'b1;
          state_q <= ST_RESPONSE;
          response_error_q <= 1'b1;
        end
      endcase
    end
  end

endmodule
