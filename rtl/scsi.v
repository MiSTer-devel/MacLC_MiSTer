/* verilator lint_off UNUSED */

// scsi.v
// implements a target only scsi device
  
module scsi
(
	input      clk,

	// scsi interface
	input 	  rst, // bus reset from initiator
	input 	  sys_rst, // system reset (CD engine state survives bus resets)
	input 	  sel,
	input 	  bus_busy, // another device currently holds the bus (its BSY)
	input 	  atn, // initiator requests to send a message
	input 	  cd_enable, // CDROM only: drive present (responds to selection even w/o disc)
	output 	  bsy, // target holds bus

	output 	  msg,
	output 	  cd,
	output 	  io,

	output 	  req,
	output 	  req_bus,   // bus-visible REQ (stays up across HPS block fetches in data phases)
	input 	  ack, // initiator acknowledges a request
	input     host_csr_rd, // pulse: host read the Current SCSI Bus Status reg (REQ poll)
	input     host_data_rd, // pulse: host read the SCSI data register via /DACK (next byte)

	input   [7:0] din, // data from initiator to target
	output  [7:0] dout, // data from target to initiator
	output [15:0] dout_pair,
	output [15:0] dout_pair_next,

	// CD audio PCM (CDROM targets only; zeros on disks). Mixed at the top.
	output signed [15:0] cd_snd_l,
	output signed [15:0] cd_snd_r,

	// interface to io controller
	input         img_mounted,
	input  [31:0] img_blocks,
	output [31:0] io_lba,
	output        io_rd,
	output reg 	  io_wr,
	input         io_ack,

	input   [7:0] sd_buff_addr,
	input   [4:0] sd_buff_addr_hi, // hps_io addr[12:8] (CD whole-frame bursts)
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din,
	input         sd_buff_wr,

	output        dbg_mounted,  // JTAG debug: is a disk mounted on this target?
	output [2:0]  dbg_phase,    // JTAG debug: current target phase
	output [7:0]  dbg_hs,       // JTAG debug: REQ/ACK handshake observations
	output [3:0]  dbg_hs2,      // JTAG debug: completion flags (survive bus reset)
	output [7:0]  dbg_cmd,      // JTAG debug: command-type bitmap (survive reset)

	// JTAG debug: word-write byte-serialization investigation. The ncr5380
	// feeds these in so we can capture, at the REAL target sample point, what
	// byte0/byte1 of the first word write actually latched vs the intended low
	// byte — pinning whether the low byte ever reaches the target.
	input         dbg_dma_word,    // ncr5380 dma_word_latched
	input         dbg_dma_long,    // ncr5380 dma_longword_latched
	input  [7:0]  dbg_dma_lowbyte, // ncr5380 dma_write_low_byte (intended odd byte)
	output [31:0] dbg_wrsnap,      // captured first-word-write snapshot
	output [31:0] dbg_selsnap,     // selection/command handshake observability

	// JTAG debug: multi-block WRITE stall observability (2026-06-10). Live
	// snapshot of the data-transfer state so the 16KB (32-block) result write
	// can be caught mid-stall: which block (data_cnt), phase, the io_wr/io_ack
	// block-flush handshake, the double-buffer select, and tlen.
	//   [15:0]=data_cnt [18:16]=phase [19]=data_complete [20]=io_wr [21]=io_ack
	//   [22]=io_busy [23]=sd_buff_sel [24]=cmd_write [30:25]=tlen[5:0] [31]=req
	output [31:0] dbg_wrstall,
	output [31:0] dbg_wrfb,     // JTAG WRFB: write-phase first-beat forensics
	output [31:0] dbg_cda0,     // JTAG CDA0: cd_audio TOC/engine state (see cd_audio.sv)
	output [31:0] dbg_cda2,     // JTAG CDA2: last 0xC1 CDB {op9, start5, alloc7, alloc8}
output [31:0] dbg_cda3,     // JTAG CDA3: last play-class CDB {op, cdb3, cdb4, cdb5}
output [31:0] dbg_cda4,     // JTAG CDA4: last play-class CDB {cdb1, cdb6, cdb7, cdb8}
	output [31:0] dbg_cda1,     // JTAG CDA1: {toc_rdy,no_media,mounted,ok, sense_asc, sense_key, cmd_cnt, last_op}
	output [31:0] dbg_cdur,     // JTAG CDUR: cd_audio underrun counters (see cd_audio.sv)

	// ===== BlueSCSI Toolbox dedicated block interface (TOOLBOX_ENABLE only) ====
	// Isolated from the disk block interface above so the disk read/write path is
	// untouched (docs/BLUESCSI_CORE_HPS_CONTRACT.md). Inert when TOOLBOX_ENABLE=0.
	// The round-trip FSM that drives tb_rd/tb_wr is M1 stage 2; stage 1 wires the
	// slot end-to-end and ties the outputs off (fs ops 0xD0-D5 already CHECK, as
	// they are not in cmd_ok).
	input         tb_mounted,    // img_mounted[VD_TOOLBOX]: shared folder ready
	output [31:0] tb_lba,
	output        tb_rd,
	output        tb_wr,
	input         tb_ack,
	output [15:0] tb_buff_din
);

// SCSI device id
parameter [2:0] ID = 0;
// Set on the PRIMARY target only (ID 0). Gates the BlueSCSI Toolbox so just one
// target presents as a Toolbox device and owns the dedicated tb_* transport.
// docs/BLUESCSI_CORE_HPS_CONTRACT.md
parameter TOOLBOX_ENABLE = 0;
// Set on the CD-ROM target (ID 3) only. Gates the BlueSCSI Toolbox CD Changer
// (0xD7 LIST / 0xD8 SET NEXT / 0xDA COUNT) onto the SAME tb_* transport as the
// disk Toolbox, with the CD-changer opcode set + a CD-folder HPS handler.
// docs/BLUESCSI_CD_CHANGER_CONTRACT.md
parameter CDCHANGER_ENABLE = 0;
// tb transport buffer size (per lane), in address bits. 8 = one 512-byte SD
// sector (file Toolbox + single-block default). The CD changer sets 11 (8
// sectors = 4 KB) so LIST CDS serves the full 100-entry list in one
// fetch-all-then-serve pass. docs/BLUESCSI_CD_CHANGER_CONTRACT.md §4, §10.
parameter TB_ADDRW = 8;
// Apple CD-ROM mode (docs/plan_scsi_cdrom.md; MAME nscsi_cdrom_apple_device is
// the byte-for-byte oracle). 0 = hard disk: every CDROM conditional below
// constant-folds away, leaving the wedge-hardened disk target bit-identical.
// 1 = read-only CD-ROM: 2048-byte logical blocks served as 4 consecutive
// 512-byte HPS blocks (lba/tlen <<2), AppleCD INQUIRY/TOC/no-disc sense.
parameter CDROM = 0;

// Read-prefetch ring depth (number of 512-byte sectors held in the buffer).
// The read path keeps this many blocks fetched AHEAD of the Mac so the per-block
// HPS fetch latency is hidden and heavy reads (e.g. Control Panels) stream
// instead of stalling at every 512-byte boundary (the #2 pseudo-DMA stall;
// MAME's nscsi_harddisk reads each sector synchronously so it never stalls —
// docs/findings_scsi_dma_stall_offline_2026-06-14.md). RING_LOG=1 reproduces the
// original two-sector double buffer exactly. WRITES are unchanged: they stay on
// the original two-slot double buffer (slots 0/1) regardless of RING_LOG.
parameter  RING_LOG    = 5;             // log2(sectors); 5 => 32-sector / 16KB read ring
                                        // (was 3/8-sector; deepened 2026-06-15 for the #2
                                        // heavy-read stall: cold 7.5.5 extension loading drains
                                        // the ring faster than the HPS refills -> pseudo-DMA
                                        // stall -> driver I/O fail. 32 sectors hides more HPS
                                        // latency. RING_LOG=6 (32KB) needs 600 M10K > 553 avail
                                        // (cache = 3 mirror RAMs x 2 buffers x 2 disks); 5 fits
                                        // at ~504/553. For >16KB, drop the look-ahead mirror
                                        // RAMs (ram_c/ram_d) -> ~1/3 the M10K -> room for 48KB+.)
localparam RING_BLOCKS = 1 << RING_LOG; // sectors buffered for reads
localparam BUF_AW      = 8 + RING_LOG;  // dpram word-address width (256 words/sector)

assign dbg_mounted = mounted;

// BlueSCSI Toolbox transport — stage-1 tie-offs (the round-trip FSM is stage 2).
// The slot is wired end-to-end but inert; fs ops (0xD0-D5) already CHECK because
// they are not in cmd_ok. tb_mounted/tb_ack feed the stage-2 FSM.
// BlueSCSI Toolbox transport outputs — driven by the round-trip FSM below
// (search "Toolbox transport"). tb_buff_din is driven there (buffer read-back).
assign tb_lba = tb_lba_r;
assign tb_rd  = tb_rd_r;
assign tb_wr  = tb_wr_r;
assign dbg_phase = phase;

localparam PHASE_IDLE        = 3'd0;
localparam PHASE_CMD_IN      = 3'd1;
localparam PHASE_DATA_OUT    = 3'd2;
localparam PHASE_DATA_IN     = 3'd3;
localparam PHASE_STATUS_OUT  = 3'd4;
localparam PHASE_MESSAGE_OUT = 3'd5;
localparam PHASE_TB          = 3'd6;  // BlueSCSI Toolbox HPS round-trip
reg [2:0]  phase;

// ------------ sector buffer IO controller read/write -----------------------
// the buffer itself. Holds RING_BLOCKS sectors for reads; writes use slots 0/1.
reg sd_buff_sel;                   // WRITE double-buffer half (unchanged path)
reg [22:0] rd_hps_blk;             // READ ring: # of sectors fetched this command

// HPS sector-buffer byte order.  buffer0 always holds the byte the Mac reads
// FIRST (even byte) and buffer1 the odd byte.  The byte that lands in each
// physical buffer depends on how the IO controller packs sd_buff_dout:
//   * the real MiSTer HPS packs WIDE words LITTLE-endian: disk byte0 -> [7:0].
//   * the Verilator sim model (sim_blkdevice.cpp) packs BIG-endian: byte0->[15:8].
// JTAG probe PSC8 showed 0x5245 ('RE') on hardware where 0x4552 ('ER') was
// expected, confirming the swap.  Map the lanes so the Mac always receives the
// disk's natural big-endian byte order in both builds.
wire [7:0] buf0_q_a, buf1_q_a;
`ifdef VERILATOR
wire [7:0] buf0_data_a = sd_buff_dout[15:8];   // sim packs byte0 in high half
wire [7:0] buf1_data_a = sd_buff_dout[7:0];
assign sd_buff_din = {buf0_q_a, buf1_q_a};
`else
wire [7:0] buf0_data_a = sd_buff_dout[7:0];    // real HPS packs byte0 in low half
wire [7:0] buf1_data_a = sd_buff_dout[15:8];
assign sd_buff_din = {buf1_q_a, buf0_q_a};
`endif

// Buffer addressing. READS span the whole RING_BLOCKS-sector ring; WRITES stay
// on the original two-slot double buffer so the (experimental) write path is
// byte-for-byte unchanged. A command is either a read or a write, so the two
// schemes never collide on a port. The write/2-slot addresses are zero-extended
// to BUF_AW by assignment (no replication, so RING_LOG=1 / BUF_AW=9 still
// compiles and exactly reproduces the original double buffer).
wire [22:0] rd_cur_blk = data_cnt[31:9];               // sector the Mac is reading
wire [RING_LOG-1:0] rd_hps_slot = rd_hps_blk[RING_LOG-1:0];
wire [BUF_AW-1:0] hps_addr_wr = {sd_buff_sel, sd_buff_addr};   // write flush: slot 0/1
wire [BUF_AW-1:0] mac_addr_wr = data_cnt[9:1];                 // Mac write: slot 0/1
// HPS side (port A): read fills target the ring fetch-slot; write flushes keep
// the original sd_buff_sel half.
wire [BUF_AW-1:0] hps_addr = cmd_write ? hps_addr_wr : { rd_hps_slot, sd_buff_addr };
// Mac side (port B): reads address the full ring; writes the 2-slot half.
wire [BUF_AW-1:0] mac_addr = (phase == PHASE_DATA_IN) ? mac_addr_wr : data_cnt[BUF_AW:1];

wire [7:0] buffer0_dout;
wire [7:0] buffer0_dout_next;
wire [7:0] buffer0_dout_next2;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer0
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(buf0_data_a),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(buf0_q_a),

	.address_b(mac_addr),
	.data_b(store_low ? odd_byte_r : din),   // beat-role mux, see BEAT-ROLE FIX below
	.wren_b(buffer0_wr),
	.q_b(buffer0_dout),

	.address_c(mac_addr + 1'b1),
	.q_c(buffer0_dout_next),

	.address_d(mac_addr + 2'd2),
	.q_d(buffer0_dout_next2)
);

wire [7:0] buffer1_dout;
wire [7:0] buffer1_dout_next;
wire [7:0] buffer1_dout_next2;

// WORD-WRITE FIX (refinement, supersedes the direct-feed of dbg_dma_lowbyte):
//   buffer1 holds the ODD byte of each 16-bit unit. In word-mode pseudo-DMA the
//   target samples `din` a few cycles AFTER the ACK pulse, by which time din has
//   reverted to the EVEN byte (dout) — so without this fix the even byte was being
//   duplicated into the odd slot (iotest WRITE verify failed @offset1, actual==byte[0]).
//
//   First attempt (one-liner) fed `dbg_dma_lowbyte` (= ncr5380 dma_write_low_byte)
//   directly into data_b. That was functionally right when timing held, but had two
//   weaknesses:
//     (1) RACE: dma_write_low_byte re-latches on the NEXT CPU `i_dma_wr` rise. If the
//         next word's CPU access lands before the current word's buffer1 dpram-write
//         edge, buffer1 captures the NEXT word's odd byte → corrupt write.
//     (2) PATH: ncr5380 reg → cross-module → mux → BlockRAM data_b is a long combo
//         path on a fit-marginal design; intermittent setup violations corrupt the
//         write and cascade into a SCSI driver fault → Sad Mac on the first WRITE.
//
//   Refinement: latch the current word's odd byte LOCALLY at the word's FIRST
//   beat (stb_ack in PHASE_DATA_IN). At that moment dma_write_low_byte is stable
//   with the current word's wdata[7:0]. Hold it across beat 2's storage.
//   This is both race-free (locked to the current word, immune to the next CPU
//   access) and timing-friendly (BlockRAM data_b is now a short local-reg-to-RAM
//   path). Byte-mode (dbg_dma_word=0) still uses din directly, unchanged.
//
//   BEAT-ROLE FIX (2026-07-29, the +1-inserted-byte write corruption): the
//   original capture/pairing keyed on data_cnt[0] parity — capture at even
//   beats, store odd_byte_r at odd beats — which assumes every word-mode pair
//   lands (even,odd). The Mac driver hand-feeds the first bytes of a write in
//   BYTE mode before flipping to word pseudo-DMA (WRFB: first_word=0,
//   modeflips=1); when that prefix has ODD length the word beats land
//   (odd,even): the first beat hit buffer1 which stored a STALE odd_byte_r
//   (never captured this phase) and dropped the high byte on din — one
//   garbage byte inserted, the rest of the phase shifted one position. Fix:
//   key the DATA SOURCE on the beat's ROLE inside the word pair (wm_beat2),
//   not on count parity. Beat A: din is reliable (dout holds the high byte
//   through the train) — store din, capture dma_write_low_byte. Beat B: din
//   has reverted (the low byte's bus window is 1 cycle, before the ack even
//   rises) — store the captured odd_byte_r. Which BUFFER a beat lands in
//   stays keyed on data_cnt[0] (pure byte-position addressing, always
//   correct); only the value mux moves. Aligned pairs behave bit-identically
//   to the proven path; store_low is beat-locked at stb_ack so the wren-cycle
//   mux no longer samples the live dbg_dma_word (immune to a mid-train
//   re-latch by the next CPU access).
reg [7:0] odd_byte_r;
reg       wm_beat2;   // word pair half-done: next word-mode beat is beat B
reg       store_low;  // this cycle's pending dpram write stores odd_byte_r
always @(posedge clk) begin
	if (rst) begin
		odd_byte_r <= 8'h00;
		wm_beat2   <= 1'b0;
		store_low  <= 1'b0;
	end else begin
		store_low <= 1'b0;
		if (phase != PHASE_DATA_IN)
			wm_beat2 <= 1'b0;
		else if (stb_ack) begin
			// Test wm_beat2 FIRST: once a word pair is in flight the next beat
			// IS beat B by construction, so the decision must not consult the
			// live mode signal. dbg_dma_word (= ncr dma_word_latched) re-latches
			// on the NEXT CPU bus-cycle RISE, which is not DREQ-gated and can
			// land in the ~3-clock gap between the pair's two ACKs. If that next
			// access is byte-mode (the driver flips modes constantly — WRFB
			// measured up to 254 flips in one phase) a mode-first test would
			// mistake beat B for a byte beat, store the stale high byte still on
			// din, and re-slip the lane the fix exists to protect.
			if (wm_beat2) begin         // beat B: din stale, serve the captured low byte
				store_low <= 1'b1;
				wm_beat2  <= 1'b0;
			end else if (dbg_dma_word) begin
				// beat A: high byte on din, low byte stable in the ncr latch
				odd_byte_r <= dbg_dma_lowbyte;
				wm_beat2   <= 1'b1;
			end
			// byte beat: store din (store_low stays 0), wm_beat2 already clear
		end
	end
end

scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer1
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(buf1_data_a),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(buf1_q_a),

	.address_b(mac_addr),
	.data_b(store_low ? odd_byte_r : din),   // beat-role mux, see BEAT-ROLE FIX above
	.wren_b(buffer1_wr),
	.q_b(buffer1_dout),

	.address_c(mac_addr + 1'b1),
	.q_c(buffer1_dout_next),

	.address_d(mac_addr + 2'd2),
	.q_d(buffer1_dout_next2)
);

reg old_io_ack;
always @(posedge clk) begin
	old_io_ack <= io_ack;
	if (phase == PHASE_IDLE)
		sd_buff_sel <= 0;
	else
		// ~ca_io_active: a CD-audio channel transfer started at bus-idle can
		// still be in flight when the Mac's next command reaches a data phase;
		// its ack falling here toggled the write double-buffer and bumped the
		// ring counter below - wrong sectors served (HW 2026-07-17: artifacted
		// CD icons, then a wedged READ). Same scope the io_busy term always had.
		if (old_io_ack & ~io_ack & ~ca_io_active) sd_buff_sel <= !sd_buff_sel;

	// READ ring fetch counter: # of sectors the HPS has delivered this command.
	// Reset alongside data_cnt (any non-transfer phase); bump on each io_ack
	// falling edge during a read. Writes never touch it (they use sd_buff_sel).
	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT)
		rd_hps_blk <= 23'd0;
	else if (old_io_ack & ~io_ack & cmd_read & ~ca_io_active)
		rd_hps_blk <= rd_hps_blk + 23'd1;
end

// -----------------------------------------------------------

// status replies
reg [7:0]  status;
`define STATUS_OK 8'h00
`define STATUS_CHECK_CONDITION 8'h02

// message codes
`define MSG_CMD_COMPLETE 8'h00
	
// drive scsi signals according to phase
assign msg = (phase == PHASE_MESSAGE_OUT);
assign cd = (phase == PHASE_CMD_IN) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
assign io = (phase == PHASE_DATA_OUT) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);

// READ stall: for a block READ, the sector the Mac wants (rd_cur_blk) has not
// been fetched yet (only sectors [0, rd_hps_blk) are in the ring). Gated on
// cmd_read — INQUIRY/READ_CAPACITY/MODE_SENSE/REQUEST_SENSE also use DATA_OUT but
// serve data combinationally with no HPS fetch (rd_hps_blk stays 0), so they
// must NOT take this stall. Depth-independent; replaces the old 2-slot "half
// being filled" test. WRITE + non-data clauses unchanged.
// '&& mounted' in the read clause: media loss mid-READ (guest eject) stops
// the ring refill, and holding DTACK on data that will never arrive ground
// the whole OS at the 8ms watchdog ceiling per poll (HW 2026-07-17). With
// the medium gone the read completes with stale bytes and the driver gets
// its error through the normal status path instead.
// wr_pending lives at module scope (declared here, driven by the flush engine
// below) because io_busy must include it: between a block's req_wr edge and
// the flush issuing (io_wr rise) — one cycle normally, longer while a previous
// flush is still in flight — neither io_wr nor io_ack is high, so the old
// (io_wr | io_ack) busy term dropped REQ for that window and one extra
// pseudo-DMA word could land in the slot the flush hadn't read yet. TIM3
// install forensics 2026-07-28: a 7.5 MB write otherwise perfect except the
// FIRST WORD of one 512-byte block ("Machine Data" blk 81) — this window's
// exact signature.
reg    wr_pending;
// (2026-07-29) rd_ahead_blk: block of the FURTHEST byte one pseudo-DMA
// transaction can consume. The host-face serves din_pair/din_pair_next =
// bytes data_cnt..data_cnt+3, and a longword read CAPTURES the +2/+3 pair
// (its ACK-suppressed second word, ncr5380 dma_second_word_data) at the END
// of its FIRST bus cycle. When the driver's byte/word prefix skews the
// longword grid off the 512-byte block grid, that capture crosses into the
// NEXT ring block — which the old stall (rd_cur_blk only) never validated.
// At a just-in-time fill the capture read the ring slot's PREVIOUS occupant:
// TIM Voices 1 fork 0x18200 got 0x8080 (the bytes exactly one ring-depth =
// 4 KB earlier) instead of 0x3840; deterministic, 2 runs x 2 builds
// (docs/resume_prompt_2026-07-29.md §8, CD sector 49385+512). Stall REQ
// until every byte the transaction can touch is in the ring. rd_ahead_needed
// clamps at the transfer TAIL, where +3 pokes past the last armed block: no
// fetch would ever arrive (deadlock), and the host never consumes those
// bytes (the driver's trailing word/byte reads stay inside the armed length
// and data_complete ends the phase first).
wire [22:0] rd_ahead_blk    = (data_cnt + 32'd3) >> 9;
wire        rd_ahead_needed = (rd_ahead_blk < rd_blk_total);
wire   io_busy = (phase == PHASE_DATA_OUT && cmd_read && mounted &&
                  ((rd_cur_blk >= rd_hps_blk) ||
                   (rd_ahead_needed && (rd_ahead_blk >= rd_hps_blk)))) ||
                 (phase == PHASE_DATA_IN  && (io_wr | wr_pending | (io_ack & ~ca_io_active)) && data_cnt[9] == sd_buff_sel) ||
                 (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN && (io_rd_d | io_wr | wr_pending | (io_ack & ~ca_io_active)));
	// A zero-length transfer (e.g. INQUIRY with allocation length 0, or a
	// WRITE with transfer length 0) must complete immediately: data_complete
	// only sets on an ACK edge, which never comes when the initiator expects
	// no data — REQ would be held forever (same deadlock class as the
	// allocation-length over-serve).
	wire data_done = data_complete || (data_len == 32'd0);
	wire data_phase_complete = ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN)) && data_done;
	// REQ assertion. Previously this was gated on !sel ("wait for the initiator
	// to drop SEL before the first REQ"). But the reference implementations
	// (Snow's NCR5380, MAME) assert REQ as soon as the target is selected and
	// in an information-transfer phase — they do NOT wait for SEL to deassert.
	// Our !sel gate added an extra handshake step: target asserts BSY at
	// CMD_IN, then withholds REQ until SEL drops. The Mac ROM driver's
	// SEL-release intermittently races that, the command never starts, the
	// driver times out and issues a bus RESET -> the CMD_IN->IDLE->reselect
	// loop seen on the FPGA (but not on real HW or MAME). Drop the !sel gate;
	// `phase != PHASE_IDLE` already prevents REQ during the IDLE->selection
	// sampling window, so REQ now comes up on selection like the references.
	assign req = (phase != PHASE_IDLE) && (phase != PHASE_TB) && !ack && !io_busy && !data_phase_complete;

	// Bus-VISIBLE REQ (CSR bit 5 / BSR DRQ): stays asserted across the HPS
	// 512-byte block-boundary fetches in the data phases. Real drives never
	// drop REQ mid-command for ~ms, and both oracles guarantee the same
	// observable (Snow pre-buffers whole responses; MAME synthesizes DRQ
	// from its FIFO). The System-7-era HD SC 4.3 driver polls CSR/BSR
	// between 512-byte pseudo-DMA chunks — when it saw our dead bus it
	// concluded the transfer died and parked forever (the Welcome wedge at
	// data_cnt=512). Flow control is unaffected: the DACK path still stalls
	// the CPU via `req` (DTACK gate) until the buffer half is really valid,
	// so a premature data access waits instead of reading stale bytes.
	// Non-data phases keep the io_busy suppression (status byte must not
	// be offered while a flush/fetch is still in flight).
	// (LBMacTwo 5adc2e1, HW-validated with 2d025c5 in round 6.)
	assign req_bus = (phase != PHASE_IDLE) && (phase != PHASE_TB) && !ack && !data_phase_complete &&
	                 ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN) || !io_busy);

assign bsy = (phase != PHASE_IDLE);

assign dout = (phase == PHASE_STATUS_OUT)?status:
	 (phase == PHASE_MESSAGE_OUT)?`MSG_CMD_COMPLETE:
	 (phase == PHASE_DATA_OUT)?cmd_dout:
	 8'h00;
assign dout_pair = (phase == PHASE_STATUS_OUT)?{status, status}:
	 (phase == PHASE_MESSAGE_OUT)?{`MSG_CMD_COMPLETE, `MSG_CMD_COMPLETE}:
	 (phase == PHASE_DATA_OUT)?cmd_dout_pair:
	 16'h0000;
assign dout_pair_next = (phase == PHASE_STATUS_OUT)?{status, status}:
	 (phase == PHASE_MESSAGE_OUT)?{`MSG_CMD_COMPLETE, `MSG_CMD_COMPLETE}:
	 (phase == PHASE_DATA_OUT)?cmd_dout_pair_next:
	 16'h0000;

// de-multiplex different data sources
wire [7:0] cmd_dout =
		cmd_read?(data_cnt[0] ? buffer1_dout : buffer0_dout):
		cmd_inquiry?inquiry_dout:
		cmd_read_capacity?read_capacity_dout:
		cmd_mode_sense?mode_sense_dout:
		cmd_request_sense?request_sense_dout:
		cmd_cd_toc?cd_toc_dout:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?cd_toc2_dout:
		cmd_cd_t43f0?cd_toc43_dout:
		cmd_cd_subq?cd_subq_dout:
		cmd_cd_subq43?cd_subq43_dout:
		cmd_cd_astat?cd_astat_dout:
		cmd_tb_devinfo?tb_devinfo_dout:
		cmd_tb_debug?tb_debug_dout:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve:
		8'h00;
wire [15:0] cmd_dout_pair =
		cmd_read?(data_cnt[0] ? {buffer1_dout, buffer0_dout_next} : {buffer0_dout, buffer1_dout}):
		cmd_inquiry?{inquiry_dout, inquiry_dout_next}:
		cmd_read_capacity?{read_capacity_dout, read_capacity_dout_next}:
		cmd_mode_sense?{mode_sense_dout, mode_sense_dout_next}:
		cmd_request_sense?{request_sense_dout, request_sense_dout_next}:
		cmd_cd_toc?{cd_toc_dout, cd_toc_dout_next}:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?{cd_toc2_dout, cd_toc2_dout_next}:
		cmd_cd_t43f0?{cd_toc43_dout, cd_toc43_dout_next}:
		cmd_cd_subq?{cd_subq_dout, cd_subq_dout_next}:
		cmd_cd_subq43?{cd_subq43_dout, cd_subq43_dout_next}:
		cmd_cd_astat?{cd_astat_dout, cd_astat_dout_next}:
		cmd_tb_devinfo?{tb_devinfo_dout, tb_devinfo_dout_next}:
		cmd_tb_debug?{tb_debug_dout, tb_debug_dout_next}:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve_pair:
		16'h0000;
wire [15:0] cmd_dout_pair_next =
		cmd_read?(data_cnt[0] ? {buffer1_dout_next, buffer0_dout_next2} : {buffer0_dout_next, buffer1_dout_next}):
		cmd_inquiry?{inquiry_dout_next2, inquiry_dout_next3}:
		cmd_read_capacity?{read_capacity_dout_next2, read_capacity_dout_next3}:
		cmd_mode_sense?{mode_sense_dout_next2, mode_sense_dout_next3}:
		cmd_request_sense?{request_sense_dout_next2, request_sense_dout_next3}:
		cmd_cd_toc?{cd_toc_dout_next2, cd_toc_dout_next3}:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?{cd_toc2_dout_next2, cd_toc2_dout_next3}:
		cmd_cd_t43f0?{cd_toc43_dout_next2, cd_toc43_dout_next3}:
		cmd_cd_subq?{cd_subq_dout_next2, cd_subq_dout_next3}:
		cmd_cd_subq43?{cd_subq43_dout_next2, cd_subq43_dout_next3}:
		cmd_cd_astat?{cd_astat_dout_next2, cd_astat_dout_next3}:
		cmd_tb_devinfo?{tb_devinfo_dout_next2, tb_devinfo_dout_next3}:
		cmd_tb_debug?{tb_debug_dout_next2, tb_debug_dout_next3}:
		(cmd_tb_fs_in || cmd_cdc_in)?tb_serve_pair_next:
		16'h0000;

// REQUEST SENSE response: minimal fixed-format sense, "NO SENSE".
//   byte 0 = 0x70 (current error, valid=0), byte 7 = 0x0a (add'l length 10),
//   sense key (byte 2) = 0 = NO SENSE, all else 0.
//   CDROM serves the latched cd_sense_key/asc (byte 2 / byte 12) instead, so
//   the AppleCD driver sees NOT READY + vendor ASC 0xB0 while no disc is in.
function [7:0] sense_byte;
	input [31:0] cnt;
	begin
		sense_byte =
			(cnt == 32'd0 )?8'h70:
			(cnt == 32'd2 )?((CDROM != 0)?{4'd0, cd_sense_key}:8'h00):
			(cnt == 32'd7 )?8'h0a:
			(cnt == 32'd12)?((CDROM != 0)?cd_sense_asc:8'h00):
			8'h00;
	end
endfunction
wire [7:0] request_sense_dout       = sense_byte(data_cnt);
wire [7:0] request_sense_dout_next  = sense_byte(data_cnt_next);
wire [7:0] request_sense_dout_next2 = sense_byte(data_cnt_next2);
wire [7:0] request_sense_dout_next3 = sense_byte(data_cnt_next3);

// INQUIRY vendor id (8 bytes, space-padded). The value is SCSI_VENDOR_STRING,
// defined in the included rtl/scsi_vendor.vh (committed default "MiSTer  "). A
// throwaway build (e.g. BlueSCSI Toolbox co-testing) overrides the vendor by
// editing that one file — no build-specific vendor string ever lives here, and
// the edit is kept out of commits with:
//   git update-index --skip-worktree rtl/scsi_vendor.vh   (undo: --no-skip-worktree)
`include "scsi_vendor.vh"
localparam [63:0] SCSI_VENDOR_ID = `SCSI_VENDOR_STRING;

// output of inquiry command, identify as "MiSTer  VIRTUAL DISKx" (x = SCSI ID)
//   vendor  (bytes  8-15): "MiSTer  "        (8 chars, space-padded)
//   product (bytes 16-31): "VIRTUAL DISKx   " (16 chars, x = '0'+ID)
// (identifiers match lbmactwo_MiSTer rtl/scsi.v — keep the SCSI files in sync)
// additional-length byte = 31 -> standard 36-byte INQUIRY response (5 + 31),
// matching real drives and Snow. It was 32 (=37 total): a driver that reads
// the standard 36 bytes then left 1 unserved byte on the target -> REQ held
// forever -> the post-clamp Welcome wedge of 2026-06-10c.
// CDROM INQUIRY: byte-exact copy of MAME nscsi_cdrom_apple_device (data taken
// from the ROM of an AppleCD 150; same descriptor scsi_empty_cd shipped). The
// stock Apple CD-ROM extension binds only to known Apple-shipped drives, so
// the SONY CDU-8002 identity is required for the driver to attach (this is
// hardware emulation fidelity, like MAME — not a vendor-string cosmetic).
// 5 + additional-length 0x31 = 54-byte standard response.
function [7:0] cd_inquiry_byte;
	input [31:0] cnt;
	begin
		cd_inquiry_byte =
			(cnt == 32'd0 )?8'h05:  // CD-ROM device class
			(cnt == 32'd1 )?8'h80:  // removable
			(cnt == 32'd2 )?8'h02:  // ANSI SCSI-2 (dialect tier; Snow-matched)
			(cnt == 32'd3 )?8'h02:
			(cnt == 32'd4 )?8'h31:  // additional length
			(cnt == 32'd8 )?"S":(cnt == 32'd9 )?"O":
			(cnt == 32'd10)?"N":(cnt == 32'd11)?"Y":
			((cnt >= 32'd12) && (cnt <= 32'd15))?" ":  // vendor pad
			(cnt == 32'd16)?"C":(cnt == 32'd17)?"D":
			(cnt == 32'd18)?"-":(cnt == 32'd19)?"R":
			(cnt == 32'd20)?"O":(cnt == 32'd21)?"M":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"C":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"U":
			(cnt == 32'd26)?"-":(cnt == 32'd27)?"8":
			(cnt == 32'd28)?"0":(cnt == 32'd29)?"0":
			(cnt == 32'd30)?"4":(cnt == 32'd31)?" ":  // 8004: standard dialect
			(cnt == 32'd32)?"1":(cnt == 32'd33)?".":
			(cnt == 32'd34)?"9":(cnt == 32'd35)?"a":
			(cnt == 32'd39)?8'hd0:(cnt == 32'd40)?8'h90:
			(cnt == 32'd41)?8'h27:(cnt == 32'd42)?8'h3e:
			(cnt == 32'd43)?8'h01:(cnt == 32'd44)?8'h04:
			(cnt == 32'd45)?8'h91:(cnt == 32'd47)?8'h18:
			(cnt == 32'd48)?8'h06:(cnt == 32'd49)?8'hf0:
			(cnt == 32'd50)?8'hfe:
			8'h00;
	end
endfunction

function [7:0] inquiry_byte;
	input [31:0] cnt;
	begin
		if (CDROM != 0) inquiry_byte = cd_inquiry_byte(cnt);
		else inquiry_byte =
			(cnt == 32'd4 )?8'd31:  // additional length

			// vendor id (bytes 8-15) from the SCSI_VENDOR_ID parameter. A string's
			// first char is its most-significant byte, so byte (cnt-8) sits at
			// SCSI_VENDOR_ID[(15-cnt)*8 +: 8]. Default "MiSTer  "; build-time
			// override lives in the gitignored rtl/scsi_vendor_local.vh (see above).
			((cnt >= 32'd8) && (cnt <= 32'd15)) ? SCSI_VENDOR_ID[(15 - cnt)*8 +: 8] :

			(cnt == 32'd16)?"V":(cnt == 32'd17)?"I":
			(cnt == 32'd18)?"R":(cnt == 32'd19)?"T":
			(cnt == 32'd20)?"U":(cnt == 32'd21)?"A":
			(cnt == 32'd22)?"L":(cnt == 32'd23)?" ":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"I":
			(cnt == 32'd26)?"S":(cnt == 32'd27)?"K":
			(cnt == 32'd28)?"0" + {5'd0, ID}:
			(cnt == 32'd29)?" ":(cnt == 32'd30)?" ":
			(cnt == 32'd31)?" ":
			8'h00;
	end
endfunction
wire [31:0] data_cnt_next = data_cnt + 32'd1;
wire [31:0] data_cnt_next2 = data_cnt + 32'd2;
wire [31:0] data_cnt_next3 = data_cnt + 32'd3;
wire [7:0] inquiry_dout       = inquiry_byte(data_cnt);
wire [7:0] inquiry_dout_next  = inquiry_byte(data_cnt_next);
wire [7:0] inquiry_dout_next2 = inquiry_byte(data_cnt_next2);
wire [7:0] inquiry_dout_next3 = inquiry_byte(data_cnt_next3);

// output of read capacity command
//wire [31:0] capacity = 32'd41056;   // 40960 + 96 blocks = 20MB
//wire [31:0] capacity = 32'd1024096;   // 1024000 + 96 blocks = 500MB
// Initialized: the CDROM target answers MODE SENSE before any image has ever
// been mounted (drive present, no disc), so the capacity bytes must not be X.
reg [31:0] capacity = 32'd0;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			// CDROM: capacity is in 2048-byte logical blocks (last LBA), i.e.
			// the mounted 512-block count / 4 - 1. Disks: 512-blocks - 1.
			capacity <= (CDROM != 0) ? ({2'b00, img_blocks[31:2]} - 1'd1)
			                         : (img_blocks - 1'd1);
			if (!mounted) $display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end else if ((CDROM != 0) && cd_eject_pulse)
		// EJECT (Apple 0xC0 or standard 0x1B LoEj — cmd_cd_eject_any): drop
		// the medium; the next img_mounted pulse (OSD mount or the BlueSCSI
		// CD-changer SET NEXT CD remap) is the "insert disc" edge the AppleCD
		// driver's insertion poll is waiting for. The HPS-side image stays
		// mounted — harmless, the target simply reports no-disc until then.
		mounted <= 0;
end

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity[31:24]:
		(data_cnt == 32'd1 )?capacity[23:16]:
		(data_cnt == 32'd2 )?capacity[15:8]:
		(data_cnt == 32'd3 )?capacity[7:0]:
		(data_cnt == 32'd6 )?((CDROM != 0)?8'h08:8'd2): // block length 2048 (CD) / 512 (disk)
		8'h00;
wire [7:0] read_capacity_dout_next =
		(data_cnt_next == 32'd0 )?capacity[31:24]:
		(data_cnt_next == 32'd1 )?capacity[23:16]:
		(data_cnt_next == 32'd2 )?capacity[15:8]:
		(data_cnt_next == 32'd3 )?capacity[7:0]:
		(data_cnt_next == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;
wire [7:0] read_capacity_dout_next2 =
		(data_cnt_next2 == 32'd0 )?capacity[31:24]:
		(data_cnt_next2 == 32'd1 )?capacity[23:16]:
		(data_cnt_next2 == 32'd2 )?capacity[15:8]:
		(data_cnt_next2 == 32'd3 )?capacity[7:0]:
		(data_cnt_next2 == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;
wire [7:0] read_capacity_dout_next3 =
		(data_cnt_next3 == 32'd0 )?capacity[31:24]:
		(data_cnt_next3 == 32'd1 )?capacity[23:16]:
		(data_cnt_next3 == 32'd2 )?capacity[15:8]:
		(data_cnt_next3 == 32'd3 )?capacity[7:0]:
		(data_cnt_next3 == 32'd6 )?((CDROM != 0)?8'h08:8'd2):
		8'h00;

// =====================================================================
// CDROM response synthesis (folds away on disk targets).
//
// The cd_audio engine (rtl/cd_audio.sv) owns the real multi-track TOC
// (fetched from the HPS MCDA blob window, with a synthesized single-track
// fallback for stock Main / sim / flat images), the AppleCD playback state
// machine and the live position registers. This section only wires its
// precomputed 0xC1 response RAM and live 0xCC/0xC2 registers into the
// serve lanes — the serve path stays free of any live arithmetic.
// Oracle: MAME nscsi_cdrom_apple_device, as before.
// =====================================================================
function [7:0] cd_bcd2bin;
	input [7:0] b;
	cd_bcd2bin = {4'd0, b[7:4]} * 8'd10 + {4'd0, b[3:0]};
endfunction

// cd_audio interface wires (driven by the generate block near the io logic)
wire        ca_io_active, ca_io_rd_w;
wire [31:0] ca_io_lba;
wire  [7:0] ca_ast_code, ca_cur_ctrl, ca_cur_trk;
wire  [7:0] ca_abs_m, ca_abs_s, ca_abs_f, ca_rel_m, ca_rel_s, ca_rel_f;
wire  [7:0] ca_t43_q0, ca_t43_q1, ca_t43_q2, ca_t43_q3;
wire  [9:0] ca_t43_len;
// 0x43 start-track filter (serve-time address transform; the table stays
// full-from-track-1): header bytes 0-3 serve as-is, descriptor bytes are
// offset so the FIRST served descriptor is the requested start track;
// start 0xAA = the lead-out row (the driver's very first ask on HW was
// {start=0xAA, alloc=12} = header + leadout only). The header's u16be
// length field is overridden to the filtered length. nreal is recovered
// from the table length: len = (nreal+1)*8 + 6 -> nreal = (len-14)>>3 +1;
// simpler: rows_total = (ca_t43_len - 10'd6) >> 3 (tracks + leadout).
wire [6:0]  ca_t43_nreal = (ca_t43_len >= 10'd14) ? ((ca_t43_len - 10'd14) >> 3) + 7'd1 : 7'd1;
wire [7:0]  ca_t43_start = cmd[6];
wire [6:0]  ca_t43_soff  =
	(ca_t43_start == 8'h00 || ca_t43_start == 8'h01) ? 7'd0 :
	(ca_t43_start == 8'hAA) ? ca_t43_nreal :
	(ca_t43_start > {1'b0, ca_t43_nreal}) ? ca_t43_nreal :
	ca_t43_start[6:0] - 7'd1;
// filtered data length (u16-be field value = bytes after the field = rows*8 + 2)
wire [9:0]  ca_t43_flen  = {(7'd1 + ca_t43_nreal - ca_t43_soff), 3'b000} + 10'd2;
wire [9:0]  ca_t43_tot   = ca_t43_flen + 10'd2;      // total serveable bytes
wire [8:0]  ca_t43_addr  = (data_cnt < 32'd4) ? data_cnt[8:0]
                         : (9'd4 + {ca_t43_soff, 3'b000} + (data_cnt[8:0] - 9'd4));
// standard audio-status codes ([PIONEER] 2-27C via Snow): 0x11 play,
// 0x12 paused, 0x13 completed/stopped (engine ast_code 0/1/3/5).
wire  [7:0] ca_ast_std = (ca_ast_code == 8'd0) ? 8'h11 :
                         (ca_ast_code == 8'd1) ? 8'h12 : 8'h13;
function [7:0] scsi_bin2bcd;           // 0..99 (vendor-dialect BCD serving)
	input [7:0] v;
	scsi_bin2bcd = {4'd0, (v / 8'd10)} << 4 | {4'd0, (v % 8'd10)};
endfunction
wire  [7:0] ca_toc_q0, ca_toc_q1, ca_toc_q2, ca_toc_q3;
wire        ca_toc_ready;
reg         ca_cmd_stb = 1'b0, ca_read_stb = 1'b0, ca_eject_stb = 1'b0;

// Apple 0xC1 serve addressing into the engine's response RAM:
//   layout [0..3] header, [4..7] lead-out, [8+4k..] track k+1 descriptors.
// Mode (CDB[9][7:6]) selects the base; track mode indexes by BCD CDB[5].
// Reads past the 99 precomputed descriptors clamp to the last one
// (byte-in-descriptor preserved) — MAME "keep returning the last track".
wire [7:0] ca_toc_trk_bin = cd_bcd2bin(cmd[5]);
wire [8:0] ca_toc_trk_k   = (ca_toc_trk_bin == 8'd0) ? 9'd0 :
                            (ca_toc_trk_bin >  8'd99) ? 9'd98 :
                            {1'b0, ca_toc_trk_bin} - 9'd1;
wire [8:0] ca_toc_base =
	(cmd[9][7:6] == 2'b01) ? 9'd4 :
	(cmd[9][7:6] == 2'b10) ? (9'd8 + {ca_toc_trk_k[6:0], 2'b00}) :
	                         9'd0;
wire [8:0] ca_toc_raw  = ca_toc_base + data_cnt[8:0];
wire [8:0] ca_toc_addr = (ca_toc_raw < 9'd404) ? ca_toc_raw
                       : (9'd400 + {7'd0, ca_toc_raw[1:0]});

wire [7:0] cd_toc_dout         = ca_toc_ready ? ca_toc_q0 : 8'h00;
wire [7:0] cd_toc_dout_next    = ca_toc_ready ? ca_toc_q1 : 8'h00;
wire [7:0] cd_toc_dout_next2   = ca_toc_ready ? ca_toc_q2 : 8'h00;
wire [7:0] cd_toc_dout_next3   = ca_toc_ready ? ca_toc_q3 : 8'h00;

// READ Q SUBCODE (0xC2, 9 bytes): control, track BCD, index 01, relative
// M/S/F, absolute M/S/F — live registers from the engine.
function [7:0] cd_subq_byte;
	input [31:0] cnt;
	begin
		cd_subq_byte = (cnt == 32'd1) ? scsi_bin2bcd(ca_cur_trk) :
		               (cnt == 32'd2) ? 8'h01 :
		               (cnt == 32'd3) ? scsi_bin2bcd(ca_rel_m) :
		               (cnt == 32'd4) ? scsi_bin2bcd(ca_rel_s) :
		               (cnt == 32'd5) ? scsi_bin2bcd(ca_rel_f) :
		               (cnt == 32'd6) ? scsi_bin2bcd(ca_abs_m) :
		               (cnt == 32'd7) ? scsi_bin2bcd(ca_abs_s) :
		               (cnt == 32'd8) ? scsi_bin2bcd(ca_abs_f) : 8'h00;
	end
endfunction

// AUDIO STATUS (0xCC, 6 bytes): {status, 0, ADR/control, abs M, S, F};
// type 1 (CDB[3]==1) reports channel volumes instead (0xFF = full).
function [7:0] cd_astat_byte;
	input [31:0] cnt;
	begin
		cd_astat_byte = (cnt == 32'd0) ? ((cmd[3] == 8'd1) ? 8'hFF : ca_ast_code) :
		                (cnt == 32'd1) ? ((cmd[3] == 8'd1) ? 8'hFF : 8'h00) :
		                (cnt == 32'd2) ? ca_cur_ctrl :
		                (cnt == 32'd3) ? scsi_bin2bcd(ca_abs_m) :
		                (cnt == 32'd4) ? scsi_bin2bcd(ca_abs_s) :
		                (cnt == 32'd5) ? scsi_bin2bcd(ca_abs_f) : 8'h00;
	end
endfunction

wire [7:0] cd_subq_dout        = cd_subq_byte(data_cnt);
wire [7:0] cd_subq_dout_next   = cd_subq_byte(data_cnt_next);
wire [7:0] cd_subq_dout_next2  = cd_subq_byte(data_cnt_next2);
wire [7:0] cd_subq_dout_next3  = cd_subq_byte(data_cnt_next3);
// standard 0x42 READ SUB-CHANNEL, format 1 (current position), MSF form,
// 16 bytes: {00, status, u16be len=12, 01, adr_ctrl, track, index=1,
// {0,M,S,F} abs, {0,M,S,F} rel} — binary values (Snow is the reference).
function [7:0] cd_subq43_byte;
	input [31:0] cnt;
	begin
		cd_subq43_byte = (cnt == 32'd1)  ? ca_ast_std :
		                 (cnt == 32'd3)  ? 8'd12 :
		                 (cnt == 32'd4)  ? 8'h01 :
		                 (cnt == 32'd5)  ? ca_cur_ctrl :
		                 (cnt == 32'd6)  ? ca_cur_trk :
		                 (cnt == 32'd7)  ? 8'h01 :
		                 (cnt == 32'd9)  ? ca_abs_m :
		                 (cnt == 32'd10) ? ca_abs_s :
		                 (cnt == 32'd11) ? ca_abs_f :
		                 (cnt == 32'd13) ? ca_rel_m :
		                 (cnt == 32'd14) ? ca_rel_s :
		                 (cnt == 32'd15) ? ca_rel_f : 8'h00;
	end
endfunction
wire [7:0] cd_subq43_dout       = cd_subq43_byte(data_cnt);
wire [7:0] cd_subq43_dout_next  = cd_subq43_byte(data_cnt_next);
wire [7:0] cd_subq43_dout_next2 = cd_subq43_byte(data_cnt_next2);
wire [7:0] cd_subq43_dout_next3 = cd_subq43_byte(data_cnt_next3);
function [7:0] t43_hdr_fix;      // filtered length in bytes 0/1; ZERO past the
	input [31:0] cnt;            // real payload (serving pads to the armed
	input [7:0]  raw;            // allocation length — see the data_len note)
	begin
		t43_hdr_fix = (cnt >= {22'd0, ca_t43_tot}) ? 8'h00 :
		              (cnt == 32'd0) ? {6'd0, ca_t43_flen[9:8]} :
		              (cnt == 32'd1) ? ca_t43_flen[7:0] : raw;
	end
endfunction
wire [7:0] cd_toc43_dout        = ca_toc_ready ? t43_hdr_fix(data_cnt,       ca_t43_q0) : 8'h00;
wire [7:0] cd_toc43_dout_next   = ca_toc_ready ? t43_hdr_fix(data_cnt_next,  ca_t43_q1) : 8'h00;
wire [7:0] cd_toc43_dout_next2  = ca_toc_ready ? t43_hdr_fix(data_cnt_next2, ca_t43_q2) : 8'h00;
wire [7:0] cd_toc43_dout_next3  = ca_toc_ready ? t43_hdr_fix(data_cnt_next3, ca_t43_q3) : 8'h00;

// format-2 FULL TOC / format-1 SESSION INFO: pre-rendered T2 plane, linear
// addressing (the plane IS the response image; session page at [496..507]).
// Zero-fill past the real payload — serving pads to the armed allocation
// per the serving law; the u16be length fields carry the true sizes.
wire [7:0]  ca_t2_q0, ca_t2_q1, ca_t2_q2, ca_t2_q3;
wire [9:0]  ca_t2_len;
wire        ca_disc_audio;
wire [8:0]  ca_t2_addr = (cmd_cd_t43f1 ? 9'd496 : 9'd0) + data_cnt[8:0];
function [7:0] t2_fix;           // full TOC: zero past toc2_len
	input [31:0] cnt;
	input [7:0]  raw;
	t2_fix = (cnt >= {22'd0, ca_t2_len}) ? 8'h00 : raw;
endfunction
function [7:0] sess_fix;         // session-info page: 12 real bytes
	input [31:0] cnt;
	input [7:0]  raw;
	sess_fix = (cnt >= 32'd12) ? 8'h00 : raw;
endfunction
wire [7:0] cd_toc2_dout        = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt, ca_t2_q0) : t2_fix(data_cnt, ca_t2_q0);
wire [7:0] cd_toc2_dout_next   = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next, ca_t2_q1) : t2_fix(data_cnt_next, ca_t2_q1);
wire [7:0] cd_toc2_dout_next2  = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next2, ca_t2_q2) : t2_fix(data_cnt_next2, ca_t2_q2);
wire [7:0] cd_toc2_dout_next3  = !ca_toc_ready ? 8'h00 :
                                 cmd_cd_t43f1 ? sess_fix(data_cnt_next3, ca_t2_q3) : t2_fix(data_cnt_next3, ca_t2_q3);

wire [7:0] cd_astat_dout       = cd_astat_byte(data_cnt);
wire [7:0] cd_astat_dout_next  = cd_astat_byte(data_cnt_next);
wire [7:0] cd_astat_dout_next2 = cd_astat_byte(data_cnt_next2);
wire [7:0] cd_astat_dout_next3 = cd_astat_byte(data_cnt_next3);

// MODE SENSE(6): 4-byte header + 8-byte block descriptor = 12 bytes.
// Header byte 0 = mode data length = total-1 = 11, so a driver that trusts
// the length field reads exactly what we serve (it was 0, which told
// length-honoring drivers "nothing follows the header" while we kept
// serving — REQ-held wedge class).
// BlueSCSI Toolbox detection page (docs/BLUESCSI_HANDOFF.md §2): when the
// client requests vendor page 0x31 (CDB[2][5:0]==0x31) serve a 56-byte response
// carrying the magic string it matches on, instead of the 12-byte default.
// Page select is combinational on the latched CDB, stable through the data
// phase; data_len switches 12<->56 on the same select. Other pages unchanged.
// Gated on tb_ready: advertise the Toolbox detection page ONLY once the HPS
// handler has mounted the slot. On a stock Main (no handler) tb_ready=0, so a
// page-0x31 request falls through to the default mode page and the target looks
// like a plain disk -> the Mac client never engages -> no app-close hang (§4a).
wire       mode_sense_p31 = TOOLBOX_ENABLE && tb_ready && cmd_mode_sense && (cmd[2][5:0] == 6'h31);

// 56-byte page-0x31 response (self-contained; block-descriptor #blocks=0 per the
// spec example -- the client only validates the page string). 4 header + 8 block
// descriptor + 2 page header + 42 string. DBD ignored (descriptor always
// present, length byte = 8), matching the default response.
function [7:0] mode_sense_p31_byte;
	input [31:0] cnt;
	begin
		mode_sense_p31_byte =
			(cnt == 32'd0 )?8'd55:   // mode data length = 56 - 1
			(cnt == 32'd3 )?8'd8:    // block descriptor length
			(cnt == 32'd10)?8'd2:    // block length 0x000200 (512); #blocks = 0
			(cnt == 32'd12)?8'h31:   // page code 0x31
			(cnt == 32'd13)?8'h2a:   // page length = 42
			(cnt == 32'd14)?"B":(cnt == 32'd15)?"l":(cnt == 32'd16)?"u":(cnt == 32'd17)?"e":
			(cnt == 32'd18)?"S":(cnt == 32'd19)?"C":(cnt == 32'd20)?"S":(cnt == 32'd21)?"I":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"i":(cnt == 32'd24)?"s":(cnt == 32'd25)?" ":
			(cnt == 32'd26)?"t":(cnt == 32'd27)?"h":(cnt == 32'd28)?"e":(cnt == 32'd29)?" ":
			(cnt == 32'd30)?"B":(cnt == 32'd31)?"E":(cnt == 32'd32)?"S":(cnt == 32'd33)?"T":
			(cnt == 32'd34)?" ":(cnt == 32'd35)?"S":(cnt == 32'd36)?"T":(cnt == 32'd37)?"O":
			(cnt == 32'd38)?"L":(cnt == 32'd39)?"E":(cnt == 32'd40)?"N":(cnt == 32'd41)?" ":
			(cnt == 32'd42)?"F":(cnt == 32'd43)?"R":(cnt == 32'd44)?"O":(cnt == 32'd45)?"M":
			(cnt == 32'd46)?" ":(cnt == 32'd47)?"B":(cnt == 32'd48)?"L":(cnt == 32'd49)?"U":
			(cnt == 32'd50)?"E":(cnt == 32'd51)?"S":(cnt == 32'd52)?"C":(cnt == 32'd53)?"S":
			(cnt == 32'd54)?"I":     // byte 55 = NUL (falls through); rest = 0
			8'h00;
	end
endfunction

// CDROM MODE SENSE(6). Header + 8-byte block descriptor (12 bytes): device-
// specific byte = 0x80 (write-protected), block length 0x000800 (2048),
// #blocks = capacity (2048-block last LBA, same byte slots as the disk
// response). Page 0x30 appends the 24-byte "magic Apple page" (0x30, 0x00,
// "APPLE COMPUTER, INC   ") — byte-exact from MAME apple_magic, which some
// Apple drivers/utilities probe even on CD drives. Other pages: header+desc
// only (proven pattern of the disk response).
function [7:0] cd_mode_sense_byte;
	input [31:0] cnt;
	begin
		cd_mode_sense_byte =
			(cnt == 32'd0 )?(cd_ms30 ? 8'd35 : 8'd11):  // mode data length = total-1
			(cnt == 32'd2 )?8'h80:                      // WP (read-only medium)
			(cnt == 32'd3 )?8'd8:                       // block descriptor length
			(cnt == 32'd5 )?capacity[23:16]:
			(cnt == 32'd6 )?capacity[15:8]:
			(cnt == 32'd7 )?capacity[7:0]:
			(cnt == 32'd10)?8'h08:                      // block length 0x000800 = 2048
			(cnt == 32'd12)?8'h30:                      // page code (0x30 request only)
			(cnt == 32'd14)?"A":(cnt == 32'd15)?"P":
			(cnt == 32'd16)?"P":(cnt == 32'd17)?"L":
			(cnt == 32'd18)?"E":(cnt == 32'd19)?" ":
			(cnt == 32'd20)?"C":(cnt == 32'd21)?"O":
			(cnt == 32'd22)?"M":(cnt == 32'd23)?"P":
			(cnt == 32'd24)?"U":(cnt == 32'd25)?"T":
			(cnt == 32'd26)?"E":(cnt == 32'd27)?"R":
			(cnt == 32'd28)?",":(cnt == 32'd29)?" ":
			(cnt == 32'd30)?"I":(cnt == 32'd31)?"N":
			(cnt == 32'd32)?"C":
			((cnt >= 32'd33) && (cnt <= 32'd35))?" ":
			8'h00;
	end
endfunction

// Page select: CDROM response, else 0x31 detection page vs. the default.
wire [7:0] mode_sense_dout       = (CDROM != 0)   ? (cd_ms31 ? mode_sense_p31_byte(data_cnt)       : cd_mode_sense_byte(data_cnt))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt)       : mode_sense_def_dout;
wire [7:0] mode_sense_dout_next  = (CDROM != 0)   ? (cd_ms31 ? mode_sense_p31_byte(data_cnt_next)  : cd_mode_sense_byte(data_cnt_next))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next)  : mode_sense_def_dout_next;
wire [7:0] mode_sense_dout_next2 = (CDROM != 0)   ? (cd_ms31 ? mode_sense_p31_byte(data_cnt_next2) : cd_mode_sense_byte(data_cnt_next2))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next2) : mode_sense_def_dout_next2;
wire [7:0] mode_sense_dout_next3 = (CDROM != 0)   ? (cd_ms31 ? mode_sense_p31_byte(data_cnt_next3) : cd_mode_sense_byte(data_cnt_next3))
                                 : mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next3) : mode_sense_def_dout_next3;

// Default MODE SENSE(6) response (unchanged; served for every page except 0x31).
wire [7:0] mode_sense_def_dout =
		(data_cnt == 32'd0 )?8'd11:
		(data_cnt == 32'd3 )?8'd8:
		(data_cnt == 32'd5 )?capacity[23:16]:
		(data_cnt == 32'd6 )?capacity[15:8]:
		(data_cnt == 32'd7 )?capacity[7:0]:
		(data_cnt == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next =
		(data_cnt_next == 32'd0 )?8'd11:
		(data_cnt_next == 32'd3 )?8'd8:
		(data_cnt_next == 32'd5 )?capacity[23:16]:
		(data_cnt_next == 32'd6 )?capacity[15:8]:
		(data_cnt_next == 32'd7 )?capacity[7:0]:
		(data_cnt_next == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next2 =
		(data_cnt_next2 == 32'd0 )?8'd11:
		(data_cnt_next2 == 32'd3 )?8'd8:
		(data_cnt_next2 == 32'd5 )?capacity[23:16]:
		(data_cnt_next2 == 32'd6 )?capacity[15:8]:
		(data_cnt_next2 == 32'd7 )?capacity[7:0]:
		(data_cnt_next2 == 32'd10 )?8'd2:
		8'h00;
wire [7:0] mode_sense_def_dout_next3 =
		(data_cnt_next3 == 32'd0 )?8'd11:
		(data_cnt_next3 == 32'd3 )?8'd8:
		(data_cnt_next3 == 32'd5 )?capacity[23:16]:
		(data_cnt_next3 == 32'd6 )?capacity[15:8]:
		(data_cnt_next3 == 32'd7 )?capacity[7:0]:
		(data_cnt_next3 == 32'd10 )?8'd2:
		8'h00;

// buffer to store incoming commands
reg [3:0]  cmd_cnt;
reg [7:0]  cmd [9:0];

// ========================================================================
// BlueSCSI Toolbox transport (TOOLBOX_ENABLE) — dedicated-slot HPS round-trip
// for the DataIn filesystem ops 0xD0 LIST / 0xD1 GET / 0xD2 COUNT.
// docs/BLUESCSI_CORE_HPS_CONTRACT.md. The disk read/write path is untouched.
//
//   load CDB into tb buffer -> tb_wr @LBA0 (HPS runs the handler) ->
//   tb_rd @LBA0 (status + 0xB5 signature + length) ->
//   tb_rd @LBA1 (one 512-byte data block) -> serve via PHASE_DATA_OUT.
//
// FIRST CUT (pending HW + Main co-test): the round-trip handshake, the buffer
// byte-lane order and the status-latch settle are modelled on the proven disk
// path but cannot be functionally validated until the Main handler exists; the
// SERVE reuses the disk buffer machinery verbatim so its timing is inherited.
// Single 512-byte response this stage; GET >512 (sequential fetch) and SEND
// upload (0xD3-D5, needs a 2nd buffer sector) are the remaining stages.
// ========================================================================
localparam TBS_IDLE=3'd0, TBS_LOAD=3'd1, TBS_REQ=3'd2, TBS_STAT=3'd3,
           TBS_LATCH=3'd4, TBS_DATA=3'd5, TBS_RDY=3'd6;
reg [2:0]  tb_state = TBS_IDLE;
reg        tb_rd_r, tb_wr_r;
reg [31:0] tb_lba_r;
reg [7:0]  tb_status;
reg [15:0] tb_len;
reg [3:0]  tb_load_w;
reg [3:0]  tb_settle;   // status-latch settle for the registered port-B (q_b) reads
                        // of the status block (word 0 = status/sig, word 1 = length).
reg [17:0] tb_to;       // tb read-completion watchdog (~8-17 ms); see TBS_STAT.
reg        old_tb_ack;
reg [3:0]  tb_fetch_sec;    // which 512B sector the HPS fill is landing (multi-block LIST; TB_ADDRW>8)

// Shared-folder availability: latches when the HPS mounts the Toolbox slot.
// Until then (incl. a stock Main with no handler) fs ops return CHECK (§4a).
reg tb_ready = 1'b0;
always @(posedge clk) if ((TOOLBOX_ENABLE || CDCHANGER_ENABLE) && tb_mounted) tb_ready <= 1'b1;

// Toolbox buffer: one 512-byte sector, byte-split (even->buf0, odd->buf1) with
// the SAME HPS lane mapping as the disk buffer so bytes arrive in order.
wire [7:0] tb_buf0_qa, tb_buf1_qa;     // HPS read-back (the CDB, during request)
`ifdef VERILATOR
wire [7:0] tb_buf0_da = sd_buff_dout[15:8];
wire [7:0] tb_buf1_da = sd_buff_dout[7:0];
assign tb_buff_din = {tb_buf0_qa, tb_buf1_qa};
`else
wire [7:0] tb_buf0_da = sd_buff_dout[7:0];
wire [7:0] tb_buf1_da = sd_buff_dout[15:8];
assign tb_buff_din = {tb_buf1_qa, tb_buf0_qa};
`endif

wire       tb_hps_wr  = sd_buff_wr & tb_ack;            // HPS fills the slot
// SEND (upload) payload collection: during the DataOut phase the Mac's bytes are
// written into the toolbox buffer at WORD offset 8 (byte 16), leaving words 0..4
// (bytes 0..9) for the CDB that TBS_LOAD writes -- so one round-trip block carries
// both (the contract's "payload at buffer[16..]" single-block layout). Even byte
// -> buf0, odd -> buf1, mirroring the CDB/serve byte split.
wire       tb_collect = (phase == PHASE_DATA_IN) && cmd_tb_send;
wire       tb_col_wr0 = tb_collect && stb_ack && ~data_cnt[0];
wire       tb_col_wr1 = tb_collect && stb_ack &&  data_cnt[0];
// tb buffer word address, computed at 11b (max = 8 sectors) then sliced to
// TB_ADDRW. On single-sector targets (TB_ADDRW=8) the high bits are always 0
// (tb_fetch_sec=0, data_cnt<512), so the slice reproduces the old data_cnt[8:1].
wire [10:0] tb_b_addr11 = (tb_state == TBS_LOAD)   ? {7'd0, tb_load_w}
                        : tb_collect               ? (11'd8 + {3'd0, data_cnt[8:1]})
                        :                             data_cnt[11:1];
wire [TB_ADDRW-1:0] tb_b_addr = tb_b_addr11[TB_ADDRW-1:0];
// HPS fill address: sector tb_fetch_sec at word offset tb_fetch_sec*256, so a
// multi-sector LIST lands contiguously (LBA 1+k -> words k*256..k*256+255).
wire [10:0] tb_hps_addr11 = {tb_fetch_sec[2:0], sd_buff_addr[7:0]};
wire [TB_ADDRW-1:0] tb_hps_addr = tb_hps_addr11[TB_ADDRW-1:0];
wire       tb_b_wr0   = (tb_state == TBS_LOAD) || tb_col_wr0;
wire       tb_b_wr1   = (tb_state == TBS_LOAD) || tb_col_wr1;
wire [7:0] tb_load_b0 = cmd[{tb_load_w[2:0], 1'b0}];   // even CDB byte
wire [7:0] tb_load_b1 = cmd[{tb_load_w[2:0], 1'b1}];   // odd  CDB byte
wire [7:0] tb_b_d0    = (tb_state == TBS_LOAD) ? tb_load_b0 : din;   // CDB even byte, else payload byte
wire [7:0] tb_b_d1    = (tb_state == TBS_LOAD) ? tb_load_b1 : din;   // CDB odd  byte, else payload byte

wire [7:0] tb0_dout, tb0_dout_next, tb0_dout_next2;
wire [7:0] tb1_dout, tb1_dout_next, tb1_dout_next2;
scsi_dpram #(.ADDRWIDTH(TB_ADDRW)) tb_buf0 (
	.clock(clk),
	.address_a(tb_hps_addr), .data_a(tb_buf0_da), .wren_a(tb_hps_wr), .q_a(tb_buf0_qa),
	.address_b(tb_b_addr), .data_b(tb_b_d0), .wren_b(tb_b_wr0), .q_b(tb0_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb0_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb0_dout_next2)
);
scsi_dpram #(.ADDRWIDTH(TB_ADDRW)) tb_buf1 (
	.clock(clk),
	.address_a(tb_hps_addr), .data_a(tb_buf1_da), .wren_a(tb_hps_wr), .q_a(tb_buf1_qa),
	.address_b(tb_b_addr), .data_b(tb_b_d1), .wren_b(tb_b_wr1), .q_b(tb1_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb1_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb1_dout_next2)
);

// Serve sources (mirror the disk read: even byte from buf0, odd from buf1).
wire  [7:0] tb_serve           = data_cnt[0] ? tb1_dout : tb0_dout;
wire [15:0] tb_serve_pair      = data_cnt[0] ? {tb1_dout, tb0_dout_next} : {tb0_dout, tb1_dout};
wire [15:0] tb_serve_pair_next = data_cnt[0] ? {tb1_dout_next, tb0_dout_next2} : {tb0_dout_next, tb1_dout_next};

// Multi-sector LIST fetch (TB_ADDRW>8): the HPS returns tb_len bytes across
// ceil(tb_len/512) sectors (LBA 1..N). TB_MAXSEC bounds it to the buffer; with
// TB_ADDRW=8 => TB_MAXSEC=1 => single-block (file Toolbox behaviour preserved).
localparam [3:0] TB_MAXSEC = 1 << (TB_ADDRW - 8);
wire [6:0] tb_nsec_raw = tb_len[15:9] + {6'd0, |tb_len[8:0]};  // ceil(tb_len/512)
wire [3:0] tb_nsec = (tb_nsec_raw == 7'd0)         ? 4'd1
                   : (tb_nsec_raw > {3'd0,TB_MAXSEC}) ? TB_MAXSEC
                   :                                  tb_nsec_raw[3:0];

// Round-trip FSM. Drives tb_state / tb_rd / tb_wr / tb_lba; the MAIN phase FSM
// moves `phase` (CMD_IN -> PHASE_TB -> DATA_OUT/STATUS_OUT) by watching tb_state.
always @(posedge clk) begin
	old_tb_ack <= tb_ack;
	if (rst) begin
		tb_state <= TBS_IDLE; tb_rd_r <= 1'b0; tb_wr_r <= 1'b0; tb_lba_r <= 32'd0;
		tb_status <= 8'h02; tb_len <= 16'd0; tb_load_w <= 4'd0; tb_settle <= 4'd0; tb_to <= 18'd0;
		tb_fetch_sec <= 4'd0;
	end else if (TOOLBOX_ENABLE || CDCHANGER_ENABLE) begin
		case (tb_state)
		TBS_IDLE: begin
			tb_load_w <= 4'd0;
			tb_fetch_sec <= 4'd0;   // sector-0 addressing for the next LOAD/REQ/STAT
			if (phase == PHASE_TB) tb_state <= TBS_LOAD;
		end
		// write the 10-byte CDB as 5 words (0..4) into the tb buffer
		TBS_LOAD:
			if (tb_load_w == 4'd4) begin
				tb_wr_r <= 1'b1; tb_lba_r <= 32'd0; tb_state <= TBS_REQ;
			end else tb_load_w <= tb_load_w + 1'b1;
		// request: HPS reads the CDB and runs the handler
		TBS_REQ: begin
			if (tb_ack) tb_wr_r <= 1'b0;
			if (old_tb_ack & ~tb_ack) begin
				tb_rd_r <= 1'b1; tb_lba_r <= 32'd0; tb_to <= 18'd0; tb_state <= TBS_STAT;
			end
		end
		// status: HPS returns {status, 0xB5, len_hi, len_lo} at buffer words 0/1.
		// Proceed on the read-completion ack-fall OR a watchdog timeout: on HW the
		// tb READ ack is not observed by the core (the write ack is, with identical
		// code; and the file-Toolbox transport this rides on was never HW-validated).
		// The HPS has already filled the buffer by the timeout, so force-latch the
		// status block. Same watchdog on TBS_DATA. (2026-07-21)
		TBS_STAT: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if ((old_tb_ack & ~tb_ack) || (&tb_to)) begin tb_settle <= 4'd8; tb_state <= TBS_LATCH; end
		end
		// buffer reads for addr 0/1 are registered; let them settle after the
		// force-latch, then read the status block: word 0 = {status, 0xB5 sig},
		// word 1 = {len_hi, len_lo}. Signature present -> adopt status+length and
		// (if length>0) fetch the data sector(s); absent -> no handler, CHECK.
		TBS_LATCH:
			if (tb_settle != 4'd0) tb_settle <= tb_settle - 1'b1;
			else if (tb1_dout == 8'hb5) begin            // signature ok (byte 1)
				tb_status <= tb0_dout;                       // byte 0 = SCSI status
				tb_len    <= {tb0_dout_next, tb1_dout_next}; // bytes 2,3 = length
				if ({tb0_dout_next, tb1_dout_next} != 16'd0) begin
					tb_rd_r <= 1'b1; tb_lba_r <= 32'd1; tb_fetch_sec <= 4'd0; tb_to <= 18'd0; tb_state <= TBS_DATA;
				end else tb_state <= TBS_RDY;                // status-only
			end else begin                               // no real handler -> CHECK
				tb_status <= 8'h02; tb_len <= 16'd0; tb_state <= TBS_RDY;
			end
		// data: HPS returns tb_len bytes across ceil(tb_len/512) sectors, one per
		// LBA (1..N). Each lands at buffer offset tb_fetch_sec*256; fetch the next
		// until all N are in, then serve linearly. Same read-ack watchdog as TBS_STAT.
		TBS_DATA: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			tb_to <= tb_to + 1'b1;
			if ((old_tb_ack & ~tb_ack) || (&tb_to)) begin
				if ((tb_fetch_sec + 4'd1) >= tb_nsec) tb_state <= TBS_RDY;
				else begin
					tb_fetch_sec <= tb_fetch_sec + 4'd1;
					tb_lba_r     <= tb_lba_r + 32'd1;
					tb_rd_r      <= 1'b1;
					tb_to        <= 18'd0;
				end
			end
		end
		// round-trip done; the main FSM consumes tb_status/tb_len and leaves
		TBS_RDY: if (phase != PHASE_TB) tb_state <= TBS_IDLE;
		default: tb_state <= TBS_IDLE;
		endcase
	end
end

/* ----------------------- request data from/to io controller ----------------------- */

// CD-audio/TOC fetches own the address bus while their request is live
assign io_lba = ca_io_active ? ca_io_lba : lba;

// READ prefetch (ring): keep issuing sequential sector fetches while sectors
// remain (rd_hps_blk < tlen) and the ring has space (fetched no more than
// RING_BLOCKS ahead of the Mac). This is a LEVEL signal — the fetch engine below
// pumps one sector per io_ack until the ring is full, hiding per-sector HPS
// latency (vs. the old 1-deep "fetch next at byte 20" which stalled the CPU at
// every 512-byte boundary). rd_hps_blk >= rd_cur_blk is invariant (the Mac
// stalls via io_busy before it can pass the fetch frontier), so the subtraction
// never underflows.
wire [22:0] rd_blk_total  = {7'd0, tlen};
wire        rd_blk_remain = (rd_hps_blk < rd_blk_total);
wire        rd_ring_space = ((rd_hps_blk - rd_cur_blk) < RING_BLOCKS);
wire req_rd = (phase == PHASE_DATA_OUT) && cmd_read && (data_len != 32'd0) &&
              !data_complete && rd_blk_remain && rd_ring_space;

// generate an io_wr signal whenever a 512 byte block has been received or when the status
// phase of a write command has been reached.
// data_len != 0 guard: a zero-length WRITE reaches STATUS_OUT without any
// data phase; without the guard the STATUS_OUT clause would flush a stale
// sector-buffer block (the previous READ's data) to the command's LBA.
wire req_wr = ((((phase == PHASE_DATA_IN) && (data_cnt[8:0] == 0) && (data_cnt != 0)) || (phase == PHASE_STATUS_OUT)) && cmd_write && (data_len != 32'd0));

// Data-path io_rd (the ring engine's own request). The module output is the
// OR with the CD-audio engine's request; the engine only runs while the
// target is bus-idle with no data io pending (ca_grant below), so the two
// requestors never overlap — and a pending req_rd naturally waits for the
// audio block in flight via the !io_rd guard on the shared wire.
reg io_rd_d;
assign io_rd = io_rd_d | ca_io_rd_w;

always @(posedge clk) begin
	reg old_wr;
	reg rd_busy;            // a read-prefetch sector fetch is outstanding

	// A SCSI bus reset aborts any in-flight/queued disk IO.  Without this,
	// io_rd/io_wr (and the pending latches) survive the reset; if the Mac
	// re-selects before the stale io_rd clears via io_ack, the next CMD_IN
	// phase sees io_busy=1 (phase!=DATA && io_rd) which suppresses REQ, the
	// command never transfers, the Mac times out and resets again -> the
	// intermittent reset/re-scan loop observed on hardware.
	if(rst) begin
		io_rd_d <= 1'b0;
		io_wr <= 1'b0;
		wr_pending <= 0;
		old_wr <= 0;
		rd_busy <= 0;
	end else begin
		old_wr <= req_wr;
		if(~old_wr & req_wr) wr_pending <= 1;

		// READ prefetch engine: while req_rd (sectors remain AND ring has
		// space), issue back-to-back sector fetches — one per io_ack — to keep
		// the ring filled ahead of the Mac. rd_busy holds across a fetch until
		// rd_hps_blk advances on the io_ack falling edge, so exactly one fetch
		// is issued per sector and the next can start immediately after.
		// (io_rd in the guard is the shared wire: a CD-audio block in flight
		// defers the ring's next fetch by one HPS block, nothing more.)
		if(io_ack) io_rd_d <= 1'b0;
		else if(req_rd && !io_rd && !rd_busy) begin io_rd_d <= 1'b1; rd_busy <= 1'b1; end
		if(old_io_ack & ~io_ack) rd_busy <= 1'b0;

		// WRITE flush engine — unchanged two-slot double-buffer behavior.
		if(io_ack) io_wr <= 1'b0;
		else if(wr_pending && !io_wr) begin io_wr <= 1'b1; wr_pending <= 0; end
	end
end

// =====================================================================
// CD audio engine (CDROM targets only; every ca_* wire folds to a constant
// on disks). Owns the AppleCD playback state machine, the real TOC, and
// the audio-frame streaming from the HPS windows. It may use the io
// channel only while the target is bus-idle with no data io pending.
// =====================================================================
// CA grant: the audio/TOC engine's fetches are HPS-channel-only (they never
// touch the SCSI bus), so they may interleave with an ACTIVE READ command's
// serving phase — requiring full bus-idle starved the frame stream to ~42
// of the required 75 frames/s whenever the guest streamed game data from
// the same disc (HW capture 2026-07-18: pstate=PLAY, fetch delta 17/400ms,
// audible crackle = sample-hold at every late frame). The io-free terms
// still serialize the channel per-op, and the ~ca_io_active scoping keeps
// CA acks out of the data-path accounting (that isolation was built for
// exactly this concurrency). DATA_IN (writes) stays excluded: the CD is
// read-only, so it never occurs; all other phases remain excluded.
wire ca_grant = (phase == PHASE_IDLE || (cmd_read && phase == PHASE_DATA_OUT))
                && !io_rd_d && !io_wr && !io_ack && mounted;

generate if (CDROM != 0) begin : g_cd_audio
	cd_audio #(.CLK_HZ(32'd32_500_000)) cd_audio_i (   // clk_sys rate; audio pitch verifies it
		.clk(clk), .rst(sys_rst), .bus_rst(rst),
		.mounted(mounted), .img_mounted(img_mounted), .img_blocks(img_blocks),
		.cmd_stb(ca_cmd_stb), .cmd_op(cmd[0]),
		.cdb1(cmd[1]), .cdb2(cmd[2]), .cdb3(cmd[3]), .cdb4(cmd[4]),
		.cdb5(cmd[5]), .cdb6(cmd[6]), .cdb7(cmd[7]), .cdb8(cmd[8]), .cdb9(cmd[9]),
		.read_stb(ca_read_stb), .eject_stb(ca_eject_stb),
		.ch_grant(ca_grant),
		.ca_io_active(ca_io_active), .ca_io_rd(ca_io_rd_w), .ca_io_lba(ca_io_lba),
		.io_ack(io_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_addr_hi(sd_buff_addr_hi),
		.sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
		.ast_code(ca_ast_code), .cur_ctrl(ca_cur_ctrl), .cur_trk(ca_cur_trk),
		.abs_m(ca_abs_m), .abs_s(ca_abs_s), .abs_f(ca_abs_f),
		.rel_m(ca_rel_m), .rel_s(ca_rel_s), .rel_f(ca_rel_f),
		.toc_base(ca_toc_addr),
		.toc_q0(ca_toc_q0), .toc_q1(ca_toc_q1), .toc_q2(ca_toc_q2), .toc_q3(ca_toc_q3),
		.toc_ready(ca_toc_ready),
		.toc43_base(ca_t43_addr),
		.toc43_q0(ca_t43_q0), .toc43_q1(ca_t43_q1),
		.toc43_q2(ca_t43_q2), .toc43_q3(ca_t43_q3),
		.toc43_len(ca_t43_len),
		.toc2_base(ca_t2_addr),
		.toc2_q0(ca_t2_q0), .toc2_q1(ca_t2_q1),
		.toc2_q2(ca_t2_q2), .toc2_q3(ca_t2_q3),
		.toc2_len(ca_t2_len),
		.disc_audio(ca_disc_audio),
		.snd_l(cd_snd_l), .snd_r(cd_snd_r),
		.dbg_cda0(dbg_cda0),
		.dbg_cdur(dbg_cdur)
	);
end else begin : g_no_cd_audio
	assign ca_io_active = 1'b0;
	assign ca_io_rd_w   = 1'b0;
	assign ca_io_lba    = 32'd0;
	assign ca_ast_code  = 8'h05;
	assign ca_cur_ctrl  = 8'h14;
	assign ca_cur_trk   = 8'h01;
	assign ca_abs_m = 8'h00; assign ca_abs_s = 8'h00; assign ca_abs_f = 8'h00;
	assign ca_rel_m = 8'h00; assign ca_rel_s = 8'h00; assign ca_rel_f = 8'h00;
	assign ca_toc_q0 = 8'h00; assign ca_toc_q1 = 8'h00;
	assign ca_toc_q2 = 8'h00; assign ca_toc_q3 = 8'h00;
	assign ca_t43_q0 = 8'h00; assign ca_t43_q1 = 8'h00;
	assign ca_t43_q2 = 8'h00; assign ca_t43_q3 = 8'h00;
	assign ca_t43_len = 10'd0;
	assign ca_t2_q0 = 8'h00; assign ca_t2_q1 = 8'h00;
	assign ca_t2_q2 = 8'h00; assign ca_t2_q3 = 8'h00;
	assign ca_t2_len = 10'd0;
	assign ca_disc_audio = 1'b0;
	assign ca_toc_ready = 1'b0;
	assign cd_snd_l = 16'sd0;
	assign cd_snd_r = 16'sd0;
	assign dbg_cda0 = 32'd0;
	assign dbg_cdur = 32'd0;
end endgenerate

reg  stb_ack;
reg  stb_adv;
always @(posedge clk) begin
	reg old_ack;
	
	old_ack <= ack;
	stb_ack <= (~old_ack & ack); // on rising edge
	stb_adv <= (old_ack & ~ack); // on falling edge
end

reg buffer0_wr, buffer1_wr;

// store data on rising edge of ack, ...
always @(posedge clk) begin
	buffer0_wr <= 0;
	buffer1_wr <= 0;
	if(stb_ack) begin
		if(phase == PHASE_CMD_IN)  cmd[cmd_cnt] <= din;
		if(phase == PHASE_DATA_IN) begin
			buffer0_wr <= ~data_cnt[0];
			buffer1_wr <=  data_cnt[0];
		end
	end
end

// ... advance counter on falling edge
always @(posedge clk) begin
	if(phase == PHASE_IDLE) cmd_cnt <= 4'd0;
	else if(stb_adv && (phase == PHASE_CMD_IN) && (cmd_cnt != 15)) cmd_cnt <= cmd_cnt + 4'd1;
end

// count data bytes. don't increase counter while we are waiting for data from
// the io controller
reg [31:0] data_cnt;
reg        data_complete;

// For block transfers tlen contains the number of 512 bytes blocks to transfer.
// Most other commands have the bytes length stored in the transfer length field.
// And some have a fixed length idependent from any header field.
// The data transfer has finished once the data counter reaches this
// number.
//
// Allocation-length clamping (2026-06-10, SCSI corruption root cause):
// tlen6's 0->256 mapping is the READ/WRITE(6) block-count convention and does
// NOT apply to allocation lengths — for INQUIRY alloc 0 means "no data", for
// REQUEST SENSE it means 4 bytes (pre-SCSI-2 convention). Undo it here.
wire [31:0] alloc_len = (tlen == 16'd256) ? 32'd0 : {16'd0, tlen};
wire [31:0] sense_len = (tlen == 16'd256) ? 32'd4 : {16'd0, tlen};
// CDROM response sizes. INQUIRY = 54 (5 + additional-length 0x31). Apple READ
// TOC (0xC1): ops 00/01 return a fixed 4 bytes; op 10 (track range) returns
// floor(alloc/4) four-byte descriptors = alloc & ~3 (MAME: num_trks = size/4).
// tlen here is the RAW 10-byte-CDB allocation ({cmd[7],cmd[8]}) — only READs
// are <<2-scaled at latch time.
localparam [31:0] INQUIRY_LEN = (CDROM != 0) ? 32'd54 : 32'd36;
wire        cd_ms30    = (CDROM != 0) && cmd_mode_sense && (cmd[2][5:0] == 6'h30);
// CD-changer detection: serve the BlueSCSI Toolbox page-0x31 magic on the CD
// target so a Toolbox client (MacAtrium) recognizes it as a CD changer (its probe
// = MODE SENSE page 0x31 magic + INQUIRY CD-ROM). UNGATED (CDCHANGER_ENABLE, not
// tb_ready): detection works standalone before the HPS handler lands; MacAtrium
// tolerates the follow-up LIST/SET CHECK gracefully. Only the explicit page-0x31
// request is affected — the AppleCD driver's page 0x30 / default MODE SENSE is
// untouched. docs/BLUESCSI_CD_CHANGER_CONTRACT.md
wire        cd_ms31    = CDCHANGER_ENABLE && cmd_mode_sense && (cmd[2][5:0] == 6'h31);
// ops 00/01: MAME serves a fixed 4; clamp to the allocation as well so a
// short alloc can never leave unserved bytes holding REQ (the 2026-06-10
// alloc-overserve wedge class). Identical to MAME for the observed alloc=4.
wire [31:0] cd_toc_len = (cmd[9][7:6] == 2'b10) ? {16'd0, tlen[15:2], 2'b00}
                       : (tlen < 16'd4)         ? {16'd0, tlen}
                       :                          32'd4;
// A real target returns min(allocation length, actual response size) and then
// switches to STATUS; the initiator detects the early phase change via the
// BSR phase-mismatch bit. Serving the raw allocation length (previous
// behavior) DEADLOCKS the bus whenever the initiator transfers fewer bytes
// than it asked for: the target holds REQ with leftover bytes while the Mac
// polls BSR for a phase change that never comes (the 2026-06-10 Welcome
// hang). Actual sizes: INQUIRY = 5 + additional-length(31) = 36 bytes — the
// STANDARD response size (matches real drives and Snow; serving 37 left one
// unread byte for drivers that read the standard 36 -> 2026-06-10c wedge);
// MODE SENSE(6) = 12 bytes (4 header + 8 block descriptor, header says 11);
// REQUEST SENSE = 8 + additional-length(0x0a) = 18 bytes.
wire [31:0] data_len =
		 cmd_read_capacity?32'd8:
		 cmd_read?{ 7'd0, tlen, 9'd0 }:   // read command length is in 512 bytes blocks
		 cmd_write?{ 7'd0, tlen, 9'd0 }:  // write command length is in 512 bytes blocks
		 cmd_cd_toc?cd_toc_len:           // Apple READ TOC (see cd_toc_len)
		 // 0x43/0x42 serve EXACTLY the allocation length (zero-filled past the
		 // real payload; header length fields still carry the true size). The
		 // under-serve direction deadlocks too (2026-07-19, deterministic at
		 // boot): the Mac's blind-transfer primitive arms the FULL allocation
		 // and pumps DACK for it; a target that goes early-STATUS after
		 // min(alloc,actual) leaves the host armed with no DREQ ever coming —
		 // 250 ms BERR beats, SCSI Mgr retry, boot wedge ("host-armed/
		 // target-idle"). Discovered via the 0x43 start-track filter: it was
		 // the first command whose actual size (20 B for the {start=22,
		 // alloc=48} duration ask) dropped BELOW the allocation. Caps: 512 =
		 // T43 plane, 64 > the 16-byte 0x42 payload (its serve function
		 // zero-fills past byte 15 by construction).
		 cmd_cd_toc43?(({16'd0, cmd[7], cmd[8]} < 32'd512) ?
		               {16'd0, cmd[7], cmd[8]} : 32'd512):   // all formats: f0/f2 tables + f1 page
		 cmd_cd_subq43?(({16'd0, cmd[7], cmd[8]} < 32'd64) ?
		                {16'd0, cmd[7], cmd[8]} : 32'd64):
		 cmd_cd_subq?32'd9:               // READ Q SUBCODE: fixed 9 bytes
		 cmd_cd_astat?32'd6:              // AUDIO STATUS: fixed 6 bytes
		 cmd_cd_actl?{24'd0, cmd[8]}:     // AUDIO CONTROL: DataOut of CDB[8] bytes (discarded)
		 cmd_inquiry?((alloc_len < INQUIRY_LEN) ? alloc_len : INQUIRY_LEN):
		 cmd_mode_sense?((CDROM != 0) ? (cd_ms31 ? ((alloc_len < 32'd56) ? alloc_len : 32'd56)
		                               : cd_ms30 ? ((alloc_len < 32'd36) ? alloc_len : 32'd36)
		                                         : ((alloc_len < 32'd12) ? alloc_len : 32'd12))
		                              : (mode_sense_p31 ? ((alloc_len < 32'd56) ? alloc_len : 32'd56)
		                                                : ((alloc_len < 32'd12) ? alloc_len : 32'd12))):
		 ((CDROM != 0) && cmd_mode_select)?alloc_len:  // MODE SELECT alloc 0 = no data (not 256)
		 cmd_request_sense?((sense_len < 32'd18) ? sense_len : 32'd18):
		 cmd_tb_devinfo?tb_devinfo_len:                       // 0xD9 DEVICE INFO
		 cmd_tb_debug_get?32'd1:                              // 0xD6 get = one flag byte
		 (cmd_tb_fs_in || cmd_cdc_in)?{16'd0, tb_len}:        // 0xD0/D1/D2 fs + 0xD7/DA CD-changer DataIn (HPS length)
		 cmd_tb_send_prep?32'd33:                             // 0xD3 SEND PREP: 33-byte filename
		 cmd_tb_send_data?(cmd[6] ? {15'd0, cmd[6], 9'd0}     // 0xD4 SEND DATA: CDB[6]*512 (block enc),
		                          : {16'd0, cmd[1], cmd[2]}): //   else legacy u16(CDB[1..2]) byte count
		 { 16'd0, tlen };                 // mode select etc have length in bytes

always @(posedge clk) begin
	if((phase != PHASE_DATA_OUT) && (phase != PHASE_DATA_IN) && (phase != PHASE_STATUS_OUT) && (phase != PHASE_MESSAGE_OUT)) begin
		data_cnt <= 0;
		data_complete <= 0;
	end else begin	
		if(stb_adv)begin	
			if(!data_complete) data_cnt <= data_cnt + 1'd1;
			data_complete <= (data_len - 1'd1) == data_cnt;
		end
	end
end

`ifdef SIMULATION
// No-progress watchdog: in a data phase, if data_cnt has not advanced for a
// long time, dump the FULL handshake state — independent of REQ level — so a
// deadlock where REQ is held LOW (io_busy / data_phase_complete)
// is visible, not just a REQ-high host stall.  Also logs every phase change.
reg [31:0] stall_cnt;
reg [31:0] data_cnt_seen;
reg  [2:0] phase_d;
always @(posedge clk) begin
	phase_d <= phase;
	if (phase != phase_d && $test$plusargs("scsi_stall_debug"))
		$display("SCSI_PHASE ID=%0d %0d->%0d data_cnt=%0d data_len=%0d complete=%0d cmd=%02h tlen=%0d lba=%0d",
		         ID, phase_d, phase, data_cnt, data_len, data_complete, cmd[0], tlen, lba);
	if (phase == PHASE_DATA_OUT || phase == PHASE_DATA_IN) begin
		if (data_cnt != data_cnt_seen) begin
			data_cnt_seen <= data_cnt;
			stall_cnt <= 0;
		end else begin
			stall_cnt <= stall_cnt + 1'd1;
			if (stall_cnt == 32'd300000 && $test$plusargs("scsi_stall_debug"))
				$display("SCSI_STALL ID=%0d phase=%0d data_cnt=%0d/%0d cmpl=%b req=%b ack=%b io_busy=%b io_rd=%b io_ack=%b sel=%b dc9=%b sd_sel=%b dpc=%b cmd=%02h tlen=%0d lba=%0d",
				         ID, phase, data_cnt, data_len, data_complete, req, ack, io_busy, io_rd, io_ack,
				         sel, data_cnt[9], sd_buff_sel, data_phase_complete, cmd[0], tlen, lba);
		end
	end else begin
		stall_cnt <= 0;
		data_cnt_seen <= 0;
	end
end

// Write-path byte-slip instrumentation (2026-06-10 forensics: a 6-sector
// WRITE landed on disk with ONE foreign byte inserted at payload offset 1
// and the rest of the command's data shifted +1, last byte dropped — see
// docs/scsi_byteslip_2026-06-10.md). Hooks:
//   * SCSI_WR_OVERRUN: an ACK beat in a write data phase after
//     data_complete — the host still has bytes after we counted data_len,
//     i.e. a phantom byte was consumed earlier in the phase.
//   * +scsi_wr_trace: per-beat log of every stored byte for offline diff
//     against the expected payload (find WHERE the foreign byte enters).
always @(posedge clk) begin
	if (stb_ack && (phase == PHASE_DATA_IN) && data_complete)
		$display("SCSI_WR_OVERRUN ID=%0d data_cnt=%0d data_len=%0d din=%02x lba=%0d cmd=%02h",
		         ID, data_cnt, data_len, din, lba, cmd[0]);
	if (stb_ack && (phase == PHASE_DATA_IN) && $test$plusargs("scsi_wr_trace"))
		$display("SCSI_WR_BEAT ID=%0d cnt=%0d din=%02x lba=%0d", ID, data_cnt, din, lba);
end

// Stuck-flush watchdog: io_wr pending while the bus is idle means the
// final-block flush ack raced the BSY drop (io_ack is masked by
// target_bsy upstream in ncr5380) — recovery then relies on the Mac's
// timeout + bus reset (the documented reset/re-scan loop). Candidate
// mechanism for the forensically-observed LOST write commands.
reg [31:0] idle_flush_cnt;
always @(posedge clk) begin
	if (io_wr && (phase == PHASE_IDLE)) begin
		idle_flush_cnt <= idle_flush_cnt + 1'd1;
		if (idle_flush_cnt == 32'd100000)
			$display("SCSI_FLUSH_STUCK ID=%0d io_wr pending while bus idle (io_ack masked by !bsy?) lba=%0d",
			         ID, lba);
	end else
		idle_flush_cnt <= 0;
end
`endif

// check whether status byte has been sent
reg status_sent;
always @(posedge clk) begin
	if(phase != PHASE_STATUS_OUT) status_sent <= 0;
	else if(stb_adv) status_sent <= 1;
end

// check whether message byte has been sent
reg message_sent;
always @(posedge clk) begin
	if(phase != PHASE_MESSAGE_OUT) message_sent <= 0;
	else if(stb_adv) message_sent <= 1;
end

/* ----------------------- command decoding ------------------------------- */


// parse commands
wire [7:0] op_code = cmd[0];
wire [2:0] cmd_group = op_code[7:5];

// check if a complete command has been received
wire       cmd_cpl = cmd6_cpl || cmd10_cpl;
wire       cmd6_cpl = (cmd_group == 3'b000) && (cmd_cnt == 6);
// BlueSCSI Toolbox vendor commands (0xD0-0xDA, group 110) are 10-byte CDBs.
// Decode ONLY this exact range as 10-byte (not the whole vendor group 110) so
// other group-110 opcodes aren't mis-lengthed (0xC0 EJECT is a 6-byte CDB).
// 0xDA (CD-changer COUNT CDS) extends the file Toolbox's 0xD0-0xD9 range.
// docs/BLUESCSI_MISTER_MAIN_PLAN.md, docs/BLUESCSI_HANDOFF.md §1,
// docs/BLUESCSI_CD_CHANGER_CONTRACT.md §2.
wire       cmd_toolbox_op = (op_code >= 8'hd0) && (op_code <= 8'hda);
// Apple CD vendor commands 0xC0-0xCE are ALL 10-byte CDBs (MAME
// nscsi_cdrom_apple_device::scsi_command_done: command&0xf0==0xc0 -> 10).
wire       cmd_apple_cd_op = (CDROM != 0) && (op_code[7:4] == 4'hc);
wire       cmd10_cpl = (((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10))
                       || (cmd_toolbox_op && (cmd_cnt == 10))
                       || (cmd_apple_cd_op && (cmd_cnt == 10));

// https://en.wikipedia.org/wiki/SCSI_command
wire       cmd_read = cmd_read6 || cmd_read10;
wire       cmd_read6 = (op_code == 8'h08);
wire       cmd_read10 = (op_code == 8'h28);
wire       cmd_write = cmd_write6 || cmd_write10;
wire       cmd_write6 = (op_code == 8'h0a);
wire       cmd_write10 = (op_code == 8'h2a);
wire       cmd_inquiry = (op_code == 8'h12);
wire       cmd_format = (op_code == 8'h04);
wire       cmd_mode_select = (op_code == 8'h15);
wire       cmd_mode_sense = (op_code == 8'h1a);
wire       cmd_test_unit_ready = (op_code == 8'h00);
wire       cmd_read_capacity = (op_code == 8'h25);
wire       cmd_read_buffer = (op_code == 8'h3b);  // fake
wire       cmd_write_buffer = (op_code == 8'h3c); // fake
wire       cmd_verify6 = (op_code == 8'h13); // fake
wire       cmd_verify10 = (op_code == 8'h2f); // fake
// REQUEST SENSE (0x03) is MANDATORY: after any CHECK CONDITION the initiator
// issues it to recover the sense data.  The target previously rejected it
// (cmd_ok=0 -> CHECK CONDITION), so on hardware -- where a transient error
// triggers the recovery path -- the Mac could never clear the condition and
// wedged.  Support it and return a clean "NO SENSE" block.
wire       cmd_request_sense = (op_code == 8'h03);

// ----- Apple CD-ROM command set (CDROM targets only; all fold to 0 on disks).
// Oracle: MAME nscsi_cdrom_apple_device (docs/plan_scsi_cdrom.md Appendix A).
wire       cmd_cd_eject     = (CDROM != 0) && (op_code == 8'hc0);  // EJECT DISC
wire       cmd_cd_toc       = (CDROM != 0) && (op_code == 8'hc1);  // READ TOC (BCD/MSF)
wire       cmd_cd_subq      = (CDROM != 0) && (op_code == 8'hc2);  // READ Q SUBCODE (9 B)
wire       cmd_cd_astat     = (CDROM != 0) && (op_code == 8'hcc);  // AUDIO STATUS (6 B)
wire       cmd_cd_actl      = (CDROM != 0) && (op_code == 8'hce);  // AUDIO CONTROL (DataOut cmd[8] B, discarded)
// Audio transport commands: v1 = data CDs only, accept as no-op GOOD (deferred
// per plan §5.1; they only matter for CD-DA which has no PCM path yet).
wire       cmd_cd_audio_nop = (CDROM != 0) && ((op_code == 8'hc8) || (op_code == 8'hc9) ||
                                               (op_code == 8'hca) || (op_code == 8'hcb) ||
                                               (op_code == 8'hcd) ||
                                               // standard set (dialect switch):
                                               (op_code == 8'h47) || (op_code == 8'h48) ||
                                               (op_code == 8'h4b) || (op_code == 8'h4e) ||
                                               // 0x01 REZERO = the AppleCD player's
                                               // STOP button ("nonstandard stop audio
                                               // playback", BlueSCSI) — rejecting it
                                               // raised the error dialog with music
                                               // still playing (sense 5/0x20 latched,
                                               // 2026-07-20). SEEK(6)/(10) carry the
                                               // same Annex-C stop-audio semantics.
                                               (op_code == 8'h01) ||
                                               (op_code == 8'h0b) || (op_code == 8'h2b));
wire       cmd_cd_toc43  = (CDROM != 0) && (op_code == 8'h43);  // standard READ TOC (any format)
// old-style format select in the CONTROL byte (cmd[9][7:6]) — the AppleCD
// driver's actual dialect on the 8004 identity (2026-07-19 capture: 0x80).
// Oracles: BlueSCSI apple-quirks (0x80=full TOC, 0x40=session info) + Snow.
// Unknown format 2'b11 falls back to format 0 (benign, never observed).
wire       cmd_cd_t43f2  = cmd_cd_toc43 && (cmd[9][7:6] == 2'b10);  // FULL TOC (format 2)
wire       cmd_cd_t43f1  = cmd_cd_toc43 && (cmd[9][7:6] == 2'b01);  // SESSION INFO (format 1)
wire       cmd_cd_t43f0  = cmd_cd_toc43 && !cmd_cd_t43f2 && !cmd_cd_t43f1;
wire       cmd_cd_subq43 = (CDROM != 0) && (op_code == 8'h42);  // standard READ SUB-CHANNEL
wire       cmd_cd_prevent   = (CDROM != 0) && (op_code == 8'h1e);  // PREVENT/ALLOW MEDIUM REMOVAL
wire       cmd_cd_startstop = (CDROM != 0) && (op_code == 8'h1b);  // START/STOP UNIT

// ----- BlueSCSI Toolbox vendor commands (0xD0-0xD9) ----------------------
// M0 = the RTL-serviceable subset that needs NO host filesystem, so the Mac
// "BlueSCSI SD Transfer" client can DETECT the device:
//   * 0xD9 DEVICE INFO  - static device-list / capabilities (like INQUIRY)
//   * 0xD6 TOGGLE DEBUG - a stored flag (get/set), no side effects
// Detection (MODE SENSE page 0x31 + 0xD9/0xD6) AND the filesystem opcodes
// (0xD0/D1/D2) are ALL gated on tb_ready, so the target advertises Toolbox
// capability only when the HPS handler is present and the slot is mounted. On a
// stock Main (no handler) tb_ready=0: every Toolbox response degrades to a plain
// disk, so the Mac client never engages. (The earlier "detection works
// standalone, fs ops degrade to empty folder" plan hung the client on app-close
// -- the page-0x31 advert is what makes it engage, so it must be gated too.)
// docs/BLUESCSI_MISTER_MAIN_PLAN.md
wire       cmd_tb_devinfo   = TOOLBOX_ENABLE && tb_ready && (op_code == 8'hd9);      // DEVICE INFO
wire       cmd_tb_fs_in     = TOOLBOX_ENABLE && (op_code == 8'hd0 || op_code == 8'hd1 || op_code == 8'hd2); // LIST/GET/COUNT (HPS round-trip, DataIn)
// SEND/upload (Mac -> host), DataOut. FIRST CUT = single-block: the CDB and the
// payload ride one round-trip block (CDB at [0..9], payload at [16..]), so a
// chunk is capped at 512-16 = 496 B (fine for the small co-test files; >496 B
// chunks / CAP_LARGE_SEND are future multi-block work). 0xD5 has no data phase.
wire       cmd_tb_send_prep = TOOLBOX_ENABLE && (op_code == 8'hd3);   // SEND FILE PREP (33-B name)
wire       cmd_tb_send_data = TOOLBOX_ENABLE && (op_code == 8'hd4);   // SEND FILE DATA (chunk)
wire       cmd_tb_send_end  = TOOLBOX_ENABLE && (op_code == 8'hd5);   // SEND FILE END (no payload)
wire       cmd_tb_send      = cmd_tb_send_prep || cmd_tb_send_data || cmd_tb_send_end;
wire       cmd_tb_send_pay  = cmd_tb_send_prep || cmd_tb_send_data;   // has a DataOut payload
wire       cmd_tb_debug     = TOOLBOX_ENABLE && tb_ready && (op_code == 8'hd6);      // TOGGLE DEBUG
wire       cmd_tb_debug_get = cmd_tb_debug && (cmd[1] != 8'd0);    // CDB[1]!=0 -> read flag
wire       tb_devinfo_caps  = cmd_tb_devinfo && (cmd[1] == 8'h01); // subcmd 1 = capabilities
// 0xD9 allocation length is CDB[8] (0 -> 8 bytes; otherwise min(CDB[8],8)).
wire [31:0] tb_devinfo_alloc = (cmd[8] == 8'd0) ? 32'd8 : {24'd0, cmd[8]};
wire [31:0] tb_devinfo_len   = (tb_devinfo_alloc < 32'd8) ? tb_devinfo_alloc : 32'd8;

// DEVICE INFO data (docs/BLUESCSI_HANDOFF.md §4.8): subcmd 0x00 LIST DEVICES ->
// 8 bytes; this target's own ID = 0x00 (fixed disk present), every other ID =
// 0xFF (absent). subcmd 0x01 GET CAPABILITIES -> API version 0 + cap flags; M0
// has no host transfer path so advertise 0x00 (force v0 paths) -> all zero.
// Bump caps when the HPS round trip lands (M2/M3).
wire [7:0] tb_devinfo_dout       = tb_devinfo_caps ? 8'h00 : (data_cnt       == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next  = tb_devinfo_caps ? 8'h00 : (data_cnt_next  == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next2 = tb_devinfo_caps ? 8'h00 : (data_cnt_next2 == {29'd0, ID}) ? 8'h00 : 8'hff;
wire [7:0] tb_devinfo_dout_next3 = tb_devinfo_caps ? 8'h00 : (data_cnt_next3 == {29'd0, ID}) ? 8'h00 : 8'hff;

// TOGGLE DEBUG (0xD6): a stored flag with no side effects, so the client's
// get/set round-trips succeed. get (CDB[1]!=0) returns the flag byte.
reg        tb_debug_flag;
wire [7:0] tb_debug_dout       = (data_cnt       == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next  = (data_cnt_next  == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next2 = (data_cnt_next2 == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;
wire [7:0] tb_debug_dout_next3 = (data_cnt_next3 == 32'd0) ? {7'd0, tb_debug_flag} : 8'h00;

// set (CDB[1]==0): latch CDB[2]!=0 at command completion. Single-driver always
// block (Quartus-clean); the flag is observable only via the 0xD6 get path.
always @(posedge clk) begin
	if (rst) tb_debug_flag <= 1'b0;
	else if (cmd_cpl && (phase == PHASE_CMD_IN) && cmd_tb_debug && (cmd[1] == 8'd0))
		tb_debug_flag <= (cmd[2] != 8'd0);
end

// ----- BlueSCSI Toolbox CD Changer (CDCHANGER_ENABLE; CD target / ID 3) ------
// 0xD7 LIST CDS + 0xDA COUNT CDS are DataIn HPS round-trips (serve the staged
// list/count exactly like the file-Toolbox 0xD0/D1/D2). 0xD8 SET NEXT CD is a
// status-only round-trip: the HPS remaps the CD image slot (VD_CDROM), whose
// img_mounted pulse drives the SAME media-change the OSD swap uses -- no extra
// RTL here. All gated on tb_ready so a stock Main (no CD-folder handler mounted
// on the changer slot) leaves them CHECK. docs/BLUESCSI_CD_CHANGER_CONTRACT.md
wire       cmd_cdc_list  = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hd7);
wire       cmd_cdc_count = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hda);
wire       cmd_cdc_set   = CDCHANGER_ENABLE && tb_ready && (op_code == 8'hd8);
wire       cmd_cdc_in    = cmd_cdc_list || cmd_cdc_count; // DataIn: serve HPS list/count
wire       cmd_cdc_tb    = cmd_cdc_in   || cmd_cdc_set;    // any changer op -> HPS round-trip

// valid command in buffer? TODO: check for valid command parameters
wire  cmd_ok_hd = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug ||
		  (cmd_tb_fs_in && tb_ready) ||  // fs DataIn ops valid only with a shared folder (else CHECK)
		  (cmd_tb_send  && tb_ready);    // fs DataOut (upload) ops, likewise

// CD-ROM command set: read-only — WRITE/FORMAT/buffer/verify are NOT accepted
// (CHECK CONDITION + ILLEGAL REQUEST), matching a real AppleCD drive.
wire  cmd_ok_cd = cmd_read || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_mode_sense ||
		  cmd_request_sense || cmd_cd_eject || cmd_cd_toc || cmd_cd_subq ||
		  cmd_cd_astat || cmd_cd_actl || cmd_cd_audio_nop ||
		  cmd_cd_toc43 || cmd_cd_subq43 ||
		  cmd_cd_prevent || cmd_cd_startstop || cmd_cdc_tb;

wire  cmd_ok = (CDROM != 0) ? cmd_ok_cd : cmd_ok_hd;

// Media-dependent commands fail with the AppleCD no-disc sense while no image
// is mounted (MAME return_no_cd: SK_NOT_READY + vendor ASC 0xB0 — 0x3A makes
// MacOS "hammer the drive asking the user to format it", cd.cpp:1214).
wire  cd_needs_media = cmd_test_unit_ready || cmd_read || cmd_read_capacity ||
		  cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_actl ||
		  cmd_cd_toc43 || cmd_cd_subq43 ||
		  cmd_cd_audio_nop;
wire  cd_no_media = (CDROM != 0) && !mounted && cd_needs_media;

// Data READs against a disc with no data track (pure audio CD) must CHECK
// with ILLEGAL REQUEST + ASC 0x64 "illegal mode for this track" — real
// AppleCD behavior (BlueSCSI/Snow). The Audio CD Access extension RELIES on
// this failure to classify the disc; serving audio bytes as data sends the
// Finder through garbage (2026-07-20 system error 10 at desktop mount).
wire  cd_audio_read_rej = (CDROM != 0) && mounted && cmd_read && ca_disc_audio;

// New-command strobe (one clk on the CDB completing). Used by the CD sense /
// eject logic; folds away on disk targets.
reg   cd_cpl_d = 1'b0;
always @(posedge clk) cd_cpl_d <= (phase == PHASE_CMD_IN) && cmd_cpl;
wire  cd_new_cmd = (phase == PHASE_CMD_IN) && cmd_cpl && !cd_cpl_d;
// BOTH eject forms, one wire: Apple vendor EJECT (0xC0) AND the standard SCSI
// START/STOP UNIT (0x1B) with LoEj=1/Start=0. The System 7.1 AppleCD driver
// ejects via the 0x1B form (HW watch 2026-07-27: Finder Put Away returned GOOD
// but `mounted` never dropped, so the driver's no-media insertion poll saw
// READY and silently REMOUNTED the volume ~10 s later — the guest could never
// empty the drive, which is also why a BlueSCSI-changer disc-to-disc swap was
// invisible: no media-change edge ever existed). The audio engine already
// treated 0x1B-LoEj as an eject (ca_eject_stb below); the MEDIA state must too.
wire  cmd_cd_eject_any = cmd_cd_eject ||
                         (cmd_cd_startstop && cmd[4][1] && !cmd[4][0]);
wire  cd_eject_pulse = cd_new_cmd && cmd_cd_eject_any && !cd_prevent;

// REQUEST SENSE state (CDROM only): key/ASC latched when a command CHECKs,
// cleared by the next successful non-REQUEST-SENSE command (SCSI-1 semantics).
reg [3:0] cd_sense_key = 4'd0;
reg [7:0] cd_sense_asc = 8'd0;
// JTAG CDA1 probe regs: every dispatched command latches its opcode; the
// accept/reject flag tells whether cmd_ok took it (a rejected PLAY is the
// interesting datum). Driven from the main phase FSM block only.
reg [7:0] dbg_last_op = 8'd0;
// CDA2: the exact 0xC1 READ TOC request the guest last issued —
// {cdb9 (operation bits), cdb5 (start track BCD), cdb7:cdb8 (allocation)}.
// The served bytes are fully determined by these + the resp plane, so this
// pins down the "player shows 2 tracks" divergence (2026-07-18).
reg [31:0] dbg_toc_cdb = 32'd0;
// CDA3/CDA4: full CDB of the last PLAY-CLASS command (0x47/48/4B/4E and the
// vendor C8..CD set) — the 0x42 position-poll flood (4/s during playback)
// overwrites dbg_last_op within 250 ms, so the skip-failure ask (2026-07-20:
// skip during playback lands the engine idle, player shows track 0) is
// unrecoverable from CDA1 alone. {op,cdb3,cdb4,cdb5} + {cdb1,cdb6,cdb7,cdb8}
// reconstruct every play form (MSF, TRACK/INDEX, pause/resume flag).
reg [31:0] dbg_play_cdb  = 32'd0;
reg [31:0] dbg_play_cdb2 = 32'd0;
wire cmd_play_class = (op_code == 8'h47) || (op_code == 8'h48) ||
                      (op_code == 8'h4b) || (op_code == 8'h4e) ||
                      (op_code == 8'hc8) || (op_code == 8'hc9) ||
                      (op_code == 8'hca) || (op_code == 8'hcb) ||
                      (op_code == 8'hcd) ||
                      (op_code == 8'h01) ||
                      (op_code == 8'h0b) || (op_code == 8'h2b);
reg [7:0] dbg_cmd_cnt = 8'd0;
reg       dbg_last_ok = 1'b0;
assign dbg_cda2 = dbg_toc_cdb;
assign dbg_cda3 = dbg_play_cdb;
assign dbg_cda4 = dbg_play_cdb2;
assign dbg_cda1 = { ca_toc_ready, cd_no_media, mounted, dbg_last_ok,
                    cd_sense_asc, cd_sense_key, dbg_cmd_cnt, dbg_last_op };
reg       cd_prevent   = 1'b0;
always @(posedge clk) begin
	if (rst) begin
		cd_sense_key <= 4'd0;
		cd_sense_asc <= 8'd0;
		cd_prevent   <= 1'b0;
	end else if ((CDROM != 0) && cd_new_cmd) begin
		if (cmd_play_class) begin
			dbg_play_cdb  <= {op_code, cmd[3], cmd[4], cmd[5]};
			dbg_play_cdb2 <= {cmd[1], cmd[6], cmd[7], cmd[8]};
		end
		if (!cmd_ok) begin
			cd_sense_key <= 4'h5;  // ILLEGAL REQUEST
			cd_sense_asc <= 8'h20; // invalid operation code
		end else if (cd_no_media) begin
			cd_sense_key <= 4'h2;  // NOT READY
			cd_sense_asc <= 8'hb0; // AppleCD vendor "no disc"
		end else if (cd_audio_read_rej) begin
			cd_sense_key <= 4'h5;  // ILLEGAL REQUEST
			cd_sense_asc <= 8'h64; // illegal mode for this track
		end else if (cmd_cd_eject_any) begin
			if (cd_prevent) begin
				cd_sense_key <= 4'h5; // ILLEGAL REQUEST
				cd_sense_asc <= 8'h80; // "prevent bit is set" (MAME)
			end else begin
				cd_sense_key <= 4'h2;  // NOT READY
				cd_sense_asc <= 8'h3a; // medium not present (post-eject, MAME)
			end
		end else if (cmd_cd_prevent) begin
			cd_prevent   <= cmd[4][0];
			cd_sense_key <= 4'd0;
			cd_sense_asc <= 8'd0;
		end else if (!cmd_request_sense) begin
			cd_sense_key <= 4'd0;
			cd_sense_asc <= 8'd0;
		end
	end
end

// latch parameters once command is complete
reg [31:0] lba;
reg [15:0] tlen;

always @(posedge clk) begin
	if (old_io_ack & ~io_ack) lba <= lba + 1'd1;
	if(cmd_cpl && (phase == PHASE_CMD_IN)) begin
		// CDROM READs address 2048-byte logical blocks; the HPS block device
		// is 512-byte sectors, so scale lba/tlen by 4 AT LATCH TIME and the
		// whole downstream ring/flush/data_len machinery runs unmodified in
		// 512-byte units. Non-READ commands keep raw CDB values (their
		// lengths are byte counts, e.g. MODE SELECT / AUDIO CONTROL).
		if ((CDROM != 0) && cmd_read) begin
			lba  <= (cmd6_cpl?{11'd0, lba6}:lba10) << 2;
			tlen <= (cmd6_cpl?{7'd0, tlen6}:tlen10) << 2;
		end else begin
			lba <= cmd6_cpl?{11'd0, lba6}:lba10;
			tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
		end
	end
end
   
// logical block address
wire [7:0] cmd1 = cmd[1];
wire [20:0] lba6 = { cmd1[4:0], cmd[2], cmd[3] };
wire [31:0] lba10 = { cmd[2], cmd[3], cmd[4], cmd[5] };

// transfer length
wire [8:0]  tlen6 = (cmd[4] == 0)?9'd256:{1'b0,cmd[4]};
wire [15:0] tlen10 = { cmd[7], cmd[8] };


// the 5380 changes phase in the falling edge, thus we monitor it
// on the rising edge
//
always @(posedge clk) begin
	if(rst) begin
		phase <= PHASE_IDLE;
		ca_cmd_stb <= 1'b0; ca_read_stb <= 1'b0; ca_eject_stb <= 1'b0;
	end else begin
		// CD-audio engine strobes: 1-clk pulses on command acceptance below
		ca_cmd_stb <= 1'b0; ca_read_stb <= 1'b0; ca_eject_stb <= 1'b0;
		if(phase == PHASE_IDLE) begin
			// Own id on bus during selection? Real SCSI selection requires a
			// FREE bus (SEL asserted, BSY false): while another device holds
			// BSY its dout is wired-ORed onto the data bus, so a stray bit in
			// that byte could otherwise "select" this target mid-dialog and
			// two targets would then consume the shared ACK stream in
			// parallel (command/LBA corruption -> misdirected writes).
			// A CD-ROM drive is present on the bus even with no disc inserted
			// (the AppleCD driver polls TEST UNIT READY to detect insertion),
			// so the CDROM target selects on cd_enable instead of mounted.
			if(sel && din[ID] && ((CDROM != 0) ? cd_enable : mounted) && !bus_busy)
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			// check if a full command is in the buffer
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				// is this a supported and valid command?
				// (CDROM: media-dependent commands CHECK with the no-disc
				// sense while unmounted; a prevent-blocked EJECT CHECKs too.)
				if(cmd_ok && !cd_no_media && !cd_audio_read_rej) begin
					// yes, continue
					status <= (cmd_cd_eject_any && cd_prevent) ? `STATUS_CHECK_CONDITION : `STATUS_OK;

					// notify the CD-audio engine (all constant 0 on disks)
					ca_cmd_stb   <= cmd_cd_audio_nop;
					dbg_last_op <= op_code;
					// latch ONLY op-0x80 (per-track descriptor) asks: the player's
					// launch-time track walk is the datum; the periodic op00/op40
					// refresh was overwriting it before we could read (2026-07-19).
					if (cmd_cd_toc43) dbg_toc_cdb <= {cmd[9], cmd[6], cmd[7], cmd[8]};
					dbg_cmd_cnt <= dbg_cmd_cnt + 8'd1;
					dbg_last_ok <= 1'b1;
					ca_read_stb  <= cmd_read && (CDROM != 0);
					ca_eject_stb <= cmd_cd_eject_any && !cd_prevent;

					// continue according to command

					// these commands return data
					if(cmd_tb_fs_in || cmd_cdc_tb) phase <= PHASE_TB;   // toolbox fs DataIn OR CD-changer (list/count DataIn + set status-only): HPS round-trip
						else if(cmd_tb_send_end) phase <= PHASE_TB;       // SEND END: no payload, straight to round-trip
						else if(cmd_tb_send_pay) phase <= PHASE_DATA_IN;  // SEND PREP/DATA: collect the DataOut payload first
						else if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug_get || cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_toc43 || cmd_cd_subq43) phase <= PHASE_DATA_OUT;
					// these commands receive dataa
					else if(cmd_write || cmd_mode_select || cmd_write_buffer || cmd_cd_actl) phase <= PHASE_DATA_IN;
					// and all other valid commands are just "ok"
					else phase <= PHASE_STATUS_OUT;
				end else begin
					// no, report failure
					dbg_last_op <= op_code;
					dbg_cmd_cnt <= dbg_cmd_cnt + 8'd1;
					dbg_last_ok <= 1'b0;
					status <= `STATUS_CHECK_CONDITION;
					phase <= PHASE_STATUS_OUT;
				end
			end
		end

		else if(phase == PHASE_TB) begin
			// round-trip done: adopt the HPS status, then serve DataIn or finish.
			if(tb_state == TBS_RDY) begin
				status <= tb_status;
				phase  <= (tb_len != 16'd0) ? PHASE_DATA_OUT : PHASE_STATUS_OUT;
			end
		end

		else if(phase == PHASE_DATA_OUT) begin
			if(data_done) phase <= PHASE_STATUS_OUT;
		end

		else if(phase == PHASE_DATA_IN) begin
			// SEND (upload): once the DataOut payload has landed in the toolbox
			// buffer, run the HPS round-trip (write CDB+payload, read status).
			// Disk writes still go straight to STATUS.
			if(data_done) phase <= cmd_tb_send ? PHASE_TB : PHASE_STATUS_OUT;
		end

		else if(phase == PHASE_STATUS_OUT) begin
			if(status_sent) phase <= PHASE_MESSAGE_OUT;
		end

		else if(phase == PHASE_MESSAGE_OUT) begin
			if(message_sent) phase <= PHASE_IDLE;
		end
		
		else
			phase <= PHASE_IDLE;  // should never happen
	end
end

// ----------------------------------------------------------------------
// JTAG debug: REQ/ACK handshake observations (sticky since reset).
//   [7:4] max command bytes received (cmd_cnt high-water)
//   [3]   cmd_cpl seen (a full command was assembled)
//   [2]   Mac ACKed a command byte  (stb_adv in CMD_IN)
//   [1]   target asserted REQ in STATUS_OUT
//   [0]   Mac ACKed the status byte (stb_adv in STATUS_OUT)
// ----------------------------------------------------------------------
reg [3:0] dbg_max_cmd_cnt;
reg       dbg_cmd_cpl, dbg_ack_in_cmd, dbg_req_in_status, dbg_ack_in_status;
always @(posedge clk) begin
	if(rst) begin
		dbg_max_cmd_cnt   <= 4'd0;
		dbg_cmd_cpl       <= 1'b0;
		dbg_ack_in_cmd    <= 1'b0;
		dbg_req_in_status <= 1'b0;
		dbg_ack_in_status <= 1'b0;
	end else begin
		if((phase == PHASE_CMD_IN) && (cmd_cnt > dbg_max_cmd_cnt)) dbg_max_cmd_cnt <= cmd_cnt;
		if((phase == PHASE_CMD_IN) && cmd_cpl)  dbg_cmd_cpl       <= 1'b1;
		if((phase == PHASE_CMD_IN) && stb_adv)  dbg_ack_in_cmd    <= 1'b1;
		if((phase == PHASE_STATUS_OUT) && req)  dbg_req_in_status <= 1'b1;
		if((phase == PHASE_STATUS_OUT) && stb_adv) dbg_ack_in_status <= 1'b1;
	end
end
assign dbg_hs = { dbg_max_cmd_cnt, dbg_cmd_cpl, dbg_ack_in_cmd,
                  dbg_req_in_status, dbg_ack_in_status };

// Completion-phase flags that DELIBERATELY survive a SCSI bus reset (no rst
// clause), so they accumulate the truth across the Mac's reset/retry cycles:
//   [3] status byte was ACKed (status_sent fired) in STATUS_OUT
//   [2] target ever reached MSG_OUT
//   [1] Mac re-asserted SEL while we were in STATUS_OUT (mid-command select)
//   [0] Mac ever ACKed a MESSAGE byte (stb_adv in MSG_OUT)
reg dbg_status_sent_ever, dbg_reached_msg_ever, dbg_sel_in_status_ever, dbg_ack_in_msg_ever;
always @(posedge clk) begin
	if((phase == PHASE_STATUS_OUT) && stb_adv) dbg_status_sent_ever  <= 1'b1;
	if(phase == PHASE_MESSAGE_OUT)             dbg_reached_msg_ever   <= 1'b1;
	if((phase == PHASE_STATUS_OUT) && sel)     dbg_sel_in_status_ever <= 1'b1;
	if((phase == PHASE_MESSAGE_OUT) && stb_adv) dbg_ack_in_msg_ever   <= 1'b1;
end
assign dbg_hs2 = { dbg_status_sent_ever, dbg_reached_msg_ever,
                   dbg_sel_in_status_ever, dbg_ack_in_msg_ever };

// Sticky bitmap of which command types the initiator issued to this target.
// Survives bus reset so it shows everything the Mac tried across retries.
//   [7]=READ [6]=WRITE [5]=INQUIRY [4]=TEST_UNIT_READY
//   [3]=READ_CAPACITY [2]=MODE_SENSE [1]=unsupported(cmd_ok=0) [0]=REQUEST_SENSE
// Repurposed: capture the LAST opcode the initiator sent to this target
// (any command, not just unsupported -- unsupported was always 0x00).
// Survives bus reset so it shows the most recent command the Mac issued
// before it gave up and re-scanned, revealing the boot-logic reject point.
reg [7:0] dbg_unsup_op;
reg       cmd_cpl_d2;
always @(posedge clk) begin
	cmd_cpl_d2 <= (phase == PHASE_CMD_IN) && cmd_cpl;
	if((phase == PHASE_CMD_IN) && cmd_cpl && !cmd_cpl_d2)
		dbg_unsup_op <= op_code;
end
assign dbg_cmd = dbg_unsup_op;

// JTAG debug: capture byte0 and byte1 of the FIRST word write exactly as the
// target latches them (din at buffer0[0] / buffer1[0]), plus the ncr5380's
// intended odd byte and word/longword flags at that moment. Sticky.
//   If dbg_b1 == dbg_b0 (and != dbg_low_l) the low byte never reached the
//   target (the serialization drops it); dbg_word_l shows whether the
//   word-write path was even engaged.
reg [7:0] dbg_b0, dbg_b1;
reg       dbg_b0_seen, dbg_b1_seen;
reg [7:0] dbg_low_l;
reg       dbg_word_l, dbg_long_l;
// Trigger on the first MULTI-BLOCK write (tlen >= 2) so the captured bytes
// carry the bench's full non-zero pattern (e.g. 1KB test: byte0=2, byte1=3).
// The 1B/512B tests (tlen==1) and the tiny JSONL result writes are skipped —
// their first word is all-zero/stale and can't distinguish the bug.
wire dbg_capture_ok = (phase == PHASE_DATA_IN) && (|tlen[15:1]);
always @(posedge clk) begin
	if (buffer0_wr && dbg_capture_ok && (data_cnt[9:1] == 9'd0) && !dbg_b0_seen) begin
		dbg_b0      <= din;
		dbg_low_l   <= dbg_dma_lowbyte;
		dbg_word_l  <= dbg_dma_word;
		dbg_long_l  <= dbg_dma_long;
		dbg_b0_seen <= 1'b1;
	end
	if (buffer1_wr && dbg_capture_ok && (data_cnt[9:1] == 9'd0) && !dbg_b1_seen) begin
		dbg_b1      <= din;
		dbg_b1_seen <= 1'b1;
	end
end
assign dbg_wrsnap = { 4'd0, dbg_b1_seen, dbg_b0_seen, dbg_long_l, dbg_word_l,
                      dbg_low_l, dbg_b1, dbg_b0 };

// ---- Bus-reset snapshot (PSCW probe, repurposed for selection/reset forensics) ----
// The read-abort probe returned valid=0 — reads do NOT die mid-transfer; the wedge
// and the bus resets cluster in the selection/scan path. So capture, at the FIRST
// SCSI bus reset (rst = the Mac asserting ICR.RST), HOW FAR the transaction that
// triggered it actually got: the high-water phase this window (IDLE => target never
// left IDLE = selection never succeeded; CMD_IN => command failed; DATA/STATUS/MSG
// => transaction progressed), whether a cmd_read COMPLETED, whether SEL was ever
// asserted, and the last full command opcode. win_* accumulate per window (since the
// previous reset) and snapshot into the sticky brst_* at the reset edge. brst_*
// survive rst (initial only). Phase encoding is monotonic with progress (IDLE0 <
// CMD_IN1 < DATA2/3 < STATUS4 < MSG5), so the numeric max IS the furthest phase.
reg  [2:0] win_maxphase;   // high-water phase since the last bus reset
reg        win_read_done;  // a cmd_read DATA_OUT reached data_complete this window
reg  [7:0] win_lastop;     // last full command opcode assembled
reg        win_sel_seen;   // SEL asserted this window
reg        brst_rst_d;
reg        brst_valid;
reg  [2:0] brst_maxphase;
reg        brst_read_done;
reg        brst_sel_seen;
reg  [6:0] brst_count;
reg  [7:0] brst_lastop;
initial begin
	win_maxphase = 0; win_read_done = 0; win_lastop = 0; win_sel_seen = 0;
	brst_rst_d = 0; brst_valid = 0; brst_maxphase = 0; brst_read_done = 0;
	brst_sel_seen = 0; brst_count = 0; brst_lastop = 0;
end
always @(posedge clk) begin
	brst_rst_d <= rst;
	// per-window accumulation
	if (phase > win_maxphase)                                   win_maxphase  <= phase;
	if (cmd_read && (phase == PHASE_DATA_OUT) && data_complete) win_read_done <= 1'b1;
	if (cmd_cpl && (phase == PHASE_CMD_IN))                     win_lastop    <= cmd[0];
	if (sel)                                                    win_sel_seen  <= 1'b1;
	// bus-reset rising edge: snapshot this window, then clear for the next
	if (rst && !brst_rst_d) begin
		if (brst_count != 7'h7F) brst_count <= brst_count + 7'd1;
		if (!brst_valid) begin
			brst_valid     <= 1'b1;
			brst_maxphase  <= win_maxphase;
			brst_read_done <= win_read_done;
			brst_sel_seen  <= win_sel_seen;
			brst_lastop    <= win_lastop;
		end
		win_maxphase  <= 3'd0;
		win_read_done <= 1'b0;
		win_sel_seen  <= 1'b0;
	end
end
//  PSCW layout: [31]=valid [30:28]=brst_maxphase [27]=read_done [26]=sel_seen
//               [25:19]=reset_count(7) [18:11]=last_opcode(8)
//               [10:8]=live win_maxphase [7]=live win_read_done [6:0]=0
assign dbg_wrstall = { brst_valid, brst_maxphase, brst_read_done, brst_sel_seen,
                       brst_count, brst_lastop, win_maxphase, win_read_done, 7'd0 };

// ---- WRFB: write-data-phase first-beat forensics (2026-07-28) -------------
// For the one-inserted-byte-per-64KB-unit corruption hunt: if a WRITE
// command's first data beat ever arrives with data_cnt[0]=1, or the
// byte/word pseudo-DMA mode flips mid-phase, the odd_byte_r lane pairing
// slips one byte for the rest of the command — exactly the observed
// signature. Latched per DATA_IN phase of a block-write command; read live
// while an install runs and correlate against the corrupt 64 KB spans.
//   [31:24]=write-phase serial (wraps)  [23:16]=mode flips this phase (sat)
//   [15:8]=first beat's din  [7:2]=CUMULATIVE count of write phases whose
//   FIRST word-mode beat arrived at odd data_cnt (sat 63 — the direct
//   slip-trigger counter; with the beat-role fix in, nonzero here plus a
//   clean extract diff = trigger occurred AND was handled)
//   [1]=first-beat dbg_dma_word
//   [0]=first-beat data_cnt[0] (law: 0; 1 = the smoking gun)
reg  [7:0] wrfb_cmds  = 8'd0;
reg  [7:0] wrfb_flips = 8'd0;
reg  [7:0] wrfb_byte0 = 8'd0;
reg  [5:0] wrfb_oddw  = 6'd0;
reg        wrfb_par0  = 1'b0;
reg        wrfb_word0 = 1'b0;
reg        wrfb_armed = 1'b0;
reg        wrfb_wmseen= 1'b0;
reg        wrfb_dma_d = 1'b0;
always @(posedge clk) begin
	wrfb_dma_d <= dbg_dma_word;
	if (phase != PHASE_DATA_IN || !cmd_write) begin
		wrfb_armed  <= 1'b1;
		wrfb_wmseen <= 1'b0;
	end else begin
		if (stb_ack && wrfb_armed) begin
			wrfb_armed <= 1'b0;
			wrfb_cmds  <= wrfb_cmds + 8'd1;
			wrfb_byte0 <= din;
			wrfb_par0  <= data_cnt[0];
			wrfb_word0 <= dbg_dma_word;
			wrfb_flips <= 8'd0;
		end
		else if (!wrfb_armed && (dbg_dma_word != wrfb_dma_d) && (wrfb_flips != 8'hFF))
			wrfb_flips <= wrfb_flips + 8'd1;
		// first word-mode beat of this write phase: odd parity = the slip trigger
		if (stb_ack && dbg_dma_word && !wrfb_wmseen) begin
			wrfb_wmseen <= 1'b1;
			if (data_cnt[0] && wrfb_oddw != 6'h3F)
				wrfb_oddw <= wrfb_oddw + 6'd1;
		end
	end
end
assign dbg_wrfb = { wrfb_cmds, wrfb_flips, wrfb_byte0, wrfb_oddw, wrfb_word0, wrfb_par0 };

// ---- Selection/command handshake observability (PSEL probe) -----------
// Live state {phase,sel,bsy,req,ack} plus sticky high-water/counters that
// SURVIVE bus reset (no rst clause) so they accumulate across the
// reset/reselect retry loop. Key indicators for the REQ-vs-SEL fix:
//   reached_data : did a transfer ever get past CMD_IN to a DATA phase?
//   req_while_sel: REQ rising edges observed while SEL was still asserted
//                  (was impossible with the old !sel gate; nonzero => fix live)
//   cmd_bytes    : command bytes ACKed in CMD_IN (does the command advance?)
//   max_phase    : highest target phase reached.
reg [2:0] dbg_max_phase;
reg       dbg_reached_data;
reg [7:0] dbg_req_while_sel;
reg [7:0] dbg_cmd_bytes;
reg       dbg_req_d;
initial begin
	dbg_max_phase = 0; dbg_reached_data = 0; dbg_req_while_sel = 0;
	dbg_cmd_bytes = 0; dbg_req_d = 0;
end
always @(posedge clk) begin
	dbg_req_d <= req;
	if (phase > dbg_max_phase) dbg_max_phase <= phase;
	if (phase == PHASE_DATA_OUT || phase == PHASE_DATA_IN) dbg_reached_data <= 1'b1;
	if (req && sel && !dbg_req_d && dbg_req_while_sel != 8'hFF)
		dbg_req_while_sel <= dbg_req_while_sel + 8'd1;
	if (phase == PHASE_CMD_IN && stb_adv && dbg_cmd_bytes != 8'hFF)
		dbg_cmd_bytes <= dbg_cmd_bytes + 8'd1;
end
assign dbg_selsnap = { 5'd0, dbg_cmd_bytes, dbg_req_while_sel, dbg_reached_data,
                       ack, req, bsy, sel, dbg_max_phase, phase };

endmodule

module scsi_empty_cd
(
	input      clk,
	input      rst,
	input      sel,
	input      bus_busy, // another device currently holds the bus (its BSY)
	input      ack,
	output     bsy,
	output     msg,
	output     cd,
	output     io,
	output     req,
	output     req_bus,  // bus-visible REQ (no HPS backing here: identical to req)
	input  [7:0] din,
	output [7:0] dout,
	output [15:0] dout_pair,
	output [15:0] dout_pair_next,
	output [2:0] dbg_phase   // JTAG debug: live phase (this target had ZERO
	                         // visibility while it wedged the 2026-06-10 hang)
);

parameter [2:0] ID = 3;

localparam PHASE_IDLE        = 3'd0;
localparam PHASE_CMD_IN      = 3'd1;
localparam PHASE_DATA_OUT    = 3'd2;
localparam PHASE_STATUS_OUT  = 3'd4;
localparam PHASE_MESSAGE_OUT = 3'd5;

localparam STATUS_OK              = 8'h00;
localparam STATUS_CHECK_CONDITION = 8'h02;
localparam MSG_CMD_COMPLETE       = 8'h00;

reg [2:0]  phase;
reg [3:0]  cmd_cnt;
reg [7:0]  cmd [9:0];
reg [31:0] data_cnt;
reg [7:0]  status;
reg        status_sent;
reg        message_sent;
reg        data_complete;

assign msg = (phase == PHASE_MESSAGE_OUT);
assign cd = (phase == PHASE_CMD_IN) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
assign io = (phase == PHASE_DATA_OUT) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
	// data_len == 0 (e.g. INQUIRY alloc 0): complete the data phase without
	// waiting for an ACK that will never come (see scsi.v data_done).
	wire data_done = data_complete || (data_len == 32'd0);
	wire data_phase_complete = (phase == PHASE_DATA_OUT) && data_done;
	assign req = (phase != PHASE_IDLE) && !ack && !data_phase_complete;
	assign req_bus = req;   // no HPS backing: visible REQ == flow REQ
assign bsy = (phase != PHASE_IDLE);
assign dbg_phase = phase;

wire [7:0] op_code = cmd[0];
wire [2:0] cmd_group = op_code[7:5];
wire       cmd6_cpl = (cmd_group == 3'b000) && (cmd_cnt == 6);
wire       cmd10_cpl = ((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10);
wire       cmd_cpl = cmd6_cpl || cmd10_cpl;
wire       cmd_inquiry = (op_code == 8'h12);
wire       cmd_request_sense = (op_code == 8'h03);
// Allocation length from the CDB. The 0->256 mapping used previously is the
// READ/WRITE(6) block-count convention and does NOT apply here: for INQUIRY
// alloc 0 means "no data", for REQUEST SENSE it means 4 bytes (pre-SCSI-2).
//
// A real device returns min(allocation length, actual response size) and then
// switches to STATUS. Serving the raw allocation length (previous behavior)
// DEADLOCKED the bus when the Mac transferred fewer bytes than it asked for:
// this target held REQ with leftover bytes forever while the Mac polled BSR
// waiting for the end-of-data phase change — the 2026-06-10 "Welcome to
// Macintosh" hang (System 6 boot-time SCSI mount scan selecting ID3).
// Actual sizes: INQUIRY = 5 + additional-length(0x31) = 54 bytes;
// REQUEST SENSE = 8 + additional-length(0x0a) = 18 bytes.
wire [31:0] cmd6_alloc = {24'd0, cmd[4]};
wire [31:0] sense_alloc = (cmd[4] == 8'h00) ? 32'd4 : cmd6_alloc;
wire [31:0] data_len = cmd_inquiry ? ((cmd6_alloc < 32'd54) ? cmd6_alloc : 32'd54) :
                       cmd_request_sense ? ((sense_alloc < 32'd18) ? sense_alloc : 32'd18) :
                       32'd0;

	wire [7:0] inquiry_dout =
			(data_cnt == 32'd0 ) ? 8'h05 : // CD/DVD device
			(data_cnt == 32'd1 ) ? 8'h80 : // removable
			(data_cnt == 32'd2 ) ? 8'h01 :
			(data_cnt == 32'd3 ) ? 8'h01 :
			(data_cnt == 32'd4 ) ? 8'h31 :
			(data_cnt == 32'd8 ) ? "S" :
			(data_cnt == 32'd9 ) ? "O" :
			(data_cnt == 32'd10) ? "N" :
			(data_cnt == 32'd11) ? "Y" :
			(data_cnt == 32'd16) ? "C" :
			(data_cnt == 32'd17) ? "D" :
			(data_cnt == 32'd18) ? "-" :
			(data_cnt == 32'd19) ? "R" :
			(data_cnt == 32'd20) ? "O" :
			(data_cnt == 32'd21) ? "M" :
			(data_cnt == 32'd22) ? " " :
			(data_cnt == 32'd23) ? "C" :
			(data_cnt == 32'd24) ? "D" :
			(data_cnt == 32'd25) ? "U" :
			(data_cnt == 32'd26) ? "-" :
			(data_cnt == 32'd27) ? "8" :
			(data_cnt == 32'd28) ? "0" :
			(data_cnt == 32'd29) ? "0" :
			(data_cnt == 32'd30) ? "2" :
			(data_cnt == 32'd32) ? "1" :
			(data_cnt == 32'd33) ? "." :
			(data_cnt == 32'd34) ? "8" :
			(data_cnt == 32'd35) ? "g" :
			(data_cnt == 32'd39) ? 8'hd0 :
			(data_cnt == 32'd40) ? 8'h90 :
			(data_cnt == 32'd41) ? 8'h27 :
			(data_cnt == 32'd42) ? 8'h3e :
			(data_cnt == 32'd43) ? 8'h01 :
			(data_cnt == 32'd44) ? 8'h04 :
			(data_cnt == 32'd45) ? 8'h91 :
			(data_cnt == 32'd47) ? 8'h18 :
			(data_cnt == 32'd48) ? 8'h06 :
			(data_cnt == 32'd49) ? 8'hf0 :
			(data_cnt == 32'd50) ? 8'hfe :
			8'h00;

wire [7:0] sense_dout =
			(data_cnt == 32'd0 ) ? 8'h70 :
			(data_cnt == 32'd2 ) ? 8'h02 : // not ready
			(data_cnt == 32'd7 ) ? 8'h0a :
			(data_cnt == 32'd12) ? 8'hb0 : // AppleCD no-disc vendor ASC
			8'h00;
wire [31:0] empty_cd_data_cnt_next = data_cnt + 32'd1;
wire [7:0] inquiry_dout_next =
			(empty_cd_data_cnt_next == 32'd0 ) ? 8'h05 :
			(empty_cd_data_cnt_next == 32'd1 ) ? 8'h80 :
			(empty_cd_data_cnt_next == 32'd2 ) ? 8'h01 :
			(empty_cd_data_cnt_next == 32'd3 ) ? 8'h01 :
			(empty_cd_data_cnt_next == 32'd4 ) ? 8'h31 :
			(empty_cd_data_cnt_next == 32'd8 ) ? "S" :
			(empty_cd_data_cnt_next == 32'd9 ) ? "O" :
			(empty_cd_data_cnt_next == 32'd10) ? "N" :
			(empty_cd_data_cnt_next == 32'd11) ? "Y" :
			(empty_cd_data_cnt_next == 32'd16) ? "C" :
			(empty_cd_data_cnt_next == 32'd17) ? "D" :
			(empty_cd_data_cnt_next == 32'd18) ? "-" :
			(empty_cd_data_cnt_next == 32'd19) ? "R" :
			(empty_cd_data_cnt_next == 32'd20) ? "O" :
			(empty_cd_data_cnt_next == 32'd21) ? "M" :
			(empty_cd_data_cnt_next == 32'd22) ? " " :
			(empty_cd_data_cnt_next == 32'd23) ? "C" :
			(empty_cd_data_cnt_next == 32'd24) ? "D" :
			(empty_cd_data_cnt_next == 32'd25) ? "U" :
			(empty_cd_data_cnt_next == 32'd26) ? "-" :
			(empty_cd_data_cnt_next == 32'd27) ? "8" :
			(empty_cd_data_cnt_next == 32'd28) ? "0" :
			(empty_cd_data_cnt_next == 32'd29) ? "0" :
			(empty_cd_data_cnt_next == 32'd30) ? "2" :
			(empty_cd_data_cnt_next == 32'd32) ? "1" :
			(empty_cd_data_cnt_next == 32'd33) ? "." :
			(empty_cd_data_cnt_next == 32'd34) ? "8" :
			(empty_cd_data_cnt_next == 32'd35) ? "g" :
			(empty_cd_data_cnt_next == 32'd39) ? 8'hd0 :
			(empty_cd_data_cnt_next == 32'd40) ? 8'h90 :
			(empty_cd_data_cnt_next == 32'd41) ? 8'h27 :
			(empty_cd_data_cnt_next == 32'd42) ? 8'h3e :
			(empty_cd_data_cnt_next == 32'd43) ? 8'h01 :
			(empty_cd_data_cnt_next == 32'd44) ? 8'h04 :
			(empty_cd_data_cnt_next == 32'd45) ? 8'h91 :
			(empty_cd_data_cnt_next == 32'd47) ? 8'h18 :
			(empty_cd_data_cnt_next == 32'd48) ? 8'h06 :
			(empty_cd_data_cnt_next == 32'd49) ? 8'hf0 :
			(empty_cd_data_cnt_next == 32'd50) ? 8'hfe :
			8'h00;
wire [7:0] sense_dout_next =
			(empty_cd_data_cnt_next == 32'd0 ) ? 8'h70 :
			(empty_cd_data_cnt_next == 32'd2 ) ? 8'h02 :
			(empty_cd_data_cnt_next == 32'd7 ) ? 8'h0a :
			(empty_cd_data_cnt_next == 32'd12) ? 8'hb0 :
			8'h00;
wire [7:0] inquiry_dout_next2 = inquiry_dout_next;
wire [7:0] inquiry_dout_next3 = inquiry_dout_next;
wire [7:0] sense_dout_next2 = sense_dout_next;
wire [7:0] sense_dout_next3 = sense_dout_next;

assign dout = (phase == PHASE_STATUS_OUT)  ? status :
              (phase == PHASE_MESSAGE_OUT) ? MSG_CMD_COMPLETE :
              (phase == PHASE_DATA_OUT)    ? (cmd_request_sense ? sense_dout : inquiry_dout) :
              8'h00;
assign dout_pair = (phase == PHASE_STATUS_OUT)  ? {status, status} :
                   (phase == PHASE_MESSAGE_OUT) ? {MSG_CMD_COMPLETE, MSG_CMD_COMPLETE} :
                   (phase == PHASE_DATA_OUT)    ? (cmd_request_sense ? {sense_dout, sense_dout_next} : {inquiry_dout, inquiry_dout_next}) :
                   16'h0000;
assign dout_pair_next = (phase == PHASE_STATUS_OUT)  ? {status, status} :
                        (phase == PHASE_MESSAGE_OUT) ? {MSG_CMD_COMPLETE, MSG_CMD_COMPLETE} :
                        (phase == PHASE_DATA_OUT)    ? (cmd_request_sense ? {sense_dout_next2, sense_dout_next3} : {inquiry_dout_next2, inquiry_dout_next3}) :
                        16'h0000;

reg old_ack;
reg stb_ack;
reg stb_adv;
always @(posedge clk) begin
	old_ack <= ack;
	stb_ack <= ~old_ack & ack;
	stb_adv <= old_ack & ~ack;
end

always @(posedge clk) begin
	if (stb_ack && phase == PHASE_CMD_IN)
		cmd[cmd_cnt] <= din;
end

always @(posedge clk) begin
	if (phase == PHASE_IDLE)
		cmd_cnt <= 4'd0;
	else if (stb_adv && phase == PHASE_CMD_IN && cmd_cnt != 4'd15)
		cmd_cnt <= cmd_cnt + 4'd1;
end

always @(posedge clk) begin
	if (phase != PHASE_DATA_OUT && phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT) begin
		data_cnt <= 32'd0;
		data_complete <= 1'b0;
	end else if (phase == PHASE_DATA_OUT && stb_adv) begin
		if (!data_complete)
			data_cnt <= data_cnt + 32'd1;
		data_complete <= (data_len == 32'd0) || ((data_len - 32'd1) == data_cnt);
	end
end

always @(posedge clk) begin
	if (phase != PHASE_STATUS_OUT)
		status_sent <= 1'b0;
	else if (stb_adv)
		status_sent <= 1'b1;
end

always @(posedge clk) begin
	if (phase != PHASE_MESSAGE_OUT)
		message_sent <= 1'b0;
	else if (stb_adv)
		message_sent <= 1'b1;
end

always @(posedge clk) begin
	if (rst) begin
		phase <= PHASE_IDLE;
	end else begin
		if (phase == PHASE_IDLE) begin
			// Selection requires a FREE bus (see scsi.v selection comment):
			// while another device holds BSY, its dout is wired-ORed onto
			// din and a stray bit 3 would spuriously select this target.
			if (sel && din[ID] && !bus_busy)
				phase <= PHASE_CMD_IN;
		end else if (phase == PHASE_CMD_IN) begin
			if (cmd_cpl) begin
				if (cmd_inquiry || cmd_request_sense) begin
					status <= STATUS_OK;
					phase <= PHASE_DATA_OUT;
				end else begin
					status <= STATUS_CHECK_CONDITION;
					phase <= PHASE_STATUS_OUT;
				end
			end
		end else if (phase == PHASE_DATA_OUT) begin
			if (data_done)
				phase <= PHASE_STATUS_OUT;
		end else if (phase == PHASE_STATUS_OUT) begin
			if (status_sent)
				phase <= PHASE_MESSAGE_OUT;
		end else if (phase == PHASE_MESSAGE_OUT) begin
			if (message_sent)
				phase <= PHASE_IDLE;
		end else begin
			phase <= PHASE_IDLE;
		end
	end
end

endmodule

module scsi_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=9)
(
	input	                clock,

	input	[ADDRWIDTH-1:0] address_a,
	input	[DATAWIDTH-1:0] data_a,
	input	                wren_a,
	output reg [DATAWIDTH-1:0] q_a,

	input	[ADDRWIDTH-1:0] address_b,
	input	[DATAWIDTH-1:0] data_b,
	input	                wren_b,
	output reg [DATAWIDTH-1:0] q_b,

	input	[ADDRWIDTH-1:0] address_c,
	output reg [DATAWIDTH-1:0] q_c,

	input	[ADDRWIDTH-1:0] address_d,
	output reg [DATAWIDTH-1:0] q_d
);

// ram_ab is the ONLY storage array (pdma-prefetch redesign, 2026-07-17).
// The former ram_c/ram_d arrays were full mirror COPIES of the buffer whose
// only job was serving same-cycle look-ahead reads at address_c/address_d
// (mac_addr+1/+2 for the pseudo-DMA word/longword assembly). Across the six
// ring instances they cost ~48 M10K blocks and drove the device to 553/553
// saturation. They are replaced by a prefetch controller that reads the
// look-ahead bytes through IDLE port-B cycles into q_c/q_d holding registers.
//
// TIMING CONTRACT (what makes this legal): ncr5380 samples dout/dout_pair/
// dout_pair_next ONLY at DREQ-gated instants, and holds DREQ down for
// dma_settle cycles after every ACK train (= after every data_cnt advance).
// The controller needs at most 3 port-B cycles after an address change
// (read addr_c, read addr_d, restore address_b) — q_b/q_c/q_d are all
// consistent no later than 7 clocks after the advance; dma_settle is
// widened to 8 in ncr5380.sv to cover it. Port-B WRITES always win
// arbitration (the controller defers and retries), so write cycles are
// never disturbed and never mis-addressed.
//
// COHERENCY: a write on either port that lands on a prefetched (or
// in-flight) look-ahead address marks the prefetch stale; the controller
// refetches, and the post-write read returns the fresh data. No forwarding
// paths — the RAM is always the single source of truth.
// M10K pin per the migrating fabric-fallback law (bae8fd8 on add-cd-audio;
// this redesign was authored from master and the 2544a1f merge took it
// wholesale, silently dropping the pin — found 2026-07-18 by the MacIIvi
// port review). ram_ab has never flipped (TDP shape infers reliably), so
// this is insurance, not a bug fix; expect zero delta in the map audit.
(* ramstyle = "M10K,no_rw_check" *) reg [DATAWIDTH-1:0] ram_ab[0:(1<<ADDRWIDTH)-1];

// ---- port A: HPS side (behavior unchanged) -------------------------------
always @(posedge clock) begin
	if(wren_a) begin
		ram_ab[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram_ab[address_a];
	end
end

// ---- look-ahead prefetch controller --------------------------------------
localparam PF_IDLE = 2'd0, PF_RDC = 2'd1, PF_RDD = 2'd2;
reg [1:0]           pf_st      = PF_IDLE;
reg [ADDRWIDTH-1:0] pf_c_addr  = {ADDRWIDTH{1'b1}}; // addresses q_c/q_d hold
reg [ADDRWIDTH-1:0] pf_d_addr  = {ADDRWIDTH{1'b1}};
reg [ADDRWIDTH-1:0] pf_c_tgt, pf_d_tgt;             // addresses in flight
reg                 pf_valid   = 1'b0;
reg                 pf_snooped = 1'b0;

wire pf_snoop_hit =
	(wren_a && (address_a == pf_c_addr || address_a == pf_d_addr ||
	            (pf_st != PF_IDLE && (address_a == pf_c_tgt || address_a == pf_d_tgt)) ||
	            // (2026-07-29) steal-LAUNCH cycle: the address_c read issues
	            // THIS cycle (pf_st still PF_IDLE, targets not latched yet),
	            // so the in-flight clause above cannot see a same-cycle
	            // port-A write to it; no_rw_check M10K returns OLD data on
	            // the cross-port collision and the stale byte would commit
	            // to q_c. (address_d needs no term: its read issues NEXT
	            // cycle, after such a write has landed.)
	            (pf_steal_c && address_a == address_c))) ||
	(wren_b && (address_b == pf_c_addr || address_b == pf_d_addr ||
	            (pf_st != PF_IDLE && (address_b == pf_c_tgt || address_b == pf_d_tgt))));

wire pf_stale = !pf_valid || pf_snooped ||
                (address_c != pf_c_addr) || (address_d != pf_d_addr);

// Port-B address mux: a stolen read presents the look-ahead address for one
// cycle; its result lands in q_b (port B's read register) and is copied into
// q_c/q_d in the following state. Writes always use the real address_b.
wire pf_steal_c = (pf_st == PF_IDLE) && pf_stale && !wren_b;
wire pf_steal_d = (pf_st == PF_RDC)  && !wren_b;
wire [ADDRWIDTH-1:0] address_b_eff =
	pf_steal_c ? address_c :
	pf_steal_d ? pf_d_tgt  :
	             address_b;

// ---- port B: Mac side + stolen prefetch reads ----------------------------
// Single-address TDP port: write and read MUST share one address or Quartus
// refuses RAM inference (Error 276003, all rings -> ~300K registers). The
// steal mux guarantees address_b_eff == address_b whenever wren_b is high
// (both steal conditions carry !wren_b), so writing at address_b_eff is
// bit-identical to writing at address_b.
always @(posedge clock) begin
	if(wren_b) begin
		ram_ab[address_b_eff] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram_ab[address_b_eff];
	end
end

// ---- controller sequencing + q_c/q_d capture -----------------------------
always @(posedge clock) begin
	case (pf_st)
		PF_IDLE: begin
			if (pf_snoop_hit) pf_snooped <= 1'b1;
			if (pf_steal_c) begin
				pf_c_tgt <= address_c;
				pf_d_tgt <= address_d;
				pf_st    <= PF_RDC;
			end
		end
		PF_RDC: begin
			if (pf_snoop_hit) pf_snooped <= 1'b1;
			q_c <= q_b;                    // ram[pf_c_tgt], read during PF_IDLE steal
			pf_st <= pf_steal_d ? PF_RDD : PF_IDLE; // wren_b stole the D cycle: abort+retry
		end
		PF_RDD: begin
			q_d <= q_b;                    // ram[pf_d_tgt], read during PF_RDC steal
			if (!pf_snooped && !pf_snoop_hit) begin
				pf_c_addr <= pf_c_tgt;
				pf_d_addr <= pf_d_tgt;
				pf_valid  <= 1'b1;
			end
			// A hit before/at this edge forced the discard above; the refetch
			// it triggers will read post-write data, so the flag is consumed.
			pf_snooped <= 1'b0;
			pf_st      <= PF_IDLE;
		end
		default: pf_st <= PF_IDLE;
	endcase
end

endmodule
