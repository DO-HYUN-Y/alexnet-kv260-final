`timescale 1ns/1ps

// Expands one processing-pass filter phase into GIN multicast writes for the
// three 12x14 clusters.  Commands whose channel slot lies beyond the final
// partial channel group are emitted with source_required=0 so the adapter can
// write zero without issuing a DDR read.
module alexnet_eyeriss_rs_filter_load_sequencer (
  input  logic          clk,
  input  logic          rst,

  input  logic          start_valid,
  output logic          start_ready,
  input  logic [13:0]   channel_base,
  input  logic [7:0]    channel_count,
  input  logic [12:0]   filter_base,
  input  logic [9:0]    filter_count,
  input  logic [3:0]    filter_r,
  input  logic [3:0]    filter_s,
  input  logic [5:0]    map_e,
  input  logic [5:0]    map_p,
  input  logic [3:0]    map_q,
  input  logic [3:0]    map_r,
  input  logic [3:0]    map_t,

  output logic          command_valid,
  input  logic          command_ready,
  output logic [1:0]    command_cluster,
  output logic [4:0]    command_row_tag,
  output logic [5:0]    command_col_tag,
  output logic [7:0]    command_rf_addr,
  output logic          source_required,
  output logic [12:0]   source_filter,
  output logic [13:0]   source_channel,
  output logic [3:0]    source_filter_y,
  output logic [3:0]    source_filter_x,

  output logic          done,
  output logic          error,
  output logic [31:0]   emitted_commands,
  output logic [31:0]   source_bytes
);

  typedef enum logic [1:0] {ST_IDLE, ST_EMIT, ST_DONE, ST_ERROR} state_t;
  state_t state_q;

  logic [13:0] channel_base_q;
  logic [7:0] channel_count_q;
  logic [12:0] filter_base_q;
  logic [9:0] filter_count_q;
  logic [3:0] filter_r_q;
  logic [3:0] filter_s_q;
  logic [5:0] map_e_q;
  logic [5:0] map_p_q;
  logic [3:0] map_q_q;
  logic [3:0] map_r_q;
  logic [3:0] map_t_q;

  logic [1:0] cluster_q;
  logic [3:0] set_t_q;
  logic [5:0] p_q;
  logic [3:0] set_r_q;
  logic [3:0] q_q;
  logic [3:0] row_q;
  logic [3:0] s_q;

  logic [10:0] local_filter_slot;
  logic [7:0] local_channel_slot;
  logic [11:0] rf_addr_calc;
  logic filter_slot_valid;
  logic descriptor_valid;
  logic layout_fold;
  logic layout_grid;
  logic layout_vertical;
  logic advance;
  logic at_last;

  assign local_filter_slot = cluster_q * (map_p_q * map_t_q) +
                             set_t_q * map_p_q + p_q;
  assign local_channel_slot = set_r_q * map_q_q + q_q;
  assign rf_addr_calc = p_q * (map_q_q * filter_s_q) +
                        q_q * filter_s_q + s_q;
  assign filter_slot_valid = local_filter_slot < filter_count_q;
  assign source_required = local_channel_slot < channel_count_q;

  assign layout_fold = map_e_q > 14;
  assign layout_grid = (map_e_q <= 14) &&
                       ((filter_r_q * map_r_q) <= 12) &&
                       ((map_e_q * map_t_q) <= 14);
  assign layout_vertical = (map_e_q <= 14) && !layout_grid;

  assign descriptor_valid = (channel_count >= 1) &&
                            (filter_count >= 1) &&
                            (filter_r >= 1) && (filter_r <= 12) &&
                            (filter_s >= 1) && (filter_s <= 11) &&
                            (map_e >= 1) && (map_e <= 27) &&
                            (map_p >= 1) && (map_p <= 24) &&
                            (map_q >= 1) && (map_q <= 12) &&
                            (map_r >= 1) && (map_t >= 1) &&
                            ((map_p * map_q * filter_s) <= 224) &&
                            (channel_count <= (map_q * map_r)) &&
                            (filter_count <= (3 * map_p * map_t)) &&
                            (((map_e > 14) && (map_r == 1) &&
                              (map_t == 1) && ((filter_r << 1) <= 12)) ||
                             ((map_e <= 14) &&
                              ((((filter_r * map_r) <= 12) &&
                                ((map_e * map_t) <= 14)) ||
                               ((filter_r * map_r * map_t) <= 12))));

  assign start_ready = state_q == ST_IDLE;
  assign command_valid = (state_q == ST_EMIT) && filter_slot_valid;
  assign command_cluster = cluster_q;
  assign command_rf_addr = rf_addr_calc[7:0];
  assign source_filter = filter_base_q + local_filter_slot;
  assign source_channel = channel_base_q + local_channel_slot;
  assign source_filter_y = row_q;
  assign source_filter_x = s_q;
  assign done = state_q == ST_DONE;
  assign error = state_q == ST_ERROR;
  assign advance = (state_q == ST_EMIT) &&
                   (!filter_slot_valid || command_ready);
  assign at_last = (cluster_q == 2) && (set_t_q == map_t_q - 1'b1) &&
                   (p_q == map_p_q - 1'b1) &&
                   (set_r_q == map_r_q - 1'b1) &&
                   (q_q == map_q_q - 1'b1) &&
                   (row_q == filter_r_q - 1'b1) &&
                   (s_q == filter_s_q - 1'b1);

  always_comb begin
    command_row_tag = '0;
    command_col_tag = '0;
    if (layout_fold) begin
      command_row_tag = row_q;
    end else if (layout_grid) begin
      command_row_tag = set_r_q * filter_r_q + row_q;
      command_col_tag = set_t_q;
    end else if (layout_vertical) begin
      command_row_tag = (set_t_q * map_r_q + set_r_q) * filter_r_q +
                        row_q;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      channel_base_q <= '0;
      channel_count_q <= '0;
      filter_base_q <= '0;
      filter_count_q <= '0;
      filter_r_q <= '0;
      filter_s_q <= '0;
      map_e_q <= '0;
      map_p_q <= '0;
      map_q_q <= '0;
      map_r_q <= '0;
      map_t_q <= '0;
      cluster_q <= '0;
      set_t_q <= '0;
      p_q <= '0;
      set_r_q <= '0;
      q_q <= '0;
      row_q <= '0;
      s_q <= '0;
      emitted_commands <= '0;
      source_bytes <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start_valid) begin
            channel_base_q <= channel_base;
            channel_count_q <= channel_count;
            filter_base_q <= filter_base;
            filter_count_q <= filter_count;
            filter_r_q <= filter_r;
            filter_s_q <= filter_s;
            map_e_q <= map_e;
            map_p_q <= map_p;
            map_q_q <= map_q;
            map_r_q <= map_r;
            map_t_q <= map_t;
            cluster_q <= '0;
            set_t_q <= '0;
            p_q <= '0;
            set_r_q <= '0;
            q_q <= '0;
            row_q <= '0;
            s_q <= '0;
            emitted_commands <= '0;
            source_bytes <= '0;
            state_q <= descriptor_valid ? ST_EMIT : ST_ERROR;
          end
        end
        ST_EMIT: begin
          if (advance) begin
            if (filter_slot_valid) begin
              emitted_commands <= emitted_commands + 1'b1;
              if (source_required)
                source_bytes <= source_bytes + 1'b1;
            end
            if (at_last) begin
              state_q <= ST_DONE;
            end else if (s_q != filter_s_q - 1'b1) begin
              s_q <= s_q + 1'b1;
            end else begin
              s_q <= '0;
              if (row_q != filter_r_q - 1'b1) begin
                row_q <= row_q + 1'b1;
              end else begin
                row_q <= '0;
                if (q_q != map_q_q - 1'b1) begin
                  q_q <= q_q + 1'b1;
                end else begin
                  q_q <= '0;
                  if (set_r_q != map_r_q - 1'b1) begin
                    set_r_q <= set_r_q + 1'b1;
                  end else begin
                    set_r_q <= '0;
                    if (p_q != map_p_q - 1'b1) begin
                      p_q <= p_q + 1'b1;
                    end else begin
                      p_q <= '0;
                      if (set_t_q != map_t_q - 1'b1) begin
                        set_t_q <= set_t_q + 1'b1;
                      end else begin
                        set_t_q <= '0;
                        cluster_q <= cluster_q + 1'b1;
                      end
                    end
                  end
                end
              end
            end
          end
        end
        ST_DONE, ST_ERROR: state_q <= ST_IDLE;
        default: state_q <= ST_ERROR;
      endcase
    end
  end

endmodule
