`timescale 1ns/1ps

module tb_alexnet_m8n126_fc_batch8_result_coalescer;
  logic clk = 1'b0;
  logic rst;
  always #2.5 clk = ~clk;

  logic result_valid, result_ready;
  logic [3:0] result_layer_id, fc_batch_size;
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
  integer output_row;
  logic last_seen_q;

  function automatic logic [63:0] batch_value(
      input integer n8, input integer image);
    batch_value = {16'(n8), 8'(image), 40'hba_8c_000000};
  endfunction

  alexnet_m8n126_result_tile_coalescer dut (.*);

  task automatic send_slice(input integer n8, input logic final_slice);
    begin
      result_n_base = n8 * 8;
      result_last_slice = final_slice;
      for (int image = 0; image < 8; image++)
        result_values[image] = batch_value(n8, image);
      result_valid = 1'b1;
      do @(posedge clk); while (!result_ready);
      @(negedge clk);
      result_valid = 1'b0;
    end
  endtask

  always @(posedge clk) begin
    dma_armed <= 1'b0;
    dma_done <= 1'b0;
    if (!rst && dma_command_valid && dma_command_ready) begin
      if (dma_command_address != 32'h6000_0000 ||
          dma_command_length != 128)
        $fatal(1, "batch8 result descriptor mismatch addr=%h len=%0d",
               dma_command_address, dma_command_length);
      dma_armed <= 1'b1;
    end
    if (!rst && m_axis_tvalid && m_axis_tready) begin
      integer low_n8;
      integer low_image;
      integer high_n8;
      integer high_image;
      low_n8 = output_row / 8;
      low_image = output_row % 8;
      high_n8 = (output_row + 1) / 8;
      high_image = (output_row + 1) % 8;
      if (m_axis_tdata !== {batch_value(high_n8, high_image),
                            batch_value(low_n8, low_image)} ||
          m_axis_tkeep != 16'hffff ||
          m_axis_tlast != (output_row == 14))
        $fatal(1, "batch8 result layout mismatch row=%0d", output_row);
      output_row <= output_row + 2;
      if (m_axis_tlast) begin
        last_seen_q <= 1'b1;
        dma_done <= 1'b1;
      end
    end
  end

  initial begin
    rst = 1'b1;
    result_valid = 1'b0;
    result_layer_id = 8;
    fc_batch_size = 8;
    result_base = 32'h6000_0000;
    result_m_count = 8;
    result_m_base = 0;
    result_n_base = 0;
    result_last_slice = 1'b0;
    dma_command_ready = 1'b1;
    dma_armed = 1'b0;
    dma_done = 1'b0;
    dma_error = 1'b0;
    m_axis_tready = 1'b1;
    output_row = 0;
    last_seen_q = 1'b0;
    for (int row = 0; row < 8; row++)
      result_values[row] = 0;
    repeat (6) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);

    send_slice(0, 1'b0);
    send_slice(1, 1'b1);
    while (completed_tiles == 0 && !fault) @(posedge clk);
    if (fault || accepted_slices != 2 || completed_tiles != 1 ||
        emitted_bytes != 128 || output_row != 16 || !last_seen_q)
      $fatal(1, "batch8 result coalescer accounting mismatch");
    $display("ALEXNET_M8N126_FC_BATCH8_RESULT_COALESCER_SIM_PASS");
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "timeout");
  end
endmodule
