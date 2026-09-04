/* tb_pds_enet.v — unit test for the PDS Ethernet card front-end
 * (rtl/pds/pds_enet.sv, v2: Apple Ethernet LC Twisted Pair / SONIC) against
 * the behavioral DDR3 model (sim_ddr3.v).
 *
 * The TB plays BOTH sides: it drives TG68-style bus cycles (address + AS +
 * UDS/LDS, waiting on card_ack = the top's stretched DTACK) and plays the
 * Main_MiSTer support/mac host (stages MAGIC / shadows / MACPROM / INT in the
 * DDR3 window, decodes doorbell ring entries).
 *
 * WHAT IT CHECKS:
 *   1. Presence gate: without MAGIC the card never claims; the v1 MAGIC
 *      ("McLCETH1") is REJECTED (version gate); v2 MAGIC + a guest-reset
 *      window latches presence (sticky-rise).
 *   2. SONIC registers: word read serves the staged shadow (index = A[7:2],
 *      no inversion); UDS/LDS byte reads serve the right halves; the $100
 *      bank mirrors at +$100; the +2 longword half serves $FFFF with no
 *      doorbell; word write posts a REG_WR ring entry + wptr publish; byte
 *      writes are ignored (complete, no doorbell).
 *   3. MAC PROM: byte reads serve the cooked MACPROM word bytes at both
 *      windows ($FE04'0000 and $FE40'0000), mirroring every 8; any word-wide
 *      read returns the $0028 magic; PROM writes complete without a doorbell.
 *   4. declROM: flat 32 KiB at $FEFF'8000 — the FHeader tail (byteLanes $0F,
 *      testPattern) reads back from the staged window; $FEFF'7FFE (below the
 *      ROM) is NOT claimed.
 *   5. Warm guest reset posts TAG_RESET; the presence-establishing reset
 *      posts nothing.
 *   6. INT word -> irq output (and clears).
 *   7. Guest-RAM DMA engine (Phase 3): DMA_CMD/DMA_STAT seq handshake; both
 *      directions move bytes between a fake SDRAM (served on the eth port)
 *      and the XFER window with the lane convention intact; the V8 RAM
 *      translation known-answers (SIMM, motherboard-high, mirror — these
 *      guard the DUPLICATED translation in pds_enet.sv against drift from
 *      addrController_top.v); error reporting for out-of-range / odd
 *      address; zero-length no-op; a guest declROM read still completes
 *      while a DMA block is in flight.
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

	reg  [7:0] ram_config_phys = 8'hC4;   // default: 8MB SIMM (bits[7:6]=11)
	wire       eth_req, eth_we;
	wire [23:0] eth_addr;
	wire [15:0] eth_din;
	reg        eth_ack_r = 0;
	reg [15:0] eth_dout_r = 0;

	pds_enet dut (
		.clk_sys(clk), .rst_core(rst_core), .rst_guest(rst_guest), .ena_osd(ena_osd),
		.ram_config_phys(ram_config_phys),
		.eth_req(eth_req), .eth_we(eth_we), .eth_addr(eth_addr), .eth_din(eth_din),
		.eth_ack(eth_ack_r), .eth_dout(eth_dout_r),
		.cpuAddr(cpuAddr), .cpuDataIn(cpuDataIn),
		._cpuAS(_cpuAS), ._cpuUDS(_cpuUDS), ._cpuLDS(_cpuLDS), ._cpuRW(_cpuRW),
		.card_sel(card_sel), .card_ack(card_ack), .card_dout(card_dout), .irq(irq),
		.mem_addr(m_addr), .mem_burst(m_burst), .mem_rd(m_rd), .mem_we(m_we),
		.mem_wdata(m_wdata), .mem_be(m_be), .mem_rdata(m_rdata),
		.mem_rvalid(m_rvalid), .mem_busy(m_busy)
	);

	// fake guest SDRAM served on the eth port — 2-edge reads like sim_ram.v
	reg [15:0] sdr_mem [0:8388607];
	reg        sdr_d = 0;
	always @(posedge clk) begin
		if (eth_req && !eth_ack_r) begin
			if (eth_we) begin
				sdr_mem[eth_addr[22:0]] <= eth_din;
				eth_ack_r <= 1;
			end else begin
				sdr_d <= 1;
				if (sdr_d) begin
					eth_dout_r <= sdr_mem[eth_addr[22:0]];
					eth_ack_r  <= 1;
				end
			end
		end
		if (!eth_req) begin
			eth_ack_r <= 0;
			sdr_d     <= 0;
		end
	end

	sim_ddr3 dd (
		.clk(clk), .addr(m_addr), .burst(m_burst), .rd(m_rd), .we(m_we),
		.wdata(m_wdata), .be(m_be), .rdata(m_rdata), .rvalid(m_rvalid), .busy(m_busy)
	);

	localparam [63:0] MAGIC_V1 = 64'h4D634C43_45544831;
	localparam [63:0] MAGIC    = 64'h4D634C43_45544832;
	localparam W_MAGIC = 15'h4000, W_WPTR = 15'h4001, W_SHAD = 15'h4002,
	           W_INT = 15'h4012, W_MACPROM = 15'h4013, W_RING = 15'h4100,
	           W_XFER = 15'h0000, W_DMACMD = 15'h4016, W_DMASTAT = 15'h4017,
	           W_RPTR = 15'h4015;

	// post a DMA command and wait for its seq echo in DMA_STAT
	task dma_run(input [7:0] seq, input dir, input [23:0] gaddr,
	             input [15:0] count, output [8:0] stat);
		integer k;
		begin
			dd.poke64(W_DMACMD, ({48'b0, count} << 40) | ({40'b0, gaddr} << 16)
			                    | ({63'b0, dir} << 8) | {56'b0, seq});
			k = 0;
			while (k < 300000 && (dd.peek64(W_DMASTAT) & 64'hFF) != {56'b0, seq}) begin
				@(negedge clk); k = k + 1;
			end
			stat = dd.peek64(W_DMASTAT) & 64'h1FF;
		end
	endtask
	reg [8:0] dstat;

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

	// cpu_cycle gives up after 3000 cycles; the watchdog fires at 130000.
	task cpu_cycle_slow(input [31:0] addr, input integer maxn,
	                    output [15:0] rdata, output claimed);
		integer n;
		begin
			@(negedge clk);
			cpuAddr = addr; _cpuRW = 1; cpuDataIn = 0;
			_cpuAS = 0; _cpuUDS = 0; _cpuLDS = 0;
			claimed = 0; rdata = 16'hFFFF; n = 0;
			while (n < maxn && !(card_sel && card_ack)) begin
				@(negedge clk); n = n + 1;
			end
			if (card_sel && card_ack) begin claimed = 1; rdata = card_dout; end
			_cpuAS = 1; _cpuUDS = 1; _cpuLDS = 1; _cpuRW = 1;
			@(negedge clk); @(negedge clk);
		end
	endtask

	reg [15:0] rd; reg cl;
	reg [63:0] e;
	integer i;
	reg [31:0] wp0;

	initial begin
		// ── reset, no host ───────────────────────────────────────────────
		repeat (10) @(negedge clk);
		rst_core = 0;
		repeat (20) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		cpu_cycle(32'hFE000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "no MAGIC: card does not claim $FE000000");

		// ── stale v1 daemon: MAGIC version gate must reject it ───────────
		dd.poke64(W_MAGIC, MAGIC_V1);
		repeat (70000) @(negedge clk);      // absent-cadence MAGIC poll
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);
		cpu_cycle(32'hFE000000, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "v1 MAGIC (McLCETH1) is rejected");

		// ── v2 host appears; presence latches during a guest reset ───────
		dd.poke64(W_MAGIC, MAGIC);
		repeat (70000) @(negedge clk);
		rst_guest = 1;
		repeat (300) @(negedge clk);
		rst_guest = 0;
		repeat (20) @(negedge clk);

		// The establishing reset must NOT have posted an event (present was
		// still 0 at its rising edge). Note wptr word = 0 was published once
		// at init; count stays 0.
		check(dd.peek64(W_WPTR) == 0, "presence-establishing reset posts no event");

		// ── SONIC register shadows ───────────────────────────────────────
		// ISR = reg 5 -> shadow word 1, lane 1; guest addr $FE00'0014
		dd.poke64(W_SHAD + 15'd1, 64'h0000_0000_8C41_0000);
		// TCR = reg 3 -> shadow word 0, lane 3
		dd.poke64(W_SHAD + 15'd0, 64'h00F2_0000_0000_0000);
		repeat (25000) @(negedge clk);      // let a full poll round pass
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h8C41, "ISR word read serves shadow (reg 5 @ +$14)");
		cpu_cycle(32'hFE00000C, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h00F2, "TCR word read serves shadow (reg 3 @ +$0C)");
		cpu_cycle(32'hFE000114, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h8C41, "register bank mirrors at +$100");
		cpu_cycle(32'hFE000014, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h8C, "UDS byte read serves reg[15:8]");
		cpu_cycle(32'hFE000014, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h41, "LDS byte read serves reg[7:0]");

		// ── 24-bit minor-slot form (2026-08-26 tester-wedge regression) ──
		// A FRESH (24-bit) System 7.5 reaches the card at $00E0'0000+off —
		// the decode must serve it exactly like the 32-bit form. This was
		// the "testers can't use ethernet" wedge: 32-bit-only decode made
		// every fresh-System driver poll phantom $FFFF forever.
		cpu_cycle(32'h00E00014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h8C41, "24-bit ISR read serves shadow ($00E0'0014)");
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'h00E00004, 0, 1, 1, 16'h1234, 1, rd, cl);
		check(cl, "24-bit reg word write claims + completes");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[9:4] == 6'd1 && e[31:16] == 16'h1234,
		      "24-bit write posts REG_WR ring entry (reg 1, data $1234)");
		check(dd.peek64(W_WPTR) == wp0 + 64'd1, "24-bit write advances WPTR");

		// +2 half of the longword: stub, no doorbell
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFE000016, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'hFFFF, "+2 longword half serves $FFFF");
		check(dd.peek64(W_WPTR) == wp0, "+2 read posts no doorbell");

		// ── register write doorbell ──────────────────────────────────────
		cpu_cycle(32'hFE000004, 0, 1, 1, 16'h8C41, 1, rd, cl);   // DCR (reg 1)
		check(cl, "reg word write (DCR @ +$04) claims + completes");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[3:1] == 3'd0 && e[9:4] == 6'd1 && e[31:16] == 16'h8C41,
		      "REG_WR entry: reg 1, data $8C41");
		check(dd.peek64(W_WPTR) == wp0 + 1, "wptr published");

		// byte write to the reg window: ignored (complete, no doorbell)
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFE000004, 0, 1, 0, 16'hAAAA, 1, rd, cl);
		check(cl, "byte write to reg window completes");
		check(dd.peek64(W_WPTR) == wp0, "byte write posts no doorbell");

		// ── MAC PROM ─────────────────────────────────────────────────────
		// cooked PROM: bytes 0..7 = 10 00 E0 48 2C 6A 00 9E (byte k at lane k)
		dd.poke64(W_MACPROM, 64'h9E00_6A2C_48E0_0010);
		repeat (25000) @(negedge clk);
		cpu_cycle(32'hFE040000, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h10, "PROM byte 0 at $FE04'0000 (UDS)");
		cpu_cycle(32'hFE040000, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h00, "PROM byte 1 at $FE04'0001 (LDS)");
		cpu_cycle(32'hFE400004, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h2C, "PROM byte 4 at the $FE40'0000 alias");
		cpu_cycle(32'hFE040006, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'h9E, "PROM checksum byte 7 (LDS @ +6)");
		cpu_cycle(32'hFE040008, 1, 1, 0, 0, 1, rd, cl);
		check(cl && rd[15:8] == 8'h10, "PROM mirrors every 8 bytes");
		cpu_cycle(32'hFE040000, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0028, "word-wide PROM read returns the $0028 magic");
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFE040000, 0, 1, 1, 16'h1234, 1, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0, "PROM write completes, no doorbell");

		// ── declROM (flat 32K at $FEFF'8000) ─────────────────────────────
		// stage the FHeader tail: window word $3FFF = guest $FEFF'FFF8-FF =
		// rev fmt testPattern[4] reserved byteLanes = 01 01 5A 932B C7 00 0F
		dd.poke64(15'h2000 + 15'h1FFF, 64'h0F00_C72B_935A_0101);
		cpu_cycle(32'hFEFFFFFE, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h000F, "declROM tail word: reserved+byteLanes $000F");
		cpu_cycle(32'hFEFFFFFA, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h5A93, "declROM testPattern hi word $5A93");
		cpu_cycle(32'hFEFFFFFC, 1, 0, 1, 0, 1, rd, cl);
		check(cl && rd[7:0] == 8'hC7, "declROM odd byte via LDS ($C7)");
		cpu_cycle(32'hFEFF7FFE, 1, 1, 1, 0, 0, rd, cl);
		check(!cl, "below the ROM ($FEFF'7FFE) is not claimed");
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFEFFFFFE, 0, 1, 1, 16'hDEAD, 1, rd, cl);
		check(cl && dd.peek64(W_WPTR) == wp0, "ROM write completes, no doorbell");

		// ── warm guest reset posts TAG_RESET ─────────────────────────────
		wp0 = dd.peek64(W_WPTR);
		rst_guest = 1;
		repeat (50) @(negedge clk);
		rst_guest = 0;
		repeat (50) @(negedge clk);
		check(dd.peek64(W_WPTR) == wp0 + 1, "warm guest reset posted an event");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[3:1] == 3'd1, "last event is TAG_RESET");

		// ── irq suppression timer (interrupt-ack livelock fix) ──
		// irq = Main's INT word, but held low for IRQ_SUPP (~60000 cyc) after
		// each guest ISR write, so the guest can't re-enter its handler on the
		// stale-high line. It ONLY delays irq's rising edge — never masks a bit,
		// never sticks, never fabricates — so it cannot deadlock or deliver a
		// spurious interrupt (the failure modes of the per-bit mask it replaces).
		dd.poke64(W_INT, 64'h1);                      // INT word -> irq (no recent ISR write)
		i = 0; while (i < 40000 && !irq) begin @(negedge clk); i = i + 1; end
		check(irq, "INT word raises irq when no ISR write is suppressing it");

		// guest writes ISR -> irq suppressed immediately, INT word still 1
		wp0 = dd.peek64(W_WPTR);
		cpu_cycle(32'hFE000014, 0, 1, 1, 16'h0200, 1, rd, cl);   // ISR = reg 5 @ +$14
		check(cl, "guest ISR clear write claims + completes");
		i = 0; while (i < 100 && irq) begin @(negedge clk); i = i + 1; end
		check(!irq, "guest ISR write suppresses irq immediately (kills the re-entry livelock)");
		check(i < 40, "irq drop was immediate");
		e = dd.peek64(W_RING + (wp0[7:0] & 8'hFF));
		check(e[0] && e[9:4] == 6'd5 && e[31:16] == 16'h0200,
		      "the ISR clear still posts a REG_WR doorbell for Main");

		// irq stays suppressed through the round-trip window even though INT=1
		repeat (30000) @(negedge clk);
		check(!irq, "irq stays suppressed during the round-trip window");

		// after IRQ_SUPP expires, irq FOLLOWS the INT word again (it is still 1):
		// this proves it can never deadlock — a real pending interrupt always
		// gets through once the fixed window passes.
		i = 0; while (i < 60000 && !irq) begin @(negedge clk); i = i + 1; end
		check(irq, "irq re-follows the INT word after suppression expires (NO DEADLOCK)");

		// Main lowers the INT word -> irq drops (no suppression involved)
		dd.poke64(W_INT, 64'h0);
		i = 0; while (i < 40000 && irq) begin @(negedge clk); i = i + 1; end
		check(!irq, "irq clears when Main lowers the INT word");
		dd.poke64(W_SHAD + 15'd1, 64'h0);                     // cleanup

		// ── guest-RAM DMA engine ─────────────────────────────────────────
		for (i = 0; i < 32; i = i + 1) sdr_mem[23'h100800 + i] = 16'h1100 + i[15:0];

		// dir 0 (guest -> XFER), 8MB SIMM config: guest $001000 -> SDRAM
		// word $100000 + $800 (the SIMM known-answer)
		dma_run(8'd1, 1'b0, 24'h001000, 16'd16, dstat);
		check(dstat == 9'h001, "DMA read completes: STAT seq 1, no error");
		check(dd.peek64(W_XFER)     == 64'h0311_0211_0111_0011,
		      "XFER word 0: guest bytes in window lanes (SIMM translation)");
		check(dd.peek64(W_XFER + 1) == 64'h0711_0611_0511_0411,
		      "XFER word 1: second group gathered");

		// dir 1 (XFER -> guest): 12 bytes = 6 words, partial second group
		dd.poke64(W_XFER,     64'h44C3_33C2_22C1_11C0);
		dd.poke64(W_XFER + 1, 64'h0000_0000_66C5_55C4);
		sdr_mem[23'h101000] = 16'hFFFF;   // guards: beyond-count words
		sdr_mem[23'h101006] = 16'hFFFF;   //         must stay untouched
		dma_run(8'd2, 1'b1, 24'h002000, 16'd12, dstat);
		check(dstat == 9'h002, "DMA write completes: STAT seq 2, no error");
		check(sdr_mem[23'h101000] == 16'hC011 && sdr_mem[23'h101001] == 16'hC122 &&
		      sdr_mem[23'h101002] == 16'hC233 && sdr_mem[23'h101003] == 16'hC344 &&
		      sdr_mem[23'h101004] == 16'hC455 && sdr_mem[23'h101005] == 16'hC566,
		      "DMA write: 6 words scattered to guest RAM");
		check(sdr_mem[23'h101006] == 16'hFFFF, "DMA write stops at count");

		// motherboard-high known-answer: guest $800010 -> SDRAM word $000008
		sdr_mem[23'h000008] = 16'hB007;
		dma_run(8'd3, 1'b0, 24'h800010, 16'd2, dstat);
		check(dstat == 9'h003 && (dd.peek64(W_XFER) & 64'hFFFF) == 64'h07B0,
		      "motherboard-high translation ($800010 -> word $000008)");

		// mirror known-answer: 4MB SIMM config, guest $500000 -> word $080000
		ram_config_phys = 8'h84;
		sdr_mem[23'h080000] = 16'h4A11;
		dma_run(8'd4, 1'b0, 24'h500000, 16'd2, dstat);
		check(dstat == 9'h004 && (dd.peek64(W_XFER) & 64'hFFFF) == 64'h114A,
		      "motherboard-mirror translation (4MB SIMM, $500000 -> word $080000)");
		ram_config_phys = 8'hC4;

		// error paths
		dma_run(8'd5, 1'b0, 24'hA00000, 16'd2, dstat);
		check(dstat == 9'h105, "out-of-range DMA ($A00000) reports the error bit");
		dma_run(8'd6, 1'b0, 24'h001001, 16'd2, dstat);
		check(dstat == 9'h106, "odd guest address reports the error bit");
		dma_run(8'd7, 1'b0, 24'h001000, 16'd0, dstat);
		check(dstat == 9'h007, "zero-length DMA is a clean no-op");

		// a guest declROM read completes while a DMA block is in flight
		dd.poke64(W_DMACMD, ({48'b0, 16'd128} << 40) | ({40'b0, 24'h001000} << 16)
		                    | 64'h08);
		cpu_cycle(32'hFEFFFFFE, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h000F, "declROM read serves during an active DMA");
		i = 0;
		while (i < 300000 && (dd.peek64(W_DMASTAT) & 64'hFF) != 64'h08) begin
			@(negedge clk); i = i + 1;
		end
		check((dd.peek64(W_DMASTAT) & 64'h1FF) == 9'h008,
		      "the interleaved DMA still completes (seq 8)");

		// ── 8. host-access watchdog ──────────────────────────────────────
		// Nothing above may have tripped it: a spurious fire drops guest
		// register writes during healthy traffic.
		check(dut.h_wd_fired === 1'b0, "watchdog silent through normal traffic");

		// Stall DDR3 so a declROM read can never complete. Without the
		// watchdog this is the hardware freeze of 2026-08-23 exactly:
		// card_ack never asserts and the 68020 waits forever mid-cycle.
		dd.stall = 1'b1;
		cpu_cycle_slow(32'hFEFFFFFE, 200000, rd, cl);
		check(cl,                       "stalled cycle still retires (DTACK asserted)");
		check(rd == 16'hFFFF,           "watchdog retires with open-bus $FFFF");
		check(dut.h_wd_fired === 1'b1, "watchdog fired");
		dd.stall = 1'b0;

		// the abandoned read's DDR3 answer arrives now: it must NOT retire
		// the next access early with its stale data.
		repeat (200) @(negedge clk);
		cpu_cycle(32'hFEFFFFFE, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h000F, "card still serves correctly after a watchdog fire");

		// ── timed ISR clear-mask ─────────────────────────────────────────
		// The .ENET dispatch loop re-reads ISR after each ack and spins until
		// the acked bits read back clear; the shadow only changes after the
		// doorbell round-trips through Main (~ms). The mask makes an ack
		// stick on the very next read, per bit, and expires on a timer.
		dd.poke64(W_SHAD + 1, {16'h0000, 16'h0000, 16'h0280, 16'h66F1});
		repeat (60000) @(negedge clk);   // let any prior isr_mask expire
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0280, "ISR read serves the raw shadow before any ack");
		cpu_cycle(32'hFE000014, 0, 1, 1, 16'h0200, 1, rd, cl);   // ack TXDN
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0080, "acked bit reads back clear at once (shadow untouched)");
		cpu_cycle(32'hFE000010, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h66F1, "non-ISR register reads stay unmasked");
		cpu_cycle(32'hFE000014, 0, 1, 1, 16'h0080, 1, rd, cl);   // ack TC too
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0000, "second ack accumulates into the mask");
		// a NEW event on an unmasked bit stays visible through the mask
		// (each poke needs one shadow poll pass ~0.66 ms to reach the DUT;
		// 25000 cycles waits that out while keeping the mask armed)
		dd.poke64(W_SHAD + 1, {16'h0000, 16'h0000, 16'h0680, 16'h66F1});
		repeat (25000) @(negedge clk);
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0400, "new PKTRX visible while TXDN/TC stay masked (per-bit)");
		// Main applies the acks and pushes the truthful shadow: agreement
		dd.poke64(W_SHAD + 1, {16'h0000, 16'h0000, 16'h0400, 16'h66F1});
		repeat (25000) @(negedge clk);
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0400, "mask agrees once Main's shadow catches up");
		// expiry: one IRQ_SUPP after the LAST ack the mask drops, so a bit
		// the shadow still shows set becomes visible again (never a loss)
		dd.poke64(W_SHAD + 1, {16'h0000, 16'h0000, 16'h0280, 16'h66F1});
		repeat (61000) @(negedge clk);
		cpu_cycle(32'hFE000014, 1, 1, 1, 0, 1, rd, cl);
		check(cl && rd == 16'h0280, "mask expires after its window (shadow truth returns)");

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
