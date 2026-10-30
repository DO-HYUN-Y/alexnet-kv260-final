`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_n8_result_store;
  localparam logic [63:0] FINAL_BASE = 64'h0000_0000_5000_0000;
  localparam logic [63:0] IMAGE_STRIDE = 64'd262144;

  logic clk = 0;
  logic rst = 1;
  always #2.5 clk = ~clk;

  logic [63:0] activation_a_base, activation_b_base, final_output_base;
  logic input_valid, input_ready;
  logic [13:0] input_col_valid;
  logic signed [7:0] input_values [0:13];
  logic [15:0] input_tag;
  logic [3:0] input_layer;
  logic [12:0] input_filter;
  logic [2:0] input_image;
  logic [5:0] input_x, input_y_base;
  logic dma_command_valid, dma_command_ready;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic idle, fault;
  logic [63:0] accepted_vectors, completed_image_tiles;
  logic [63:0] s2mm_commands, emitted_bytes;

  int command_index;
  int stream_byte_index;
  int expected_stream_bytes;
  int active_image;
  int active_filter_base;

  alexnet_eyeriss_rs_n8_result_store dut (.*);

  function automatic logic [7:0] result_byte(
      input int image, input int filter);
    result_byte = (image * 17 + filter) & 8'hff;
  endfunction

  task automatic send_fc_vector(input int image, input int filter);
    begin
      @(negedge clk);
      while (!input_ready) @(negedge clk);
      input_valid = 1;
      input_layer = 8;
      input_image = image;
      input_filter = filter;
      input_x = 0;
      input_y_base = 0;
      input_col_valid = 14'b1;
      input_values[0] = result_byte(image, filter);
      @(negedge clk);
      input_valid = 0;
    end
  endtask

  always_ff @(posedge clk) begin
    dma_armed <= 0;
    dma_done <= 0;
    if (!rst && dma_command_valid && dma_command_ready) begin
      if (command_index < 8) begin
        if (dma_command_address !=
                FINAL_BASE[31:0] + command_index * IMAGE_STRIDE ||
            dma_command_length != 752)
          $fatal(1, "first FC tile command mismatch index=%0d addr=%h len=%0d",
                 command_index, dma_command_address, dma_command_length);
        active_image <= command_index;
        active_filter_base <= 0;
        expected_stream_bytes <= 752;
      end else if (command_index == 8) begin
        if (dma_command_address != FINAL_BASE[31:0] + 752 ||
            dma_command_length != 248)
          $fatal(1, "merged FC tile command mismatch addr=%h len=%0d",
                 dma_command_address, dma_command_length);
        active_image <= 0;
        active_filter_base <= 752;
        expected_stream_bytes <= 248;
      end else begin
        $fatal(1, "unexpected command index=%0d", command_index);
      end
      stream_byte_index <= 0;
      command_index <= command_index + 1;
      dma_armed <= 1;
    end

    if (!rst && m_axis_tvalid && m_axis_tready) begin
      for (int byte_lane = 0; byte_lane < 16; byte_lane++) begin
        if (m_axis_tkeep[byte_lane]) begin
          if (m_axis_tdata[byte_lane*8 +: 8] !==
              result_byte(active_image,
                          active_filter_base + stream_byte_index + byte_lane))
            $fatal(1, "FC payload mismatch cmd=%0d byte=%0d got=%h expected=%h",
                   command_index - 1, stream_byte_index + byte_lane,
                   m_axis_tdata[byte_lane*8 +: 8],
                   result_byte(active_image,
                               active_filter_base + stream_byte_index +
                               byte_lane));
        end
      end
      if (m_axis_tlast) begin
        if (stream_byte_index + $countones(m_axis_tkeep) !=
            expected_stream_bytes)
          $fatal(1, "FC payload length mismatch got=%0d expected=%0d",
                 stream_byte_index + $countones(m_axis_tkeep),
                 expected_stream_bytes);
        dma_done <= 1;
      end
      stream_byte_index <= stream_byte_index + $countones(m_axis_tkeep);
    end
  end

  initial begin
    activation_a_base = 64'h3000_0000;
    activation_b_base = 64'h4000_0000;
    final_output_base = FINAL_BASE;
    input_valid = 0;
    input_col_valid = 0;
    input_tag = 16'hbeef;
    input_layer = 0;
    input_filter = 0;
    input_image = 0;
    input_x = 0;
    input_y_base = 0;
    dma_command_ready = 1;
    dma_armed = 0;
    dma_done = 0;
    dma_error = 0;
    m_axis_tready = 1;
    command_index = 0;
    stream_byte_index = 0;
    expected_stream_bytes = 0;
    active_image = 0;
    active_filter_base = 0;
    for (int lane = 0; lane < 14; lane++) input_values[lane] = 0;

    repeat (5) @(posedge clk);
    rst = 0;

    // Tile 0 ends at filter 755 and leaves filters 752..755 in the carry.
    for (int image = 0; image < 8; image++)
      for (int filter = 0; filter < 756; filter++)
        send_fc_vector(image, filter);

    // Tile 1 begins at filter 756.  The first S2MM word must merge the prior
    // four carry bytes with filters 756..759, then continue through filter999.
    for (int filter = 756; filter < 1000; filter++)
      send_fc_vector(0, filter);

    wait (completed_image_tiles == 9);
    repeat (5) @(posedge clk);
    if (fault || command_index != 9 || accepted_vectors != 6292 ||
        s2mm_commands != 9 || emitted_bytes != 6264)
      $fatal(1, "result-store counters/fault mismatch fault=%0d cmd=%0d accepted=%0d tiles=%0d emitted=%0d",
             fault, command_index, accepted_vectors,
             completed_image_tiles, emitted_bytes);

    $display("ALEXNET_EYERISS_RS_N8_RESULT_STORE_TEST_PASSED vectors=%0d commands=%0d bytes=%0d carry_merge=4",
             accepted_vectors, s2mm_commands, emitted_bytes);
    $finish;
  end

  initial begin
    #3000000;
    $fatal(1, "result-store timeout");
  end
endmodule
