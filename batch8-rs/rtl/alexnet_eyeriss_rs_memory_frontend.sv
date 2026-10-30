`timescale 1ns/1ps

// Board-facing source service for the pure-RS core.  It translates logical
// coordinates into the frozen DDR layout and services them through separate
// 128-bit filter and ifmap line-read channels.
module alexnet_eyeriss_rs_memory_frontend (
  input  logic         clk,
  input  logic         rst,
  input  logic [63:0]  input_base,
  input  logic [63:0]  activation_a_base,
  input  logic [63:0]  activation_b_base,
  input  logic [63:0]  weights_base,

  input  logic         filter_request_valid,
  input  logic [3:0]   filter_request_layer,
  input  logic [12:0]  filter_request_filter,
  input  logic [13:0]  filter_request_channel,
  input  logic [3:0]   filter_request_y,
  input  logic [3:0]   filter_request_x,
  output logic         filter_data_valid,
  input  logic         filter_data_ready,
  output logic [7:0]   filter_data,
  output logic         filter_data_error,

  input  logic         ifmap_request_valid,
  input  logic [3:0]   ifmap_request_layer,
  input  logic [2:0]   ifmap_request_image,
  input  logic [13:0]  ifmap_request_channel,
  input  logic signed [8:0] ifmap_request_y,
  input  logic signed [8:0] ifmap_request_x,
  output logic         ifmap_data_valid,
  input  logic         ifmap_data_ready,
  output logic [7:0]   ifmap_data,
  output logic         ifmap_data_error,

  output logic         filter_line_request_valid,
  input  logic         filter_line_request_ready,
  output logic [63:0]  filter_line_request_address,
  input  logic         filter_line_response_valid,
  output logic         filter_line_response_ready,
  input  logic [127:0] filter_line_response_data,
  input  logic         filter_line_response_error,

  output logic         ifmap_line_request_valid,
  input  logic         ifmap_line_request_ready,
  output logic [63:0]  ifmap_line_request_address,
  input  logic         ifmap_line_response_valid,
  output logic         ifmap_line_response_ready,
  input  logic [127:0] ifmap_line_response_data,
  input  logic         ifmap_line_response_error,

  output logic         fault,
  output logic [63:0]  filter_byte_requests,
  output logic [63:0]  filter_cache_hits,
  output logic [63:0]  filter_cache_misses,
  output logic [63:0]  filter_dma_line_fetches,
  output logic [63:0]  ifmap_byte_requests,
  output logic [63:0]  ifmap_cache_hits,
  output logic [63:0]  ifmap_cache_misses,
  output logic [63:0]  ifmap_dma_line_fetches
);

  logic filter_address_valid, filter_address_error;
  logic [63:0] filter_byte_address_comb, filter_line_address_unused;
  logic [3:0] filter_byte_select_unused;
  logic [63:0] filter_relative_offset;
  logic ifmap_address_valid, ifmap_address_error;
  logic [63:0] ifmap_byte_address_comb, ifmap_line_address_unused;
  logic [3:0] ifmap_byte_select_unused;
  logic [63:0] ifmap_relative_offset, ifmap_selected_base;

  logic filter_cache_request_ready;
  logic filter_cache_response_valid, filter_cache_response_ready;
  logic [7:0] filter_cache_response_data;
  logic filter_cache_response_error;
  logic ifmap_cache_request_ready;
  logic ifmap_cache_response_valid, ifmap_cache_response_ready;
  logic [7:0] ifmap_cache_response_data;
  logic ifmap_cache_response_error;

  // Register the logical-coordinate boundary before address arithmetic.  This
  // breaks the long core-coordinate -> 64-bit address -> core-ready path and
  // keeps one request active until its byte response is consumed.
  logic filter_request_active_q;
  logic [3:0] filter_request_layer_q;
  logic [12:0] filter_request_filter_q;
  logic [13:0] filter_request_channel_q;
  logic [3:0] filter_request_y_q, filter_request_x_q;
  logic ifmap_request_active_q;
  logic [3:0] ifmap_request_layer_q;
  logic [2:0] ifmap_request_image_q;
  logic [13:0] ifmap_request_channel_q;
  logic signed [8:0] ifmap_request_y_q, ifmap_request_x_q;
  logic filter_offset_valid_q, filter_offset_error_q;
  logic [63:0] filter_relative_offset_q, filter_base_q;
  logic filter_address_ready_q;
  logic [63:0] filter_byte_address_q;
  logic ifmap_offset_valid_q, ifmap_offset_error_q;
  logic [63:0] ifmap_relative_offset_q, ifmap_base_q;
  logic ifmap_address_ready_q;
  logic [63:0] ifmap_byte_address_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      filter_request_active_q <= 1'b0;
      filter_request_layer_q <= '0;
      filter_request_filter_q <= '0;
      filter_request_channel_q <= '0;
      filter_request_y_q <= '0;
      filter_request_x_q <= '0;
      filter_offset_valid_q <= 1'b0;
      filter_offset_error_q <= 1'b0;
      filter_relative_offset_q <= '0;
      filter_base_q <= '0;
      filter_address_ready_q <= 1'b0;
      filter_byte_address_q <= '0;
      ifmap_request_active_q <= 1'b0;
      ifmap_request_layer_q <= '0;
      ifmap_request_image_q <= '0;
      ifmap_request_channel_q <= '0;
      ifmap_request_y_q <= '0;
      ifmap_request_x_q <= '0;
      ifmap_offset_valid_q <= 1'b0;
      ifmap_offset_error_q <= 1'b0;
      ifmap_relative_offset_q <= '0;
      ifmap_base_q <= '0;
      ifmap_address_ready_q <= 1'b0;
      ifmap_byte_address_q <= '0;
    end else begin
      if (!filter_request_active_q && filter_request_valid) begin
        filter_request_active_q <= 1'b1;
        filter_request_layer_q <= filter_request_layer;
        filter_request_filter_q <= filter_request_filter;
        filter_request_channel_q <= filter_request_channel;
        filter_request_y_q <= filter_request_y;
        filter_request_x_q <= filter_request_x;
        filter_offset_valid_q <= 1'b0;
        filter_offset_error_q <= 1'b0;
        filter_address_ready_q <= 1'b0;
      end else if (filter_data_valid && filter_data_ready) begin
        filter_request_active_q <= 1'b0;
        filter_offset_valid_q <= 1'b0;
        filter_offset_error_q <= 1'b0;
        filter_address_ready_q <= 1'b0;
      end else if (filter_request_active_q) begin
        if (!filter_offset_valid_q && !filter_offset_error_q) begin
          if (filter_address_error) begin
            filter_offset_error_q <= 1'b1;
          end else if (filter_address_valid) begin
            filter_relative_offset_q <= filter_relative_offset;
            filter_base_q <= weights_base;
            filter_offset_valid_q <= 1'b1;
          end
        end else if (filter_offset_valid_q && !filter_address_ready_q) begin
          filter_byte_address_q <= filter_base_q + filter_relative_offset_q;
          filter_address_ready_q <= 1'b1;
        end
      end

      if (!ifmap_request_active_q && ifmap_request_valid) begin
        ifmap_request_active_q <= 1'b1;
        ifmap_request_layer_q <= ifmap_request_layer;
        ifmap_request_image_q <= ifmap_request_image;
        ifmap_request_channel_q <= ifmap_request_channel;
        ifmap_request_y_q <= ifmap_request_y;
        ifmap_request_x_q <= ifmap_request_x;
        ifmap_offset_valid_q <= 1'b0;
        ifmap_offset_error_q <= 1'b0;
        ifmap_address_ready_q <= 1'b0;
      end else if (ifmap_data_valid && ifmap_data_ready) begin
        ifmap_request_active_q <= 1'b0;
        ifmap_offset_valid_q <= 1'b0;
        ifmap_offset_error_q <= 1'b0;
        ifmap_address_ready_q <= 1'b0;
      end else if (ifmap_request_active_q) begin
        if (!ifmap_offset_valid_q && !ifmap_offset_error_q) begin
          if (ifmap_address_error) begin
            ifmap_offset_error_q <= 1'b1;
          end else if (ifmap_address_valid) begin
            ifmap_relative_offset_q <= ifmap_relative_offset;
            ifmap_base_q <= ifmap_selected_base;
            ifmap_offset_valid_q <= 1'b1;
          end
        end else if (ifmap_offset_valid_q && !ifmap_address_ready_q) begin
          ifmap_byte_address_q <= ifmap_base_q + ifmap_relative_offset_q;
          ifmap_address_ready_q <= 1'b1;
        end
      end
    end
  end

  alexnet_eyeriss_rs_board_address_gen u_address (
    .input_base, .activation_a_base, .activation_b_base, .weights_base,
    .filter_request_valid(filter_request_active_q),
    .filter_request_layer(filter_request_layer_q),
    .filter_request_filter(filter_request_filter_q),
    .filter_request_channel(filter_request_channel_q),
    .filter_request_y(filter_request_y_q),
    .filter_request_x(filter_request_x_q),
    .filter_address_valid, .filter_address_error,
    .filter_byte_address(filter_byte_address_comb),
    .filter_line_address(filter_line_address_unused),
    .filter_byte_select(filter_byte_select_unused),
    .filter_relative_offset,
    .ifmap_request_valid(ifmap_request_active_q),
    .ifmap_request_layer(ifmap_request_layer_q),
    .ifmap_request_image(ifmap_request_image_q),
    .ifmap_request_channel(ifmap_request_channel_q),
    .ifmap_request_y(ifmap_request_y_q),
    .ifmap_request_x(ifmap_request_x_q),
    .ifmap_address_valid, .ifmap_address_error,
    .ifmap_byte_address(ifmap_byte_address_comb),
    .ifmap_line_address(ifmap_line_address_unused),
    .ifmap_byte_select(ifmap_byte_select_unused),
    .ifmap_relative_offset, .ifmap_selected_base
  );

  alexnet_eyeriss_rs_dma_line_cache u_filter_cache (
    .clk, .rst,
    .byte_request_valid(filter_address_ready_q),
    .byte_request_ready(filter_cache_request_ready),
    .byte_request_address(filter_byte_address_q),
    .byte_response_valid(filter_cache_response_valid),
    .byte_response_ready(filter_cache_response_ready),
    .byte_response_data(filter_cache_response_data),
    .byte_response_error(filter_cache_response_error),
    .line_request_valid(filter_line_request_valid),
    .line_request_ready(filter_line_request_ready),
    .line_request_address(filter_line_request_address),
    .line_response_valid(filter_line_response_valid),
    .line_response_ready(filter_line_response_ready),
    .line_response_data(filter_line_response_data),
    .line_response_error(filter_line_response_error),
    .byte_requests(filter_byte_requests), .cache_hits(filter_cache_hits),
    .cache_misses(filter_cache_misses),
    .dma_line_fetches(filter_dma_line_fetches)
  );

  alexnet_eyeriss_rs_dma_line_cache u_ifmap_cache (
    .clk, .rst,
    .byte_request_valid(ifmap_address_ready_q),
    .byte_request_ready(ifmap_cache_request_ready),
    .byte_request_address(ifmap_byte_address_q),
    .byte_response_valid(ifmap_cache_response_valid),
    .byte_response_ready(ifmap_cache_response_ready),
    .byte_response_data(ifmap_cache_response_data),
    .byte_response_error(ifmap_cache_response_error),
    .line_request_valid(ifmap_line_request_valid),
    .line_request_ready(ifmap_line_request_ready),
    .line_request_address(ifmap_line_request_address),
    .line_response_valid(ifmap_line_response_valid),
    .line_response_ready(ifmap_line_response_ready),
    .line_response_data(ifmap_line_response_data),
    .line_response_error(ifmap_line_response_error),
    .byte_requests(ifmap_byte_requests), .cache_hits(ifmap_cache_hits),
    .cache_misses(ifmap_cache_misses),
    .dma_line_fetches(ifmap_dma_line_fetches)
  );

  // Invalid coordinates are completed with an error byte so the command
  // source cannot deadlock while the sticky fault reports the bad contract.
  assign filter_data_valid = filter_request_active_q &&
      (filter_offset_error_q || filter_cache_response_valid);
  assign filter_data = filter_offset_error_q ? 8'd0 :
                       filter_cache_response_data;
  assign filter_data_error = filter_request_active_q &&
      (filter_offset_error_q ||
       (filter_cache_response_valid && filter_cache_response_error));
  assign filter_cache_response_ready = filter_request_active_q &&
      filter_data_ready && !filter_offset_error_q;

  assign ifmap_data_valid = ifmap_request_active_q &&
      (ifmap_offset_error_q || ifmap_cache_response_valid);
  assign ifmap_data = ifmap_offset_error_q ? 8'd0 : ifmap_cache_response_data;
  assign ifmap_data_error = ifmap_request_active_q &&
      (ifmap_offset_error_q ||
       (ifmap_cache_response_valid && ifmap_cache_response_error));
  assign ifmap_cache_response_ready = ifmap_request_active_q &&
      ifmap_data_ready && !ifmap_offset_error_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      fault <= 1'b0;
    end else if ((filter_data_valid && filter_data_ready && filter_data_error) ||
                 (ifmap_data_valid && ifmap_data_ready && ifmap_data_error)) begin
      fault <= 1'b1;
    end
  end

endmodule
