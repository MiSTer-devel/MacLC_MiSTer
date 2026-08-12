/* tb_scc_midi.v — unit test for MIDI-over-SCC: the WR11/TRxC clock path.
 *
 * WHY THIS EXISTS (2026-08-12): Mac MIDI interfaces feed a 1 MHz clock into
 * the serial port's HSKi pin (wired to the SCC's TRxC input) and drivers
 * program WR11=$28 (RX+TX clock from TRxC) + WR4=$84 (x32) for 31,250 baud,
 * with the BRG DISABLED. Before the WR11 fix scc.v dropped WR11 entirely and
 * the BRG-off fallback ran the serializers at 9600 baud — precisely the path
 * every MIDI driver exercises. The fix emulates a permanently-attached 1 MHz
 * TRxC source: clocks_per_baud = 32.5 * mult (x32 -> 1040 exactly @ 32.5 MHz).
 *
 * WHAT IT CHECKS (channel A = modem port, where Mac MIDI software defaults):
 *   1. MIDI recipe (WR9 reset, WR4=$84, WR3=$C1, WR5=$68, WR11=$28, WR14=$00):
 *      TX bit period == 1040 clk +/-2 (measured edge-to-edge on $55).
 *   2. TX framing: mid-bit reconstruction of an asymmetric byte, LSB-first,
 *      8N1, and a 3-byte MIDI Note-On ($90 $3C $40) paced by RR0 TX-empty.
 *   3. RX: a framed byte driven into rxd at 1040 clk/bit lands in the FIFO
 *      (RR0 bit0), reads back via the data port, raises the RX IRQ with
 *      WR1=$10 + WR9 MIE, and the IRQ/avail clear after the read. FIFO
 *      order preserved for 2 queued bytes.
 *   4. REGRESSION: WR11=$50 (BRG-sourced) + WR14[0]=1 still uses the BRG
 *      divider (WR12=$0A/WR13=0/x16 -> 3387 clk/bit) — the TRxC clause must
 *      not hijack BRG users (console/PPP/LocalTalk-era behavior unchanged).
 *   5. PRIORITY: WR11=$28 with WR14[0] STILL 1 -> 1040 clk/bit (WR11 source
 *      selection wins over the BRG enable, as on real hardware).
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps -I../rtl \
 *     --Mdir /tmp/obj_sccmidi --top-module tb_scc_midi tb_scc_midi.v \
 *     ../rtl/scc.v ../rtl/uart/txuart.v ../rtl/uart/rxuart.v
 *   /tmp/obj_sccmidi/Vtb_scc_midi
 * PASS criterion: last line "RESULT: PASS", exit 0.
 */

`timescale 1ns/1ps

module tb_scc_midi;

	reg clk = 0;
	always #15.384 clk = ~clk;          // ~32.5 MHz = clk_sys

	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 1'b1;
	wire cep = (phase == 2'd0);         // ~8.1 MHz enables, like clk8_en_p/n
	wire cen = (phase == 2'd2);

	reg        reset_hw = 1;
	reg        cs = 0, we = 0;
	reg  [1:0] rs = 0;
	reg  [7:0] wdata = 0;
	wire [7:0] rdata;
	wire       _irq;
	reg        rxd = 1;
	wire       txd;
	wire       rts;

	scc dut (
		.clk(clk), .cep(cep), .cen(cen), .rtxc_en(1'b0),
		.reset_hw(reset_hw),
		.cs(cs), .we(we), .rs(rs), .wdata(wdata), .rdata(rdata),
		._irq(_irq),
		.rxd(rxd), .txd(txd), .cts(1'b1), .rts(rts),
		.rxd_b(1'b1), .txd_b_out(),
		.dcd_a(1'b1), .dcd_b(1'b1),
		.wreq()
	);

	integer errors = 0;
	reg [31:0] clkcnt = 0;
	always @(posedge clk) clkcnt <= clkcnt + 1;

	localparam integer CPB_MIDI = 1040;  // 32.5e6 / 31250
	localparam integer CPB_BRG  = 3387;  // 2*(10+2)*16 * 1129/128 (WR12=$0A, x16)

	// ------------------------------------------------------------------
	// Bus helpers (mimic dataController: CS window spanning >=2 cen pulses;
	// cs_access_done consumes each access exactly once)
	// ------------------------------------------------------------------
	task bus_write(input [1:0] rsel, input [7:0] val);
		begin
			@(negedge clk);
			rs = rsel; wdata = val; we = 1; cs = 1;
			repeat (10) @(posedge clk);
			@(negedge clk);
			cs = 0; we = 0;
			repeat (10) @(posedge clk);
		end
	endtask

	task bus_read(input [1:0] rsel, output [7:0] val);
		begin
			@(negedge clk);
			rs = rsel; we = 0; cs = 1;
			repeat (10) @(posedge clk);
			val = rdata;
			@(negedge clk);
			cs = 0;
			repeat (10) @(posedge clk);
		end
	endtask

	// Write channel A register: pointer write, then value write
	task wreg_ch_a(input [3:0] r, input [7:0] val);
		begin
			bus_write(2'b01, {4'd0, r});
			bus_write(2'b01, val);
		end
	endtask

	// Read RR0 of channel A (pointer rests at 0 between accesses)
	task rd_rr0_a(output [7:0] val);
		begin
			bus_read(2'b01, val);
		end
	endtask

	task rd_data_a(output [7:0] val);
		begin
			bus_read(2'b11, val);
		end
	endtask

	// Poll RR0 until TX buffer empty (bit 2), bounded. The guard must cover
	// txuart's 16-baud-interval post-reset guard time (every WR4/5/11-14
	// write pulses the txuart reset): 16*3387 = ~54k clk at the slowest rate
	// tested here; 4000 polls * ~31 clk ≈ 124k clk. Real drivers poll RR0
	// exactly like this, so the guard time is invisible to them.
	task wait_tx_empty;
		reg [7:0] v;
		integer guard;
		begin
			guard = 0;
			v = 0;
			while (!v[2] && guard < 4000) begin
				rd_rr0_a(v);
				guard = guard + 1;
			end
			if (!v[2]) begin
				errors = errors + 1;
				$display("TB_FAIL: RR0 TX-empty never set (RR0=%02x)", v);
			end
		end
	endtask

	// ------------------------------------------------------------------
	// TX measurement helpers
	// ------------------------------------------------------------------

	// Drain the TX path completely after register (re)programming: RR0 bit2
	// is TX-BUFFER-empty (correct SCC semantics), which reads 1 while the
	// shifter still sits in txuart's 16-baud post-reset guard — a byte
	// written then is accepted but appears up to 16 bit-times later. Flush
	// with a throwaway byte, then require the line high for 3 bit-times and
	// the buffer empty, so a subsequent write starts its frame immediately.
	task tx_quiesce(input integer cpb);
		integer guard;
		begin
			wait_tx_empty;
			bus_write(2'b11, 8'hFF);   // throwaway flush byte: exactly one low
			                           // (start) bit, data+stop all high
			guard = 0;                 // wait for its start edge. The 16-baud
			                           // post-reset guard runs at the OLD baud
			                           // (txuart latches i_setup only when busy
			                           // drops), so bound this in absolute
			                           // clocks: 16*3387 = ~54k worst case here.
			while (txd === 1'b1 && guard < cpb*40 + 200000) begin
				@(posedge clk);
				guard = guard + 1;
			end
			if (txd === 1'b1) begin
				errors = errors + 1;
				$display("TB_FAIL: quiesce flush byte never started");
			end
			repeat (cpb*11) @(posedge clk);   // ride out the full frame + margin
			wait_tx_empty;
		end
	endtask

	// Write $55 to the data port and measure the 9 edge-to-edge intervals
	// (start->d0, d0->d1, ... d7->stop): $55 LSB-first toggles at every bit
	// boundary, so each interval is exactly one bit period.
	task tx_period_check(input integer expect_cpb, input [8*24-1:0] label);
		integer i;
		integer t_prev;
		integer delta;
		reg lastv;
		integer guard;
		integer errors0;
		begin
			errors0 = errors;
			// fully drain shifter + guard time so the measured frame starts
			// promptly after the write
			tx_quiesce(expect_cpb);
			if (txd !== 1'b1) begin
				errors = errors + 1;
				$display("TB_FAIL[%0s]: txd not idle before write", label);
			end
			bus_write(2'b11, 8'h55);
			// catch the start-bit falling edge (may already be low: the write
			// strobe fires mid-CS-window; with >=520-clk bits the skew from
			// polling late is < 30 clk and does not affect edge deltas)
			guard = 0;
			while (txd === 1'b1 && guard < expect_cpb*4) begin
				@(posedge clk); guard = guard + 1;
			end
			if (txd === 1'b1) begin
				errors = errors + 1;
				$display("TB_FAIL[%0s]: no start bit seen", label);
			end else begin
				t_prev = clkcnt;
				lastv = 0;
				for (i = 0; i < 9; i = i + 1) begin
					guard = 0;
					while (txd === lastv && guard < expect_cpb*3) begin
						@(posedge clk); guard = guard + 1;
					end
					delta = clkcnt - t_prev;
					t_prev = clkcnt;
					lastv = ~lastv;
					// first interval measured from a late-caught start edge is
					// only checked loosely; intervals 1..8 are exact
					if (i == 0) begin
						if (delta > expect_cpb + 40 || delta < expect_cpb - 40) begin
							errors = errors + 1;
							$display("TB_FAIL[%0s]: start-bit width %0d, expected ~%0d", label, delta, expect_cpb);
						end
					end else if (delta > expect_cpb + 3 || delta < expect_cpb - 3) begin
						errors = errors + 1;
						$display("TB_FAIL[%0s]: bit %0d period %0d, expected %0d", label, i, delta, expect_cpb);
					end
				end
				if (errors == errors0)
					$display("TB_INFO[%0s]: bit period OK (~%0d clk/bit)", label, expect_cpb);
			end
			// let stop bit + line settle
			repeat (expect_cpb*3) @(posedge clk);
		end
	endtask

	// Write a byte, reconstruct it by mid-bit sampling at the expected rate
	task tx_frame_check(input [7:0] val, input integer expect_cpb);
		integer i;
		integer guard;
		reg [7:0] got;
		begin
			wait_tx_empty;
			bus_write(2'b11, val);
			guard = 0;
			while (txd === 1'b1 && guard < expect_cpb*4) begin
				@(posedge clk); guard = guard + 1;
			end
			if (txd === 1'b1) begin
				errors = errors + 1;
				$display("TB_FAIL: no start bit for frame %02x", val);
			end else begin
				// sample mid-bit: from (late-caught) start edge, d[i] center is
				// at (i+1.5) bit times
				repeat (expect_cpb + expect_cpb/2) @(posedge clk);
				for (i = 0; i < 8; i = i + 1) begin
					got[i] = txd;
					if (i != 7) repeat (expect_cpb) @(posedge clk);
				end
				// stop bit
				repeat (expect_cpb) @(posedge clk);
				if (txd !== 1'b1) begin
					errors = errors + 1;
					$display("TB_FAIL: stop bit low for frame %02x", val);
				end
				if (got !== val) begin
					errors = errors + 1;
					$display("TB_FAIL: TX frame %02x read back as %02x", val, got);
				end else
					$display("TB_INFO: TX frame %02x OK", val);
			end
			repeat (expect_cpb*2) @(posedge clk);
		end
	endtask

	// ------------------------------------------------------------------
	// RX driver
	// ------------------------------------------------------------------
	task send_rx_byte(input [7:0] val, input integer cpb);
		integer i;
		begin
			rxd = 0;                                   // start
			repeat (cpb) @(posedge clk);
			for (i = 0; i < 8; i = i + 1) begin
				rxd = val[i];                          // LSB first
				repeat (cpb) @(posedge clk);
			end
			rxd = 1;                                   // stop
			repeat (cpb * 2) @(posedge clk);
		end
	endtask

	reg [7:0] v;
	reg [7:0] v2;
	integer k;

	initial begin
		$display("TB: tb_scc_midi start");
		repeat (40) @(posedge clk);
		reset_hw = 0;
		repeat (100) @(posedge clk);

		// -------- MIDI recipe (the TinkerDifferent/Apple-driver sequence) ----
		wreg_ch_a(9, 8'hC0);     // force hardware reset
		repeat (60) @(posedge clk);
		wreg_ch_a(4, 8'h84);     // x32 clock mode, 1 stop bit, no parity
		wreg_ch_a(3, 8'hC1);     // RX 8 bits/char, RX enable
		wreg_ch_a(5, 8'h68);     // TX 8 bits/char, TX enable
		wreg_ch_a(11, 8'h28);    // RX and TX clock = TRxC pin (the MIDI clock)
		wreg_ch_a(14, 8'h00);    // BRG off — the path that used to fall to 9600
		wreg_ch_a(1, 8'h10);     // int on all RX chars
		wreg_ch_a(9, 8'h08);     // MIE (no reset bits)
		repeat (60) @(posedge clk);

		// -------- 1. bit period == 1040 --------
		tx_period_check(CPB_MIDI, "MIDI-31250");

		// -------- 2. framing + a real MIDI message --------
		tx_frame_check(8'hB6, CPB_MIDI);
		tx_frame_check(8'h90, CPB_MIDI);  // Note On, ch 0
		tx_frame_check(8'h3C, CPB_MIDI);  // middle C
		tx_frame_check(8'h40, CPB_MIDI);  // velocity 64

		// -------- 3. RX -> FIFO -> IRQ --------
		if (_irq !== 1'b1) begin
			errors = errors + 1;
			$display("TB_FAIL: _irq active before any RX");
		end
		send_rx_byte(8'hF8, CPB_MIDI);           // MIDI clock byte
		repeat (100) @(posedge clk);
		if (_irq !== 1'b0) begin
			errors = errors + 1;
			$display("TB_FAIL: RX IRQ not asserted (WR1=$10, MIE on)");
		end
		rd_rr0_a(v);
		if (!v[0]) begin
			errors = errors + 1;
			$display("TB_FAIL: RR0 rx-available clear after RX byte (RR0=%02x)", v);
		end
		rd_data_a(v);
		if (v !== 8'hF8) begin
			errors = errors + 1;
			$display("TB_FAIL: RX byte read %02x, expected F8", v);
		end else
			$display("TB_INFO: RX byte F8 OK, IRQ asserted");
		repeat (100) @(posedge clk);
		rd_rr0_a(v);
		if (v[0]) begin
			errors = errors + 1;
			$display("TB_FAIL: RR0 rx-available stuck after read (RR0=%02x)", v);
		end
		if (_irq !== 1'b1) begin
			errors = errors + 1;
			$display("TB_FAIL: RX IRQ stuck after FIFO drained");
		end

		// FIFO order for two queued bytes
		send_rx_byte(8'h91, CPB_MIDI);
		send_rx_byte(8'h45, CPB_MIDI);
		repeat (100) @(posedge clk);
		rd_data_a(v);
		rd_data_a(v2);
		if (v !== 8'h91 || v2 !== 8'h45) begin
			errors = errors + 1;
			$display("TB_FAIL: FIFO order got %02x,%02x expected 91,45", v, v2);
		end else
			$display("TB_INFO: RX FIFO order OK");

		// -------- 4. regression: BRG-sourced clocking unchanged --------
		wreg_ch_a(11, 8'h50);    // RX and TX clock = BRG output
		wreg_ch_a(4, 8'h44);     // x16, 1 stop
		wreg_ch_a(12, 8'h0A);    // N=10 -> cpb = 2*(10+2)*16 * 1129/128 = 3387
		wreg_ch_a(13, 8'h00);
		wreg_ch_a(14, 8'h01);    // BRG on
		repeat (60) @(posedge clk);
		wait_tx_empty;
		tx_period_check(CPB_BRG, "BRG-regress");

		// -------- 5. priority: TRxC wins over an enabled BRG --------
		wreg_ch_a(4, 8'h84);     // back to x32
		wreg_ch_a(11, 8'h28);    // TRxC — WR14[0] still 1
		repeat (60) @(posedge clk);
		wait_tx_empty;
		tx_period_check(CPB_MIDI, "TRxC-over-BRG");

		if (errors == 0) $display("RESULT: PASS");
		else begin
			$display("RESULT: FAIL %0d errors", errors);
			$stop;
		end
		$finish;
	end

	// global watchdog
	initial begin
		repeat (30_000_000) @(posedge clk);
		$display("TB_FAIL: global watchdog expired");
		$display("RESULT: FAIL (watchdog)");
		$stop;
	end

endmodule
