`timescale 1ns/1ps

// Pure Eyeriss-RS board boundary through complete N8 result storage and
// batch-eight Conv1/Conv2/Conv5 max pooling.  Compute/result storage own the
// main DMA channels during a layer.  At a pooling layer barrier, the in-place
// pool service sequentially takes the MM2S and S2MM channels before the next
// layer is released.
module alexnet_eyeriss_rs_batch8_board_store_top #(
  parameter int TAG_W = 16
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       start_valid,
  output logic                       start_ready,
  input  logic [TAG_W-1:0]           start_tag,
  input  logic [63:0]                input_base,
  input  logic [63:0]                activation_a_base,
  input  logic [63:0]                activation_b_base,
  input  logic [63:0]                weights_base,
  input  logic [63:0]                parameters_base,
  input  logic [63:0]                final_output_base,

  output logic                       weight_dma_command_valid,
  input  logic                       weight_dma_command_ready,
  output logic [31:0]                weight_dma_command_address,
  output logic [25:0]                weight_dma_command_length,
  input  logic                       weight_dma_armed,
  input  logic                       weight_dma_done,
  input  logic                       weight_dma_error,
  input  logic [127:0]               weight_axis_tdata,
  input  logic [15:0]                weight_axis_tkeep,
  input  logic                       weight_axis_tvalid,
  output logic                       weight_axis_tready,
  input  logic                       weight_axis_tlast,

  output logic                       main_mm2s_command_valid,
  input  logic                       main_mm2s_command_ready,
  output logic [31:0]                main_mm2s_command_address,
  output logic [25:0]                main_mm2s_command_length,
  input  logic                       main_mm2s_armed,
  input  logic                       main_mm2s_done,
  input  logic                       main_mm2s_error,
  input  logic [127:0]               main_mm2s_axis_tdata,
  input  logic [15:0]                main_mm2s_axis_tkeep,
  input  logic                       main_mm2s_axis_tvalid,
  output logic                       main_mm2s_axis_tready,
  input  logic                       main_mm2s_axis_tlast,

  output logic                       main_s2mm_command_valid,
  input  logic                       main_s2mm_command_ready,
  output logic [31:0]                main_s2mm_command_address,
  output logic [25:0]                main_s2mm_command_length,
  input  logic                       main_s2mm_armed,
  input  logic                       main_s2mm_done,
  input  logic                       main_s2mm_error,
  output logic [127:0]               main_s2mm_axis_tdata,
  output logic [15:0]                main_s2mm_axis_tkeep,
  output logic                       main_s2mm_axis_tvalid,
  input  logic                       main_s2mm_axis_tready,
  output logic                       main_s2mm_axis_tlast,

  output logic                       layer_complete_valid,
  input  logic                       layer_complete_ready,
  output logic [3:0]                 layer_complete_id,
  output logic                       inference_done,
  input  logic                       inference_done_ready,
  output logic                       fault,
  output logic [15:0]                completed_passes,
  output logic [63:0]                total_mac_count,
  output logic [31:0]                total_local_psum_hops,

  output logic [63:0]                filter_byte_requests,
  output logic [63:0]                filter_cache_hits,
  output logic [63:0]                filter_cache_misses,
  output logic [63:0]                filter_dma_line_fetches,
  output logic [63:0]                ifmap_byte_requests,
  output logic [63:0]                ifmap_cache_hits,
  output logic [63:0]                ifmap_cache_misses,
  output logic [63:0]                ifmap_dma_line_fetches,
  output logic [63:0]                partial_result_inputs,
  output logic [63:0]                accumulator_uram_reads,
  output logic [63:0]                accumulator_uram_writes,
  output logic [63:0]                final_result_outputs,
  output logic [63:0]                weight_dma_line_commands,
  output logic [63:0]                weight_dma_line_errors,
  output logic [63:0]                main_dma_line_commands,
  output logic [63:0]                main_dma_line_errors,
  output logic [31:0]                parameter_blob_loads,
  output logic [63:0]                parameter_lookups,
  output logic [63:0]                requantized_vectors,
  output logic [63:0]                stored_result_vectors,
  output logic [63:0]                stored_image_tiles,
  output logic [63:0]                result_s2mm_commands,
  output logic [63:0]                result_s2mm_bytes,
  output logic [9:0]                 pool_completed_tiles,
  output logic [31:0]                pool_raw_words_read,
  output logic [31:0]                pool_pooled_words_written,
  output logic [31:0]                pool_mm2s_commands,
  output logic [31:0]                pool_s2mm_commands,
  output logic                       pool_active
);
  logic post_start_valid, post_start_ready;
  logic post_result_valid, post_result_ready;
  logic [13:0] post_result_col_valid;
  logic signed [7:0] post_result_values [0:13];
  logic [TAG_W-1:0] post_result_tag;
  logic [3:0] post_result_layer;
  logic [12:0] post_result_filter;
  logic [2:0] post_result_image;
  logic [5:0] post_result_x, post_result_y_base;
  logic post_layer_complete_valid, post_layer_complete_ready;
  logic [3:0] post_layer_complete_id;
  logic post_inference_done, post_inference_done_ready;
  logic post_fault, store_fault, store_idle;
  logic [63:0] activation_a_base_q, activation_b_base_q;
  logic [63:0] final_output_base_q;
  logic [TAG_W-1:0] start_tag_q;

  logic compute_mm2s_command_valid, compute_mm2s_command_ready;
  logic [31:0] compute_mm2s_command_address;
  logic [25:0] compute_mm2s_command_length;
  logic compute_mm2s_armed, compute_mm2s_done, compute_mm2s_error;
  logic compute_mm2s_axis_tvalid, compute_mm2s_axis_tready;

  logic store_s2mm_command_valid, store_s2mm_command_ready;
  logic [31:0] store_s2mm_command_address;
  logic [25:0] store_s2mm_command_length;
  logic store_s2mm_armed, store_s2mm_done, store_s2mm_error;
  logic [127:0] store_s2mm_axis_tdata;
  logic [15:0] store_s2mm_axis_tkeep;
  logic store_s2mm_axis_tvalid, store_s2mm_axis_tready;
  logic store_s2mm_axis_tlast;

  logic pool_required, pool_started_q, pool_done_q;
  logic pool_layer_valid, pool_layer_ready, pool_layer_done;
  logic pool_layer_error, pool_busy;
  logic [31:0] pool_buffer_base;
  logic pool_dma_command_valid, pool_dma_command_ready;
  logic pool_dma_command_s2mm, pool_dma_active_s2mm_q;
  logic [31:0] pool_dma_command_address;
  logic [25:0] pool_dma_command_length;
  logic pool_dma_armed, pool_dma_done, pool_dma_error;
  logic [127:0] pool_s2mm_axis_tdata;
  logic [15:0] pool_s2mm_axis_tkeep;
  logic pool_s2mm_axis_tvalid, pool_s2mm_axis_tready;
  logic pool_s2mm_axis_tlast;
  logic pool_mm2s_axis_tready;
  logic [9:0] pool_layer_completed_tiles;
  logic [31:0] pool_layer_raw_words, pool_layer_pooled_words;
  logic [31:0] pool_layer_mm2s_commands, pool_layer_s2mm_commands;

  assign post_start_valid = start_valid && store_idle && !pool_started_q &&
                            !fault;
  assign start_ready = post_start_ready && store_idle && !pool_started_q &&
                       !fault;
  assign pool_active = pool_started_q;

  alexnet_eyeriss_rs_batch8_board_postprocess_top #(.TAG_W(TAG_W))
      u_postprocess (
    .clk, .rst, .start_valid(post_start_valid),
    .start_ready(post_start_ready), .start_tag,
    .input_base, .activation_a_base, .activation_b_base, .weights_base,
    .parameters_base,
    .weight_dma_command_valid, .weight_dma_command_ready,
    .weight_dma_command_address, .weight_dma_command_length,
    .weight_dma_armed, .weight_dma_done, .weight_dma_error,
    .weight_axis_tdata, .weight_axis_tkeep, .weight_axis_tvalid,
    .weight_axis_tready, .weight_axis_tlast,
    .main_dma_command_valid(compute_mm2s_command_valid),
    .main_dma_command_ready(compute_mm2s_command_ready),
    .main_dma_command_address(compute_mm2s_command_address),
    .main_dma_command_length(compute_mm2s_command_length),
    .main_dma_armed(compute_mm2s_armed),
    .main_dma_done(compute_mm2s_done),
    .main_dma_error(compute_mm2s_error),
    .main_axis_tdata(main_mm2s_axis_tdata),
    .main_axis_tkeep(main_mm2s_axis_tkeep),
    .main_axis_tvalid(compute_mm2s_axis_tvalid),
    .main_axis_tready(compute_mm2s_axis_tready),
    .main_axis_tlast(main_mm2s_axis_tlast),
    .result_valid(post_result_valid), .result_ready(post_result_ready),
    .result_col_valid(post_result_col_valid),
    .result_values(post_result_values), .result_tag(post_result_tag),
    .result_layer(post_result_layer), .result_filter(post_result_filter),
    .result_image(post_result_image), .result_x(post_result_x),
    .result_y_base(post_result_y_base),
    .layer_complete_valid(post_layer_complete_valid),
    .layer_complete_ready(post_layer_complete_ready),
    .layer_complete_id(post_layer_complete_id),
    .inference_done(post_inference_done),
    .inference_done_ready(post_inference_done_ready),
    .fault(post_fault), .completed_passes, .total_mac_count,
    .total_local_psum_hops, .filter_byte_requests, .filter_cache_hits,
    .filter_cache_misses, .filter_dma_line_fetches, .ifmap_byte_requests,
    .ifmap_cache_hits, .ifmap_cache_misses, .ifmap_dma_line_fetches,
    .partial_result_inputs, .accumulator_uram_reads,
    .accumulator_uram_writes, .final_result_outputs,
    .weight_dma_line_commands, .weight_dma_line_errors,
    .main_dma_line_commands, .main_dma_line_errors,
    .parameter_blob_loads, .parameter_lookups, .requantized_vectors
  );

  alexnet_eyeriss_rs_n8_result_store #(.TAG_W(TAG_W)) u_result_store (
    .clk, .rst, .activation_a_base(activation_a_base_q),
    .activation_b_base(activation_b_base_q),
    .final_output_base(final_output_base_q),
    .input_valid(post_result_valid), .input_ready(post_result_ready),
    .input_col_valid(post_result_col_valid),
    .input_values(post_result_values), .input_tag(post_result_tag),
    .input_layer(post_result_layer), .input_filter(post_result_filter),
    .input_image(post_result_image), .input_x(post_result_x),
    .input_y_base(post_result_y_base),
    .dma_command_valid(store_s2mm_command_valid),
    .dma_command_ready(store_s2mm_command_ready),
    .dma_command_address(store_s2mm_command_address),
    .dma_command_length(store_s2mm_command_length),
    .dma_armed(store_s2mm_armed), .dma_done(store_s2mm_done),
    .dma_error(store_s2mm_error), .m_axis_tdata(store_s2mm_axis_tdata),
    .m_axis_tkeep(store_s2mm_axis_tkeep),
    .m_axis_tvalid(store_s2mm_axis_tvalid),
    .m_axis_tready(store_s2mm_axis_tready),
    .m_axis_tlast(store_s2mm_axis_tlast), .idle(store_idle),
    .fault(store_fault), .accepted_vectors(stored_result_vectors),
    .completed_image_tiles(stored_image_tiles),
    .s2mm_commands(result_s2mm_commands),
    .emitted_bytes(result_s2mm_bytes)
  );

  assign pool_required = post_layer_complete_id == 1 ||
                         post_layer_complete_id == 2 ||
                         post_layer_complete_id == 5;
  assign pool_buffer_base = post_layer_complete_id == 2 ?
                            activation_b_base_q[31:0] :
                            activation_a_base_q[31:0];
  assign pool_layer_valid = post_layer_complete_valid && store_idle &&
                            pool_required && !pool_started_q;

  alexnet_eyeriss_rs_batch8_inplace_pool_service #(.TAG_W(TAG_W))
      u_batch8_inplace_pool (
    .clk, .rst, .layer_valid(pool_layer_valid),
    .layer_ready(pool_layer_ready), .layer_id(post_layer_complete_id),
    .layer_tag(start_tag_q), .layer_buffer_base(pool_buffer_base),
    .dma_command_valid(pool_dma_command_valid),
    .dma_command_ready(pool_dma_command_ready),
    .dma_command_s2mm(pool_dma_command_s2mm),
    .dma_command_address(pool_dma_command_address),
    .dma_command_length(pool_dma_command_length),
    .dma_armed(pool_dma_armed), .dma_done(pool_dma_done),
    .dma_error(pool_dma_error), .s_axis_tdata(main_mm2s_axis_tdata),
    .s_axis_tkeep(main_mm2s_axis_tkeep),
    .s_axis_tvalid(main_mm2s_axis_tvalid && pool_started_q),
    .s_axis_tready(pool_mm2s_axis_tready),
    .s_axis_tlast(main_mm2s_axis_tlast),
    .m_axis_tdata(pool_s2mm_axis_tdata),
    .m_axis_tkeep(pool_s2mm_axis_tkeep),
    .m_axis_tvalid(pool_s2mm_axis_tvalid),
    .m_axis_tready(pool_s2mm_axis_tready),
    .m_axis_tlast(pool_s2mm_axis_tlast), .layer_done(pool_layer_done),
    .layer_error(pool_layer_error), .busy(pool_busy),
    .completed_tiles(pool_layer_completed_tiles),
    .raw_words_read(pool_layer_raw_words),
    .pooled_words_written(pool_layer_pooled_words),
    .mm2s_commands(pool_layer_mm2s_commands),
    .s2mm_commands(pool_layer_s2mm_commands)
  );

  assign main_mm2s_command_valid = pool_started_q ?
      (pool_dma_command_valid && !pool_dma_command_s2mm) :
      compute_mm2s_command_valid;
  assign main_mm2s_command_address = pool_started_q ?
      pool_dma_command_address : compute_mm2s_command_address;
  assign main_mm2s_command_length = pool_started_q ?
      pool_dma_command_length : compute_mm2s_command_length;
  assign compute_mm2s_command_ready = !pool_started_q &&
                                       main_mm2s_command_ready;
  assign compute_mm2s_armed = !pool_started_q && main_mm2s_armed;
  assign compute_mm2s_done = !pool_started_q && main_mm2s_done;
  assign compute_mm2s_error = !pool_started_q && main_mm2s_error;
  assign compute_mm2s_axis_tvalid = !pool_started_q &&
                                    main_mm2s_axis_tvalid;
  assign main_mm2s_axis_tready = pool_started_q ?
      pool_mm2s_axis_tready : compute_mm2s_axis_tready;

  assign main_s2mm_command_valid = pool_started_q ?
      (pool_dma_command_valid && pool_dma_command_s2mm) :
      store_s2mm_command_valid;
  assign main_s2mm_command_address = pool_started_q ?
      pool_dma_command_address : store_s2mm_command_address;
  assign main_s2mm_command_length = pool_started_q ?
      pool_dma_command_length : store_s2mm_command_length;
  assign store_s2mm_command_ready = !pool_started_q &&
                                     main_s2mm_command_ready;
  assign store_s2mm_armed = !pool_started_q && main_s2mm_armed;
  assign store_s2mm_done = !pool_started_q && main_s2mm_done;
  assign store_s2mm_error = !pool_started_q && main_s2mm_error;
  assign main_s2mm_axis_tdata = pool_started_q ? pool_s2mm_axis_tdata :
                                                store_s2mm_axis_tdata;
  assign main_s2mm_axis_tkeep = pool_started_q ? pool_s2mm_axis_tkeep :
                                                store_s2mm_axis_tkeep;
  assign main_s2mm_axis_tvalid = pool_started_q ? pool_s2mm_axis_tvalid :
                                                 store_s2mm_axis_tvalid;
  assign main_s2mm_axis_tlast = pool_started_q ? pool_s2mm_axis_tlast :
                                                store_s2mm_axis_tlast;
  assign pool_s2mm_axis_tready = pool_started_q &&
                                  main_s2mm_axis_tready;
  assign store_s2mm_axis_tready = !pool_started_q &&
                                   main_s2mm_axis_tready;

  assign pool_dma_command_ready = pool_started_q &&
      (pool_dma_command_s2mm ? main_s2mm_command_ready :
                               main_mm2s_command_ready);
  assign pool_dma_armed = pool_started_q &&
      (pool_dma_active_s2mm_q ? main_s2mm_armed : main_mm2s_armed);
  assign pool_dma_done = pool_started_q &&
      (pool_dma_active_s2mm_q ? main_s2mm_done : main_mm2s_done);
  assign pool_dma_error = pool_started_q &&
      (pool_dma_active_s2mm_q ? main_s2mm_error : main_mm2s_error);

  assign layer_complete_valid = post_layer_complete_valid && store_idle &&
      (!pool_required || pool_done_q);
  assign layer_complete_id = post_layer_complete_id;
  assign post_layer_complete_ready = layer_complete_ready && store_idle &&
      (!pool_required || pool_done_q);
  assign inference_done = post_inference_done && store_idle &&
                          !pool_started_q;
  assign post_inference_done_ready = inference_done_ready && store_idle &&
                                     !pool_started_q;
  assign fault = post_fault || store_fault || pool_layer_error;

  always_ff @(posedge clk) begin
    if (rst) begin
      activation_a_base_q <= '0;
      activation_b_base_q <= '0;
      final_output_base_q <= '0;
      start_tag_q <= '0;
      pool_started_q <= 1'b0;
      pool_done_q <= 1'b0;
      pool_dma_active_s2mm_q <= 1'b0;
      pool_completed_tiles <= 0;
      pool_raw_words_read <= 0;
      pool_pooled_words_written <= 0;
      pool_mm2s_commands <= 0;
      pool_s2mm_commands <= 0;
    end else if (start_valid && start_ready) begin
      activation_a_base_q <= activation_a_base;
      activation_b_base_q <= activation_b_base;
      final_output_base_q <= final_output_base;
      start_tag_q <= start_tag;
      pool_started_q <= 1'b0;
      pool_done_q <= 1'b0;
      pool_completed_tiles <= 0;
      pool_raw_words_read <= 0;
      pool_pooled_words_written <= 0;
      pool_mm2s_commands <= 0;
      pool_s2mm_commands <= 0;
    end else begin
      if (pool_layer_valid && pool_layer_ready)
        pool_started_q <= 1'b1;

      if (pool_dma_command_valid && pool_dma_command_ready)
        pool_dma_active_s2mm_q <= pool_dma_command_s2mm;

      if (pool_layer_done) begin
        pool_done_q <= 1'b1;
        pool_completed_tiles <= pool_completed_tiles +
                                pool_layer_completed_tiles;
        pool_raw_words_read <= pool_raw_words_read + pool_layer_raw_words;
        pool_pooled_words_written <= pool_pooled_words_written +
                                     pool_layer_pooled_words;
        pool_mm2s_commands <= pool_mm2s_commands +
                              pool_layer_mm2s_commands;
        pool_s2mm_commands <= pool_s2mm_commands +
                              pool_layer_s2mm_commands;
      end

      if (post_layer_complete_valid && post_layer_complete_ready) begin
        pool_started_q <= 1'b0;
        pool_done_q <= 1'b0;
      end
    end
  end

endmodule
