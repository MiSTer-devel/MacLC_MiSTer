/* tb_pds_enet.v — unit test for the PDS Ethernet card front-end
 * (rtl/pds/pds_enet.sv) against the behavioral DDR3 model (sim_ddr3.v).
 *
 * The TB plays BOTH sides: it drives TG68-style bus cycles (address + AS +
 * UDS/LDS, waiting on card_ack = the top's stretched DTACK) and plays the
 * maclc_eth daemon (stages MAGIC / shadows / INT / RPC in the DDR3 window,
 * decodes doorbell ring entries).
 *
 * WHAT IT CHECKS:
 *   1. Presence gate: without MAGIC the card never claims a cycle; after
 *      MAGIC + a guest-reset window it does (sticky-rise latch).
 *   2. Boardram: word + UDS-only + LDS-only writes/readbacks at $FE0D'xxxx,
 *      and the DDR3 lane convention (guest byte A = window byte A).
 *   3. declROM: byte read at $FEFF'FFFE returns the staged byteLanes byte on
 *      D[15:8] (the Slot Manager's first probe target).
 *   4. Register write doorbell: CR write at $FE0E'003C (index inversion
 *      ~$F = reg 0) lands as a REG_WR ring entry + wptr publish; the RESET
 *      event from a warm guest reset also appears.
 *   5. Register read shadows: ISR ($FE0E'0020, reg 7) serves the daemon-
 *      staged value; the 24-bit window form ($EE'0020) serves it too.
 *   6. INT word -> irq output (and clears).
 *   7. Data-port (word) read RPC: seq-matched response returns the daemon's
 *      data; an unanswered read completes with $FFFF via the watchdog.
 *   8. Unmodelled reg-window shapes (LDS-only byte) serve $FFFF with no
 *      doorbell entry.
 *
 * Build + run (Verilator 5.x, from verilator/):
 *   verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
 *     --Mdir /tmp/obj_pdsenet --top-module tb_pds_enet \
 *     tb_pds_enet.v sim_ddr3.v ../rtl/pds/pds_enet.sv
 *   /tmp/obj_pdsenet/Vtb_pds_enet
 */
`timescale 1ns/1ps

module tb_pds_enet;

	reg clk = 0;
	always #5 clk = ~clk;

	reg rst_core = 1, rst_guest = 1, ena_osd = 1;

	reg  [31:0] cpuAddr = 0;
	reg  [15:0] cpuDataIn = 0;
	reg  _cpuAS = 1, _cpuUDS = 1, _cpuLDS = 1, _cpuRW = 1;

	wire card_sel, card_ack, irq;
	wire [15:0] card_dout;
	wire [28:0] m_addr;  wire [7:0] m_burst, m_be;
	wire m_rd, m_we, m_rvalid, m_busy;
	wire [63:0] m_wdata, m_rdata;

	pds_enet #(.DP_WD_BITS(10)) dut (
		.clk_sys(clk), .rst_core(rst_core), .rst_guest(rst_guest), .ena_osd(ena_osd),
		.cpuAddr(cpuAddr), .cpuDataIn(cpuDataIn),
		._cpuAS(_cpuAS), ._cpuUDS(_cpuUDS), ._cpuLDS(_cpuLDS), ._cpuRW(_cpuRW),
		.card_sel(card_sel), .card_ack(card_ack), .card_dout(card_dout), .irq(irq),
		.mem_addr(m_addr), .mem_burst(m_burst), .mem_rd(m_rd), .mem_we(m_we),
		.mem_wdata(m_wdata), .mem_be(m_be), .mem_rdata(m_rdata),
		.mem_rvalid(m_rvalid), .mem_busy(m_busy)
	);

	sim_ddr3 dd (
		.clk(clk), .addr(m_addr), .burst(m_burst), .rd(m_rd), .we(m_we),
		.wdata(m_wdata), .be(m_be), .rdata(m_rdata), .rvalid(m_rvalid), .busy(m_busy)
	);

	localparam [63:0] MAGIC = 64'h4D634C43_45544831;
	localparam W_MAGIC = 15'h4000, W_WPTR = 15'h4001, W_SHAD = 15'h4002,
	           W_INT = 15'h4008, W_RPC = 15'h4009, W_RING = 15'h4100;

	integer fails = 0;
	task check(input cond, input [511:0] name);
		if (!cond) begin
			$display("FAIL: %0s", name);
			fails = fails + 1;
		end else
			$display("pass: %0s", name);
	endtask

	// ── TG68-flavored bus cycles ────────────────────────────────────────────
	task cpu_cycle(input [31:0] addr, input rw, input uds, input lds,
	               input [15:0] wdata, input expect_claim,
	               output [15:0] rdata, output claimed);
		integer n;
		begin
			@(negedge clk);
			cpuAddr  = addr; _cpuRW = rw; cpuDataIn = wdata;
			_cpuAS   = 0; _cpuUDS = !uds; _cpuLDS = !lds;
			claimed  = 0; rdata = 16'hFFFF;
			n = 0;
			while (n < 3000 && !(card_sel && card_ack)) begin
				@(negedge clk);
				if (card_sel) claimed = 1;
				n = n + 1;
			end
			if (card_sel && card_ack) begin
				claimed = 1;
				rdata   = card_dout;
			end
			if (expect_claim != claimed)
				$display("  (cycle @%h claim=%0d expected=%0d)", addr, claimed, expect_claim);
			_cpuAS = 1; _cpuUDS = 1; _cpuLDS = 1; _cpuRW = 1;
			@(negedge clk);
			@(negedge clk);
		end
	endtask

	reg [15:0] rd; reg cl;
	reg [63:0] e;
	integer i;
	reg [31:0] wp0;

	initial begin
		// ── reset, no daemon ─────────────────────────────────────────────
		repeat (10) @(negedge clk);
		rst_core = 0;
		repeat (20) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		cpu_cycle(32'hFE0D0000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "no MAGIC: card does not claim $FE0D0000");

		// ── daemon appears; presence latches during a guest reset ────────
		dd.poke64(W_MAGIC, MAGIC);
		// magic poll cadence while absent is poll_div==16'hFFFF
		repeat (70000) @(negedge clk);
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		// ── boardram ─────────────────────────────────────────────────────
		cpu_cycle(32'hFE0D0010, 0, 1, 1, 16'hBEEF, 1, rd, cl);
		check(cl, "boardram word write claims");
		cpu_cycle(32'hFE0D0010, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hBEEF, "boardram word readback BEEF");
		e = dd.peek64(15'h0002);   // guest 0x10 -> word 2, lane 0x10&7 = 0
		check(e[7:0] == 8'hBE && e[15:8] == 8'hEF,
		      "DDR3 lane convention: byte A=0x10 lane0=BE, A=0x11 lane1=EF");
		cpu_cycle(32'hFE0D0010, 0, 1, 0, 16'hAA55, 1, rd, cl);   // UDS-only
		cpu_cycle(32'hFE0D0010, 1, 1, 1, 0, 1, rd, cl);
		check(rd == 16'hAAEF, "UDS-only byte write merged (AAEF)");
		cpu_cycle(32'hFE0D0010, 0, 0, 1, 16'h1177, 1, rd, cl);   // LDS-only
		cpu_cycle(32'hFE0D0010, 1, 1, 1, 0, 1, rd, cl);
		check(rd == 16'hAA77, "LDS-only byte write merged (AA77)");

		// ── declROM ──────────────────────────────────────────────────────
		// stage the byteLanes byte $A5 at window byte $FFFE (lane 6 of the
		// last ROM word) the way the daemon's expansion does
		dd.poke64(15'h2000 + 15'h1FFF, 64'hFFA5_FF00_FFC7_FF2B);
		cpu_cycle(32'hFEFFFFFE, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'hA5, "declROM byteLanes byte at $FEFFFFFE");

		// ── register write doorbell (+ the RESET event from a warm reset) ─
		// The FIRST (presence-establishing) reset must NOT post an event:
		// present was still 0 at its rising edge.
		check(dd.peek64(W_WPTR) == 0, "presence-establishing reset posts no event");
		// A genuine warm restart (present already latched) posts TAG_RESET.
		rst_guest = 1;
		repeat (50) @(negedge clk);
		rst_guest = 0;
		repeat (50) @(negedge clk);
		wp0 = dd.peek64(W_WPTR);
		check(wp0 == 1, "warm guest reset posted an event");
		e = dd.peek64(W_RING + ((wp0 - 1) & 15'hFF));
		check(e[0] && e[3:1] == 3'd4, "last event is TAG_RESET");

		cpu_cycle(32'hFE0E003C, 0, 1, 0, 16'h2100, 1, rd, cl);   // CR = $21
		check(cl, "reg write (CR @+3C) claims + completes");
		e = dd.peek64(W_RING + (wp0 & 15'hFF));
		check(e[0] && e[3:1] == 3'd0 && e[7:4] == 4'h0 && e[15:8] == 8'h21,
		      "REG_WR entry: reg 0 (inverted from +3C), data $21");
		check(dd.peek64(W_WPTR) == wp0 + 1, "wptr published");

		// ── register read shadows ────────────────────────────────────────
		// ISR = page0 reg 7 -> shadow word 0 byte 7; guest addr +$20 (~8=7)
		dd.poke64(W_SHAD, 64'h8000_0000_0000_0000);
		repeat (12000) @(negedge clk);      // let a full poll round pass
		cpu_cycle(32'hFE0E0020, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h80, "ISR shadow read via 32-bit window");
		cpu_cycle(32'h00EE0020, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h80, "ISR shadow read via 24-bit window");

		// ── INT -> irq ───────────────────────────────────────────────────
		dd.poke64(W_INT, 64'h1);
		i = 0; while (i < 12000 && !irq) begin @(negedge clk); i = i + 1; end
		check(irq, "INT word raises irq");
		dd.poke64(W_INT, 64'h0);
		i = 0; while (i < 12000 && irq) begin @(negedge clk); i = i + 1; end
		check(!irq, "INT word clears irq");

		// ── data-port read RPC ───────────────────────────────────────────
		fork
			begin : rpc_daemon
				reg [63:0] entry;
				reg [31:0] wp;
				integer k;
				wp = dd.peek64(W_WPTR);
				k = 0;
				while (k < 20000 && dd.peek64(W_WPTR) == wp) begin
					@(negedge clk); k = k + 1;
				end
				entry = dd.peek64(W_RING + (wp & 15'hFF));
				if (entry[0] && entry[3:1] == 3'd2)
					dd.poke64(W_RPC, {32'b0, 16'hCAFE, entry[31:24], 8'h01});
			end
			begin
				cpu_cycle(32'hFE0E0000, 1, 1, 1, 0, 1, rd, cl);
			end
		join
		check(cl && rd == 16'hCAFE, "data-port read RPC returns CAFE");

		// unanswered data-port read -> watchdog $FFFF (DP_WD_BITS=10)
		cpu_cycle(32'hFE0E0004, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hFFFF, "unanswered data-port read times out to FFFF");

		// ── unmodelled shape: LDS-only reg-window byte ───────────────────
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFE0E0004, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hFFFF, "LDS-only reg byte serves FFFF");
		check(dd.peek64(W_WPTR) == wp0, "LDS-only reg byte posts no doorbell");

		if (fails == 0) $display("ALL PASS (tb_pds_enet)");
		else            $display("%0d FAILURES (tb_pds_enet)", fails);
		$finish;
	end

	initial begin
		#80_000_000;   // 80 ms wall-stop
		$display("TIMEOUT (tb_pds_enet)");
		$finish;
	end

endmodule
