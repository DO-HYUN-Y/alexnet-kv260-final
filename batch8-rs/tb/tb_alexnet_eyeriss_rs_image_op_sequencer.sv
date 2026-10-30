`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_image_op_sequencer;
  logic clk = 0;
  logic rst = 1;
  logic start_valid, start_ready;
  logic [15:0] start_tag;
  logic [3:0] layer_id;
  logic [2:0] image_index;
  logic [5:0] strip_y, strip_rows;
  logic [13:0] channel_base;
  logic [7:0] channel_count;
  logic [12:0] filter_base;
  logic [9:0] filter_count;
  logic [5:0] output_width;
  logic [3:0] filter_r, filter_s;
  logic [2:0] stride;
  logic [5:0] map_e, map_p;
  logic [3:0] map_q, map_r, map_t;
  logic ifmap_command_valid, ifmap_command_ready;
  logic [4:0] ifmap_row_tag;
  logic [5:0] ifmap_col_tag;
  logic [3:0] ifmap_rf_addr;
  logic ifmap_source_required;
  logic [2:0] ifmap_source_image;
  logic [13:0] ifmap_source_channel;
  logic signed [8:0] ifmap_source_y, ifmap_source_x;
  logic op_command_valid, op_command_ready;
  logic [2:0] op_cluster_enable;
  logic [2:0][167:0] op_mask;
  logic [7:0] op_filter_addr;
  logic [3:0] op_ifmap_addr;
  logic [4:0] op_psum_addr;
  logic op_first, op_last;
  logic [15:0] op_tag;
  logic reduce_command_valid, reduce_command_ready;
  logic reduce_command_done, reduce_command_error;
  logic [1:0] reduce_cluster;
  logic [3:0] reduce_rows, reduce_cols;
  logic [3:0] reduce_start_row, reduce_start_col;
  logic [15:0] reduce_tag;
  logic [12:0] reduce_output_filter;
  logic [2:0] reduce_output_image;
  logic [5:0] reduce_output_x, reduce_output_y_base;
  logic done, error;
  logic [31:0] ifmap_commands, ifmap_source_bytes, op_vectors, reductions;
  logic [63:0] pe_mac_operations;
  logic reduce_pending;

  always #2.5 clk = ~clk;
  alexnet_eyeriss_rs_image_op_sequencer dut (.*);

  always_ff @(posedge clk) begin
    reduce_command_done <= 1'b0;
    if (rst) begin
      reduce_pending <= 1'b0;
    end else begin
      if (reduce_command_valid && reduce_command_ready)
        reduce_pending <= 1'b1;
      if (reduce_pending) begin
        reduce_command_done <= 1'b1;
        reduce_pending <= 1'b0;
      end
    end
  end

  function automatic int expected_source_bytes(
    input int layer, input int sy, input int rows,
    input int ccount, input int width,
    input int fr, input int fs, input int st
  );
    int dim;
    int pad;
    int total;
    int diag_count;
    begin
      case (layer)
        1: begin dim = 224; pad = 2; end
        2: begin dim = 27; pad = 2; end
        3, 4, 5: begin dim = 13; pad = 1; end
        default: begin dim = 1; pad = 0; end
      endcase
      if (layer >= 6) begin
        expected_source_bytes = ccount;
      end else begin
        total = 0;
        diag_count = fr + (rows - 1) * st;
        for (int x = 0; x < width; x++)
          for (int s = 0; s < fs; s++)
            for (int diag = 0; diag < diag_count; diag++)
              if (((sy * st + diag - pad) >= 0) &&
                  ((sy * st + diag - pad) < dim) &&
                  ((x * st + s - pad) >= 0) &&
                  ((x * st + s - pad) < dim))
                total += ccount;
        expected_source_bytes = total;
      end
    end
  endfunction

  task automatic run_case(
    input int layer, input int sy, input int rows,
    input int cbase, input int ccount,
    input int fbase, input int fcount,
    input int width, input int fr, input int fs, input int st,
    input int e, input int p, input int q, input int r, input int t
  );
    int diag_count;
    int exp_ifmap;
    int exp_source;
    int exp_ops;
    int exp_macs;
    int exp_reductions;
    begin
      layer_id = layer;
      strip_y = sy;
      strip_rows = rows;
      channel_base = cbase;
      channel_count = ccount;
      filter_base = fbase;
      filter_count = fcount;
      output_width = width;
      filter_r = fr;
      filter_s = fs;
      stride = st;
      map_e = e;
      map_p = p;
      map_q = q;
      map_r = r;
      map_t = t;
      diag_count = fr + (rows - 1) * st;
      exp_ifmap = width * r * q * fs * diag_count;
      exp_source = expected_source_bytes(layer, sy, rows, ccount,
                                         width, fr, fs, st);
      exp_ops = width * p * q * fs;
      exp_macs = width * fcount * fr * r * rows * q * fs;
      exp_reductions = width * fcount;
      if (e > 14 && rows > 14)
        exp_reductions *= 2;

      @(negedge clk); start_valid = 1;
      do @(posedge clk); while (!start_ready);
      @(negedge clk); start_valid = 0;
      while (!done) begin
        @(negedge clk);
        if (ifmap_command_valid && ifmap_command_ready) begin
          if (ifmap_row_tag >= r || ifmap_col_tag >= diag_count ||
              ifmap_rf_addr >= (q * fs) ||
              ifmap_source_image != image_index)
            $fatal(1, "ifmap metadata row=%0d col=%0d addr=%0d image=%0d",
                   ifmap_row_tag, ifmap_col_tag, ifmap_rf_addr,
                   ifmap_source_image);
          if (ifmap_source_required &&
              (ifmap_source_channel < cbase ||
               ifmap_source_channel >= (cbase + ccount)))
            $fatal(1, "ifmap source channel %0d", ifmap_source_channel);
        end
        if (op_command_valid && op_command_ready) begin
          if (!(|op_cluster_enable) || op_filter_addr >= (p*q*fs) ||
              op_ifmap_addr >= (q*fs) || op_psum_addr >= p ||
              op_tag != start_tag)
            $fatal(1, "op metadata");
        end
        if (reduce_command_valid && reduce_command_ready) begin
          if (reduce_cluster > 2 || reduce_rows == 0 || reduce_cols == 0 ||
              (reduce_start_row + reduce_rows) > 12 ||
              (reduce_start_col + reduce_cols) > 14 ||
              reduce_output_filter < fbase ||
              reduce_output_filter >= (fbase + fcount) ||
              reduce_output_image != image_index || reduce_tag != start_tag)
            $fatal(1, "reduction metadata");
        end
      end
      if (error || ifmap_commands != exp_ifmap ||
          ifmap_source_bytes != exp_source || op_vectors != exp_ops ||
          pe_mac_operations != exp_macs || reductions != exp_reductions)
        $fatal(1, "layer %0d counts ifmap=%0d/%0d src=%0d/%0d op=%0d/%0d mac=%0d/%0d reduce=%0d/%0d",
               layer, ifmap_commands, exp_ifmap,
               ifmap_source_bytes, exp_source, op_vectors, exp_ops,
               pe_mac_operations, exp_macs, reductions, exp_reductions);
      @(negedge clk);
    end
  endtask

  initial begin
    start_valid = 0;
    start_tag = 16'h1a58;
    image_index = 3;
    ifmap_command_ready = 1;
    op_command_ready = 1;
    reduce_command_ready = 1;
    reduce_command_done = 0;
    reduce_command_error = 0;
    layer_id = 1;
    strip_y = 0;
    strip_rows = 1;
    channel_base = 0;
    channel_count = 1;
    filter_base = 0;
    filter_count = 1;
    output_width = 1;
    filter_r = 1;
    filter_s = 1;
    stride = 1;
    map_e = 1;
    map_p = 1;
    map_q = 1;
    map_r = 1;
    map_t = 1;
    repeat (6) @(negedge clk);
    rst = 0;

    run_case(1, 49, 6, 2, 1, 0, 64, 55, 11, 11, 4,
             7, 16, 1, 1, 2);
    run_case(2, 0, 27, 62, 2, 144, 48, 27, 5, 5, 1,
             27, 16, 2, 1, 1);
    run_case(3, 0, 13, 188, 4, 192, 192, 13, 3, 3, 1,
             13, 16, 4, 1, 4);
    run_case(5, 0, 13, 252, 4, 192, 64, 13, 3, 3, 1,
             13, 16, 3, 2, 2);
    run_case(7, 0, 1, 4032, 64, 3780, 316, 1, 1, 1, 1,
             1, 18, 12, 12, 14);

    $display("ALEXNET_EYERISS_RS_IMAGE_OP_SEQUENCER_TEST_PASSED");
    $finish;
  end
endmodule
