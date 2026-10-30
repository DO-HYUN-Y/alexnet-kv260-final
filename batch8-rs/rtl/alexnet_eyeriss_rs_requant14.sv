`timescale 1ns/1ps

// Parameter-driven postprocess for one pure-RS result vector.  A result is a
// single output filter at one x coordinate and up to fourteen consecutive y
// coordinates, so all fourteen lanes share one channel parameter record.
// The deliberately serialized control path changes parameters every vector;
// the arithmetic itself remains fourteen-lane parallel and uses 14 DSP48E2s.
module alexnet_eyeriss_rs_requant14 #(
  parameter int TAG_W = 16,
  parameter int PARAMETER_RECORDS = 10344
) (
  input  logic                       clk,
  input  logic                       rst,

  input  logic                       input_valid,
  output logic                       input_ready,
  input  logic [13:0]                input_col_valid,
  input  logic signed [31:0]         input_psum [0:13],
  input  logic [TAG_W-1:0]           input_tag,
  input  logic [3:0]                 input_layer,
  input  logic [12:0]                input_filter,
  input  logic [2:0]                 input_image,
  input  logic [5:0]                 input_x,
  input  logic [5:0]                 input_y_base,

  output logic                       parameter_request_valid,
  input  logic                       parameter_request_ready,
  output logic [$clog2(PARAMETER_RECORDS)-1:0] parameter_request_index,
  input  logic                       parameter_response_valid,
  output logic                       parameter_response_ready,
  input  logic [127:0]               parameter_response_data,

  output logic                       output_valid,
  input  logic                       output_ready,
  output logic [13:0]                output_col_valid,
  output logic signed [7:0]          output_values [0:13],
  output logic [TAG_W-1:0]           output_tag,
  output logic [3:0]                 output_layer,
  output logic [12:0]                output_filter,
  output logic [2:0]                 output_image,
  output logic [5:0]                 output_x,
  output logic [5:0]                 output_y_base,

  output logic                       idle,
  output logic                       fault,
  output logic [63:0]                accepted_vectors,
  output logic [63:0]                emitted_vectors
);
  typedef enum logic [3:0] {
    ST_IDLE, ST_REQUEST, ST_PARAMETER, ST_BIAS, ST_PRODUCT,
    ST_PRODUCT_PIPE, ST_ROUND, ST_SATURATE, ST_OUTPUT
  } state_t;
  state_t state_q;

  localparam logic signed [32:0] SIGNED27_MIN = -33'sd67108864;
  localparam logic signed [32:0] SIGNED27_MAX =  33'sd67108863;

  logic [13:0] col_valid_q;
  logic signed [31:0] psum_q [0:13];
  logic [TAG_W-1:0] tag_q;
  logic [3:0] layer_q;
  logic [12:0] filter_q;
  logic [2:0] image_q;
  logic [5:0] x_q, y_base_q;
  logic [$clog2(PARAMETER_RECORDS)-1:0] record_index_q;

  logic signed [31:0] bias_q;
  logic signed [17:0] multiplier_q;
  logic [5:0] right_shift_q;
  logic relu_q;
  logic signed [32:0] biased_value [0:13];
  logic signed [26:0] biased_q [0:13];
  (* use_dsp = "yes" *) logic signed [44:0] product_q [0:13];
  logic signed [44:0] product_pipe_q [0:13];
  logic signed [45:0] rounded_q [0:13];
  logic signed [7:0] values_q [0:13];
  logic parameter_fields_valid;
  logic biased_range_valid;

  function automatic logic [13:0] layer_record_base(
      input logic [3:0] layer_id);
    case (layer_id)
      1: layer_record_base = 14'd0;
      2: layer_record_base = 14'd64;
      3: layer_record_base = 14'd256;
      4: layer_record_base = 14'd640;
      5: layer_record_base = 14'd896;
      6: layer_record_base = 14'd1152;
      7: layer_record_base = 14'd5248;
      8: layer_record_base = 14'd9344;
      default: layer_record_base = 14'd0;
    endcase
  endfunction

  function automatic logic signed [45:0] rounded_shift(
      input logic signed [44:0] value,
      input logic [5:0] right_shift);
    logic signed [44:0] rounding_bias;
    logic signed [44:0] adjusted_value;
    logic signed [21:0] coarse_value;
    logic signed [21:0] shifted_value;
    logic [5:0] shift_offset;
    begin
      rounding_bias = 45'sd1 <<< (right_shift - 1'b1);
      if (value[44])
        rounding_bias = rounding_bias - 1'b1;
      adjusted_value = value + rounding_bias;
      coarse_value = adjusted_value[44:23];
      shift_offset = right_shift - 6'd23;
      shifted_value = coarse_value >>> shift_offset;
      rounded_shift = {{24{shifted_value[21]}}, shifted_value};
    end
  endfunction

  function automatic logic signed [7:0] saturate_i8(
      input logic signed [45:0] value,
      input logic relu);
    begin
      if (relu && value < 0)
        saturate_i8 = 8'sd0;
      else if (value > 46'sd127)
        saturate_i8 = 8'sd127;
      else if (value < -46'sd128)
        saturate_i8 = -8'sd128;
      else
        saturate_i8 = value[7:0];
    end
  endfunction

  always_comb begin
    biased_range_valid = 1'b1;
    for (integer lane = 0; lane < 14; lane = lane + 1) begin
      biased_value[lane] =
          $signed({psum_q[lane][31], psum_q[lane]}) +
          $signed({bias_q[31], bias_q});
      if (col_valid_q[lane] &&
          (biased_value[lane] < SIGNED27_MIN ||
           biased_value[lane] > SIGNED27_MAX))
        biased_range_valid = 1'b0;
      output_values[lane] = values_q[lane];
    end
  end

  assign parameter_fields_valid =
      parameter_response_data[63:50] == 0 &&
      parameter_response_data[71:70] == 0 &&
      parameter_response_data[79:73] == 0 &&
      parameter_response_data[127:80] == 0 &&
      $signed(parameter_response_data[49:32]) >= 18'sd65540 &&
      $signed(parameter_response_data[49:32]) <= 18'sd131067 &&
      parameter_response_data[69:64] >= 6'd23 &&
      parameter_response_data[69:64] <= 6'd32 &&
      parameter_response_data[72] == (layer_q != 8);

  assign input_ready = state_q == ST_IDLE && !fault;
  assign parameter_request_valid = state_q == ST_REQUEST;
  assign parameter_request_index = record_index_q;
  assign parameter_response_ready = state_q == ST_PARAMETER;
  assign output_valid = state_q == ST_OUTPUT;
  assign output_col_valid = col_valid_q;
  assign output_tag = tag_q;
  assign output_layer = layer_q;
  assign output_filter = filter_q;
  assign output_image = image_q;
  assign output_x = x_q;
  assign output_y_base = y_base_q;
  assign idle = state_q == ST_IDLE;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      col_valid_q <= '0;
      tag_q <= '0;
      layer_q <= '0;
      filter_q <= '0;
      image_q <= '0;
      x_q <= '0;
      y_base_q <= '0;
      record_index_q <= '0;
      bias_q <= '0;
      multiplier_q <= '0;
      right_shift_q <= '0;
      relu_q <= 1'b0;
      fault <= 1'b0;
      accepted_vectors <= '0;
      emitted_vectors <= '0;
      for (integer lane = 0; lane < 14; lane = lane + 1) begin
        psum_q[lane] <= '0;
        biased_q[lane] <= '0;
        product_q[lane] <= '0;
        product_pipe_q[lane] <= '0;
        rounded_q[lane] <= '0;
        values_q[lane] <= '0;
      end
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (input_valid && input_ready) begin
            if (input_layer < 1 || input_layer > 8 ||
                input_col_valid == 0 ||
                14'(layer_record_base(input_layer) + input_filter) >=
                    14'(PARAMETER_RECORDS)) begin
              fault <= 1'b1;
            end else begin
              col_valid_q <= input_col_valid;
              tag_q <= input_tag;
              layer_q <= input_layer;
              filter_q <= input_filter;
              image_q <= input_image;
              x_q <= input_x;
              y_base_q <= input_y_base;
              record_index_q <= layer_record_base(input_layer) +
                                input_filter;
              for (integer lane = 0; lane < 14; lane = lane + 1)
                psum_q[lane] <= input_psum[lane];
              accepted_vectors <= accepted_vectors + 1'b1;
              state_q <= ST_REQUEST;
            end
          end
        end

        ST_REQUEST:
          if (parameter_request_valid && parameter_request_ready)
            state_q <= ST_PARAMETER;

        ST_PARAMETER: begin
          if (parameter_response_valid && parameter_response_ready) begin
            if (!parameter_fields_valid) begin
              fault <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              bias_q <= $signed(parameter_response_data[31:0]);
              multiplier_q <= $signed(parameter_response_data[49:32]);
              right_shift_q <= parameter_response_data[69:64];
              relu_q <= parameter_response_data[72];
              state_q <= ST_BIAS;
            end
          end
        end

        ST_BIAS: begin
          if (!biased_range_valid) begin
            fault <= 1'b1;
            state_q <= ST_IDLE;
          end else begin
            for (integer lane = 0; lane < 14; lane = lane + 1)
              biased_q[lane] <= col_valid_q[lane] ?
                  biased_value[lane][26:0] : '0;
            state_q <= ST_PRODUCT;
          end
        end

        ST_PRODUCT: begin
          for (integer lane = 0; lane < 14; lane = lane + 1)
            product_q[lane] <= biased_q[lane] * multiplier_q;
          state_q <= ST_PRODUCT_PIPE;
        end

        ST_PRODUCT_PIPE: begin
          for (integer lane = 0; lane < 14; lane = lane + 1)
            product_pipe_q[lane] <= product_q[lane];
          state_q <= ST_ROUND;
        end

        ST_ROUND: begin
          for (integer lane = 0; lane < 14; lane = lane + 1)
            rounded_q[lane] <= rounded_shift(product_pipe_q[lane],
                                               right_shift_q);
          state_q <= ST_SATURATE;
        end

        ST_SATURATE: begin
          for (integer lane = 0; lane < 14; lane = lane + 1)
            values_q[lane] <= col_valid_q[lane] ?
                saturate_i8(rounded_q[lane], relu_q) : 8'sd0;
          state_q <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          if (output_valid && output_ready) begin
            emitted_vectors <= emitted_vectors + 1'b1;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          fault <= 1'b1;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (!rst && output_valid && !output_ready)
      assert ($stable({output_col_valid, output_tag, output_layer,
                       output_filter, output_image, output_x,
                       output_y_base}));
  end
`endif

endmodule
