`timescale 1ns/1ps

// Coordinate-to-DDR address translation for the frozen KV260 AlexNet image
// and row-stationary weight layouts.  Activations use N8-tile-major storage;
// convolution weights use N,ky,C,kx and FC weights use N,K.
(* use_dsp = "no" *)
module alexnet_eyeriss_rs_board_address_gen #(
  parameter logic [63:0] INPUT_IMAGE_STRIDE = 64'd401408,
  parameter logic [63:0] ACTIVATION_IMAGE_STRIDE = 64'd262144
) (
  input  logic [63:0]       input_base,
  input  logic [63:0]       activation_a_base,
  input  logic [63:0]       activation_b_base,
  input  logic [63:0]       weights_base,

  input  logic              filter_request_valid,
  input  logic [3:0]        filter_request_layer,
  input  logic [12:0]       filter_request_filter,
  input  logic [13:0]       filter_request_channel,
  input  logic [3:0]        filter_request_y,
  input  logic [3:0]        filter_request_x,
  output logic              filter_address_valid,
  output logic              filter_address_error,
  output logic [63:0]       filter_byte_address,
  output logic [63:0]       filter_line_address,
  output logic [3:0]        filter_byte_select,
  output logic [63:0]       filter_relative_offset,

  input  logic              ifmap_request_valid,
  input  logic [3:0]        ifmap_request_layer,
  input  logic [2:0]        ifmap_request_image,
  input  logic [13:0]       ifmap_request_channel,
  input  logic signed [8:0] ifmap_request_y,
  input  logic signed [8:0] ifmap_request_x,
  output logic              ifmap_address_valid,
  output logic              ifmap_address_error,
  output logic [63:0]       ifmap_byte_address,
  output logic [63:0]       ifmap_line_address,
  output logic [3:0]        ifmap_byte_select,
  output logic [63:0]       ifmap_relative_offset,
  output logic [63:0]       ifmap_selected_base
);

  logic [63:0] filter_layer_offset;
  logic [13:0] filter_channels, filter_k;
  logic [12:0] filter_count;
  logic [3:0] filter_rows, filter_cols;
  logic filter_geometry_valid, filter_fields_valid;
  logic [63:0] filter_linear_offset;

  logic [13:0] ifmap_channels;
  logic [8:0] ifmap_height, ifmap_width;
  logic [63:0] ifmap_image_base, ifmap_linear_offset;
  logic ifmap_geometry_valid, ifmap_fields_valid;
  logic [13:0] fc6_channel;
  logic [5:0] fc6_position;

  always_comb begin
    filter_layer_offset = '0;
    filter_channels = '0;
    filter_k = '0;
    filter_count = '0;
    filter_rows = '0;
    filter_cols = '0;
    filter_geometry_valid = 1'b1;
    case (filter_request_layer)
      4'd1: begin
        filter_layer_offset = 64'd0;
        filter_channels = 14'd3; filter_count = 13'd64;
        filter_rows = 4'd11; filter_cols = 4'd11; filter_k = 14'd363;
      end
      4'd2: begin
        filter_layer_offset = 64'd23232;
        filter_channels = 14'd64; filter_count = 13'd192;
        filter_rows = 4'd5; filter_cols = 4'd5; filter_k = 14'd1600;
      end
      4'd3: begin
        filter_layer_offset = 64'd330432;
        filter_channels = 14'd192; filter_count = 13'd384;
        filter_rows = 4'd3; filter_cols = 4'd3; filter_k = 14'd1728;
      end
      4'd4: begin
        filter_layer_offset = 64'd993984;
        filter_channels = 14'd384; filter_count = 13'd256;
        filter_rows = 4'd3; filter_cols = 4'd3; filter_k = 14'd3456;
      end
      4'd5: begin
        filter_layer_offset = 64'd1878720;
        filter_channels = 14'd256; filter_count = 13'd256;
        filter_rows = 4'd3; filter_cols = 4'd3; filter_k = 14'd2304;
      end
      4'd6: begin
        filter_layer_offset = 64'd2468544;
        filter_channels = 14'd9216; filter_count = 13'd4096;
        filter_rows = 4'd1; filter_cols = 4'd1; filter_k = 14'd9216;
      end
      4'd7: begin
        filter_layer_offset = 64'd40217280;
        filter_channels = 14'd4096; filter_count = 13'd4096;
        filter_rows = 4'd1; filter_cols = 4'd1; filter_k = 14'd4096;
      end
      4'd8: begin
        filter_layer_offset = 64'd56994496;
        filter_channels = 14'd4096; filter_count = 13'd1000;
        filter_rows = 4'd1; filter_cols = 4'd1; filter_k = 14'd4096;
      end
      default: filter_geometry_valid = 1'b0;
    endcase

    filter_fields_valid = filter_geometry_valid &&
        (filter_request_filter < filter_count) &&
        (filter_request_channel < filter_channels) &&
        (filter_request_y < filter_rows) &&
        (filter_request_x < filter_cols);
    filter_linear_offset = filter_layer_offset +
        64'(filter_request_filter) * filter_k +
        (64'(filter_request_y) * filter_channels +
         filter_request_channel) * filter_cols + filter_request_x;
    filter_byte_address = weights_base + filter_linear_offset;
    filter_line_address = {filter_byte_address[63:4], 4'b0000};
    filter_byte_select = filter_byte_address[3:0];
    filter_relative_offset = filter_linear_offset;
    filter_address_valid = filter_request_valid && filter_fields_valid;
    filter_address_error = filter_request_valid && !filter_address_valid;
  end

  always_comb begin
    ifmap_channels = '0;
    ifmap_height = '0;
    ifmap_width = '0;
    ifmap_image_base = '0;
    ifmap_geometry_valid = 1'b1;
    case (ifmap_request_layer)
      4'd1: begin
        ifmap_channels = 14'd3; ifmap_height = 9'd224; ifmap_width = 9'd224;
        ifmap_image_base = input_base +
                           64'(ifmap_request_image) * INPUT_IMAGE_STRIDE;
      end
      4'd2: begin
        ifmap_channels = 14'd64; ifmap_height = 9'd27; ifmap_width = 9'd27;
        ifmap_image_base = activation_a_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd3: begin
        ifmap_channels = 14'd192; ifmap_height = 9'd13; ifmap_width = 9'd13;
        ifmap_image_base = activation_b_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd4: begin
        ifmap_channels = 14'd384; ifmap_height = 9'd13; ifmap_width = 9'd13;
        ifmap_image_base = activation_a_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd5: begin
        ifmap_channels = 14'd256; ifmap_height = 9'd13; ifmap_width = 9'd13;
        ifmap_image_base = activation_b_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd6: begin
        ifmap_channels = 14'd9216; ifmap_height = 9'd1; ifmap_width = 9'd1;
        ifmap_image_base = activation_a_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd7: begin
        ifmap_channels = 14'd4096; ifmap_height = 9'd1; ifmap_width = 9'd1;
        ifmap_image_base = activation_b_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      4'd8: begin
        ifmap_channels = 14'd4096; ifmap_height = 9'd1; ifmap_width = 9'd1;
        ifmap_image_base = activation_a_base +
                           64'(ifmap_request_image) * ACTIVATION_IMAGE_STRIDE;
      end
      default: ifmap_geometry_valid = 1'b0;
    endcase

    ifmap_fields_valid = ifmap_geometry_valid &&
        (ifmap_request_channel < ifmap_channels) &&
        (ifmap_request_y >= 0) && (ifmap_request_y < $signed(ifmap_height)) &&
        (ifmap_request_x >= 0) && (ifmap_request_x < $signed(ifmap_width));
    fc6_channel = ifmap_request_channel / 36;
    fc6_position = ifmap_request_channel % 36;
    // Keep each frozen AlexNet geometry in a constant-coefficient expression.
    // This avoids synthesizing height/width as runtime variable multipliers on
    // the coordinate-to-offset critical path.
    case (ifmap_request_layer)
      4'd1: ifmap_linear_offset =
          ((64'(ifmap_request_channel >> 3) * 64'd50176 +
            64'($unsigned(ifmap_request_y)) * 64'd224 +
            $unsigned(ifmap_request_x)) << 3) +
          ifmap_request_channel[2:0];
      4'd2: ifmap_linear_offset =
          ((64'(ifmap_request_channel >> 3) * 64'd729 +
            64'($unsigned(ifmap_request_y)) * 64'd27 +
            $unsigned(ifmap_request_x)) << 3) +
          ifmap_request_channel[2:0];
      4'd3, 4'd4, 4'd5: ifmap_linear_offset =
          ((64'(ifmap_request_channel >> 3) * 64'd169 +
            64'($unsigned(ifmap_request_y)) * 64'd13 +
            $unsigned(ifmap_request_x)) << 3) +
          ifmap_request_channel[2:0];
      4'd6: ifmap_linear_offset =
          ((64'(fc6_channel >> 3) * 64'd36 + fc6_position) << 3) +
          fc6_channel[2:0];
      4'd7, 4'd8: ifmap_linear_offset = ifmap_request_channel;
      default: ifmap_linear_offset = '0;
    endcase
    ifmap_byte_address = ifmap_image_base + ifmap_linear_offset;
    ifmap_line_address = {ifmap_byte_address[63:4], 4'b0000};
    ifmap_byte_select = ifmap_byte_address[3:0];
    ifmap_relative_offset = ifmap_linear_offset;
    ifmap_selected_base = ifmap_image_base;
    ifmap_address_valid = ifmap_request_valid && ifmap_fields_valid;
    ifmap_address_error = ifmap_request_valid && !ifmap_address_valid;
  end

endmodule
