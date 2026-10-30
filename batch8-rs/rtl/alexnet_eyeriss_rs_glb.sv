`timescale 1ns/1ps

// 128 KiB FPGA adaptation of the Eyeriss 108 KiB reconfigurable GLB.
// Thirty-two 4 KiB banks are dynamically assigned to ifmaps or psums.  The
// two logical ports may operate concurrently when they target different
// banks, preserving the paper's simultaneous ifmap/psum bandwidth contract.
module alexnet_eyeriss_rs_glb (
  input  logic          clk,
  input  logic          rst,

  input  logic          cfg_valid,
  output logic          cfg_ready,
  input  logic [4:0]    cfg_bank,
  input  logic [1:0]    cfg_role, // 0=free, 1=ifmap, 2=psum

  input  logic          if_req_valid,
  output logic          if_req_ready,
  input  logic          if_req_write,
  input  logic [14:0]   if_req_addr,
  input  logic [31:0]   if_req_wdata,
  input  logic [3:0]    if_req_wstrb,
  output logic          if_rsp_valid,
  input  logic          if_rsp_ready,
  output logic [31:0]   if_rsp_rdata,

  input  logic          ps_req_valid,
  output logic          ps_req_ready,
  input  logic          ps_req_write,
  input  logic [14:0]   ps_req_addr,
  input  logic [31:0]   ps_req_wdata,
  input  logic [3:0]    ps_req_wstrb,
  output logic          ps_rsp_valid,
  input  logic          ps_rsp_ready,
  output logic [31:0]   ps_rsp_rdata,

  output logic [1:0]    bank_role [0:31],
  output logic          fault,
  output logic [31:0]   ifmap_read_bytes,
  output logic [31:0]   ifmap_write_bytes,
  output logic [31:0]   psum_read_bytes,
  output logic [31:0]   psum_write_bytes
);

  (* ram_style = "block" *) logic [31:0] mem [0:31][0:1023];

  logic [4:0] if_bank;
  logic [4:0] ps_bank;
  logic [9:0] if_word;
  logic [9:0] ps_word;
  logic bank_conflict;
  logic if_fire;
  logic ps_fire;

  function automatic [2:0] popcount4(input logic [3:0] value);
    popcount4 = {2'b0, value[0]} + {2'b0, value[1]} +
                {2'b0, value[2]} + {2'b0, value[3]};
  endfunction

  assign if_bank = if_req_addr[14:10];
  assign ps_bank = ps_req_addr[14:10];
  assign if_word = if_req_addr[9:0];
  assign ps_word = ps_req_addr[9:0];
  assign cfg_ready = !if_req_valid && !ps_req_valid;
  assign bank_conflict = if_req_valid && ps_req_valid && (if_bank == ps_bank);
  assign if_req_ready = (bank_role[if_bank] == 2'd1) &&
                        (!if_rsp_valid || if_rsp_ready) && !bank_conflict;
  assign ps_req_ready = (bank_role[ps_bank] == 2'd2) &&
                        (!ps_rsp_valid || ps_rsp_ready) && !bank_conflict;
  assign if_fire = if_req_valid && if_req_ready;
  assign ps_fire = ps_req_valid && ps_req_ready;

  integer bank;
  integer byte_idx;
  always_ff @(posedge clk) begin
    if (rst) begin
      for (bank = 0; bank < 32; bank = bank + 1)
        bank_role[bank] <= 2'd0;
      if_rsp_valid      <= 1'b0;
      if_rsp_rdata      <= '0;
      ps_rsp_valid      <= 1'b0;
      ps_rsp_rdata      <= '0;
      fault             <= 1'b0;
      ifmap_read_bytes  <= '0;
      ifmap_write_bytes <= '0;
      psum_read_bytes   <= '0;
      psum_write_bytes  <= '0;
    end else begin
      if (if_rsp_valid && if_rsp_ready)
        if_rsp_valid <= 1'b0;
      if (ps_rsp_valid && ps_rsp_ready)
        ps_rsp_valid <= 1'b0;

      if (cfg_valid) begin
        if (cfg_ready && (cfg_role <= 2'd2))
          bank_role[cfg_bank] <= cfg_role;
        else
          fault <= 1'b1;
      end

      if (if_req_valid && (bank_role[if_bank] != 2'd1))
        fault <= 1'b1;
      if (ps_req_valid && (bank_role[ps_bank] != 2'd2))
        fault <= 1'b1;
      if (bank_conflict)
        fault <= 1'b1;

      if (if_fire) begin
        if (if_req_write) begin
          for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
            if (if_req_wstrb[byte_idx])
              mem[if_bank][if_word][byte_idx*8 +: 8] <=
                if_req_wdata[byte_idx*8 +: 8];
          ifmap_write_bytes <= ifmap_write_bytes +
                               {29'd0, popcount4(if_req_wstrb)};
        end else begin
          if_rsp_rdata <= mem[if_bank][if_word];
          if_rsp_valid <= 1'b1;
          ifmap_read_bytes <= ifmap_read_bytes + 32'd4;
        end
      end

      if (ps_fire) begin
        if (ps_req_write) begin
          for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
            if (ps_req_wstrb[byte_idx])
              mem[ps_bank][ps_word][byte_idx*8 +: 8] <=
                ps_req_wdata[byte_idx*8 +: 8];
          psum_write_bytes <= psum_write_bytes +
                              {29'd0, popcount4(ps_req_wstrb)};
        end else begin
          ps_rsp_rdata <= mem[ps_bank][ps_word];
          ps_rsp_valid <= 1'b1;
          psum_read_bytes <= psum_read_bytes + 32'd4;
        end
      end
    end
  end

endmodule
