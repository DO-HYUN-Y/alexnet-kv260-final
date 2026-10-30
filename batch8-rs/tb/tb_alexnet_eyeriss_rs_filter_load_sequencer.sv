`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_filter_load_sequencer;
  logic clk = 0;
  logic rst = 1;
  logic start_valid, start_ready;
  logic [13:0] channel_base;
  logic [7:0] channel_count;
  logic [12:0] filter_base;
  logic [9:0] filter_count;
  logic [3:0] filter_r, filter_s;
  logic [5:0] map_e, map_p;
  logic [3:0] map_q, map_r, map_t;
  logic command_valid, command_ready;
  logic [1:0] command_cluster;
  logic [4:0] command_row_tag;
  logic [5:0] command_col_tag;
  logic [7:0] command_rf_addr;
  logic source_required;
  logic [12:0] source_filter;
  logic [13:0] source_channel;
  logic [3:0] source_filter_y, source_filter_x;
  logic done, error;
  logic [31:0] emitted_commands, source_bytes;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_filter_load_sequencer dut (.*);

  task automatic run_case(
    input int cbase, input int ccount,
    input int fbase, input int fcount,
    input int fr, input int fs, input int e,
    input int p, input int q, input int r, input int t
  );
    int observed_commands;
    int observed_sources;
    int expected_commands;
    int expected_sources;
    begin
      channel_base = cbase;
      channel_count = ccount;
      filter_base = fbase;
      filter_count = fcount;
      filter_r = fr;
      filter_s = fs;
      map_e = e;
      map_p = p;
      map_q = q;
      map_r = r;
      map_t = t;
      observed_commands = 0;
      observed_sources = 0;
      expected_commands = fcount * q * r * fr * fs;
      expected_sources = fcount * ccount * fr * fs;

      @(negedge clk); start_valid = 1;
      do @(posedge clk); while (!start_ready);
      @(negedge clk); start_valid = 0;
      while (!done) begin
        @(posedge clk);
        if (command_valid && command_ready) begin
          observed_commands++;
          if (command_cluster > 2 || command_rf_addr >= 224)
            $fatal(1, "illegal destination cluster=%0d addr=%0d",
                   command_cluster, command_rf_addr);
          if (source_filter < fbase || source_filter >= (fbase + fcount))
            $fatal(1, "filter source %0d outside pass", source_filter);
          if (source_required) begin
            observed_sources++;
            if (source_channel < cbase ||
                source_channel >= (cbase + ccount))
              $fatal(1, "channel source %0d outside pass", source_channel);
          end
          if (source_filter_y >= fr || source_filter_x >= fs)
            $fatal(1, "kernel coordinate y=%0d x=%0d",
                   source_filter_y, source_filter_x);
        end
      end
      if (error || observed_commands != expected_commands ||
          observed_sources != expected_sources ||
          emitted_commands != expected_commands ||
          source_bytes != expected_sources)
        $fatal(1, "counts cmd=%0d/%0d src=%0d/%0d hw=%0d/%0d",
               observed_commands, expected_commands,
               observed_sources, expected_sources,
               emitted_commands, source_bytes);
      @(negedge clk);
    end
  endtask

  initial begin
    start_valid = 0;
    command_ready = 1;
    channel_base = 0;
    channel_count = 1;
    filter_base = 0;
    filter_count = 1;
    filter_r = 1;
    filter_s = 1;
    map_e = 1;
    map_p = 1;
    map_q = 1;
    map_r = 1;
    map_t = 1;
    repeat (6) @(negedge clk);
    rst = 0;

    // Conv1: horizontal t=2 sets, partial final filter group.
    run_case(0, 1, 0, 64, 11, 11, 7, 16, 1, 1, 2);
    // Conv2: folded 5x27 PE set.
    run_case(0, 2, 0, 48, 5, 5, 27, 16, 2, 1, 1);
    // Conv3: four vertical filter sets.
    run_case(0, 4, 0, 192, 3, 3, 13, 16, 4, 1, 4);
    // Conv4/5: r=2, t=2 with a partial filter group.
    run_case(252, 4, 192, 64, 3, 3, 13, 16, 3, 2, 2);
    // FC: final partial channel and filter groups exercise zero fill.
    run_case(4032, 64, 3780, 316, 1, 1, 1, 18, 12, 12, 14);

    $display("ALEXNET_EYERISS_RS_FILTER_LOAD_SEQUENCER_TEST_PASSED");
    $finish;
  end
endmodule
