`timescale 1ns/1ps

// One physical UltraRAM slice.  Two 64-bit banks form one 128-bit parameter
// record and three depth segments hold all 10,344 AlexNet output channels.
module alexnet_eyeriss_rs_parameter_uram64_slice (
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

// Cache the complete frozen AlexNet quantization blob once per DDR base.
// The software format is one 16-byte little-endian record per output channel:
//   [31:0]   signed INT32 bias
//   [63:32]  signed INT32 multiplier (the implemented value fits INT18)
//   [69:64]  right shift
//   [79:72]  ReLU byte
//   all remaining bits are zero
// Loading and lookup are mutually exclusive, permitting six URAM288s.
module alexnet_eyeriss_rs_parameter_cache #(
  parameter int RECORD_COUNT = 10344,
  parameter int RECORD_W = 128
) (
  input  logic                         clk,
  input  logic                         rst,

  input  logic                         load_start_valid,
  output logic                         load_start_ready,
  input  logic [127:0]                 load_axis_tdata,
  input  logic [15:0]                  load_axis_tkeep,
  input  logic                         load_axis_tvalid,
  output logic                         load_axis_tready,
  input  logic                         load_axis_tlast,
  output logic                         load_active,
  output logic                         load_done,
  output logic                         cache_valid,

  input  logic                         request_valid,
  output logic                         request_ready,
  input  logic [$clog2(RECORD_COUNT)-1:0] request_index,
  output logic                         response_valid,
  input  logic                         response_ready,
  output logic [127:0]                 response_data,

  output logic                         fault,
  output logic [31:0]                  completed_loads,
  output logic [63:0]                  completed_lookups
);
  localparam int ADDR_W = $clog2(RECORD_COUNT);
  localparam int SEGMENTS = (RECORD_COUNT + 4095) / 4096;
  localparam int SEG_W = ($clog2(SEGMENTS) < 1) ? 1 : $clog2(SEGMENTS);

  logic [63:0] slice_read_data [0:1][0:SEGMENTS-1];
  logic loading_q, cache_valid_q, fault_q;
  logic [ADDR_W-1:0] load_address_q;
  logic read_pending_q, response_valid_q;
  logic [SEG_W-1:0] read_segment_q;
  logic [11:0] load_local_address, request_local_address;
  logic [127:0] response_data_q;
  logic load_fire, request_fire, response_fire;
  logic expected_last;

  assign load_start_ready = !loading_q && !read_pending_q &&
                            !response_valid_q && !fault_q;
  assign load_axis_tready = loading_q && !fault_q;
  assign load_fire = load_axis_tvalid && load_axis_tready;
  assign expected_last = load_address_q == ADDR_W'(RECORD_COUNT-1);
  assign load_local_address = 12'(load_address_q);
  assign request_local_address = 12'(request_index);
  assign load_active = loading_q;
  assign cache_valid = cache_valid_q;

  assign request_ready = cache_valid_q && !loading_q && !read_pending_q &&
                         !response_valid_q && !fault_q;
  assign request_fire = request_valid && request_ready;
  assign response_valid = response_valid_q;
  assign response_data = response_data_q;
  assign response_fire = response_valid && response_ready;
  assign fault = fault_q;

  generate
    for (genvar bank = 0; bank < 2; bank = bank + 1) begin : g_bank
      for (genvar segment = 0; segment < SEGMENTS;
           segment = segment + 1) begin : g_segment
        alexnet_eyeriss_rs_parameter_uram64_slice u_slice (
          .clk,
          .read_enable(request_fire &&
              ((request_index >> 12) == segment)),
          .write_enable(load_fire &&
              ((load_address_q >> 12) == segment)),
          .address(load_fire ? load_local_address : request_local_address),
          .write_data(load_axis_tdata[bank*64 +: 64]),
          .read_data(slice_read_data[bank][segment])
        );
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      loading_q <= 1'b0;
      cache_valid_q <= 1'b0;
      fault_q <= 1'b0;
      load_address_q <= '0;
      read_pending_q <= 1'b0;
      read_segment_q <= '0;
      response_valid_q <= 1'b0;
      response_data_q <= '0;
      load_done <= 1'b0;
      completed_loads <= '0;
      completed_lookups <= '0;
    end else begin
      load_done <= 1'b0;

      if (response_fire)
        response_valid_q <= 1'b0;

      if (load_start_valid && load_start_ready) begin
        loading_q <= 1'b1;
        cache_valid_q <= 1'b0;
        load_address_q <= '0;
      end

      if (load_fire) begin
        if (load_axis_tkeep != 16'hffff ||
            load_axis_tlast != expected_last) begin
          fault_q <= 1'b1;
          cache_valid_q <= 1'b0;
          loading_q <= 1'b0;
        end else if (expected_last) begin
          loading_q <= 1'b0;
          cache_valid_q <= 1'b1;
          load_done <= 1'b1;
          completed_loads <= completed_loads + 1'b1;
        end else begin
          load_address_q <= load_address_q + 1'b1;
        end
      end

      if (request_fire) begin
        read_segment_q <= SEG_W'(request_index >> 12);
        read_pending_q <= 1'b1;
      end

      // The URAM read ports update on the same edge.  Capture their registered
      // outputs one cycle later, then hold the response under backpressure.
      if (read_pending_q) begin
        response_data_q[63:0] <= slice_read_data[0][read_segment_q];
        response_data_q[127:64] <= slice_read_data[1][read_segment_q];
        response_valid_q <= 1'b1;
        read_pending_q <= 1'b0;
        completed_lookups <= completed_lookups + 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  logic response_stalled_q;

  initial begin
    if (RECORD_W != 128 || RECORD_COUNT < 1 || SEGMENTS > 3)
      $fatal(1, "parameter-cache geometry is unsupported");
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      response_stalled_q <= 1'b0;
    end else begin
      if (response_stalled_q)
        assert ($stable(response_data));
      response_stalled_q <= response_valid && !response_ready;
    end
  end
`endif

endmodule
