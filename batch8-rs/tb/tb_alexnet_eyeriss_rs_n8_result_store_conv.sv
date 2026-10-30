`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_n8_result_store_conv;
  localparam logic [63:0] A_BASE = 64'h0000_0000_3000_0000;

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
  int active_group;

  alexnet_eyeriss_rs_n8_result_store dut (.*);

  function automatic logic [7:0] conv_byte(
      input int filter, input int y, input int x);
    conv_byte = (filter * 3 + y * 5 + x) & 255;
  endfunction

  task automatic send_conv1_vector(input int filter, input int x);
    begin
      @(negedge clk);
      while (!input_ready) @(negedge clk);
      input_valid = 1;
      input_layer = 1;
      input_image = 0;
      input_filter = filter;
      input_x = x;
      input_y_base = 0;
      input_col_valid = 14'h007f;
      for (int lane = 0; lane < 14; lane++)
        input_values[lane] = lane < 7 ? conv_byte(filter, lane, x) : 0;
      @(negedge clk);
      input_valid = 0;
    end
  endtask

  always_ff @(posedge clk) begin
    dma_armed <= 0;
    dma_done <= 0;
    if (!rst && dma_command_valid && dma_command_ready) begin
      if (command_index >= 8 ||
          dma_command_address != A_BASE[31:0] +
              command_index * 3025 * 8 ||
          dma_command_length != 3080)
        $fatal(1, "Conv1 command mismatch index=%0d addr=%h len=%0d",
               command_index, dma_command_address, dma_command_length);
      active_group <= command_index;
      command_index <= command_index + 1;
      stream_byte_index <= 0;
      dma_armed <= 1;
    end

    if (!rst && m_axis_tvalid && m_axis_tready) begin
      for (int byte_lane = 0; byte_lane < 16; byte_lane++) begin
        int byte_number;
        int spatial;
        int bank;
        int y;
        int x;
        byte_number = stream_byte_index + byte_lane;
        spatial = byte_number / 8;
        bank = byte_number % 8;
        y = spatial / 55;
        x = spatial % 55;
        if (m_axis_tkeep[byte_lane] &&
            m_axis_tdata[byte_lane*8 +: 8] !==
                conv_byte(active_group * 8 + bank, y, x))
          $fatal(1, "Conv1 payload mismatch group=%0d byte=%0d got=%h expected=%h",
                 active_group, byte_number,
                 m_axis_tdata[byte_lane*8 +: 8],
                 conv_byte(active_group * 8 + bank, y, x));
      end
      stream_byte_index <= stream_byte_index + $countones(m_axis_tkeep);
      if (m_axis_tlast) begin
        if (stream_byte_index + $countones(m_axis_tkeep) != 3080 ||
            m_axis_tkeep != 16'h00ff)
          $fatal(1, "Conv1 group tail mismatch bytes=%0d keep=%h",
                 stream_byte_index + $countones(m_axis_tkeep), m_axis_tkeep);
        dma_done <= 1;
      end
    end
  end

  initial begin
    activation_a_base = A_BASE;
    activation_b_base = 64'h4000_0000;
    final_output_base = 64'h5000_0000;
    input_valid = 0;
    input_col_valid = 0;
    input_tag = 16'h1234;
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
    active_group = 0;
    for (int lane = 0; lane < 14; lane++) input_values[lane] = 0;

    repeat (5) @(posedge clk);
    rst = 0;

    // Match the RS stream shape: x is outer, one vertical vector per filter.
    for (int x = 0; x < 55; x++)
      for (int filter = 0; filter < 64; filter++)
        send_conv1_vector(filter, x);

    wait (completed_image_tiles == 1);
    repeat (5) @(posedge clk);
    if (fault || command_index != 8 || accepted_vectors != 3520 ||
        s2mm_commands != 8 || emitted_bytes != 24640)
      $fatal(1, "Conv1 store counters mismatch fault=%0d commands=%0d vectors=%0d bytes=%0d",
             fault, command_index, accepted_vectors, emitted_bytes);

    $display("ALEXNET_EYERISS_RS_N8_RESULT_STORE_CONV_TEST_PASSED vectors=%0d commands=%0d bytes=%0d layout=N8_y_x_lane",
             accepted_vectors, s2mm_commands, emitted_bytes);
    $finish;
  end

  initial begin
    #3000000;
    $fatal(1, "Conv1 result-store timeout");
  end
endmodule
