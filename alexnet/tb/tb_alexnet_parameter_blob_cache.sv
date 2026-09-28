`timescale 1ns/1ps

module tb_alexnet_parameter_blob_cache;
  localparam int TOTAL_BEATS = 10_344;
  localparam int RECORD_COUNT = 1_293;

  logic clk = 1'b0;
  logic rst;
  logic load_start_valid, load_start_ready;
  logic [127:0] s_axis_tdata;
  logic [15:0] s_axis_tkeep;
  logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
  logic load_active, load_done, cache_valid;
  logic request_valid, request_ready;
  logic [$clog2(RECORD_COUNT)-1:0] request_record_index;
  logic [127:0] m_axis_tdata;
  logic [15:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
  logic replay_active, fault;
  logic [31:0] completed_loads, completed_replays;

  alexnet_parameter_blob_cache dut (.*);
  always #2.5 clk = ~clk;

  function automatic logic [127:0] beat_value(input int beat);
    beat_value = {32'hca11_0000 | beat[15:0],
                  32'hb10b_0000 | beat[15:0],
                  32'h600d_0000 | beat[15:0],
                  32'hface_0000 | beat[15:0]};
  endfunction

  task automatic load_blob;
    begin
      load_start_valid = 1'b1;
      do @(posedge clk); while (!load_start_ready);
      @(negedge clk);
      load_start_valid = 1'b0;
      for (int beat = 0; beat < TOTAL_BEATS; beat++) begin
        s_axis_tdata = beat_value(beat);
        s_axis_tkeep = 16'hffff;
        s_axis_tlast = beat == TOTAL_BEATS-1;
        s_axis_tvalid = 1'b1;
        do @(posedge clk); while (!s_axis_tready);
        @(negedge clk);
        s_axis_tvalid = 1'b0;
      end
      while (!load_done) @(negedge clk);
      if (!cache_valid || fault)
        $fatal(1, "parameter cache did not validate the full blob");
    end
  endtask

  task automatic replay_record(input int record_index);
    int received;
    begin
      request_record_index = record_index;
      request_valid = 1'b1;
      do @(posedge clk); while (!request_ready);
      @(negedge clk);
      request_valid = 1'b0;
      received = 0;
      while (received < 8) begin
        m_axis_tready = $urandom_range(0, 3) != 0;
        @(posedge clk);
        if (m_axis_tvalid && m_axis_tready) begin
          if (m_axis_tdata != beat_value(record_index*8 + received) ||
              m_axis_tkeep != 16'hffff ||
              m_axis_tlast != (received == 7))
            $fatal(1, "parameter replay mismatch record=%0d beat=%0d",
                   record_index, received);
          received++;
        end
        @(negedge clk);
      end
      m_axis_tready = 1'b0;
      while (replay_active) @(negedge clk);
    end
  endtask

  initial begin
    int seed_sink;
    seed_sink = $urandom(32'hcace_1293);
    rst = 1'b1;
    load_start_valid = 1'b0;
    s_axis_tdata = 0;
    s_axis_tkeep = 0;
    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    request_valid = 1'b0;
    request_record_index = 0;
    m_axis_tready = 1'b0;
    repeat (6) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    load_blob();
    replay_record(0);
    replay_record(144);
    replay_record(656);
    replay_record(1292);

    if (completed_loads != 1 || completed_replays != 4 || fault)
      $fatal(1, "parameter cache counters mismatch");
    $display("ALEXNET_PARAMETER_BLOB_CACHE_TEST_PASSED bytes=165504 records=1293 replays=4");
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "parameter blob cache watchdog");
  end
endmodule
