`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Wishbone-only behavioral model in Verilog-2001.
//
// Firmware-visible behavior:
//   - First 3 writes after reset are configuration packets.
//   - Normal writes are command packets.
//   - Reads return queued TDC-style result words.
//   - Runtime reconfiguration is triggered by:
//       mode=2'b11, row=0, col=0, bit[17]=1
//     After that trigger, the next 3 writes are configuration packets again.
//
// Result format:
//   wbs_dat_o = {13'd0, column[4:0], tdc_value[13:0]}
// -----------------------------------------------------------------------------

module Neuromorphic_X2_wb_beh #(
  parameter [31:0] ADDR_MATCH        = 32'h3000_0004,
  parameter integer READ_DELAY       = 160,
  parameter integer PROGRAM_DELAY    = 220,
  parameter integer COMPUTE_DELAY    = 180,
  parameter integer CONFIG_WRITES    = 3
)(
  input         wb_clk_i,
  input         wb_rst_i,
  input         wbs_stb_i,
  input         wbs_cyc_i,
  input         wbs_we_i,
  input  [3:0]  wbs_sel_i,
  input  [31:0] wbs_dat_i,
  input  [31:0] wbs_adr_i,
  output reg [31:0] wbs_dat_o,
  output reg        wbs_ack_o
);

  localparam [1:0] MODE_RESET   = 2'b00;
  localparam [1:0] MODE_READ    = 2'b01;
  localparam [1:0] MODE_COMPUTE = 2'b10;
  localparam [1:0] MODE_SET     = 2'b11;

  localparam [2:0] STATUS_OK           = 3'b000;
  localparam [2:0] STATUS_BAD_COMMAND  = 3'b010;
  localparam [2:0] STATUS_COMPUTE_WAIT = 3'b100;

  integer r;
  integer c;

  reg [31:0] array_state [0:31];
  reg [13:0] cell_level  [0:1023];

  reg [31:0] command_q  [0:31];
  reg [31:0] response_q [0:31];

  reg [4:0] command_wr_idx;
  reg       command_wr_wrap;
  reg [4:0] command_rd_idx;
  reg       command_rd_wrap;

  reg [4:0] response_wr_idx;
  reg       response_wr_wrap;
  reg [4:0] response_rd_idx;
  reg       response_rd_wrap;

  reg [2:0]  status_code;
  reg        status_readback;
  reg [15:0] target_set1;
  reg [15:0] target_set2;
  reg [15:0] target_reset1;
  reg [15:0] target_reset2;
  reg [9:0]  no_of_clk_cycles;
  reg [9:0]  counter_value;
  reg [6:0]  tdc_time_out;
  reg [1:0]  tdc_dead_time;
  integer    config_count;

  reg [31:0] compute_packet0;
  reg [31:0] compute_packet1;
  integer    compute_count;
  reg        normal_operation_seen;

  wire selected;
  wire command_empty;
  wire command_full;
  wire response_empty;
  wire response_full;

  assign selected = wbs_stb_i && wbs_cyc_i &&
                    (wbs_sel_i == 4'hF) &&
                    (wbs_adr_i == ADDR_MATCH);

  assign command_empty = (command_wr_idx == command_rd_idx) &&
                         (command_wr_wrap == command_rd_wrap);
  assign command_full  = (command_wr_idx == command_rd_idx) &&
                         (command_wr_wrap != command_rd_wrap);
  assign response_empty = (response_wr_idx == response_rd_idx) &&
                          (response_wr_wrap == response_rd_wrap);
  assign response_full  = (response_wr_idx == response_rd_idx) &&
                          (response_wr_wrap != response_rd_wrap);

  function [9:0] cell_index;
    input [4:0] row_index;
    input [4:0] col_index;
    begin
      cell_index = {row_index, col_index};
    end
  endfunction

  function [31:0] onehot5;
    input [4:0] index;
    begin
      onehot5 = 32'h0000_0000;
      onehot5[index] = 1'b1;
    end
  endfunction

  function is_reconfig_packet;
    input [31:0] packet;
    begin
      is_reconfig_packet = (packet[31:30] == MODE_SET) &&
                           (packet[29:25] == 5'd0) &&
                           (packet[24:20] == 5'd0) &&
                           (packet[17] == 1'b1);
    end
  endfunction

  function [13:0] target_midpoint;
    input [15:0] target_a;
    input [15:0] target_b;
    reg [15:0] low_target;
    reg [15:0] high_target;
    reg [16:0] sum;
    begin
      if (target_a > target_b) begin
        high_target = target_a;
        low_target  = target_b;
      end else begin
        high_target = target_b;
        low_target  = target_a;
      end

      sum = {1'b0, low_target} + {1'b0, high_target};
      target_midpoint = sum[14:1];
    end
  endfunction

  function [13:0] programmed_level;
    input       set_cell;
    input [7:0] program_value;
    begin
      if (set_cell)
        programmed_level = target_midpoint(target_set1, target_set2) +
                           {6'd0, program_value};
      else
        programmed_level = target_midpoint(target_reset1, target_reset2) +
                           {6'd0, program_value};
    end
  endfunction

  function [13:0] cell_value;
    input [4:0] row_index;
    input [4:0] col_index;
    input [7:0] read_value;
    reg [13:0] raw_count;
    reg [13:0] timeout_ceiling;
    begin
      raw_count = cell_level[cell_index(row_index, col_index)] +
                  {6'd0, read_value};
      timeout_ceiling = {tdc_time_out[5:0], 8'hFF};

      if (raw_count > timeout_ceiling)
        cell_value = timeout_ceiling;
      else
        cell_value = raw_count;
    end
  endfunction

  function [31:0] result_word;
    input [4:0] col_index;
    input [13:0] value;
    begin
      result_word = {13'd0, col_index, value};
    end
  endfunction

  task wait_cycles;
    input integer cycles;
    begin
      repeat (cycles) @(posedge wb_clk_i);
    end
  endtask

  task advance_command_read;
    begin
      if (command_rd_idx == 5'd31) begin
        command_rd_idx  = 5'd0;
        command_rd_wrap = ~command_rd_wrap;
      end else begin
        command_rd_idx = command_rd_idx + 5'd1;
      end
    end
  endtask

  task advance_response_write;
    begin
      if (response_wr_idx == 5'd31) begin
        response_wr_idx  = 5'd0;
        response_wr_wrap = ~response_wr_wrap;
      end else begin
        response_wr_idx = response_wr_idx + 5'd1;
      end
    end
  endtask

  task push_response;
    input [31:0] value;
    begin
      while (response_full && !wb_rst_i)
        @(posedge wb_clk_i);

      if (!wb_rst_i) begin
        response_q[response_wr_idx] = value;
        advance_response_write();
      end
    end
  endtask

  task emit_read_results;
    input [31:0] packet;
    integer col;
    reg [4:0] row_index;
    reg [31:0] col_mask;
    begin
      row_index = packet[29:25];
      col_mask = packet[18] ? 32'hFFFF_FFFF : onehot5(packet[24:20]);

      wait_cycles(READ_DELAY);

      if (!wb_rst_i) begin
        for (col = 0; col < 32; col = col + 1) begin
          if (col_mask[col]) begin
            push_response(result_word(col[4:0],
                                      cell_value(row_index,
                                                 col[4:0],
                                                 packet[7:0])));
          end
        end
        status_code = STATUS_OK;
      end
    end
  endtask

  task run_program;
    input [31:0] packet;
    input        set_cell;
    reg [4:0] row_index;
    reg [4:0] col_index;
    begin
      row_index = packet[29:25];
      col_index = packet[24:20];

      wait_cycles(PROGRAM_DELAY + no_of_clk_cycles);

      if (!wb_rst_i) begin
        array_state[row_index][col_index] = set_cell;
        cell_level[cell_index(row_index, col_index)] =
          programmed_level(set_cell, packet[7:0]);
        status_code = STATUS_OK;
      end
    end
  endtask

  task emit_compute_results;
    input [31:0] packet0;
    input [31:0] packet1;
    input [31:0] packet2;
    integer col;
    reg [31:0] rows;
    reg [31:0] cols;
    reg [13:0] acc;
    begin
      rows = onehot5(packet0[29:25]) |
             onehot5(packet1[29:25]) |
             onehot5(packet2[29:25]);

      if (packet0[18] || packet1[18] || packet2[18])
        cols = 32'hFFFF_FFFF;
      else
        cols = onehot5(packet0[24:20]) |
               onehot5(packet1[24:20]) |
               onehot5(packet2[24:20]);

      wait_cycles(COMPUTE_DELAY);

      if (!wb_rst_i) begin
        for (col = 0; col < 32; col = col + 1) begin
          if (cols[col]) begin
            acc = 14'd0;

            if (array_state[packet0[29:25]][col])
              acc = acc + {6'd0, packet0[7:0]};
            if (array_state[packet1[29:25]][col])
              acc = acc + {6'd0, packet1[7:0]};
            if (array_state[packet2[29:25]][col])
              acc = acc + {6'd0, packet2[7:0]};

            push_response(result_word(col[4:0], acc));
          end
        end

        status_code = (rows == 32'h0000_0000) ? STATUS_BAD_COMMAND : STATUS_OK;
      end
    end
  endtask

  task apply_config;
    input [31:0] packet;
    begin
      case (config_count)
        0: begin
          target_set1 = packet[15:0];
          target_set2 = packet[31:16];
        end
        1: begin
          target_reset1 = packet[15:0];
          target_reset2 = packet[31:16];
        end
        2: begin
          no_of_clk_cycles = packet[9:0];
          counter_value    = packet[19:10];
          tdc_time_out     = packet[26:20];
          tdc_dead_time    = packet[31:30];
        end
      endcase

      config_count = config_count + 1;

      if ((config_count == CONFIG_WRITES) && !normal_operation_seen) begin
        for (r = 0; r < 32; r = r + 1) begin
          for (c = 0; c < 32; c = c + 1)
            cell_level[cell_index(r[4:0], c[4:0])] = programmed_level(1'b0, 8'h00);
        end
      end

      status_code = STATUS_OK;
    end
  endtask

  task execute_packet;
    input [31:0] packet;
    begin
      if (config_count < CONFIG_WRITES) begin
        apply_config(packet);
      end else begin
        status_readback = packet[19];

        if (is_reconfig_packet(packet)) begin
          config_count = 0;
          compute_count = 0;
          status_code = STATUS_OK;
        end else begin
        case (packet[31:30])
          MODE_READ: begin
            normal_operation_seen = 1'b1;
            compute_count = 0;
            emit_read_results(packet);
          end

          MODE_SET: begin
            normal_operation_seen = 1'b1;
            compute_count = 0;
            run_program(packet, 1'b1);
          end

          MODE_RESET: begin
            normal_operation_seen = 1'b1;
            compute_count = 0;
            run_program(packet, 1'b0);
          end

          MODE_COMPUTE: begin
            normal_operation_seen = 1'b1;
            status_code = STATUS_COMPUTE_WAIT;
            if (compute_count == 0) begin
              compute_packet0 = packet;
              compute_count = 1;
            end else if (compute_count == 1) begin
              compute_packet1 = packet;
              compute_count = 2;
            end else begin
              emit_compute_results(compute_packet0, compute_packet1, packet);
              compute_count = 0;
            end
          end

          default: begin
            status_code = STATUS_BAD_COMMAND;
          end
        endcase
        end
      end
    end
  endtask

  always @(posedge wb_clk_i or posedge wb_rst_i) begin
    if (wb_rst_i) begin
      wbs_ack_o        <= 1'b0;
      wbs_dat_o        <= 32'h0000_0000;
      command_wr_idx   <= 5'd0;
      command_wr_wrap  <= 1'b0;
      response_rd_idx  <= 5'd0;
      response_rd_wrap <= 1'b0;
    end else begin
      wbs_ack_o <= 1'b0;

      if (selected && wbs_we_i && !wbs_ack_o) begin
        if (!command_full) begin
          command_q[command_wr_idx] <= wbs_dat_i;

          if (command_wr_idx == 5'd31) begin
            command_wr_idx  <= 5'd0;
            command_wr_wrap <= ~command_wr_wrap;
          end else begin
            command_wr_idx <= command_wr_idx + 5'd1;
          end

          wbs_ack_o <= 1'b1;
        end
      end else if (selected && !wbs_we_i && !wbs_ack_o) begin
        if (status_readback) begin
          wbs_dat_o <= {29'd0, status_code};
          wbs_ack_o <= 1'b1;
        end else if (!response_empty) begin
          wbs_dat_o <= response_q[response_rd_idx];

          if (response_rd_idx == 5'd31) begin
            response_rd_idx  <= 5'd0;
            response_rd_wrap <= ~response_rd_wrap;
          end else begin
            response_rd_idx <= response_rd_idx + 5'd1;
          end

          wbs_ack_o <= 1'b1;
        end
      end
    end
  end

  initial begin
    for (r = 0; r < 32; r = r + 1) begin
      array_state[r] = 32'h0000_0000;
      for (c = 0; c < 32; c = c + 1)
        cell_level[cell_index(r[4:0], c[4:0])] = 14'h0E23;
    end

    command_rd_idx   = 5'd0;
    command_rd_wrap  = 1'b0;
    response_wr_idx  = 5'd0;
    response_wr_wrap = 1'b0;
    status_code      = STATUS_OK;
    status_readback  = 1'b0;
    target_set1      = 16'hC40F;
    target_set2      = 16'hA203;
    target_reset1    = 16'h0D43;
    target_reset2    = 16'h0F03;
    no_of_clk_cycles = 10'd3;
    counter_value    = 10'd3;
    tdc_time_out     = 7'd32;
    tdc_dead_time    = 2'b01;
    config_count     = 0;
    compute_packet0  = 32'h0000_0000;
    compute_packet1  = 32'h0000_0000;
    compute_count    = 0;
    normal_operation_seen = 1'b0;

    forever begin
      @(posedge wb_clk_i or posedge wb_rst_i);

      if (wb_rst_i) begin
        for (r = 0; r < 32; r = r + 1) begin
          array_state[r] = 32'h0000_0000;
          for (c = 0; c < 32; c = c + 1)
            cell_level[cell_index(r[4:0], c[4:0])] = 14'h0E23;
        end

        command_rd_idx   = 5'd0;
        command_rd_wrap  = 1'b0;
        response_wr_idx  = 5'd0;
        response_wr_wrap = 1'b0;
        status_code      = STATUS_OK;
        status_readback  = 1'b0;
        target_set1      = 16'hC40F;
        target_set2      = 16'hA203;
        target_reset1    = 16'h0D43;
        target_reset2    = 16'h0F03;
        no_of_clk_cycles = 10'd3;
        counter_value    = 10'd3;
        tdc_time_out     = 7'd32;
        tdc_dead_time    = 2'b01;
        config_count     = 0;
        compute_packet0  = 32'h0000_0000;
        compute_packet1  = 32'h0000_0000;
        compute_count    = 0;
        normal_operation_seen = 1'b0;
      end else if (!command_empty) begin
        execute_packet(command_q[command_rd_idx]);
        advance_command_read();
      end
    end
  end

endmodule

`ifdef NEUROMORPHIC_X2_WB_BEH_AS_RTL
module Neuromorphic_X2_wb #(
  parameter [31:0] ADDR_MATCH        = 32'h3000_0004,
  parameter integer READ_DELAY       = 160,
  parameter integer PROGRAM_DELAY    = 220,
  parameter integer COMPUTE_DELAY    = 180,
  parameter integer CONFIG_WRITES    = 3
)(
  input         wb_clk_i,
  input         wb_rst_i,
  input         wbs_stb_i,
  input         wbs_cyc_i,
  input         wbs_we_i,
  input  [3:0]  wbs_sel_i,
  input  [31:0] wbs_dat_i,
  input  [31:0] wbs_adr_i,
  output [31:0] wbs_dat_o,
  output        wbs_ack_o
);

  Neuromorphic_X2_wb_beh #(
    .ADDR_MATCH(ADDR_MATCH),
    .READ_DELAY(READ_DELAY),
    .PROGRAM_DELAY(PROGRAM_DELAY),
    .COMPUTE_DELAY(COMPUTE_DELAY),
    .CONFIG_WRITES(CONFIG_WRITES)
  ) wb_black_box_i (
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

endmodule
`endif
