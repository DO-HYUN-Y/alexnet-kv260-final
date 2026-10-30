`timescale 1ns/1ps

// One-line read cache converting byte-coordinate RS requests into aligned
// 128-bit DMA reads.  The requester holds no transaction state: a request is
// accepted once, then the byte response is held until consumed.
module alexnet_eyeriss_rs_dma_line_cache (
  input  logic         clk,
  input  logic         rst,

  input  logic         byte_request_valid,
  output logic         byte_request_ready,
  input  logic [63:0]  byte_request_address,
  output logic         byte_response_valid,
  input  logic         byte_response_ready,
  output logic [7:0]   byte_response_data,
  output logic         byte_response_error,

  output logic         line_request_valid,
  input  logic         line_request_ready,
  output logic [63:0]  line_request_address,
  input  logic         line_response_valid,
  output logic         line_response_ready,
  input  logic [127:0] line_response_data,
  input  logic         line_response_error,

  output logic [63:0]  byte_requests,
  output logic [63:0]  cache_hits,
  output logic [63:0]  cache_misses,
  output logic [63:0]  dma_line_fetches
);

  typedef enum logic [1:0] {ST_IDLE, ST_COMMAND, ST_WAIT, ST_RESPONSE} state_t;
  state_t state_q;
  logic cache_valid_q;
  logic [59:0] cache_tag_q;
  logic [127:0] cache_data_q;
  logic [63:0] request_line_q;
  logic [3:0] request_select_q;
  logic [7:0] response_data_q;
  logic response_error_q;
  logic request_hit;

  assign request_hit = cache_valid_q &&
                       (cache_tag_q == byte_request_address[63:4]);
  assign byte_request_ready = state_q == ST_IDLE;
  assign byte_response_valid = state_q == ST_RESPONSE;
  assign byte_response_data = response_data_q;
  assign byte_response_error = response_error_q;
  assign line_request_valid = state_q == ST_COMMAND;
  assign line_request_address = request_line_q;
  assign line_response_ready = state_q == ST_WAIT;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      cache_valid_q <= 1'b0;
      cache_tag_q <= '0;
      cache_data_q <= '0;
      request_line_q <= '0;
      request_select_q <= '0;
      response_data_q <= '0;
      response_error_q <= 1'b0;
      byte_requests <= '0;
      cache_hits <= '0;
      cache_misses <= '0;
      dma_line_fetches <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (byte_request_valid && byte_request_ready) begin
            byte_requests <= byte_requests + 1'b1;
            request_line_q <= {byte_request_address[63:4], 4'b0000};
            request_select_q <= byte_request_address[3:0];
            response_error_q <= 1'b0;
            if (request_hit) begin
              response_data_q <=
                  cache_data_q[byte_request_address[3:0] * 8 +: 8];
              cache_hits <= cache_hits + 1'b1;
              state_q <= ST_RESPONSE;
            end else begin
              cache_misses <= cache_misses + 1'b1;
              state_q <= ST_COMMAND;
            end
          end
        end
        ST_COMMAND: begin
          if (line_request_valid && line_request_ready) begin
            dma_line_fetches <= dma_line_fetches + 1'b1;
            state_q <= ST_WAIT;
          end
        end
        ST_WAIT: begin
          if (line_response_valid && line_response_ready) begin
            response_data_q <=
                line_response_data[request_select_q * 8 +: 8];
            response_error_q <= line_response_error;
            if (!line_response_error) begin
              cache_valid_q <= 1'b1;
              cache_tag_q <= request_line_q[63:4];
              cache_data_q <= line_response_data;
            end
            state_q <= ST_RESPONSE;
          end
        end
        ST_RESPONSE: begin
          if (byte_response_valid && byte_response_ready)
            state_q <= ST_IDLE;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

endmodule
