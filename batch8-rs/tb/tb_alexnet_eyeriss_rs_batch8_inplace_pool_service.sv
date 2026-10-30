`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_batch8_inplace_pool_service;
  localparam logic [31:0] BASE = 32'h2800_0000;
  localparam int IMAGE_STRIDE = 262144;

  logic clk = 1'b0;
  logic rst;
  logic layer_valid, layer_ready;
  logic [3:0] layer_id;
  logic [15:0] layer_tag;
  logic [31:0] layer_buffer_base;
  logic dma_command_valid, dma_command_ready, dma_command_s2mm;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic layer_done, layer_error, busy;
  logic [9:0] completed_tiles;
  logic [31:0] raw_words_read, pooled_words_written;
  logic [31:0] mm2s_commands, s2mm_commands;

  bit layer_done_seen;
  int total_tiles_checked;
  int total_output_words_checked;

  alexnet_eyeriss_rs_batch8_inplace_pool_service dut (.*);

  always #2.5 clk = ~clk;
  always @(posedge clk)
    if (layer_done)
      layer_done_seen <= 1'b1;

  function automatic int raw_width(input int layer);
    case (layer)
      1: raw_width = 55;
      2: raw_width = 27;
      5: raw_width = 13;
      default: raw_width = 0;
    endcase
  endfunction

  function automatic int raw_words(input int layer);
    case (layer)
      1: raw_words = 3025;
      2: raw_words = 729;
      5: raw_words = 169;
      default: raw_words = 0;
    endcase
  endfunction

  function automatic int stored_width(input int layer);
    case (layer)
      1: stored_width = 27;
      2: stored_width = 13;
      5: stored_width = 6;
      default: stored_width = 0;
    endcase
  endfunction

  function automatic int stored_words(input int layer);
    case (layer)
      1: stored_words = 729;
      2: stored_words = 169;
      5: stored_words = 36;
      default: stored_words = 0;
    endcase
  endfunction

  function automatic int tiles(input int layer);
    case (layer)
      1: tiles = 8;
      2: tiles = 24;
      5: tiles = 32;
      default: tiles = 0;
    endcase
  endfunction

  function automatic integer signed raw_value(
      input int layer, input int image, input int tile,
      input int y, input int x, input int lane);
    raw_value = ((layer * 11 + image * 19 + tile * 17 +
                  y * 5 + x * 3 + lane * 7) % 201) - 100;
  endfunction

  function automatic logic [63:0] raw_word(
      input int layer, input int image, input int tile,
      input int word_index);
    int y;
    int x;
    integer signed value;
    logic [63:0] result;
    begin
      y = word_index / raw_width(layer);
      x = word_index % raw_width(layer);
      result = 0;
      for (int lane = 0; lane < 8; lane++) begin
        value = raw_value(layer, image, tile, y, x, lane);
        result[lane*8 +: 8] = value[7:0];
      end
      raw_word = result;
    end
  endfunction

  function automatic integer signed pooled_value(
      input int layer, input int image, input int tile,
      input int output_index, input int lane);
    int output_y;
    int output_x;
    integer signed best;
    integer signed candidate;
    begin
      output_y = output_index / stored_width(layer);
      output_x = output_index % stored_width(layer);
      best = -128;
      for (int ky = 0; ky < 3; ky++) begin
        for (int kx = 0; kx < 3; kx++) begin
          candidate = raw_value(layer, image, tile,
                                2*output_y + ky, 2*output_x + kx, lane);
          if (candidate > best)
            best = candidate;
        end
      end
      pooled_value = best;
    end
  endfunction

  task automatic accept_command(
      input bit expected_s2mm,
      input logic [31:0] expected_address,
      input int expected_length);
    begin
      while (!dma_command_valid) @(negedge clk);
      if (dma_command_s2mm != expected_s2mm ||
          dma_command_address != expected_address ||
          dma_command_length != expected_length)
        $fatal(1,
               "pool DMA command mismatch dir=%0b/%0b addr=%h/%h len=%0d/%0d",
               dma_command_s2mm, expected_s2mm, dma_command_address,
               expected_address, dma_command_length, expected_length);
      dma_command_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_command_ready = 1'b0;
      dma_armed = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_armed = 1'b0;
    end
  endtask

  task automatic send_raw_tile(
      input int layer, input int image, input int tile);
    int words;
    int beats;
    logic [63:0] lo;
    logic [63:0] hi;
    begin
      words = raw_words(layer);
      beats = (words + 1) / 2;
      for (int beat = 0; beat < beats; beat++) begin
        lo = raw_word(layer, image, tile, 2*beat);
        hi = 2*beat + 1 < words ?
             raw_word(layer, image, tile, 2*beat+1) : 0;
        s_axis_tdata = {hi, lo};
        s_axis_tkeep = beat == beats-1 && words[0] ?
                       16'h00ff : 16'hffff;
        s_axis_tlast = beat == beats-1;
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        @(negedge clk);
      end
      s_axis_tvalid = 1'b0;
      s_axis_tlast = 1'b0;
      s_axis_tkeep = 0;
      dma_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_done = 1'b0;
    end
  endtask

  task automatic receive_pooled_tile(
      input int layer, input int image, input int tile);
    int word_index;
    int expected_words;
    int got;
    int expected;
    bit saw_last;
    begin
      word_index = 0;
      expected_words = stored_words(layer);
      saw_last = 1'b0;
      m_axis_tready = 1'b1;
      while (!saw_last) begin
        @(posedge clk);
        if (m_axis_tvalid && m_axis_tready) begin
          for (int half = 0; half < 2; half++) begin
            if (m_axis_tkeep[half*8 +: 8] == 8'hff) begin
              if (word_index >= expected_words)
                $fatal(1, "pool emitted too many words");
              for (int lane = 0; lane < 8; lane++) begin
                got = $signed(m_axis_tdata[half*64 + lane*8 +: 8]);
                expected = pooled_value(layer, image, tile,
                                        word_index, lane);
                if (got != expected)
                  $fatal(1,
                         "pool mismatch layer=%0d image=%0d tile=%0d word=%0d lane=%0d got=%0d expected=%0d",
                         layer, image, tile, word_index, lane, got, expected);
              end
              word_index++;
              total_output_words_checked++;
            end else if (m_axis_tkeep[half*8 +: 8] != 0) begin
              $fatal(1, "pool emitted partial N8 keep");
            end
          end
          saw_last = m_axis_tlast;
        end
      end
      @(negedge clk);
      m_axis_tready = 1'b0;
      if (word_index != expected_words)
        $fatal(1, "pool output word count mismatch got=%0d expected=%0d",
               word_index, expected_words);
      dma_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dma_done = 1'b0;
      total_tiles_checked++;
    end
  endtask

  task automatic run_layer(input int layer);
    int raw_bytes;
    int stored_bytes;
    int expected_tiles;
    begin
      raw_bytes = raw_words(layer) * 8;
      stored_bytes = stored_words(layer) * 8;
      expected_tiles = 8 * tiles(layer);
      while (!layer_ready) @(negedge clk);
      layer_done_seen = 1'b0;
      layer_id = layer;
      layer_tag = 16'h5000 + layer;
      layer_buffer_base = BASE;
      layer_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      layer_valid = 1'b0;

      for (int image = 0; image < 8; image++) begin
        for (int tile = 0; tile < tiles(layer); tile++) begin
          accept_command(1'b0,
              BASE + image*IMAGE_STRIDE + tile*raw_bytes, raw_bytes);
          send_raw_tile(layer, image, tile);
          accept_command(1'b1,
              BASE + image*IMAGE_STRIDE + tile*stored_bytes, stored_bytes);
          receive_pooled_tile(layer, image, tile);
        end
      end

      for (int timeout = 0; timeout < 20 && !layer_done_seen; timeout++)
        @(negedge clk);
      if (!layer_done_seen)
        $fatal(1, "pool layer completion timeout layer=%0d", layer);
      if (layer_error || completed_tiles != expected_tiles ||
          raw_words_read != expected_tiles * raw_words(layer) ||
          pooled_words_written != expected_tiles * stored_words(layer) ||
          mm2s_commands != expected_tiles ||
          s2mm_commands != expected_tiles)
        $fatal(1, "pool layer completion counters mismatch layer=%0d", layer);
    end
  endtask

  initial begin
    rst = 1'b1;
    layer_valid = 1'b0;
    layer_id = 0;
    layer_tag = 0;
    layer_buffer_base = BASE;
    dma_command_ready = 1'b0;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    m_axis_tready = 1'b0;
    layer_done_seen = 1'b0;
    total_tiles_checked = 0;
    total_output_words_checked = 0;

    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    run_layer(1);
    run_layer(2);
    run_layer(5);

    if (total_tiles_checked != 512 ||
        total_output_words_checked != 88320)
      $fatal(1, "batch8 pool aggregate mismatch tiles=%0d words=%0d",
             total_tiles_checked, total_output_words_checked);
    $display("ALEXNET_EYERISS_RS_BATCH8_INPLACE_POOL_TEST_PASSED tiles=%0d pooled_words=%0d images=8 layers=1,2,5",
             total_tiles_checked, total_output_words_checked);
    $finish;
  end
endmodule
