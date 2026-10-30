`timescale 1ns/1ps

module tb_alexnet_eyeriss_filter_prefetch;
  logic clk = 0;
  logic rst = 1;
  logic fill_valid, fill_ready, fill_bank;
  logic [9:0] fill_word_count;
  logic [15:0] fill_context_tag;
  logic fill_data_valid, fill_data_ready;
  logic [63:0] fill_data;
  logic [7:0] fill_keep;
  logic fill_last;
  logic replay_valid, replay_ready, replay_bank;
  logic [9:0] replay_word_count;
  logic [15:0] replay_context_tag;
  logic replay_data_valid, replay_data_ready;
  logic [63:0] replay_data;
  logic [7:0] replay_keep;
  logic replay_last;
  logic release_valid, release_bank;
  logic [15:0] release_context_tag;
  logic [1:0] bank_state [0:1];
  logic fault;
  logic [31:0] dram_fill_bytes, pe_replay_bytes;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_filter_prefetch dut (.*);

  task automatic start_fill(input bit bank, input int words, input int tag);
    @(negedge clk);
    fill_valid = 1; fill_bank = bank; fill_word_count = words;
    fill_context_tag = tag;
    do @(posedge clk); while (!fill_ready);
    @(negedge clk); fill_valid = 0;
  endtask

  task automatic send_fill_word(input longint unsigned data, input bit last);
    @(negedge clk);
    fill_data_valid = 1; fill_data = data; fill_keep = 8'hff; fill_last = last;
    do @(posedge clk); while (!fill_data_ready);
    @(negedge clk); fill_data_valid = 0; fill_last = 0;
  endtask

  initial begin
    fill_valid = 0; fill_bank = 0; fill_word_count = 0; fill_context_tag = 0;
    fill_data_valid = 0; fill_data = 0; fill_keep = 0; fill_last = 0;
    replay_valid = 0; replay_bank = 0; replay_word_count = 0;
    replay_context_tag = 0; replay_data_ready = 1;
    release_valid = 0; release_bank = 0; release_context_tag = 0;
    repeat (5) @(negedge clk);
    rst = 0;

    start_fill(0, 3, 16'h1010);
    send_fill_word(64'h0102030405060708, 0);
    send_fill_word(64'h1112131415161718, 0);
    send_fill_word(64'h2122232425262728, 1);

    @(negedge clk);
    replay_valid = 1; replay_bank = 0; replay_word_count = 3;
    replay_context_tag = 16'h1010;
    do @(posedge clk); while (!replay_ready);
    @(negedge clk); replay_valid = 0;

    for (int i = 0; i < 3; i++) begin
      while (!replay_data_valid) @(negedge clk);
      case (i)
        0: if (replay_data != 64'h0102030405060708) $fatal(1, "replay word0");
        1: if (replay_data != 64'h1112131415161718) $fatal(1, "replay word1");
        2: if (replay_data != 64'h2122232425262728) $fatal(1, "replay word2");
      endcase
      if (replay_keep != 8'hff || replay_last != (i == 2))
        $fatal(1, "replay metadata i=%0d keep=%h last=%0b", i, replay_keep, replay_last);
      @(posedge clk);
      @(negedge clk);
    end

    @(negedge clk);
    release_valid = 1; release_bank = 0; release_context_tag = 16'h1010;
    @(negedge clk); release_valid = 0;
    if (fault) $fatal(1, "filter prefetch faulted");
    if (dram_fill_bytes != 24 || pe_replay_bytes != 24)
      $fatal(1, "prefetch counters fill=%0d replay=%0d",
             dram_fill_bytes, pe_replay_bytes);
    $display("ALEXNET_EYERISS_FILTER_PREFETCH_TEST_PASSED fill_bytes=%0d replay_bytes=%0d",
             dram_fill_bytes, pe_replay_bytes);
    $finish;
  end
endmodule
