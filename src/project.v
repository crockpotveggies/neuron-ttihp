/*
 * Copyright (c) 2024 Justin
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_crockpotveggies_neuron (
`ifdef USE_POWER_PINS
    input  wire VGND,
    input  wire VPWR,
`endif
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // design enabled
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  neuron u_neuron (
`ifdef USE_POWER_PINS
      .VGND(VGND),
      .VPWR(VPWR),
`endif
      .ui_in(ui_in),
      .uo_out(uo_out),
      .uio_in(uio_in),
      .uio_out(uio_out),
      .uio_oe(uio_oe),
      .ena(ena),
      .clk(clk),
      .rst_n(rst_n)
  );

endmodule
