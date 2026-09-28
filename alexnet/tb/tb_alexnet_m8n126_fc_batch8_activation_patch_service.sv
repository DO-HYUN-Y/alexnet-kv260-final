`timescale 1ns/1ps

module tb_alexnet_m8n126_fc_batch8_activation_patch_service;
  localparam logic [31:0] POOL5_BASE = 32'h1000_0000;
  localparam logic [31:0] BATCH_A_BASE = 32'h2000_0000;
  localparam logic [31:0] BATCH_B_BASE = 32'h3000_0000;
  localparam logic [31:0] IMAGE_STRIDE = 32'd262144;

  logic clk = 1'b0;
  logic rst;
  always #2.5 clk = ~clk;

  logic request_valid, request_ready;
  logic [3:0] request_layer_id;
  logic [12:0] request_m_base;
  logic [13:0] request_k_offset;
  logic [12:0] request_k_count;
  logic [15:0] request_m_lane_mask, request_context_tag;
  logic dma_command_valid, dma_command_ready;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [127:0] patch_axis_tdata;
  logic patch_axis_tvalid, patch_axis_tready, patch_axis_tlast;
  logic busy, fault, cache_load_active;
  logic [3:0] cached_layer_id;
  logic [31:0] cache_load_commands, completed_patches;
  logic [31:0] emitted_patch_words;

  logic dma_stream_active_q;
  logic [31:0] dma_address_q;
  logic [25:0] dma_length_q;
  logic [15:0] dma_beat_q;
  integer observed_commands;
  integer observed_words;
  integer checked_start_k;
  integer checked_layer;

  function automatic logic [7:0] memory_byte(input logic [31:0] address);
    integer image;
    integer offset;
    begin
      memory_byte = 0;
      if (address >= POOL5_BASE &&
          address < POOL5_BASE + 8 * IMAGE_STRIDE) begin
        image = (address - POOL5_BASE) / IMAGE_STRIDE;
        offset = (address - POOL5_BASE) % IMAGE_STRIDE;
        memory_byte = (image * 29 + offset) & 8'hff;
      end else if (address >= BATCH_B_BASE &&
                   address < BATCH_B_BASE + 32768) begin
        offset = address - BATCH_B_BASE;
        memory_byte = (offset * 3 + 7) & 8'hff;
      end else if (address >= BATCH_A_BASE &&
                   address < BATCH_A_BASE + 32768) begin
        offset = address - BATCH_A_BASE;
        memory_byte = (offset * 5 + 11) & 8'hff;
      end
    end
  endfunction

  always_comb begin
    s_axis_tdata = 0;
    for (int byte_index = 0; byte_index < 16; byte_index++)
      s_axis_tdata[byte_index*8 +: 8] =
          memory_byte(dma_address_q + dma_beat_q * 16 + byte_index);
    s_axis_tkeep = 16'hffff;
    s_axis_tvalid = dma_stream_active_q;
    s_axis_tlast = dma_stream_active_q &&
        (dma_beat_q + 1) * 16 == dma_length_q;
  end

  always @(posedge clk) begin
    dma_armed <= 1'b0;
    dma_done <= 1'b0;
    if (rst) begin
      dma_stream_active_q <= 1'b0;
      dma_address_q <= 0;
      dma_length_q <= 0;
      dma_beat_q <= 0;
      observed_commands <= 0;
    end else begin
      if (dma_command_valid && dma_command_ready) begin
        if (dma_stream_active_q)
          $fatal(1, "overlapping DMA command");
        dma_address_q <= dma_command_address;
        dma_length_q <= dma_command_length;
        dma_beat_q <= 0;
        dma_stream_active_q <= 1'b1;
        dma_armed <= 1'b1;
        observed_commands <= observed_commands + 1;
      end
      if (s_axis_tvalid && s_axis_tready) begin
        if (s_axis_tlast) begin
          dma_stream_active_q <= 1'b0;
          dma_done <= 1'b1;
        end else begin
          dma_beat_q <= dma_beat_q + 1'b1;
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst && patch_axis_tvalid && patch_axis_tready) begin
      integer global_k;
      integer channel;
      integer spatial;
      integer byte_offset;
      logic [7:0] expected;
      global_k = checked_start_k + observed_words;
      for (int image = 0; image < 8; image++) begin
        if (checked_layer == 6) begin
          channel = global_k / 36;
          spatial = global_k % 36;
          byte_offset = (((channel / 8) * 36 + spatial) * 8) +
                        (channel % 8);
          expected = (image * 29 + byte_offset) & 8'hff;
        end else if (checked_layer == 7) begin
          byte_offset = (global_k / 8) * 64 + image * 8 +
                        (global_k % 8);
          expected = (byte_offset * 3 + 7) & 8'hff;
        end else begin
          byte_offset = (global_k / 8) * 64 + image * 8 +
                        (global_k % 8);
          expected = (byte_offset * 5 + 11) & 8'hff;
        end
        if (patch_axis_tdata[image*8 +: 8] !== expected)
          $fatal(1, "layer %0d K %0d image %0d got %02x expected %02x",
                 checked_layer, global_k, image,
                 patch_axis_tdata[image*8 +: 8], expected);
      end
      if (patch_axis_tdata[127:64] !== 0)
        $fatal(1, "inactive batch lanes were not zero");
      observed_words <= observed_words + 1;
    end
  end

  task automatic send_request(
      input logic [3:0] layer_id,
      input logic [13:0] k_offset,
      input logic [12:0] k_count);
    integer commands_before;
    integer patches_before;
    begin
      while (!request_ready) @(posedge clk);
      commands_before = observed_commands;
      patches_before = completed_patches;
      checked_layer = layer_id;
      checked_start_k = k_offset;
      observed_words = 0;
      request_layer_id = layer_id;
      request_m_base = 0;
      request_k_offset = k_offset;
      request_k_count = k_count;
      request_m_lane_mask = 16'h00ff;
      request_context_tag = 16'hb800 | layer_id;
      request_valid = 1'b1;
      @(posedge clk);
      request_valid = 1'b0;
      while (completed_patches == patches_before)
        @(posedge clk);
      if (observed_words != k_count)
        $fatal(1, "layer %0d emitted %0d words expected %0d",
               layer_id, observed_words, k_count);
      if (fault)
        $fatal(1, "service faulted");
      if (layer_id == 6 && k_offset == 8192 &&
          observed_commands - commands_before != 8)
        $fatal(1, "FC6 initial cache load did not issue eight commands");
      if (layer_id == 6 && k_offset == 0 &&
          observed_commands != commands_before)
        $fatal(1, "FC6 cache was not reused");
      if (layer_id >= 7 && observed_commands - commands_before != 1)
        $fatal(1, "FC7/8 cache load command count mismatch");
    end
  endtask

  alexnet_m8n126_fc_batch8_activation_patch_service dut (
      .clk, .rst, .request_valid, .request_ready, .request_layer_id,
      .request_m_base, .request_k_offset, .request_k_count,
      .request_m_lane_mask, .request_context_tag,
      .pool5_image0_base(POOL5_BASE),
      .batch_activation_a_base(BATCH_A_BASE),
      .batch_activation_b_base(BATCH_B_BASE),
      .dma_command_valid, .dma_command_ready, .dma_command_address,
      .dma_command_length, .dma_armed, .dma_done, .dma_error,
      .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready,
      .s_axis_tlast, .patch_axis_tdata, .patch_axis_tvalid,
      .patch_axis_tready, .patch_axis_tlast, .busy, .fault,
      .cache_load_active, .cached_layer_id, .cache_load_commands,
      .completed_patches, .emitted_patch_words
  );

  initial begin
    rst = 1'b1;
    request_valid = 1'b0;
    request_layer_id = 0;
    request_m_base = 0;
    request_k_offset = 0;
    request_k_count = 0;
    request_m_lane_mask = 0;
    request_context_tag = 0;
    dma_command_ready = 1'b1;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    patch_axis_tready = 1'b1;
    observed_words = 0;
    checked_start_k = 0;
    checked_layer = 0;
    repeat (5) @(posedge clk);
    rst = 1'b0;

    send_request(4'd6, 14'd8192, 13'd1024);
    send_request(4'd6, 14'd0, 13'd4096);
    send_request(4'd7, 14'd0, 13'd4096);
    send_request(4'd8, 14'd0, 13'd4096);

    if (cache_load_commands != 10)
      $fatal(1, "expected ten total cache commands, got %0d",
             cache_load_commands);
    if (emitted_patch_words != 13312)
      $fatal(1, "patch word counter mismatch");
    $display("ALEXNET_M8N126_FC_BATCH8_ACTIVATION_PATCH_SERVICE_SIM_PASS");
    $finish;
  end

  initial begin
    #5ms;
    $fatal(1, "timeout");
  end
endmodule
