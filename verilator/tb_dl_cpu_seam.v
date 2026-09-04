/* tb_dl_cpu_seam.v — unit test for the CPU-vs-DOWNLOAD seam in the memory
 * controller. This is the seam that had NO coverage and where the Phase C
 * floppy regression lived.
 *
 * WHY THIS EXISTS (2026-08-18): mounting a floppy bombed the running guest
 * with "illegal instruction" / "coprocessor not installed" — the CPU
 * executing garbage. The cause was NOT the floppy datapath (two fixes aimed
 * there both failed on hardware) but the image DOWNLOAD:
 *
 *   Pre-Phase-C the CPU's _ramOE/_ramWE were gated on cpuBusControl, the exact
 *   complement of dioBusControl, so a CPU request and a download write could
 *   not coexist. Phase C (f13d936) made the CPU request a LEVEL held for the
 *   whole AS-low window, and that level now spans the download's slot. Both
 *   tops still muxed the download onto the CPU's addr/din/we/oe nets, so:
 *     (a) while the mux pointed at the download the CPU's request was
 *         invisible to the controller, and
 *     (b) the download's posted-write ack landed in cpu_done — which IS the
 *         CPU's DTACK. When the slot ended and the CPU's still-asserted oe
 *         came back, !(oe||we) was never true, so cpu_done never cleared: the
 *         CPU completed a read it had never issued and latched the PREVIOUS
 *         access's cpu_dout.
 *   The ROM download at boot was immune only because the CPU is held in reset
 *   for it — which is exactly why booting always worked and only mounting
 *   broke.
 *
 * The fix gives the download its own request port (dl_req/dl_slot/dl_addr/
 * dl_din/dl_ack) which never writes cpu_done. This TB locks that in.
 *
 * ★ DIFFERENTIAL, not just an invariant check. Built with +define+TB_LEGACY_MUX
 *   the testbench wires the download the OLD way — onto the CPU's own
 *   oe/we/addr/din, dl_req tied 0 — against the SAME DUT, and Test 2 then
 *   FAILS with stale read data. That fault injection is what proves the test
 *   can see the defect it was written for. Run BOTH.
 *
 * DUT: verilator/sim_ram.v, the model the whole offline sim rests on; it
 * mirrors rtl/sdram.v's demand handshake and carries the identical download
 * port. rtl/sdram.v itself cannot be Verilated (it drives its sd_data
 * tristate from a non-blocking procedural assignment, which Verilator 5.x
 * rejects — that is why sim_ram.v exists at all). To run this same test
 * against the REAL controller, use Icarus, which is not installed here:
 *   iverilog -g2012 -DTB_REAL_SDRAM -o /tmp/tb.vvp -I../rtl \
 *     tb_dl_cpu_seam.v ../rtl/sdram.v altddio_out_stub.v && vvp /tmp/tb.vvp
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
 *     --timescale 1ns/1ps --Mdir /tmp/obj_dlseam \
 *     --top-module tb_dl_cpu_seam tb_dl_cpu_seam.v sim_ram.v
 *   /tmp/obj_dlseam/Vtb_dl_cpu_seam
 * Fault injection (must FAIL):
 *   verilator --binary -j 0 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
 *     --timescale 1ns/1ps +define+TB_LEGACY_MUX --Mdir /tmp/obj_dlseam_leg \
 *     --top-module tb_dl_cpu_seam tb_dl_cpu_seam.v sim_ram.v
 *   /tmp/obj_dlseam_leg/Vtb_dl_cpu_seam
 * PASS criterion: last line "RESULT: PASS", exit 0.
 */

`timescale 1ns/1ps

module tb_dl_cpu_seam;

reg clk = 0;
always #16 clk = ~clk;               // clk_sys-ish; the model is single-clock

reg         reset = 1;
reg  [15:0] cpu_din  = 0;
reg  [24:0] cpu_addr = 0;
reg   [1:0] cpu_ds   = 2'b11;
reg         cpu_oe   = 0, cpu_we = 0;

reg         dl_req = 0, dl_slot = 0;
reg  [23:0] dl_addr = 0;
reg  [15:0] dl_din  = 0;
wire        dl_ack;

wire [15:0] dout, cpu_dout;
wire        cpu_done;

// ── the wiring under test ───────────────────────────────────────────────
// Default = the FIX (separate ports).
// TB_LEGACY_MUX = the pre-fix top-level wiring: `download_cycle` steals the
// CPU's nets for the download's bus slot, and dl_req is tied off.
`ifdef TB_LEGACY_MUX
wire        dl_cycle  = dl_req && dl_slot;
wire [24:0] dut_addr  = dl_cycle ? {1'b0, dl_addr} : cpu_addr;
wire [15:0] dut_din   = dl_cycle ? dl_din  : cpu_din;
wire  [1:0] dut_ds    = dl_cycle ? 2'b11   : cpu_ds;
wire        dut_we    = dl_cycle ? 1'b1    : cpu_we;
wire        dut_oe    = dl_cycle ? 1'b0    : cpu_oe;
wire        dut_dlreq = 1'b0;
// With the legacy mux the download is acknowledged by the bus-slot edge, as
// the old top level did, so the stimulus below still advances.
reg  dl_slot_d = 0;
always @(posedge clk) dl_slot_d <= dl_slot;
wire dl_ack_eff = dl_slot_d && !dl_slot;
`else
wire [24:0] dut_addr  = cpu_addr;
wire [15:0] dut_din   = cpu_din;
wire  [1:0] dut_ds    = cpu_ds;
wire        dut_we    = cpu_we;
wire        dut_oe    = cpu_oe;
wire        dut_dlreq = dl_req;
wire        dl_ack_eff = dl_ack;
`endif

sim_ram dut (
	.clk(clk), .reset(reset),
	.din(dut_din), .dout(dout), .addr(dut_addr), .ds(dut_ds),
	.oe(dut_oe), .we(dut_we),
	.flp_win(1'b0), .flp_addr(24'd0), .flp_guard(1'b0),
	.dl_req(dut_dlreq), .dl_slot(dl_slot), .dl_addr(dl_addr), .dl_din(dl_din),
	.dl_ack(dl_ack),
	.cpu_done(cpu_done), .cpu_dout(cpu_dout),
	.frame_count(32'd0)
);

// ── bus-slot generator: dl_slot mirrors dioBusControl (one slot in four) ──
reg [3:0] slotdiv = 0;
always @(posedge clk) begin
	slotdiv <= slotdiv + 4'd1;
	dl_slot <= (slotdiv[3:2] == 2'b10);
end

// ── scoreboard ──────────────────────────────────────────────────────────
integer errors = 0;
integer checks = 0;
integer i;

// Golden content: unique per address, pre-seeded into the model's memory.
function [15:0] golden(input [24:0] a); golden = a[15:0] ^ 16'hA53C; endfunction

task expect_read(input [24:0] a);
	integer guard;
begin
	@(negedge clk);
	cpu_addr = a; cpu_ds = 2'b11; cpu_oe = 1; cpu_we = 0;
	guard = 0;
	while (!cpu_done && guard < 500) begin @(posedge clk); guard = guard + 1; end
	checks = checks + 1;
	if (guard >= 500) begin
		errors = errors + 1;
		$display("FAIL: read %06h never completed (cpu_done stuck low)", a);
	end else if (cpu_dout !== golden(a)) begin
		errors = errors + 1;
		$display("FAIL: read %06h returned %04h, expected %04h  <-- STALE/WRONG DATA",
		         a, cpu_dout, golden(a));
	end
	@(negedge clk);
	cpu_oe = 0;                       // release the request level, as AS does
	repeat (3) @(posedge clk);
end
endtask

// One download word, presented in its slot and released on the ack — the
// same two-phase handshake MacLC.sv drives from ioctl_wait.
task dl_word(input [23:0] a, input [15:0] d);
	integer guard;
begin
	@(negedge clk);
	dl_addr = a; dl_din = d; dl_req = 1;
	guard = 0;
	while (!dl_ack_eff && guard < 400) begin @(posedge clk); guard = guard + 1; end
	if (guard >= 400) begin
		errors = errors + 1;
		$display("FAIL: download word never acknowledged (ioctl_wait would hang)");
	end
	@(negedge clk);
	dl_req = 0;
	repeat (2) @(posedge clk);
end
endtask

initial begin
	// Seed the golden pattern directly into the model's array.
	for (i = 0; i < 4096; i = i + 1)      mem_seed(i);
	for (i = 24'h100000; i < 24'h100040; i = i + 1) mem_seed(i);

	repeat (4) @(posedge clk);
	reset = 0;
	repeat (8) @(posedge clk);

	$display("=== Test 1: a download alone must never assert cpu_done ===");
	cpu_oe = 0; cpu_we = 0;
	for (i = 0; i < 8; i = i + 1) begin
		dl_word(24'h600000 + i[23:0], 16'h1000 + i[15:0]);
		if (cpu_done) begin
			errors = errors + 1;
			$display("FAIL: cpu_done asserted by a download write (word %0d)", i);
		end
	end
	for (i = 0; i < 8; i = i + 1)
		if (dut.mem[24'h600000 + i] !== (16'h1000 + i[15:0])) begin
			errors = errors + 1;
			$display("FAIL: download word %0d landed as %04h, expected %04h",
			         i, dut.mem[24'h600000 + i], 16'h1000 + i[15:0]);
		end

	$display("=== Test 2: CPU reads stay correct while a download runs ===");
	// The regression: the guest keeps fetching during an OSD mount while
	// download words stream into the floppy window of memory. Every read must
	// return ITS OWN data. Under the legacy mux this is where stale cpu_dout
	// (the executed-garbage bomb) shows up.
	fork
		begin : downloader
			for (i = 0; i < 40; i = i + 1)
				dl_word(24'h600100 + i[23:0], 16'h2000 + i[15:0]);
		end
		begin : reader
			expect_read(25'h000123);
			expect_read(25'h000ABC);
			expect_read(25'h100001);
			expect_read(25'h000123);
			expect_read(25'h000FFF);
			expect_read(25'h000010);
			expect_read(25'h000456);
			expect_read(25'h100020);
			expect_read(25'h000789);
			expect_read(25'h000001);
		end
	join

	$display("=== Test 3: CPU writes and download writes must not cross ===");
	fork
		begin
			for (i = 0; i < 8; i = i + 1)
				dl_word(24'h600200 + i[23:0], 16'h3000 + i[15:0]);
		end
		begin
			@(negedge clk);
			cpu_addr = 25'h005555; cpu_din = 16'hBEEF; cpu_ds = 2'b11;
			cpu_we = 1; cpu_oe = 0;
			repeat (40) @(posedge clk);
			@(negedge clk);
			cpu_we = 0;
			repeat (8) @(posedge clk);
		end
	join
	if (dut.mem[24'h005555] !== 16'hBEEF) begin
		errors = errors + 1;
		$display("FAIL: CPU write to 005555 landed as %04h, expected BEEF",
		         dut.mem[24'h005555]);
	end
	for (i = 0; i < 8; i = i + 1)
		if (dut.mem[24'h600200 + i] !== (16'h3000 + i[15:0])) begin
			errors = errors + 1;
			$display("FAIL: download word %0d landed as %04h, expected %04h",
			         i, dut.mem[24'h600200 + i], 16'h3000 + i[15:0]);
		end

	$display("");
	$display("checks=%0d errors=%0d", checks, errors);
	if (errors == 0) $display("RESULT: PASS");
	else             $display("RESULT: FAIL");
	$finish;
end

task mem_seed(input integer a);
begin
	dut.mem[a] = golden(a[24:0]);
end
endtask

initial begin
	#8_000_000;
	$display("FAIL: global timeout");
	$display("RESULT: FAIL");
	$finish;
end

endmodule
