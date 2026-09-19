// Mount-time floppy image loader — Phase 1 of docs/floppy_write_plan.md.
//
// Floppies used to arrive as a one-way `ioctl_download` blob into SDRAM
// (plan §2.5), which is a dead end for writing: there is no file handle to
// write back through. This streams the image in as a real SD block device
// instead — on img_mounted, sector by sector via sd_rd, into the SAME SDRAM
// word offsets the read side already expects (dskReadAddrInt/Ext in
// rtl/addrController_top.v), so nothing downstream of SDRAM changes.
//
// STILL READ-ONLY. No sd_wr, no write-back, no WRTPRT change. Phase 1's gate
// is "boots from floppy exactly as before", so a regression here is provably
// plumbing and nothing else.
//
// SDRAM PATH: this drives the sdram.v DOWNLOAD write port (wr_req/wr_ack),
// not a new requester and not addrController_top's extra slot. Plan §6.3 is
// explicit that a new extra-slot requester is the wrong move — MacPlus lost
// two hardware gates to sdram.v's two-phase RAS/CAS sampling doing exactly
// that. The download port is one of the two already-proven LEVEL-handshake
// requesters, and once floppies are block devices its only other user is the
// ROM at boot, which runs with the CPU in reset. MacLC.sv owns the mux.
//
// DC42 NORMALISATION (plan §6.2, decided 2026-09-14): a DiskCopy 4.2 image
// carries an 84-byte header. It is stripped HERE, while streaming, so SDRAM
// holds pure sector data and guest sector N sits at SDRAM word offset N*256.
// 84 bytes = 42 words, so the write address is simply the file word index
// minus 42 and the first 42 words are dropped — no alignment problem, because
// SDRAM is word-addressed. `raw_img` reports whether this was a raw image:
// stage-1 writes are raw-only, so a DC42 mount must present write-protected.
//
// `done` does not fire until the whole image is resident, so the guest can
// never observe a half-loaded disk — the block-device equivalent of the old
// end-of-download latch.
//
// Ported from MacPlus_MiSTer rtl/floppy_loader.v (branch floppy-write) and
// changed where this core differs: the SDRAM port above, DC42 handling
// (MacPlus has no DC42 support at all), and the 13-bit sd_buff_addr this
// core's WIDE hps_io uses.

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
	// ── file block 0's first 42 words, kept for the SD writer (Phase 4b) ──
	// The 84-byte DC42 header is stripped from SDRAM, so it is the one part
	// of file block 0 the SDRAM-sourced writer cannot fetch. Captured here
	// as block 0 streams past at mount, in the INTERNAL (swapped) word
	// convention like everything else in SDRAM. Registered read port:
	// hdr_data is valid the cycle after hdr_addr. Words 36/37 are the data
	// checksum as it stood at mount; the writer substitutes its own.
	input       [5:0] hdr_addr,
	output reg [15:0] hdr_data,
	// ── the MEDIUM's own sidedness, latched with `done` (plan Phase 6B) ──
	// Not the file's size and not the drive's: see rtl/floppy.v's
	// doubleSidedDisk. Sniffed from the volume header as it streams past, so
	// it survives a remount, which is the whole reason it exists.
	output reg        media_ds,
	output reg  [7:0] dc42_fmt       // DC42 byte 0x50: 0=400K 1=800K 2=720K 3=1440K
	                                 // ★ For a DC42 image `size` CANNOT decide the
	                                 // geometry: tags trail the sector data, so an
	                                 // 800K DC42 has 838400 payload bytes, not
	                                 // 819200, and matches no size test. This byte
	                                 // is the discriminator — same as the old
	                                 // download path's dc42_disk_format.
);

	// ── sector staging RAM ────────────────────────────────────────────────
	// sd_buff_wr has no rate limit against on-chip RAM, but the SDRAM side is
	// paced by the download slot, so a sector is captured whole and then
	// drained. Load-then-drain, not double-buffered: correctness first.
	reg [15:0] buf_ram [0:255];
	reg  [7:0] drain_idx;

	// Stored BYTE-SWAPPED. hps_io assigns both paths from the same source —
	// `ioctl_dout <= io_din[DW:0]` (hps_io.sv:692) and
	// `sd_buff_dout <= io_din[DW:0]` (hps_io.sv:405) — so a block-device word
	// packs exactly like a download word, and the read side depends on the
	// swap the old download path applied (MacLC.sv:2544
	// `{ioctl_data[7:0], ioctl_data[15:8]}`). Omitting it transposes every
	// byte pair: the disk mounts and is unreadable.
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

	// DC42 header words, sampled as sector 0 streams past.
	//
	// ★ TESTED ON THE RAW DELIVERED WORD, NOT THE SWAPPED ONE. In the HPS
	// word, bit [7:0] is the FIRST byte of the pair (which is why the storage
	// swap is {d[7:0], d[15:8]}). The proven download path tests raw
	// `ioctl_data` (MacLC.sv:2538-2541) and this must match it exactly:
	//   word 0  byte 0  = d[7:0] : Pascal name length, 1..63
	//   word 40 byte 80 = d[7:0] : disk-format byte (DC42 offset 0x50)
	//   word 41         = d      : the magic, 16'h0001
	// Testing the swapped word instead reads byte 1 for the name length and
	// transposes the magic.
	localparam DC42_HDR_WORDS = 24'd42;   // 84 bytes

	wire [15:0] sw_data = {sd_buff_dout[7:0], sd_buff_dout[15:8]};   // byte swap,
	// matching the old download path's `{ioctl_data[7:0], ioctl_data[15:8]}` —
	// the read side depends on this byte order.

	// ── medium sidedness sniff (plan Phase 6B) ────────────────────────────
	// Ported from MacPlus_MiSTer rtl/floppy_loader.v at b340c9f, with the DC42
	// offset this core needs.
	//
	// WHY IT EXISTS: 400K and 800K are the same medium; nothing on a diskette
	// records which it is, and the file's SIZE is not the answer either -- a
	// One-Sided erase of an 819,200-byte image leaves an 819,200-byte file
	// holding a 400K volume. Deciding sidedness from the size re-advertises
	// that disk as double-sided after a remount, and the driver then builds an
	// 800K volume over a side the erase never wrote (plan section 1.1 defect
	// 2). Within a session the format byte of the last formatted address field
	// covers it; this is the answer ACROSS one.
	//
	// The Master Directory Block lives in sector 2 on MFS and HFS alike, and
	// its volume size is drNmAlBlks * drAlBlkSiz. No usable MDB means
	// double-sided -- an unformatted or foreign medium must not be capped.
	localparam [15:0] MDB_SIG_MFS = 16'hD2D7;
	localparam [15:0] MDB_SIG_HFS = 16'h4244;
	// volume size in 512-byte blocks, midway between 800 and 1600
	localparam [23:0] SIDEDNESS_THRESHOLD = 24'd1200;

	// Word index within the SECTOR, not the file block: a DC42's 84-byte
	// header shifts guest sector 2 down by 42 words, and words 0/9/10/11 of it
	// still land inside file block 2 (indices 42/51/52/53). The subtraction
	// wraps for indices below 42, and no wrapped value can alias 0/9/10/11.
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
				// A mount pulse with a non-zero size starts a load; a zero size
				// is an UNMOUNT and must not start one. Latch readonly here,
				// at THIS slot's own pulse — per-slot latching is the point
				// (plan Phase 1; precedent UK101.sv:274-277).
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
						// CEIL, not floor (plan Phase 6D, 2026-09-19). A DC42
						// file is 84 + payload bytes and never ends on a block
						// boundary, so a floor here silently dropped the last
						// 84 bytes of the last sector of every TAGLESS DC42 --
						// latent for HFS (the volume's last block is unused),
						// wrong for DOS. Main serves the partial block: its
						// read path is FileReadAdv into the whole buffer, and
						// a short count is still truthy, so the block arrives
						// with the file's true tail at the front and Main's
						// stale buffer behind it (user_io.cpp:3556).
						//
						// The stale remainder is drained to SDRAM past the
						// payload end -- 428 bytes for a tagless 1.44MB DC42,
						// 214 words. The floppy region is $600000-$6FFFFF,
						// 1M words, and the largest payload it holds (a
						// tagged 1.44MB DC42, 1,509,120 bytes = 736.9K words)
						// leaves that slack many times over.
						//
						// Raw images are always 512-multiples, so ceil == floor
						// and nothing about them changes.
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
				// hps_io raises sd_ack when it picks the transfer up and drops
				// it once the sector has been delivered. DROP THE REQUEST ON
				// THE RISING EDGE, not at the end: this core's own SCSI does
				// exactly that (rtl/scsi.v:1847 `if(io_ack) io_rd_d <= 1'b0;`,
				// with completion tracked separately off the falling edge).
				// Holding sd_rd up for the whole transfer leaves the request
				// still asserted when hps_io next samples it, and it re-issues
				// the same LBA.
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
