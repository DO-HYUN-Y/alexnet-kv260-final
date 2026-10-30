`timescale 1ns/1ps

module tb_alexnet_eyeriss_rs_board_address_gen;
  logic [63:0] input_base, activation_a_base, activation_b_base, weights_base;
  logic filter_request_valid;
  logic [3:0] filter_request_layer;
  logic [12:0] filter_request_filter;
  logic [13:0] filter_request_channel;
  logic [3:0] filter_request_y, filter_request_x;
  logic filter_address_valid, filter_address_error;
  logic [63:0] filter_byte_address, filter_line_address;
  logic [3:0] filter_byte_select;
  logic [63:0] filter_relative_offset;
  logic ifmap_request_valid;
  logic [3:0] ifmap_request_layer;
  logic [2:0] ifmap_request_image;
  logic [13:0] ifmap_request_channel;
  logic signed [8:0] ifmap_request_y, ifmap_request_x;
  logic ifmap_address_valid, ifmap_address_error;
  logic [63:0] ifmap_byte_address, ifmap_line_address;
  logic [3:0] ifmap_byte_select;
  logic [63:0] ifmap_relative_offset, ifmap_selected_base;

  alexnet_eyeriss_rs_board_address_gen dut (.*);

  task automatic check_filter(
    input int layer, filter, channel, y, x,
    input logic [63:0] expected
  );
    begin
      filter_request_layer = layer; filter_request_filter = filter;
      filter_request_channel = channel; filter_request_y = y;
      filter_request_x = x; filter_request_valid = 1;
      #1;
      if (!filter_address_valid || filter_address_error ||
          filter_byte_address != expected ||
          filter_line_address != (expected & ~64'hf) ||
          filter_byte_select != expected[3:0])
        $fatal(1, "filter address layer=%0d got=%h expected=%h",
               layer, filter_byte_address, expected);
      filter_request_valid = 0;
    end
  endtask

  task automatic check_ifmap(
    input int layer, image, channel, y, x,
    input logic [63:0] expected
  );
    begin
      ifmap_request_layer = layer; ifmap_request_image = image;
      ifmap_request_channel = channel; ifmap_request_y = y;
      ifmap_request_x = x; ifmap_request_valid = 1;
      #1;
      if (!ifmap_address_valid || ifmap_address_error ||
          ifmap_byte_address != expected ||
          ifmap_line_address != (expected & ~64'hf) ||
          ifmap_byte_select != expected[3:0])
        $fatal(1, "ifmap address layer=%0d got=%h expected=%h",
               layer, ifmap_byte_address, expected);
      ifmap_request_valid = 0;
    end
  endtask

  initial begin
    input_base = 64'h2000_0000;
    activation_a_base = 64'h3000_0000;
    activation_b_base = 64'h4000_0000;
    weights_base = 64'h1000_0000;
    filter_request_valid = 0;
    ifmap_request_valid = 0;

    check_filter(1, 2, 1, 3, 4, weights_base + 840);
    check_filter(2, 191, 63, 4, 4,
                 weights_base + 23232 + 191*1600 + ((4*64+63)*5+4));
    check_filter(6, 17, 9000, 0, 0,
                 weights_base + 2468544 + 17*9216 + 9000);
    check_filter(8, 999, 4095, 0, 0,
                 weights_base + 56994496 + 999*4096 + 4095);

    check_ifmap(1, 3, 2, 223, 223,
                input_base + 3*401408 + (223*224+223)*8 + 2);
    check_ifmap(2, 7, 63, 26, 26,
                activation_a_base + 7*262144 + (7*729+728)*8 + 7);
    check_ifmap(3, 1, 191, 12, 12,
                activation_b_base + 262144 + (23*169+168)*8 + 7);
    check_ifmap(6, 5, 36, 0, 0,
                activation_a_base + 5*262144 + 1);
    check_ifmap(7, 2, 4095, 0, 0,
                activation_b_base + 2*262144 + 4095);

    filter_request_layer = 1; filter_request_filter = 64;
    filter_request_channel = 0; filter_request_y = 0; filter_request_x = 0;
    filter_request_valid = 1; #1;
    if (filter_address_valid || !filter_address_error)
      $fatal(1, "invalid filter coordinate accepted");
    filter_request_valid = 0;

    ifmap_request_layer = 1; ifmap_request_image = 0;
    ifmap_request_channel = 0; ifmap_request_y = -1; ifmap_request_x = 0;
    ifmap_request_valid = 1; #1;
    if (ifmap_address_valid || !ifmap_address_error)
      $fatal(1, "invalid ifmap coordinate accepted");

    $display("ALEXNET_EYERISS_RS_BOARD_ADDRESS_GEN_TEST_PASSED");
    $finish;
  end
endmodule
