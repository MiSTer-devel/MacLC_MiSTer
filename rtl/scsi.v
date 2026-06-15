/* verilator lint_off UNUSED */

// scsi.v
// implements a target only scsi device
  
module scsi
(
	input      clk,

	// scsi interface
	input 	  rst, // bus reset from initiator
	input 	  sel,
	input 	  bus_busy, // another device currently holds the bus (its BSY)
	input 	  atn, // initiator requests to send a message
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

	// interface to io controller
	input         img_mounted,
	input  [31:0] img_blocks,
	output [31:0] io_lba,
	output reg 	  io_rd,
	output reg 	  io_wr,
	input         io_ack,

	input   [7:0] sd_buff_addr,
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
// Set on the PRIMARY target only (ID 6). Gates the BlueSCSI Toolbox so just one
// target presents as a Toolbox device and owns the dedicated tb_* transport.
// docs/BLUESCSI_CORE_HPS_CONTRACT.md
parameter TOOLBOX_ENABLE = 0;

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
	.wren_a(sd_buff_wr),
	.q_a(buf0_q_a),

	.address_b(mac_addr),
	.data_b(din),
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
//   Refinement: latch the current word's odd byte LOCALLY at beat-1's stb_ack (when
//   data_cnt is even and we're in PHASE_DATA_IN). At that moment dma_write_low_byte
//   is stable with the current word's wdata[7:0]. Hold it across beat 2's storage.
//   This is both race-free (locked to the current word, immune to the next CPU
//   access) and timing-friendly (BlockRAM data_b is now a short local-reg-to-RAM
//   path). Byte-mode (dbg_dma_word=0) still uses din directly, unchanged.
//   buffer0 (even byte) is untouched — it was already storing correctly.
reg [7:0] odd_byte_r;
always @(posedge clk) begin
	if (rst)
		odd_byte_r <= 8'h00;
	else if (stb_ack && (phase == PHASE_DATA_IN) && ~data_cnt[0] && dbg_dma_word)
		odd_byte_r <= dbg_dma_lowbyte;
end

scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer1
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(buf1_data_a),
	.wren_a(sd_buff_wr),
	.q_a(buf1_q_a),

	.address_b(mac_addr),
	.data_b(dbg_dma_word ? odd_byte_r : din),
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
		if (old_io_ack & ~io_ack) sd_buff_sel <= !sd_buff_sel;

	// READ ring fetch counter: # of sectors the HPS has delivered this command.
	// Reset alongside data_cnt (any non-transfer phase); bump on each io_ack
	// falling edge during a read. Writes never touch it (they use sd_buff_sel).
	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT)
		rd_hps_blk <= 23'd0;
	else if (old_io_ack & ~io_ack & cmd_read)
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
wire   io_busy = (phase == PHASE_DATA_OUT && cmd_read && (rd_cur_blk >= rd_hps_blk)) ||
                 (phase == PHASE_DATA_IN  && (io_wr | io_ack) && data_cnt[9] == sd_buff_sel) ||
                 (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN && (io_rd | io_wr | io_ack));
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
		cmd_tb_devinfo?tb_devinfo_dout:
		cmd_tb_debug?tb_debug_dout:
		cmd_tb_fs_in?tb_serve:
		8'h00;
wire [15:0] cmd_dout_pair =
		cmd_read?(data_cnt[0] ? {buffer1_dout, buffer0_dout_next} : {buffer0_dout, buffer1_dout}):
		cmd_inquiry?{inquiry_dout, inquiry_dout_next}:
		cmd_read_capacity?{read_capacity_dout, read_capacity_dout_next}:
		cmd_mode_sense?{mode_sense_dout, mode_sense_dout_next}:
		cmd_request_sense?{request_sense_dout, request_sense_dout_next}:
		cmd_tb_devinfo?{tb_devinfo_dout, tb_devinfo_dout_next}:
		cmd_tb_debug?{tb_debug_dout, tb_debug_dout_next}:
		cmd_tb_fs_in?tb_serve_pair:
		16'h0000;
wire [15:0] cmd_dout_pair_next =
		cmd_read?(data_cnt[0] ? {buffer1_dout_next, buffer0_dout_next2} : {buffer0_dout_next, buffer1_dout_next}):
		cmd_inquiry?{inquiry_dout_next2, inquiry_dout_next3}:
		cmd_read_capacity?{read_capacity_dout_next2, read_capacity_dout_next3}:
		cmd_mode_sense?{mode_sense_dout_next2, mode_sense_dout_next3}:
		cmd_request_sense?{request_sense_dout_next2, request_sense_dout_next3}:
		cmd_tb_devinfo?{tb_devinfo_dout_next2, tb_devinfo_dout_next3}:
		cmd_tb_debug?{tb_debug_dout_next2, tb_debug_dout_next3}:
		cmd_tb_fs_in?tb_serve_pair_next:
		16'h0000;

// REQUEST SENSE response: minimal fixed-format sense, "NO SENSE".
//   byte 0 = 0x70 (current error, valid=0), byte 7 = 0x0a (add'l length 10),
//   sense key (byte 2) = 0 = NO SENSE, all else 0.
wire [7:0] request_sense_dout       = (data_cnt       == 32'd0)?8'h70:(data_cnt       == 32'd7)?8'h0a:8'h00;
wire [7:0] request_sense_dout_next  = (data_cnt_next  == 32'd0)?8'h70:(data_cnt_next  == 32'd7)?8'h0a:8'h00;
wire [7:0] request_sense_dout_next2 = (data_cnt_next2 == 32'd0)?8'h70:(data_cnt_next2 == 32'd7)?8'h0a:8'h00;
wire [7:0] request_sense_dout_next3 = (data_cnt_next3 == 32'd0)?8'h70:(data_cnt_next3 == 32'd7)?8'h0a:8'h00;

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
function [7:0] inquiry_byte;
	input [31:0] cnt;
	begin
		inquiry_byte =
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
reg [31:0] capacity;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			capacity <= img_blocks - 1'd1;
			if (!mounted) $display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end
end

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity[31:24]:
		(data_cnt == 32'd1 )?capacity[23:16]:
		(data_cnt == 32'd2 )?capacity[15:8]:
		(data_cnt == 32'd3 )?capacity[7:0]:
		(data_cnt == 32'd6 )?8'd2:             // 512 bytes per sector
		8'h00;
wire [7:0] read_capacity_dout_next =
		(data_cnt_next == 32'd0 )?capacity[31:24]:
		(data_cnt_next == 32'd1 )?capacity[23:16]:
		(data_cnt_next == 32'd2 )?capacity[15:8]:
		(data_cnt_next == 32'd3 )?capacity[7:0]:
		(data_cnt_next == 32'd6 )?8'd2:
		8'h00;
wire [7:0] read_capacity_dout_next2 =
		(data_cnt_next2 == 32'd0 )?capacity[31:24]:
		(data_cnt_next2 == 32'd1 )?capacity[23:16]:
		(data_cnt_next2 == 32'd2 )?capacity[15:8]:
		(data_cnt_next2 == 32'd3 )?capacity[7:0]:
		(data_cnt_next2 == 32'd6 )?8'd2:
		8'h00;
wire [7:0] read_capacity_dout_next3 =
		(data_cnt_next3 == 32'd0 )?capacity[31:24]:
		(data_cnt_next3 == 32'd1 )?capacity[23:16]:
		(data_cnt_next3 == 32'd2 )?capacity[15:8]:
		(data_cnt_next3 == 32'd3 )?capacity[7:0]:
		(data_cnt_next3 == 32'd6 )?8'd2:
		8'h00;

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
wire       mode_sense_p31 = TOOLBOX_ENABLE && cmd_mode_sense && (cmd[2][5:0] == 6'h31);

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

// Page select: 0x31 detection page vs. the unchanged default below.
wire [7:0] mode_sense_dout       = mode_sense_p31 ? mode_sense_p31_byte(data_cnt)       : mode_sense_def_dout;
wire [7:0] mode_sense_dout_next  = mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next)  : mode_sense_def_dout_next;
wire [7:0] mode_sense_dout_next2 = mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next2) : mode_sense_def_dout_next2;
wire [7:0] mode_sense_dout_next3 = mode_sense_p31 ? mode_sense_p31_byte(data_cnt_next3) : mode_sense_def_dout_next3;

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
reg [1:0]  tb_settle;
reg        old_tb_ack;

// Shared-folder availability: latches when the HPS mounts the Toolbox slot.
// Until then (incl. a stock Main with no handler) fs ops return CHECK (§4a).
reg tb_ready = 1'b0;
always @(posedge clk) if (TOOLBOX_ENABLE && tb_mounted) tb_ready <= 1'b1;

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
wire [7:0] tb_b_addr  = (tb_state == TBS_LOAD) ? {4'd0, tb_load_w} : data_cnt[8:1];
wire       tb_b_wr    = (tb_state == TBS_LOAD);
wire [7:0] tb_load_b0 = cmd[{tb_load_w[2:0], 1'b0}];   // even CDB byte
wire [7:0] tb_load_b1 = cmd[{tb_load_w[2:0], 1'b1}];   // odd  CDB byte

wire [7:0] tb0_dout, tb0_dout_next, tb0_dout_next2;
wire [7:0] tb1_dout, tb1_dout_next, tb1_dout_next2;
scsi_dpram #(.ADDRWIDTH(8)) tb_buf0 (
	.clock(clk),
	.address_a(sd_buff_addr), .data_a(tb_buf0_da), .wren_a(tb_hps_wr), .q_a(tb_buf0_qa),
	.address_b(tb_b_addr), .data_b(tb_load_b0), .wren_b(tb_b_wr), .q_b(tb0_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb0_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb0_dout_next2)
);
scsi_dpram #(.ADDRWIDTH(8)) tb_buf1 (
	.clock(clk),
	.address_a(sd_buff_addr), .data_a(tb_buf1_da), .wren_a(tb_hps_wr), .q_a(tb_buf1_qa),
	.address_b(tb_b_addr), .data_b(tb_load_b1), .wren_b(tb_b_wr), .q_b(tb1_dout),
	.address_c(tb_b_addr + 1'b1), .q_c(tb1_dout_next),
	.address_d(tb_b_addr + 2'd2), .q_d(tb1_dout_next2)
);

// Serve sources (mirror the disk read: even byte from buf0, odd from buf1).
wire  [7:0] tb_serve           = data_cnt[0] ? tb1_dout : tb0_dout;
wire [15:0] tb_serve_pair      = data_cnt[0] ? {tb1_dout, tb0_dout_next} : {tb0_dout, tb1_dout};
wire [15:0] tb_serve_pair_next = data_cnt[0] ? {tb1_dout_next, tb0_dout_next2} : {tb0_dout_next, tb1_dout_next};

// Round-trip FSM. Drives tb_state / tb_rd / tb_wr / tb_lba; the MAIN phase FSM
// moves `phase` (CMD_IN -> PHASE_TB -> DATA_OUT/STATUS_OUT) by watching tb_state.
always @(posedge clk) begin
	old_tb_ack <= tb_ack;
	if (rst) begin
		tb_state <= TBS_IDLE; tb_rd_r <= 1'b0; tb_wr_r <= 1'b0; tb_lba_r <= 32'd0;
		tb_status <= 8'h02; tb_len <= 16'd0; tb_load_w <= 4'd0; tb_settle <= 2'd0;
	end else if (TOOLBOX_ENABLE) begin
		case (tb_state)
		TBS_IDLE: begin
			tb_load_w <= 4'd0;
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
				tb_rd_r <= 1'b1; tb_lba_r <= 32'd0; tb_state <= TBS_STAT;
			end
		end
		// status: HPS returns {status, 0xB5, len_hi, len_lo} at buffer words 0/1
		TBS_STAT: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			if (old_tb_ack & ~tb_ack) begin tb_settle <= 2'd2; tb_state <= TBS_LATCH; end
		end
		// let the registered buffer reads (addr 0/1, data_cnt=0) settle, then latch
		TBS_LATCH:
			if (tb_settle != 2'd0) tb_settle <= tb_settle - 1'b1;
			else if (tb1_dout == 8'hb5) begin            // signature ok (byte 1)
				tb_status <= tb0_dout;                       // byte 0 = SCSI status
				tb_len    <= {tb0_dout_next, tb1_dout_next}; // bytes 2,3 = length
				if ({tb0_dout_next, tb1_dout_next} != 16'd0) begin
					tb_rd_r <= 1'b1; tb_lba_r <= 32'd1; tb_state <= TBS_DATA;
				end else tb_state <= TBS_RDY;                // status-only
			end else begin                               // no real handler -> CHECK
				tb_status <= 8'h02; tb_len <= 16'd0; tb_state <= TBS_RDY;
			end
		// data: HPS returns one 512-byte block at words 0..255
		TBS_DATA: begin
			if (tb_ack) tb_rd_r <= 1'b0;
			if (old_tb_ack & ~tb_ack) tb_state <= TBS_RDY;
		end
		// round-trip done; the main FSM consumes tb_status/tb_len and leaves
		TBS_RDY: if (phase != PHASE_TB) tb_state <= TBS_IDLE;
		default: tb_state <= TBS_IDLE;
		endcase
	end
end

/* ----------------------- request data from/to io controller ----------------------- */

assign io_lba = lba;

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

always @(posedge clk) begin
	reg old_wr;
	reg wr_pending;
	reg rd_busy;            // a read-prefetch sector fetch is outstanding

	// A SCSI bus reset aborts any in-flight/queued disk IO.  Without this,
	// io_rd/io_wr (and the pending latches) survive the reset; if the Mac
	// re-selects before the stale io_rd clears via io_ack, the next CMD_IN
	// phase sees io_busy=1 (phase!=DATA && io_rd) which suppresses REQ, the
	// command never transfers, the Mac times out and resets again -> the
	// intermittent reset/re-scan loop observed on hardware.
	if(rst) begin
		io_rd <= 1'b0;
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
		if(io_ack) io_rd <= 1'b0;
		else if(req_rd && !io_rd && !rd_busy) begin io_rd <= 1'b1; rd_busy <= 1'b1; end
		if(old_io_ack & ~io_ack) rd_busy <= 1'b0;

		// WRITE flush engine — unchanged two-slot double-buffer behavior.
		if(io_ack) io_wr <= 1'b0;
		else if(wr_pending && !io_wr) begin io_wr <= 1'b1; wr_pending <= 0; end
	end
end

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
		 cmd_inquiry?((alloc_len < 32'd36) ? alloc_len : 32'd36):
		 cmd_mode_sense?(mode_sense_p31 ? ((alloc_len < 32'd56) ? alloc_len : 32'd56)
		                                : ((alloc_len < 32'd12) ? alloc_len : 32'd12)):
		 cmd_request_sense?((sense_len < 32'd18) ? sense_len : 32'd18):
		 cmd_tb_devinfo?tb_devinfo_len:                       // 0xD9 DEVICE INFO
		 cmd_tb_debug_get?32'd1:                              // 0xD6 get = one flag byte
		 cmd_tb_fs_in?{16'd0, tb_len}:                        // 0xD0/D1/D2 toolbox DataIn (HPS length)
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
// BlueSCSI Toolbox vendor commands (0xD0-0xD9, group 110) are 10-byte CDBs.
// Decode ONLY this exact range as 10-byte (not the whole vendor group 110) so
// other group-110 opcodes aren't mis-lengthed (0xC0 EJECT is a 6-byte CDB).
// docs/BLUESCSI_MISTER_MAIN_PLAN.md, docs/BLUESCSI_HANDOFF.md §1.
wire       cmd_toolbox_op = (op_code >= 8'hd0) && (op_code <= 8'hd9);
wire       cmd10_cpl = (((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10))
                       || (cmd_toolbox_op && (cmd_cnt == 10));

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

// ----- BlueSCSI Toolbox vendor commands (0xD0-0xD9) ----------------------
// M0 = the RTL-serviceable subset that needs NO host filesystem, so the Mac
// "BlueSCSI SD Transfer" client can DETECT the device:
//   * 0xD9 DEVICE INFO  - static device-list / capabilities (like INQUIRY)
//   * 0xD6 TOGGLE DEBUG - a stored flag (get/set), no side effects
// Detection itself is MODE SENSE page 0x31 (mode_sense_p31) + normal INQUIRY.
// The filesystem opcodes (0xD0/D1/D2/D3/D4/D5) need the HPS round trip and are
// NOT in cmd_ok yet -> they return CHECK CONDITION, which the client tolerates
// as "no shared folder" (empty listing). M1+ wires them to Main_MiSTer.
// docs/BLUESCSI_MISTER_MAIN_PLAN.md
wire       cmd_tb_devinfo   = TOOLBOX_ENABLE && (op_code == 8'hd9);
wire       cmd_tb_fs_in     = TOOLBOX_ENABLE && (op_code == 8'hd0 || op_code == 8'hd1 || op_code == 8'hd2); // LIST/GET/COUNT (HPS round-trip)                  // DEVICE INFO
wire       cmd_tb_debug     = TOOLBOX_ENABLE && (op_code == 8'hd6);                  // TOGGLE DEBUG
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

// valid command in buffer? TODO: check for valid command parameters
wire  cmd_ok = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug ||
		  (cmd_tb_fs_in && tb_ready);   // fs ops valid only with a shared folder (else CHECK)

// latch parameters once command is complete
reg [31:0] lba;
reg [15:0] tlen;

always @(posedge clk) begin
	if (old_io_ack & ~io_ack) lba <= lba + 1'd1;
	if(cmd_cpl && (phase == PHASE_CMD_IN)) begin
		lba <= cmd6_cpl?{11'd0, lba6}:lba10;
		tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
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
	end else begin
		if(phase == PHASE_IDLE) begin
			// Own id on bus during selection? Real SCSI selection requires a
			// FREE bus (SEL asserted, BSY false): while another device holds
			// BSY its dout is wired-ORed onto the data bus, so a stray bit in
			// that byte could otherwise "select" this target mid-dialog and
			// two targets would then consume the shared ACK stream in
			// parallel (command/LBA corruption -> misdirected writes).
			if(sel && din[ID] && mounted && !bus_busy)
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			// check if a full command is in the buffer
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				// is this a supported and valid command?
				if(cmd_ok) begin
					// yes, continue
					status <= `STATUS_OK;

					// continue according to command

					// these commands return data
					if(cmd_tb_fs_in) phase <= PHASE_TB;   // toolbox fs op: HPS round-trip, then serve
						else if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense || cmd_tb_devinfo || cmd_tb_debug_get) phase <= PHASE_DATA_OUT;
					// these commands receive dataa
					else if(cmd_write || cmd_mode_select || cmd_write_buffer) phase <= PHASE_DATA_IN;
					// and all other valid commands are just "ok"
					else phase <= PHASE_STATUS_OUT;
				end else begin
					// no, report failure
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
			if(data_done) phase <= PHASE_STATUS_OUT;
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

// Multi-block WRITE stall snapshot (2026-06-10). Live data-transfer state.
assign dbg_wrstall = { req, tlen[5:0], cmd_write, sd_buff_sel, io_busy,
                       io_ack, io_wr, data_complete, phase, data_cnt[15:0] };

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

// ram_ab is a true dual-port RAM serving the existing q_a/q_b read paths
// (each read at its port's write address). ram_c and ram_d are simple
// dual-port mirrors used for the look-ahead read ports q_c/q_d.
//
// wren_a and wren_b are mutually exclusive in this design (wren_a is
// driven by the SD->buffer path during PHASE_DATA_OUT, wren_b by the
// SCSI->buffer path during PHASE_DATA_IN), so muxing them into a single
// SDP write port keeps the mirrors coherent without needing two write
// ports on those arrays. Using a single ram array with >2 reads fails
// Quartus's TDP inference and produces "multiple constant drivers"
// errors on the ram net.
reg [DATAWIDTH-1:0] ram_ab[0:(1<<ADDRWIDTH)-1];
reg [DATAWIDTH-1:0] ram_c [0:(1<<ADDRWIDTH)-1];
reg [DATAWIDTH-1:0] ram_d [0:(1<<ADDRWIDTH)-1];

wire                  mirror_we    = wren_a | wren_b;
wire [ADDRWIDTH-1:0]  mirror_waddr = wren_a ? address_a : address_b;
wire [DATAWIDTH-1:0]  mirror_wdata = wren_a ? data_a    : data_b;

always @(posedge clock) begin
	if(wren_a) begin
		ram_ab[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram_ab[address_a];
	end
end

always @(posedge clock) begin
	if(wren_b) begin
		ram_ab[address_b] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram_ab[address_b];
	end
end

always @(posedge clock) begin
	if(mirror_we) ram_c[mirror_waddr] <= mirror_wdata;
	q_c <= ram_c[address_c];
end

always @(posedge clock) begin
	if(mirror_we) ram_d[mirror_waddr] <= mirror_wdata;
	q_d <= ram_d[address_d];
end

endmodule
