/* tb_icache_seam.v — unit test for the CPU-vs-FETCH-CACHE seam in the REAL
 * SDRAM controller (rtl/sdram.v), the one seam no offline gate covered.
 *
 * WHY THIS EXISTS (2026-08-19): enabling the I-cache on hardware hangs the
 * machine while every offline test passes. The whole offline stack runs
 * sim_ram.v — whose demand handshake is STRUCTURALLY IMMUNE to this defect
 * (its `!(oe||we)` clear is first in an else-if chain, its set only fires
 * while the level is high, and it has no delayed-start mechanism at all) —
 * so rtl/sdram.v's handshake had never executed in simulation.
 *
 * THE DEFECT (pre-fix): a fetch-cache hit answers the CPU early, so the CPU
 * releases AS ~4 ticks into the cycle and ABANDONS the demand-start SDRAM
 * transaction it triggered. cpu_done's early-done set (seq==STATE_CMD_CONT+1)
 * is written AFTER the `!(oe||we)` clear in the same always block, so the set
 * wins even when the request level has already dropped. If the abandoned
 * transaction's ACTIVE was DELAYED — floppy fetch window (8 clk_64 of
 * sequencer occupancy), refresh, or a download word — its early-done lands
 * 3 clk_64 after ACTIVE, which can be INSIDE THE NEXT BUS CYCLE's S_WAIT
 * sampling window: the CPU sees DTACK for a request the controller never
 * served and latches the PREVIOUS access's cpu_dout. Executed garbage = the
 * hang. (Same failure family as the 2026-08-17 "oe-bridge stale-done" magenta
 * bug and the 2026-08-18 download-ack-in-cpu_done floppy-mount bomb: a done
 * consumed by a request that never earned it.)
 *
 * Cache-off is immune BY PROTOCOL: the FSM sits in S_WAIT until its own done,
 * so a done can never outlive the request that started it. Only the hit
 * bypass (and BERR aborts) creates abandonment.
 *
 * WHAT THIS TB DOES: drives the controller with the exact Phase-B bus shape —
 * requests as levels on clk_sys-aligned edges (every other clk_64 edge, the
 * DUT's own t[0] parity), a "hit cycle" = a 4-tick oe level the master
 * abandons unconsumed, a 2-tick AS-high gap, then the next request — while
 * sweeping floppy-window / download occupancy phases past the abandoned
 * fetch. INVARIANT CHECKED: cpu_done must be 0 at the next cycle's first
 * three S_WAIT sample edges (its own transaction cannot complete that fast),
 * and the completed read must return its own data.
 *
 * ★ DIFFERENTIAL: rtl/sdram.v carries the negative control
 *   +define+SDRAM_NO_DONE_LEVEL_FIX (the pre-fix set expression). Built with
 *   it, this TB must FAIL — proving the test sees the defect it was written
 *   for. Run BOTH builds after any sdram.v request/handshake edit.
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
 *     -Wno-TIMESCALEMOD --timescale 1ns/1ps +define+TB_NO_TRISTATE \
 *     --Mdir /tmp/obj_icseam --top-module tb_icache_seam \
 *     tb_icache_seam.v ../rtl/sdram.v altddio_out_stub.v
 *   /tmp/obj_icseam/Vtb_icache_seam
 * Negative control (must FAIL):
 *   ... same + +define+SDRAM_NO_DONE_LEVEL_FIX --Mdir /tmp/obj_icseam_neg
 * PASS criterion: last line "RESULT: PASS", exit 0.
 */

`timescale 1ns/1ps

module tb_icache_seam;

// ── clocks: clk_64, and clk_8 with the real 4-high/4-low slot shape ───────
reg clk64 = 0;
always #1 clk64 = ~clk64;              // period 2 ns

reg [2:0] c8div = 0;
reg       clk8  = 0;
always @(posedge clk64) begin
	c8div <= c8div + 3'd1;
	clk8  <= c8div[2];                 // 8 clk_64 per clk_8 period
end

// ── DUT-facing stimulus: shadow regs registered at every clk_64 posedge ───
// The NBA reload makes every stimulus signal transition exactly like a
// clk_sys-domain register seen from the clk_64 domain: a DUT flop clocked on
// the same edge samples the OLD value (silicon hold behaviour) — the very
// coincident-edge semantics the defect window depends on.
reg        oe_nxt = 0, we_nxt = 0;
reg [24:0] addr_nxt = 0;
reg [15:0] din_nxt = 0;
reg  [1:0] ds_nxt = 2'b11;
reg        flpwin_nxt = 0, flpguard_nxt = 0;
reg        dlreq_nxt = 0, dlslot_nxt = 0;
reg [23:0] dladdr_nxt = 0;
reg [15:0] dldin_nxt = 0;

reg        oe = 0, we = 0;
reg [24:0] addr = 0;
reg [15:0] din = 0;
reg  [1:0] ds = 2'b11;
reg        flp_win = 0, flp_guard = 0;
reg        dl_req = 0, dl_slot = 0;
reg [23:0] dl_addr = 0;
reg [15:0] dl_din = 0;

always @(posedge clk64) begin
	oe <= oe_nxt;  we <= we_nxt;  addr <= addr_nxt;  din <= din_nxt;
	ds <= ds_nxt;  flp_win <= flpwin_nxt;  flp_guard <= flpguard_nxt;
	dl_req <= dlreq_nxt;  dl_slot <= dlslot_nxt;
	dl_addr <= dladdr_nxt;  dl_din <= dldin_nxt;
end

// ── DUT: the real controller, pins split via TB_NO_TRISTATE ──────────────
reg         init = 1;
wire        sd_clk, sd_cs, sd_we_n, sd_ras, sd_cas;
wire [12:0] sd_addr;
wire  [1:0] sd_dqm, sd_ba;
wire [15:0] sd_data_o;                 // controller -> chip (write data)
reg  [15:0] sd_data_i = 16'h0000;      // chip -> controller (read data)
wire [15:0] dout, cpu_dout;
wire        cpu_done, dl_ack;

sdram dut (
	.sd_clk(sd_clk), .sd_data(sd_data_o), .sd_data_in(sd_data_i),
	.sd_addr(sd_addr), .sd_dqm(sd_dqm), .sd_ba(sd_ba),
	.sd_cs(sd_cs), .sd_we(sd_we_n), .sd_ras(sd_ras), .sd_cas(sd_cas),
	.init(init), .clk_64(clk64), .clk_8(clk8),
	.din(din), .dout(dout), .addr(addr[23:0]), .ds(ds), .oe(oe), .we(we),
	.flp_win(flp_win), .flp_addr(24'h001000), .flp_guard(flp_guard),
	.dl_req(dl_req), .dl_slot(dl_slot), .dl_addr(dl_addr), .dl_din(dl_din),
	.dl_ack(dl_ack),
	.cpu_done(cpu_done), .cpu_dout(cpu_dout)
);

// ── behavioural SDRAM chip (enough of MT48LC16M16 for this controller) ───
// Samples the controller's registered outputs one edge later (old-value
// reads at each posedge = the chip clocking the pin state), serves reads
// with CAS-2 latency held until the next READ, commits writes with DQM.
// Word address reconstruction assumes the TB keeps addr[24:20]==0 (checked).
reg [15:0] mem [0:(1<<20)-1];
reg [11:0] chip_row [0:3];
reg [19:0] rd_word;
reg  [1:0] rd_lat = 0;
wire [3:0] chip_cmd = {sd_cs, sd_ras, sd_cas, sd_we_n};
always @(posedge clk64) begin
	case (chip_cmd)
		4'b0011: chip_row[sd_ba] <= sd_addr[11:0];              // ACTIVE
		4'b0101: begin                                          // READ
			rd_word <= {chip_row[sd_ba], sd_addr[7:0]};
			rd_lat  <= 2'd2;
		end
		4'b0100: begin                                          // WRITE
			if (!sd_dqm[1]) mem[{chip_row[sd_ba], sd_addr[7:0]}][15:8] <= sd_data_o[15:8];
			if (!sd_dqm[0]) mem[{chip_row[sd_ba], sd_addr[7:0]}][7:0]  <= sd_data_o[7:0];
		end
		default: ;
	endcase
	if (rd_lat != 0) begin
		rd_lat <= rd_lat - 2'd1;
		if (rd_lat == 2'd1) sd_data_i <= mem[rd_word];
	end
end

// ── pacing: clk_sys-aligned edges = the DUT's own t[0] parity ────────────
// tick() parks at the NEGEDGE preceding an aligned posedge ("edge E"):
// values read there are exactly what a clk_sys flop samples at E, and
// stimulus written to *_nxt there is loaded into the DUT-facing regs AT E
// (visible to the DUT's clk_64 samplers only from E+half — silicon timing).
task tick; begin
	@(negedge clk64);
	while (dut.t[0] !== 1'b1) @(negedge clk64);
end endtask

task ticks(input integer n); integer k; begin
	for (k = 0; k < n; k = k + 1) tick;
end endtask

// ── scoreboard ───────────────────────────────────────────────────────────
integer errors = 0, checks = 0, viol = 0;
function [15:0] golden(input [19:0] a); golden = a[15:0] ^ 16'hC3A5; endfunction

// Full Phase-B protocol read, cache-OFF style: hold the level until done,
// latch cpu_dout two ticks later (din_r at S_TAIL2), drop the level one
// tick after that (oe_q trails AS by one). Checks the data.
task legit_read(input [19:0] a); integer guard; reg seen; reg [15:0] got; begin
	tick; oe_nxt = 1; addr_nxt = {5'd0, a}; ds_nxt = 2'b11;
	guard = 0; seen = 0;
	while (!seen && guard < 200) begin
		tick; guard = guard + 1;
		if (cpu_done === 1'b1) seen = 1;
	end
	checks = checks + 1;
	if (!seen) begin
		errors = errors + 1;
		$display("FAIL: legit read %05h never completed", a);
	end else begin
		ticks(2); got = cpu_dout;               // S_TAIL2 din_r latch point
		if (got !== golden(a)) begin
			errors = errors + 1;
			$display("FAIL: legit read %05h returned %04h, expected %04h", a, got, golden(a));
		end
		tick; oe_nxt = 0;                       // oe_q drops one tick after AS
	end
	if (!seen) begin tick; oe_nxt = 0; end
	ticks(4);
end endtask

task legit_write(input [19:0] a, input [15:0] d); integer guard; reg seen; begin
	tick; we_nxt = 1; addr_nxt = {5'd0, a}; din_nxt = d; ds_nxt = 2'b11;
	guard = 0; seen = 0;
	while (!seen && guard < 200) begin
		tick; guard = guard + 1;
		if (cpu_done === 1'b1) seen = 1;
	end
	checks = checks + 1;
	if (!seen) begin
		errors = errors + 1;
		$display("FAIL: legit write %05h never acked", a);
	end
	ticks(2); tick; we_nxt = 0;
	ticks(4);
end endtask

// The seam scenario. One iteration =
//   legit read A (loads cpu_dout with A's data, protocol-clean),
//   an occupancy event at phase `phi` ticks relative to the abandoned
//   fetch's oe rise (floppy window, optionally guarded, or a download word),
//   fetch B presented for exactly 4 ticks and ABANDONED (the hit shape),
//   2-tick gap, then read C — with the invariant probe on C's first three
//   S_WAIT samples, then C completed and data-checked.
task seam_iter(input integer phi, input integer use_guard, input integer use_dl);
	integer k; reg [2:0] stale; reg seenC; integer guard; reg [15:0] got;
begin
	legit_read(20'h00123);                      // cpu_dout now = golden(A)

	// Timeline index k, in oe(=oe_q) terms: the abandoned fetch B's request
	// level spans [0,4) — the 4-tick oe_q shape of a 6-tick hit cycle — and
	// is never consumed. The occupancy event spans [phi, phi+4) (a full
	// floppy-window slot / download burst; the guard variant precedes the
	// window by its real 4-tick approach). k runs through the 2-tick AS-high
	// gap [4,6); C's request rises at k=6.
	for (k = (phi - 5 < -6 ? phi - 5 : -6); k <= 5; k = k + 1) begin
		tick;
		oe_nxt       = (k >= 0) && (k < 4);
		addr_nxt     = 25'h00456; ds_nxt = 2'b11;
		flpwin_nxt   = (!use_dl) && (k >= phi) && (k < phi + 4);
		flpguard_nxt = (!use_dl) && (use_guard != 0) && (k >= phi - 4) && (k < phi);
		dlreq_nxt    = (use_dl != 0) && (k >= phi) && (k < phi + 4);
		dlslot_nxt   = dlreq_nxt;
		dladdr_nxt   = 24'h0F000;
		dldin_nxt    = 16'hD00D;
	end

	// C: next request, rising at k=6. The pre-edge samples at k=6/7/8 are
	// its first three S_WAIT samples (C's own transaction cannot produce a
	// done visible before the k=9 sample). Occupancy keeps its scheduled
	// shape through these ticks (a real window doesn't care about CPU
	// cycles); for the swept range it has ended by k=7.
	stale = 3'b000;
	tick;  if (cpu_done === 1'b1) stale[0] = 1; // sample 1: done during [5,6)
	oe_nxt = 1; addr_nxt = 25'h00789;
	flpwin_nxt = (!use_dl) && (6 >= phi) && (6 < phi + 4);
	dlreq_nxt  = (use_dl != 0) && (6 >= phi) && (6 < phi + 4);
	dlslot_nxt = dlreq_nxt;
	tick;  if (cpu_done === 1'b1) stale[1] = 1; // sample 2: done during [6,7)
	flpwin_nxt = 0; flpguard_nxt = 0; dlreq_nxt = 0; dlslot_nxt = 0;
	tick;  if (cpu_done === 1'b1) stale[2] = 1; // sample 3: done during [7,8)
	checks = checks + 1;
	if (stale != 3'b000) begin
		viol = viol + 1;
		errors = errors + 1;
		$display("FAIL: STALE DONE consumed by next cycle (phi=%0d guard=%0d dl=%0d samples=%b) — CPU would latch %04h (prev access's data) for read 00789",
		         phi, use_guard, use_dl, stale, cpu_dout);
	end

	// complete C properly regardless, and check its data
	seenC = 0; guard = 0;
	if (cpu_done === 1'b1) seenC = 1;
	while (!seenC && guard < 200) begin
		tick; guard = guard + 1;
		if (cpu_done === 1'b1) seenC = 1;
	end
	checks = checks + 1;
	if (!seenC) begin
		errors = errors + 1;
		$display("FAIL: read C (00789) never completed (phi=%0d guard=%0d dl=%0d)", phi, use_guard, use_dl);
	end else begin
		ticks(2); got = cpu_dout;
		if (got !== golden(20'h00789)) begin
			errors = errors + 1;
			$display("FAIL: read C returned %04h, expected %04h (phi=%0d guard=%0d dl=%0d)",
			         got, golden(20'h00789), phi, use_guard, use_dl);
		end
	end
	tick; oe_nxt = 0;
	ticks(8);                                   // drain
end endtask

integer i;
integer phi;

initial begin
	// golden content for every address the scenarios touch
	mem[20'h00123] = golden(20'h00123);
	mem[20'h00456] = golden(20'h00456);
	mem[20'h00789] = golden(20'h00789);
	mem[20'h00ABC] = golden(20'h00ABC);
	mem[20'h01000] = 16'h5AA5;                  // floppy-window target

	repeat (8) @(posedge clk64);
	init = 0;
	wait (dut.reset == 10'd0);                  // init ladder done
	repeat (16) @(posedge clk64);

	$display("=== S0: legit protocol control (reads/writes, no abandonment) ===");
	legit_read (20'h00123);
	legit_read (20'h00ABC);
	legit_write(20'h00ABC, 16'h1234);
	mem_expect (20'h00ABC, 16'h1234);
	mem[20'h00ABC] = golden(20'h00ABC);         // restore, then read it back
	legit_read (20'h00ABC);

	$display("=== S1: abandoned fetch vs floppy-window occupancy (phase sweep) ===");
	for (phi = -6; phi <= 3; phi = phi + 1) begin
		seam_iter(phi, 0, 0);                   // window alone
		seam_iter(phi, 1, 0);                   // window with leading guard
	end

	$display("=== S2: abandoned fetch vs download-word occupancy (phase sweep) ===");
	for (phi = -6; phi <= 3; phi = phi + 1)
		seam_iter(phi, 0, 1);

	$display("=== S3: abandonment with NO occupancy (control — must be clean) ===");
	for (i = 0; i < 4; i = i + 1)
		seam_iter(-20, 0, 0);                   // occupancy far away = none

	$display("");
	$display("checks=%0d errors=%0d stale_done_violations=%0d", checks, errors, viol);
	if (errors == 0) $display("RESULT: PASS");
	else             $display("RESULT: FAIL");
	$finish;
end

task mem_expect(input [19:0] a, input [15:0] d); begin
	checks = checks + 1;
	if (mem[a] !== d) begin
		errors = errors + 1;
		$display("FAIL: mem[%05h] = %04h, expected %04h", a, mem[a], d);
	end
end endtask

initial begin
	#4_000_000;
	$display("FAIL: global timeout");
	$display("RESULT: FAIL");
	$finish;
end

endmodule
