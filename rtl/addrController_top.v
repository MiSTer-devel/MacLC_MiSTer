module addrController_top(
	// clocks:
	input clk,
	output clk8,
	output clk8_en_p,
	output clk8_en_n,
	output clk16_en_p,
	output clk16_en_n,

	// system config:
	input [7:0] ram_config,       // V8 RAM config byte WRITTEN by ROM (pseudovia reg $01)
	input [7:0] ram_config_phys,  // PHYSICAL hardware RAM config (configRAMSize) — never
	                              // changes; gives the real installed SIMM size.
	input       ram_configured,  // 1 once ROM programs V8 config (enables $0 mirror)

	// 68000 CPU memory interface:
	input _cpuReset,
	input [31:0] cpuAddr,
	input _cpuUDS,
	input _cpuLDS,
	input _cpuRW,
	input _cpuAS,
	// Function code: FC[1]=1 distinguishes program access (FC=2/6) from
	// data access (FC=1/5). We gate overlay-disable on it so an incidental
	// data read of $A0xxxxx (e.g. TG68-driven access to $ABC146 before the
	// boot ROM is ready to leave the overlay mirror) doesn't prematurely
	// clear overlay and crash the CPU through zero-RAM.
	// Note: this is STRICTER than MAME (which clears on any non-debugger
	// read), but MAME's behavior caused us to wild-execute through RAM=0
	// (build 20260601_073828 confirmed: overlay-trigger=$ABC146 → opcode
	// $0000 wild branch). The FC[1] gate is the empirically-correct fit
	// for our TG68 + SDRAM stack even though it diverges from MAME.
	input [2:0] cpuFC,

	// PDS Ethernet card claims this bus cycle (rtl/pds/pds_enet.sv): its
	// 32-bit slot addresses ($FE0Dxxxx RAM / $FE0Exxxx regs) alias into the
	// $0Dxxxx/$0Exxxx RAM range through the 24-bit-truncating decode below,
	// so an unmasked selectRAM would let a card-RAM write ALSO commit to
	// guest SDRAM. Mask selectRAM for claimed cycles; everything else the
	// card claims decodes as peripheral/unmapped space and is harmless.
	input pds_claim,

	// RAM/ROM:
	output [22:0] memoryAddr,  // 23-bit SDRAM word address
	output _memoryUDS,
	output _memoryLDS,
	output _romOE,
	output _ramOE,
	output _ramWE,
	output dioBusControl,
	output cpuBusControl,
	output memoryLatch,
	output flp_guard,      // pending floppy window this rotation: SDRAM demand
	                       // sequencer must not start a CPU access (Phase C)
	input  cpu_wr_ack,     // demand write acked (sdram cpu_done): strobes the
	                       // VRAM BRAM write mirror once per CPU write cycle
	input  flp_present,    // a disk is in either drive: only then do floppy fetch
	                       // windows (and their CPU guard) run at all — see flp_ok
	input  dio_download,   // HPS is writing SDRAM (image download) — invalidates
	                       // the floppy served-address cache, see below

	// peripherals:
	output selectSCSI,
	output selectSCSIDMA,
	output selectSCC,
	output selectIWM,
	output selectASC,
	output selectVIA,
	output selectRAM,
	output selectROM,

	// LC Peripherals
	output selectAriel,
	output selectPseudoVIA,
	output selectVRAM,
	output selectUnmapped,

	// On-chip framebuffer (BRAM) write mirror — Phase 1 of the VRAM-in-BRAM plan.
	input  [10:0] words_per_line, // active words/line (from v8_video) for packing
	output [17:0] vram_waddr,     // packed BRAM word address for a CPU VRAM write
	output        vram_we,        // 1-cyc strobe: commit the CPU VRAM write to BRAM

	// misc
	output memoryOverlayOn,
	output [23:0] overlay_trigger_addr,  // debug: address that caused overlay disable

	// interface to read dsk image from ram
	input [21:0] dskReadAddrInt,
	output dskReadAckInt,
	input [21:0] dskReadAddrExt,
	output dskReadAckExt
);

	// Legacy Mac-Plus sound DMA removed in Commit C.
	// Extra-slot 2 is now idle; ASC owns all audio output.

	// ============================================================
	// Bus cycle / clock generation
	// ============================================================
	assign dioBusControl = extraBusControl;

	reg [1:0] busCycle;
	reg [1:0] busPhase;
	reg [1:0] extra_slot_count;

	always @(posedge clk) begin
		busPhase <= busPhase + 1'd1;
		if (busPhase == 2'b11)
			busCycle <= busCycle + 2'd1;
	end
	assign memoryLatch = busPhase == 2'd3;
	assign clk8 = !busPhase[1];
	assign clk8_en_p = busPhase == 2'b11;
	assign clk8_en_n = busPhase == 2'b01;
	assign clk16_en_p = !busPhase[0];
	assign clk16_en_n = busPhase[0];

	reg extra_slot_advance;
	always @(posedge clk)
		if (clk8_en_n) extra_slot_advance <= (busCycle == 2'b11);

	always @(posedge clk) begin
		if(clk8_en_p && extra_slot_advance) begin
			extra_slot_count <= extra_slot_count + 2'd1;
		end
	end

	// H1 (perf): video scanout reads the on-chip BRAM framebuffer (vram_bram),
	// not SDRAM, so the CPU owns slots 00/01/11 (3 of 4 slots). The remaining
	// "extra" slot (10) serves floppy disk reads. NOTE: the dtack glue in
	// MacLC.sv/sim.v must assert per-cpu-slot (the 3 slots 11,00,01 are
	// CONTIGUOUS, so a rising-edge detector would see only one edge per round
	// and HALVE throughput).
	assign cpuBusControl = (busCycle == 2'b00) || (busCycle == 2'b01) || (busCycle == 2'b11);
	wire extraBusControl = (busCycle == 2'b10);

	// ============================================================
	// Memory control signals
	// ============================================================
	// Phase C (branch cpu-enhancements): the SDRAM controller is demand-
	// started, so these are no longer gated on cpuBusControl (the slot
	// rotation). They form a LEVEL request held for the whole AS-low window;
	// the controller serves it once (cpu_done handshake in sdram.v) at the
	// next free clk_64 edge. The selects are already AS-qualified in
	// addrDecoder. Floppy windows force read-both-bytes below.
	assign _romOE = ~(selectROM && _cpuRW);

	assign _ramOE = ~((selectRAM || selectVRAM) && _cpuRW);

	// RAM Write Enable: Active for RAM or VRAM writes
	assign _ramWE = ~((selectRAM || selectVRAM) && !_cpuRW);

	wire flp_win_any = dskReadAckInt || dskReadAckExt;
	assign _memoryUDS = flp_win_any ? 1'b0 : _cpuUDS;
	assign _memoryLDS = flp_win_any ? 1'b0 : _cpuLDS;

	// ============================================================
	// V8-style RAM address translation
	// All outputs are 23-bit SDRAM word addresses
	//
	// SDRAM Layout (word addresses):
	//   $000000-$0FFFFF  Motherboard RAM (2MB)
	//   $100000-$4FFFFF  SIMM RAM (up to 8MB)
	//   $500000-$53FFFF  ROM (512KB)
	//   $580000-$5BFFFF  VRAM (512KB)
	//   $600000-$6FFFFF  Floppy disk image 1 (2MB)
	//   $700000-$7FFFFF  Floppy disk image 2 (2MB)
	// ============================================================

	// Decode SIMM size from the PHYSICAL config, NOT the ROM-written register.
	// MAME sizes the SIMM from m_ram_size (physical), and only the install ENABLE
	// / motherboard placement use the writable config register. For a 2MB machine
	// (configRAMSize=$24, bits[7:6]=00) there is NO SIMM, so $0 must never route to
	// the SIMM SDRAM region — it stays a true mirror of $800000. Using the written
	// register here (which transiently becomes $C4 during the ROM's RAM probe)
	// fabricated a phantom 8MB SIMM at $0, turning $0 into a SEPARATE bank instead
	// of a $800000 mirror; the boot's bank scan then recorded a phantom $0 entry and
	// the march clobbered the descriptor table at $9FFFEC.
	// NOTE: 8MB = $800000 needs bit 23, so this field MUST be 24 bits wide.
	// A 23-bit field silently truncated $800000 to 0, killing the 8MB/10MB config.
	wire [23:0] simm_byte_size = (ram_config_phys[7:6] == 2'b00) ? 24'h000000 :  // 0MB
	                              (ram_config_phys[7:6] == 2'b01) ? 24'h200000 :  // 2MB
	                              (ram_config_phys[7:6] == 2'b10) ? 24'h400000 :  // 4MB
	                                                                24'h800000;   // 8MB
	wire [22:0] simm_word_size = simm_byte_size[23:1];

	// CPU address classification for RAM
	wire motherboard_high = (cpuAddr[23:21] == 3'b100);  // $800000-$9FFFFF
	wire in_simm = (cpuAddr[22:0] < simm_byte_size);     // Below SIMM size

	// CPU byte addr -> word addr
	wire [21:0] cpu_word = cpuAddr[22:1];

	// Motherboard mirror offset: (cpu_word - simm_words) mod 2MB
	// (dead when the SIMM fills the whole lower bank, e.g. 8MB, but kept width-clean)
	wire [22:0] mb_mirror_offset_raw = {1'b0, cpu_word} - simm_word_size;
	wire [19:0] mb_mirror_offset = mb_mirror_offset_raw[19:0];  // Wrap to 2MB (1M words)

	// V8 RAM translation to SDRAM word address
	wire [22:0] ram_sdram_word =
		motherboard_high ? {3'b000, cpuAddr[20:1]} :                          // → Motherboard at SDRAM $000000
		in_simm          ? (23'h100000 + {1'b0, cpu_word}) :                  // → SIMM at SDRAM $100000+
		                   {3'b000, mb_mirror_offset};                        // → Motherboard mirror at SDRAM $000000+

	// ROM translation: SDRAM word $500000 + offset within 512KB
	wire [22:0] rom_sdram_word = {5'b10100, cpuAddr[18:1]};  // $500000 + offset
	// NOTE: 5'b10100 == $14, giving base $14<<18 = $500000. The old 5'b01010 ($0A)
	// placed ROM at $280000 — INSIDE the 8MB SIMM SDRAM region ($100000-$4FFFFF),
	// so a 10MB RAM fill overwrote the ROM image and crashed the boot. $500000 sits
	// safely between the SIMM ($100000-$4FFFFF) and VRAM ($580000). Must match the
	// download mapping in MacLC.sv and verilator/sim.v.

	// VRAM CPU access: CPU $F40000-$FBFFFF → SDRAM word $580000+
	// Offset from VRAM start = cpuAddr[19:0] - $40000
	wire [19:0] vram_cpu_offset = cpuAddr[19:0] - 20'h40000;
	wire [22:0] vram_sdram_word = 23'h580000 + {5'b0, vram_cpu_offset[18:1]};

	// ---- On-chip framebuffer (BRAM) write mirror (Phase 1) ----
	// The V8 scans 1-8bpp at a fixed 1024-byte (512-word) stride, but only the
	// first words_per_line words of each line are visible. Pack out the stride gap
	// (packed = line*words_per_line + col) so 640-wide modes fit the 384KB BRAM;
	// for 16bpp@512 (words_per_line=512) packing == the natural word offset.
	wire [9:0]  vram_line = vram_cpu_offset[19:10];   // scanline (stride 1024B)
	wire [8:0]  vram_colw = vram_cpu_offset[9:1];     // word within the line (0..511)
	wire [18:0] vram_packed = vram_line * words_per_line + {10'd0, vram_colw};
	wire        vram_col_visible = ({2'b0, vram_colw} < words_per_line);
	// One BRAM write per CPU VRAM write cycle, only for visible columns
	// (off-screen stride padding is dropped so it can't corrupt the next line).
	// Phase C: the strobe fires on the RISING EDGE of the demand write ack
	// (sdram cpu_done, via cpu_wr_ack), instead of at (cpuBusControl &&
	// memoryLatch). Under demand-start serving the CPU write cycle is no
	// longer slot-aligned, and an AS-low window can contain a memoryLatch
	// tick that falls in the floppy slot — the old condition would silently
	// drop that BRAM mirror write (stale framebuffer pixels, ghost class).
	// The ack rises mid-cycle while AS, the data strobes (a_be at the top is
	// the LIVE ~_cpuUDS/~_cpuLDS), the address, and the write data are all
	// still held — everything the BRAM port needs is naturally valid.
	reg cpu_wr_ack_q;
	always @(posedge clk) cpu_wr_ack_q <= cpu_wr_ack;
	assign vram_waddr = vram_packed[17:0];
	assign vram_we = selectVRAM && !_cpuRW && vram_col_visible &&
	                 cpu_wr_ack && !cpu_wr_ack_q;

`ifdef SIMULATION
	// Phase-C debug: is the BRAM mirror strobe firing once per VRAM write
	// cycle? (magenta-screen hunt 2026-08-17; remove when resolved)
	integer dbg_vwe_cnt = 0, dbg_vwr_cycles = 0, dbg_vwr_missed = 0;
	reg dbg_in_vwr = 0, dbg_got_strobe = 0;
	always @(posedge clk) begin
		if (vram_we) begin
			dbg_vwe_cnt = dbg_vwe_cnt + 1;
			if (dbg_vwe_cnt <= 6)
				$display("VRAMWE[%0d]: waddr=%h wpl=%0d cpuAddr=%h ack=%b%b",
				         dbg_vwe_cnt, vram_waddr, words_per_line,
				         cpuAddr[23:0], cpu_wr_ack, cpu_wr_ack_q);
		end
		if (selectVRAM && !_cpuRW && !_cpuAS) begin
			dbg_in_vwr <= 1;
			if (vram_we) dbg_got_strobe <= 1;
		end else if (dbg_in_vwr) begin
			dbg_vwr_cycles = dbg_vwr_cycles + 1;
			if (!dbg_got_strobe && vram_col_visible_q) dbg_vwr_missed = dbg_vwr_missed + 1;
			if (dbg_vwr_cycles % 200000 == 0 || (dbg_vwr_missed > 0 && dbg_vwr_missed <= 6))
				$display("VRAMWR cycles=%0d strobes=%0d missed=%0d",
				         dbg_vwr_cycles, dbg_vwe_cnt, dbg_vwr_missed);
			dbg_in_vwr <= 0;
			dbg_got_strobe <= 0;
		end
	end
	reg vram_col_visible_q;
	always @(posedge clk) if (selectVRAM && !_cpuRW && !_cpuAS) vram_col_visible_q <= vram_col_visible;
`endif

	// Floppy disk addresses: byte offset → SDRAM word
	wire [22:0] dsk_int_sdram_word = 23'h600000 + {2'b0, dskReadAddrInt[21:1]};
	wire [22:0] dsk_ext_sdram_word = 23'h700000 + {2'b0, dskReadAddrExt[21:1]};

	// CPU address mux (selects based on address decode)
	wire [22:0] cpu_sdram_word = selectVRAM ? vram_sdram_word :
	                              selectROM ? rom_sdram_word :
	                              selectRAM ? ram_sdram_word :
	                              23'h0;

	wire [22:0] addr_mux = cpu_sdram_word;

	// ============================================================
	// Extra bus slots (disk reads, sound)
	// ============================================================
	// ── Floppy fetch windows: UNGATED, one fetch per rotation ──────────────
	// Phase C made these windows PENDING-GATED (fire only when the encoder's
	// address changed since the last served fetch) to stop idle windows
	// stealing CPU bandwidth. That gate is REVERTED here (2026-08-19), back to
	// the pre-Phase-C behaviour of reading SDRAM every rotation.
	//
	// Why: with the download-corruption bug fixed, a mount no longer bombs the
	// guest — but the volume then reports "This disk is unreadable" for BOTH an
	// 800K GCR image and a 1.44MB MFM image, while the same GCR image mounts
	// and reads perfectly on releases/MacLC_20260815.rbf (pre-mission). Failing
	// identically across two completely different track encoders rules the
	// encoders out and puts the defect in this shared fetch seam, which the
	// gate is the only Phase C change to alter FUNCTIONALLY (everything else
	// only moved timing).
	//
	// ★ The gate's stated premise — "one ack per address is precisely what the
	// freshness protocol needs" — is provably WRONG. Read floppy.v's MFM
	// delivery loop: on every byte it sets `mfm_ack_skip` (the ack still in
	// flight belongs to the address it just advanced FROM) and clears
	// `mfm_fresh`, then waits for an ack to set `mfm_fresh` again. That is
	// **TWO acks per delivered byte** — one absorbed by the skip, one to arm
	// the next byte. The pending gate delivers exactly ONE ack per address
	// change; it is consumed by the skip, `mfm_fresh` never sets, and delivery
	// stalls at the loop's own "payload byte not fetched yet" branch. The GCR
	// path relies on repeated acks the same way (`if (dskReadAck) diskImageData
	// <= dskReadDataEnc` re-samples every rotation, picking up the value
	// dskReadDataLatch settled on a previous one). Both encoders were written
	// against continuous every-rotation acks — which is exactly what this
	// design provided before Phase C, and why BOTH a GCR and an MFM image fail
	// identically with the gate in.
	// It is fragile in a second way too: dskReadAddr is compared LIVE while the
	// window is open, so an address advancing mid-window records the NEW
	// address in flp_addr_q against data fetched for the OLD one.
	//
	// The bandwidth argument for the gate no longer applies: under demand-start
	// the CPU is served from any idle clk_64 edge and does not need this slot.
	// (The MacIIvi-noted "spurious read" is harmless — it re-reads an address
	// the encoder is still pointing at.)
	// ★★★ !dio_download is LOAD-BEARING (2026-08-18). The floppy window and the
	// download slot are THE SAME SLOT (extraBusControl == dioBusControl), and a
	// window does more than request a fetch: it switches `memoryAddr` to the
	// floppy image address and forces both data strobes. That was harmless only
	// because a window also blocks CPU starts (flp_win/flp_guard in sdram.v).
	// During a download flp_win is deliberately suppressed at the top level, so
	// nothing blocks the CPU — and with the old `download_cycle` mux gone, the
	// CPU's own request now reaches the controller with the FLOPPY address on
	// memoryAddr. Reads then return image bytes instead of the guest's memory
	// (and writes land in the image). Observed on hardware as a mount that
	// freezes the guest with a sprayed framebuffer.
	// The encoder free-runs with no disk, so these windows fire continuously
	// during a normal boot — this is not a corner case.
	// Suppressing the ack here (rather than only flp_win at the top) keeps
	// memoryAddr, the data strobes, flp_win_any and the sdram_do source mux all
	// consistent: during a download there is simply no floppy window. The
	// so the encoder simply gets no data during the download and resumes
	// fetching normally the moment it ends.
	// ★ flp_present is a PERFORMANCE gate, not a correctness one. The windows
	// must fire every rotation while a disk is being read (see the two-acks-per-
	// byte note above), and that costs the CPU: flp_guard blocks new starts
	// through busCycle 01+10 on the rotations it covers, i.e. roughly a quarter
	// of all start opportunities. But the GCR encoder FREE-RUNS with no disk
	// inserted, so without this gate every SCSI-only boot — and every benchmark
	// run — pays that quarter for fetches nobody reads. Keying on "a disk is
	// present" (not "the motor is spinning") deliberately keeps the behaviour
	// with a floppy mounted BYTE-FOR-BYTE identical to the configuration that
	// was hardware-validated, and only reclaims the bandwidth in the case where
	// the floppy path is provably idle.
	wire flp_ok = !dio_download && flp_present;
	assign dskReadAckInt = (extraBusControl == 1'b1) && (extra_slot_count == 0) && flp_ok;
	assign dskReadAckExt = (extraBusControl == 1'b1) && (extra_slot_count == 1) && flp_ok;
	// extra_slot_count == 2 is now idle (legacy sound DMA removed)

	// flp_guard: a pending floppy window fires this rotation — hold off new
	// CPU accesses from one full slot before it through its end, so the
	// demand sequencer is guaranteed idle when the window opens (an access
	// occupies 8 clk_64 = one slot). Covering ALL of the preceding slot
	// (not just its last 3 ticks) costs the CPU at most one extra slot only
	// while a floppy fetch is actually pending, and makes the guard's rise
	// race-free against the sequencer's clk_64 sampling.
	assign flp_guard = ((extra_slot_count == 2'd0) || (extra_slot_count == 2'd1)) &&
	                   ((busCycle == 2'b01) || (busCycle == 2'b10)) && flp_ok;

	// Final SDRAM word address output
	assign memoryAddr =
		dskReadAckInt ? dsk_int_sdram_word :
		dskReadAckExt ? dsk_ext_sdram_word :
		addr_mux;

	// ============================================================
	// Address decoder
	// ============================================================
	wire selectRAM_dec;
	assign selectRAM = selectRAM_dec & ~pds_claim;

	addrDecoder ad(
		.address({cpuAddr[23:1], 1'b0}),
		._cpuAS(_cpuAS),
		._cpuRW(_cpuRW),
		.memoryOverlayOn(memoryOverlayOn),
		.ram_config(ram_config),
		.ram_config_phys(ram_config_phys),
		.ram_configured(ram_configured),
		.selectRAM(selectRAM_dec),
		.selectROM(selectROM),
		.selectSCSI(selectSCSI),
		.selectSCSIDMA(selectSCSIDMA),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectASC(selectASC),
		.selectVIA(selectVIA),
		.selectAriel(selectAriel),
		.selectPseudoVIA(selectPseudoVIA),
		.selectVRAM(selectVRAM),
		.selectUnmapped(selectUnmapped)
	);

	// ============================================================
	// ROM Overlay Register
	// ============================================================
	// At reset, ROM is overlaid at $000000 so the CPU reads the reset
	// vector from ROM.  The overlay is disabled when the CPU first
	// accesses the ROM area ($A0xxxx).
	//
	// The disable is deferred until _cpuAS goes high (bus cycle ends),
	// so the instruction/data read that triggered it completes with
	// overlay still active.  The next bus cycle sees overlay OFF.
	// ============================================================
	reg rom_overlay = 1;
	reg overlay_disable_pending = 0;
	reg [23:0] overlay_trigger_addr_r = 0;

	assign memoryOverlayOn = rom_overlay;
	assign overlay_trigger_addr = overlay_trigger_addr_r;

	// Overlay disables on first INSTRUCTION FETCH in $A00000-$AFFFFF.
	// MAME clears overlay on any read (v8.cpp:rom_switch_r), but in our
	// TG68 + SDRAM stack the boot ROM's data read of $ABC146 happens
	// while PC is still in the $0xxxxx overlay mirror; if that data
	// read clears overlay, the next code fetch at $0xxxxx returns RAM=0
	// and the CPU wild-branches through ORI.B #0,D0. Gating on FC[1]=1
	// (program access) holds overlay until the boot ROM does its real
	// JMP-to-ROM, at which point overlay clears safely.
	// NOTE: do NOT gate on cpuFC[1]. The TG68 presents FC=000 at the clk_sys
	// posedge where addrController samples _cpuAS low, so a cpuFC[1] gate can
	// never fire and the overlay never clears (RAM never appears → garbage
	// RAM descriptor, SP=0, no video). Matches MAME (v8 rom_switch_r clears on
	// any ROM-region read). The premature-$ABC146 concern that motivated the
	// gate was a symptom of other bugs (cmp.l flag race, sim/FPGA core split),
	// now fixed; the first live $A access is legit program exec at $A02E3E.
	wire overlay_trigger = !_cpuAS && (cpuAddr[23:20] == 4'hA);

	always @(posedge clk) begin
		if (!_cpuReset) begin
			rom_overlay <= 1'b1;
			overlay_disable_pending <= 1'b0;
			overlay_trigger_addr_r <= 24'h0;
		end else begin
			if (overlay_trigger && rom_overlay) begin
				overlay_disable_pending <= 1'b1;
				overlay_trigger_addr_r <= cpuAddr;
			end

			if (overlay_disable_pending && _cpuAS) begin
				rom_overlay <= 1'b0;
				overlay_disable_pending <= 1'b0;
			end
		end
	end

endmodule
