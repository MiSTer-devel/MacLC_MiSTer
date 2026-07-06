// pll_video.v — dedicated pixel-clock PLL for the Mac LC V8 scanout.
//
// The V8 previously scanned out at clk_sys/2 = 16.25 MHz in EVERY monitor mode,
// which made VGA 640x480 (800x525 total) refresh at 38.7 Hz instead of 59.94.
// A fractional (Bresenham) CE off clk_sys was tried and reverted (shaky image
// through the scaler — see maclc_v8_video.sv); the correct fix is a real pixel
// clock. One extra fractional-N PLL provides all three monitor rates from a
// single VCO (~704.9 MHz = 50 MHz x 14.098):
//
//   outclk_0  /28 = 25.175000 MHz  VGA 640x480      -> 59.94 Hz (exact)
//   outclk_1  /45 = 15.664444 MHz  12" RGB 512x384  -> 60.14 Hz (real LC:
//                                  15.6672 MHz / 60.15 Hz, -180 ppm)
//   outclk_2  /12 = 58.741667 MHz  Portrait 640x870 -> 76.9 Hz (real:
//                                  57.2832 MHz / 75 Hz, +2.5% — was 21 Hz!)
//
// The scanout clock is selected per monitor_id by a cyclonev_clkselect in
// MacLC.sv. CPU/SDRAM stay on the main PLL — nothing but scanout moves.
// FPGA-only: verilator/sim.v keeps the old clk_sys/2 enable (see pix_ce).

`timescale 1 ps / 1 ps
module pll_video (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0, // 25.175 MHz — VGA
	output wire outclk_1, // 15.664 MHz — 12" RGB
	output wire outclk_2, // 58.742 MHz — Portrait
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("25.175000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("15.664444 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("58.741667 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst      (rst),
		.outclk   ({outclk_2, outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk ( ),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);
endmodule
