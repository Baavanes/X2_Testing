# Neuromorphic_X2_wb_beh Behavioral Model README

This document explains the Wishbone-only behavioral model in
`Neuromorphic_X2_wb_beh.v`.

The model is intended for simulation. It hides detailed RTL internals and exposes
only the firmware-visible Wishbone behavior: configuration writes, command
writes, delayed program/read behavior, and TDC-style read results.

## File And Module

Main file:

```text
Neuromorphic_X2_wb_beh.v
```

Primary module:

```verilog
module Neuromorphic_X2_wb_beh
```

Optional wrapper module, compiled only when this define is enabled:

```verilog
`define NEUROMORPHIC_X2_WB_BEH_AS_RTL
module Neuromorphic_X2_wb
```

The testbench normally instantiates `Neuromorphic_X2_wb_beh` directly.

## Wishbone Interface

The model uses a simple 32-bit Wishbone-style interface:

```verilog
input         wb_clk_i;
input         wb_rst_i;
input         wbs_stb_i;
input         wbs_cyc_i;
input         wbs_we_i;
input  [3:0]  wbs_sel_i;
input  [31:0] wbs_dat_i;
input  [31:0] wbs_adr_i;
output [31:0] wbs_dat_o;
output        wbs_ack_o;
```

A transaction is selected only when all of these are true:

```verilog
wbs_stb_i == 1'b1
wbs_cyc_i == 1'b1
wbs_sel_i == 4'hF
wbs_adr_i == ADDR_MATCH
```

Default address:

```verilog
ADDR_MATCH = 32'h3000_0004
```

## Wishbone ACK Behavior

The behavioral model is decoupled internally using a command FIFO and a response
FIFO.

For a Wishbone write:

1. The master drives `wbs_we_i = 1'b1`.
2. If the address/select match and the command FIFO is not full, the model stores
   `wbs_dat_i` into the command FIFO.
3. `wbs_ack_o` pulses high for one clock.

For a Wishbone read:

1. The master drives `wbs_we_i = 1'b0`.
2. If a response word is available, the model places it on `wbs_dat_o`.
3. `wbs_ack_o` pulses high for one clock.
4. If no response is ready, the model does not ACK. The master waits.

There is no empty-read token. A Wishbone read completes only when data is ready.

## Parameters

```verilog
parameter [31:0] ADDR_MATCH     = 32'h3000_0004;
parameter integer READ_DELAY    = 160;
parameter integer PROGRAM_DELAY = 220;
parameter integer COMPUTE_DELAY = 180;
parameter integer CONFIG_WRITES = 3;
```

`READ_DELAY`, `PROGRAM_DELAY`, and `COMPUTE_DELAY` are simulation delays. They
model the approximate latency of the real RTL/analog-assisted operation using
clock waits such as:

```verilog
repeat (READ_DELAY) @(posedge wb_clk_i);
```

## Initialization And Configuration

After reset, the first three Wishbone writes are always treated as configuration
packets. They are not treated as normal SET/RESET/READ commands.

### Config Packet 0

```verilog
target_set1 = packet[15:0];
target_set2 = packet[31:16];
```

Example:

```verilog
{TARGET_SET2, TARGET_SET1}
```

### Config Packet 1

```verilog
target_reset1 = packet[15:0];
target_reset2 = packet[31:16];
```

Example:

```verilog
{TARGET_RESET2, TARGET_RESET1}
```

### Config Packet 2

```verilog
no_of_clk_cycles = packet[9:0];
counter_value    = packet[19:10];
tdc_time_out     = packet[26:20];
tdc_dead_time    = packet[31:30];
```

Example:

```verilog
{2'b01, 3'b000, 7'd32, 10'd3, 10'd3}
```

## Runtime Reconfiguration

The model can return to configuration mode during normal operation.

Runtime reconfiguration is triggered by this command packet:

```verilog
mode  = 2'b11;  // SET mode
row   = 5'd0;
col   = 5'd0;
bit17 = 1'b1;
```

In packet form:

```verilog
{2'b11, 5'd0, 5'd0, 1'b0, 1'b0, 1'b1, 9'd0, 8'h00}
```

When this packet is received:

1. It is not used to program cell `(0,0)`.
2. The model resets `config_count` to zero.
3. The next three Wishbone writes are consumed as Config0, Config1, and Config2.

## Normal Command Packet Format

After the first three config writes, normal command packets use this layout:

```text
[31:30] mode
[29:25] row
[24:20] column
[19]    status_readback
[18]    full_row
[17]    runtime reconfig trigger
[16:8]  unused/reserved in this model
[7:0]   data_byte
```

The testbench helper packs this as:

```verilog
make_packet(mode, row, col, status_read, full_row, data_byte)
```

which returns:

```verilog
{mode, row, col, status_read, full_row, 10'd0, data_byte}
```

## Command Modes

### RESET Mode

```verilog
mode = 2'b00
```

RESET mode programs the selected cell into a reset-like TDC level. It waits:

```verilog
PROGRAM_DELAY + no_of_clk_cycles
```

Then it stores:

```verilog
cell_level[row,col] = midpoint(target_reset1, target_reset2) + data_byte;
array_state[row][col] = 1'b0;
```

RESET does not produce a Wishbone read result. A later READ command must be sent
to generate a TDC result.

### READ Mode

```verilog
mode = 2'b01
```

READ mode waits:

```verilog
READ_DELAY
```

Then it pushes one or more response words into the response FIFO.

For a single-cell read:

```verilog
full_row = 1'b0;
```

Only `packet[24:20]` is returned.

For a full-row read:

```verilog
full_row = 1'b1;
```

The model returns 32 response words, one for each column in the selected row.

### COMPUTE Mode

```verilog
mode = 2'b10
```

Compute mode waits for three compute packets. The first two packets are stored.
When the third compute packet arrives, the model waits `COMPUTE_DELAY` and
generates result words.

For each selected column, the model adds the packet data bytes for rows whose
stored `array_state` bit is SET.

### SET Mode

```verilog
mode = 2'b11
```

SET mode programs the selected cell into a set-like TDC level. It waits:

```verilog
PROGRAM_DELAY + no_of_clk_cycles
```

Then it stores:

```verilog
cell_level[row,col] = midpoint(target_set1, target_set2) + data_byte;
array_state[row][col] = 1'b1;
```

SET does not produce a Wishbone read result. A later READ command must be sent to
generate a TDC result.

## TDC Result Format

Every normal read result is a 32-bit word:

```verilog
wbs_dat_o = {13'd0, column[4:0], tdc_value[13:0]};
```

Decode it like this:

```verilog
read_column = rdata[18:14];
tdc_value   = rdata[13:0];
```

Bits `[31:19]` are zero for normal TDC result words.

## TDC Value Calculation

The model does not simulate analog circuitry. Instead, it stores a digital
representative TDC level for each cell.

For SET:

```verilog
stored_level = midpoint(target_set1, target_set2) + set_data_byte;
```

For RESET:

```verilog
stored_level = midpoint(target_reset1, target_reset2) + reset_data_byte;
```

For READ:

```verilog
raw_tdc = stored_level + read_data_byte;
```

Then the value is clamped by the configured timeout:

```verilog
timeout_ceiling = {tdc_time_out[5:0], 8'hFF};
tdc_value = (raw_tdc > timeout_ceiling) ? timeout_ceiling : raw_tdc;
```

## Example Using Testbench Config Values

The testbench initially uses:

```verilog
TARGET_SET1   = 16'h0300;
TARGET_SET2   = 16'h0200;
TARGET_RESET1 = 16'h0040;
TARGET_RESET2 = 16'h0080;
```

The midpoints are:

```verilog
SET midpoint   = (16'h0300 + 16'h0200) / 2 = 14'h0280;
RESET midpoint = (16'h0040 + 16'h0080) / 2 = 14'h0060;
```

A simple threshold to classify SET vs RESET is:

```verilog
threshold = (14'h0280 + 14'h0060) / 2 = 14'h0170;
```

After a Wishbone read:

```verilog
tdc_value = rdata[13:0];

if (tdc_value >= 14'h0170)
  cell_state = SET;
else
  cell_state = RESET;
```

For example, SET row `1`, column `3` with data `8'hA5`, then READ row `1`,
column `3` with data `8'h12`:

```verilog
stored_level = 14'h0280 + 8'hA5 = 14'h0325;
tdc_value    = 14'h0325 + 8'h12 = 14'h0337;
wbs_dat_o    = {13'd0, 5'd3, 14'h0337} = 32'h0000_C337;
```

## Status Readback

If a command packet has bit `[19]` set, the next Wishbone read returns status
instead of a TDC FIFO result:

```verilog
wbs_dat_o = {29'd0, status_code};
```

Status codes used by the model:

```verilog
STATUS_OK           = 3'b000;
STATUS_BAD_COMMAND  = 3'b010;
STATUS_COMPUTE_WAIT = 3'b100;
```

Normal TDC reads should keep bit `[19]` low.

## Important Usage Notes

- Always send the three config writes after reset before normal commands.
- SET and RESET only update the modeled cell state and TDC level.
- READ commands generate output data.
- Wishbone bus reads only complete when response data is ready.
- Decode `rdata[18:14]` as column and `rdata[13:0]` as TDC value.
- Do not expect a response word immediately from SET or RESET unless a READ
  command has been sent.

