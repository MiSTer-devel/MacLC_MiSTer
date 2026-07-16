// Apple Sound Chip (ASC) for Mac LC
//
// The Mac LC uses the V8's ASC, which MAME models as asc_v8_device: a MONO,
// FIFO-only chip. Only channel A's FIFO (FIFO[0]) is used; its sample is sent
// to BOTH the left and right outputs. FIFO B and the MODE/CONTROL/CLOCK/
// WTCONTROL registers are no-ops on the V8 (the chip is permanently in FIFO
// mode). FIFO bytes are offset-binary (0x80 = centre); MAME converts with
// (s8)x ^ 0x80, which is what the {~bit7, bits[6:0]} packing below does.
//
// Register file at $F14800-$F1480F, stride 1: register = (addr - 0x800).
// IMPORTANT: the odd-numbered registers (MODE $801, FIFOMODE $803, CLOCK $807)
// live at odd byte addresses, so the top level MUST feed the real A0 into
// `addr` (see MacLC.sv / sim.v: .addr({cpuAddr[11:1], tg68_a[0]})). If A0 is
// dropped, the odd regs alias onto the even reg below them and the boot-chime
// FIFOMODE-clear / MODE-start / FIFOSTAT-poll handshake never completes.
//
// Per docs/plan_040526.md Commit B (Step 3a): the FIFO + sample-output path is
// gated behind `USE_ASC_AUDIO`. When undefined the original register stub
// remains so we can fall back instantly during debugging.

module asc(
	input         clk,
	input         reset,

	// CPU Interface
	input         cs,      // Chip Select (selectASC)
	input  [11:0] addr,    // Offset within ASC window (4 KB), real A0 in addr[0]
	input   [7:0] data_in,
	output  [7:0] data_out,
	input         we,      // Write Enable (!_cpuRW && cpuBusControl)
	input         cpu_as_n,// 68k _AS: low during a bus cycle, high between
	input         uds_n,   // 68k _UDS \ data strobes — assert LATER than _AS on a
	input         lds_n,   // 68k _LDS / write; gate capture on (~uds_n|~lds_n)

	// Sample output (routed to AUDIO_L/R)
	output reg signed [15:0] sample_l,
	output reg signed [15:0] sample_r,
	output reg               sample_tick,

	// Interrupts
	output reg    irq      // Active HIGH (PseudoVIA inverts it)
);

`ifdef USE_ASC_AUDIO

	// ============================================================
	// Mac LC V8 ASC model (MAME asc_v8_device)
	// ============================================================
	//   $800 VERSION (RO, 0xE8)   $801 MODE      $802 CONTROL
	//   $803 FIFOMODE (bit7=clr)  $804 FIFOSTAT  $806 VOLUME   $807 CLOCK
	// ------------------------------------------------------------
	// Sample rate: MAME streams the ASC at 22257 Hz. 32.5 MHz / 22257 ≈ 1460.
	localparam SAMPLE_DIV = 16'd1460;

	// FIFO A storage in forced-M10K BRAM (cd_sdp, rtl/cd_audio.sv). As a plain
	// register array Quartus 17's small-RAM heuristic silently built it from
	// ~8K registers + mux fabric (discovered in the 2026-07-16 LAB-overflow
	// hunt). Read side: fifo_a_q continuously tracks fifo_a[rptr_a] with a
	// 1-cycle lag — invisible at the 22 kHz pop cadence (1460 idle clocks
	// between pops), and a push can only land on the read slot when the FIFO
	// is empty (sample path skipped) or full (push blocked), both guarded.
	wire [7:0] fifo_a_q;
	reg [9:0]  wptr_a, rptr_a;
	reg [10:0] count_a;          // 0..1024
	reg [15:0] sample_div;
	reg [7:0]  regs [0:15];

	// `we` (cpuBusControl) is asserted in several separate bus slots during one
	// CPU access, so edge-detecting cs&&we would push each byte multiple times
	// (stretching FIFO playback). Arm a one-shot per bus cycle using _AS, which
	// deasserts between every access (even back-to-back ones), so exactly one
	// byte is pushed / one register write happens per CPU access.
	// Fire only when a data strobe is asserted (~uds_n | ~lds_n). On a 68k WRITE
	// the data strobes assert LATER than _AS, and this one-shot captures at the
	// FIRST cs&&we cycle (busPhase 0 of the cpu slot) — earlier than Ariel's
	// mem_latch. Without the gate it can latch data_in before the CPU drives it,
	// pushing a stale/zero byte into the FIFO (silent or garbled playback). Same
	// class as the Ariel CLUT bug (commit 6f79571); aggravated by the slot-00
	// reclaim (90c7696) which gave the CPU an earlier DTACK slot. The one-shot
	// disarms on we_stb (the SAME gated condition) so an early strobe-less cycle
	// can't disarm-without-firing and drop the write.
	reg  asc_armed;
	wire we_stb = asc_armed && cs && we && !cpu_as_n && (~uds_n | ~lds_n);
	always @(posedge clk) begin
		if (reset)         asc_armed <= 1'b1;
		else if (cpu_as_n) asc_armed <= 1'b1; // bus cycle ended → re-arm
		else if (we_stb)   asc_armed <= 1'b0; // captured this cycle's write
	end

	cd_sdp #(.DW(8), .AW(10)) fifo_a_ram (
		.clock(clk),
		.waddr(wptr_a), .wdata(data_in), .wr(fifo_a_push),
		.raddr(rptr_a), .q(fifo_a_q)
	);

	wire fifo_a_write = we_stb && (addr < 12'h400);
	// FIFO B ($400-$7FF) writes are ignored on the V8.
	wire reg_write    = we_stb && (addr >= 12'h800) && (addr <= 12'h80F);
	wire reg_read     = cs && !we && (addr >= 12'h800) && (addr <= 12'h80F);

	// FIFOMODE ($803) bit7 clears the FIFO.
	wire fifo_clear   = reg_write && (addr[3:0] == 4'h3) && data_in[7];

	wire pop_tick     = (sample_div == SAMPLE_DIV - 1);
	wire pop_a        = pop_tick && (count_a != 0);
	wire fifo_a_push  = fifo_a_write && (count_a < 1024) && !fifo_clear;

	// Live FIFO A status byte ($804): bit0 = STAT_HALF_FULL_A (half-empty),
	// bit1 = STAT_EMPTY_OR_FULL_A. Per MAME asc_v8, bit1 is set when the FIFO is
	// EMPTY (cap==0) OR FULL (cap>=0x3ff) — the ROM FIFO POST ($A45F2C) fills the
	// FIFO and spins until bit1 reports FULL, so bit1 must include the full case.
	wire [7:0] fifo_stat = {6'b0,
	                        (count_a == 0) || (count_a >= 11'd1023),
	                        (count_a < 512)};

	integer i;
	always @(posedge clk) begin
		sample_tick <= 1'b0;

		if (reset) begin
			wptr_a <= 0; rptr_a <= 0; count_a <= 0;
			sample_div <= 0;
			sample_l <= 0;
			sample_r <= 0;
			irq <= 0;
			for (i = 0; i < 16; i = i + 1) regs[i] <= 8'h00;
			regs[0] <= 8'hE8; // Version (RO)
		end else begin
			// Sample-rate divider + FIFO A pop (MONO: same sample to L and R).
			if (pop_tick) begin
				sample_div  <= 0;
				sample_tick <= 1'b1;
				if (count_a != 0) begin
					sample_l <= {~fifo_a_q[7], fifo_a_q[6:0], 8'h00};
					sample_r <= {~fifo_a_q[7], fifo_a_q[6:0], 8'h00};
				end
				// when empty, hold the last sample (matches MAME asc_v8)
			end else begin
				sample_div <= sample_div + 1'b1;
			end

			// FIFO A pointer / count management (single driver each).
			if (fifo_clear) begin
				wptr_a <= 0; rptr_a <= 0; count_a <= 0;
			end else begin
				if (fifo_a_push) begin
					wptr_a <= wptr_a + 1'b1;
				end
				if (pop_a)
					rptr_a <= rptr_a + 1'b1;
				case ({fifo_a_push, pop_a})
					2'b10: count_a <= count_a + 1'b1;
					2'b01: count_a <= count_a - 1'b1;
					default: ; // 00 / 11 → no net change
				endcase
			end

			// Register writes. VERSION + FIFOSTAT are read-only; MODE/CONTROL/
			// CLOCK/WTCONTROL are no-ops on the V8 but harmless to store.
			if (reg_write) begin
				case (addr[3:0])
					4'h0: ; // Version RO
					4'h4: ; // FIFOSTAT RO
					default: regs[addr[3:0]] <= data_in;
				endcase
			end

			// IRQ: half-empty FIFO A. MAME re-evaluates this once per OUTPUT
			// SAMPLE (in sound_stream_update), not every clock. Re-asserting every
			// clock would re-interrupt the CPU before its ISR can RTE — an
			// interrupt storm that hangs the boot once the chime driver unmasks
			// the ASC IRQ. So only (re)assert on the sample tick; a FIFOSTAT read
			// clears it and it then stays low until the next tick (~1460 clocks).
			if (reg_read && addr[3:0] == 4'h4)
				irq <= 1'b0;
			else if (pop_tick && (count_a < 512))
				irq <= 1'b1;
		end
	end

	reg [7:0] data_out_reg;
	always @(*) begin
		data_out_reg = 8'h00;
		if (addr >= 12'h800 && addr <= 12'h80F) begin
			// V8 register reads are HARDWIRED (MAME asc_v8::read): MODE/CONTROL/
			// FIFOMODE always read 1; WTCONTROL/CLOCK/BATMANCONTROL always read 0;
			// VERSION=0xE8; FIFOSTAT is live. The chip IGNORES writes to MODE/
			// CONTROL/FIFOMODE, so the old `default: regs[...]` (returning the last
			// written value, or 0) diverged from real V8 hardware — a Sound Manager
			// setup/poll loop that reads MODE/CONTROL/FIFOMODE waiting for the fixed
			// V8 value would spin forever on our readback (hung sound cdev).
			case (addr[3:0])
				4'h0:    data_out_reg = 8'hE8;        // VERSION
				4'h1:    data_out_reg = 8'h01;        // MODE       (V8: always 1)
				4'h2:    data_out_reg = 8'h01;        // CONTROL    (V8: always 1)
				4'h3:    data_out_reg = 8'h01;        // FIFOMODE   (V8: always 1)
				4'h4:    data_out_reg = fifo_stat;    // FIFOSTAT (live)
				4'h5:    data_out_reg = 8'h00;        // WTCONTROL  (V8: always 0)
				4'h7:    data_out_reg = 8'h00;        // CLOCK      (V8: always 0)
				4'h8:    data_out_reg = 8'h00;        // BATMANCTRL (V8: always 0)
				default: data_out_reg = regs[addr[3:0]]; // VOLUME(6)/PLAYRECA(A)/...
			endcase
		end
	end
	assign data_out = data_out_reg;

`else

	// ============================================================
	// Original register stub (USE_ASC_AUDIO undefined)
	// ============================================================
	// Sample outputs are tied off; the legacy DMA path in
	// dataController_top is still driving AUDIO_L/R until Commit C.
	always @(*) begin
		sample_l    = 16'sd0;
		sample_r    = 16'sd0;
		sample_tick = 1'b0;
	end

	reg [7:0] regs [0:15];
	reg [10:0] fifo_count;
	reg [9:0]  tick_div;
	reg [7:0]  fifo_stat;

	always @(posedge clk) begin
		tick_div <= tick_div + 1'b1;

		if (reset) begin
			irq <= 0;
			fifo_count <= 0;
			fifo_stat <= 8'h05;
			regs[0] <= 8'hE8;
			regs[1] <= 0;
			regs[2] <= 0;
		end else begin
			fifo_stat[0] <= (fifo_count < 1024);
			fifo_stat[1] <= (fifo_count >= 1024);
			fifo_stat[2] <= (fifo_count < 1024);
			fifo_stat[3] <= (fifo_count >= 1024);

			if (cs) begin
				if (we) begin
					if (addr < 12'h800) begin
						if (fifo_count < 1024) fifo_count <= fifo_count + 1'b1;
					end
					else if (addr >= 12'h800 && addr <= 12'h80F) begin
						case (addr[3:0])
							4'h0: ;
							4'h1: begin
								regs[1] <= data_in;
								if (data_in == 1 && fifo_count == 0) irq <= 1;
								else irq <= 0;
							end
							4'h4: ;
							default: regs[addr[3:0]] <= data_in;
						endcase
					end
				end else begin
					if (addr == 12'h804) irq <= 0;
				end
			end
			else if (tick_div == 0 && fifo_count > 0) begin
				fifo_count <= fifo_count - 1'b1;
			end
		end
	end

	reg [7:0] data_out_reg;
	always @(*) begin
		if (addr >= 12'h800 && addr <= 12'h80F) begin
			case (addr[3:0])
				4'h0:    data_out_reg = 8'hE8;
				4'h4:    data_out_reg = fifo_stat;
				default: data_out_reg = regs[addr[3:0]];
			endcase
		end else begin
			data_out_reg = 8'h00;
		end
	end
	assign data_out = data_out_reg;

`endif

`ifdef SIMULATION
	// ------------------------------------------------------------------
	// Diagnostic trace (sim only). One line per CPU register write (rising
	// edge of cs&&we), decoding MODE/FIFOMODE/CLOCK, plus a running FIFO-A/B
	// write count. Also tracks the peak output amplitude and non-zero sample
	// count so we can confirm the chime is actually reaching AUDIO_L/R.
	// ------------------------------------------------------------------
	reg         dbg_armed;
	reg  [31:0] dbg_fifo_a_cnt, dbg_fifo_b_cnt;
	reg  [15:0] dbg_peak;
	reg  [31:0] dbg_nonzero_samples;
	wire [15:0] dbg_abs_l = sample_l[15] ? (~sample_l + 1'b1) : sample_l;
	always @(posedge clk) begin
		if (reset) begin
			dbg_armed           <= 1'b1;
			dbg_fifo_a_cnt      <= 0;
			dbg_fifo_b_cnt      <= 0;
			dbg_peak            <= 0;
			dbg_nonzero_samples <= 0;
		end else begin
			if (cpu_as_n)      dbg_armed <= 1'b1;
			else if (cs && we) dbg_armed <= 1'b0;
			if (dbg_armed && cs && we && !cpu_as_n) begin
				if (addr < 12'h400)
					dbg_fifo_a_cnt <= dbg_fifo_a_cnt + 1'b1;
				else if (addr < 12'h800)
					dbg_fifo_b_cnt <= dbg_fifo_b_cnt + 1'b1;
				else if (addr <= 12'h80F) begin
					$display("ASC-WR off=%03h reg=%0d data=%02h  [fifoA_wr=%0d fifoB_wr=%0d] @%0t",
						addr, addr[3:0], data_in, dbg_fifo_a_cnt, dbg_fifo_b_cnt, $time);
					if (addr[3:0] == 4'h1) $display("ASC-MODE = %0d  (V8 ignores; always FIFO)", data_in[1:0]);
					if (addr[3:0] == 4'h3) $display("ASC-FIFOMODE = %02h  (bit7=clear FIFO)", data_in);
					if (addr[3:0] == 4'h7) $display("ASC-CLOCK = %0d  (0=22257 2=22050 3=44100)", data_in);
				end
			end
			if (sample_tick) begin
				if (sample_l != 0) dbg_nonzero_samples <= dbg_nonzero_samples + 1'b1;
				if (dbg_abs_l > dbg_peak) begin
					dbg_peak <= dbg_abs_l;
					$display("ASC-AUDIO peak=%0d nonzero_samples=%0d @%0t", dbg_abs_l, dbg_nonzero_samples, $time);
				end
			end
		end
	end
`endif

endmodule
