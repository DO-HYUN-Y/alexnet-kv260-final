`timescale 1ns/1ps

// One physical-width/depth UltraRAM slice.  Keeping each declaration at
// 64x4096 avoids Vivado's one-million-bit RTL variable limit and maps directly
// to one 72-bit-wide URAM288 primitive.
module alexnet_eyeriss_rs_uram64_slice (
  input  logic        clk,
  input  logic        read_enable,
  input  logic        write_enable,
  input  logic [11:0] address,
  input  logic [63:0] write_data,
  output logic [63:0] read_data
);
  (* ram_style = "ultra" *) logic [63:0] memory [0:4095];

  always_ff @(posedge clk) begin
    if (write_enable)
      memory[address] <= write_data;
    else if (read_enable)
      read_data <= memory[address];
  end
endmodule

// On-chip channel-pass accumulator for the pure-RS result stream.  The pass
// scheduler keeps one filter tile fixed while channel_base advances, so every
// channel pass emits the same ordered sequence of result vectors.  The first
// pass initializes URAM, middle passes read/add/write it, and the final pass
// emits completed INT32 results without another write.
module alexnet_eyeriss_rs_channel_accumulator #(
  parameter int TAG_W = 16,
  parameter int MAX_SLOTS = 28672
) (
  input  logic                       clk,
  input  logic                       rst,

  input  logic                       input_valid,
  output logic                       input_ready,
  input  logic [13:0]                input_col_valid,
  input  logic signed [31:0]         input_psum [0:13],
  input  logic [TAG_W-1:0]           input_tag,
  input  logic [3:0]                 input_layer,
  input  logic                       input_psum_first,
  input  logic                       input_psum_final,
  input  logic [13:0]                input_channel_base,
  input  logic [12:0]                input_filter,
  input  logic [2:0]                 input_image,
  input  logic [5:0]                 input_x,
  input  logic [5:0]                 input_y_base,

  output logic                       output_valid,
  input  logic                       output_ready,
  output logic [13:0]                output_col_valid,
  output logic signed [31:0]         output_psum [0:13],
  output logic [TAG_W-1:0]           output_tag,
  output logic [3:0]                 output_layer,
  output logic [12:0]                output_filter,
  output logic [2:0]                 output_image,
  output logic [5:0]                 output_x,
  output logic [5:0]                 output_y_base,

  output logic                       idle,
  output logic                       fault,
  output logic [63:0]                partial_inputs,
  output logic [63:0]                uram_reads,
  output logic [63:0]                uram_writes,
  output logic [63:0]                final_outputs
);

  localparam int LANES = 14;
  localparam int PACK_W = LANES * 32;
  localparam int ADDR_W = ($clog2(MAX_SLOTS) < 12) ? 12 :
                          $clog2(MAX_SLOTS);
  localparam int URAM_DEPTH = 4096;
  localparam int SEGMENTS = (MAX_SLOTS + URAM_DEPTH - 1) / URAM_DEPTH;

  typedef enum logic [1:0] {ST_IDLE, ST_ACCUMULATE, ST_OUTPUT} state_t;
  state_t state_q;

  localparam int BANKS = 7;
  logic [63:0] slice_read_data [0:BANKS-1][0:SEGMENTS-1];
  logic [2:0] memory_read_segment_q;
  logic [PACK_W-1:0] memory_read_packed;
  logic memory_read_enable, memory_write_enable;
  logic [ADDR_W-1:0] memory_read_address, memory_write_address;
  logic [PACK_W-1:0] memory_write_data;
  logic [PACK_W-1:0] input_packed, accumulated_packed;
  logic [PACK_W-1:0] pending_psum_q, output_packed_q;
  logic [ADDR_W-1:0] pending_address_q;
  logic pending_final_q;

  logic channel_seen_q;
  logic [13:0] active_channel_base_q;
  logic active_pass_first_q, active_pass_final_q;
  logic [ADDR_W:0] slot_count_q;
  logic expected_slots_valid_q;
  logic [ADDR_W:0] expected_slots_q;
  logic channel_change, slot_overflow, protocol_error;
  logic [ADDR_W-1:0] selected_address;

  logic [13:0] pending_col_valid_q;
  logic [TAG_W-1:0] pending_tag_q;
  logic [3:0] pending_layer_q;
  logic [12:0] pending_filter_q;
  logic [2:0] pending_image_q;
  logic [5:0] pending_x_q, pending_y_base_q;

  logic [13:0] output_col_valid_q;
  logic [TAG_W-1:0] output_tag_q;
  logic [3:0] output_layer_q;
  logic [12:0] output_filter_q;
  logic [2:0] output_image_q;
  logic [5:0] output_x_q, output_y_base_q;

  always_comb begin
    input_packed = '0;
    accumulated_packed = '0;
    for (integer lane = 0; lane < LANES; lane = lane + 1) begin
      input_packed[lane*32 +: 32] = input_psum[lane];
      accumulated_packed[lane*32 +: 32] =
          $signed(memory_read_packed[lane*32 +: 32]) +
          $signed(pending_psum_q[lane*32 +: 32]);
      output_psum[lane] = $signed(output_packed_q[lane*32 +: 32]);
    end
  end

  always_comb begin
    memory_read_packed = '0;
    for (integer bank = 0; bank < BANKS; bank = bank + 1)
      memory_read_packed[bank*64 +: 64] =
          slice_read_data[bank][memory_read_segment_q];

    memory_read_enable = 1'b0;
    memory_write_enable = 1'b0;
    memory_read_address = selected_address;
    memory_write_address = selected_address;
    memory_write_data = input_packed;
    if ((state_q == ST_IDLE) && input_valid && input_ready &&
        !protocol_error) begin
      if (input_psum_first && !input_psum_final) begin
        memory_write_enable = 1'b1;
      end else if (!input_psum_first) begin
        memory_read_enable = 1'b1;
      end
    end else if ((state_q == ST_ACCUMULATE) && !pending_final_q) begin
      memory_write_enable = 1'b1;
      memory_write_address = pending_address_q;
      memory_write_data = accumulated_packed;
    end
  end

  generate
    for (genvar bank = 0; bank < BANKS; bank = bank + 1) begin : g_uram
      for (genvar segment = 0; segment < SEGMENTS;
           segment = segment + 1) begin : g_segment
        alexnet_eyeriss_rs_uram64_slice u_slice (
          .clk,
          .read_enable(memory_read_enable &&
              ((memory_read_address >> 12) == segment)),
          .write_enable(memory_write_enable &&
              ((memory_write_address >> 12) == segment)),
          .address(memory_write_enable ? memory_write_address[11:0] :
                   memory_read_address[11:0]),
          .write_data(memory_write_data[bank*64 +: 64]),
          .read_data(slice_read_data[bank][segment])
        );
      end
    end
  endgenerate

  assign channel_change = !channel_seen_q ||
                          (input_channel_base != active_channel_base_q);
  assign selected_address = channel_change ? '0 :
                            slot_count_q[ADDR_W-1:0];
  assign slot_overflow = !channel_change && (slot_count_q >= MAX_SLOTS);
  assign protocol_error = slot_overflow ||
      (!channel_seen_q && !input_psum_first) ||
      (input_psum_first && (input_channel_base != 0)) ||
      (!channel_change &&
       ((input_psum_first != active_pass_first_q) ||
        (input_psum_final != active_pass_final_q))) ||
      (channel_seen_q && channel_change && expected_slots_valid_q &&
       (slot_count_q != expected_slots_q));

  assign input_ready = (state_q == ST_IDLE) && !fault;
  assign idle = state_q == ST_IDLE;
  assign output_valid = state_q == ST_OUTPUT;
  assign output_col_valid = output_col_valid_q;
  assign output_tag = output_tag_q;
  assign output_layer = output_layer_q;
  assign output_filter = output_filter_q;
  assign output_image = output_image_q;
  assign output_x = output_x_q;
  assign output_y_base = output_y_base_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      memory_read_segment_q <= '0;
      pending_psum_q <= '0;
      pending_address_q <= '0;
      pending_final_q <= 1'b0;
      channel_seen_q <= 1'b0;
      active_channel_base_q <= '0;
      active_pass_first_q <= 1'b0;
      active_pass_final_q <= 1'b0;
      slot_count_q <= '0;
      expected_slots_valid_q <= 1'b0;
      expected_slots_q <= '0;
      pending_col_valid_q <= '0;
      pending_tag_q <= '0;
      pending_layer_q <= '0;
      pending_filter_q <= '0;
      pending_image_q <= '0;
      pending_x_q <= '0;
      pending_y_base_q <= '0;
      output_packed_q <= '0;
      output_col_valid_q <= '0;
      output_tag_q <= '0;
      output_layer_q <= '0;
      output_filter_q <= '0;
      output_image_q <= '0;
      output_x_q <= '0;
      output_y_base_q <= '0;
      fault <= 1'b0;
      partial_inputs <= '0;
      uram_reads <= '0;
      uram_writes <= '0;
      final_outputs <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (input_valid && input_ready) begin
            if (protocol_error) begin
              fault <= 1'b1;
            end else begin
              partial_inputs <= partial_inputs + 1'b1;

              if (channel_change) begin
                if (channel_seen_q && active_pass_first_q &&
                    !active_pass_final_q) begin
                  expected_slots_q <= slot_count_q;
                  expected_slots_valid_q <= 1'b1;
                end else if (input_psum_first) begin
                  expected_slots_valid_q <= 1'b0;
                end
                channel_seen_q <= 1'b1;
                active_channel_base_q <= input_channel_base;
                active_pass_first_q <= input_psum_first;
                active_pass_final_q <= input_psum_final;
                slot_count_q <= 1;
              end else begin
                slot_count_q <= slot_count_q + 1'b1;
              end

              if (input_psum_first && input_psum_final) begin
                output_packed_q <= input_packed;
                output_col_valid_q <= input_col_valid;
                output_tag_q <= input_tag;
                output_layer_q <= input_layer;
                output_filter_q <= input_filter;
                output_image_q <= input_image;
                output_x_q <= input_x;
                output_y_base_q <= input_y_base;
                state_q <= ST_OUTPUT;
              end else if (input_psum_first) begin
                uram_writes <= uram_writes + 1'b1;
              end else begin
                pending_psum_q <= input_packed;
                pending_address_q <= selected_address;
                pending_final_q <= input_psum_final;
                pending_col_valid_q <= input_col_valid;
                pending_tag_q <= input_tag;
                pending_layer_q <= input_layer;
                pending_filter_q <= input_filter;
                pending_image_q <= input_image;
                pending_x_q <= input_x;
                pending_y_base_q <= input_y_base;
                uram_reads <= uram_reads + 1'b1;
                state_q <= ST_ACCUMULATE;
              end
            end
          end
        end

        ST_ACCUMULATE: begin
          if (pending_final_q) begin
            output_packed_q <= accumulated_packed;
            output_col_valid_q <= pending_col_valid_q;
            output_tag_q <= pending_tag_q;
            output_layer_q <= pending_layer_q;
            output_filter_q <= pending_filter_q;
            output_image_q <= pending_image_q;
            output_x_q <= pending_x_q;
            output_y_base_q <= pending_y_base_q;
            state_q <= ST_OUTPUT;
          end else begin
            uram_writes <= uram_writes + 1'b1;
            state_q <= ST_IDLE;
          end
        end

        ST_OUTPUT: begin
          if (output_valid && output_ready) begin
            final_outputs <= final_outputs + 1'b1;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          fault <= 1'b1;
          state_q <= ST_IDLE;
        end
      endcase
      if (memory_read_enable)
        memory_read_segment_q <= memory_read_address >> 12;
    end
  end

endmodule
