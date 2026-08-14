/* tb_scc_baud.v — CAPTURE TOOL (not a pass/fail gate): sweep the standard Mac
 * Serial Driver baud time-constants through the real scc.v BRG path and
 * measure the resulting TX wire rate (clocks/bit @ 32.5 MHz). Answers "which
 * PPP-relevant bauds does our baud path honor, and which hit the ROM-selftest
 * special-cases at scc.v:1610-1629?" — offline, deterministic, no PPP client.
 *
 * Mac Serial Driver programs async 8N1, x16 clock, BRG-sourced (WR11=$50),
 * WR14=$01 (BRG enable). Time constant TC = 3.6864e6/(32*baud) - 2, written to
 * WR12 (WR13=0 for all these rates). Ideal wire rate = 32.5e6/baud.
 *
 * Build + run (from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps -I../rtl \
 *     --Mdir /tmp/obj_baud --top-module tb_scc_baud tb_scc_baud.v \
 *     ../rtl/scc.v ../rtl/uart/txuart.v ../rtl/uart/rxuart.v
 *   /tmp/obj_baud/Vtb_scc_baud
 */
`timescale 1ns/1ps
module tb_scc_baud;
	reg clk = 0; always #15.384 clk = ~clk;      // ~32.5 MHz
	reg [1:0] phase = 0; always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);
	wire cen = (phase == 2'd2);

	reg reset_hw = 1, cs = 0, we = 0; reg [1:0] rs = 0; reg [7:0] wdata = 0;
	wire [7:0] rdata; wire _irq, txd, rts; reg rxd = 1;
	scc dut (.clk(clk), .cep(cep), .cen(cen), .rtxc_en(1'b0), .reset_hw(reset_hw),
		.cs(cs), .we(we), .rs(rs), .wdata(wdata), .rdata(rdata), ._irq(_irq),
		.rxd(rxd), .txd(txd), .cts(1'b1), .rts(rts),
		.rxd_b(1'b1), .txd_b_out(), .dcd_a(1'b1), .dcd_b(1'b1), .wreq());

	reg [31:0] clkcnt = 0; always @(posedge clk) clkcnt <= clkcnt + 1;

	task bus_write(input [1:0] rsel, input [7:0] val);
		begin @(negedge clk); rs=rsel; wdata=val; we=1; cs=1;
			repeat (10) @(posedge clk); @(negedge clk); cs=0; we=0;
			repeat (10) @(posedge clk); end
	endtask
	task bus_read(input [1:0] rsel, output [7:0] val);
		begin @(negedge clk); rs=rsel; we=0; cs=1;
			repeat (10) @(posedge clk); val=rdata; @(negedge clk); cs=0;
			repeat (10) @(posedge clk); end
	endtask
	task wreg(input [3:0] r, input [7:0] val);
		begin bus_write(2'b01, {4'd0, r}); bus_write(2'b01, val); end
	endtask
	task wait_tx_empty; reg [7:0] v; integer g; begin g=0; v=0;
		while (!v[2] && g<6000) begin bus_read(2'b01, v); g=g+1; end end
	endtask

	// Measure one bit period: send $55 (toggles every bit), time d0->d1 (exact).
	task measure(input [15:0] baud, input [7:0] tc, input integer ideal);
		integer i, tprev, delta, meas; reg last; integer g;
		begin
			wreg(9, 8'hC0); repeat (60) @(posedge clk);   // hw reset
			wreg(4, 8'h44);                                // x16, 1 stop, no par
			wreg(3, 8'hC1); wreg(5, 8'h68);                // RX/TX enable
			wreg(11, 8'h50);                               // clocks from BRG
			wreg(12, tc); wreg(13, 8'h00);
			wreg(14, 8'h01);                               // BRG enable
			repeat (70000) @(posedge clk);                 // ride out reset guard
			wait_tx_empty;
			bus_write(2'b11, 8'h55);
			g=0; while (txd===1'b1 && g<ideal*4+200000) begin @(posedge clk); g=g+1; end
			// skip start bit, then measure one full data-bit interval
			last=1'b0; tprev=clkcnt; meas=0;
			for (i=0;i<2;i=i+1) begin
				g=0; while (txd===last && g<ideal*4+300000) begin @(posedge clk); g=g+1; end
				if (i==1) meas = clkcnt - tprev; tprev=clkcnt; last=~last;
			end
			$display("BAUD %6d | WR12=%02x | measured %6d clk/bit | ideal %6d | %s",
				baud, tc, meas, ideal,
				(meas>ideal-ideal/16 && meas<ideal+ideal/16) ? "OK" : "*** WRONG ***");
			repeat (ideal*3) @(posedge clk);
		end
	endtask

	initial begin
		$display("== tb_scc_baud: Mac Serial Driver baud sweep through real scc.v ==");
		repeat (40) @(posedge clk); reset_hw=0; repeat (100) @(posedge clk);
		measure(16'd9600,  8'h0A, 3385);
		measure(16'd19200, 8'h04, 1693);
		measure(16'd38400, 8'h01,  846);
		measure(16'd57600, 8'h00,  564);
		$display("== end ==");
		$finish;
	end
	initial begin repeat (60000000) @(posedge clk); $display("WATCHDOG"); $finish; end
endmodule
