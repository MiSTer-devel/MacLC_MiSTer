//
// sdram.v
//
// sdram controller implementation for the MiST board
// 
// Copyright (c) 2015 Till Harbaum <till@harbaum.org> 
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram 
(
	// interface to the MT48LC16M16 chip
	output              sd_clk,
	inout  reg [15:0]   sd_data,    // 16 bit bidirectional data bus
	output reg [12:0]   sd_addr,    // 13 bit multiplexed address bus
	output     [1:0]    sd_dqm,     // two byte masks
	output reg [1:0]    sd_ba,      // two banks
	output              sd_cs,      // a single chip select
	output              sd_we,      // write enable
	output              sd_ras,     // row address select
	output              sd_cas,     // columns address select

	// cpu/chipset interface
	input               init,       // init signal after FPGA config to initialize RAM
	input               clk_64,     // sdram is accessed at 64MHz
	input               clk_8,      // 8MHz chipset clock to which sdram state machine is synchonized

	input [15:0]        din,        // data input from chipset/cpu
	output reg [15:0]   dout,       // data output to chipset/cpu (floppy-window reads)
	input [23:0]        addr,       // 24 bit word address
	input [1:0]         ds,         // upper/lower data strobe
	input               oe,         // cpu/chipset requests read
	input               we,         // cpu/chipset requests write

	// ── demand-start CPU service (Phase C, branch cpu-enhancements) ────────
	// oe/we + addr/din/ds form a LEVEL request (held while _cpuAS is low, or
	// while a download write is presented). The sequencer starts an access at
	// the next clk_64 edge instead of waiting for a bus-slot boundary; that
	// removes the mod-4 slot quantization that pinned every CPU memory access
	// to >=8 clk_sys (docs/CPU_Perf_Log.md).
	input               flp_win,    // floppy fetch window (old slot timing, pending-gated
	                                // in addrController): serve `flp_addr` into `dout`, priority
	input  [23:0]       flp_addr,   // UNREGISTERED floppy address. ★ The floppy path must
	                                // NOT take the clk_sys request pipeline: floppy.v latches
	                                // its byte at busPhase 3 of the window slot, and delaying
	                                // the access by the pipeline's one tick pushes the data
	                                // capture to busPhase 0 of the NEXT slot — one tick after
	                                // the latch, so the guest receives the PREVIOUS byte and
	                                // the disk stream is corrupt (observed on hardware as
	                                // illegal-instruction / coprocessor bombs after a mount).
	                                // Bypassing is safe here: this cone is a shallow add+mux
	                                // and the encoder holds the address stable for the whole
	                                // window, unlike the deep V8 CPU translation the pipeline
	                                // exists to protect.
	input               flp_guard,  // a pending floppy window opens soon: don't START a
	                                // CPU access that would still occupy the chip then
	output reg          cpu_done,   // request served: read data will be stable in cpu_dout
	                                // before a consumer sampling done can latch it 2 ticks
	                                // later (early-done: set at ACTIVE+3 clk_64, capture at
	                                // ACTIVE+6); for writes set at ACTIVE (posted). Holds
	                                // until the request level drops (AS release), so the
	                                // CPU glue can use it as an async DTACK directly.
	output reg [15:0]   cpu_dout    // held CPU read data (private register: floppy-window
	                                // reads land in `dout` and can no longer clobber it)
);

localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 3 cycles@128MHz
localparam BURST_LENGTH   = 3'b000; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 


// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

// The state machine runs at 128Mhz synchronous to the 8 Mhz chipset clock.
// It wraps from T15 to T0 on the rising edge of clk_8

localparam STATE_FIRST     = 3'd0;   // first state in cycle
localparam STATE_CMD_START = 3'd0;   // state in which a new command can be started
localparam STATE_CMD_CONT  = STATE_CMD_START  + RASCAS_DELAY; // command can be continued
localparam STATE_READ      = STATE_CMD_CONT + CAS_LATENCY + 4'd2;  // +2 for 65MHz margin (was +1)
localparam STATE_LAST      = 3'd7;  // last state in cycle

reg [2:0] t;
always @(posedge clk_64) begin
	// 128Mhz counter synchronous to 8 Mhz clock
	// force counter to pass state 0 exactly after the rising edge of clk_8
	if(((t == STATE_LAST)  && ( clk_8 == 0)) ||
		((t == STATE_FIRST) && ( clk_8 == 1)) ||
		((t != STATE_LAST) && (t != STATE_FIRST)))
			t <= t + 3'd1;
end

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// JEDEC SDR-SDRAM init: ~118us of NOPs after the clock starts (the chip
// wants 100us of stable clock before the first command — the FPGA was just
// reconfigured, so the SDRAM clock was dead/floating until now), then
// PRECHARGE ALL -> 8x AUTO REFRESH -> LOAD MODE. The previous sequence
// (31 chipset cycles ~4us, ZERO refreshes; its "wait 1ms" comment was wrong)
// relied on the chip state the PREVIOUS core left behind; whether the mode
// register write took was per-load luck — suspected cause of the cold-load
// flakiness that clears after loading a different core first.
// The ladder is content-preserving (NOPs/refreshes/MRS only), so it is also
// safe to re-run via `init` on a warm user reset while the ROM is in SDRAM.
reg [9:0] reset;
always @(posedge clk_64) begin
	if(init)	reset <= 10'h3ff;
	else if((t == STATE_LAST) && (reset != 0))
		reset <= reset - 10'd1;
end

initial reset = 10'h3FF;

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [3:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = sd_cmd[3];
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];
assign sd_dqm = sd_addr[12:11];

reg oe_latch, we_latch;

// ── Demand sequencer state (Phase C, branch cpu-enhancements) ────────────
// One access = the same 8-clk_64 command schedule the old slot machine used
// (ACTIVE at start, READ/WRITE+auto-precharge at STATE_CMD_CONT, capture at
// STATE_READ with its empirically-margined +2) — only the START is now any
// idle clk_64 edge instead of a bus-slot boundary. Floppy windows (flp_win)
// take priority and still run slot-aligned by construction (the window IS
// the old slot), so floppy.v and its fetch-freshness protocol see identical
// timing. Refresh is explicit now that idle slots no longer auto-refresh:
// tREF needs one AUTO_REFRESH per 7.8 us (~508 clk_64); opportunistic when
// idle past REF_OPP, request-blocking past REF_FORCE. (The old design
// refreshed every idle slot — orders of magnitude more than required.)
reg [2:0]  seq;          // position within a running access (1..7; ACTIVE at start)
reg        seq_busy;
reg        src_cpu;      // running access belongs to the CPU/download (vs floppy)
// Request values frozen at ACTIVE: the download path's din/ds/addr muxes are
// gated on dioBusControl (a 4-tick window), so an access that starts late —
// e.g. delayed behind a refresh — could otherwise see them flip mid-access.
reg [15:0] din_q;
reg [1:0]  ds_q;
reg [8:0]  col_q;        // {addr[22], addr[7:0]} for the CAS phase
reg        flp_served;   // this floppy window already got its access
reg        ref_busy;
reg [2:0]  ref_cnt;
reg [9:0]  ref_due;      // clk_64 ticks since last refresh (saturating)
// ── served_addr / cpu_rearm REMOVED (2026-08-18) ────────────────────────────
// They existed to re-arm a write whose `we` stayed high across two DIFFERENT
// addresses (imagined download bursts). That case cannot occur: during a
// download `we` is only presented inside dioBusControl slots and drops between
// them, and CPU writes always release AS between accesses — either way
// cpu_done clears and the next write starts on its own. The compare cost a
// 24-bit clk_sys -> clk_64 crossing that repeatedly produced marginal HOLD
// violations (sdram_addr_q -> served_addr, seen at -0.216 ns and -0.037 ns on
// different placements). Deleting it removes the hazard at its source rather
// than reseeding around it. If a download ever hangs (ioctl_wait never
// clearing, so the ROM never loads and nothing boots), this is the first thing
// to reconsider.
localparam REF_OPP   = 10'd300;  // idle refresh threshold
localparam REF_FORCE = 10'd480;  // block new CPU starts, refresh first

wire req_flp   = flp_win && !flp_served;
// t[0] parity gate: only start CPU accesses on clk_64 edges that coincide
// with a clk_sys edge (the free-running ladder counter t wraps at the clk_8
// boundary, so an edge evaluating an ODD t begins an even-t period = an
// integer clk_sys tick). This pins the STATE_READ capture edge to a clk_sys
// boundary, so cpu_dout -> clk_sys consumer paths are timed at a full
// 30.8 ns period by STA — no cross-clock multicycle, no half-period races.
// Costs at most one clk_64 of start latency.
wire req_cpu   = (oe || we) && !flp_win && !flp_guard && t[0]
                 && !cpu_done && (ref_due < REF_FORCE);

always @(posedge clk_64) begin
	sd_cmd <= CMD_INHIBIT;  // default: idle
	sd_data <= 16'bZZZZZZZZZZZZZZZZ;

	if(reset != 0) begin
		seq_busy   <= 0;
		ref_busy   <= 0;
		ref_due    <= 0;
		cpu_done   <= 0;
		flp_served <= 0;
		// init ladder, one command slot per chipset cycle (~123ns apart):
		// 1023..65 = NOP wait, 64 = PRECHARGE ALL, 56/52/../28 = 8x AUTO
		// REFRESH, 2 = LOAD MODE. tRP/tRFC/tMRD are all satisfied by orders
		// of magnitude at this spacing.
		if(t == STATE_CMD_START) begin

			if(reset == 64) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr[10] <= 1'b1;      // precharge all banks
			end

			if(reset >= 28 && reset <= 56 && reset[1:0] == 2'b00)
				sd_cmd <= CMD_AUTO_REFRESH;

			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end

		end
	end else begin
		// normal operation (demand-start)

		// request-level bookkeeping
		if (!(oe || we)) cpu_done <= 0;    // AS released / request withdrawn
		if (!flp_win)    flp_served <= 0;
		if (ref_due != 10'h3FF) ref_due <= ref_due + 10'd1;

		if (seq_busy) begin
			seq <= seq + 3'd1;
			// CAS phase (auto-precharge), from the values frozen at ACTIVE
			if (seq == STATE_CMD_CONT) begin
				sd_cmd <= we_latch ? CMD_WRITE : CMD_READ;
				if (we_latch) sd_data <= din_q;
				// always return both bytes in a read. The cpu may not
				// need it, but the caches need to be able to store everything
				sd_addr <= { we_latch ? ~ds_q : 2'b00, 2'b10, col_q };  // auto precharge
			end
			// early-done for CPU reads: 3 clk_64 (1.5 clk_sys) before capture.
			// The CPU bus FSM samples done, then latches din TWO clk_sys ticks
			// later (S_WAIT exit -> S_TAIL2), so cpu_dout is stable a full
			// clk_sys tick before the consumer's latch edge. Do not move done
			// earlier than STATE_CMD_CONT+1 without redoing that arithmetic.
			if (seq == STATE_CMD_CONT + 3'd1 && src_cpu && oe_latch) cpu_done <= 1;
			// Data ready
			if (seq == STATE_READ) begin
				if (src_cpu) begin
					if (oe_latch) cpu_dout <= sd_data;
				end else begin
					dout <= sd_data;   // floppy-window data (legacy consumer path)
				end
			end
			if (seq == 3'd7) seq_busy <= 0;
		end else if (ref_busy) begin
			ref_cnt <= ref_cnt + 3'd1;
			if (ref_cnt == 3'd4) ref_busy <= 0;   // 5 clk_64 = 77 ns > tRFC
		end else if (req_flp || req_cpu) begin
			sd_cmd  <= CMD_ACTIVE;
			sd_addr <= req_flp ? { 1'b0, flp_addr[19:8] } : { 1'b0, addr[19:8] };
			sd_ba   <= req_flp ? flp_addr[21:20]          : addr[21:20];
			din_q   <= din;
			ds_q    <= ds;
			col_q   <= req_flp ? { flp_addr[22], flp_addr[7:0] }
			                   : { addr[22],     addr[7:0] };
			seq      <= 3'd1;
			seq_busy <= 1;
			src_cpu  <= !req_flp;
			we_latch <= req_flp ? 1'b0 : we;
			oe_latch <= req_flp ? 1'b1 : oe;
			if (req_flp) begin
				flp_served <= 1;
			end else begin
				if (we) cpu_done <= 1;   // posted write: ack at ACTIVE; din/ds
				                         // stay valid (AS held) through CAS
			end
		end else if (ref_due >= REF_OPP && !flp_guard && !flp_win) begin
			// !flp_guard/!flp_win: a refresh started just before a floppy
			// window would push the window's capture past its end — floppy.v
			// latches on its own (post-window) enables and would read stale
			// data. The guard zone gives refresh a hard keep-out; plenty of
			// other idle edges exist (tREF needs one refresh per ~508 clk_64).
			sd_cmd   <= CMD_AUTO_REFRESH;
			ref_busy <= 1;
			ref_cnt  <= 0;
			ref_due  <= 0;
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_64),
	.dataout(sd_clk),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
