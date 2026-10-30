`timescale 1ns/1ps

// AlexNet processing-pass scheduler for three 12x14 Eyeriss RS clusters.
// One issued pass keeps its filter rows resident while all eight images are
// processed sequentially.  pass_done therefore means the complete batch of
// eight has crossed the PE clusters for that pass.
module alexnet_eyeriss_rs_batch8_pass_scheduler (
  input  logic          clk,
  input  logic          rst,

  input  logic          start_valid,
  output logic          start_ready,
  input  logic [15:0]   start_tag,

  output logic          pass_valid,
  input  logic          pass_ready,
  output logic [15:0]   pass_tag,
  output logic [3:0]    pass_layer_id,
  output logic [5:0]    pass_strip_y,
  output logic [5:0]    pass_strip_rows,
  output logic [13:0]   pass_channel_base,
  output logic [7:0]    pass_channel_count,
  output logic [12:0]   pass_filter_base,
  output logic [9:0]    pass_filter_count,
  output logic [5:0]    pass_output_width,
  output logic [3:0]    pass_filter_r,
  output logic [3:0]    pass_filter_s,
  output logic [5:0]    pass_e,
  output logic [2:0]    pass_stride,
  output logic [9:0]    pass_m,
  output logic [3:0]    pass_n,
  output logic [5:0]    pass_p,
  output logic [3:0]    pass_q,
  output logic [3:0]    pass_r,
  output logic [3:0]    pass_t,
  output logic          pass_load_ifmap,
  output logic          pass_load_filter,
  output logic          pass_keep_filter_for_batch,
  output logic          pass_psum_first,
  output logic          pass_psum_final,
  output logic [63:0]   pass_useful_macs,
  output logic [31:0]   pass_weight_bytes,

  input  logic          pass_done,
  input  logic          pass_error,

  output logic          layer_complete_valid,
  input  logic          layer_complete_ready,
  output logic [3:0]    layer_complete_id,
  output logic          inference_done,
  input  logic          inference_done_ready,
  output logic          fault,
  output logic [15:0]   completed_passes
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_ISSUE,
    ST_WAIT_PASS,
    ST_LAYER_BARRIER,
    ST_DONE,
    ST_FAULT
  } state_t;

  state_t state_q;
  logic [3:0]  layer_q;
  logic [5:0]  strip_y_q;
  logic [13:0] channel_base_q;
  logic [12:0] filter_base_q;
  logic [15:0] tag_q;

  logic [5:0]  layer_output_h;
  logic [5:0]  layer_output_w;
  logic [13:0] layer_channels;
  logic [12:0] layer_filters;
  logic [3:0]  layer_filter_r;
  logic [3:0]  layer_filter_s;
  logic [5:0]  map_e;
  logic [2:0]  layer_stride;
  logic [9:0]  map_m;
  logic [5:0]  map_p;
  logic [3:0]  map_q;
  logic [3:0]  map_r;
  logic [3:0]  map_t;
  logic [7:0]  channels_per_pass;
  logic [9:0]  filters_per_pass;
  logic [5:0]  current_strip_rows;
  logic [7:0]  current_channels;
  logic [9:0]  current_filters;
  logic        last_filter_group;
  logic        last_channel_group;
  logic        last_strip;

  logic [63:0] mac_product;
  logic [31:0] weight_product;

  always_comb begin
    layer_output_h = 6'd1;
    layer_output_w = 6'd1;
    layer_channels = 14'd1;
    layer_filters  = 13'd1;
    layer_filter_r = 4'd1;
    layer_filter_s = 4'd1;
    map_e = 6'd1;
    layer_stride = 3'd1;
    map_m = 10'd756;
    map_p = 6'd18;
    map_q = 4'd12;
    map_r = 4'd12;
    map_t = 4'd14;
    case (layer_q)
      4'd1: begin
        layer_output_h = 6'd55; layer_output_w = 6'd55;
        layer_channels = 14'd3; layer_filters = 13'd64;
        layer_filter_r = 4'd11; layer_filter_s = 4'd11;
        layer_stride = 3'd4;
        map_e = 6'd7; map_m = 10'd64;
        map_p = 6'd16; map_q = 4'd1; map_r = 4'd1; map_t = 4'd2;
      end
      4'd2: begin
        layer_output_h = 6'd27; layer_output_w = 6'd27;
        layer_channels = 14'd64; layer_filters = 13'd192;
        layer_filter_r = 4'd5; layer_filter_s = 4'd5;
        map_e = 6'd27; map_m = 10'd32;
        map_p = 6'd16; map_q = 4'd2; map_r = 4'd1; map_t = 4'd1;
      end
      4'd3: begin
        layer_output_h = 6'd13; layer_output_w = 6'd13;
        layer_channels = 14'd192; layer_filters = 13'd384;
        layer_filter_r = 4'd3; layer_filter_s = 4'd3;
        map_e = 6'd13; map_m = 10'd64;
        map_p = 6'd16; map_q = 4'd4; map_r = 4'd1; map_t = 4'd4;
      end
      4'd4: begin
        layer_output_h = 6'd13; layer_output_w = 6'd13;
        layer_channels = 14'd384; layer_filters = 13'd256;
        layer_filter_r = 4'd3; layer_filter_s = 4'd3;
        map_e = 6'd13; map_m = 10'd64;
        map_p = 6'd16; map_q = 4'd3; map_r = 4'd2; map_t = 4'd2;
      end
      4'd5: begin
        layer_output_h = 6'd13; layer_output_w = 6'd13;
        layer_channels = 14'd256; layer_filters = 13'd256;
        layer_filter_r = 4'd3; layer_filter_s = 4'd3;
        map_e = 6'd13; map_m = 10'd64;
        map_p = 6'd16; map_q = 4'd3; map_r = 4'd2; map_t = 4'd2;
      end
      4'd6: begin
        layer_channels = 14'd9216; layer_filters = 13'd4096;
      end
      4'd7: begin
        layer_channels = 14'd4096; layer_filters = 13'd4096;
      end
      4'd8: begin
        layer_channels = 14'd4096; layer_filters = 13'd1000;
      end
      default: begin end
    endcase
  end

  always_comb begin
    channels_per_pass = map_q * map_r;
    filters_per_pass  = map_p * map_t * 3;

    if ((strip_y_q + map_e) > layer_output_h)
      current_strip_rows = layer_output_h - strip_y_q;
    else
      current_strip_rows = map_e;

    if ((channel_base_q + channels_per_pass) > layer_channels)
      current_channels = layer_channels - channel_base_q;
    else
      current_channels = channels_per_pass;

    if ((filter_base_q + filters_per_pass) > layer_filters)
      current_filters = layer_filters - filter_base_q;
    else
      current_filters = filters_per_pass;

    last_filter_group = (filter_base_q + current_filters) >= layer_filters;
    last_channel_group = (channel_base_q + current_channels) >= layer_channels;
    last_strip = (strip_y_q + current_strip_rows) >= layer_output_h;

    mac_product = 64'(current_strip_rows) * 64'(layer_output_w) *
                  64'(current_channels) * 64'(current_filters) *
                  64'(layer_filter_r) * 64'(layer_filter_s) * 64'd8;
    weight_product = 32'(current_channels) * 32'(current_filters) *
                     32'(layer_filter_r) * 32'(layer_filter_s);
  end

  assign start_ready = (state_q == ST_IDLE);
  assign pass_valid = (state_q == ST_ISSUE);
  assign pass_tag = tag_q;
  assign pass_layer_id = layer_q;
  assign pass_strip_y = strip_y_q;
  assign pass_strip_rows = current_strip_rows;
  assign pass_channel_base = channel_base_q;
  assign pass_channel_count = current_channels;
  assign pass_filter_base = filter_base_q;
  assign pass_filter_count = current_filters;
  assign pass_output_width = layer_output_w;
  assign pass_filter_r = layer_filter_r;
  assign pass_filter_s = layer_filter_s;
  assign pass_e = map_e;
  assign pass_stride = layer_stride;
  assign pass_m = map_m;
  assign pass_n = 4'd8;
  assign pass_p = map_p;
  assign pass_q = map_q;
  assign pass_r = map_r;
  assign pass_t = map_t;
  // Channel groups are revisited for every filter tile, so a future GLB
  // adapter must make the active ifmap tile available on every pass.
  assign pass_load_ifmap = 1'b1;
  assign pass_load_filter = 1'b1;
  assign pass_keep_filter_for_batch = 1'b1;
  assign pass_psum_first = (channel_base_q == 0);
  assign pass_psum_final = last_channel_group;
  assign pass_useful_macs = mac_product;
  assign pass_weight_bytes = weight_product;
  assign layer_complete_valid = (state_q == ST_LAYER_BARRIER);
  assign layer_complete_id = layer_q;
  assign inference_done = (state_q == ST_DONE);
  assign fault = (state_q == ST_FAULT);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q          <= ST_IDLE;
      layer_q          <= 4'd1;
      strip_y_q        <= '0;
      channel_base_q   <= '0;
      filter_base_q    <= '0;
      tag_q            <= '0;
      completed_passes <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start_valid) begin
            layer_q          <= 4'd1;
            strip_y_q        <= '0;
            channel_base_q   <= '0;
            filter_base_q    <= '0;
            tag_q            <= start_tag;
            completed_passes <= '0;
            state_q          <= ST_ISSUE;
          end
        end

        ST_ISSUE: begin
          if (pass_valid && pass_ready)
            state_q <= ST_WAIT_PASS;
        end

        ST_WAIT_PASS: begin
          if (pass_error) begin
            state_q <= ST_FAULT;
          end else if (pass_done) begin
            completed_passes <= completed_passes + 1'b1;
            // Keep one output-filter tile fixed while walking every channel
            // group.  This bounds external channel-pass accumulation to one
            // filter tile instead of the complete layer.
            if (!last_channel_group) begin
              channel_base_q <= channel_base_q + channels_per_pass;
              state_q <= ST_ISSUE;
            end else if (!last_filter_group) begin
              channel_base_q <= '0;
              filter_base_q <= filter_base_q + filters_per_pass;
              state_q <= ST_ISSUE;
            end else if (!last_strip) begin
              filter_base_q <= '0;
              channel_base_q <= '0;
              strip_y_q <= strip_y_q + map_e;
              state_q <= ST_ISSUE;
            end else begin
              state_q <= ST_LAYER_BARRIER;
            end
          end
        end

        ST_LAYER_BARRIER: begin
          if (layer_complete_valid && layer_complete_ready) begin
            if (layer_q == 4'd8) begin
              state_q <= ST_DONE;
            end else begin
              layer_q <= layer_q + 1'b1;
              strip_y_q <= '0;
              channel_base_q <= '0;
              filter_base_q <= '0;
              state_q <= ST_ISSUE;
            end
          end
        end

        ST_DONE: begin
          if (inference_done_ready)
            state_q <= ST_IDLE;
        end

        default: state_q <= ST_FAULT;
      endcase
    end
  end

endmodule
