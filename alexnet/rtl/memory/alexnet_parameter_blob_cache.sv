`timescale 1ns/1ps

// Cache the complete frozen AlexNet requantization blob once, then replay one
// 128-byte N8 parameter record without returning to DDR.  The software format
// is 10,344 consecutive 128-bit channel records (1,293 N8 records).
//
// The RAM is deliberately a single-write/single-read store.  Loading and
// replay are mutually exclusive, so Vivado can map it to URAM rather than
// spending the remaining BRAM needed by the graph data path.
module alexnet_parameter_blob_cache #(
    parameter int TOTAL_BYTES = 165_504,
    parameter int BEAT_BYTES = 16,
    parameter int RECORD_BEATS = 8,
    parameter int RECORD_COUNT = 1_293
) (
    input logic clk,
    input logic rst,

    input  logic load_start_valid,
    output logic load_start_ready,
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0] s_axis_tkeep,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,
    output logic load_active,
    output logic load_done,
    output logic cache_valid,

    input  logic request_valid,
    output logic request_ready,
    input  logic [$clog2(RECORD_COUNT)-1:0] request_record_index,
    output logic [127:0] m_axis_tdata,
    output logic [15:0] m_axis_tkeep,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,

    output logic replay_active,
    output logic fault,
    output logic [31:0] completed_loads,
    output logic [31:0] completed_replays
);
  localparam int TOTAL_BEATS = TOTAL_BYTES / BEAT_BYTES;
  localparam int BEAT_ADDR_W = $clog2(TOTAL_BEATS);
  localparam int RECORD_INDEX_W = $clog2(RECORD_COUNT);

  (* ram_style = "ultra" *) logic [127:0] cache_memory [0:TOTAL_BEATS-1];

  logic loading_q, cache_valid_q, replay_active_q, fault_q;
  logic [BEAT_ADDR_W-1:0] load_address_q, read_address_q;
  logic [$clog2(RECORD_BEATS)-1:0] replay_beat_q;
  logic read_pending_q, output_valid_q;
  logic [127:0] output_data_q;
  logic output_last_q;
  logic load_fire, request_fire, output_fire;
  logic expected_load_last;

  assign load_start_ready = !loading_q && !replay_active_q &&
                            !read_pending_q && !output_valid_q && !fault_q;
  assign load_fire = s_axis_tvalid && s_axis_tready;
  assign s_axis_tready = loading_q;
  assign expected_load_last = load_address_q == TOTAL_BEATS-1;
  assign load_active = loading_q;
  assign cache_valid = cache_valid_q;

  assign request_ready = cache_valid_q && !loading_q && !replay_active_q &&
                         !read_pending_q && !output_valid_q && !fault_q;
  assign request_fire = request_valid && request_ready;
  assign replay_active = replay_active_q;

  assign m_axis_tdata = output_data_q;
  assign m_axis_tkeep = 16'hffff;
  assign m_axis_tvalid = output_valid_q;
  assign m_axis_tlast = output_last_q;
  assign output_fire = m_axis_tvalid && m_axis_tready;
  assign fault = fault_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      loading_q <= 1'b0;
      cache_valid_q <= 1'b0;
      replay_active_q <= 1'b0;
      fault_q <= 1'b0;
      load_address_q <= '0;
      read_address_q <= '0;
      replay_beat_q <= '0;
      read_pending_q <= 1'b0;
      output_valid_q <= 1'b0;
      output_data_q <= '0;
      output_last_q <= 1'b0;
      load_done <= 1'b0;
      completed_loads <= '0;
      completed_replays <= '0;
    end else begin
      load_done <= 1'b0;

      if (load_start_valid && load_start_ready) begin
        loading_q <= 1'b1;
        cache_valid_q <= 1'b0;
        load_address_q <= '0;
      end

      if (load_fire) begin
        cache_memory[load_address_q] <= s_axis_tdata;
        if (s_axis_tkeep != 16'hffff ||
            s_axis_tlast != expected_load_last) begin
          fault_q <= 1'b1;
          cache_valid_q <= 1'b0;
        end

        if (s_axis_tlast || expected_load_last) begin
          loading_q <= 1'b0;
          if (s_axis_tkeep == 16'hffff &&
              s_axis_tlast == expected_load_last) begin
            cache_valid_q <= 1'b1;
            load_done <= 1'b1;
            completed_loads <= completed_loads + 1'b1;
          end
        end else begin
          load_address_q <= load_address_q + 1'b1;
        end
      end

      if (request_fire) begin
        if (request_record_index < RECORD_COUNT) begin
          replay_active_q <= 1'b1;
          replay_beat_q <= '0;
          read_address_q <= request_record_index * RECORD_BEATS;
          read_pending_q <= 1'b1;
        end else begin
          fault_q <= 1'b1;
        end
      end

      // One registered read stage keeps the inferred URAM path synchronous.
      if (read_pending_q) begin
        output_data_q <= cache_memory[read_address_q];
        output_last_q <= replay_beat_q == RECORD_BEATS-1;
        output_valid_q <= 1'b1;
        read_pending_q <= 1'b0;
      end

      if (output_fire) begin
        output_valid_q <= 1'b0;
        if (output_last_q) begin
          replay_active_q <= 1'b0;
          completed_replays <= completed_replays + 1'b1;
        end else begin
          replay_beat_q <= replay_beat_q + 1'b1;
          read_address_q <= read_address_q + 1'b1;
          read_pending_q <= 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (TOTAL_BYTES % BEAT_BYTES != 0 ||
        TOTAL_BEATS != RECORD_COUNT * RECORD_BEATS)
      $fatal(1, "parameter cache geometry is inconsistent");
  end

  always_ff @(posedge clk) begin
    if (!rst) begin
      if (load_fire && load_address_q >= TOTAL_BEATS)
        $fatal(1, "parameter cache load overflow");
      if (request_fire && request_record_index >= RECORD_COUNT)
        $error("parameter cache request index is out of range");
      if (m_axis_tvalid && !m_axis_tready)
        assert ($stable({m_axis_tdata, m_axis_tkeep, m_axis_tlast}));
    end
  end
`endif

endmodule
