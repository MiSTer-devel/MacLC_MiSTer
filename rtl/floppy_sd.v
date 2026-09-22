// floppy_sd.v - the floppy image's path to and from the SD card.
//
// A mounted floppy is a block device (hps_io slot), not a one-way download,
// which is what gives a write a path back to the user's file. Four modules:
//
//   floppy_loader           card -> SDRAM at mount, DC42 header stripped
//   floppy_write_committer  a decoded sector -> SDRAM
//   floppy_sd_writer        SDRAM -> card, and the DC42 checksum rewrite
//   eth_port_arb            shares sdram.v's DMA port with pds_enet

module floppy_loader
(
	input             clk_sys,
	input             reset,

	// ── HPS block device (this slot) ──────────────────────────────────────
	input             img_mounted,   // one-shot mount pulse for this slot
	input      [63:0] img_size,      // valid at img_mounted; 0 = unmount
	input             img_readonly,  // valid at img_mounted

	output reg [31:0] sd_lba,
	output reg        sd_rd,
	input             sd_ack,
	input      [12:0] sd_buff_addr,  // AW=12 WIDE hps_io; [7:0] is the 512 B word index
	input      [15:0] sd_buff_dout,
	input             sd_buff_wr,

	// ── SDRAM download write port (level handshake, see sdram.v dl_*) ──────
	input      [23:0] base_addr,     // SDRAM WORD address of this image's slot
	output reg [23:0] wr_addr,       // SDRAM word address for the pending word
	output reg [15:0] wr_data,
	output reg        wr_req,        // LEVEL: held until wr_ack is seen
	input             wr_ack,        // LEVEL

	// ── status ────────────────────────────────────────────────────────────
	output reg        loading,       // high for the whole mount: gates flp_ok
	output reg        done,          // one clk_sys pulse: image fully resident
	output reg [63:0] size,          // latched payload size (DC42 header removed)
	output reg        readonly,      // latched at THIS slot's own mount pulse
	output reg        raw_img,       // 1 = raw sector image (writable in stage 1)
	output reg        is_dc42,       // 1 = a DiskCopy 4.2 image was detected
	// ── file block 0's first 42 words, kept for the SD writer ────────────
	// The 84-byte DC42 header is stripped from SDRAM, so it is the one part
	// of file block 0 the SDRAM-sourced writer cannot fetch. Registered
	// read port; words 36/37 are the data checksum as it stood at mount.
	input       [5:0] hdr_addr,
	output reg [15:0] hdr_data,
	// ── the MEDIUM's own sidedness, latched with `done` ──────────────────
	// Sniffed from the volume header so it survives a remount; not the
	// file's size and not the drive's.
	output reg        media_ds,
	output reg  [7:0] dc42_fmt       // DC42 byte 0x50: 0=400K 1=800K 2=720K 3=1440K
	                                 // a DC42's size cannot give the geometry:
	                                 // tags trail the data, so an 800K DC42 is
	                                 // 838400 payload bytes and matches no
	                                 // size test
);

	// sector staging RAM: load-then-drain rather than double-buffered, since
	// the SDRAM side is paced by the download slot
	reg [15:0] buf_ram [0:255];
	reg  [7:0] drain_idx;

	// Stored BYTE-SWAPPED: a block-device word packs exactly like a download
	// word, and the read side depends on that byte order.
	always @(posedge clk_sys)
		if (sd_buff_wr && sd_ack) buf_ram[sd_buff_addr[7:0]] <= sw_data;

	// header store: every mount rewrites it (a raw image's "header" is just
	// its first 84 bytes, harmless — the writer only consults it for DC42).
	reg [15:0] hdr_ram [0:63];
	always @(posedge clk_sys) begin
		if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0 &&
		    sd_buff_addr[7:0] < 8'd42)
			hdr_ram[sd_buff_addr[5:0]] <= sw_data;
		hdr_data <= hdr_ram[hdr_addr];
	end

	localparam S_IDLE   = 3'd0;
	localparam S_RD     = 3'd1;   // sd_rd asserted, waiting for the sector
	localparam S_WAIT   = 3'd2;   // sd_ack fell: sector is in buf_ram
	localparam S_DRAIN  = 3'd3;   // push words to SDRAM
	localparam S_NEXT   = 3'd4;
	localparam S_DONE   = 3'd5;

	reg  [2:0] state;
	reg [31:0] sec_total;         // sectors to stream (file size / 512)
	reg [23:0] file_word;         // word index within the FILE
	reg        dc42;              // this image has a DiskCopy 4.2 header
	reg        dc42_name_ok;
	reg        old_ack;

	// DC42 header words, sampled as sector 0 streams past. Tested on the RAW
	// delivered word, not the swapped one:
	//   word 0  byte 0  = d[7:0] : Pascal name length, 1..63
	//   word 40 byte 80 = d[7:0] : disk-format byte (DC42 offset 0x50)
	//   word 41         = d      : the magic, 16'h0001
	localparam DC42_HDR_WORDS = 24'd42;   // 84 bytes

	wire [15:0] sw_data = {sd_buff_dout[7:0], sd_buff_dout[15:8]};   // byte swap,
	// matching the old download path's `{ioctl_data[7:0], ioctl_data[15:8]}` —
	// the read side depends on this byte order.

	// medium sidedness sniff: 400K and 800K are the same medium, nothing on
	// the diskette records which it is, and the file's size cannot say (a
	// One-Sided erase of an 800K image leaves an 800K file). The Master
	// Directory Block is sector 2 on MFS and HFS alike, and its volume size
	// is drNmAlBlks * drAlBlkSiz. No usable MDB means double-sided, so an
	// unformatted or foreign medium is never capped.
	localparam [15:0] MDB_SIG_MFS = 16'hD2D7;
	localparam [15:0] MDB_SIG_HFS = 16'h4244;
	// volume size in 512-byte blocks, midway between 800 and 1600
	localparam [23:0] SIDEDNESS_THRESHOLD = 24'd1200;

	// word index within the SECTOR, not the file block: a DC42 header shifts
	// sector 2 down by 42 words. The wrap below 42 cannot alias 0/9/10/11.
	wire [8:0] mdb_idx  = {1'b0, sd_buff_addr[7:0]} - (dc42 ? 9'd42 : 9'd0);
	wire       mdb_wr   = (state == S_RD) && sd_buff_wr && sd_ack &&
	                      (sd_lba == 32'd2);
	wire       sniff_rst = reset || img_mounted;

	reg [15:0] mdb_sig;     // word 0:      drSigWord
	reg [15:0] mdb_nalbk;   // word 9:      drNmAlBlks
	reg [15:0] mdb_absz_h;  // words 10-11: drAlBlkSiz, big-endian
	reg [15:0] mdb_absz_l;
	reg        mdb_seen;    // sector 2 went by, so the four words are this image's

	always @(posedge clk_sys) begin
		if (sniff_rst) mdb_seen <= 1'b0;
		else if (mdb_wr) begin
			case (mdb_idx)
			9'd0:  mdb_sig    <= sw_data;
			9'd9:  mdb_nalbk  <= sw_data;
			9'd10: mdb_absz_h <= sw_data;
			9'd11: begin mdb_absz_l <= sw_data; mdb_seen <= 1'b1; end
			default: ;
			endcase
		end
	end

	// drAlBlkSiz is a non-zero multiple of 512, well under 64K on a floppy
	wire mdb_ok = mdb_seen &&
	              ((mdb_sig == MDB_SIG_MFS) || (mdb_sig == MDB_SIG_HFS)) &&
	              (mdb_absz_h == 16'd0) && (mdb_absz_l != 16'd0) &&
	              (mdb_absz_l[8:0] == 9'd0) && (mdb_nalbk != 16'd0);

	// drNmAlBlks * (drAlBlkSiz / 512), shift-add over seven cycles
	reg [23:0] vol_blocks;
	reg [23:0] mul_cand;
	reg  [6:0] mul_mult;
	reg  [2:0] mul_step;
	reg        mul_busy;

	always @(posedge clk_sys) begin
		if (sniff_rst) begin
			mul_busy   <= 1'b0;
			vol_blocks <= 24'd0;
		end
		else if (mdb_wr && mdb_idx == 9'd11) begin
			vol_blocks <= 24'd0;
			mul_cand   <= {8'd0, mdb_nalbk};
			mul_mult   <= sw_data[15:9];
			mul_step   <= 3'd0;
			mul_busy   <= 1'b1;
		end
		else if (mul_busy) begin
			if (mul_mult[0]) vol_blocks <= vol_blocks + mul_cand;
			mul_cand <= {mul_cand[22:0], 1'b0};
			mul_mult <= {1'b0, mul_mult[6:1]};
			mul_step <= mul_step + 3'd1;
			if (mul_step == 3'd6) mul_busy <= 1'b0;
		end
	end

	// published with `done`; double-sided until the medium says otherwise
	always @(posedge clk_sys) begin
		if (reset) media_ds <= 1'b1;
		else if (state == S_DONE)
			media_ds <= !mdb_ok || (vol_blocks > SIDEDNESS_THRESHOLD);
	end

	always @(posedge clk_sys) begin
		old_ack <= sd_ack;
		done    <= 1'b0;

		if (reset) begin
			state    <= S_IDLE;
			sd_rd    <= 1'b0;
			wr_req   <= 1'b0;
			loading  <= 1'b0;
			size     <= 64'd0;
			readonly <= 1'b0;
			raw_img  <= 1'b0;
			dc42     <= 1'b0;
			is_dc42  <= 1'b0;
			dc42_fmt <= 8'd0;
		end else begin

			// ── capture the DC42 signature as sector 0 streams in ──────────
			if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0) begin
				if (sd_buff_addr[7:0] == 8'd0)
					dc42_name_ok <= (sd_buff_dout[7:0] >= 8'd1) && (sd_buff_dout[7:0] <= 8'd63);
				else if (sd_buff_addr[7:0] == 8'd40)
					dc42_fmt <= sd_buff_dout[7:0];      // DC42 byte 0x50
				else if (sd_buff_addr[7:0] == 8'd41 && dc42_name_ok && sd_buff_dout == 16'h0001)
					dc42 <= 1'b1;
			end

			case (state)

			S_IDLE: begin
				// a mount pulse with a non-zero size starts a load; zero is an
				// UNMOUNT. readonly is latched here, at THIS slot's own pulse.
				if (img_mounted) begin
					readonly     <= img_readonly;
					dc42         <= 1'b0;
					dc42_name_ok <= 1'b0;
					dc42_fmt     <= 8'd0;
					raw_img      <= 1'b0;
					is_dc42      <= 1'b0;   // an unmount must not leave the old
					                        // container flag standing
					size         <= 64'd0;
					if (img_size != 64'd0) begin
						// CEIL, not floor: a DC42 file is 84 + payload bytes and
						// never ends on a block boundary, so a floor drops the
						// last sector's tail. Main serves the partial block and
						// the stale remainder drains past the payload end, well
						// inside the floppy region. Raw images are 512-multiples,
						// so ceil == floor.
						sec_total <= img_size[40:9] + {31'd0, |img_size[8:0]};
						sd_lba    <= 32'd0;
						file_word <= 24'd0;
						loading   <= 1'b1;
						sd_rd     <= 1'b1;
						state     <= S_RD;
					end else begin
						loading <= 1'b0;               // unmount: drive goes empty
					end
				end
			end

			S_RD: begin
				// hps_io raises sd_ack when it picks the transfer up and drops it
				// once the sector is delivered. Drop the request on the RISING
				// edge: held up for the whole transfer it is still asserted when
				// hps_io next samples it, and the same LBA re-issues.
				if (sd_ack) sd_rd <= 1'b0;
				if (old_ack && !sd_ack) begin
					drain_idx <= 8'd0;
					state     <= S_WAIT;
				end
			end

			S_WAIT: begin
				state <= S_DRAIN;      // one cycle for buf_ram's read port
			end

			S_DRAIN: begin
				if (!wr_req) begin
					// Skip the DC42 header entirely: those words are not disk
					// data and must not shift the payload.
					if (dc42 && (file_word < DC42_HDR_WORDS)) begin
						file_word <= file_word + 24'd1;
						drain_idx <= drain_idx + 8'd1;
						if (drain_idx == 8'd255) state <= S_NEXT;
					end else begin
						wr_addr <= base_addr +
						           (dc42 ? (file_word - DC42_HDR_WORDS) : file_word);
						wr_data <= buf_ram[drain_idx];
						wr_req  <= 1'b1;
					end
				end else if (wr_ack) begin
					wr_req    <= 1'b0;     // two-phase: drop req, ack follows
					file_word <= file_word + 24'd1;
					drain_idx <= drain_idx + 8'd1;
					if (drain_idx == 8'd255) state <= S_NEXT;
				end
			end

			S_NEXT: begin
				if (sd_lba + 32'd1 >= sec_total) begin
					state <= S_DONE;
				end else begin
					sd_lba <= sd_lba + 32'd1;
					sd_rd  <= 1'b1;
					state  <= S_RD;
				end
			end

			S_DONE: begin
				// Publish the payload size the guest should see: for DC42 that
				// is the file minus its header. raw_img gates stage-1 writes.
				size    <= dc42 ? (img_size_l - 64'd84) : img_size_l;   // 42 words
				raw_img <= !dc42;
				is_dc42 <= dc42;
				loading <= 1'b0;
				done    <= 1'b1;         // one pulse, AFTER the image is resident
				state   <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

	// img_size is only valid at the mount pulse, so hold it for S_DONE.
	reg [63:0] img_size_l;
	always @(posedge clk_sys)
		if (img_mounted) img_size_l <= img_size;

endmodule

module floppy_write_committer
(
	input             clk,
	input             rst,          // synchronous, active high — as floppy_sd.v

	// from floppy_track_decoder
	input             sector_valid, // 1-clk pulse: a verified sector is ready
	input      [21:0] sector_addr,  // the decoder's `addr`: image BYTE offset of byte 0
	output reg [8:0]  buf_addr,     // drives the decoder's buf_addr
	input      [7:0]  buf_data,     // the decoder's registered buf_data, 1 clk later

	// SDRAM write port, same LEVEL protocol as floppy_sd.v
	output reg [21:0] wr_addr,      // image BYTE offset of this word's EVEN byte
	output reg [15:0] wr_data,
	output reg        wr_req,       // LEVEL: held until wr_ack
	input             wr_ack,       // LEVEL

	output            busy,
	output reg        done,         // 1-clk pulse: sector fully in SDRAM
	output     [21:0] committed_addr,

	// persistence tap: a mirror of the word stream going to SDRAM, taken
	// from the same registered wr_addr/wr_data so the two destinations
	// cannot disagree. sd_buf_wr follows the LEVEL wr_req, rewriting a
	// waiting word each cycle with the same address and data.
	output      [7:0] sd_buf_addr,   // word index 0..255 within the sector
	output     [15:0] sd_buf_data,   // internal convention: EVEN byte in the high half
	output            sd_buf_wr
);

	localparam IDLE       = 3'd0,
	           FETCH_LO   = 3'd1,
	           FETCH_HI   = 3'd2,
	           ASSERT     = 3'd3,
	           WAIT       = 3'd4,
	           DONE_PULSE = 3'd5;

	reg [2:0]  state;
	reg [21:0] base_addr;
	reg [7:0]  word_idx;             // 0..255 (512 bytes / 2)
	reg [7:0]  byte_hi;              // the EVEN byte, held while the odd one is read

	assign busy           = (state != IDLE);
	assign committed_addr = base_addr;

	assign sd_buf_addr    = word_idx;
	assign sd_buf_data    = wr_data;
	assign sd_buf_wr      = wr_req;

	always @(*) begin
		case (state)
			FETCH_HI: buf_addr = {word_idx, 1'b1};
			default:  buf_addr = {word_idx, 1'b0}; // FETCH_LO, and settles in IDLE
		endcase
	end

	always @(posedge clk) begin
		done <= 1'b0;                 // default; pulsed explicitly below

		if (rst) begin
			state  <= IDLE;
			wr_req <= 1'b0;
		end else begin
			case (state)
			IDLE: if (sector_valid) begin
				base_addr <= sector_addr;
				word_idx  <= 8'd0;
				state     <= FETCH_LO;
			end

			// buf_addr (even) is presented this cycle; the decoder's
			// registered read makes it valid the next one
			FETCH_LO: state <= FETCH_HI;

			// buf_data is now the EVEN byte. Capture it, while buf_addr (odd)
			// is presented this whole cycle for the decoder to capture in turn.
			FETCH_HI: begin
				byte_hi <= buf_data;
				state   <= ASSERT;
			end

			// buf_data is now the ODD byte. Pack {even, odd} and issue.
			ASSERT: begin
				wr_addr <= base_addr + {13'd0, word_idx, 1'b0};
				wr_data <= {byte_hi, buf_data};
				wr_req  <= 1'b1;
				state   <= WAIT;
			end

			WAIT: if (wr_ack) begin
				wr_req <= 1'b0;
				if (word_idx == 8'd255)
					state <= DONE_PULSE;
				else begin
					word_idx <= word_idx + 8'd1;
					state    <= FETCH_LO;
				end
			end

			DONE_PULSE: begin
				done  <= 1'b1;
				state <= IDLE;
			end

			default: state <= IDLE;
			endcase
		end
	end

endmodule

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
	                                 // them (a DC42's 84-byte header makes
	                                 // every DC42 file end mid-block). That
	                                 // block is writable - Main clips to EOF.

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

	output            busy
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
	                                 // registered: hdr_data is valid TWO
	                                 // edges after P_FILL_ADDR, not one
	           P_SKIP      = 4'd15;  // refused entry: one cycle for q_head
	                                 // to catch up with rd_ptr
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


	wire [12:0] blk_now  = cur_sec + (phase ? 13'd1 : 13'd0);
	// Both blocks a DC42 sector touches must be writable or the sector lands
	// half-written. The limit includes a partial tail block; 14 bits so
	// q_head + 1 cannot wrap at the top of the range.
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
		end else begin
			// ── capture side: independent of pstate ──────────────────────
			if (commit_done && write_ok) begin
				// a full queue is the one loss path left, and it needs a ~11 s card stall
				if (!full) wr_ptr <= wr_ptr + 1'd1;
			end

			// Latch the guest's eject if anything was, or may yet be, written
			// this mount; P_IDLE decides whether a rewrite is needed once the
			// queue has drained. Not gated on write_ok now - dirty already
			// proves the writes were permitted when they happened.
			if (flush_req && dc42 && (dirty || !empty || pstate != P_IDLE))
				flush_pending <= 1'b1;

			case (pstate)
			P_IDLE: begin
				if (flush_pending && empty && !loader_busy) begin
					if (dirty) begin
						hdr_addr <= 6'd32;
						pstate   <= F_HDR_SZ0;
					end else
						flush_pending <= 1'b0;   // nothing of ours in the file
				end else if (!empty && !empty_d && !loader_busy) begin
					// q_head is valid once the queue has been non-empty for
					// two cycles (its read lags the push by one).
					rd_ptr <= rd_ptr + 1'd1;
					if (!head_ok) begin
						// past the end of the file: retire without writing.
						// Leave P_IDLE for a cycle - q_head is a registered read
						// and still shows the entry just retired, so staying
						// would refuse the same sector twice and drop the one
						// behind it.
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
				// re-PRESENT the same block: hps_io may have captured sd_lba
				// already and ack late. Never retire here.
				sd_wr  <= 1'b0;
				pstate <= P_WR;
			end else
				ackTimer <= ackTimer + 1'b1;

			P_WAIT_DONE: if (!sd_ack) begin
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
					// sum = ror32(sum + word), the DC42 data checksum
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
			// The queue belongs to the image that is gone. A request nobody has
			// seen is dropped; an SDRAM request withdrawn mid-flight is safe,
			// because ack is born only while req is up.
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

module eth_port_arb
(
	input             clk,
	input             reset,

	// client A — pds_enet, priority
	input             a_req,
	input             a_we,
	input      [23:0] a_addr,
	input      [15:0] a_din,
	output            a_ack,
	output     [15:0] a_dout,

	// client B — floppy_sd_writer (reads only in practice; we is honoured)
	input             b_req,
	input             b_we,
	input      [23:0] b_addr,
	input      [15:0] b_din,
	output            b_ack,
	output     [15:0] b_dout,

	// the controller's eth port
	output reg        m_req,
	output reg        m_we,
	output reg [23:0] m_addr,
	output reg [15:0] m_din,
	input             m_ack,
	input      [15:0] m_dout
);

	localparam G_NONE = 2'd0, G_A = 2'd1, G_B = 2'd2;
	reg [1:0] grant;

	assign a_ack  = (grant == G_A) && m_ack;
	assign b_ack  = (grant == G_B) && m_ack;
	assign a_dout = m_dout;
	assign b_dout = m_dout;

	always @(posedge clk) begin
		if (reset) begin
			grant <= G_NONE;
			m_req <= 1'b0;
			m_we  <= 1'b0;
		end else begin
			case (grant)
			G_NONE: begin
				m_req <= 1'b0;
				if (a_req) begin
					grant  <= G_A;
					m_we   <= a_we;
					m_addr <= a_addr;
					m_din  <= a_din;
				end else if (b_req) begin
					grant  <= G_B;
					m_we   <= b_we;
					m_addr <= b_addr;
					m_din  <= b_din;
				end
			end
			// bundle already registered on the grant edge, so m_req rises one
			// edge after m_addr settled — the shape the port asks for.
			G_A: begin
				m_req <= a_req;
				if (!a_req && !m_req && !m_ack) grant <= G_NONE;
			end
			G_B: begin
				m_req <= b_req;
				if (!b_req && !m_req && !m_ack) grant <= G_NONE;
			end
			default: grant <= G_NONE;
			endcase
		end
	end

endmodule
