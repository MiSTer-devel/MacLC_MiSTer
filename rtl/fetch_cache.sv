// fetch_cache.sv — direct-mapped instruction cache in front of TG68K
//
// WHY: the core ran QuickDraw at ~0.75x a real LC. Measured mid-draw
// (2026-07-07, PBL/PBH/PCH0 probes, Speedometer color suite): bus occupancy
// only 64%, but instruction fetches were 43% of WALL time at avg 6.15 clk_sys
// each — TG68K serializes every fetch-wait into execution, where a real '020
// overlaps fetching (prefetch queue) and serves hot loops from its 256 B
// I-cache with zero bus traffic. A shadow model on the live fetch stream hit
// 87.7% (256 B) / 96.0% (1 KB); at a ~3-clk hit answer that projects the core
// to ~parity with a real LC. This is that cache, made real.
//
// Shape: word-granular (16-bit entries, the external fetch size), direct-
// mapped, LOG2_WORDS index bits. No lines: a fill captures exactly the word
// the missed fetch returned, at the same commit point the PIFD probe proved
// stable (AS rising edge). Loop re-execution — the case that matters — hits
// identically to a lined cache after the first iteration.
//
// Coherency (all hardware, no guest cooperation assumed):
//   * WRITE SNOOP: any CPU write into snoopable space kills the indexed
//     entry unconditionally (no tag compare — cheaper, strictly safe).
//     QuickDraw BUILDS blit code at runtime; a stale hit executes garbage,
//     so the snoop is load-bearing, not hygiene.
//   * GENERATION FLUSH: `flush_bits` carries mapping-change levels (ROM
//     overlay state, HPS download active). ANY change bumps `gen`, and a
//     tag only matches its own generation — an O(1) full flush with no
//     valid-bit array. gen==0 is skipped so zero-initialized BRAM (and
//     snoop-killed entries, which write gen 0) can never match.
//   * The cache FILLS AND SNOOPS EVEN WHILE DISABLED — `enable` gates only
//     the answer path. The OSD switch can therefore be flipped mid-session
//     and the cache is instantly warm and coherent, giving a same-build
//     live A/B (the validation method for this whole mission).
//
// Both tops instantiate this module (MacLC.sv AND verilator/sim.v — keep
// them in sync per docs/verilator_differences.md). The answer contract with
// the tops' glue:
//   * `hit` registers ON the AS-fall edge (continuous pre-read + comb
//     compare), holds while AS stays low, clears at AS rise. The tops OR it
//     directly into _cpuDTACK (and dtack_en), bypassing both the SDRAM
//     cpu-slot alignment and the dtack_en register stage — the earliest
//     answer the 68k bus protocol admits.
//   * `hit_data` is stable alongside `hit`; the tops mux it into the CPU
//     din path INSTEAD of dataControllerDataOut for that cycle. The
//     background SDRAM slot read still happens and is ignored (reads are
//     side-effect free in RAM/ROM).
//   * Fills use dataControllerDataOut (the memory-side data), never the
//     post-cache mux, so a fill can only capture what memory returned.

module fetch_cache #(
	parameter LOG2_WORDS = 9        // 2^9 x 16-bit = 1 KB (shadow-measured 96%)
)(
	input  wire        clk,
	input  wire        reset,       // level; edge bumps gen and clears state
	input  wire [1:0]  flush_bits,  // mapping-change levels; ANY change bumps gen
	input  wire        enable,      // OSD switch — gates the ANSWER path only

	// CPU bus view (raw TG68 signals, same names as the tops).
	// cpuAddr MUST be the EARLY (pre-AS) address — see the port note above.
	input  wire [23:0] cpuAddr,
	input  wire        as_n,
	input  wire        rw,          // 1 = read
	input  wire [2:0]  fc,
	input  wire        cacheable,   // fetch side: selectRAM || selectROM
	input  wire        snoopable,   // write side: RAM-backed space to invalidate
	input  wire [15:0] mem_din,     // dataControllerDataOut (fill source)

	output reg         hit,         // registered; ~2 clk after AS-fall on a hit
	output reg  [15:0] hit_data,
	// COMBINATIONAL hit indication, valid from the cycle AS falls (the same
	// cycle the tops would launch the SDRAM demand request). The tops gate
	// the fetch's SDRAM request with this so a HIT NEVER STARTS A
	// TRANSACTION. Why (2026-08-19, Speedometer per-test evidence): a hit
	// answers the CPU early and ABANDONS its in-flight demand transaction;
	// the controller stays busy finishing the phantom and the NEXT access
	// stalls behind it. Fetch-dominated loops still won (Sieve +21%), but
	// data-heavy code (the software-FP tests) paid more stall than it
	// gained: KWhet/FFT/FP-Matrix regressed 4-6% vs cache-off. Gating the
	// request at the source removes the abandonment class entirely;
	// sdram.v's done-birth guard (`&& oe`) remains as the safety net.
	// Stable for the whole access: cpuAddr cannot change until the next
	// clkena, and lookup_match's inputs (tag_q/data_q/rd_idx_d/gen) only
	// move on clk edges that also move `hit`.
	output wire        hit_now
);

	localparam WORDS = 1 << LOG2_WORDS;
	localparam TAGW  = 23 - LOG2_WORDS;   // of the 23-bit word address
	localparam GENW  = 16;

	// {gen, tag} per entry; gen 0 = never-match (snoop kill / power-up zeros)
	(* ramstyle = "M10K" *) reg [GENW+TAGW-1:0] tag_ram  [0:WORDS-1];
	(* ramstyle = "M10K" *) reg [15:0]          data_ram [0:WORDS-1];

	wire [LOG2_WORDS-1:0] idx = cpuAddr[LOG2_WORDS:1];
	wire [TAGW-1:0]       tag = cpuAddr[23:LOG2_WORDS+1];

	reg                 as_n_d = 1'b1;
	reg                 rst_d  = 1'b0;
	reg  [1:0]          flush_d = 2'b00;
	reg  [GENW-1:0]     gen = {{GENW-1{1'b0}}, 1'b1};
	reg                 enable_r = 1'b0;

	wire as_fall = as_n_d && !as_n;
	wire as_rise = !as_n_d && as_n;
	wire fetch_start = as_fall && rw  && (fc == 3'b010 || fc == 3'b110) && cacheable;
	wire write_start = as_fall && !rw && snoopable;

	// CONTINUOUS lookup (v2): the BRAM read runs every clock against the live
	// address, so tag_q/data_q are already resolved for THIS cycle's address
	// when AS falls — the hit can register on the AS-fall edge itself.
	//
	// ★★★ PORT NOTE (2026-08-18, Phase B+C tree): this REQUIRES an address that
	// is valid at least one clk BEFORE AS falls. The pre-Phase-B walker gave
	// that for free (addr registered at s0, AS asserted at s1). The Phase-B FSM
	// registers `addr` and asserts `as_n_r` on the SAME edge, so feeding this
	// module the REGISTERED cpuAddr makes rd_idx_d != idx at every as_fall and
	// the cache misses 100% of the time — silently useless, not broken.
	// The tops therefore feed `cpuAddr_early` = the kernel's combinational
	// address output (tg68_addr), which settles one full tick earlier, right
	// after clkena. It is stable for the whole access (the kernel cannot change
	// it until the next clkena), so the correspondence guard holds.
	// rd_idx_d guards correspondence (the entry read must be for the current
	// index); a fetch whose address settled later simply misses, safely.
	// (v1 issued the read AT AS-fall and resolved a clock later, then went
	// through dtack_en — the answer landed at 5-7 clk, unable to beat the
	// uncached mode-5 slot path. Measured 2026-07-07 PM: tail compressed,
	// mode untouched, Speedometer unchanged.)
	reg [GENW+TAGW-1:0]  tag_q;
	reg [15:0]           data_q;
	reg [LOG2_WORDS-1:0] rd_idx_d;
	reg                  miss_pend = 1'b0;   // fill at AS-rise
	reg [LOG2_WORDS-1:0] miss_idx;
	reg [TAGW-1:0]       miss_tag;

	// ── RDW IMMUNITY (2026-08-18) ────────────────────────────────────────────
	// The continuous lookup reads tag_ram/data_ram EVERY clock while the snoop
	// and the fill write them. When a write targets the very entry being read,
	// M10K read-during-write behaviour is NOT guaranteed to match Verilog's
	// non-blocking semantics (these arrays carry `ramstyle = "M10K"` with no
	// explicit RDW mode), so silicon may return the new tag beside stale data —
	// a HIT CARRYING THE WRONG INSTRUCTION WORD. The module previously relied
	// on a timing argument ("the fill's garbage is never consumed, next AS-fall
	// >= 2 clk"), but that margin came from the pre-Phase-B 8-tick bus cycle;
	// the Phase-B/C cycle is 6 ticks with a single-tick S_IDLE, so the next
	// fetch's address arrives sooner relative to the fill and the window is
	// reachable. Enabling the cache on that tree HUNG the machine while every
	// offline test passed — see docs/CPU_Perf_Log.md entry 6.
	//
	// Fix by construction, not by margin: if the entry read this cycle was
	// written this cycle, the registered lookup is untrustworthy, so force a
	// MISS. Costs one refill in a rare case and removes the hazard class
	// entirely, whatever RDW mode the fitter picks.
	reg  rdw_collide_d = 1'b0;
	wire rdw_collide = (tag_we && (tag_waddr == idx))
	                || (as_rise && miss_pend && (miss_idx == idx));

`ifdef FETCH_CACHE_NO_RDW_FIX
	// NEGATIVE CONTROL (TB only): the pre-fix expression, so the testbench can
	// demonstrate it actually catches the bug rather than passing vacuously.
	wire lookup_match = (tag_q == {gen, tag}) && (rd_idx_d == idx);
`else
	wire lookup_match = (tag_q == {gen, tag}) && (rd_idx_d == idx) && !rdw_collide_d;
`endif

	// Request-suppression hit (see the port comment). Uses the same terms as
	// fetch_start/hit so it can never suppress a request the answer path will
	// not serve. ★ PER-ACCESS SNAPSHOT, not the live verdict: lookup_match
	// can RISE mid-access (an RDW-forced miss refills and matches one cycle
	// later) — a live gate would then drop the request level mid-transaction
	// and, with sdram.v's done-birth guard, the CPU would wait on a done
	// that can never be born. So: combinational on the AS-fall cycle (the
	// same edge `hit` registers, so gate and answer always agree), latched
	// for the remainder of the access, cleared when AS rises.
	wire hit_now_comb = enable_r && rw && (fc == 3'b010 || fc == 3'b110)
	                    && cacheable && lookup_match;
	reg  hit_now_held;
	always @(posedge clk) begin
		if (reset || as_n) hit_now_held <= 1'b0;
		else if (as_n_d)   hit_now_held <= hit_now_comb;  // first AS-low cycle
	end
	assign hit_now = !as_n && (as_n_d ? hit_now_comb : hit_now_held);

	// SINGLE write port for tag_ram (M10K is 1R+1W): the snoop kill (AS-fall
	// of a write cycle) and the miss fill (AS-rise of a fetch cycle) are on
	// opposite AS edges and can never coincide, so mux them onto one port.
	// Two separate write statements made Quartus fall back to a register
	// array — 6.3k ALUTs / 15.5k FFs, the 2026-07-07 fitter overflow.
	wire                  tag_we    = !reset && (write_start || (as_rise && miss_pend));
	wire [LOG2_WORDS-1:0] tag_waddr = write_start ? idx : miss_idx;
	wire [GENW+TAGW-1:0]  tag_wdata = write_start ? {(GENW+TAGW){1'b0}}
	                                              : {gen, miss_tag};

	always @(posedge clk) begin
		as_n_d   <= as_n;
		rdw_collide_d <= rdw_collide;   // travels with tag_q/data_q/rd_idx_d
		rst_d    <= reset;
		flush_d  <= flush_bits;
		enable_r <= enable;

		// generation bump: reset edge or any mapping-change edge. Skip gen 0.
		if ((reset && !rst_d) || (flush_bits != flush_d)) begin
			gen <= (gen == {GENW{1'b1}}) ? {{GENW-1{1'b0}}, 1'b1} : gen + 1'd1;
		end

		// tag_ram: one read + ONE muxed write (see tag_we above) → M10K
		if (tag_we)
			tag_ram[tag_waddr] <= tag_wdata;

		// continuous lookup — every clock, unconditional
`ifdef FETCH_CACHE_HOSTILE_RDW
		// TB-ONLY FAULT INJECTION (never synthesised). Verilog's non-blocking
		// semantics always return OLD data on a read-during-write, so a plain
		// simulation CANNOT reproduce the silicon behaviour that hangs the
		// machine. Model the WORST realistic M10K mix: the tag reads
		// write-first (NEW) while the data reads read-first (OLD) — which is
		// precisely what turns a collision into a hit carrying a stale
		// instruction word. tb_fetch_cache.v runs with this defined to prove
		// the rdw_collide guard above actually protects against it.
		tag_q    <= (tag_we && (tag_waddr == idx)) ? tag_wdata : tag_ram[idx];
`else
		tag_q    <= tag_ram[idx];
`endif
		data_q   <= data_ram[idx];
		rd_idx_d <= idx;

		if (reset) begin
			miss_pend <= 1'b0;
			hit       <= 1'b0;
		end else begin
			// 1) resolve AT the fetch's AS-fall edge: the continuous lookup
			//    already holds this address's entry. Hit (answer path) only
			//    when enabled; miss tracking (fill path) always.
			if (fetch_start) begin
				if (lookup_match) begin
					hit      <= enable_r;
					hit_data <= data_q;
				end else begin
					miss_pend <= 1'b1;
					miss_idx  <= idx;
					miss_tag  <= tag;
				end
			end

			// 2) cycle completion: clear the answer; commit the data fill with
			//    what memory actually returned (PIFD-proven stable at AS-rise);
			//    the matching tag write goes through the shared port above
			if (as_rise) begin
				hit <= 1'b0;
				if (miss_pend) begin
					miss_pend          <= 1'b0;
					data_ram[miss_idx] <= mem_din;
				end
			end
		end
	end

`ifdef SIMULATION
	// Port-verification counters (2026-08-18): is the cache actually engaging
	// on this tree? Checks the two gates most likely to silently disable it —
	// the FC program-space test (addrController warns FC is unreliable at
	// AS-fall in this core) and the continuous-lookup correspondence guard.
	integer ic_fetch = 0, ic_hit = 0, ic_miss = 0, ic_asfall_rd = 0, ic_idxbad = 0;
	always @(posedge clk) begin
		if (!reset) begin
			if (as_fall && rw && cacheable) begin
				ic_asfall_rd = ic_asfall_rd + 1;          // cacheable read at AS-fall
				if (!(fc == 3'b010 || fc == 3'b110))
					ic_idxbad = ic_idxbad + 1;            // rejected by the FC gate
			end
			if (fetch_start) begin
				ic_fetch = ic_fetch + 1;
				if (lookup_match) ic_hit = ic_hit + 1; else ic_miss = ic_miss + 1;
				if (ic_fetch % 200000 == 0)
					$display("ICACHE fetches=%0d hit=%0d (%0d%%) miss=%0d | cacheable_rd=%0d fc_rejected=%0d",
					         ic_fetch, ic_hit, (ic_hit*100)/ic_fetch, ic_miss,
					         ic_asfall_rd, ic_idxbad);
			end
		end
	end
`endif

endmodule