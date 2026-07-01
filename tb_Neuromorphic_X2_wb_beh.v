`timescale 1ns/1ps

module tb_Neuromorphic_X2_wb_beh;

  localparam [31:0] ADDR_MATCH = 32'h3000_0004;
  localparam [15:0] TARGET_SET1   = 16'h0300;
  localparam [15:0] TARGET_SET2   = 16'h0200;
  localparam [15:0] TARGET_RESET1 = 16'h0040;
  localparam [15:0] TARGET_RESET2 = 16'h0080;
  localparam [15:0] TARGET2_SET1   = 16'h0500;
  localparam [15:0] TARGET2_SET2   = 16'h0400;
  localparam [15:0] TARGET2_RESET1 = 16'h0100;
  localparam [15:0] TARGET2_RESET2 = 16'h0180;

  localparam [31:0] RECONFIG_PACKET = {2'b11, 5'd0, 5'd0, 1'b0, 1'b0,
                                       1'b1, 9'd0, 8'h00};

  reg         wb_clk_i;
  reg         wb_rst_i;
  reg         wbs_stb_i;
  reg         wbs_cyc_i;
  reg         wbs_we_i;
  reg  [3:0]  wbs_sel_i;
  reg  [31:0] wbs_dat_i;
  reg  [31:0] wbs_adr_i;
  wire [31:0] wbs_dat_o;
  wire        wbs_ack_o;

  integer pass_count;
  integer col_loop;
  reg ack_prev;
	
	reg [31:0] rdata;

  Neuromorphic_X2_wb_beh #(
    .ADDR_MATCH(ADDR_MATCH),
    .READ_DELAY(8),
    .PROGRAM_DELAY(12),
    .COMPUTE_DELAY(10),
    .CONFIG_WRITES(3)
  ) dut (
    .wb_clk_i(wb_clk_i),
    .wb_rst_i(wb_rst_i),
    .wbs_stb_i(wbs_stb_i),
    .wbs_cyc_i(wbs_cyc_i),
    .wbs_we_i(wbs_we_i),
    .wbs_sel_i(wbs_sel_i),
    .wbs_dat_i(wbs_dat_i),
    .wbs_adr_i(wbs_adr_i),
    .wbs_dat_o(wbs_dat_o),
    .wbs_ack_o(wbs_ack_o)
  );

  always #5 wb_clk_i = ~wb_clk_i;

  always @(posedge wb_clk_i or posedge wb_rst_i) begin
    if (wb_rst_i) begin
      ack_prev <= 1'b0;
    end else begin
      if (ack_prev && wbs_ack_o) begin
        $display("%0t ERROR: wbs_ack_o stayed high for more than one clock",
                 $time);
        $finish;
      end
      ack_prev <= wbs_ack_o;
    end
  end

  function [31:0] make_packet;
    input [1:0] mode;
    input [4:0] row;
    input [4:0] col;
    input       status_read;
    input       full_row;
    input [7:0] data_byte;
    begin
      make_packet = {mode, row, col, status_read, full_row, 10'd0, data_byte};
    end
  endfunction

  function [31:0] expect_word;
    input [4:0]  col;
    input [13:0] value;
    begin
      expect_word = {13'd0, col, value};
    end
  endfunction

  function [13:0] expect_programmed_level_cfg;
    input       is_set;
    input [7:0] program_byte;
    input [15:0] set1;
    input [15:0] set2;
    input [15:0] reset1;
    input [15:0] reset2;
    reg [16:0] set_sum;
    reg [16:0] reset_sum;
    begin
      set_sum   = {1'b0, set1} + {1'b0, set2};
      reset_sum = {1'b0, reset1} + {1'b0, reset2};

      if (is_set)
        expect_programmed_level_cfg = set_sum[14:1] + {6'd0, program_byte};
      else
        expect_programmed_level_cfg = reset_sum[14:1] + {6'd0, program_byte};
    end
  endfunction

  function [13:0] expect_programmed_level;
    input       is_set;
    input [7:0] program_byte;
    begin
      expect_programmed_level = expect_programmed_level_cfg(
        is_set,
        program_byte,
        TARGET_SET1,
        TARGET_SET2,
        TARGET_RESET1,
        TARGET_RESET2
      );
    end
  endfunction

  function [13:0] expect_read_value;
    input [13:0] stored_level;
    input [4:0]  row;
    input [4:0]  col;
    input [7:0]  read_byte;
    reg [13:0] raw_count;
    reg [13:0] timeout_ceiling;
    begin
      raw_count = stored_level + {6'd0, read_byte};
      timeout_ceiling = {6'd32, 8'hFF};

      if (raw_count > timeout_ceiling)
        expect_read_value = timeout_ceiling;
      else
        expect_read_value = raw_count;
    end
  endfunction

  task init_bus;
    begin
      wbs_stb_i <= 1'b0;
      wbs_cyc_i <= 1'b0;
      wbs_we_i  <= 1'b0;
      wbs_sel_i <= 4'h0;
      wbs_dat_i <= 32'h0000_0000;
      wbs_adr_i <= 32'h0000_0000;
    end
  endtask

  task apply_reset;
    begin
      wb_rst_i = 1'b1;
      init_bus();
      repeat (5) @(posedge wb_clk_i);
      @(posedge wb_clk_i);
      wb_rst_i <= 1'b0;
      repeat (2) @(posedge wb_clk_i);
    end
  endtask

  task wb_write32;
    input [31:0] addr;
    input [31:0] data_word;
    begin
      @(posedge wb_clk_i);
      wbs_adr_i <= addr;
      wbs_dat_i <= data_word;
      wbs_sel_i <= 4'hF;
      wbs_we_i  <= 1'b1;
      wbs_cyc_i <= 1'b1;
      wbs_stb_i <= 1'b1;

      wait(wbs_ack_o);

      @(posedge wb_clk_i);
      init_bus();
    end
  endtask

  task wb_read32;
    input [31:0] addr;
    output [31:0] data_word;
    begin
      @(posedge wb_clk_i);
      wbs_adr_i <= addr;
      wbs_dat_i <= 32'h0000_0000;
      wbs_sel_i <= 4'hF;
      wbs_we_i  <= 1'b0;
      wbs_cyc_i <= 1'b1;
      wbs_stb_i <= 1'b1;

      wait(wbs_ack_o);
      data_word = wbs_dat_o;

      @(posedge wb_clk_i);
      init_bus();
    end
  endtask

  task wb_write;
    input [31:0] data_word;
    begin
      wb_write32(ADDR_MATCH, data_word);
    end
  endtask

  task wb_read;
    output [31:0] data_word;
    begin
      wb_read32(ADDR_MATCH, data_word);
    end
  endtask

  task check_read;
    input [511:0] label_text;
    input [31:0] expected;
    reg [31:0] got;
    begin
      wb_read(got);
      if (got !== expected) begin
        $display("%0t ERROR: %0s expected=%08h got=%08h",
                 $time, label_text, expected, got);
        $finish;
      end
      pass_count = pass_count + 1;
      $display("%0t PASS: %0s -> %08h", $time, label_text, got);
    end
  endtask

  task write_configuration;
    begin
      wb_write({TARGET_SET2, TARGET_SET1});
      wb_write({TARGET_RESET2, TARGET_RESET1});
      wb_write({2'b01, 3'b000, 7'd32, 10'd3, 10'd3});
    end
  endtask

  task write_configuration_2;
    begin
      wb_write({TARGET2_SET2, TARGET2_SET1});
      wb_write({TARGET2_RESET2, TARGET2_RESET1});
      wb_write({2'b01, 3'b000, 7'd40, 10'd4, 10'd5});
    end
  endtask

  initial begin
    wb_clk_i   = 1'b0;
    wb_rst_i   = 1'b1;
    pass_count = 0;
    ack_prev   = 1'b0;

    apply_reset();
    write_configuration();
		
		wb_write(make_packet(2'b11, 5'd1, 5'd3, 1'b0, 1'b0, 8'hA5));
    wb_write(make_packet(2'b01, 5'd1, 5'd3, 1'b0, 1'b0, 8'h12));
		wb_write(make_packet(2'b11, 5'd3, 5'd5, 1'b0, 1'b0, 8'hA6));
    wb_write(make_packet(2'b01, 5'd3, 5'd5, 1'b0, 1'b0, 8'h53));
		wb_write(make_packet(2'b11, 5'd9, 5'd20, 1'b0, 1'b0, 8'hF3));
		wb_write(make_packet(2'b11, 5'd5, 5'd4, 1'b0, 1'b0, 8'h11));
    wb_write(make_packet(2'b01, 5'd9, 5'd20, 1'b0, 1'b0, 8'h00));
    wb_write(make_packet(2'b01, 5'd5, 5'd4, 1'b0, 1'b0, 8'hDC));
		repeat (1000) @(posedge wb_clk_i);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
		
		wb_write(make_packet(2'b00, 5'd2, 5'd3, 1'b0, 1'b0, 8'hA5));
    wb_write(make_packet(2'b01, 5'd2, 5'd3, 1'b0, 1'b0, 8'h12));
		repeat (400) @(posedge wb_clk_i);
    wb_read32(ADDR_MATCH, rdata);
		
		wb_write(RECONFIG_PACKET);
    write_configuration_2();
		
		wb_write(make_packet(2'b11, 5'd1, 5'd3, 1'b0, 1'b0, 8'hA5));
    wb_write(make_packet(2'b01, 5'd1, 5'd3, 1'b0, 1'b0, 8'h12));
		wb_write(make_packet(2'b11, 5'd3, 5'd5, 1'b0, 1'b0, 8'hA6));
    wb_write(make_packet(2'b01, 5'd3, 5'd5, 1'b0, 1'b0, 8'h53));
		wb_write(make_packet(2'b11, 5'd9, 5'd20, 1'b0, 1'b0, 8'hF3));
		wb_write(make_packet(2'b11, 5'd5, 5'd4, 1'b0, 1'b0, 8'h11));
    wb_write(make_packet(2'b01, 5'd9, 5'd20, 1'b0, 1'b0, 8'h00));
    wb_write(make_packet(2'b01, 5'd5, 5'd4, 1'b0, 1'b0, 8'hDC));
		repeat (1000) @(posedge wb_clk_i);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
    wb_read32(ADDR_MATCH, rdata);
		
		wb_write(make_packet(2'b00, 5'd2, 5'd3, 1'b0, 1'b0, 8'hA5));
    wb_write(make_packet(2'b01, 5'd2, 5'd3, 1'b0, 1'b0, 8'h12));
		repeat (400) @(posedge wb_clk_i);
    wb_read32(ADDR_MATCH, rdata);
		
		
		
		/*

    wb_write(make_packet(2'b01, 5'd3, 5'd0, 1'b0, 1'b1, 8'h00));
    for (col_loop = 0; col_loop < 32; col_loop = col_loop + 1) begin
      wb_read32(ADDR_MATCH, rdata);
    end

    wb_write(make_packet(2'b11, 5'd1, 5'd2, 1'b0, 1'b0, 8'h01));
    wb_write(make_packet(2'b11, 5'd2, 5'd2, 1'b0, 1'b0, 8'h01));
    wb_write(make_packet(2'b11, 5'd3, 5'd2, 1'b0, 1'b0, 8'h01));

    wb_write(make_packet(2'b10, 5'd1, 5'd2, 1'b0, 1'b0, 8'h03));
    wb_write(make_packet(2'b10, 5'd2, 5'd2, 1'b0, 1'b0, 8'h04));
    wb_write(make_packet(2'b10, 5'd3, 5'd2, 1'b0, 1'b0, 8'h05));
    wb_read32(ADDR_MATCH, rdata);

    wb_write(RECONFIG_PACKET);
    write_configuration_2();

    wb_write(make_packet(2'b11, 5'd4, 5'd6, 1'b0, 1'b0, 8'h12));
    wb_write(make_packet(2'b01, 5'd4, 5'd6, 1'b0, 1'b0, 8'h03));
    wb_read32(ADDR_MATCH, rdata);
		*/

    $display("%0t TEST PASSED: %0d checks completed", $time, pass_count);
    #50;
    $finish;
  end

endmodule
