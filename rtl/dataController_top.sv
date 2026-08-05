module dataController_top(
	// clocks:
	input clk32,					// 32.5 MHz pixel clock
	input clk8_en_p,
	input clk8_en_n,
	input scsi_pclk_en,			// V8 SCSI_PCLK / SCC RTxC enable (~3.672 MHz)
	input E_rising,
	input E_falling,

	// system control:
	input _systemReset,
	input pseudovia_irq,  // PseudoVIA interrupt (VBlank, slots)

	// 68000 CPU control:
	output _cpuReset,
	output [2:0] _cpuIPL,

	// 68000 CPU memory interface:
	input [15:0] cpuDataIn,
	input [3:0] cpuAddrRegHi, // A12-A9
	input [2:0] cpuAddrRegMid, // A6-A4
	input [1:0] cpuAddrRegLo, // A2-A1
	input cpuLongword,         // TG68 longword-access flag (for SCSI pseudo-DMA)
	input _cpuUDS,
	input _cpuLDS,	
	input _cpuRW,
	output [15:0] cpuDataOut,
	
	// peripherals:
	input selectSCSI,
	input selectSCSIDMA,    // SCSI pseudo-DMA window (DACK)
	output scsiDREQ,        // SCSI pseudo-DMA request (gates CPU DTACK upstream)
	output scsiIRQ,         // NCR5380 latched IRQ (level) -> pseudo-VIA IFR bit 3
	// JTAG probe feeds (dbg_probes.sv in the FPGA top; unconnected in sim)
	output [15:0] dbg_scsi,   // selection/arbitration: out_en/SEL/BSY/bsy/MOUNTED/data
	output [15:0] dbg_scsi2,  // target phases + HPS io handshake
	output [15:0] dbg_scsi4,  // bus-reset count + per-target completion flags
	output [15:0] dbg_scsi5,  // per-target last-opcode bitmap
	output [31:0] dbg_ncr,    // host-side pseudo-DMA state + DACK beat count
	output [31:0] dbg_cda0,   // CD-audio engine TOC/state (JTAG CDA0)
	output [31:0] dbg_cda1,   // CD target command visibility (JTAG CDA1)
	output [31:0] dbg_cda2,   // last 0xC1 CDB (JTAG CDA2)
	output [31:0] dbg_cda3,   // last play-class CDB hi (JTAG CDA3)
	output [31:0] dbg_cda4,   // last play-class CDB lo (JTAG CDA4)
	output [31:0] dbg_cdur,   // cd_audio underrun counters (JTAG CDUR)
	output [31:0] dbg_ncr2,   // req_deferred/req_bus + IRQ machine + counters
	output [31:0] dbg_wr,     // write-stall snapshot (DATA_IN target)
	output [31:0] dbg_wrfb,   // write first-beat forensics (JTAG WRFB)
	output [31:0] dbg_ism_flpe, // swim ISM error/overrun counters (JTAG FLPE)
	output [31:0] dbg_ring0,  // disk-0 read-ring bookkeeping (anchor feed)
	output [31:0] dbg_ring1,  // disk-1 read-ring bookkeeping (anchor feed)
	input selectSCC,
	input selectIWM,
	input selectVIA,
	input _cpuVMA,
	
	input selectASC,
	input [7:0] asc_data_in,
	
	input selectAriel,
	input [7:0] ariel_data_in,
	input selectPseudoVIA,
	input [7:0] pseudovia_data_in,
	input selectUnmapped,

	// RAM/ROM:
	input cpuBusControl,
	input [15:0] memoryDataIn,
	output [15:0] memoryDataOut,
	input memoryLatch,
	
	// keyboard:
	input [10:0] ps2_key,
	output capslock, 
	 
	// mouse:
	input [24:0] ps2_mouse,
	
	// serial:
	input serialIn, 
	output serialOut,	
	input serialCTS,
	output serialRTS,

	// RTC
	input [32:0] timestamp,

	// video:
	input _hblank,
	input _vblank,
	output vid_alt,

	// (legacy Mac-Plus audio DMA path removed in Commit C — ASC owns audio now)
	
	// misc
	input [1:0] insertDisk,
	input [1:0] diskSides,
	input [1:0] diskMFM,    // disk is MFM-format (ISM path): {ext,int}
	input [1:0] diskHD,     // disk is 1.44MB HD (vs 720K DD): {ext,int}
	output [1:0] diskEject,
	output [1:0] diskMotor,
	output [1:0] diskAct,

	output [21:0] dskReadAddrInt,
	input dskReadAckInt,
	output [21:0] dskReadAddrExt,
	input dskReadAckExt,

	// connections to io controller
	input   [SCSI_DEVS-1:0] img_mounted,
	input            [31:0] img_size,
	output           [31:0] io_lba[SCSI_DEVS],
	output  [SCSI_DEVS-1:0] io_rd,
	output  [SCSI_DEVS-1:0] io_wr,
	input   [SCSI_DEVS-1:0] io_ack,
	input             [7:0] sd_buff_addr,
	input             [4:0] sd_buff_addr_hi,  // hps_io addr[12:8]: CD whole-frame bursts
	input            [15:0] sd_buff_dout,
	output           [15:0] sd_buff_din[SCSI_DEVS],
	input                   sd_buff_wr,

	// ---- BlueSCSI Toolbox dedicated block interface (primary SCSI target) ----
	input                   tb_mounted,
	output           [31:0] tb_lba,
	output                  tb_rd,
	output                  tb_wr,
	input                   tb_ack,
	output           [15:0] tb_buff_din,

	// ---- BlueSCSI Toolbox CD Changer block interface (CD target / ID 3) ------
	input                   cdtb_mounted,
	output           [31:0] cdtb_lba,
	output                  cdtb_rd,
	output                  cdtb_wr,
	input                   cdtb_ack,
	output           [15:0] cdtb_buff_din,

	// CD audio PCM (from the SCSI CDROM target's playback engine)
	output signed    [15:0] cd_snd_l,
	output signed    [15:0] cd_snd_r,

	// ---- CD-ROM target (SCSI ID 3) dedicated block interface ----
	input                   cd_enable,
	input                   cd_img_mounted,
	output           [31:0] cd_io_lba,
	output                  cd_io_rd,
	output                  cd_io_wr,
	input                   cd_io_ack,
	output           [15:0] cd_sd_buff_din,

	// ---- PRAM persistence pass-through (to the Egret's pram[]) ----
	input             [7:0] pram_load_addr,
	input             [7:0] pram_load_data,
	input                   pram_load_wr,
	input             [7:0] pram_save_addr,
	output            [7:0] pram_save_data,
	output                  pram_wr_stb,
	input                   pram_ready,

	// VIA SR debug outputs for on-screen indicator
	output [2:0]  via_sr_dbg_bit_cnt,
	output        via_sr_dbg_edge_pending,
	output        via_sr_dbg_fall_pending,
	output [7:0]  via_sr_dbg_shift_reg,
	output        via_sr_dbg_active,
	output        via_sr_dbg_dir,
	output        via_sr_dbg_cb1,
	output        via_sr_dbg_cb2,

	// Egret debug outputs for on-screen indicator
	output        egret_dbg_running,       // HC05 not in reset
	output        egret_dbg_port_test_done,
	output        egret_dbg_handshake_done,
	output        egret_dbg_treq,          // TREQ asserted
	output        egret_dbg_tip,           // TIP from VIA (synced in Egret)
	output        egret_dbg_byteack,       // BYTEACK from VIA (synced in Egret)
	output        egret_dbg_reset_680x0,   // Egret holding 68K in reset
	output        egret_dbg_cpu_reset_out, // Final _cpuReset signal

	// Floppy diagnostic passthroughs (PFLP probes; internal drive)
	output [15:0] dbg_flp_byte_cnt,
	output [15:0] dbg_flp_miss_cnt,
	output [7:0]  dbg_flp_disk_data,
	output [6:0]  dbg_flp_track,
	output        dbg_flp_side,
	output [15:0] dbg_flp_step_cnt,
	output [7:0]  dbg_iwm_latch,
	output        dbg_flp_byte_stb,  // 1-clk delivered-byte strobe (capture ring)
	output [7:0]  dbg_flp_raw,      // pre-encoder SDRAM fetch latch (internal drive)
	output [31:0] dbg_ism_state,
	output [15:0] dbg_flp_strb_cnt,
	output [15:0] dbg_flp_strb_en_cnt,
	output [23:0] dbg_flp_strb_last,
	output [8:0]  dbg_flp_rej_step,
	output [7:0]  dbg_flp_status,
	output [21:0] dbg_flp_gcr_addr, // live GCR fetch address (internal drive)
	output [31:0] dbg_ism_verdict,  // {b1_hot,b5_hot} over handshake reads
	output [15:0] dbg_ism_pop2      // pops taken with the FIFO at 2 entries
);
	
	parameter SCSI_DEVS = 2;
	
	// Mac-Plus-style sound DMA removed — ASC handles all audio in the LC core.


	// CPU reset generation
	// Mac LC boot sequence: Egret controls when 68000 comes out of reset via Port C bit 3
	// We also need a minimum reset time for the 68000 (100ms = 800,000 clocks of clk8)
	// The 68000 reset is released when:
	//   1. The minimum reset time has passed
	//   2. _systemReset is not asserted
	//   3. Egret has released reset_680x0 (Port C bit 3 = 1)

	reg [19:0] resetDelay; // 20 bits = 1 million
	wire minResetPassed = (resetDelay == 0);

	// Egret controls 68000 reset via Port C bit 3
`ifdef USE_EGRET_CPU
	wire egret_reset_680x0;  // 1 = hold 68000 in reset, 0 = release
`endif

	initial begin
		// force a reset when the FPGA configuration is completed
`ifdef SIMULATION
		// In simulation, use shorter reset delay (~1ms at 8MHz)
		// This allows faster boot testing while still giving hardware time to stabilize
		// GEMINI: Increased to 0x0200 (512 cycles) to ensure Egret starts (256 cycles) BEFORE CPU.
		resetDelay <= 20'h0200;  
`else
		resetDelay <= 20'hFFFFF;
`endif
	end

	always @(posedge clk32 or negedge _systemReset) begin
		if (_systemReset == 1'b0) begin
`ifdef SIMULATION
			resetDelay <= 20'h0200;
`else
			resetDelay <= 20'hFFFFF;
`endif
		end
		else if (clk8_en_p && !minResetPassed) begin
			resetDelay <= resetDelay - 1'b1;
		end
	end

`ifdef USE_EGRET_CPU
	// With real Egret: 68000 reset is controlled by Egret (but respect minimum time)
	assign _cpuReset = (minResetPassed && !egret_reset_680x0) ? 1'b1 : 1'b0;
`else
	// Without Egret: just use the timer
	assign _cpuReset = minResetPassed ? 1'b1 : 1'b0;
`endif

	// Egret reset generation - Egret needs to start BEFORE the 68000
	// The real Egret starts very early and controls when the 68000 comes out of reset
	// IMPORTANT: In simulation, wait for _systemReset to go high (ROM download complete)
	// before releasing Egret, otherwise Egret times out before 68020 can respond.
	// ALSO: Wait for minResetPassed so Egret doesn't start (and assert TREQ) while
	// 68020 is held in resetDelay.
	reg [9:0] egretBootCounter = 0;
	wire egretReset = (egretBootCounter < 10'd256) || !minResetPassed;
	// NOTE (2026-06-12): wiring the 68k RESET instruction into the NCR/SCC
	// resets here REGRESSED cold boot to a blinking `?` — the LC ROM issues
	// RESET at ~T+4s AFTER initializing the SCSI chip at ~T+2.8s and expects
	// that setup to survive. Do NOT hard-reset the NCR from the RESET
	// instruction. The 7.x post-enabler-restart ID-6 skip remains open
	// (docs/findings_pds_phantom_card_2026-06-12.md).

	always @(posedge clk32) begin
		if (!_systemReset) begin
			// Keep counter at 0 while system reset is active
			egretBootCounter <= 0;
		end
		else if (egretBootCounter < 10'd512) begin  // Stop counting once well past threshold
			if (clk8_en_p)
				egretBootCounter <= egretBootCounter + 1'b1;
		end
	end

`ifdef SIMULATION
	reg [31:0] dc_debug_count = 0;
	reg egretReset_prev = 1;
`ifdef USE_EGRET_CPU
	reg egret_reset_680x0_prev = 1;
	reg cpuReset_prev = 0;
`endif
	always @(posedge clk32) begin
		dc_debug_count <= dc_debug_count + 1;
		egretReset_prev <= egretReset;
		if (egretReset != egretReset_prev) begin
			$display("DC[%0d]: egretReset %s (egretBootCounter=%0d)",
			         dc_debug_count, egretReset ? "ASSERTED" : "RELEASED", egretBootCounter);
		end
`ifdef USE_EGRET_CPU
		egret_reset_680x0_prev <= egret_reset_680x0;
		cpuReset_prev <= _cpuReset;
		// Track when Egret releases/asserts 68000 reset
		if (egret_reset_680x0 != egret_reset_680x0_prev) begin
			$display("DC[%0d]: Egret %s 68000 reset (minResetPassed=%b, _cpuReset=%b)",
			         dc_debug_count,
			         egret_reset_680x0 ? "ASSERTS" : "RELEASES",
			         minResetPassed, _cpuReset);
		end
		// Track when 68000 actually comes out of reset
		if (_cpuReset != cpuReset_prev) begin
			$display("DC[%0d]: *** 68000 reset %s *** (egret_reset=%b, minResetPassed=%b)",
			         dc_debug_count,
			         _cpuReset ? "RELEASED" : "ASSERTED",
			         egret_reset_680x0, minResetPassed);
		end
`endif
	end
`endif
	
	// interconnects
	wire SEL;
	wire _viaIrq, _sccIrq, sccWReq;
	wire [15:0] viaDataOut;
	wire [15:0] swimDataOut;
	wire [7:0] sccDataOut;
	wire [15:0] scsiDataOut;   // 16-bit: ncr5380 returns word for pseudo-DMA, byte-duplicated otherwise
	wire mouseX1, mouseX2, mouseY1, mouseY2, mouseButton;
	
	// Mac LC interrupt priorities (active low encoding: 111=none, 110=1, 101=2, 011=4, etc.)
	// Level 1: VIA1
	// Level 2: PseudoVIA (VBlank, slot interrupts)
	// Level 4: SCC
	assign _cpuIPL =
		!_sccIrq      ? 3'b011 :   // Level 4: SCC (highest priority)
		pseudovia_irq ? 3'b101 :   // Level 2: PseudoVIA
		!_viaIrq      ? 3'b110 :   // Level 1: VIA1
		3'b111;                     // No interrupt
		

	reg [15:0] cpu_data;
	always @(posedge clk32) if (cpuBusControl && memoryLatch) cpu_data <= memoryDataIn;

	// CPU-side data output mux
    wire [15:0] viaDataOut_full = viaDataOut;
    wire [15:0] sccDataOut_full = { sccDataOut, sccDataOut };
    // scsiDataOut is already 16-bit: ncr5380 returns cur_data_pair on word
    // pseudo-DMA reads and { rdata8, rdata8 } otherwise — no duplication here.
    wire [15:0] arielDataOut_full = {ariel_data_in, ariel_data_in};
    wire [15:0] pviaDataOut_full = {pseudovia_data_in, pseudovia_data_in};
    wire [15:0] ascDataOut_full = {asc_data_in, asc_data_in};

    assign cpuDataOut = selectIWM ? swimDataOut :
                        selectVIA ? viaDataOut_full :
                        selectSCC ? sccDataOut_full :
                        selectSCSI ? scsiDataOut :
                        selectAriel ? arielDataOut_full :
                        selectPseudoVIA ? pviaDataOut_full :
                        selectASC ? ascDataOut_full :
                        // Unmapped reads: return 16'hFFFF (MAME's open-bus
                        // convention). Previously returned 16'h0000 which was
                        // deterministic — the boot ROM's RAM-probe XOR-pattern
                        // test cascaded zeros through unmapped SIMM addresses
                        // and falsely concluded "RAM here, value = 0" instead
                        // of "no RAM here", because (a) the unmapped writes
                        // were silently dropped (_ramWE not asserted), and
                        // (b) the subsequent read returned 0, matching the
                        // 0 that the XOR test had cascaded. 0xFFFF is the
                        // conventional "open bus" value that the probe's
                        // write-pattern/read-mismatch check correctly rejects.
                        selectUnmapped ? 16'hFFFF :
                        (cpuBusControl && memoryLatch) ? memoryDataIn : cpu_data;


    always @(posedge clk32) begin
        if (cpuBusControl && memoryLatch) begin
            if (selectVIA) begin
                if (_cpuRW) begin
                    // $display("PERIPH: READ VIA reg=%h data=%h @%0t", cpuAddrRegHi, viaDataOut_full, $time);
                end else begin
                    // $display("PERIPH: WRITE VIA reg=%h data=%h @%0t", cpuAddrRegHi, cpuDataIn, $time);
                end
            end
            if (selectPseudoVIA) begin
                if (_cpuRW) begin
                    // $display("PERIPH: READ PVIA reg=%h data=%h @%0t", {cpuAddrRegHi, cpuAddrRegMid, cpuAddrRegLo}, pviaDataOut_full, $time);
                end else begin
                    // $display("PERIPH: WRITE PVIA reg=%h data=%h @%0t", {cpuAddrRegHi, cpuAddrRegMid, cpuAddrRegLo}, cpuDataIn, $time);
                end
            end
            if (selectASC) begin
                if (_cpuRW) begin
                    // $display("PERIPH: READ ASC reg=%h data=%h @%0t", {cpuAddrRegHi, cpuAddrRegMid, cpuAddrRegLo}, ascDataOut_full, $time);
                end else begin
                    // $display("PERIPH: WRITE ASC reg=%h data=%h @%0t", {cpuAddrRegHi, cpuAddrRegMid, cpuAddrRegLo}, cpuDataIn, $time);
                end
            end
            if (selectSCC) begin
                if (_cpuRW) begin
                    // $display("PERIPH: READ SCC reg=%h data=%h @%0t", cpuAddrRegLo, sccDataOut_full, $time);
                end else begin
                    // $display("PERIPH: WRITE SCC reg=%h data=%h @%0t", cpuAddrRegLo, cpuDataIn, $time);
                end
            end
        end
    end
	
	// Memory-side
	assign memoryDataOut = cpuDataIn;

	// SCSI (NCR5380 with Mac LC pseudo-DMA — ported from lbmactwo)
	// Mac LC V8: SCSI (like SWIM) lives on the UPPER byte at even addresses, so
	// ior/iow gate on _cpuUDS and the 16-bit data path is duplicated/serialised
	// inside the ncr5380. DACK is the decoded pseudo-DMA window (selectSCSIDMA,
	// $F06000/$F12000) — NOT A9 as on the Mac Plus. dma_word/dma_longword/
	// dma_second_word describe the 68020 access width so the chip packs 1/2/4
	// bytes per cycle (matches MAME scsi_drq_r/w). dreq feeds the CPU DTACK
	// gate upstream so a pseudo-DMA cycle stalls until the target has data.
	// o_irq (latched phase-mismatch IRQ, cleared by a reg-7 read) and dreq
	// also feed the pseudo-VIA IFR bits 3/0 LEVEL-wise — the on-disk HD SC
	// 4.3 driver's async path sleeps on those flags between pseudo-DMA
	// chunks (Apple_Driver43 partition; the System 7 Welcome wedge).
	ncr5380 #(.DEVS(SCSI_DEVS)) scsi(
		.clk(clk32),
		.reset(!_cpuReset),
		.bus_cs(selectSCSI),
		.bus_rs(cpuAddrRegMid),
		.ior(_cpuRW && !_cpuUDS),
		.iow(!_cpuRW && !_cpuUDS),
		.dack(selectSCSIDMA),
		.dma_word(!_cpuUDS && !_cpuLDS),
		.dma_longword(cpuLongword),
		.dma_second_word(cpuAddrRegLo[0]),
		.dreq(scsiDREQ),
		.o_irq(scsiIRQ),
		.wdata(cpuDataIn),
		.rdata(scsiDataOut),

		// connections to io controller
		.img_mounted( img_mounted ),
		.img_size( img_size ),
		.io_lba ( io_lba ),
		.io_rd ( io_rd ),
		.io_wr ( io_wr ),
		.io_ack ( io_ack ),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_addr_hi(sd_buff_addr_hi),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr),

		// BlueSCSI Toolbox dedicated transport pass-through (primary target).
		.tb_mounted(tb_mounted),
		.tb_lba(tb_lba),
		.tb_rd(tb_rd),
		.tb_wr(tb_wr),
		.tb_ack(tb_ack),
		.tb_buff_din(tb_buff_din),

		// BlueSCSI Toolbox CD Changer transport pass-through (CD target).
		.cdtb_mounted(cdtb_mounted),
		.cdtb_lba(cdtb_lba),
		.cdtb_rd(cdtb_rd),
		.cdtb_wr(cdtb_wr),
		.cdtb_ack(cdtb_ack),
		.cdtb_buff_din(cdtb_buff_din),
		.cd_snd_l(cd_snd_l),
		.cd_snd_r(cd_snd_r),

		// CD-ROM target (SCSI ID 3) pass-through.
		.cd_enable(cd_enable),
		.cd_img_mounted(cd_img_mounted),
		.cd_io_lba(cd_io_lba),
		.cd_io_rd(cd_io_rd),
		.cd_io_wr(cd_io_wr),
		.cd_io_ack(cd_io_ack),
		.cd_sd_buff_din(cd_sd_buff_din),

		// JTAG probe feeds (consumed by dbg_probes.sv in the FPGA top)
		.dbg_scsi(dbg_scsi),
		.dbg_scsi2(dbg_scsi2),
		.dbg_scsi3(),
		.dbg_scsi4(dbg_scsi4),
		.dbg_scsi5(dbg_scsi5),
		.dbg_ncr(dbg_ncr),
		.dbg_cda0(dbg_cda0),
		.dbg_cda1(dbg_cda1),
		.dbg_cda2(dbg_cda2),
		.dbg_cda3(dbg_cda3),
		.dbg_cda4(dbg_cda4),
		.dbg_cdur(dbg_cdur),
		.dbg_ncr2(dbg_ncr2),
		.dbg_wr(dbg_wr),
		.dbg_wrfb(dbg_wrfb),
		.dbg_ring0(dbg_ring0),
		.dbg_ring1(dbg_ring1)
	);

	// onesec (VIA1 CA2) is derived from the fixed 60.15 Hz system tick — see
	// the tick_60hz block below. It must NOT count video vblanks: the vblank
	// rate is monitor-mode dependent (38.7 Hz in 640x480 VGA), which made a
	// "second" last 1.55 s.

	// VIA
	wire [2:0] snd_vol;
	wire snd_ena;
	wire driveSel; // internal drive select, 0 - upper, 1 - lower

	wire [7:0] via_pa_i, via_pa_o, via_pa_oe;
	wire [7:0] via_pb_i, via_pb_o, via_pb_oe;
	wire viaIrq;

	assign _viaIrq = ~viaIrq;

	// Port A - Mac LC configuration sense lines.
	// MAME v8.cpp via_in_a(): return 0xd4 | (config & 1), where config bit0 =
	// FPU present. The LC has no FPU, so the correct value is $D4 (not the old
	// $55 placeholder). NOTE: setting $D4 alone does NOT avoid the STM serial
	// monitor (confirmed: with $D4 our VIA matches MAME exactly yet still enters
	// STM), so the STM-entry root cause is elsewhere (boot state machine). Keep
	// $55 until the real cause is found, to avoid mixing unconfirmed changes.
	assign via_pa_i = 8'h55;
	// Sound volume still comes from PA[2:0] output latch
	assign snd_vol = ~via_pa_oe[2:0] | via_pa_o[2:0];
	assign driveSel = ~via_pa_oe[4] | via_pa_o[4];  // Drive select from VIA PA4
	assign SEL = ~via_pa_oe[5] | via_pa_o[5];

`ifdef SIMULATION
	// PA trace: SEL (PA5/HDSEL) picks the drive sense bank (regs 8-F) and the
	// head; the Sony driver toggles it with read-modify-writes around every
	// high-bank sense read. Diff against the MAME capture's "V8-PA5 HDSEL -> x".
	reg [7:0] dbg_pa_o_d = 8'hxx, dbg_pa_oe_d = 8'hxx;
	reg [11:0] dbg_pa_cnt = 0;
	always @(posedge clk32) begin
		if ((via_pa_o != dbg_pa_o_d || via_pa_oe != dbg_pa_oe_d) && dbg_pa_cnt < 12'd600) begin
			dbg_pa_cnt <= dbg_pa_cnt + 1'd1;
			$display("VIA-PA: o=%02x oe=%02x -> SEL=%b driveSel=%b @%0t",
			         via_pa_o, via_pa_oe, ~via_pa_oe[5] | via_pa_o[5],
			         ~via_pa_oe[4] | via_pa_o[4], $time);
			dbg_pa_o_d  <= via_pa_o;
			dbg_pa_oe_d <= via_pa_oe;
		end
	end
`endif
	assign vid_alt = ~via_pa_oe[6] | via_pa_o[6];

	// Port B - Mac LC Egret/CUDA interface (V8 protocol)
	// From MAME v8.cpp and maclc.cpp:
	// - PB3: XCVR_SESSION/TREQ from Egret/CUDA (input to VIA - 0 means CUDA has data)
	// - PB4: VIA_FULL/BYTEACK to Egret/CUDA (output from VIA)
	// - PB5: SYS_SESSION/TIP to Egret/CUDA (output from VIA)
	// - PB0: +5V sense (always 1)
	// - PB1-2, PB6-7: tied high
	//
	// TREQ polarity: cuda_treq=1 means CUDA is asserting TREQ (pin LOW = has data)
	// So we invert cuda_treq when building the external value
	// DEBUG: Connect _hblank to PB7, and force Sense=6 (110) on PB2-0
	wire [7:0] via_pb_external = {_hblank, 1'b1, 2'b11, ~cuda_treq, 3'b110};
	// Combine VIA outputs with CUDA inputs
	// Standard MUX for most bits: VIA output when OE, external when input
	wire [7:0] pb_pin_level_mux = (via_pb_oe & via_pb_o) | (~via_pb_oe & via_pb_external);
	// TREQ (bit 3) is open-drain: CUDA can always pull it low
	// Only high if VIA is not pulling low AND CUDA is not pulling low
	wire pb3_via_pulling_low = via_pb_oe[3] & ~via_pb_o[3];
	wire pb3_cuda_pulling_low = cuda_treq;  // cuda_treq=1 means CUDA pulling TREQ low
	wire pb3_open_drain = ~(pb3_via_pulling_low | pb3_cuda_pulling_low);
	wire [7:0] pb_pin_level = {pb_pin_level_mux[7:4], pb3_open_drain, pb_pin_level_mux[2:0]};
	// VIA Port B input - just use the pin level directly.
	// Don't mix in Egret's Port B output (cuda_pb_o) - the two Port B registers are on
	// different chips with completely different meanings. TREQ (bit 3) is already handled
	// via the pb3_open_drain logic above.
	assign via_pb_i = pb_pin_level;
	assign snd_ena = ~via_pb_oe[7] | via_pb_o[7];

	assign viaDataOut[7:0] = 8'hEF;

	// CUDA signals for Mac LC
	wire       cuda_cb1;
	wire       cuda_cb2;
	wire       cuda_cb2_oe;
	wire       cuda_treq;
	wire       cuda_byteack;
	wire       cuda_sr_irq;
	wire       via_sr_active;
	wire       via_sr_dir;
	wire       via_sr_ext_clk;
	wire [7:0] cuda_pb_o;
	wire [7:0] cuda_pb_oe;

	// VIA Shift Register read/write strobes for CUDA
	// These pulse when CPU accesses the VIA shift register (register 0xA)
	localparam VIA_SR_REG = 4'hA;
	reg via_sr_read, via_sr_write;
	reg via_access_prev;
	always @(posedge clk32) begin
		if (!_cpuReset) begin
			via_sr_read <= 1'b0;
			via_sr_write <= 1'b0;
			via_access_prev <= 1'b0;
		end else if (clk8_en_p) begin
			// Generate single-cycle pulses on VIA SR access
			via_sr_read <= 1'b0;
			via_sr_write <= 1'b0;

			if (selectVIA && !_cpuVMA && cpuAddrRegHi == VIA_SR_REG) begin
				if (!via_access_prev) begin
					if (_cpuRW) begin
						via_sr_read <= 1'b1;
`ifdef SIMULATION
						$display("VIA: SR READ = 0x%02x", viaDataOut[15:8]);
`endif
					end else begin
						via_sr_write <= 1'b1;
					end
				end
				via_access_prev <= 1'b1;
			end else begin
				via_access_prev <= 1'b0;
			end
		end
	end

	// CB1 from CUDA (CUDA always drives CB1 for shift register clocking)
	wire via_cb1_in = cuda_cb1;

	// Debug: track CB2 signal for VIA shift register
`ifdef VERBOSE_TRACE
	reg cuda_cb1_prev;
	always @(posedge clk32) begin
		cuda_cb1_prev <= cuda_cb1;
		if (cuda_cb1 && !cuda_cb1_prev) begin
			$display("DC: CB1 RISE - cuda_cb2_oe=%b, cuda_cb2=%b, final_cb2_i=%b",
			         cuda_cb2_oe, cuda_cb2, (cuda_cb2_oe ? cuda_cb2 : 1'b1));
		end
	end
`endif

	// Debug: Monitor Port B and CUDA signals
	/* verilator lint_off STMTDLY */
`ifdef SIMULATION
	reg [7:0] via_pb_oe_prev_sim = 8'h00;
	always @(posedge clk32) begin
		if (via_pb_oe !== via_pb_oe_prev_sim) begin
			$display("VIA: DDRB changed: 0x%02x -> 0x%02x (PB3=%b=%s, PB4=%b=%s, PB5=%b=%s)",
				via_pb_oe_prev_sim, via_pb_oe,
				via_pb_oe[3], via_pb_oe[3] ? "OUT" : "IN",
				via_pb_oe[4], via_pb_oe[4] ? "OUT" : "IN",
				via_pb_oe[5], via_pb_oe[5] ? "OUT" : "IN");
			via_pb_oe_prev_sim <= via_pb_oe;
		end
	end
`endif
`ifdef VERBOSE_TRACE
	reg [7:0] via_pb_oe_prev = 8'h00;
	reg cuda_treq_prev = 1'b0;
	always @(posedge clk32) begin
		if (via_pb_oe !== via_pb_oe_prev) begin
			$display("VIA_VERBOSE: DDRB changed: 0x%02x -> 0x%02x",
				via_pb_oe_prev, via_pb_oe);
			via_pb_oe_prev <= via_pb_oe;
		end
		if (cuda_treq !== cuda_treq_prev) begin
			$display("VIA: cuda_treq changed: %b -> %b, via_pb_external=0x%02x, via_pb_i=0x%02x",
				cuda_treq_prev, cuda_treq, via_pb_external, via_pb_i);
			cuda_treq_prev <= cuda_treq;
		end
	end
`endif
	/* verilator lint_on STMTDLY */

	// 60.15 Hz System Tick for VIA1 CA1 (+ derived one-second CA2).
	// The Mac LC's V8 generates a fixed 60.15 Hz tick independent of the video
	// mode's real vblank (MAME v8.cpp mac_6015 timer). The ROM's CA1 VBL ISR
	// increments Ticks from this, so it paces EVERYTHING tick-driven: caret
	// blink, double-click timing, and TickCount-paced games (POP's frame wait
	// sits in a TickCount compare loop — verified on HW via PIFD sampling).
	//
	// CA1 interrupts on a single edge POLARITY, so the line must complete a
	// full period per tick: toggle every HALF period.
	//   8.125 MHz / 60.15 Hz = 135,078 cycles/period -> toggle every 67,539.
	// (The previous full-period toggle halved the System Tick to 30.075 Hz.)
	//
	// onesec: 60 CA1 periods = 0.9975 s (the real LC's CA2 comes from the RTC
	// at 1 Hz; 60 ticks is the closest tick-locked equivalent and is what the
	// old vblank-counting version intended).
	reg [17:0] tick_cnt;
	reg tick_60hz;
	reg [5:0] tickCount;

	always @(posedge clk32) begin
		if (clk8_en_p) begin
			if (tick_cnt >= 67538) begin
				tick_cnt <= 0;
				tick_60hz <= ~tick_60hz;
				if (!tick_60hz)   // about to rise: one full tick period elapsed
					tickCount <= (tickCount == 59) ? 6'h0 : tickCount + 1'b1;
			end else begin
				tick_cnt <= tick_cnt + 1'b1;
			end
		end
	end
	wire onesec = tickCount == 59;

	via6522 via(
		.clock      (clk32),
		.rising     (E_rising),
		.falling    (E_falling),
		.reset      (!_cpuReset),

		.addr       (cpuAddrRegHi),
		.wen        (selectVIA && !_cpuVMA && !_cpuRW),
		.ren        (selectVIA && !_cpuVMA &&  _cpuRW),
		.data_in    (cpuDataIn[15:8]),
		.data_out   (viaDataOut[15:8]),

		.phi2_ref   (),

		//-- pio --
		.port_a_o   (via_pa_o),
		.port_a_t   (via_pa_oe),
		.port_a_i   (via_pa_i),

		.port_b_o   (via_pb_o),
		.port_b_t   (via_pb_oe),
		.port_b_i   (via_pb_i),  // CUDA contribution already in via_pb_i

		//-- handshake pins
		.ca1_i      (tick_60hz),
		.ca2_i      (onesec),

		.cb1_i      (via_cb1_in),
		.cb2_i      (cuda_cb2_oe ? cuda_cb2 : cb2_i),
		.cb2_o      (cb2_o),
		.cb2_t      (cb2_t),

		.irq        (viaIrq),

		// Shift register status for CUDA
		.sr_out_active (via_sr_active),
		.sr_out_dir    (via_sr_dir),
		.sr_ext_clk    (via_sr_ext_clk),

		// Debug outputs for FPGA SR diagnostics
		.sr_dbg_bit_cnt     (via_sr_dbg_bit_cnt),
		.sr_dbg_edge_pending(via_sr_dbg_edge_pending),
		.sr_dbg_fall_pending(via_sr_dbg_fall_pending),
		.sr_dbg_shift_reg   (via_sr_dbg_shift_reg)
	);

	assign via_sr_dbg_active = via_sr_active;
	assign via_sr_dbg_dir    = via_sr_dir;
	assign via_sr_dbg_cb1    = cuda_cb1;
	assign via_sr_dbg_cb2    = cuda_cb2_oe ? cuda_cb2 : cb2_o;

`ifdef USE_EGRET_CPU
	assign egret_dbg_reset_680x0  = egret_reset_680x0;
	assign egret_dbg_cpu_reset_out = _cpuReset;
`else
	assign egret_dbg_running       = 1'b0;
	assign egret_dbg_port_test_done = 1'b0;
	assign egret_dbg_handshake_done = 1'b0;
	assign egret_dbg_treq          = 1'b0;
	assign egret_dbg_tip           = 1'b0;
	assign egret_dbg_byteack       = 1'b0;
	assign egret_dbg_reset_680x0   = 1'b0;
	assign egret_dbg_cpu_reset_out = _cpuReset;
`endif

	// Egret/CUDA controller for Mac LC - handles PRAM, RTC, and ADB
	// Mac LC uses Egret (not CUDA) with V8 chip:
	// - PB3: TREQ from Egret (input to VIA)
	// - PB4: BYTEACK from VIA (output to Egret)
	// - PB5: TIP from VIA (output to Egret)
	//
	// Define USE_EGRET_CPU to use real 68HC05 CPU + Egret ROM (341s0850)
	// Otherwise uses state machine implementation (cuda_maclc.sv)

	// TIP latch: Hold TIP value when VIA is driving PB5 as output.
	// The 68020 code frequently changes DDRB to read Port B (check TREQ),
	// which temporarily makes PB5 an input. Without latching, this causes
	// TIP to toggle HIGH (external pull-up), interrupting communication.
	//
	// POLARITY: Mac LC Egret — PB5 passed directly (no inversion).
	// MAME: m_v8->pb5_callback().set(m_egret, FUNC(egret_device::set_sys_session))
	// PB5=1 → TIP active (session), PB5=0 → TIP idle
	reg via_tip_latched;
	always @(posedge clk32) begin
		if (!_cpuReset) begin
			// Reset: TIP idle (0 = no session)
			via_tip_latched <= 1'b0;
		end else if (clk8_en_p && via_pb_oe[5]) begin
`ifdef SIMULATION
			if (via_tip_latched != via_pb_o[5])
				$display("TIP_LATCH: %b -> %b (pb_o=0x%02x pb_oe=0x%02x)",
					via_tip_latched, via_pb_o[5], via_pb_o, via_pb_oe);
`endif
			// Pass PB5 directly to Egret as sys_session (no inversion)
			// MAME: m_v8->pb5_callback().set(m_egret, FUNC(egret_device::set_sys_session))
			// Host PB5=1 (TIP asserted) → Egret bit 3=1, PB5=0 (idle) → bit 3=0
			via_tip_latched <= via_pb_o[5];
		end
	end

`ifdef USE_EGRET_CPU
	// Use the real 68HC05 + 341S0851 firmware (rtl/egret/egret_wrapper.sv)
	// for FPGA synthesis, but fall back to egret_behavioral for Verilator.
	// The behavioral SM (rtl/egret_behavioral.sv) was previously instantiated
	// here but synthesized its 256-entry PRAM as flat flops, eating ~48k ALMs
	// — about 94% of the entire design. The HC05 wrapper has the exact same
	// port signature ("drop-in replacement") and infers block RAM for ROM/PRAM.
	// CONSOLIDATED: the real HC05 wrapper is now used for BOTH Verilator and
	// FPGA so the simulation matches hardware. The behavioral SM hid the Egret
	// CB1/overlay-escape bug (it drives CB1 slowly, so the VIA SR never drops
	// edges); using the HC05 in sim lets us reproduce and fix that bug without
	// burning Quartus builds. The behavioral SM remains available only if
	// EGRET_BEHAVIORAL is defined. The GHDL-converted HC05 core needs a few
	// -Wno-* in the Verilator Makefile (BLKLOOPINIT, etc.).

	// ADB open-collector line: the Egret HC05 drives PA7 (adb_data_out, where
	// 1 = pull the line LOW per MAME egret.cpp `m_adb_out = !(PA7)`) and reads the
	// wired-AND line value back on PA6 (adb_data_in). With NO device, the line =
	// ~adb_data_out (the Egret reads back its own drive). The old stub tied
	// adb_data_in to 1'b1, so the HC05 could never see the line it was driving —
	// breaking its ADB probe state machine. Loopback restores correct
	// idle-bus behaviour. When an ADB device is added, AND its (open-collector,
	// 1 = released) line into this: adb_data_in = ~adb_data_out & adb_dev_line.
	wire egret_adb_dout;
	wire adb_dev_line;                    // open-collector drive from the ADB device(s)
	wire egret_adb_din = ~egret_adb_dout & adb_dev_line;

	// Wire-level ADB keyboard (addr 2) + mouse (addr 3) on the Egret ADB line.
	// host_line = the line as driven by the Egret (~adb_data_out, 1 = idle high);
	// dev_line is the device's open-collector drive (1 = released, 0 = pull low),
	// wire-ANDed into adb_data_in above.
	adb_device adb_dev(
		.clk        (clk32),
		.reset      (!_cpuReset),
		.host_line  (~egret_adb_dout),
		.dev_line   (adb_dev_line),
		.ps2_key    (ps2_key),
		.ps2_mouse  (ps2_mouse)
	);
`ifdef EGRET_BEHAVIORAL
	egret_behavioral egret_inst(
`else
	egret_wrapper egret_inst(
`endif
		.clk            (clk32),
		.clk8_en        (clk8_en_p),
		.reset          (egretReset),  // Egret uses shorter reset than 68000

		// RTC timestamp initialization
		.timestamp      (timestamp),

		// VIA Port B connections (Mac LC V8 protocol)
		// TIP: Latch the value when VIA drives PB5 as output
		// This prevents TIP from toggling when VIA temporarily makes PB5 an input to read Port B
		// Polarity already inverted in via_tip_latched (Mac LC: PB5 HIGH = TIP asserted)
		.via_tip        (via_tip_latched),  // TIP from VIA (PB5 = SYS_SESSION)
		.via_byteack_in (via_pb_o[4]),     // BYTEACK from VIA - direct (no inversion, matches MAME)
		.cuda_treq      (cuda_treq),       // TREQ to VIA (PB3 = XCVR_SESSION)
		.cuda_byteack   (cuda_byteack),    // Not used in Egret

		// VIA Shift Register interface
		.cuda_cb1       (cuda_cb1),        // Shift clock
		.via_cb2_in     (cb2_o),           // Data from VIA
		.cuda_cb2       (cuda_cb2),        // Data to VIA
		.cuda_cb2_oe    (cuda_cb2_oe),     // CB2 output enable

		// VIA SR control signals
		.via_sr_read    (via_sr_read),
		.via_sr_write   (via_sr_write),
		.via_sr_ext_clk (via_sr_ext_clk),
		.via_sr_dir     (via_sr_dir),
		.cuda_sr_irq    (cuda_sr_irq),

		// Full Port B
		.cuda_portb     (cuda_pb_o),
		.cuda_portb_oe  (cuda_pb_oe),

		// ADB open-collector line (loopback; no device yet — see above)
		.adb_data_in    (egret_adb_din),
		.adb_data_out   (egret_adb_dout),

		// System control - Egret controls 68000 reset via Port C bit 3
		.reset_680x0    (egret_reset_680x0),
		.nmi_680x0      (),

		// PRAM persistence (NVRAM save/restore). Active egret_wrapper path only —
		// the dead egret_behavioral build (EGRET_BEHAVIORAL) lacks these ports.
`ifndef EGRET_BEHAVIORAL
		.pram_load_wr   (pram_load_wr),
		.pram_load_addr (pram_load_addr),
		.pram_load_data (pram_load_data),
		.pram_save_addr (pram_save_addr),
		.pram_save_data (pram_save_data),
		.pram_wr_stb    (pram_wr_stb),
		.pram_ready     (pram_ready),
`endif

		// Debug outputs
		.dbg_cen            (),
		.dbg_port_test_done (egret_dbg_port_test_done),
		.dbg_handshake_done (egret_dbg_handshake_done),
		.dbg_treq           (egret_dbg_treq),
		.dbg_tip_in         (egret_dbg_tip),
		.dbg_byteack_in     (egret_dbg_byteack),
		.dbg_pb_out         (),
		.dbg_pc_out         (),
		.dbg_cpu_running    (egret_dbg_running)
	);
`else
	cuda_maclc cuda(
		.clk            (clk32),
		.clk8_en        (clk8_en_p),
		.reset          (!_cpuReset),

		// RTC timestamp initialization
		.timestamp      (timestamp),

		// VIA Port B connections (Mac LC V8 protocol)
		// TIP: Use latched value to prevent toggling when VIA reads Port B
		// Polarity already inverted in via_tip_latched (Mac LC: PB5 HIGH = TIP asserted)
		.via_tip        (via_tip_latched),  // TIP from VIA (PB5 = SYS_SESSION)
		.via_byteack_in (via_pb_o[4]),     // BYTEACK from VIA - direct (no inversion, matches MAME)
		.cuda_treq      (cuda_treq),       // TREQ to VIA (PB3 = XCVR_SESSION)
		.cuda_byteack   (cuda_byteack),    // Not used in V8 protocol

		// VIA Shift Register interface
		.cuda_cb1       (cuda_cb1),        // Shift clock
		.via_cb2_in     (cb2_o),           // Data from VIA
		.cuda_cb2       (cuda_cb2),        // Data to VIA
		.cuda_cb2_oe    (cuda_cb2_oe),     // CB2 output enable

		// VIA SR control signals
		.via_sr_read    (via_sr_read),
		.via_sr_write   (via_sr_write),
		.via_sr_ext_clk (via_sr_ext_clk),
		.via_sr_dir     (via_sr_dir),
		.cuda_sr_irq    (cuda_sr_irq),

		// Full Port B
		.cuda_portb     (cuda_pb_o),
		.cuda_portb_oe  (cuda_pb_oe),

		// ADB (simplified for now)
		.adb_data_in    (1'b1),
		.adb_data_out   (),

		// System control (not used yet)
		.reset_680x0    (),
		.nmi_680x0      ()
	);
`endif

	wire _ADBint;
	wire ADBST0 = ~via_pb_oe[4] | via_pb_o[4];
	wire ADBST1 = ~via_pb_oe[5] | via_pb_o[5];
	wire ADBListen;

	reg kbdclk;
	reg [7:0] kbdclk_count;  // ADB timing only needs 8 bits
	reg kbd_transmitting, kbd_wait_receiving, kbd_receiving;
	reg [2:0] kbd_bitcnt;

	wire cb2_i = kbddata_o;
	wire cb2_o, cb2_t;
	wire kbddat_i = ~cb2_t | cb2_o;
	reg kbddata_o;
	reg  [7:0] kbd_to_mac;
	reg kbd_data_valid;

	// ADB Keyboard transmitter-receiver
	always @(posedge clk32) begin
		if (clk8_en_p) begin
			if ((kbd_transmitting && !kbd_wait_receiving) || kbd_receiving) begin
				kbdclk_count <= kbdclk_count + 1'd1;
				if (kbdclk_count == 8'd80) begin  // ADB timing
					kbdclk <= ~kbdclk;
					kbdclk_count <= 0;
					if (kbdclk) begin
						// shift before the falling edge
						if (kbd_transmitting) kbd_out_data <= { kbd_out_data[6:0], kbddat_i };
						if (kbd_receiving) kbddata_o <= kbd_to_mac[7-kbd_bitcnt];
					end
				end
			end else begin
				kbdclk_count <= 0;
				kbdclk <= 1;
			end
		end
	end

	// ADB Keyboard control (Mac LC uses ADB exclusively)
	always @(posedge clk32) begin
		reg kbdclk_d;
		reg ADBListenD;
		if (!_cpuReset) begin
			kbd_bitcnt <= 0;
			kbd_transmitting <= 0;
			kbd_wait_receiving <= 0;
			kbd_data_valid <= 0;
			ADBListenD <= 0;
		end else if (clk8_en_p) begin
			// ADB data reception
			if (adb_dout_strobe) begin
				kbd_to_mac <= adb_dout;
				kbd_receiving <= 1;
			end

			kbd_out_strobe <= 0;
			adb_din_strobe <= 0;
			kbdclk_d <= kbdclk;

			// ADB transmission start
			if (!kbd_transmitting && !kbd_receiving) begin
				ADBListenD <= ADBListen;
				if (!ADBListenD && ADBListen) begin
					kbd_transmitting <= 1;
					kbd_bitcnt <= 0;
				end
			end

			// send/receive bits at rising edge of the keyboard clock
			if (~kbdclk_d & kbdclk) begin
				kbd_bitcnt <= kbd_bitcnt + 1'd1;

				if (kbd_bitcnt == 3'd7) begin
					if (kbd_transmitting) begin
						adb_din_strobe <= 1;
						adb_din <= kbd_out_data;
						kbd_transmitting <= 0;
					end
					if (kbd_receiving) begin
						kbd_receiving <= 0;
						kbd_data_valid <= 0;
					end
				end
			end
		end
	end

	// SWIM (IWM + ISM dual-mode floppy controller)
	swim sw(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		._reset(_cpuReset),
		.selectSWIM(selectIWM),
		._cpuRW(_cpuRW),
		._cpuUDS(_cpuUDS),  // LC V8: SWIM is on the upper byte (even addresses)
		.dataIn(cpuDataIn),
		.cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL),
		.driveSel(driveSel),
		.dataOut(swimDataOut),
		.insertDisk(insertDisk),
		.diskSides(diskSides),
		.diskMFM(diskMFM),
		.diskHD(diskHD),
		.diskEject(diskEject),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.dskReadData(memoryDataIn[7:0]),

		.dbg_ism_flpe(dbg_ism_flpe),
		.dbg_flp_byte_cnt(dbg_flp_byte_cnt),
		.dbg_flp_miss_cnt(dbg_flp_miss_cnt),
		.dbg_flp_disk_data(dbg_flp_disk_data),
		.dbg_flp_track(dbg_flp_track),
		.dbg_flp_side(dbg_flp_side),
		.dbg_flp_step_cnt(dbg_flp_step_cnt),
		.dbg_iwm_latch(dbg_iwm_latch),
		.dbg_flp_byte_stb(dbg_flp_byte_stb),
		.dbg_flp_raw(dbg_flp_raw),
		.dbg_flp_gcr_addr(dbg_flp_gcr_addr),
		.dbg_ism_verdict(dbg_ism_verdict),
		.dbg_ism_pop2(dbg_ism_pop2),
		.dbg_ism_state(dbg_ism_state),
		.dbg_flp_strb_cnt(dbg_flp_strb_cnt),
		.dbg_flp_strb_en_cnt(dbg_flp_strb_en_cnt),
		.dbg_flp_strb_last(dbg_flp_strb_last),
		.dbg_flp_rej_step(dbg_flp_rej_step),
		.dbg_flp_status(dbg_flp_status)
	);

	// SCC
	scc s(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		.rtxc_en(scsi_pclk_en),
		.reset_hw(~_cpuReset),
		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0)),
//		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0) && cpuBusControl),
		.we(!_cpuRW),  // Mac LC: SCC is on upper byte (even addr/UDS), not LDS like Mac Plus
//		.we(!_cpuLDS),
		.rs(cpuAddrRegLo),
		.wdata(cpuDataIn[7:0]),  // TG68K puts byte data on lower bus; FX68K needs [15:8]
		.rdata(sccDataOut),
		._irq(_sccIrq),
		.dcd_a(1'b1),  // Mac LC uses ADB for mouse, not SCC DCD
		.dcd_b(1'b1),
		.wreq(sccWReq),
		.txd(serialOut),
		.rxd(serialIn),
		.cts(serialCTS),
		.rts(serialRTS)
		);
				
	
	// Mouse
	ps2_mouse mouse(
		.clk(clk32),
		.ce(clk8_en_p),
		.reset(~_cpuReset),
		.ps2_mouse(ps2_mouse),
		.x1(mouseX1),
		.y1(mouseY1),
		.x2(mouseX2),
		.y2(mouseY2),
		.button(mouseButton));

	wire [7:0] kbd_in_data;
	wire kbd_in_strobe;
	reg  [7:0] kbd_out_data;
	reg  kbd_out_strobe;

	// Keyboard
	ps2_kbd kbd(
		.clk(clk32),
		.ce(clk8_en_p),
		.reset(~_cpuReset),
		.ps2_key(ps2_key),
		.data_out(kbd_out_data),              // data from mac
		.strobe_out(kbd_out_strobe),
		.data_in(kbd_in_data),         // data to mac
		.strobe_in(kbd_in_strobe),
		.capslock(capslock)
		);
		
	reg  [7:0] adb_din;
	reg        adb_din_strobe;
	wire [7:0] adb_dout;
	wire       adb_dout_strobe;

	adb adb(
		.clk(clk32),
		.clk_en(clk8_en_p),
		.reset(~_cpuReset),
		.st({ADBST1, ADBST0}),
		._int(_ADBint),
		.viaBusy(kbd_transmitting || kbd_receiving),
		.listen(ADBListen),
		.adb_din(adb_din),
		.adb_din_strobe(adb_din_strobe),
		.adb_dout(adb_dout),
		.adb_dout_strobe(adb_dout_strobe),

		.ps2_mouse(ps2_mouse),
		.ps2_key(ps2_key)
	);

endmodule