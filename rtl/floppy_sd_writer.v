// floppy_sd_writer.v — Phase 4b: SDRAM-sourced persistence with an unbounded
// backlog (docs/floppy_write_plan.md, Phase 4b).
//
// Persist every sector the guest writes out to the mounted image on the SD
// card, via hps_io's sd_wr/sd_ack/sd_buff_* block-device protocol. This is
// the only module in the floppy write path that touches the user's file.
//
// ★ WHY THIS IS THE SECOND DESIGN. The first (tag `phase4-card-sourced`, a
// port of MacPlus's writer) kept a COPY of each committed sector in a
// depth-2 shadow queue and read the neighbouring bytes of a DC42 block back
// from the card. A 450 KB Finder copy overflowed that queue twice and left
// four wrong sectors on the card while the volume still checked out. The
// cause is the environment: Main opens a writable image O_RDWR|O_SYNC, so
// every block is a synchronous card write with bursty latency, against one
// sector every ~11 ms during a track write. Any fixed-depth copy of the DATA
// overflows on a long enough stall, and it does so silently.
//
// So this module keeps no copy of the data at all:
//
//   1. It queues sector NUMBERS. floppy_write_committer.v has already landed
//      the sector in SDRAM, and SDRAM always holds the NEWEST version, so a
//      sector re-written while still queued is simply queued twice and
//      written twice with the latest contents. No dedupe, no dirty bitmap,
//      no in-flight tracking. The FIFO is 2^QDEPTH_BITS deep (1024 = ~11 s of
//      backlog at one sector per 11 ms). If even that fills the push is
//      REFUSED and the refusal count in `dbg[31:24]` rises — visible, never
//      corrupting. That is the one failure mode left, and it is loud.
//
//   2. It fetches the block from SDRAM at write time, into ONE 256x16 block
//      buffer, then hands that to hps_io. The SDRAM read goes through the
//      controller's Ethernet-DMA requester (a proven LEVEL two-phase port
//      that starts only on idle edges and never touches cpu_done), shared
//      with pds_enet by rtl/eth_port_arb.v. rtl/sdram.v is NOT edited.
//
//   3. DC42 needs no card read any more. A DC42 file puts sector N at file
//      byte 84 + N*512, so file block N is [last 84 bytes of sector N-1]
//      [first 428 bytes of sector N] = payload words N*256-42 .. N*256+213,
//      all in SDRAM (the loader strips only the header; sector data AND the
//      tag section are resident). The one exception is block 0, whose first
//      42 words ARE the stripped header: floppy_loader.v keeps them and
//      exports the hdr_addr/hdr_data read port used here.
//
//   4. The eject-time DC42 data-checksum rewrite (sum = ror32(sum + word) is
//      position-dependent, so it cannot be updated incrementally) is now an
//      SDRAM scan: drain the queue, read the data section word by word from
//      SDRAM accumulating the sum, then write block 0 assembled from the
//      loader's header words with 36/37 substituted plus sector 0's head.
//      dataSize comes from header words 32/33. The TAG checksum is left as
//      stored: tags are never written, so it is still right.
//
// ★ PHASE 6D (2026-09-19) REVERSED LC ADDITION 3's LAST CLAUSE. The old rule
// was "file_blocks refuses any block at or past the file's last COMPLETE
// block, so a tagless DC42's final sector tail stays volatile", on the
// premise that a partial block would EXTEND the file. It does not: Main
// clips the write to the file's real end (user_io.cpp:3502-3514, upstream
// since 2021, so every stock MiSTer does it) and `sd_image_cangrow` is set
// only by the pre-create mount path, which an OSD mount is not. So the tail
// block is writable, the writer still sends its full 512-byte buffer, and
// Main writes only the bytes that exist. `file_tail` carries that one fact
// in; `head_ok`'s "both blocks or neither" rule is UNCHANGED, which is the
// point — the straddling sector is now written whole rather than refused.
//
// UNCHANGED FROM PHASE 4: write_ok is the single gate on reaching the card
// (decided in MacLC.sv, never re-derived here); file_blocks refuses any block
// past the file's end (its last complete block, plus the partial tail block
// when file_tail says there is one); the guest
// eject is the flush trigger (an OSD unmount has already taken the file
// away); img_mounted ABORTS everything, because a sector is now several
// requests and sd_ack is per SLOT — a running FSM would be walked forward by
// the loader's acks on the new image (Phase 4 review finding, bench sections
// 10-11); the ack timeout re-PRESENTS the same block rather than retiring it
// (hps_io captures sd_lba in one poll and acks in a later one, so a retired
// entry plus a late ack would stream the wrong block to a captured LBA).
//
// Byte order: SDRAM words are in the internal convention (even byte in the
// HIGH half, floppy_loader.v's sw_data); hps_io's wire word is the opposite,
// so the single output swap below mirrors the loader's input swap. The
// checksum is defined over the big-endian file word, which IS the internal
// word, so the scan needs no swap.
module floppy_sd_writer #(
	parameter ACK_TIMEOUT_BITS = 24,  // ~0.5 s at clk_sys; the bench narrows it
	parameter QDEPTH_BITS      = 10   // 1024 pending sectors
) (
	input             clk,
	input             reset,

	input             img_mounted,   // this slot's mount pulse: abort + empty the queue

	// commit tap from floppy_write_committer, via floppy.v
	input             commit_done,
	input      [21:0] commit_addr,   // PAYLOAD byte offset of the sector's byte 0

	input             write_ok,      // the single gate on reaching the card
	input             loader_busy,   // floppy_loader owns the slot and SDRAM region
	input             dc42,          // DiskCopy 4.2 container (84-byte header)
	input             flush_req,     // 1-clk pulse: the guest ejected
	input      [12:0] file_blocks,   // COMPLETE 512-byte blocks in the FILE
	input             file_tail,     // ...and the file has a PARTIAL block after
	                                 // them (DC42's 84-byte header makes every
	                                 // DC42 file end mid-block). That block is
	                                 // writable — Main clips to EOF; see the
	                                 // Phase 6D note in the header.

	// where the image lives in SDRAM (word address of payload word 0)
	input      [23:0] img_base,

	// floppy_loader's header store (registered: data valid the cycle after addr)
	output reg  [5:0] hdr_addr,
	input      [15:0] hdr_data,

	// SDRAM read requester — the eth-port protocol, via eth_port_arb
	output reg        mem_req,       // LEVEL: held until mem_ack, then dropped
	output reg [23:0] mem_addr,      // settled one edge before mem_req rises
	input             mem_ack,       // rises with data valid, falls after req drops
	input      [15:0] mem_dout,

	// hps_io block-device slot (writes only — this module never reads the card)
	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,
	input      [12:0] sd_buff_addr_i, // HPS-driven word address; [7:0] within the block
	output     [15:0] sd_buff_din,

	output            busy,

	// Witness word for the debug observer (PFSW probe in MacLC.sv).
	//   [31:24] queue REFUSALS (sat) — nonzero means a sector was LOST
	//   [23:16] blocks refused as out of range (sat)
	//   [15:8]  blocks landed (wraps)   [7:4] flushes started (sat)
	//   [3:0]   pstate
	output     [31:0] dbg
);

	localparam HDR_WORDS = 8'd42;

	// ── the sector-number queue ────────────────────────────────────────────
	reg [12:0] q_mem [0:(1<<QDEPTH_BITS)-1];
	reg [QDEPTH_BITS:0] wr_ptr, rd_ptr;
	wire [QDEPTH_BITS:0] count = wr_ptr - rd_ptr;
	wire full  = count[QDEPTH_BITS];
	wire empty = (count == 0);
	reg  [12:0] q_head;          // registered view of q_mem[rd_ptr]
	reg         empty_d;         // q_head lags a push by one cycle; see P_IDLE

	wire        push = commit_done && write_ok && !full;
	wire [12:0] push_idx = commit_addr[21:9];

	always @(posedge clk) begin
		if (push) q_mem[wr_ptr[QDEPTH_BITS-1:0]] <= push_idx;
		q_head  <= q_mem[rd_ptr[QDEPTH_BITS-1:0]];
		empty_d <= empty;
	end

	// ── the block buffer, filled from SDRAM / the header store, drained by
	//    hps_io through the HPS-driven address ────────────────────────────
	reg [15:0] blk [0:255];
	reg        blk_we;
	reg  [7:0] blk_wa;
	reg [15:0] blk_wd;
	always @(posedge clk) if (blk_we) blk[blk_wa] <= blk_wd;

	wire [7:0] sd_buff_addr = sd_buff_addr_i[7:0];
	reg [15:0] blk_do;
	always @(posedge clk) blk_do <= blk[sd_buff_addr];
	assign sd_buff_din = {blk_do[7:0], blk_do[15:8]};   // internal -> wire order

	// ── state ──────────────────────────────────────────────────────────────
	localparam P_IDLE      = 4'd0,
	           P_FILL_ADDR = 4'd1,   // point at word w (SDRAM address or header word)
	           P_FILL_REQ  = 4'd2,   // mem_req up, waiting for the word
	           P_FILL_TURN = 4'd3,   // mem_req dropped, waiting for ack to fall
	           P_FILL_HDR  = 4'd4,   // header word: one cycle for the loader's read port
	           P_WR        = 4'd5,   // block in the buffer: present sd_wr
	           P_WAIT_ACK  = 4'd6,
	           P_WAIT_DONE = 4'd7,
	           F_HDR_SZ0   = 4'd8,   // flush: fetch dataSize from header words 32/33
	           F_HDR_SZ1   = 4'd9,
	           F_HDR_SZ2   = 4'd10,
	           F_SCAN_ADDR = 4'd11,  // flush: checksum scan over SDRAM
	           F_SCAN_REQ  = 4'd12,
	           F_SCAN_TURN = 4'd13,
	           P_FILL_HWAIT = 4'd14, // header word: the loader's read port is
	                                 // registered, so hdr_data for the address
	                                 // set in P_FILL_ADDR is valid TWO edges
	                                 // later, not one (bench section 17 caught
	                                 // the one-edge version: every header word
	                                 // came out as its predecessor)
	           P_SKIP      = 4'd15;  // refused entry: one cycle for q_head to
	                                 // catch up with rd_ptr. Numbered last on
	                                 // purpose - the earlier codes are what the
	                                 // PFSW witness words captured in
	                                 // docs/floppy_write_plan.md decode to.
	reg [3:0] pstate;

	reg [12:0] cur_sec;      // sector being written (its FIRST block index)
	reg        phase;        // DC42: 0 = block N, 1 = block N+1
	reg  [8:0] w;            // word index within the block being filled
	reg        hdr_wr;       // the block being written is the flush's block 0
	reg        dirty;        // a block of ours reached the card this mount
	reg        flush_pending;
	reg [31:0] cksum;
	reg [21:0] data_size;    // DC42 header dataSize, bytes
	reg [20:0] scan_w;       // payload word index during the scan

	reg [ACK_TIMEOUT_BITS-1:0] ackTimer;
	wire ackTimeout = &ackTimer;

	// debug witness counters (see the dbg port)
	reg [7:0] dbg_ovf, dbg_refused, dbg_landed;
	reg [3:0] dbg_flushes;
	assign dbg = {dbg_ovf, dbg_refused, dbg_landed, dbg_flushes, pstate};

	wire [12:0] blk_now  = cur_sec + (phase ? 13'd1 : 13'd0);
	// Both blocks a DC42 sector touches must be writable, or the sector would
	// land half-written — the torn state that reads back self-consistently.
	// The limit is the file's last block INCLUSIVE of a partial tail (6D); 14
	// bits so q_head + 1 cannot wrap the comparison at the top of the range.
	wire [13:0] blk_limit = {1'b0, file_blocks} + {13'd0, file_tail};
	wire [13:0] blk_last  = dc42 ? ({1'b0, q_head} + 14'd1) : {1'b0, q_head};
	wire        head_ok  = (file_blocks != 13'd0) && (blk_last < blk_limit);
	// Word w of block blk_now: header word (DC42 block 0, w < 42) or payload
	// word. DC42 shifts the payload down by the 42 header words.
	wire        hdr_src  = dc42 && (blk_now == 13'd0) && (w < 9'd42);
	wire [23:0] pay_word = {3'd0, blk_now, w[7:0]} - (dc42 ? 24'd42 : 24'd0);
	wire [20:0] scan_words = data_size[21:1];     // dataSize / 2
	wire [31:0] cksum_add  = cksum + {16'd0, mem_dout};

	assign busy = (pstate != P_IDLE) || !empty || flush_pending;

	always @(posedge clk) begin
		blk_we <= 1'b0;
		if (reset) begin
			pstate <= P_IDLE;
			sd_lba <= 32'd0;
			sd_wr  <= 1'b0;
			mem_req <= 1'b0;
			mem_addr <= 24'd0;
			hdr_addr <= 6'd0;
			wr_ptr <= 0;
			rd_ptr <= 0;
			cur_sec <= 13'd0;
			phase  <= 1'b0;
			w      <= 9'd0;
			hdr_wr <= 1'b0;
			dirty  <= 1'b0;
			flush_pending <= 1'b0;
			cksum  <= 32'd0;
			data_size <= 22'd0;
			scan_w <= 21'd0;
			ackTimer <= 0;
			dbg_ovf <= 8'd0; dbg_refused <= 8'd0; dbg_landed <= 8'd0; dbg_flushes <= 4'd0;
		end else begin
			// ── capture side: independent of pstate ──────────────────────
			if (commit_done && write_ok) begin
				if (full) begin
					// the one remaining loss path, and it is loud: 1024
					// sectors pending means the card has stalled for ~11 s.
					// dbg[31:24] != 0 is the sticky witness.
					if (dbg_ovf != 8'hFF) dbg_ovf <= dbg_ovf + 8'd1;
				end else
					wr_ptr <= wr_ptr + 1'd1;
			end

			// Latch the guest's eject if anything was, or may yet be,
			// written this mount; whether a rewrite is needed is decided at
			// P_IDLE once the queue has drained and `dirty` is final. A
			// read-only session (dirty can never set) leaves the file alone.
			// Not gated on write_ok's CURRENT state: dirty already proves the
			// writes were permitted when they happened.
			if (flush_req && dc42 && (dirty || !empty || pstate != P_IDLE))
				flush_pending <= 1'b1;

			case (pstate)
			P_IDLE: begin
				if (flush_pending && empty && !loader_busy) begin
					if (dirty) begin
						hdr_addr <= 6'd32;
						pstate   <= F_HDR_SZ0;
						if (dbg_flushes != 4'hF) dbg_flushes <= dbg_flushes + 4'd1;
					end else
						flush_pending <= 1'b0;   // nothing of ours in the file
				end else if (!empty && !empty_d && !loader_busy) begin
					// q_head is valid once the queue has been non-empty for
					// two cycles (its read lags the push by one).
					rd_ptr <= rd_ptr + 1'd1;
					if (!head_ok) begin
						// past the end of the file (or its partial tail):
						// retire without writing. This is the last place
						// that can refuse; nothing upstream checks the block
						// against the mounted file's length.
						if (dbg_refused != 8'hFF) dbg_refused <= dbg_refused + 8'd1;
						// ...but leave P_IDLE for a cycle. q_head is a
						// registered read of q_mem[rd_ptr], so it still shows
						// the entry just retired; staying here would pop a
						// SECOND entry against that stale head - refusing the
						// same sector twice and silently dropping the one
						// behind it (bench section 3).
						pstate <= P_SKIP;
					end else begin
						cur_sec <= q_head;
						phase   <= 1'b0;
						hdr_wr  <= 1'b0;
						w       <= 9'd0;
						pstate  <= P_FILL_ADDR;
					end
				end
			end

			P_SKIP: pstate <= P_IDLE;   // q_head catches up with rd_ptr here

			// ── fill the block buffer, one word per two-phase handshake ──
			P_FILL_ADDR: begin
				if (hdr_src) begin
					hdr_addr <= w[5:0];
					pstate   <= P_FILL_HWAIT;
				end else begin
					mem_addr <= img_base + pay_word;
					pstate   <= P_FILL_REQ;
				end
			end

			P_FILL_HWAIT: pstate <= P_FILL_HDR;   // the loader samples hdr_addr here

			P_FILL_HDR: begin
				// hdr_data is now word w of the stored header. During the
				// flush's block 0, words 36/37 carry the recomputed checksum.
				blk_wa <= w[7:0];
				blk_wd <= (hdr_wr && w == 9'd36) ? cksum[31:16]
				        : (hdr_wr && w == 9'd37) ? cksum[15:0]
				        : hdr_data;
				blk_we <= 1'b1;
				w      <= w + 9'd1;
				pstate <= (w == 9'd255) ? P_WR : P_FILL_ADDR;
			end

			P_FILL_REQ: begin
				mem_req <= 1'b1;     // rises one edge after mem_addr settled
				if (mem_ack) begin
					blk_wa  <= w[7:0];
					blk_wd  <= mem_dout;
					blk_we  <= 1'b1;
					mem_req <= 1'b0;
					pstate  <= P_FILL_TURN;
				end
			end

			P_FILL_TURN: if (!mem_ack) begin
				w      <= w + 9'd1;
				pstate <= (w == 9'd255) ? P_WR : P_FILL_ADDR;
			end

			// ── hand the block to hps_io ─────────────────────────────────
			P_WR: begin
				sd_lba <= {19'd0, blk_now};
				sd_wr  <= 1'b1;
				pstate <= P_WAIT_ACK;
			end

			P_WAIT_ACK: if (sd_ack) begin
				sd_wr  <= 1'b0;   // mirrors scsi.v: drop as soon as ack rises
				pstate <= P_WAIT_DONE;
			end else if (ackTimeout) begin
				// re-PRESENT the same block from the same buffer. hps_io may
				// have captured sd_lba already and ack late; whichever
				// attempt the ack belongs to, it streams this block to this
				// LBA. Never retire here.
				sd_wr  <= 1'b0;
				pstate <= P_WR;
			end else
				ackTimer <= ackTimer + 1'b1;

			P_WAIT_DONE: if (!sd_ack) begin
				dbg_landed <= dbg_landed + 8'd1;
				if (hdr_wr) begin
					// the flush's block 0 is down: header now matches the data
					hdr_wr        <= 1'b0;
					flush_pending <= 1'b0;
					dirty         <= 1'b0;
					pstate        <= P_IDLE;
				end else begin
					dirty <= 1'b1;
					if (dc42 && !phase) begin
						// the sector's second block (its 84-byte spill)
						phase  <= 1'b1;
						w      <= 9'd0;
						pstate <= P_FILL_ADDR;
					end else
						pstate <= P_IDLE;
				end
			end

			// ── eject flush: dataSize from the header, then the SDRAM scan ─
			F_HDR_SZ0: begin hdr_addr <= 6'd33; pstate <= F_HDR_SZ1; end
			F_HDR_SZ1: begin
				data_size[21:16] <= hdr_data[5:0];   // word 32 = dataSize[31:16]
				pstate <= F_HDR_SZ2;
			end
			F_HDR_SZ2: begin
				data_size[15:0] <= hdr_data;          // word 33 = dataSize[15:0]
				cksum  <= 32'd0;
				scan_w <= 21'd0;
				pstate <= F_SCAN_ADDR;
			end

			F_SCAN_ADDR: begin
				mem_addr <= img_base + {3'd0, scan_w};
				pstate   <= F_SCAN_REQ;
			end

			F_SCAN_REQ: begin
				mem_req <= 1'b1;
				if (mem_ack) begin
					// sum = ror32(sum + word), exactly scripts/mk_dc42.py
					cksum   <= {cksum_add[0], cksum_add[31:1]};
					mem_req <= 1'b0;
					pstate  <= F_SCAN_TURN;
				end
			end

			F_SCAN_TURN: if (!mem_ack) begin
				scan_w <= scan_w + 21'd1;
				if (scan_w + 21'd1 >= scan_words) begin
					// whole data section summed: write block 0 with the new
					// checksum, through the ordinary fill/write path.
					hdr_wr  <= 1'b1;
					cur_sec <= 13'd0;
					phase   <= 1'b0;
					w       <= 9'd0;
					pstate  <= P_FILL_ADDR;
				end else
					pstate <= F_SCAN_ADDR;
			end

			default: pstate <= P_IDLE;
			endcase

			if (pstate != P_WAIT_ACK) ackTimer <= 0;

			// ── remount ABORT, after the case so it wins this cycle ──────
			// The queue belongs to the image that is gone; a request nobody
			// has seen is dropped (Main is single-threaded: a captured
			// transfer completes before a mount notification can be sent);
			// an SDRAM request withdrawn mid-flight is safe by the port's
			// done-birth law (ack is born only while req is up).
			if (img_mounted) begin
				wr_ptr        <= 0;
				rd_ptr        <= 0;
				flush_pending <= 1'b0;
				dirty         <= 1'b0;
				hdr_wr        <= 1'b0;
				phase         <= 1'b0;
				sd_wr         <= 1'b0;
				mem_req       <= 1'b0;
				blk_we        <= 1'b0;
				pstate        <= P_IDLE;
			end
		end
	end

endmodule
