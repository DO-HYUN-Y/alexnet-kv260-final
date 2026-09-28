`timescale 1ns/1ps

// PS-facing batch-one M8xN126 graph-payload accelerator.
//
// HP0 first supplies the normal 224x224xN8 input raster.  An x-mod-4 feeder
// assembles Conv1 M16 patches locally. Conv2-FC8 activations are cached once
// per layer from the N8-tile-major A/B tensors and gathered into the exact
// K-major M16 stream. HP1 scatter-writes results and HP3 fills weights.
module alexnet_m8n126_graph_accelerator_top #(
    parameter int CTRL_ADDR_W = 8,
    parameter bit NATIVE_BATCH8 = 1'b0,
    parameter logic [15:0] BUILD_CLOCK_MHZ = 16'd200
) (
    input logic aclk,
    input logic aresetn,

    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_awaddr,
    input logic [2:0] s_axi_ctrl_awprot,
    input logic s_axi_ctrl_awvalid,
    output logic s_axi_ctrl_awready,
    input logic [31:0] s_axi_ctrl_wdata,
    input logic [3:0] s_axi_ctrl_wstrb,
    input logic s_axi_ctrl_wvalid,
    output logic s_axi_ctrl_wready,
    output logic [1:0] s_axi_ctrl_bresp,
    output logic s_axi_ctrl_bvalid,
    input logic s_axi_ctrl_bready,
    input logic [CTRL_ADDR_W-1:0] s_axi_ctrl_araddr,
    input logic [2:0] s_axi_ctrl_arprot,
    input logic s_axi_ctrl_arvalid,
    output logic s_axi_ctrl_arready,
    output logic [31:0] s_axi_ctrl_rdata,
    output logic [1:0] s_axi_ctrl_rresp,
    output logic s_axi_ctrl_rvalid,
    input logic s_axi_ctrl_rready,

    input logic [63:0] s_axis_camera_tdata,
    input logic [7:0] s_axis_camera_tkeep,
    input logic s_axis_camera_tvalid,
    output logic s_axis_camera_tready,
    input logic s_axis_camera_tlast,

    input logic [127:0] s_axis_mm2s_tdata,
    input logic [15:0] s_axis_mm2s_tkeep,
    input logic s_axis_mm2s_tvalid,
    output logic s_axis_mm2s_tready,
    input logic s_axis_mm2s_tlast,

    input logic [127:0] s_axis_weight_tdata,
    input logic [15:0] s_axis_weight_tkeep,
    input logic s_axis_weight_tvalid,
    output logic s_axis_weight_tready,
    input logic s_axis_weight_tlast,

    output logic [127:0] m_axis_s2mm_tdata,
    output logic [15:0] m_axis_s2mm_tkeep,
    output logic m_axis_s2mm_tvalid,
    input logic m_axis_s2mm_tready,
    output logic m_axis_s2mm_tlast,

    output logic [31:0] m_axi_dma_awaddr,
    output logic [2:0] m_axi_dma_awprot,
    output logic m_axi_dma_awvalid,
    input logic m_axi_dma_awready,
    output logic [31:0] m_axi_dma_wdata,
    output logic [3:0] m_axi_dma_wstrb,
    output logic m_axi_dma_wvalid,
    input logic m_axi_dma_wready,
    input logic [1:0] m_axi_dma_bresp,
    input logic m_axi_dma_bvalid,
    output logic m_axi_dma_bready,
    output logic [31:0] m_axi_dma_araddr,
    output logic [2:0] m_axi_dma_arprot,
    output logic m_axi_dma_arvalid,
    input logic m_axi_dma_arready,
    input logic [31:0] m_axi_dma_rdata,
    input logic [1:0] m_axi_dma_rresp,
    input logic m_axi_dma_rvalid,
    output logic m_axi_dma_rready,

    output logic [31:0] m_axi_weight_dma_awaddr,
    output logic [2:0] m_axi_weight_dma_awprot,
    output logic m_axi_weight_dma_awvalid,
    input logic m_axi_weight_dma_awready,
    output logic [31:0] m_axi_weight_dma_wdata,
    output logic [3:0] m_axi_weight_dma_wstrb,
    output logic m_axi_weight_dma_wvalid,
    input logic m_axi_weight_dma_wready,
    input logic [1:0] m_axi_weight_dma_bresp,
    input logic m_axi_weight_dma_bvalid,
    output logic m_axi_weight_dma_bready,
    output logic [31:0] m_axi_weight_dma_araddr,
    output logic [2:0] m_axi_weight_dma_arprot,
    output logic m_axi_weight_dma_arvalid,
    input logic m_axi_weight_dma_arready,
    input logic [31:0] m_axi_weight_dma_rdata,
    input logic [1:0] m_axi_weight_dma_rresp,
    input logic m_axi_weight_dma_rvalid,
    output logic m_axi_weight_dma_rready,

    output logic irq,
    output logic accelerator_busy,
    output logic accelerator_fault
);

  typedef enum logic [3:0] {
    MAIN_IDLE,
    MAIN_PARAMETER_CACHE_CHECK,
    MAIN_PARAMETER_CACHE_COMMAND,
    MAIN_PARAMETER_CACHE_ARM,
    MAIN_PARAMETER_CACHE_STREAM,
    MAIN_PARAMETER_CACHE_DRAIN,
    MAIN_RASTER_FRAME,
    MAIN_RASTER_COMMAND,
    MAIN_RASTER_ARM,
    MAIN_FC_ARM,
    MAIN_FAILED
  } main_state_t;

  localparam logic [31:0] INPUT_IMAGE_STRIDE = 32'd401408;
  localparam logic [31:0] ACTIVATION_IMAGE_STRIDE = 32'd262144;
  localparam logic [31:0] BATCH_ACTIVATION_OFFSET = 32'd2097152;
  localparam logic [31:0] CONV_WEIGHT_BYTES = 32'd2468544;

  logic rst;
  main_state_t main_state_q;
  logic service_fault_q;
  logic main_s2mm_done_seen_q, weight_dma_done_seen_q;
  logic weight_service_active_q, weight_stream_done_q;
  logic raster_stream_active_q;
  logic [31:0] weight_byte_offset_q;
  logic [12:0] patch_m_base_q;
  logic [3:0] patch_lower_m_count_q, patch_upper_m_count_q;

  logic core_start_valid, core_start_ready;
  logic engine_start_ready;
  logic engine_start_valid, engine_start_fire;
  logic [15:0] core_start_tag;
  logic [15:0] active_inference_tag_q;
  logic [63:0] active_input_base, active_activation_a_base;
  logic [63:0] active_activation_b_base, active_weights_base;
  logic [63:0] active_parameters_base, active_final_output_base;
  logic [31:0] active_dma_timeout_cycles;

  logic engine_weight_request_valid, engine_weight_request_ready;
  logic [3:0] engine_weight_request_layer_id;
  logic [15:0] engine_weight_request_n_base;
  logic [13:0] engine_weight_request_k_offset;
  logic [12:0] engine_weight_request_k_count;
  logic [7:0] engine_weight_request_bank_enable;
  logic [15:0] engine_weight_request_n_lane_mask [0:7];
  logic [15:0] engine_weight_request_context_tag;
  logic engine_weight_axis_ready;

  logic engine_patch_request_valid, engine_patch_request_ready;
  logic [3:0] engine_patch_request_layer_id;
  logic [12:0] engine_patch_request_m_base;
  logic [13:0] engine_patch_request_k_offset;
  logic [12:0] engine_patch_request_k_count;
  logic [15:0] engine_patch_request_m_lane_mask;
  logic [15:0] engine_patch_request_context_tag;
  logic engine_patch_axis_ready;

  logic raster_frame_valid, raster_frame_ready;
  logic raster_axis_ready;
  logic raster_request_ready;
  logic raster_patch_axis_valid, raster_patch_axis_ready;
  logic [127:0] raster_patch_axis_data;
  logic raster_patch_axis_last;
  logic raster_active, raster_frame_active, raster_frame_done;
  logic [15:0] raster_completed_fills, raster_completed_replays;
  logic raster_overlap_active, raster_fault, raster_idle;
  logic raster_patch_active_q;
  logic engine_start_pending_q;
  logic raster_frame_fire;
  logic batch_fc_phase_q;
  logic [2:0] batch_image_q;
  logic [3:0] batch_conv_layer_q;
  logic [15:0] batch_conv_n_base_q;
  logic inference_done_q;
  logic [3:0] engine_start_layer_id, engine_stop_layer_id;
  logic [3:0] engine_fc_batch_size;
  logic [15:0] engine_start_n_base;
  logic engine_start_single_n_tile;
  logic engine_start_weight_fill_enable;
  logic engine_start_weight_release_enable;
  logic engine_start_pool_enable;
  logic [15:0] batch_conv_n_total, batch_conv_n_tile;
  logic batch_conv_n_final;
  logic [31:0] effective_input_base;
  logic [31:0] effective_activation_a_base;
  logic [31:0] effective_activation_b_base;
  logic [31:0] batch_activation_a_base;
  logic [31:0] batch_activation_b_base;

  logic activation_request_valid, activation_request_ready;
  logic activation_dma_cmd_valid, activation_dma_cmd_ready;
  logic activation_dma_selected, activation_mm2s_ready;
  logic [31:0] activation_dma_cmd_address;
  logic [25:0] activation_dma_cmd_length;
  logic [127:0] activation_patch_axis_data;
  logic activation_patch_axis_valid, activation_patch_axis_last;
  logic activation_busy, activation_fault, activation_cache_load_active;
  logic [3:0] activation_cached_layer_id;
  logic [15:0] unused_activation_context_tag;
  logic [7:0] unused_activation_m_count;
  logic [31:0] activation_cache_loads, activation_completed_patches;
  logic [31:0] activation_emitted_patch_words;

  logic fc_batch_request_valid, fc_batch_request_ready;
  logic fc_batch_dma_cmd_valid, fc_batch_dma_cmd_ready;
  logic fc_batch_dma_selected, fc_batch_mm2s_ready;
  logic [31:0] fc_batch_dma_cmd_address;
  logic [25:0] fc_batch_dma_cmd_length;
  logic [127:0] fc_batch_patch_axis_data;
  logic fc_batch_patch_axis_valid, fc_batch_patch_axis_last;
  logic fc_batch_busy, fc_batch_fault, fc_batch_cache_load_active;
  logic [3:0] fc_batch_cached_layer_id;
  logic [31:0] fc_batch_cache_load_commands;
  logic [31:0] fc_batch_completed_patches;
  logic [31:0] fc_batch_emitted_patch_words;

  logic engine_parameter_request_valid, engine_parameter_request_ready;
  logic [3:0] engine_parameter_request_layer_id;
  logic [15:0] engine_parameter_request_n_base;
  logic [15:0] engine_parameter_request_context_tag;
  logic engine_parameter_valid, engine_parameter_ready;
  logic [15:0] engine_parameter_n_base, engine_parameter_context_tag;
  logic signed [31:0] engine_parameter_bias [0:7];
  logic signed [17:0] engine_parameter_multiplier [0:7];
  logic [5:0] engine_parameter_right_shift [0:7];
  logic [7:0] engine_parameter_relu;

  logic engine_result_valid, engine_result_ready;
  logic [63:0] engine_result_values [0:7];
  logic [7:0] engine_result_lane_mask [0:7];
  logic [3:0] engine_result_m_count;
  logic [12:0] engine_result_m_base;
  logic [15:0] engine_result_n_base, engine_result_tile_tag;
  logic engine_result_last_slice;
  logic result_pipe_valid_q;
  logic [63:0] result_pipe_values_q [0:7];
  logic [3:0] result_pipe_layer_id_q, result_pipe_fc_batch_size_q;
  logic [31:0] result_pipe_base_q;
  logic [3:0] result_pipe_m_count_q;
  logic [12:0] result_pipe_m_base_q;
  logic [15:0] result_pipe_n_base_q;
  logic result_pipe_last_slice_q;
  logic engine_layer_complete_valid, engine_layer_complete_ready;
  logic [3:0] engine_layer_complete_id;
  logic engine_layer_complete_requires_pool;
  logic engine_busy, engine_done, engine_failed, engine_fault;
  logic [3:0] engine_active_layer_id;
  logic [15:0] engine_completed_commands;
  logic [31:0] engine_active_cycles, engine_issue_cycles;
  logic [31:0] engine_patch_stall_cycles, engine_weight_stall_cycles;
  logic [31:0] engine_result_stall_cycles;
  logic [31:0] weight_words_loaded, patch_words_loaded;
  logic [31:0] completed_result_slices;
  logic [63:0] useful_mac_count, physical_mac_slot_count;

  logic pool_layer_valid, pool_layer_ready, pool_layer_done;
  logic pool_layer_error, pool_busy;
  logic pool_layer_accepted_q;
  logic [31:0] pool_layer_base;
  logic pool_dma_cmd_valid, pool_dma_cmd_ready, pool_dma_cmd_s2mm;
  logic [31:0] pool_dma_cmd_address;
  logic [25:0] pool_dma_cmd_length;
  logic pool_mm2s_ready;
  logic pool_dma_active_s2mm_q, pool_command_fire;
  logic [127:0] pool_s2mm_data;
  logic [15:0] pool_s2mm_keep;
  logic pool_s2mm_valid, pool_s2mm_ready, pool_s2mm_last;
  logic [5:0] pool_completed_tiles;
  logic [31:0] pool_raw_words, pool_stored_words;

  logic main_mm2s_cmd_valid, main_mm2s_cmd_ready;
  logic [31:0] main_mm2s_cmd_address;
  logic [25:0] main_mm2s_cmd_length;
  logic main_s2mm_cmd_valid, main_s2mm_cmd_ready;
  logic [31:0] main_s2mm_cmd_address;
  logic [25:0] main_s2mm_cmd_length;
  logic main_mm2s_armed, main_mm2s_busy, main_mm2s_done;
  logic main_mm2s_error;
  logic main_s2mm_armed, main_s2mm_busy, main_s2mm_done;
  logic main_s2mm_error;
  logic [3:0] main_mm2s_error_code, main_s2mm_error_code;
  logic [3:0] unused_main_mm2s_state, unused_main_s2mm_state;
  logic main_dma_busy, main_dma_error;
  logic [3:0] main_dma_error_code;

  logic weight_dma_cmd_valid, weight_dma_cmd_ready;
  logic [31:0] weight_dma_cmd_address;
  logic [25:0] weight_dma_cmd_length;
  logic weight_dma_armed, weight_dma_busy, weight_dma_done;
  logic weight_dma_error;
  logic [3:0] weight_dma_error_code, unused_weight_dma_state;
  logic [31:0] unused_weight_dma_status, unused_weight_dma_cycles;

  logic loader_start_valid, loader_start_ready;
  logic loader_axis_ready, loader_parameter_valid, loader_parameter_ready;
  logic loader_parameter_is_fc;
  logic [3:0] loader_parameter_layer_id;
  logic [15:0] loader_parameter_tag, loader_parameter_n_base;
  logic signed [31:0] loader_parameter_bias [0:7];
  logic signed [17:0] loader_parameter_multiplier [0:7];
  logic [5:0] loader_parameter_right_shift [0:7];
  logic loader_busy, loader_fault;
  logic [2:0] unused_loader_lane;
  logic [31:0] unused_loader_accepted, unused_loader_completed;
  logic [31:0] unused_loader_rejected;

  logic parameter_cache_load_start_valid;
  logic parameter_cache_load_start_ready;
  logic parameter_cache_load_active, parameter_cache_load_done;
  logic parameter_cache_valid, parameter_cache_fault;
  logic parameter_cache_request_valid, parameter_cache_request_ready;
  logic [10:0] parameter_cache_record_index;
  logic [127:0] parameter_cache_axis_data;
  logic [15:0] parameter_cache_axis_keep;
  logic parameter_cache_axis_valid, parameter_cache_axis_ready;
  logic parameter_cache_fill_ready;
  logic parameter_cache_axis_last, parameter_cache_replay_active;
  logic [31:0] parameter_cache_completed_loads;
  logic [31:0] parameter_cache_completed_replays;
  logic [63:0] cached_parameters_base_q;

  logic result_coalescer_ready, result_coalescer_busy;
  logic result_coalescer_fault;
  logic result_coalescer_dma_cmd_valid, result_coalescer_dma_cmd_ready;
  logic [31:0] result_coalescer_dma_cmd_address;
  logic [25:0] result_coalescer_dma_cmd_length;
  logic [127:0] result_coalescer_axis_data;
  logic [15:0] result_coalescer_axis_keep;
  logic result_coalescer_axis_valid, result_coalescer_axis_ready;
  logic result_coalescer_axis_last;
  logic [31:0] result_coalescer_accepted_slices;
  logic [31:0] result_coalescer_completed_tiles;
  logic [63:0] result_coalescer_emitted_bytes;

  logic [31:0] result_signature_q;
  logic [31:0] result_signature_fold;
  logic [63:0] ddr_read_bytes_q, ddr_write_bytes_q;
  logic [63:0] main_read_bytes_q, weight_read_bytes_q;
  logic [63:0] camera_read_bytes_q;
  logic pipeline_active_q;
  logic [31:0] pipeline_total_cycles_q, pipeline_engine_cycles_q;
  logic [31:0] pipeline_weight_cycles_q, pipeline_patch_cycles_q;
  logic [31:0] pipeline_pool_cycles_q, pipeline_result_cycles_q;
  logic [31:0] pipeline_raster_cycles_q, pipeline_dma_cycles_q;
  logic [31:0] pipeline_overlap_cycles_q, pipeline_idle_cycles_q;

  logic [25:0] weight_request_bytes;
  logic [31:0] selected_result_base;
  logic main_mm2s_command_fire, main_s2mm_command_fire;
  logic weight_command_fire, parameter_cache_command_fire;
  logic weight_fill_command_selected, parameter_cache_command_selected;
  logic raster_stream_fire, raster_patch_fire;
  logic weight_stream_fire;
  logic core_start_fire;

  function automatic logic [3:0] popcount8(input logic [7:0] value);
    logic [3:0] count;
    begin
      count = 0;
      for (int bit_index = 0; bit_index < 8; bit_index++)
        count = count + value[bit_index];
      return count;
    end
  endfunction

  function automatic logic [25:0] weight_bytes(
      input logic [12:0] k_count,
      input logic [7:0] bank_enable);
    logic [3:0] banks;
    logic [25:0] k_bytes;
    begin
      banks = popcount8(bank_enable);
      k_bytes = {9'd0, k_count, 4'b0000};
      case (banks)
        1: weight_bytes = k_bytes;
        2: weight_bytes = k_bytes << 1;
        3: weight_bytes = k_bytes + (k_bytes << 1);
        4: weight_bytes = k_bytes << 2;
        5: weight_bytes = k_bytes + (k_bytes << 2);
        6: weight_bytes = (k_bytes << 1) + (k_bytes << 2);
        7: weight_bytes = (k_bytes << 3) - k_bytes;
        8: weight_bytes = k_bytes << 3;
        default: weight_bytes = 0;
      endcase
    end
  endfunction

  function automatic logic [31:0] parameter_layer_offset(
      input logic [3:0] layer_id);
    begin
      case (layer_id)
        1: parameter_layer_offset = 0;
        2: parameter_layer_offset = 1024;
        3: parameter_layer_offset = 4096;
        4: parameter_layer_offset = 10240;
        5: parameter_layer_offset = 14336;
        6: parameter_layer_offset = 18432;
        7: parameter_layer_offset = 83968;
        8: parameter_layer_offset = 149504;
        default: parameter_layer_offset = 0;
      endcase
    end
  endfunction

  assign rst = !aresetn;
  assign core_start_ready = main_state_q == MAIN_IDLE &&
                            engine_start_ready &&
                            !accelerator_fault;
  assign core_start_fire = core_start_valid && core_start_ready;
  assign engine_start_valid = engine_start_pending_q &&
                              (main_state_q == MAIN_RASTER_ARM ||
                               main_state_q == MAIN_FC_ARM) &&
                              !accelerator_fault;
  assign engine_start_fire = engine_start_valid && engine_start_ready;
  assign raster_frame_valid = main_state_q == MAIN_RASTER_FRAME &&
                              !accelerator_fault;
  assign raster_frame_fire = raster_frame_valid && raster_frame_ready;
  assign s_axis_camera_tready = 1'b1;
  assign activation_request_valid = engine_patch_request_valid &&
      engine_patch_request_layer_id != 1 && main_state_q == MAIN_IDLE &&
      !(NATIVE_BATCH8 && batch_fc_phase_q) &&
      !pool_busy && !main_mm2s_busy && !accelerator_fault;
  assign fc_batch_request_valid = engine_patch_request_valid &&
      engine_patch_request_layer_id >= 6 && main_state_q == MAIN_IDLE &&
      NATIVE_BATCH8 && batch_fc_phase_q &&
      !pool_busy && !main_mm2s_busy && !accelerator_fault;
  assign activation_dma_cmd_ready = activation_dma_selected &&
                                    main_mm2s_cmd_ready;
  assign fc_batch_dma_cmd_ready = fc_batch_dma_selected &&
                                  main_mm2s_cmd_ready;

  assign effective_input_base = active_input_base[31:0] +
      (NATIVE_BATCH8 ? batch_image_q * INPUT_IMAGE_STRIDE : 0);
  assign effective_activation_a_base = active_activation_a_base[31:0] +
      (NATIVE_BATCH8 && !batch_fc_phase_q ?
       batch_image_q * ACTIVATION_IMAGE_STRIDE : 0);
  assign effective_activation_b_base = active_activation_b_base[31:0] +
      (NATIVE_BATCH8 && !batch_fc_phase_q ?
       batch_image_q * ACTIVATION_IMAGE_STRIDE : 0);
  assign batch_activation_a_base = active_activation_a_base[31:0] +
                                   BATCH_ACTIVATION_OFFSET;
  assign batch_activation_b_base = active_activation_b_base[31:0] +
                                   BATCH_ACTIVATION_OFFSET;
  always_comb begin
    batch_conv_n_total = 0;
    batch_conv_n_tile = 0;
    case (batch_conv_layer_q)
      1: begin batch_conv_n_total = 64;  batch_conv_n_tile = 64;  end
      2: begin batch_conv_n_total = 192; batch_conv_n_tile = 64;  end
      3: begin batch_conv_n_total = 384; batch_conv_n_tile = 112; end
      4, 5: begin batch_conv_n_total = 256; batch_conv_n_tile = 112; end
      default: begin end
    endcase
  end
  assign batch_conv_n_final = batch_conv_n_base_q + batch_conv_n_tile >=
                              batch_conv_n_total;
  assign engine_start_layer_id = NATIVE_BATCH8 ?
      (batch_fc_phase_q ? 4'd6 : batch_conv_layer_q) : 4'd1;
  assign engine_stop_layer_id = NATIVE_BATCH8 ?
      (batch_fc_phase_q ? 4'd8 : batch_conv_layer_q) : 4'd8;
  assign engine_fc_batch_size = NATIVE_BATCH8 && batch_fc_phase_q ?
                                4'd8 : 4'd1;
  assign engine_start_n_base = NATIVE_BATCH8 && !batch_fc_phase_q ?
                               batch_conv_n_base_q : 0;
  assign engine_start_single_n_tile = NATIVE_BATCH8 && !batch_fc_phase_q;
  assign engine_start_weight_fill_enable =
      !(NATIVE_BATCH8 && !batch_fc_phase_q) || batch_image_q == 0;
  assign engine_start_weight_release_enable =
      !(NATIVE_BATCH8 && !batch_fc_phase_q) || batch_image_q == 7;
  assign engine_start_pool_enable =
      !(NATIVE_BATCH8 && !batch_fc_phase_q) || batch_conv_n_final;

  assign weight_request_bytes = weight_bytes(
      engine_weight_request_k_count, engine_weight_request_bank_enable);
  assign parameter_cache_record_index =
      (parameter_layer_offset(engine_parameter_request_layer_id) >> 7) +
      (engine_parameter_request_n_base >> 3);
  assign selected_result_base =
      engine_active_layer_id == 8 ? active_final_output_base[31:0] :
      NATIVE_BATCH8 && batch_fc_phase_q ?
        (engine_active_layer_id == 7 ? batch_activation_a_base :
                                      batch_activation_b_base) :
      engine_active_layer_id == 1 || engine_active_layer_id == 3 ||
      engine_active_layer_id == 5 || engine_active_layer_id == 7 ?
        effective_activation_a_base : effective_activation_b_base;
  assign pool_layer_base = engine_layer_complete_id == 2 ?
                           effective_activation_b_base :
                           effective_activation_a_base;
  assign pool_layer_valid = engine_layer_complete_valid &&
                            engine_layer_complete_requires_pool &&
                            !pool_layer_accepted_q &&
                            main_state_q == MAIN_IDLE &&
                            !result_coalescer_busy &&
                            !main_mm2s_busy && !main_s2mm_busy;
  assign engine_layer_complete_ready = engine_layer_complete_valid &&
      !result_coalescer_busy &&
      (engine_layer_complete_requires_pool ? pool_layer_done : 1'b1);

  always_comb begin
    main_mm2s_cmd_valid = 1'b0;
    main_mm2s_cmd_address = 0;
    main_mm2s_cmd_length = 0;
    main_s2mm_cmd_valid = 1'b0;
    main_s2mm_cmd_address = 0;
    main_s2mm_cmd_length = 0;
    engine_patch_request_ready = 1'b0;
    activation_dma_selected = 1'b0;
    fc_batch_dma_selected = 1'b0;

    if (pool_dma_cmd_valid && !accelerator_fault) begin
      if (pool_dma_cmd_s2mm) begin
        main_s2mm_cmd_valid = 1'b1;
        main_s2mm_cmd_address = pool_dma_cmd_address;
        main_s2mm_cmd_length = pool_dma_cmd_length;
      end else begin
        main_mm2s_cmd_valid = 1'b1;
        main_mm2s_cmd_address = pool_dma_cmd_address;
        main_mm2s_cmd_length = pool_dma_cmd_length;
      end
    end else if (result_coalescer_dma_cmd_valid && !accelerator_fault) begin
      main_s2mm_cmd_valid = 1'b1;
      main_s2mm_cmd_address = result_coalescer_dma_cmd_address;
      main_s2mm_cmd_length = result_coalescer_dma_cmd_length;
    end else if (main_state_q == MAIN_RASTER_COMMAND && !accelerator_fault) begin
      main_mm2s_cmd_valid = 1'b1;
      main_mm2s_cmd_address = effective_input_base;
      main_mm2s_cmd_length = 26'd401408;
    end else if (engine_patch_request_valid &&
                 engine_patch_request_layer_id == 1 &&
                 !accelerator_fault) begin
      engine_patch_request_ready = raster_request_ready;
    end else if (main_state_q == MAIN_IDLE && !accelerator_fault) begin
      if (fc_batch_dma_cmd_valid && NATIVE_BATCH8 && batch_fc_phase_q) begin
        fc_batch_dma_selected = 1'b1;
        main_mm2s_cmd_valid = 1'b1;
        main_mm2s_cmd_address = fc_batch_dma_cmd_address;
        main_mm2s_cmd_length = fc_batch_dma_cmd_length;
      end else if (activation_dma_cmd_valid) begin
        activation_dma_selected = 1'b1;
        main_mm2s_cmd_valid = 1'b1;
        main_mm2s_cmd_address = activation_dma_cmd_address;
        main_mm2s_cmd_length = activation_dma_cmd_length;
      end else if (engine_patch_request_valid &&
                   engine_patch_request_layer_id != 1) begin
        engine_patch_request_ready =
            NATIVE_BATCH8 && batch_fc_phase_q ?
            fc_batch_request_ready : activation_request_ready;
      end
    end
  end

  assign main_mm2s_command_fire = main_mm2s_cmd_valid &&
                                   main_mm2s_cmd_ready;
  assign main_s2mm_command_fire = main_s2mm_cmd_valid &&
                                   main_s2mm_cmd_ready;
  assign pool_dma_cmd_ready = pool_dma_cmd_valid && !accelerator_fault &&
      (pool_dma_cmd_s2mm ? main_s2mm_cmd_ready : main_mm2s_cmd_ready);
  assign result_coalescer_dma_cmd_ready = result_coalescer_dma_cmd_valid &&
      !pool_dma_cmd_valid && !accelerator_fault && main_s2mm_cmd_ready;
  assign pool_command_fire = pool_dma_cmd_valid && pool_dma_cmd_ready;
  assign parameter_cache_command_selected =
      main_state_q == MAIN_PARAMETER_CACHE_COMMAND &&
      parameter_cache_load_start_ready && !weight_service_active_q &&
      !accelerator_fault;
  assign weight_fill_command_selected = !parameter_cache_command_selected &&
      engine_weight_request_valid && !weight_service_active_q &&
      !parameter_cache_load_active && !accelerator_fault;
  assign weight_dma_cmd_valid = parameter_cache_command_selected ||
                                weight_fill_command_selected;
  assign weight_dma_cmd_address = parameter_cache_command_selected ?
      active_parameters_base[31:0] :
      active_weights_base[31:0] + weight_byte_offset_q;
  assign weight_dma_cmd_length = parameter_cache_command_selected ?
                                 26'd165504 : weight_request_bytes;
  assign engine_weight_request_ready = weight_fill_command_selected &&
                                       weight_dma_cmd_ready;
  assign parameter_cache_load_start_valid =
      parameter_cache_command_selected && weight_dma_cmd_ready;
  assign parameter_cache_request_valid = engine_parameter_request_valid &&
                                         loader_start_ready;
  assign loader_start_valid = engine_parameter_request_valid &&
                              parameter_cache_request_ready;
  assign engine_parameter_request_ready = loader_start_ready &&
                                          parameter_cache_request_ready;
  assign weight_command_fire = weight_dma_cmd_valid && weight_dma_cmd_ready;
  assign parameter_cache_command_fire = parameter_cache_command_selected &&
                                        weight_dma_cmd_ready;

  assign s_axis_weight_tready = parameter_cache_load_active ?
                                parameter_cache_fill_ready :
                                weight_service_active_q ?
                                engine_weight_axis_ready :
                                1'b0;
  assign weight_stream_fire = weight_service_active_q &&
      s_axis_weight_tvalid && s_axis_weight_tready;
  assign raster_stream_fire = raster_stream_active_q &&
      s_axis_mm2s_tvalid && raster_axis_ready;
  assign raster_patch_fire = raster_patch_axis_valid &&
                             raster_patch_axis_ready;
  assign s_axis_mm2s_tready =
      pool_busy ? pool_mm2s_ready :
      fc_batch_cache_load_active ? fc_batch_mm2s_ready :
      activation_cache_load_active ? activation_mm2s_ready :
      raster_stream_active_q ? raster_axis_ready : 1'b0;

  assign engine_parameter_valid = loader_parameter_valid;
  assign loader_parameter_ready = engine_parameter_ready;
  assign engine_parameter_n_base = loader_parameter_n_base;
  assign engine_parameter_context_tag = loader_parameter_tag;
  assign engine_parameter_relu = loader_parameter_layer_id == 8 ?
                                  8'h00 : 8'hff;
  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      engine_parameter_bias[lane] = loader_parameter_bias[lane];
      engine_parameter_multiplier[lane] =
          loader_parameter_multiplier[lane];
      engine_parameter_right_shift[lane] =
          loader_parameter_right_shift[lane];
    end
  end

  // Register the result descriptor at the engine/coalescer boundary.  The
  // coalescer's tile-finished predicate includes layer geometry and address
  // arithmetic; feeding that predicate directly back into the payload result
  // handshake creates a long cross-module 200 MHz path.  This one-entry
  // elastic register accepts a replacement in the same cycle that the old
  // entry retires, so it adds latency but no steady-state result bandwidth.
  assign engine_result_ready = !result_pipe_valid_q ||
                               result_coalescer_ready;
  always_ff @(posedge aclk) begin
    if (rst) begin
      result_pipe_valid_q <= 1'b0;
      result_pipe_layer_id_q <= '0;
      result_pipe_fc_batch_size_q <= '0;
      result_pipe_base_q <= '0;
      result_pipe_m_count_q <= '0;
      result_pipe_m_base_q <= '0;
      result_pipe_n_base_q <= '0;
      result_pipe_last_slice_q <= 1'b0;
      for (int row = 0; row < 8; row++)
        result_pipe_values_q[row] <= '0;
    end else if (engine_result_ready) begin
      result_pipe_valid_q <= engine_result_valid;
      if (engine_result_valid) begin
        result_pipe_layer_id_q <= engine_active_layer_id;
        result_pipe_fc_batch_size_q <= engine_fc_batch_size;
        result_pipe_base_q <= selected_result_base;
        result_pipe_m_count_q <= engine_result_m_count;
        result_pipe_m_base_q <= engine_result_m_base;
        result_pipe_n_base_q <= engine_result_n_base;
        result_pipe_last_slice_q <= engine_result_last_slice;
        for (int row = 0; row < 8; row++)
          result_pipe_values_q[row] <= engine_result_values[row];
      end
    end
  end

  assign m_axis_s2mm_tvalid = pool_busy ? pool_s2mm_valid :
                                          result_coalescer_axis_valid;
  assign m_axis_s2mm_tdata = pool_busy ? pool_s2mm_data :
                                          result_coalescer_axis_data;
  assign m_axis_s2mm_tkeep = pool_busy ? pool_s2mm_keep :
                                          result_coalescer_axis_keep;
  assign m_axis_s2mm_tlast = pool_busy ? pool_s2mm_last :
                                          result_coalescer_axis_last;
  assign pool_s2mm_ready = pool_busy && m_axis_s2mm_tready;
  assign result_coalescer_axis_ready = !pool_busy && m_axis_s2mm_tready;

  always_comb begin
    result_signature_fold = 0;
    for (int row = 0; row < 8; row++)
      result_signature_fold = result_signature_fold ^
                              engine_result_values[row][31:0] ^
                              engine_result_values[row][63:32];
  end

  assign main_dma_busy = main_mm2s_busy || main_s2mm_busy;
  assign main_dma_error = main_mm2s_error || main_s2mm_error;
  assign main_dma_error_code = main_mm2s_error ? main_mm2s_error_code :
                               main_s2mm_error_code;
  assign accelerator_fault = service_fault_q || engine_fault ||
      engine_failed || main_dma_error || weight_dma_error || loader_fault ||
      raster_fault || pool_layer_error || activation_fault ||
      fc_batch_fault || parameter_cache_fault || result_coalescer_fault;
  assign accelerator_busy = engine_busy || main_state_q != MAIN_IDLE ||
      weight_service_active_q || main_dma_busy || weight_dma_busy ||
      result_coalescer_busy || parameter_cache_load_active ||
      parameter_cache_replay_active || pool_busy || activation_busy ||
      fc_batch_busy;

  // Count payload bytes only when a transfer is accepted.  These counters
  // therefore include partial final beats and exclude cycles stalled by
  // backpressure.  Camera traffic is counted even though this graph variant
  // currently sinks that optional stream, making redundant DDR reads visible.
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
      .ddr_read_bytes(ddr_read_bytes_q),
      .ddr_write_bytes(ddr_write_bytes_q),
      .main_read_bytes(main_read_bytes_q),
      .weight_read_bytes(weight_read_bytes_q),
      .camera_read_bytes(camera_read_bytes_q)
  );

  always_ff @(posedge aclk) begin
    if (rst) begin
      main_state_q <= MAIN_IDLE;
      service_fault_q <= 1'b0;
      main_s2mm_done_seen_q <= 1'b0;
      weight_dma_done_seen_q <= 1'b0;
      weight_service_active_q <= 1'b0;
      weight_stream_done_q <= 1'b0;
      raster_stream_active_q <= 1'b0;
      pool_layer_accepted_q <= 1'b0;
      pool_dma_active_s2mm_q <= 1'b0;
      weight_byte_offset_q <= 0;
      patch_m_base_q <= 0;
      patch_lower_m_count_q <= 0;
      patch_upper_m_count_q <= 0;
      result_signature_q <= 0;
      active_inference_tag_q <= 0;
      cached_parameters_base_q <= 64'hffff_ffff_ffff_ffff;
      engine_start_pending_q <= 1'b0;
      raster_patch_active_q <= 1'b0;
      batch_fc_phase_q <= 1'b0;
      batch_image_q <= 0;
      batch_conv_layer_q <= 1;
      batch_conv_n_base_q <= 0;
      inference_done_q <= 1'b0;
      pipeline_active_q <= 1'b0;
      pipeline_total_cycles_q <= 0;
      pipeline_engine_cycles_q <= 0;
      pipeline_weight_cycles_q <= 0;
      pipeline_patch_cycles_q <= 0;
      pipeline_pool_cycles_q <= 0;
      pipeline_result_cycles_q <= 0;
      pipeline_raster_cycles_q <= 0;
      pipeline_dma_cycles_q <= 0;
      pipeline_overlap_cycles_q <= 0;
      pipeline_idle_cycles_q <= 0;
    end else begin
      inference_done_q <= 1'b0;
      if (pipeline_active_q) begin
        pipeline_total_cycles_q <= pipeline_total_cycles_q + 1'b1;
        if (engine_busy)
          pipeline_engine_cycles_q <= pipeline_engine_cycles_q + 1'b1;
        if (weight_service_active_q || parameter_cache_load_active)
          pipeline_weight_cycles_q <= pipeline_weight_cycles_q + 1'b1;
        if (activation_busy || fc_batch_busy || raster_patch_active_q)
          pipeline_patch_cycles_q <= pipeline_patch_cycles_q + 1'b1;
        if (pool_busy)
          pipeline_pool_cycles_q <= pipeline_pool_cycles_q + 1'b1;
        if (result_coalescer_busy)
          pipeline_result_cycles_q <= pipeline_result_cycles_q + 1'b1;
        if (raster_stream_active_q || main_state_q == MAIN_RASTER_FRAME ||
            main_state_q == MAIN_RASTER_COMMAND ||
            main_state_q == MAIN_RASTER_ARM)
          pipeline_raster_cycles_q <= pipeline_raster_cycles_q + 1'b1;
        if (main_dma_busy || weight_dma_busy)
          pipeline_dma_cycles_q <= pipeline_dma_cycles_q + 1'b1;
        if (engine_busy &&
            (weight_service_active_q || activation_busy || fc_batch_busy ||
             raster_patch_active_q))
          pipeline_overlap_cycles_q <= pipeline_overlap_cycles_q + 1'b1;
        if (!engine_busy && main_state_q == MAIN_IDLE &&
            !weight_service_active_q && !parameter_cache_load_active &&
            !main_dma_busy && !weight_dma_busy && !pool_busy &&
            !result_coalescer_busy && !activation_busy && !fc_batch_busy &&
            !raster_stream_active_q)
          pipeline_idle_cycles_q <= pipeline_idle_cycles_q + 1'b1;
      end
      if (core_start_fire) begin
        pipeline_active_q <= 1'b1;
        engine_start_pending_q <= 1'b1;
        active_inference_tag_q <= core_start_tag;
        weight_byte_offset_q <= 0;
        result_signature_q <= 0;
        raster_stream_active_q <= 1'b0;
        batch_fc_phase_q <= 1'b0;
        batch_image_q <= 0;
        batch_conv_layer_q <= 1;
        batch_conv_n_base_q <= 0;
      end

      if (engine_start_fire)
        engine_start_pending_q <= 1'b0;

      if (engine_done) begin
        if (NATIVE_BATCH8 && !batch_fc_phase_q) begin
          engine_start_pending_q <= 1'b1;
          raster_stream_active_q <= 1'b0;
          if (batch_image_q != 7) begin
            batch_image_q <= batch_image_q + 1'b1;
            main_state_q <= batch_conv_layer_q == 1 ?
                            MAIN_RASTER_FRAME : MAIN_FC_ARM;
          end else if (!batch_conv_n_final) begin
            batch_image_q <= 0;
            batch_conv_n_base_q <= batch_conv_n_base_q +
                                   batch_conv_n_tile;
            main_state_q <= MAIN_FC_ARM;
          end else if (batch_conv_layer_q != 5) begin
            batch_image_q <= 0;
            batch_conv_layer_q <= batch_conv_layer_q + 1'b1;
            batch_conv_n_base_q <= 0;
            main_state_q <= MAIN_FC_ARM;
          end else begin
            batch_fc_phase_q <= 1'b1;
            weight_byte_offset_q <= CONV_WEIGHT_BYTES;
            main_state_q <= MAIN_FC_ARM;
          end
        end else begin
          inference_done_q <= 1'b1;
          pipeline_active_q <= 1'b0;
        end
      end

      // A layer-complete request is level-held until the pool-done pulse is
      // consumed by the scheduler. The pool service returns to IDLE on that
      // same pulse, so remember the first acceptance and prevent a second
      // launch during the one-cycle scheduler retirement window.
      if (!engine_layer_complete_valid)
        pool_layer_accepted_q <= 1'b0;
      else if (pool_layer_valid && pool_layer_ready)
        pool_layer_accepted_q <= 1'b1;

      if (engine_patch_request_valid && engine_patch_request_ready &&
          engine_patch_request_layer_id == 1) begin
        raster_patch_active_q <= 1'b1;
        patch_m_base_q <= engine_patch_request_m_base;
        patch_lower_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[7:0]);
        patch_upper_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[15:8]);
      end
      if (raster_patch_fire && raster_patch_axis_last)
        raster_patch_active_q <= 1'b0;

      if (engine_patch_request_valid && engine_patch_request_ready &&
          engine_patch_request_layer_id != 1) begin
        patch_m_base_q <= engine_patch_request_m_base;
        patch_lower_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[7:0]);
        patch_upper_m_count_q <=
            popcount8(engine_patch_request_m_lane_mask[15:8]);
      end

      if (main_s2mm_done)
        main_s2mm_done_seen_q <= 1'b1;
      if (weight_dma_done)
        weight_dma_done_seen_q <= 1'b1;

      if (weight_command_fire && weight_fill_command_selected) begin
        weight_service_active_q <= 1'b1;
        weight_stream_done_q <= 1'b0;
        weight_dma_done_seen_q <= 1'b0;
        weight_byte_offset_q <= weight_byte_offset_q +
                                weight_request_bytes;
      end
      if (parameter_cache_command_fire) begin
        weight_dma_done_seen_q <= 1'b0;
      end
      if (pool_command_fire)
        pool_dma_active_s2mm_q <= pool_dma_cmd_s2mm;
      if (weight_stream_fire) begin
        if (s_axis_weight_tkeep != 16'hffff)
          service_fault_q <= 1'b1;
        if (s_axis_weight_tlast)
          weight_stream_done_q <= 1'b1;
      end
      if (weight_service_active_q &&
          (weight_stream_done_q ||
           (weight_stream_fire && s_axis_weight_tlast)) &&
          (weight_dma_done_seen_q || weight_dma_done)) begin
        weight_service_active_q <= 1'b0;
        weight_stream_done_q <= 1'b0;
        weight_dma_done_seen_q <= 1'b0;
      end

      if (engine_result_valid && engine_result_ready)
        result_signature_q <= result_signature_q ^ result_signature_fold;

      case (main_state_q)
        MAIN_IDLE: begin
          if (core_start_fire)
            main_state_q <= MAIN_PARAMETER_CACHE_CHECK;
        end

        MAIN_PARAMETER_CACHE_CHECK:
          if (parameter_cache_valid &&
              cached_parameters_base_q == active_parameters_base)
            main_state_q <= MAIN_RASTER_FRAME;
          else
            main_state_q <= MAIN_PARAMETER_CACHE_COMMAND;

        MAIN_PARAMETER_CACHE_COMMAND:
          if (parameter_cache_command_fire)
            main_state_q <= MAIN_PARAMETER_CACHE_ARM;

        MAIN_PARAMETER_CACHE_ARM:
          if (weight_dma_armed)
            main_state_q <= MAIN_PARAMETER_CACHE_STREAM;

        MAIN_PARAMETER_CACHE_STREAM:
          if (parameter_cache_load_done) begin
            if (weight_dma_done_seen_q || weight_dma_done) begin
              weight_dma_done_seen_q <= 1'b0;
              cached_parameters_base_q <= active_parameters_base;
              main_state_q <= MAIN_RASTER_FRAME;
            end else begin
              main_state_q <= MAIN_PARAMETER_CACHE_DRAIN;
            end
          end

        MAIN_PARAMETER_CACHE_DRAIN:
          if (weight_dma_done_seen_q || weight_dma_done) begin
            weight_dma_done_seen_q <= 1'b0;
            cached_parameters_base_q <= active_parameters_base;
            main_state_q <= MAIN_RASTER_FRAME;
          end

        MAIN_RASTER_FRAME:
          if (raster_frame_fire)
            main_state_q <= MAIN_RASTER_COMMAND;

        MAIN_RASTER_COMMAND: if (main_mm2s_command_fire) begin
          raster_stream_active_q <= 1'b1;
          main_state_q <= MAIN_RASTER_ARM;
        end

        MAIN_RASTER_ARM: begin
          if (engine_start_fire)
            main_state_q <= MAIN_IDLE;
        end

        MAIN_FC_ARM: begin
          if (engine_start_fire)
            main_state_q <= MAIN_IDLE;
        end

        MAIN_FAILED: main_state_q <= MAIN_FAILED;
        default: begin
          service_fault_q <= 1'b1;
          main_state_q <= MAIN_FAILED;
        end
      endcase

      if (main_dma_error || weight_dma_error || loader_fault || raster_fault ||
          pool_layer_error || activation_fault || engine_fault ||
          engine_failed || fc_batch_fault || parameter_cache_fault ||
          result_coalescer_fault) begin
        service_fault_q <= 1'b1;
        main_state_q <= MAIN_FAILED;
      end

      if (raster_stream_fire && s_axis_mm2s_tlast)
        raster_stream_active_q <= 1'b0;
    end
  end

  assign raster_patch_axis_ready = raster_patch_active_q &&
                                   engine_patch_axis_ready;

  alexnet_m16_raster_patch_service u_conv1_raster_patches (
      .clk(aclk), .rst,
      .frame_valid(raster_frame_valid), .frame_ready(raster_frame_ready),
      .frame_input_h(8'd224), .frame_input_w(8'd224),
      .frame_channel_count(4'd3), .frame_lane_mask(8'h07),
      .frame_kernel(4'd11), .frame_stride(3'd4), .frame_padding(3'd2),
      .frame_k_count(13'd363), .frame_tag(active_inference_tag_q),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && raster_stream_active_q),
      .s_axis_tready(raster_axis_ready), .s_axis_tlast(s_axis_mm2s_tlast),
      .request_valid(engine_patch_request_valid &&
          engine_patch_request_layer_id == 1),
      .request_ready(raster_request_ready),
      .request_k_count(engine_patch_request_k_count),
      .request_m_lane_mask(engine_patch_request_m_lane_mask),
      .request_context_tag(engine_patch_request_context_tag),
      .patch_axis_valid(raster_patch_axis_valid),
      .patch_axis_ready(raster_patch_axis_ready),
      .patch_axis_data(raster_patch_axis_data),
      .patch_axis_last(raster_patch_axis_last),
      .raster_active, .frame_active(raster_frame_active),
      .frame_done(raster_frame_done),
      .completed_patch_fills(raster_completed_fills),
      .completed_patch_replays(raster_completed_replays),
      .overlap_active(raster_overlap_active), .fault(raster_fault),
      .idle(raster_idle)
  );

  alexnet_m8n126_activation_patch_service u_activation_patches (
      .clk(aclk), .rst,
      .request_valid(activation_request_valid),
      .request_ready(activation_request_ready),
      .request_layer_id(engine_patch_request_layer_id),
      .request_m_base(engine_patch_request_m_base),
      .request_k_offset(engine_patch_request_k_offset),
      .request_k_count(engine_patch_request_k_count),
      .request_m_lane_mask(engine_patch_request_m_lane_mask),
      .request_context_tag(engine_patch_request_context_tag),
      .activation_a_base(effective_activation_a_base),
      .activation_b_base(effective_activation_b_base),
      .dma_command_valid(activation_dma_cmd_valid),
      .dma_command_ready(activation_dma_cmd_ready),
      .dma_command_address(activation_dma_cmd_address),
      .dma_command_length(activation_dma_cmd_length),
      .dma_armed(main_mm2s_armed), .dma_done(main_mm2s_done),
      .dma_error(main_mm2s_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && activation_cache_load_active),
      .s_axis_tready(activation_mm2s_ready),
      .s_axis_tlast(s_axis_mm2s_tlast),
      .patch_axis_tdata(activation_patch_axis_data),
      .patch_axis_tvalid(activation_patch_axis_valid),
      .patch_axis_tready(engine_patch_axis_ready),
      .patch_axis_tlast(activation_patch_axis_last),
      .busy(activation_busy), .fault(activation_fault),
      .cache_load_active(activation_cache_load_active),
      .cached_layer_id(activation_cached_layer_id),
      .active_context_tag(unused_activation_context_tag),
      .active_m_count(unused_activation_m_count),
      .cache_loads(activation_cache_loads),
      .completed_patches(activation_completed_patches),
      .emitted_patch_words(activation_emitted_patch_words)
  );

  alexnet_m8n126_fc_batch8_activation_patch_service
      u_fc_batch8_activation_patches (
      .clk(aclk), .rst,
      .request_valid(fc_batch_request_valid),
      .request_ready(fc_batch_request_ready),
      .request_layer_id(engine_patch_request_layer_id),
      .request_m_base(engine_patch_request_m_base),
      .request_k_offset(engine_patch_request_k_offset),
      .request_k_count(engine_patch_request_k_count),
      .request_m_lane_mask(engine_patch_request_m_lane_mask),
      .request_context_tag(engine_patch_request_context_tag),
      .pool5_image0_base(active_activation_a_base[31:0]),
      .batch_activation_a_base(batch_activation_a_base),
      .batch_activation_b_base(batch_activation_b_base),
      .dma_command_valid(fc_batch_dma_cmd_valid),
      .dma_command_ready(fc_batch_dma_cmd_ready),
      .dma_command_address(fc_batch_dma_cmd_address),
      .dma_command_length(fc_batch_dma_cmd_length),
      .dma_armed(main_mm2s_armed), .dma_done(main_mm2s_done),
      .dma_error(main_mm2s_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid &&
                     fc_batch_cache_load_active),
      .s_axis_tready(fc_batch_mm2s_ready),
      .s_axis_tlast(s_axis_mm2s_tlast),
      .patch_axis_tdata(fc_batch_patch_axis_data),
      .patch_axis_tvalid(fc_batch_patch_axis_valid),
      .patch_axis_tready(engine_patch_axis_ready),
      .patch_axis_tlast(fc_batch_patch_axis_last),
      .busy(fc_batch_busy), .fault(fc_batch_fault),
      .cache_load_active(fc_batch_cache_load_active),
      .cached_layer_id(fc_batch_cached_layer_id),
      .cache_load_commands(fc_batch_cache_load_commands),
      .completed_patches(fc_batch_completed_patches),
      .emitted_patch_words(fc_batch_emitted_patch_words)
  );

  alexnet_m8n126_graph_payload_engine u_graph_payload (
      .clk(aclk), .rst,
      .start_valid(engine_start_valid),
      .start_ready(engine_start_ready), .start_tag(active_inference_tag_q),
      .start_layer_id(engine_start_layer_id),
      .stop_layer_id(engine_stop_layer_id),
      .fc_batch_size(engine_fc_batch_size),
      .start_n_base(engine_start_n_base),
      .start_single_n_tile(engine_start_single_n_tile),
      .start_weight_fill_enable(engine_start_weight_fill_enable),
      .start_weight_release_enable(engine_start_weight_release_enable),
      .start_pool_enable(engine_start_pool_enable),
      .weight_request_valid(engine_weight_request_valid),
      .weight_request_ready(engine_weight_request_ready),
      .weight_request_layer_id(engine_weight_request_layer_id),
      .weight_request_n_base(engine_weight_request_n_base),
      .weight_request_k_offset(engine_weight_request_k_offset),
      .weight_request_k_count(engine_weight_request_k_count),
      .weight_request_bank_enable(engine_weight_request_bank_enable),
      .weight_request_n_lane_mask(engine_weight_request_n_lane_mask),
      .weight_request_context_tag(engine_weight_request_context_tag),
      .weight_axis_valid(s_axis_weight_tvalid && weight_service_active_q),
      .weight_axis_ready(engine_weight_axis_ready),
      .weight_axis_data(s_axis_weight_tdata),
      .weight_axis_last(s_axis_weight_tlast),
      .patch_request_valid(engine_patch_request_valid),
      .patch_request_ready(engine_patch_request_ready),
      .patch_request_layer_id(engine_patch_request_layer_id),
      .patch_request_m_base(engine_patch_request_m_base),
      .patch_request_k_offset(engine_patch_request_k_offset),
      .patch_request_k_count(engine_patch_request_k_count),
      .patch_request_m_lane_mask(engine_patch_request_m_lane_mask),
      .patch_request_context_tag(engine_patch_request_context_tag),
      .patch_axis_valid(raster_patch_active_q ? raster_patch_axis_valid :
          NATIVE_BATCH8 && batch_fc_phase_q ?
          fc_batch_patch_axis_valid : activation_patch_axis_valid),
      .patch_axis_ready(engine_patch_axis_ready),
      .patch_axis_data(raster_patch_active_q ? raster_patch_axis_data :
          NATIVE_BATCH8 && batch_fc_phase_q ?
          fc_batch_patch_axis_data : activation_patch_axis_data),
      .patch_axis_last(raster_patch_active_q ? raster_patch_axis_last :
          NATIVE_BATCH8 && batch_fc_phase_q ?
          fc_batch_patch_axis_last : activation_patch_axis_last),
      .parameter_request_valid(engine_parameter_request_valid),
      .parameter_request_ready(engine_parameter_request_ready),
      .parameter_request_layer_id(engine_parameter_request_layer_id),
      .parameter_request_n_base(engine_parameter_request_n_base),
      .parameter_request_context_tag(engine_parameter_request_context_tag),
      .parameter_valid(engine_parameter_valid),
      .parameter_ready(engine_parameter_ready),
      .parameter_n_base(engine_parameter_n_base),
      .parameter_context_tag(engine_parameter_context_tag),
      .parameter_bias(engine_parameter_bias),
      .parameter_multiplier(engine_parameter_multiplier),
      .parameter_right_shift(engine_parameter_right_shift),
      .parameter_relu(engine_parameter_relu),
      .result_valid(engine_result_valid),
      .result_ready(engine_result_ready),
      .result_values(engine_result_values),
      .result_lane_mask(engine_result_lane_mask),
      .result_m_count(engine_result_m_count),
      .result_m_base(engine_result_m_base),
      .result_n_base(engine_result_n_base),
      .result_tile_tag(engine_result_tile_tag),
      .result_last_slice(engine_result_last_slice),
      .layer_complete_valid(engine_layer_complete_valid),
      .layer_complete_ready(engine_layer_complete_ready),
      .layer_complete_id(engine_layer_complete_id),
      .layer_complete_requires_pool(engine_layer_complete_requires_pool),
      .busy(engine_busy), .inference_done(engine_done),
      .inference_failed(engine_failed), .fault(engine_fault),
      .active_layer_id(engine_active_layer_id),
      .completed_commands(engine_completed_commands),
      .active_cycles(engine_active_cycles),
      .issue_cycles(engine_issue_cycles),
      .patch_stall_cycles(engine_patch_stall_cycles),
      .weight_stall_cycles(engine_weight_stall_cycles),
      .result_stall_cycles(engine_result_stall_cycles),
      .weight_words_loaded, .patch_words_loaded,
      .completed_result_slices, .useful_mac_count,
      .physical_mac_slot_count
  );

  alexnet_parameter_record_loader u_parameter_loader (
      .clk(aclk), .rst,
      .start_valid(loader_start_valid), .start_ready(loader_start_ready),
      .start_is_fc(engine_parameter_request_layer_id >= 6),
      .start_layer_id(engine_parameter_request_layer_id),
      .start_job_tag(engine_parameter_request_context_tag),
      .start_n_base(engine_parameter_request_n_base),
      .s_axis_tdata(parameter_cache_axis_data),
      .s_axis_tkeep(parameter_cache_axis_keep),
      .s_axis_tvalid(parameter_cache_axis_valid),
      .s_axis_tready(loader_axis_ready),
      .s_axis_tlast(parameter_cache_axis_last),
      .parameter_valid(loader_parameter_valid),
      .parameter_ready(loader_parameter_ready),
      .parameter_is_fc(loader_parameter_is_fc),
      .parameter_layer_id(loader_parameter_layer_id),
      .parameter_job_tag(loader_parameter_tag),
      .parameter_n_base(loader_parameter_n_base),
      .parameter_bias(loader_parameter_bias),
      .parameter_multiplier(loader_parameter_multiplier),
      .parameter_right_shift(loader_parameter_right_shift),
      .busy(loader_busy), .fault(loader_fault),
      .active_lane(unused_loader_lane),
      .accepted_tiles(unused_loader_accepted),
      .completed_tiles(unused_loader_completed),
      .rejected_tiles(unused_loader_rejected)
  );

  assign parameter_cache_axis_ready = loader_axis_ready;

  alexnet_parameter_blob_cache u_parameter_cache (
      .clk(aclk), .rst,
      .load_start_valid(parameter_cache_load_start_valid),
      .load_start_ready(parameter_cache_load_start_ready),
      .s_axis_tdata(s_axis_weight_tdata),
      .s_axis_tkeep(s_axis_weight_tkeep),
      .s_axis_tvalid(s_axis_weight_tvalid &&
                     parameter_cache_load_active),
      .s_axis_tready(parameter_cache_fill_ready),
      .s_axis_tlast(s_axis_weight_tlast),
      .load_active(parameter_cache_load_active),
      .load_done(parameter_cache_load_done),
      .cache_valid(parameter_cache_valid),
      .request_valid(parameter_cache_request_valid),
      .request_ready(parameter_cache_request_ready),
      .request_record_index(parameter_cache_record_index),
      .m_axis_tdata(parameter_cache_axis_data),
      .m_axis_tkeep(parameter_cache_axis_keep),
      .m_axis_tvalid(parameter_cache_axis_valid),
      .m_axis_tready(parameter_cache_axis_ready),
      .m_axis_tlast(parameter_cache_axis_last),
      .replay_active(parameter_cache_replay_active),
      .fault(parameter_cache_fault),
      .completed_loads(parameter_cache_completed_loads),
      .completed_replays(parameter_cache_completed_replays)
  );

  alexnet_m8n126_result_tile_coalescer u_result_coalescer (
      .clk(aclk), .rst,
      .result_valid(result_pipe_valid_q),
      .result_ready(result_coalescer_ready),
      .result_layer_id(result_pipe_layer_id_q),
      .fc_batch_size(result_pipe_fc_batch_size_q),
      .result_base(result_pipe_base_q),
      .result_values(result_pipe_values_q),
      .result_m_count(result_pipe_m_count_q),
      .result_m_base(result_pipe_m_base_q),
      .result_n_base(result_pipe_n_base_q),
      .result_last_slice(result_pipe_last_slice_q),
      .dma_command_valid(result_coalescer_dma_cmd_valid),
      .dma_command_ready(result_coalescer_dma_cmd_ready),
      .dma_command_address(result_coalescer_dma_cmd_address),
      .dma_command_length(result_coalescer_dma_cmd_length),
      .dma_armed(main_s2mm_armed), .dma_done(main_s2mm_done),
      .dma_error(main_s2mm_error),
      .m_axis_tdata(result_coalescer_axis_data),
      .m_axis_tkeep(result_coalescer_axis_keep),
      .m_axis_tvalid(result_coalescer_axis_valid),
      .m_axis_tready(result_coalescer_axis_ready),
      .m_axis_tlast(result_coalescer_axis_last),
      .busy(result_coalescer_busy), .fault(result_coalescer_fault),
      .accepted_slices(result_coalescer_accepted_slices),
      .completed_tiles(result_coalescer_completed_tiles),
      .emitted_bytes(result_coalescer_emitted_bytes)
  );

  alexnet_m8n126_inplace_pool_service u_inplace_pool_service (
      .clk(aclk), .rst,
      .layer_valid(pool_layer_valid), .layer_ready(pool_layer_ready),
      .layer_id(engine_layer_complete_id),
      .layer_job_tag(active_inference_tag_q),
      .layer_buffer_base(pool_layer_base),
      .dma_command_valid(pool_dma_cmd_valid),
      .dma_command_ready(pool_dma_cmd_ready),
      .dma_command_s2mm(pool_dma_cmd_s2mm),
      .dma_command_address(pool_dma_cmd_address),
      .dma_command_length(pool_dma_cmd_length),
      .dma_armed(pool_dma_active_s2mm_q ? main_s2mm_armed :
                                                 main_mm2s_armed),
      .dma_done(pool_dma_active_s2mm_q ? main_s2mm_done : main_mm2s_done),
      .dma_error(pool_dma_active_s2mm_q ? main_s2mm_error :
                                                 main_mm2s_error),
      .s_axis_tdata(s_axis_mm2s_tdata),
      .s_axis_tkeep(s_axis_mm2s_tkeep),
      .s_axis_tvalid(s_axis_mm2s_tvalid && pool_busy),
      .s_axis_tready(pool_mm2s_ready), .s_axis_tlast(s_axis_mm2s_tlast),
      .m_axis_tdata(pool_s2mm_data), .m_axis_tkeep(pool_s2mm_keep),
      .m_axis_tvalid(pool_s2mm_valid), .m_axis_tready(pool_s2mm_ready),
      .m_axis_tlast(pool_s2mm_last), .layer_done(pool_layer_done),
      .layer_error(pool_layer_error), .busy(pool_busy),
      .completed_tiles(pool_completed_tiles),
      .raw_words_read(pool_raw_words),
      .pooled_words_written(pool_stored_words)
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
      .mm2s_state(unused_main_mm2s_state),
      .s2mm_cmd_valid(main_s2mm_cmd_valid),
      .s2mm_cmd_ready(main_s2mm_cmd_ready),
      .s2mm_cmd_address(main_s2mm_cmd_address),
      .s2mm_cmd_length(main_s2mm_cmd_length),
      .s2mm_timeout_cycles(active_dma_timeout_cycles),
      .s2mm_armed(main_s2mm_armed), .s2mm_busy(main_s2mm_busy),
      .s2mm_done(main_s2mm_done), .s2mm_error(main_s2mm_error),
      .s2mm_error_code(main_s2mm_error_code),
      .s2mm_state(unused_main_s2mm_state),
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
      .cmd_valid(weight_dma_cmd_valid), .cmd_ready(weight_dma_cmd_ready),
      .cmd_s2mm(1'b0), .cmd_buffer_addr(weight_dma_cmd_address),
      .cmd_length_bytes(weight_dma_cmd_length),
      .cmd_timeout_cycles(active_dma_timeout_cycles),
      .armed(weight_dma_armed), .busy(weight_dma_busy),
      .done(weight_dma_done), .error(weight_dma_error),
      .error_code(weight_dma_error_code),
      .last_status(unused_weight_dma_status),
      .active_cycles(unused_weight_dma_cycles),
      .state_debug(unused_weight_dma_state),
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

  alexnet_axi_lite_regs #(
      .ADDR_W(CTRL_ADDR_W), .MODULE_ID(16'h4d38),
      .VERSION(NATIVE_BATCH8 ? 8'h85 : 8'h83),
      .BUILD_M(8'd8), .BUILD_N(8'd126),
      .BUILD_CLOCK_MHZ(BUILD_CLOCK_MHZ)
  ) u_control_regs (
      .clk(aclk), .rst,
      .s_axi_awaddr(s_axi_ctrl_awaddr),
      .s_axi_awvalid(s_axi_ctrl_awvalid),
      .s_axi_awready(s_axi_ctrl_awready),
      .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
      .s_axi_wvalid(s_axi_ctrl_wvalid),
      .s_axi_wready(s_axi_ctrl_wready), .s_axi_bresp(s_axi_ctrl_bresp),
      .s_axi_bvalid(s_axi_ctrl_bvalid),
      .s_axi_bready(s_axi_ctrl_bready),
      .s_axi_araddr(s_axi_ctrl_araddr),
      .s_axi_arvalid(s_axi_ctrl_arvalid),
      .s_axi_arready(s_axi_ctrl_arready),
      .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp),
      .s_axi_rvalid(s_axi_ctrl_rvalid),
      .s_axi_rready(s_axi_ctrl_rready),
      .core_start_valid, .core_start_ready, .core_start_tag,
      .active_input_base, .active_activation_a_base,
      .active_activation_b_base, .active_weights_base,
      .active_parameters_base, .active_final_output_base,
      .active_dma_timeout_cycles,
      .core_busy(accelerator_busy), .inference_done(inference_done_q),
      .inference_failed(engine_failed), .core_fault(accelerator_fault),
      .fault_code(accelerator_fault ? 4'h8 : 4'h0),
      .fault_detail({main_dma_error_code, weight_dma_error_code}),
      .graph_phase({1'b0, main_state_q}),
      .active_layer_id(engine_active_layer_id),
      .active_inference_tag(active_inference_tag_q),
      .completed_conv_layers(inference_done_q ? 3'd5 :
          engine_active_layer_id <= 1 ? 3'd0 :
          engine_active_layer_id > 5 ? 3'd5 :
          engine_active_layer_id[2:0] - 1'b1),
      .completed_fc_layers(inference_done_q ? 2'd3 :
          engine_active_layer_id <= 6 ? 2'd0 :
          engine_active_layer_id >= 8 ? 2'd2 : 2'd1),
      .pool5_cache_valid(1'b0),
      .dma_busy(main_dma_busy || weight_dma_busy),
      .dma_error(main_dma_error || weight_dma_error),
      .dma_error_code(main_dma_error ? main_dma_error_code :
                      weight_dma_error_code),
      .dma_active_source(weight_service_active_q ? 3'd1 :
                         (activation_busy || fc_batch_busy) ? 3'd2 :
                         parameter_cache_load_active ? 3'd3 :
                         result_coalescer_busy ? 3'd4 : 3'd0),
      .dma_accepted_requests(weight_words_loaded + patch_words_loaded),
      .dma_issued_commands({16'd0, engine_completed_commands}),
      .dma_completed_transfers(result_coalescer_completed_tiles),
      .conv_storage_completed_tiles(result_coalescer_completed_tiles),
      .perf_active_cycles(engine_active_cycles),
      .perf_issue_cycles(engine_issue_cycles),
      .perf_weight_stall_cycles(engine_weight_stall_cycles),
      .perf_activation_stall_cycles(engine_patch_stall_cycles),
      .perf_result_stall_cycles(engine_result_stall_cycles),
      .perf_useful_mac_count(useful_mac_count),
      .perf_peak_mac_slot_count(physical_mac_slot_count),
      .perf_result_signature(result_signature_q),
      .perf_completed_tiles(engine_completed_commands),
      .perf_ddr_read_bytes(ddr_read_bytes_q),
      .perf_ddr_write_bytes(ddr_write_bytes_q),
      .perf_main_read_bytes(main_read_bytes_q),
      .perf_weight_read_bytes(weight_read_bytes_q),
      .perf_camera_read_bytes(camera_read_bytes_q),
      .perf_pipeline_total_cycles(pipeline_total_cycles_q),
      .perf_engine_cycles(pipeline_engine_cycles_q),
      .perf_weight_service_cycles(pipeline_weight_cycles_q),
      .perf_patch_service_cycles(pipeline_patch_cycles_q),
      .perf_pool_cycles(pipeline_pool_cycles_q),
      .perf_result_service_cycles(pipeline_result_cycles_q),
      .perf_raster_cycles(pipeline_raster_cycles_q),
      .perf_dma_cycles(pipeline_dma_cycles_q),
      .perf_overlap_cycles(pipeline_overlap_cycles_q),
      .perf_pipeline_idle_cycles(pipeline_idle_cycles_q),
      .irq,
      .start_pending(), .done_sticky(), .failed_sticky(),
      .fault_sticky(), .start_rejected_sticky()
  );

`ifndef SYNTHESIS
  always_ff @(posedge aclk) begin
    if (!rst) begin
      if (weight_command_fire && weight_fill_command_selected &&
          weight_request_bytes == 0)
        $fatal(1, "weight DMA accepted a zero-length graph request");
      if ((main_mm2s_command_fire && main_mm2s_cmd_length == 0) ||
          (main_s2mm_command_fire && main_s2mm_cmd_length == 0))
        $fatal(1, "main DMA accepted a zero-length graph request");
      if (engine_parameter_request_valid && engine_parameter_request_ready &&
          parameter_cache_record_index >= 1293)
        $fatal(1, "parameter cache record index is out of range");
    end
  end
`endif

endmodule
