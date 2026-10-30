`timescale 1ns/1ps

// KV260 shell adapter for the pure Eyeriss-RS batch-eight graph.  The stable
// software register ABI, AXI DMA control masters, stream byte counters, and
// external IP interfaces are reused.  All graph payload work is delegated to
// alexnet_eyeriss_rs_batch8_board_store_top.
module alexnet_eyeriss_rs_graph_accelerator_top #(
  parameter int CTRL_ADDR_W = 8,
  // Kept in the packaged-IP ABI used by the common KV260 block design.
  // This graph is intrinsically batch-eight, so the parameter is metadata
  // rather than a mode switch.
  parameter bit NATIVE_BATCH8 = 1'b1,
  parameter logic [15:0] BUILD_CLOCK_MHZ = 16'd185
) (
  input  logic                       aclk,
  input  logic                       aresetn,

  input  logic [CTRL_ADDR_W-1:0]     s_axi_ctrl_awaddr,
  input  logic [2:0]                 s_axi_ctrl_awprot,
  input  logic                       s_axi_ctrl_awvalid,
  output logic                       s_axi_ctrl_awready,
  input  logic [31:0]                s_axi_ctrl_wdata,
  input  logic [3:0]                 s_axi_ctrl_wstrb,
  input  logic                       s_axi_ctrl_wvalid,
  output logic                       s_axi_ctrl_wready,
  output logic [1:0]                 s_axi_ctrl_bresp,
  output logic                       s_axi_ctrl_bvalid,
  input  logic                       s_axi_ctrl_bready,
  input  logic [CTRL_ADDR_W-1:0]     s_axi_ctrl_araddr,
  input  logic [2:0]                 s_axi_ctrl_arprot,
  input  logic                       s_axi_ctrl_arvalid,
  output logic                       s_axi_ctrl_arready,
  output logic [31:0]                s_axi_ctrl_rdata,
  output logic [1:0]                 s_axi_ctrl_rresp,
  output logic                       s_axi_ctrl_rvalid,
  input  logic                       s_axi_ctrl_rready,

  input  logic [63:0]                s_axis_camera_tdata,
  input  logic [7:0]                 s_axis_camera_tkeep,
  input  logic                       s_axis_camera_tvalid,
  output logic                       s_axis_camera_tready,
  input  logic                       s_axis_camera_tlast,

  input  logic [127:0]               s_axis_mm2s_tdata,
  input  logic [15:0]                s_axis_mm2s_tkeep,
  input  logic                       s_axis_mm2s_tvalid,
  output logic                       s_axis_mm2s_tready,
  input  logic                       s_axis_mm2s_tlast,

  input  logic [127:0]               s_axis_weight_tdata,
  input  logic [15:0]                s_axis_weight_tkeep,
  input  logic                       s_axis_weight_tvalid,
  output logic                       s_axis_weight_tready,
  input  logic                       s_axis_weight_tlast,

  output logic [127:0]               m_axis_s2mm_tdata,
  output logic [15:0]                m_axis_s2mm_tkeep,
  output logic                       m_axis_s2mm_tvalid,
  input  logic                       m_axis_s2mm_tready,
  output logic                       m_axis_s2mm_tlast,

  output logic [31:0]                m_axi_dma_awaddr,
  output logic [2:0]                 m_axi_dma_awprot,
  output logic                       m_axi_dma_awvalid,
  input  logic                       m_axi_dma_awready,
  output logic [31:0]                m_axi_dma_wdata,
  output logic [3:0]                 m_axi_dma_wstrb,
  output logic                       m_axi_dma_wvalid,
  input  logic                       m_axi_dma_wready,
  input  logic [1:0]                 m_axi_dma_bresp,
  input  logic                       m_axi_dma_bvalid,
  output logic                       m_axi_dma_bready,
  output logic [31:0]                m_axi_dma_araddr,
  output logic [2:0]                 m_axi_dma_arprot,
  output logic                       m_axi_dma_arvalid,
  input  logic                       m_axi_dma_arready,
  input  logic [31:0]                m_axi_dma_rdata,
  input  logic [1:0]                 m_axi_dma_rresp,
  input  logic                       m_axi_dma_rvalid,
  output logic                       m_axi_dma_rready,

  output logic [31:0]                m_axi_weight_dma_awaddr,
  output logic [2:0]                 m_axi_weight_dma_awprot,
  output logic                       m_axi_weight_dma_awvalid,
  input  logic                       m_axi_weight_dma_awready,
  output logic [31:0]                m_axi_weight_dma_wdata,
  output logic [3:0]                 m_axi_weight_dma_wstrb,
  output logic                       m_axi_weight_dma_wvalid,
  input  logic                       m_axi_weight_dma_wready,
  input  logic [1:0]                 m_axi_weight_dma_bresp,
  input  logic                       m_axi_weight_dma_bvalid,
  output logic                       m_axi_weight_dma_bready,
  output logic [31:0]                m_axi_weight_dma_araddr,
  output logic [2:0]                 m_axi_weight_dma_arprot,
  output logic                       m_axi_weight_dma_arvalid,
  input  logic                       m_axi_weight_dma_arready,
  input  logic [31:0]                m_axi_weight_dma_rdata,
  input  logic [1:0]                 m_axi_weight_dma_rresp,
  input  logic                       m_axi_weight_dma_rvalid,
  output logic                       m_axi_weight_dma_rready,

  output logic                       irq,
  output logic                       accelerator_busy,
  output logic                       accelerator_fault
);
  logic rst;
  assign rst = !aresetn;

  logic core_start_valid, core_start_ready, board_start_ready;
  logic [15:0] core_start_tag;
  logic [63:0] active_input_base, active_activation_a_base;
  logic [63:0] active_activation_b_base, active_weights_base;
  logic [63:0] active_parameters_base, active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;

  logic weight_cmd_valid, weight_cmd_ready;
  logic [31:0] weight_cmd_address;
  logic [25:0] weight_cmd_length;
  logic weight_armed, weight_busy, weight_done, weight_error;
  logic [3:0] weight_error_code, weight_state;
  logic [31:0] unused_weight_status, unused_weight_cycles;

  logic main_mm2s_cmd_valid, main_mm2s_cmd_ready;
  logic [31:0] main_mm2s_cmd_address;
  logic [25:0] main_mm2s_cmd_length;
  logic main_mm2s_armed, main_mm2s_busy, main_mm2s_done;
  logic main_mm2s_error;
  logic [3:0] main_mm2s_error_code, main_mm2s_state;
  logic main_s2mm_cmd_valid, main_s2mm_cmd_ready;
  logic [31:0] main_s2mm_cmd_address;
  logic [25:0] main_s2mm_cmd_length;
  logic main_s2mm_armed, main_s2mm_busy, main_s2mm_done;
  logic main_s2mm_error;
  logic [3:0] main_s2mm_error_code, main_s2mm_state;

  logic layer_complete_valid;
  logic [3:0] layer_complete_id;
  logic board_inference_done, board_fault;
  logic [15:0] completed_passes;
  logic [63:0] total_mac_count;
  logic [31:0] total_local_psum_hops;
  logic [63:0] filter_byte_requests, filter_cache_hits;
  logic [63:0] filter_cache_misses, filter_dma_line_fetches;
  logic [63:0] ifmap_byte_requests, ifmap_cache_hits;
  logic [63:0] ifmap_cache_misses, ifmap_dma_line_fetches;
  logic [63:0] partial_result_inputs, accumulator_uram_reads;
  logic [63:0] accumulator_uram_writes, final_result_outputs;
  logic [63:0] weight_dma_line_commands, weight_dma_line_errors;
  logic [63:0] main_dma_line_commands, main_dma_line_errors;
  logic [31:0] parameter_blob_loads;
  logic [63:0] parameter_lookups, requantized_vectors;
  logic [63:0] stored_result_vectors, stored_image_tiles;
  logic [63:0] result_s2mm_commands, result_s2mm_bytes;
  logic [9:0] pool_completed_tiles;
  logic [31:0] pool_raw_words_read, pool_pooled_words_written;
  logic [31:0] pool_mm2s_commands, pool_s2mm_commands;
  logic pool_active;

  logic [63:0] ddr_read_bytes, ddr_write_bytes;
  logic [63:0] main_read_bytes, weight_read_bytes, camera_read_bytes;
  logic job_active_q, fault_reported_q, inference_failed_q;
  logic [15:0] active_inference_tag_q;
  logic [3:0] active_layer_id_q;
  logic [2:0] completed_conv_layers_q;
  logic [1:0] completed_fc_layers_q;
  logic pool5_done_q;
  logic [31:0] job_cycles_q, weight_cycles_q, main_cycles_q;
  logic [31:0] pool_cycles_q, result_cycles_q, overlap_cycles_q;
  logic [63:0] peak_mac_slot_count_q;
  logic [31:0] result_signature_q;
  logic core_start_fire, inference_done_event;
  logic main_dma_busy, main_dma_error;
  logic [3:0] main_dma_error_code;

  assign s_axis_camera_tready = 1'b1;
  assign core_start_ready = board_start_ready && !job_active_q &&
                            !accelerator_fault;
  assign core_start_fire = core_start_valid && core_start_ready;
  assign inference_done_event = board_inference_done && job_active_q;
  assign main_dma_busy = main_mm2s_busy || main_s2mm_busy;
  assign main_dma_error = main_mm2s_error || main_s2mm_error;
  assign main_dma_error_code = main_mm2s_error ? main_mm2s_error_code :
                               main_s2mm_error_code;
  assign accelerator_fault = board_fault || main_dma_error || weight_error;
  assign accelerator_busy = job_active_q || main_dma_busy || weight_busy;

  alexnet_eyeriss_rs_batch8_board_store_top #(.TAG_W(16)) u_pure_rs_graph (
    .clk(aclk), .rst, .start_valid(core_start_valid && !job_active_q),
    .start_ready(board_start_ready), .start_tag(core_start_tag),
    .input_base(active_input_base),
    .activation_a_base(active_activation_a_base),
    .activation_b_base(active_activation_b_base),
    .weights_base(active_weights_base),
    .parameters_base(active_parameters_base),
    .final_output_base(active_final_output_base),
    .weight_dma_command_valid(weight_cmd_valid),
    .weight_dma_command_ready(weight_cmd_ready),
    .weight_dma_command_address(weight_cmd_address),
    .weight_dma_command_length(weight_cmd_length),
    .weight_dma_armed(weight_armed), .weight_dma_done(weight_done),
    .weight_dma_error(weight_error),
    .weight_axis_tdata(s_axis_weight_tdata),
    .weight_axis_tkeep(s_axis_weight_tkeep),
    .weight_axis_tvalid(s_axis_weight_tvalid),
    .weight_axis_tready(s_axis_weight_tready),
    .weight_axis_tlast(s_axis_weight_tlast),
    .main_mm2s_command_valid(main_mm2s_cmd_valid),
    .main_mm2s_command_ready(main_mm2s_cmd_ready),
    .main_mm2s_command_address(main_mm2s_cmd_address),
    .main_mm2s_command_length(main_mm2s_cmd_length),
    .main_mm2s_armed, .main_mm2s_done, .main_mm2s_error,
    .main_mm2s_axis_tdata(s_axis_mm2s_tdata),
    .main_mm2s_axis_tkeep(s_axis_mm2s_tkeep),
    .main_mm2s_axis_tvalid(s_axis_mm2s_tvalid),
    .main_mm2s_axis_tready(s_axis_mm2s_tready),
    .main_mm2s_axis_tlast(s_axis_mm2s_tlast),
    .main_s2mm_command_valid(main_s2mm_cmd_valid),
    .main_s2mm_command_ready(main_s2mm_cmd_ready),
    .main_s2mm_command_address(main_s2mm_cmd_address),
    .main_s2mm_command_length(main_s2mm_cmd_length),
    .main_s2mm_armed, .main_s2mm_done, .main_s2mm_error,
    .main_s2mm_axis_tdata(m_axis_s2mm_tdata),
    .main_s2mm_axis_tkeep(m_axis_s2mm_tkeep),
    .main_s2mm_axis_tvalid(m_axis_s2mm_tvalid),
    .main_s2mm_axis_tready(m_axis_s2mm_tready),
    .main_s2mm_axis_tlast(m_axis_s2mm_tlast),
    .layer_complete_valid, .layer_complete_ready(1'b1),
    .layer_complete_id, .inference_done(board_inference_done),
    .inference_done_ready(1'b1), .fault(board_fault),
    .completed_passes, .total_mac_count, .total_local_psum_hops,
    .filter_byte_requests, .filter_cache_hits, .filter_cache_misses,
    .filter_dma_line_fetches, .ifmap_byte_requests, .ifmap_cache_hits,
    .ifmap_cache_misses, .ifmap_dma_line_fetches,
    .partial_result_inputs, .accumulator_uram_reads,
    .accumulator_uram_writes, .final_result_outputs,
    .weight_dma_line_commands, .weight_dma_line_errors,
    .main_dma_line_commands, .main_dma_line_errors,
    .parameter_blob_loads, .parameter_lookups, .requantized_vectors,
    .stored_result_vectors, .stored_image_tiles, .result_s2mm_commands,
    .result_s2mm_bytes, .pool_completed_tiles, .pool_raw_words_read,
    .pool_pooled_words_written, .pool_mm2s_commands,
    .pool_s2mm_commands, .pool_active
  );

  alexnet_axi_dma_dual_channel_master #(
    .DMA_BASE_ADDR(32'ha001_0000),
    .MM2S_ALIGNMENT_BYTES(8), .S2MM_ALIGNMENT_BYTES(8)
  ) u_main_dma_control (
    .clk(aclk), .rst_n(aresetn),
    .mm2s_cmd_valid(main_mm2s_cmd_valid),
    .mm2s_cmd_ready(main_mm2s_cmd_ready),
    .mm2s_cmd_address(main_mm2s_cmd_address),
    .mm2s_cmd_length(main_mm2s_cmd_length),
    .mm2s_timeout_cycles(active_dma_timeout_cycles),
    .mm2s_armed(main_mm2s_armed), .mm2s_busy(main_mm2s_busy),
    .mm2s_done(main_mm2s_done), .mm2s_error(main_mm2s_error),
    .mm2s_error_code(main_mm2s_error_code),
    .mm2s_state(main_mm2s_state),
    .s2mm_cmd_valid(main_s2mm_cmd_valid),
    .s2mm_cmd_ready(main_s2mm_cmd_ready),
    .s2mm_cmd_address(main_s2mm_cmd_address),
    .s2mm_cmd_length(main_s2mm_cmd_length),
    .s2mm_timeout_cycles(active_dma_timeout_cycles),
    .s2mm_armed(main_s2mm_armed), .s2mm_busy(main_s2mm_busy),
    .s2mm_done(main_s2mm_done), .s2mm_error(main_s2mm_error),
    .s2mm_error_code(main_s2mm_error_code),
    .s2mm_state(main_s2mm_state),
    .m_axi_awaddr(m_axi_dma_awaddr), .m_axi_awprot(m_axi_dma_awprot),
    .m_axi_awvalid(m_axi_dma_awvalid), .m_axi_awready(m_axi_dma_awready),
    .m_axi_wdata(m_axi_dma_wdata), .m_axi_wstrb(m_axi_dma_wstrb),
    .m_axi_wvalid(m_axi_dma_wvalid), .m_axi_wready(m_axi_dma_wready),
    .m_axi_bresp(m_axi_dma_bresp), .m_axi_bvalid(m_axi_dma_bvalid),
    .m_axi_bready(m_axi_dma_bready), .m_axi_araddr(m_axi_dma_araddr),
    .m_axi_arprot(m_axi_dma_arprot), .m_axi_arvalid(m_axi_dma_arvalid),
    .m_axi_arready(m_axi_dma_arready), .m_axi_rdata(m_axi_dma_rdata),
    .m_axi_rresp(m_axi_dma_rresp), .m_axi_rvalid(m_axi_dma_rvalid),
    .m_axi_rready(m_axi_dma_rready)
  );

  axi_dma_simple_master #(
    .DMA_BASE_ADDR(32'ha003_0000), .DMA_ALIGNMENT_BYTES(16)
  ) u_weight_dma_control (
    .clk(aclk), .rst_n(aresetn), .clear_error(1'b0),
    .cmd_valid(weight_cmd_valid), .cmd_ready(weight_cmd_ready),
    .cmd_s2mm(1'b0), .cmd_buffer_addr(weight_cmd_address),
    .cmd_length_bytes(weight_cmd_length),
    .cmd_timeout_cycles(active_dma_timeout_cycles),
    .armed(weight_armed), .busy(weight_busy), .done(weight_done),
    .error(weight_error), .error_code(weight_error_code),
    .last_status(unused_weight_status),
    .active_cycles(unused_weight_cycles), .state_debug(weight_state),
    .m_axi_awaddr(m_axi_weight_dma_awaddr),
    .m_axi_awprot(m_axi_weight_dma_awprot),
    .m_axi_awvalid(m_axi_weight_dma_awvalid),
    .m_axi_awready(m_axi_weight_dma_awready),
    .m_axi_wdata(m_axi_weight_dma_wdata),
    .m_axi_wstrb(m_axi_weight_dma_wstrb),
    .m_axi_wvalid(m_axi_weight_dma_wvalid),
    .m_axi_wready(m_axi_weight_dma_wready),
    .m_axi_bresp(m_axi_weight_dma_bresp),
    .m_axi_bvalid(m_axi_weight_dma_bvalid),
    .m_axi_bready(m_axi_weight_dma_bready),
    .m_axi_araddr(m_axi_weight_dma_araddr),
    .m_axi_arprot(m_axi_weight_dma_arprot),
    .m_axi_arvalid(m_axi_weight_dma_arvalid),
    .m_axi_arready(m_axi_weight_dma_arready),
    .m_axi_rdata(m_axi_weight_dma_rdata),
    .m_axi_rresp(m_axi_weight_dma_rresp),
    .m_axi_rvalid(m_axi_weight_dma_rvalid),
    .m_axi_rready(m_axi_weight_dma_rready)
  );

  alexnet_axis_byte_counters u_axis_byte_counters (
    .clk(aclk), .rst,
    .main_read_tkeep(s_axis_mm2s_tkeep),
    .main_read_tvalid(s_axis_mm2s_tvalid),
    .main_read_tready(s_axis_mm2s_tready),
    .weight_read_tkeep(s_axis_weight_tkeep),
    .weight_read_tvalid(s_axis_weight_tvalid),
    .weight_read_tready(s_axis_weight_tready),
    .camera_read_tkeep(s_axis_camera_tkeep),
    .camera_read_tvalid(s_axis_camera_tvalid),
    .camera_read_tready(s_axis_camera_tready),
    .ddr_write_tkeep(m_axis_s2mm_tkeep),
    .ddr_write_tvalid(m_axis_s2mm_tvalid),
    .ddr_write_tready(m_axis_s2mm_tready),
    .ddr_read_bytes, .ddr_write_bytes, .main_read_bytes,
    .weight_read_bytes, .camera_read_bytes
  );

  alexnet_axi_lite_regs #(
    .ADDR_W(CTRL_ADDR_W), .MODULE_ID(16'h4552), .VERSION(8'h88),
    .BUILD_M(8'd12), .BUILD_N(8'd14),
    .BUILD_CLOCK_MHZ(BUILD_CLOCK_MHZ)
  ) u_control_regs (
    .clk(aclk), .rst,
    .s_axi_awaddr(s_axi_ctrl_awaddr),
    .s_axi_awvalid(s_axi_ctrl_awvalid),
    .s_axi_awready(s_axi_ctrl_awready),
    .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
    .s_axi_wvalid(s_axi_ctrl_wvalid),
    .s_axi_wready(s_axi_ctrl_wready), .s_axi_bresp(s_axi_ctrl_bresp),
    .s_axi_bvalid(s_axi_ctrl_bvalid), .s_axi_bready(s_axi_ctrl_bready),
    .s_axi_araddr(s_axi_ctrl_araddr),
    .s_axi_arvalid(s_axi_ctrl_arvalid),
    .s_axi_arready(s_axi_ctrl_arready),
    .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp),
    .s_axi_rvalid(s_axi_ctrl_rvalid), .s_axi_rready(s_axi_ctrl_rready),
    .core_start_valid, .core_start_ready, .core_start_tag,
    .active_input_base, .active_activation_a_base,
    .active_activation_b_base, .active_weights_base,
    .active_parameters_base, .active_final_output_base,
    .active_dma_timeout_cycles,
    .core_busy(accelerator_busy), .inference_done(inference_done_event),
    .inference_failed(inference_failed_q), .core_fault(accelerator_fault),
    .fault_code(accelerator_fault ? 4'h8 : 4'h0),
    .fault_detail({main_dma_error_code, weight_error_code}),
    .graph_phase({job_active_q, active_layer_id_q}),
    .active_layer_id(active_layer_id_q),
    .active_inference_tag(active_inference_tag_q),
    .completed_conv_layers(completed_conv_layers_q),
    .completed_fc_layers(completed_fc_layers_q),
    .pool5_cache_valid(pool5_done_q),
    .dma_busy(main_dma_busy || weight_busy),
    .dma_error(main_dma_error || weight_error),
    .dma_error_code(main_dma_error ? main_dma_error_code :
                    weight_error_code),
    .dma_active_source(weight_busy ? 3'd1 :
                       main_mm2s_busy ? 3'd2 :
                       main_s2mm_busy ? 3'd4 : 3'd0),
    .dma_accepted_requests(main_dma_line_commands[31:0] +
                           weight_dma_line_commands[31:0]),
    .dma_issued_commands(result_s2mm_commands[31:0] +
                         pool_mm2s_commands + pool_s2mm_commands),
    .dma_completed_transfers(stored_image_tiles[31:0] +
                             pool_completed_tiles),
    .conv_storage_completed_tiles(stored_image_tiles[31:0]),
    .perf_active_cycles(job_cycles_q),
    .perf_issue_cycles({16'd0, completed_passes}),
    .perf_weight_stall_cycles(32'd0),
    .perf_activation_stall_cycles(32'd0),
    .perf_result_stall_cycles(32'd0),
    .perf_useful_mac_count(total_mac_count),
    .perf_peak_mac_slot_count(peak_mac_slot_count_q),
    .perf_result_signature(result_signature_q),
    .perf_completed_tiles(stored_image_tiles[15:0]),
    .perf_ddr_read_bytes(ddr_read_bytes),
    .perf_ddr_write_bytes(ddr_write_bytes),
    .perf_main_read_bytes(main_read_bytes),
    .perf_weight_read_bytes(weight_read_bytes),
    .perf_camera_read_bytes(camera_read_bytes),
    .perf_pipeline_total_cycles(job_cycles_q),
    .perf_engine_cycles(job_cycles_q),
    .perf_weight_service_cycles(weight_cycles_q),
    .perf_patch_service_cycles(main_cycles_q),
    .perf_pool_cycles(pool_cycles_q),
    .perf_result_service_cycles(result_cycles_q),
    .perf_raster_cycles(32'd0),
    .perf_dma_cycles(main_cycles_q + weight_cycles_q),
    .perf_overlap_cycles(overlap_cycles_q),
    .perf_pipeline_idle_cycles(32'd0),
    .irq, .start_pending(), .done_sticky(), .failed_sticky(),
    .fault_sticky(), .start_rejected_sticky()
  );

  always_ff @(posedge aclk) begin
    if (rst) begin
      job_active_q <= 1'b0;
      fault_reported_q <= 1'b0;
      inference_failed_q <= 1'b0;
      active_inference_tag_q <= 0;
      active_layer_id_q <= 0;
      completed_conv_layers_q <= 0;
      completed_fc_layers_q <= 0;
      pool5_done_q <= 1'b0;
      job_cycles_q <= 0;
      weight_cycles_q <= 0;
      main_cycles_q <= 0;
      pool_cycles_q <= 0;
      result_cycles_q <= 0;
      overlap_cycles_q <= 0;
      peak_mac_slot_count_q <= 0;
      result_signature_q <= 0;
    end else begin
      inference_failed_q <= 1'b0;

      if (core_start_fire) begin
        job_active_q <= 1'b1;
        fault_reported_q <= 1'b0;
        active_inference_tag_q <= core_start_tag;
        active_layer_id_q <= 1;
        completed_conv_layers_q <= 0;
        completed_fc_layers_q <= 0;
        pool5_done_q <= 1'b0;
        job_cycles_q <= 0;
        weight_cycles_q <= 0;
        main_cycles_q <= 0;
        pool_cycles_q <= 0;
        result_cycles_q <= 0;
        overlap_cycles_q <= 0;
        peak_mac_slot_count_q <= 0;
        result_signature_q <= 0;
      end else if (job_active_q) begin
        job_cycles_q <= job_cycles_q + 1'b1;
        peak_mac_slot_count_q <= peak_mac_slot_count_q + 10'd504;
        if (weight_busy)
          weight_cycles_q <= weight_cycles_q + 1'b1;
        if (main_dma_busy)
          main_cycles_q <= main_cycles_q + 1'b1;
        if (pool_active)
          pool_cycles_q <= pool_cycles_q + 1'b1;
        if (main_s2mm_busy && !pool_active)
          result_cycles_q <= result_cycles_q + 1'b1;
        if (main_dma_busy && weight_busy)
          overlap_cycles_q <= overlap_cycles_q + 1'b1;
      end

      if (layer_complete_valid) begin
        if (layer_complete_id <= 5) begin
          completed_conv_layers_q <= layer_complete_id[2:0];
          if (layer_complete_id == 5)
            pool5_done_q <= 1'b1;
        end else begin
          completed_fc_layers_q <= layer_complete_id - 5;
        end
        if (layer_complete_id < 8)
          active_layer_id_q <= layer_complete_id + 1'b1;
      end

      if (m_axis_s2mm_tvalid && m_axis_s2mm_tready)
        result_signature_q <= result_signature_q ^
            m_axis_s2mm_tdata[31:0] ^ m_axis_s2mm_tdata[63:32] ^
            m_axis_s2mm_tdata[95:64] ^ m_axis_s2mm_tdata[127:96];

      if (inference_done_event) begin
        job_active_q <= 1'b0;
        active_layer_id_q <= 8;
      end

      if (job_active_q && accelerator_fault && !fault_reported_q) begin
        inference_failed_q <= 1'b1;
        fault_reported_q <= 1'b1;
        job_active_q <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (!rst) begin
      if (core_start_fire && job_active_q)
        $fatal(1, "pure-RS board shell accepted overlapping jobs");
      if (main_mm2s_cmd_valid && main_mm2s_cmd_address[2:0] != 0)
        $fatal(1, "pure-RS main MM2S command is not 8-byte aligned");
      if (main_s2mm_cmd_valid && main_s2mm_cmd_address[2:0] != 0)
        $fatal(1, "pure-RS main S2MM command is not 8-byte aligned");
    end
  end
`endif
endmodule
