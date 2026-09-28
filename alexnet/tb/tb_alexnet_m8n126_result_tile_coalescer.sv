`timescale 1ns/1ps

module tb_alexnet_m8n126_result_tile_coalescer;
  logic clk = 1'b0;
  logic rst;
  logic result_valid, result_ready;
  logic [3:0] result_layer_id;
  logic [3:0] fc_batch_size;
  logic [31:0] result_base;
  logic [63:0] result_values [0:7];
  logic [3:0] result_m_count;
  logic [12:0] result_m_base;
  logic [15:0] result_n_base;
  logic result_last_slice;
  logic dma_command_valid, dma_command_ready;
  logic [31:0] dma_command_address;
  logic [25:0] dma_command_length;
  logic dma_armed, dma_done, dma_error;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic busy, fault;
  logic [31:0] accepted_slices, completed_tiles;
  logic [63:0] emitted_bytes;

  int output_row;
  longint unsigned observed_bytes;
  bit saw_last;
  bit arm_pending;

  alexnet_m8n126_result_tile_coalescer dut (.*);
  always #2.5 clk = ~clk;

  function automatic logic [63:0] value_for(
      input int n8, input int m_word, input int row);
    value_for = {8'(n8), 16'(m_word), 8'(row), 32'h51ce_0000 |
                 (n8 << 8) | row};
  endfunction

  task automatic send_slice(
      input int n8, input int m_word, input int rows,
      input bit last_slice);
    begin
      result_layer_id = 4'd3;
      result_base = 32'h3000_0000;
      result_m_base = m_word * 8;
      result_m_count = rows;
      result_n_base = n8 * 8;
      result_last_slice = last_slice;
      for (int row = 0; row < 8; row++)
        result_values[row] = value_for(n8, m_word, row);
      result_valid = 1'b1;
      do @(posedge clk); while (!result_ready);
      @(negedge clk);
      result_valid = 1'b0;
    end
  endtask

  always @(negedge clk) begin
    dma_command_ready = dma_command_valid;
    dma_armed = arm_pending;
    arm_pending = 1'b0;
    dma_done = 1'b0;
    if (dma_command_valid && dma_command_ready) begin
      if (dma_command_address != 32'h3000_0000 ||
          dma_command_length != 26'd18928)
        $fatal(1, "coalesced DMA descriptor mismatch addr=%h len=%0d",
               dma_command_address, dma_command_length);
      arm_pending = 1'b1;
    end
    m_axis_tready = $urandom_range(0, 4) != 0;
    if (saw_last)
      dma_done = 1'b1;
  end

  always @(posedge clk) begin
    if (!rst && m_axis_tvalid && m_axis_tready) begin
      logic [127:0] expected_data;
      logic [15:0] expected_keep;
      int low_n8, low_m, high_n8, high_m;
      low_n8 = output_row / 169;
      low_m = output_row % 169;
      high_n8 = (output_row + 1) / 169;
      high_m = (output_row + 1) % 169;
      expected_data = {
          value_for(high_n8, high_m/8, high_m%8),
          value_for(low_n8, low_m/8, low_m%8)};
      expected_keep = output_row + 1 < 14*169 ? 16'hffff : 16'h00ff;
      if (m_axis_tdata != expected_data || m_axis_tkeep != expected_keep)
        $fatal(1, "coalesced stream mismatch row=%0d got=%h expected=%h keep=%h/%h",
               output_row, m_axis_tdata,
               expected_data, m_axis_tkeep, expected_keep);
      observed_bytes += $countones(m_axis_tkeep);
      if (m_axis_tlast) begin
        if (output_row + 2 != 14*169)
          $fatal(1, "coalesced TLAST arrived early");
        saw_last = 1'b1;
      end
      output_row += expected_keep == 16'hffff ? 2 : 1;
    end
  end

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'hc0a1_0312);
    rst = 1'b1;
    result_valid = 1'b0;
    result_layer_id = 0;
    fc_batch_size = 1;
    result_base = 0;
    result_m_count = 0;
    result_m_base = 0;
    result_n_base = 0;
    result_last_slice = 1'b0;
    for (int row = 0; row < 8; row++)
      result_values[row] = 0;
    dma_command_ready = 1'b0;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    m_axis_tready = 1'b0;
    output_row = 0;
    observed_bytes = 0;
    saw_last = 1'b0;
    arm_pending = 1'b0;
    repeat (6) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    // Payload order is M-major; the coalescer must drain N8-major.
    for (int m_word = 0; m_word < 22; m_word++) begin
      for (int n8 = 0; n8 < 14; n8++) begin
        send_slice(n8, m_word, m_word == 21 ? 1 : 8,
                   m_word == 21 && n8 == 13);
      end
    end

    while (completed_tiles == 0 && !fault) @(negedge clk);
    if (fault || accepted_slices != 308 || completed_tiles != 1 ||
        observed_bytes != 18928 || emitted_bytes != 18928 || !saw_last)
      $fatal(1, "result coalescer final accounting mismatch");
    $display("ALEXNET_M8N126_RESULT_TILE_COALESCER_TEST_PASSED slices=308 dma_commands=1 bytes=18928");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "result tile coalescer watchdog");
  end
endmodule
