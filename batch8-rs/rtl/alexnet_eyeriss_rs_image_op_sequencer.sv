`timescale 1ns/1ps

// Expands one image phase of an AlexNet processing pass into diagonal ifmap
// loads, vector PE operations, and per-filter local-psum reductions.  The
// command interfaces are deliberately decoupled from AXI and from the core so
// the DMA/GLB adapter can apply backpressure without changing the RS schedule.
module alexnet_eyeriss_rs_image_op_sequencer #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,

  input  logic                       start_valid,
  output logic                       start_ready,
  input  logic [TAG_W-1:0]           start_tag,
  input  logic [3:0]                 layer_id,
  input  logic [2:0]                 image_index,
  input  logic [5:0]                 strip_y,
  input  logic [5:0]                 strip_rows,
  input  logic [13:0]                channel_base,
  input  logic [7:0]                 channel_count,
  input  logic [12:0]                filter_base,
  input  logic [9:0]                 filter_count,
  input  logic [5:0]                 output_width,
  input  logic [3:0]                 filter_r,
  input  logic [3:0]                 filter_s,
  input  logic [2:0]                 stride,
  input  logic [5:0]                 map_e,
  input  logic [5:0]                 map_p,
  input  logic [3:0]                 map_q,
  input  logic [3:0]                 map_r,
  input  logic [3:0]                 map_t,

  output logic                       ifmap_command_valid,
  input  logic                       ifmap_command_ready,
  output logic [4:0]                 ifmap_row_tag,
  output logic [5:0]                 ifmap_col_tag,
  output logic [3:0]                 ifmap_rf_addr,
  output logic                       ifmap_source_required,
  output logic [2:0]                 ifmap_source_image,
  output logic [13:0]                ifmap_source_channel,
  output logic signed [8:0]          ifmap_source_y,
  output logic signed [8:0]          ifmap_source_x,

  output logic                       op_command_valid,
  input  logic                       op_command_ready,
  output logic [2:0]                 op_cluster_enable,
  output logic [2:0][167:0]          op_mask,
  output logic [7:0]                 op_filter_addr,
  output logic [3:0]                 op_ifmap_addr,
  output logic [4:0]                 op_psum_addr,
  output logic                       op_first,
  output logic                       op_last,
  output logic [TAG_W-1:0]           op_tag,

  output logic                       reduce_command_valid,
  input  logic                       reduce_command_ready,
  input  logic                       reduce_command_done,
  input  logic                       reduce_command_error,
  output logic [1:0]                 reduce_cluster,
  output logic [3:0]                 reduce_rows,
  output logic [3:0]                 reduce_cols,
  output logic [3:0]                 reduce_start_row,
  output logic [3:0]                 reduce_start_col,
  output logic [TAG_W-1:0]           reduce_tag,
  output logic [12:0]                reduce_output_filter,
  output logic [2:0]                 reduce_output_image,
  output logic [5:0]                 reduce_output_x,
  output logic [5:0]                 reduce_output_y_base,

  output logic                       done,
  output logic                       error,
  output logic [31:0]                ifmap_commands,
  output logic [31:0]                ifmap_source_bytes,
  output logic [31:0]                op_vectors,
  output logic [63:0]                pe_mac_operations,
  output logic [31:0]                reductions
);

  typedef enum logic [3:0] {
    ST_IDLE, ST_IFMAP, ST_PREP_MASK, ST_PREP_COUNT, ST_OP,
    ST_REDUCE_ISSUE, ST_REDUCE_WAIT, ST_DONE, ST_ERROR
  } state_t;
  state_t state_q;

  logic [TAG_W-1:0] tag_q;
  logic [3:0] layer_q;
  logic [2:0] image_q;
  logic [5:0] strip_y_q, strip_rows_q;
  logic [13:0] channel_base_q;
  logic [7:0] channel_count_q;
  logic [12:0] filter_base_q;
  logic [9:0] filter_count_q;
  logic [5:0] output_width_q;
  logic [3:0] filter_r_q, filter_s_q;
  logic [2:0] stride_q;
  logic [5:0] map_e_q, map_p_q;
  logic [3:0] map_q_q, map_r_q, map_t_q;

  logic [5:0] output_x_q;
  logic [3:0] ifmap_set_r_q, ifmap_q_q, ifmap_s_q;
  logic [5:0] diagonal_q;
  logic [5:0] p_q;
  logic [3:0] op_q_q, op_s_q;
  logic [1:0] reduce_cluster_q;
  logic [3:0] reduce_set_t_q;
  logic       reduce_segment_q;

  logic layout_fold, layout_grid, layout_vertical;
  logic [6:0] diagonal_count;
  logic [7:0] ifmap_channel_slot;
  logic signed [8:0] source_y_calc, source_x_calc;
  logic [8:0] input_dim;
  logic [3:0] padding;
  logic fully_connected;
  logic descriptor_valid;
  logic [10:0] reduce_filter_slot;
  logic reduce_slot_valid, reduce_segment_valid;
  logic [2:0] any_op_mask;
  logic [2:0][167:0] op_mask_calc;
  logic [2:0][167:0] op_mask_q;
  logic [10:0] op_pe_count_q;

  integer cluster_i;
  integer pe_i;
  integer physical_row;
  integer physical_col;
  integer logical_e;
  integer logical_set_t;
  integer filter_slot;

  function automatic [8:0] countones168(input logic [167:0] value);
    integer bit_i;
    begin
      countones168 = '0;
      for (bit_i = 0; bit_i < 168; bit_i = bit_i + 1)
        countones168 = countones168 + value[bit_i];
    end
  endfunction

  assign layout_fold = map_e_q > 14;
  assign layout_grid = (map_e_q <= 14) &&
                       ((filter_r_q * map_r_q) <= 12) &&
                       ((map_e_q * map_t_q) <= 14);
  assign layout_vertical = (map_e_q <= 14) && !layout_grid;
  assign diagonal_count = filter_r_q + (strip_rows_q - 1'b1) * stride_q;
  assign ifmap_channel_slot = ifmap_set_r_q * map_q_q + ifmap_q_q;

  always_comb begin
    input_dim = 1;
    padding = 0;
    fully_connected = 1'b0;
    case (layer_q)
      // The board model is torchvision AlexNet: 224x224 input with pad=2.
      // This has the same 55x55 Conv1 output geometry as the historical
      // 227x227/no-padding form, but the DDR coordinate contract differs.
      4'd1: begin input_dim = 224; padding = 2; end
      4'd2: begin input_dim = 27; padding = 2; end
      4'd3, 4'd4, 4'd5: begin input_dim = 13; padding = 1; end
      4'd6, 4'd7, 4'd8: begin
        input_dim = 1; padding = 0; fully_connected = 1'b1;
      end
      default: begin input_dim = 1; padding = 0; end
    endcase
  end

  assign source_y_calc = $signed({1'b0, strip_y_q}) *
                         $signed({1'b0, stride_q}) +
                         $signed({1'b0, diagonal_q}) -
                         $signed({1'b0, padding});
  assign source_x_calc = $signed({1'b0, output_x_q}) *
                         $signed({1'b0, stride_q}) +
                         $signed({1'b0, ifmap_s_q}) -
                         $signed({1'b0, padding});

  assign descriptor_valid = (layer_id >= 1) && (layer_id <= 8) &&
                            (strip_rows >= 1) && (strip_rows <= map_e) &&
                            (channel_count >= 1) &&
                            (filter_count >= 1) &&
                            (output_width >= 1) &&
                            (filter_r >= 1) && (filter_r <= 12) &&
                            (filter_s >= 1) && (filter_s <= 11) &&
                            (stride >= 1) && (stride <= 4) &&
                            (map_e >= 1) && (map_e <= 27) &&
                            (map_p >= 1) && (map_p <= 24) &&
                            (map_q >= 1) && (map_q <= 12) &&
                            (map_r >= 1) && (map_t >= 1) &&
                            ((map_p * map_q * filter_s) <= 224) &&
                            (channel_count <= (map_q * map_r)) &&
                            (filter_count <= (3 * map_p * map_t));

  assign start_ready = state_q == ST_IDLE;
  assign done = state_q == ST_DONE;
  assign error = state_q == ST_ERROR;

  assign ifmap_command_valid = state_q == ST_IFMAP;
  assign ifmap_row_tag = ifmap_set_r_q;
  assign ifmap_col_tag = diagonal_q;
  assign ifmap_rf_addr = ifmap_q_q * filter_s_q + ifmap_s_q;
  assign ifmap_source_image = image_q;
  assign ifmap_source_channel = channel_base_q + ifmap_channel_slot;
  assign ifmap_source_y = fully_connected ? 9'sd0 : source_y_calc;
  assign ifmap_source_x = fully_connected ? 9'sd0 : source_x_calc;
  assign ifmap_source_required = (ifmap_channel_slot < channel_count_q) &&
                                 (fully_connected ||
                                  ((source_y_calc >= 0) &&
                                   (source_y_calc < $signed(input_dim)) &&
                                   (source_x_calc >= 0) &&
                                   (source_x_calc < $signed(input_dim))));

  assign op_mask = op_mask_q;

  always_comb begin
    op_mask_calc = '0;
    physical_row = 0;
    physical_col = 0;
    logical_e = 0;
    logical_set_t = 0;
    filter_slot = 0;
    for (cluster_i = 0; cluster_i < 3; cluster_i = cluster_i + 1) begin
      for (pe_i = 0; pe_i < 168; pe_i = pe_i + 1) begin
        physical_row = pe_i / 14;
        physical_col = pe_i % 14;
        logical_e = 0;
        logical_set_t = 0;
        if (layout_fold) begin
          if ((physical_row < filter_r_q) &&
              (physical_col < strip_rows_q)) begin
            logical_e = physical_col;
            logical_set_t = 0;
            filter_slot = cluster_i * (map_p_q * map_t_q) + p_q;
            if (filter_slot < filter_count_q)
              op_mask_calc[cluster_i][pe_i] = 1'b1;
          end else if ((physical_row >= filter_r_q) &&
                       (physical_row < (filter_r_q << 1)) &&
                       ((physical_col + 14) < strip_rows_q)) begin
            logical_e = physical_col + 14;
            logical_set_t = 0;
            filter_slot = cluster_i * (map_p_q * map_t_q) + p_q;
            if (filter_slot < filter_count_q)
              op_mask_calc[cluster_i][pe_i] = 1'b1;
          end
        end else if (layout_grid) begin
          if ((physical_row < (filter_r_q * map_r_q)) &&
              (physical_col < (map_e_q * map_t_q))) begin
            logical_e = physical_col % map_e_q;
            logical_set_t = physical_col / map_e_q;
            filter_slot = cluster_i * (map_p_q * map_t_q) +
                          logical_set_t * map_p_q + p_q;
            if ((logical_e < strip_rows_q) &&
                (filter_slot < filter_count_q))
              op_mask_calc[cluster_i][pe_i] = 1'b1;
          end
        end else if (layout_vertical) begin
          if ((physical_row < (filter_r_q * map_r_q * map_t_q)) &&
              (physical_col < map_e_q)) begin
            logical_e = physical_col;
            logical_set_t = (physical_row / filter_r_q) / map_r_q;
            filter_slot = cluster_i * (map_p_q * map_t_q) +
                          logical_set_t * map_p_q + p_q;
            if ((logical_e < strip_rows_q) &&
                (filter_slot < filter_count_q))
              op_mask_calc[cluster_i][pe_i] = 1'b1;
          end
        end
      end
    end
  end

  assign any_op_mask[0] = |op_mask_q[0];
  assign any_op_mask[1] = |op_mask_q[1];
  assign any_op_mask[2] = |op_mask_q[2];
  assign op_cluster_enable = any_op_mask;
  assign op_command_valid = (state_q == ST_OP) && (|any_op_mask);
  assign op_filter_addr = p_q * (map_q_q * filter_s_q) +
                          op_q_q * filter_s_q + op_s_q;
  assign op_ifmap_addr = op_q_q * filter_s_q + op_s_q;
  assign op_psum_addr = p_q[4:0];
  assign op_first = (op_q_q == 0) && (op_s_q == 0);
  assign op_last = (op_q_q == map_q_q - 1'b1) &&
                   (op_s_q == filter_s_q - 1'b1);
  assign op_tag = tag_q;

  assign reduce_filter_slot = reduce_cluster_q * (map_p_q * map_t_q) +
                              reduce_set_t_q * map_p_q + p_q;
  assign reduce_slot_valid = reduce_filter_slot < filter_count_q;
  assign reduce_segment_valid = !layout_fold || !reduce_segment_q ||
                                (strip_rows_q > 14);
  assign reduce_command_valid = (state_q == ST_REDUCE_ISSUE) &&
                                reduce_slot_valid && reduce_segment_valid;
  assign reduce_cluster = reduce_cluster_q;
  assign reduce_tag = tag_q;
  assign reduce_output_filter = filter_base_q + reduce_filter_slot;
  assign reduce_output_image = image_q;
  assign reduce_output_x = output_x_q;

  always_comb begin
    reduce_rows = filter_r_q * map_r_q;
    reduce_cols = strip_rows_q[3:0];
    reduce_start_row = '0;
    reduce_start_col = '0;
    reduce_output_y_base = strip_y_q;
    if (layout_fold) begin
      reduce_rows = filter_r_q;
      if (!reduce_segment_q) begin
        reduce_cols = (strip_rows_q > 14) ? 4'd14 : strip_rows_q[3:0];
      end else begin
        reduce_rows = filter_r_q;
        reduce_cols = strip_rows_q - 14;
        reduce_start_row = filter_r_q;
        reduce_output_y_base = strip_y_q + 14;
      end
    end else if (layout_grid) begin
      reduce_start_col = reduce_set_t_q * map_e_q;
    end else if (layout_vertical) begin
      reduce_start_row = reduce_set_t_q * filter_r_q * map_r_q;
    end
  end

  task automatic advance_reduction;
    begin
      if (layout_fold && !reduce_segment_q) begin
        reduce_segment_q <= 1'b1;
        state_q <= ST_REDUCE_ISSUE;
      end else begin
        reduce_segment_q <= 1'b0;
        if (reduce_set_t_q != map_t_q - 1'b1) begin
          reduce_set_t_q <= reduce_set_t_q + 1'b1;
          state_q <= ST_REDUCE_ISSUE;
        end else begin
          reduce_set_t_q <= '0;
          if (reduce_cluster_q != 2) begin
            reduce_cluster_q <= reduce_cluster_q + 1'b1;
            state_q <= ST_REDUCE_ISSUE;
          end else begin
            reduce_cluster_q <= '0;
            if (p_q != map_p_q - 1'b1) begin
              p_q <= p_q + 1'b1;
              op_q_q <= '0;
              op_s_q <= '0;
              state_q <= ST_PREP_MASK;
            end else if (output_x_q != output_width_q - 1'b1) begin
              output_x_q <= output_x_q + 1'b1;
              ifmap_set_r_q <= '0;
              ifmap_q_q <= '0;
              ifmap_s_q <= '0;
              diagonal_q <= '0;
              p_q <= '0;
              op_q_q <= '0;
              op_s_q <= '0;
              state_q <= ST_IFMAP;
            end else begin
              state_q <= ST_DONE;
            end
          end
        end
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      tag_q <= '0;
      layer_q <= '0;
      image_q <= '0;
      strip_y_q <= '0;
      strip_rows_q <= '0;
      channel_base_q <= '0;
      channel_count_q <= '0;
      filter_base_q <= '0;
      filter_count_q <= '0;
      output_width_q <= '0;
      filter_r_q <= '0;
      filter_s_q <= '0;
      stride_q <= '0;
      map_e_q <= '0;
      map_p_q <= '0;
      map_q_q <= '0;
      map_r_q <= '0;
      map_t_q <= '0;
      output_x_q <= '0;
      ifmap_set_r_q <= '0;
      ifmap_q_q <= '0;
      ifmap_s_q <= '0;
      diagonal_q <= '0;
      p_q <= '0;
      op_q_q <= '0;
      op_s_q <= '0;
      reduce_cluster_q <= '0;
      reduce_set_t_q <= '0;
      reduce_segment_q <= 1'b0;
      op_mask_q <= '0;
      op_pe_count_q <= '0;
      ifmap_commands <= '0;
      ifmap_source_bytes <= '0;
      op_vectors <= '0;
      pe_mac_operations <= '0;
      reductions <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start_valid) begin
            tag_q <= start_tag;
            layer_q <= layer_id;
            image_q <= image_index;
            strip_y_q <= strip_y;
            strip_rows_q <= strip_rows;
            channel_base_q <= channel_base;
            channel_count_q <= channel_count;
            filter_base_q <= filter_base;
            filter_count_q <= filter_count;
            output_width_q <= output_width;
            filter_r_q <= filter_r;
            filter_s_q <= filter_s;
            stride_q <= stride;
            map_e_q <= map_e;
            map_p_q <= map_p;
            map_q_q <= map_q;
            map_r_q <= map_r;
            map_t_q <= map_t;
            output_x_q <= '0;
            ifmap_set_r_q <= '0;
            ifmap_q_q <= '0;
            ifmap_s_q <= '0;
            diagonal_q <= '0;
            p_q <= '0;
            op_q_q <= '0;
            op_s_q <= '0;
            reduce_cluster_q <= '0;
            reduce_set_t_q <= '0;
            reduce_segment_q <= 1'b0;
            ifmap_commands <= '0;
            ifmap_source_bytes <= '0;
            op_vectors <= '0;
            pe_mac_operations <= '0;
            reductions <= '0;
            state_q <= descriptor_valid ? ST_IFMAP : ST_ERROR;
          end
        end
        ST_IFMAP: begin
          if (ifmap_command_valid && ifmap_command_ready) begin
            ifmap_commands <= ifmap_commands + 1'b1;
            if (ifmap_source_required)
              ifmap_source_bytes <= ifmap_source_bytes + 1'b1;
            if (diagonal_q != diagonal_count - 1'b1) begin
              diagonal_q <= diagonal_q + 1'b1;
            end else begin
              diagonal_q <= '0;
              if (ifmap_s_q != filter_s_q - 1'b1) begin
                ifmap_s_q <= ifmap_s_q + 1'b1;
              end else begin
                ifmap_s_q <= '0;
                if (ifmap_q_q != map_q_q - 1'b1) begin
                  ifmap_q_q <= ifmap_q_q + 1'b1;
                end else begin
                  ifmap_q_q <= '0;
                  if (ifmap_set_r_q != map_r_q - 1'b1) begin
                    ifmap_set_r_q <= ifmap_set_r_q + 1'b1;
                  end else begin
                    ifmap_set_r_q <= '0;
                    p_q <= '0;
                    op_q_q <= '0;
                    op_s_q <= '0;
                    state_q <= ST_PREP_MASK;
                  end
                end
              end
            end
          end
        end
        ST_PREP_MASK: begin
          op_mask_q <= op_mask_calc;
          state_q <= ST_PREP_COUNT;
        end
        ST_PREP_COUNT: begin
          op_pe_count_q <= countones168(op_mask_q[0]) +
                           countones168(op_mask_q[1]) +
                           countones168(op_mask_q[2]);
          state_q <= ST_OP;
        end
        ST_OP: begin
          if (!(|any_op_mask) || (op_command_valid && op_command_ready)) begin
            if (|any_op_mask) begin
              op_vectors <= op_vectors + 1'b1;
              pe_mac_operations <= pe_mac_operations + op_pe_count_q;
            end
            if (op_s_q != filter_s_q - 1'b1) begin
              op_s_q <= op_s_q + 1'b1;
            end else begin
              op_s_q <= '0;
              if (op_q_q != map_q_q - 1'b1) begin
                op_q_q <= op_q_q + 1'b1;
              end else begin
                op_q_q <= '0;
                reduce_cluster_q <= '0;
                reduce_set_t_q <= '0;
                reduce_segment_q <= 1'b0;
                state_q <= ST_REDUCE_ISSUE;
              end
            end
          end
        end
        ST_REDUCE_ISSUE: begin
          if (!reduce_slot_valid || !reduce_segment_valid) begin
            advance_reduction();
          end else if (reduce_command_valid && reduce_command_ready) begin
            reductions <= reductions + 1'b1;
            state_q <= ST_REDUCE_WAIT;
          end
        end
        ST_REDUCE_WAIT: begin
          if (reduce_command_error)
            state_q <= ST_ERROR;
          else if (reduce_command_done)
            advance_reduction();
        end
        ST_DONE, ST_ERROR: state_q <= ST_IDLE;
        default: state_q <= ST_ERROR;
      endcase
    end
  end

endmodule
