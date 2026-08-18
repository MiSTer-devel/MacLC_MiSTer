/* tb_fetch_cache.v — coherency torture test for rtl/fetch_cache.sv
 *
 * WHY THIS EXISTS (2026-08-18): the fetch cache is parked because enabling it
 * on hardware once CORRUPTED A FILE ON THE BOOT IMAGE (2026-07-07). The
 * suspected mechanism is a coherency hole — a hit returning stale data, i.e.
 * the CPU executing an instruction that memory no longer holds. QuickDraw
 * BUILDS blit code at runtime, so a stale hit executes garbage.
 *
 * Hunting that by booting a full system is hopeless: the diskless sim runs
 * 5.2M instructions across only ~1000 distinct PCs and never generates code at
 * runtime, so it cannot reach the case. This testbench drives the exact
 * hazards directly and checks ONE invariant, continuously:
 *
 *     whenever `hit` is asserted, `hit_data` MUST equal the current memory
 *     contents of that address.
 *
 * Any violation is the corruption bug, caught with the address and the
 * preceding operation named.
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps +define+SIMULATION \
 *     -I../rtl --Mdir /tmp/obj_fc --top-module tb_fetch_cache tb_fetch_cache.v \
 *     ../rtl/fetch_cache.sv
 *   /tmp/obj_fc/Vtb_fetch_cache
 * PASS criterion: last line "RESULT: PASS", exit 0.
 */
`timescale 1ns/1ps

module tb_fetch_cache;

	localparam LOG2 = 9;                 // 1 KB, the shipped size
	localparam WORDS = 1 << LOG2;

	reg clk = 0;
	always #5 clk = ~clk;

	reg         reset = 1;
	reg  [1:0]  flush_bits = 2'b00;
	reg         enable = 1;
	reg  [23:0] cpuAddr = 24'h0;
	reg         as_n = 1;
	reg         rw = 1;
	reg  [2:0]  fc = 3'b010;
	reg         cacheable = 1;
	reg         snoopable = 0;
	reg  [15:0] mem_din = 16'h0000;
	wire        hit;
	wire [15:0] hit_data;

	fetch_cache #(.LOG2_WORDS(LOG2)) dut (
		.clk(clk), .reset(reset), .flush_bits(flush_bits), .enable(enable),
		.cpuAddr(cpuAddr), .as_n(as_n), .rw(rw), .fc(fc),
		.cacheable(cacheable), .snoopable(snoopable), .mem_din(mem_din),
		.hit(hit), .hit_data(hit_data)
	);

	// ── golden model: what memory actually holds ────────────────────────────
	reg [15:0] mem [0:65535];            // indexed by word address (addr>>1)
	integer    errors = 0;
	integer    hits = 0, misses = 0, checks = 0;
	reg [23:0] cur_addr;
	reg        cur_valid = 0;            // a fetch cycle is in progress

	// THE INVARIANT: any asserted hit must match memory for the live address.
	always @(posedge clk) begin
		if (!reset && cur_valid && hit) begin
			checks = checks + 1;
			if (hit_data !== mem[cur_addr[16:1]]) begin
				errors = errors + 1;
				$display("*** COHERENCY VIOLATION at addr=%06h: hit_data=%04h but memory=%04h",
				         cur_addr, hit_data, mem[cur_addr[16:1]]);
			end
		end
	end

	// ── bus-cycle drivers ───────────────────────────────────────────────────
	// A fetch: address settles one clk BEFORE AS falls (the module's documented
	// requirement — the tops satisfy it by feeding the EARLY address).
	task do_fetch(input [23:0] a, input integer gap);
		integer i;
		begin
			cpuAddr = a; cur_addr = a; rw = 1; fc = 3'b010;
			cacheable = 1; snoopable = 0;
			@(negedge clk);                       // address stable a full clk early
			as_n = 0; cur_valid = 1;
			@(negedge clk);
			@(negedge clk);
			if (hit) hits = hits + 1; else misses = misses + 1;
			mem_din = mem[a[16:1]];               // memory answers with the truth
			@(negedge clk);
			as_n = 1; cur_valid = 0;              // fill commits at AS-rise
			for (i = 0; i < gap; i = i + 1) @(negedge clk);
		end
	endtask

	// A write: updates memory AND must invalidate any cached copy.
	task do_write(input [23:0] a, input [15:0] d, input integer gap);
		integer i;
		begin
			cpuAddr = a; rw = 0; fc = 3'b001;
			cacheable = 0; snoopable = 1;
			@(negedge clk);
			as_n = 0;
			mem[a[16:1]] = d;                     // memory changes now
			@(negedge clk);
			@(negedge clk);
			as_n = 1;
			rw = 1; snoopable = 0; cacheable = 1;
			for (i = 0; i < gap; i = i + 1) @(negedge clk);
		end
	endtask

	integer i, j;
	reg [23:0] a1, a2;

	initial begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = 16'h4E71;   // NOP everywhere

		repeat (4) @(negedge clk);
		reset = 0;
		repeat (4) @(negedge clk);

		$display("=== tb_fetch_cache: coherency torture ===");

		// 1) cold fetch -> miss; refetch -> hit with the right data
		$display("[1] cold fetch then refetch");
		mem[24'h001000 >> 1] = 16'h1234;
		do_fetch(24'h001000, 2);
		do_fetch(24'h001000, 2);

		// 2) ★ THE CRITICAL CASE: self-modifying code.
		//    fetch, then WRITE that address, then fetch again. A stale hit here
		//    is exactly what executes garbage when QuickDraw rebuilds a blit.
		$display("[2] fetch / write-same-address / refetch  (self-modifying code)");
		for (i = 0; i < 64; i = i + 1) begin
			a1 = 24'h002000 + (i << 1);
			mem[a1[16:1]] = 16'hAAAA;
			do_fetch(a1, 1);
			do_write(a1, 16'h5555, 1);
			do_fetch(a1, 1);        // MUST NOT hit with AAAA
		end

		// 3) same case with ZERO idle gap — snoop and the next fetch as close
		//    together as the bus allows (the timing corner)
		$display("[3] back-to-back write/fetch, no idle gap");
		for (i = 0; i < 64; i = i + 1) begin
			a1 = 24'h003000 + (i << 1);
			do_fetch(a1, 0);
			do_write(a1, 16'h0F0F + i[15:0], 0);
			do_fetch(a1, 0);
		end

		// 4) tag aliasing: a different address with the SAME index. The snoop
		//    kills by index without a tag compare, so this must never produce a
		//    wrong hit (it may cost an extra miss — that is fine).
		$display("[4] index aliasing across a snoop");
		a1 = 24'h004000;
		a2 = a1 + (WORDS << 1);         // same index, different tag
		mem[a1[16:1]] = 16'h1111;
		mem[a2[16:1]] = 16'h2222;
		for (i = 0; i < 32; i = i + 1) begin
			do_fetch(a1, 0);
			do_fetch(a2, 0);
			do_write(a1, 16'h3333 + i[15:0], 0);
			do_fetch(a2, 0);            // a2 must never return a1's data
			do_fetch(a1, 0);
		end

		// 5) generation flush: a mapping change must invalidate everything
		$display("[5] flush_bits change invalidates the whole cache");
		for (i = 0; i < 32; i = i + 1) do_fetch(24'h005000 + (i << 1), 0);
		for (i = 0; i < 32; i = i + 1) mem[(24'h005000 + (i << 1)) >> 1] = 16'hDEAD;
		flush_bits = 2'b01;             // e.g. overlay flip / download start
		@(negedge clk);
		for (i = 0; i < 32; i = i + 1) do_fetch(24'h005000 + (i << 1), 0);

		// 6) interleaved stream: writes landing between fetches of neighbours
		$display("[6] interleaved fetch/write stream");
		for (i = 0; i < 256; i = i + 1) begin
			a1 = 24'h006000 + ((i % 40) << 1);
			a2 = 24'h006000 + (((i * 7) % 40) << 1);
			do_fetch(a1, 0);
			do_write(a2, 16'h8000 + i[15:0], 0);
			do_fetch(a2, 0);
			do_fetch(a1, 0);
		end

		$display("");
		$display("fetches: %0d hits, %0d misses; %0d hit-data checks", hits, misses, checks);
		if (errors == 0) begin
			$display("RESULT: PASS - every hit returned current memory contents");
			$finish;
		end else begin
			$display("RESULT: FAIL - %0d coherency violations", errors);
			$fatal;
		end
	end

	initial begin
		#20000000;
		$display("RESULT: FAIL - timeout");
		$fatal;
	end

endmodule
