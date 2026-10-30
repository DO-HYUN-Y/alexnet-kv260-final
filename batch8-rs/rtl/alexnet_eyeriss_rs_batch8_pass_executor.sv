`timescale 1ns/1ps

// Control-plane executor for one pure Eyeriss RS processing pass.
//
// It programs the paper-style two-level GIN for horizontal filter multicast
// and diagonal ifmap multicast, requests one filter load, and then launches
// all eight images while that filter state remains resident in the PE set.
// The data mover/operation sequencer acknowledges the two phase interfaces;
// this block owns the mapping scan and the native batch-eight residency rule.
module alexnet_eyeriss_rs_batch8_pass_executor #(
  parameter int TAG_W = 16
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic                 pass_valid,
  output logic                 pass_ready,
  input  logic [TAG_W-1:0]     pass_tag,
  input  logic [3:0]           pass_layer_id,
  input  logic [3:0]           pass_filter_r,
  input  logic [5:0]           pass_e,
  input  logic [2:0]           pass_stride,
  input  logic [3:0]           pass_set_r,
  input  logic [3:0]           pass_set_t,

  output logic                 gin_cfg_valid,
  output logic                 gin_cfg_ifmap,
  output logic                 gin_cfg_xbus_valid,
  output logic [3:0]           gin_cfg_xbus_index,
  output logic [4:0]           gin_cfg_xbus_row_id,
  output logic                 gin_cfg_pe_valid,
  output logic [7:0]           gin_cfg_pe_index,
  output logic [5:0]           gin_cfg_pe_col_id,
  output logic                 gin_cfg_pe_enable,

  output logic                 filter_phase_valid,
  input  logic                 filter_phase_ready,
  input  logic                 filter_phase_done,
  input  logic                 filter_phase_error,

  output logic                 image_phase_valid,
  input  logic                 image_phase_ready,
  output logic [2:0]           image_phase_index,
  input  logic                 image_phase_done,
  input  logic                 image_phase_error,

  output logic [TAG_W-1:0]     active_tag,
  output logic [3:0]           active_layer_id,
  output logic                 pass_done,
  output logic                 pass_error,
  output logic [8:0]           configured_active_pes,
  output logic [8:0]           gin_config_cycles
);

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_CFG_FILTER_XBUS,
    ST_CFG_FILTER_PE,
    ST_CFG_IFMAP_XBUS,
    ST_CFG_IFMAP_PE,
    ST_ISSUE_FILTER,
    ST_WAIT_FILTER,
    ST_ISSUE_IMAGE,
    ST_WAIT_IMAGE,
    ST_DONE,
    ST_ERROR
  } state_t;

  state_t state_q;
  logic [TAG_W-1:0] tag_q;
  logic [3:0] layer_q;
  logic [3:0] filter_r_q;
  logic [5:0] e_q;
  logic [2:0] stride_q;
  logic [3:0] set_r_q;
  logic [3:0] set_t_q;
  logic [3:0] xbus_index_q;
  logic [7:0] pe_index_q;
  logic [2:0] image_index_q;
  logic mapping_cached_q;

  logic [3:0] physical_row;
  logic [3:0] physical_col;
  logic [3:0] logical_filter_row;
  logic [5:0] logical_e;
  logic [3:0] logical_set_r;
  logic [3:0] logical_set_t;
  logic pe_active;
  logic descriptor_valid;
  logic [12:0] active_product;
  logic layout_fold;
  logic layout_grid;
  logic layout_vertical;
  logic [4:0] filter_xbus_row_id;
  logic [4:0] ifmap_xbus_row_id;

  assign physical_row = pe_index_q / 14;
  assign physical_col = pe_index_q % 14;
  assign active_product = filter_r_q * e_q * set_r_q * set_t_q;
  assign layout_fold = (e_q > 14);
  assign layout_grid = (e_q <= 14) &&
                       ((filter_r_q * set_r_q) <= 12) &&
                       ((e_q * set_t_q) <= 14);
  assign layout_vertical = (e_q <= 14) && !layout_grid &&
                           ((filter_r_q * set_r_q * set_t_q) <= 12);
  assign descriptor_valid = (pass_filter_r >= 1) &&
                            (pass_filter_r <= 12) &&
                            (pass_e >= 1) && (pass_e <= 27) &&
                            (pass_stride >= 1) && (pass_stride <= 4) &&
                            (pass_set_r >= 1) && (pass_set_t >= 1) &&
                            (($unsigned(pass_filter_r) *
                              $unsigned(pass_e) *
                              $unsigned(pass_set_r) *
                              $unsigned(pass_set_t)) <= 168) &&
                            (((pass_e > 14) &&
                              (pass_set_r == 1) && (pass_set_t == 1) &&
                              (($unsigned(pass_filter_r) << 1) <= 12)) ||
                             ((pass_e <= 14) &&
                              (((pass_filter_r * pass_set_r) <= 12) &&
                               ((pass_e * pass_set_t) <= 14) ||
                               ((pass_filter_r * pass_set_r * pass_set_t) <= 12))));

  always_comb begin
    logical_filter_row = '0;
    logical_e = '0;
    logical_set_r = '0;
    logical_set_t = '0;
    pe_active = 1'b0;
    if (layout_fold) begin
      if ((physical_row < filter_r_q) && (physical_col < 14)) begin
        pe_active = 1'b1;
        logical_filter_row = physical_row;
        logical_e = physical_col;
      end else if ((physical_row >= filter_r_q) &&
                   (physical_row < (filter_r_q << 1)) &&
                   (physical_col < (e_q - 14))) begin
        pe_active = 1'b1;
        logical_filter_row = physical_row - filter_r_q;
        logical_e = physical_col + 14;
      end
    end else if (layout_grid) begin
      pe_active = (physical_row < (filter_r_q * set_r_q)) &&
                  (physical_col < (e_q * set_t_q));
      logical_filter_row = physical_row % filter_r_q;
      logical_set_r = physical_row / filter_r_q;
      logical_e = physical_col % e_q;
      logical_set_t = physical_col / e_q;
    end else if (layout_vertical) begin
      pe_active = (physical_row < (filter_r_q * set_r_q * set_t_q)) &&
                  (physical_col < e_q);
      logical_filter_row = physical_row % filter_r_q;
      logical_set_r = (physical_row / filter_r_q) % set_r_q;
      logical_set_t = (physical_row / filter_r_q) / set_r_q;
      logical_e = physical_col;
    end
  end

  always_comb begin
    filter_xbus_row_id = 5'h1f;
    ifmap_xbus_row_id = 5'h1f;
    if (layout_fold) begin
      if (xbus_index_q < (filter_r_q << 1)) begin
        filter_xbus_row_id = xbus_index_q % filter_r_q;
        ifmap_xbus_row_id = 5'd0;
      end
    end else if (layout_grid) begin
      if (xbus_index_q < (filter_r_q * set_r_q)) begin
        filter_xbus_row_id = xbus_index_q;
        ifmap_xbus_row_id = xbus_index_q / filter_r_q;
      end
    end else if (layout_vertical) begin
      if (xbus_index_q < (filter_r_q * set_r_q * set_t_q)) begin
        filter_xbus_row_id = xbus_index_q;
        ifmap_xbus_row_id = (xbus_index_q / filter_r_q) % set_r_q;
      end
    end
  end

  assign pass_ready = (state_q == ST_IDLE);
  assign active_tag = tag_q;
  assign active_layer_id = layer_q;
  assign image_phase_index = image_index_q;
  assign pass_done = (state_q == ST_DONE);
  assign pass_error = (state_q == ST_ERROR);
  assign configured_active_pes = active_product[8:0];

  always_comb begin
    gin_cfg_valid = 1'b0;
    gin_cfg_ifmap = 1'b0;
    gin_cfg_xbus_valid = 1'b0;
    gin_cfg_xbus_index = xbus_index_q;
    gin_cfg_xbus_row_id = 5'h1f;
    gin_cfg_pe_valid = 1'b0;
    gin_cfg_pe_index = pe_index_q;
    gin_cfg_pe_col_id = '0;
    gin_cfg_pe_enable = pe_active;
    filter_phase_valid = 1'b0;
    image_phase_valid = 1'b0;

    case (state_q)
      ST_CFG_FILTER_XBUS: begin
        gin_cfg_valid = 1'b1;
        gin_cfg_xbus_valid = 1'b1;
        gin_cfg_xbus_row_id = filter_xbus_row_id;
      end
      ST_CFG_FILTER_PE: begin
        gin_cfg_valid = 1'b1;
        gin_cfg_pe_valid = 1'b1;
        gin_cfg_pe_col_id = layout_grid ? logical_set_t : 6'd0;
      end
      ST_CFG_IFMAP_XBUS: begin
        gin_cfg_valid = 1'b1;
        gin_cfg_ifmap = 1'b1;
        gin_cfg_xbus_valid = 1'b1;
        gin_cfg_xbus_row_id = ifmap_xbus_row_id;
      end
      ST_CFG_IFMAP_PE: begin
        gin_cfg_valid = 1'b1;
        gin_cfg_ifmap = 1'b1;
        gin_cfg_pe_valid = 1'b1;
        gin_cfg_pe_col_id = logical_filter_row + logical_e * stride_q;
      end
      ST_ISSUE_FILTER: filter_phase_valid = 1'b1;
      ST_ISSUE_IMAGE: image_phase_valid = 1'b1;
      default: begin end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      tag_q <= '0;
      layer_q <= '0;
      filter_r_q <= '0;
      e_q <= '0;
      stride_q <= '0;
      set_r_q <= '0;
      set_t_q <= '0;
      xbus_index_q <= '0;
      pe_index_q <= '0;
      image_index_q <= '0;
      mapping_cached_q <= 1'b0;
      gin_config_cycles <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (pass_valid) begin
            tag_q <= pass_tag;
            layer_q <= pass_layer_id;
            filter_r_q <= pass_filter_r;
            e_q <= pass_e;
            stride_q <= pass_stride;
            set_r_q <= pass_set_r;
            set_t_q <= pass_set_t;
            xbus_index_q <= '0;
            pe_index_q <= '0;
            image_index_q <= '0;
            gin_config_cycles <= '0;
            if (!descriptor_valid) begin
              state_q <= ST_ERROR;
            end else if (mapping_cached_q &&
                         (pass_filter_r == filter_r_q) &&
                         (pass_e == e_q) &&
                         (pass_stride == stride_q) &&
                         (pass_set_r == set_r_q) &&
                         (pass_set_t == set_t_q)) begin
              state_q <= ST_ISSUE_FILTER;
            end else begin
              mapping_cached_q <= 1'b1;
              state_q <= ST_CFG_FILTER_XBUS;
            end
          end
        end
        ST_CFG_FILTER_XBUS: begin
          gin_config_cycles <= gin_config_cycles + 1'b1;
          if (xbus_index_q == 11) begin
            pe_index_q <= '0;
            state_q <= ST_CFG_FILTER_PE;
          end else xbus_index_q <= xbus_index_q + 1'b1;
        end
        ST_CFG_FILTER_PE: begin
          gin_config_cycles <= gin_config_cycles + 1'b1;
          if (pe_index_q == 167) begin
            xbus_index_q <= '0;
            state_q <= ST_CFG_IFMAP_XBUS;
          end else pe_index_q <= pe_index_q + 1'b1;
        end
        ST_CFG_IFMAP_XBUS: begin
          gin_config_cycles <= gin_config_cycles + 1'b1;
          if (xbus_index_q == 11) begin
            pe_index_q <= '0;
            state_q <= ST_CFG_IFMAP_PE;
          end else xbus_index_q <= xbus_index_q + 1'b1;
        end
        ST_CFG_IFMAP_PE: begin
          gin_config_cycles <= gin_config_cycles + 1'b1;
          if (pe_index_q == 167)
            state_q <= ST_ISSUE_FILTER;
          else pe_index_q <= pe_index_q + 1'b1;
        end
        ST_ISSUE_FILTER: begin
          if (filter_phase_ready)
            state_q <= ST_WAIT_FILTER;
        end
        ST_WAIT_FILTER: begin
          if (filter_phase_error)
            state_q <= ST_ERROR;
          else if (filter_phase_done) begin
            image_index_q <= '0;
            state_q <= ST_ISSUE_IMAGE;
          end
        end
        ST_ISSUE_IMAGE: begin
          if (image_phase_ready)
            state_q <= ST_WAIT_IMAGE;
        end
        ST_WAIT_IMAGE: begin
          if (image_phase_error)
            state_q <= ST_ERROR;
          else if (image_phase_done) begin
            if (image_index_q == 7)
              state_q <= ST_DONE;
            else begin
              image_index_q <= image_index_q + 1'b1;
              state_q <= ST_ISSUE_IMAGE;
            end
          end
        end
        ST_DONE, ST_ERROR: state_q <= ST_IDLE;
        default: state_q <= ST_ERROR;
      endcase
    end
  end

endmodule
