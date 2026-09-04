/* altddio_out_stub.v — behavioural stand-in for the Altera altddio_out megafunction.
 *
 * rtl/sdram.v instantiates altddio_out to generate the SDRAM clock as a DDR
 * output (rising edge low, falling edge high = a clock shifted 180 deg). The
 * full sim (verilator/sim.v) never needs this because it swaps in sim_ram.v,
 * but any testbench that instantiates the REAL controller does.
 *
 * Only the clock-forwarding case is modelled: dataout follows datain_h while
 * outclock is high and datain_l while it is low. Nothing in a TB samples the
 * SDRAM clock, so this only has to exist and be well-typed.
 */

`timescale 1ns/1ps

module altddio_out #(
	parameter extend_oe_disable    = "OFF",
	parameter intended_device_family = "Cyclone V",
	parameter invert_output        = "OFF",
	parameter lpm_hint             = "UNUSED",
	parameter lpm_type             = "altddio_out",
	parameter oe_reg               = "UNREGISTERED",
	parameter power_up_high        = "OFF",
	parameter width                = 1
) (
	input  [width-1:0] datain_h,
	input  [width-1:0] datain_l,
	input              outclock,
	input              outclocken,
	input              aclr,
	input              aset,
	input              sclr,
	input              sset,
	input              oe,
	output [width-1:0] dataout
);

assign dataout = outclock ? datain_h : datain_l;

endmodule
