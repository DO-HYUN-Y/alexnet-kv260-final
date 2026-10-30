`timescale 1ns/1ps

// Two 4 KiB banks overlap the current processing pass with prefetch of the
// next pass, matching the paper's 8 KiB filter allocation.
module alexnet_eyeriss_filter_prefetch (
  input  logic          clk,
  input  logic          rst,

  input  logic          fill_valid,
  output logic          fill_ready,
  input  logic          fill_bank,
  input  logic [9:0]    fill_word_count,
  input  logic [15:0]   fill_context_tag,
  input  logic          fill_data_valid,
  output logic          fill_data_ready,
  input  logic [63:0]   fill_data,
  input  logic [7:0]    fill_keep,
  input  logic          fill_last,

  input  logic          replay_valid,
  output logic          replay_ready,
  input  logic          replay_bank,
  input  logic [9:0]    replay_word_count,
  input  logic [15:0]   replay_context_tag,
  output logic          replay_data_valid,
  input  logic          replay_data_ready,
  output logic [63:0]   replay_data,
  output logic [7:0]    replay_keep,
  output logic          replay_last,

  input  logic          release_valid,
  input  logic          release_bank,
  input  logic [15:0]   release_context_tag,

  output logic [1:0]    bank_state [0:1], // 0=empty,1=filling,2=resident,3=replay
  output logic          fault,
  output logic [31:0]   dram_fill_bytes,
  output logic [31:0]   pe_replay_bytes
);

  (* ram_style = "block" *) logic [63:0] mem [0:1][0:511];
  logic [9:0] resident_count [0:1];
  logic [15:0] resident_tag [0:1];

  logic fill_bank_q;
  logic [9:0] fill_count_q;
  logic [8:0] write_addr_q;
  logic replay_bank_q;
  logic [9:0] replay_count_q;
  logic [9:0] read_issued_q;

  function automatic [3:0] popcount8(input logic [7:0] value);
    integer i;
    begin
      popcount8 = '0;
      for (i = 0; i < 8; i = i + 1)
        popcount8 = popcount8 + value[i];
    end
  endfunction

  assign fill_ready = (bank_state[fill_bank] == 2'd0) &&
                      (fill_word_count >= 1) && (fill_word_count <= 512);
  assign fill_data_ready = (bank_state[fill_bank_q] == 2'd1);
  assign replay_ready = (bank_state[replay_bank] == 2'd2) &&
                        (resident_tag[replay_bank] == replay_context_tag) &&
                        (replay_word_count >= 1) &&
                        (replay_word_count <= resident_count[replay_bank]);
  assign replay_keep = 8'hff;
  assign replay_last = replay_data_valid &&
                       (read_issued_q == replay_count_q);

  integer b;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (b = 0; b < 2; b = b + 1) begin
        bank_state[b]     <= 2'd0;
        resident_count[b] <= '0;
        resident_tag[b]   <= '0;
      end
      fill_bank_q       <= 1'b0;
      fill_count_q      <= '0;
      write_addr_q      <= '0;
      replay_bank_q     <= 1'b0;
      replay_count_q    <= '0;
      read_issued_q     <= '0;
      replay_data_valid <= 1'b0;
      replay_data       <= '0;
      fault             <= 1'b0;
      dram_fill_bytes   <= '0;
      pe_replay_bytes   <= '0;
    end else begin
      if (replay_data_valid && replay_data_ready)
        replay_data_valid <= 1'b0;

      if (fill_valid) begin
        if (fill_ready) begin
          fill_bank_q       <= fill_bank;
          fill_count_q      <= fill_word_count;
          write_addr_q      <= '0;
          resident_tag[fill_bank] <= fill_context_tag;
          bank_state[fill_bank] <= 2'd1;
        end else begin
          fault <= 1'b1;
        end
      end

      if (fill_data_valid) begin
        if (fill_data_ready) begin
          mem[fill_bank_q][write_addr_q] <= fill_data;
          dram_fill_bytes <= dram_fill_bytes +
                             {28'd0, popcount8(fill_keep)};
          if ((write_addr_q + 1'b1 == fill_count_q) || fill_last) begin
            if ((write_addr_q + 1'b1 != fill_count_q) || !fill_last)
              fault <= 1'b1;
            resident_count[fill_bank_q] <= write_addr_q + 1'b1;
            bank_state[fill_bank_q] <= 2'd2;
          end else begin
            write_addr_q <= write_addr_q + 1'b1;
          end
        end else begin
          fault <= 1'b1;
        end
      end

      if (replay_valid) begin
        if (replay_ready) begin
          replay_bank_q  <= replay_bank;
          replay_count_q <= replay_word_count;
          read_issued_q  <= '0;
          bank_state[replay_bank] <= 2'd3;
        end else begin
          fault <= 1'b1;
        end
      end

      if ((bank_state[replay_bank_q] == 2'd3) &&
          (!replay_data_valid || replay_data_ready)) begin
        replay_data <= mem[replay_bank_q][read_issued_q[8:0]];
        replay_data_valid <= 1'b1;
        read_issued_q <= read_issued_q + 1'b1;
        pe_replay_bytes <= pe_replay_bytes + 32'd8;
        if (read_issued_q + 1'b1 == replay_count_q)
          bank_state[replay_bank_q] <= 2'd2;
      end

      if (release_valid) begin
        if ((bank_state[release_bank] == 2'd2) &&
            (resident_tag[release_bank] == release_context_tag)) begin
          bank_state[release_bank] <= 2'd0;
          resident_count[release_bank] <= '0;
        end else begin
          fault <= 1'b1;
        end
      end
    end
  end

endmodule
