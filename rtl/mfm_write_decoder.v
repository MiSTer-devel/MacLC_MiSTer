/*
 mfm_write_decoder.v

 Recover sectors from the decoded byte stream the guest pushes out through the
 SWIM's ISM write path (1.44 MB HD / 720 KB DD 3.5" MFM). The algebraic inverse
 of rtl/mfm_track_encoder.v, and the MFM counterpart to
 rtl/floppy_track_decoder.v. Byte-level, not flux: the SWIM does the data
 separation, so the CPU only ever sees bytes plus a MARK flag.

 An MFM data field does not name its own sector - it is [A1 A1 A1] FB <512> CRC
 with no C/H/R - so the sector number comes from, in priority order:

   1. a CRC-valid ID field seen in this stream and not yet consumed (the
      format case, where the guest lays down ID+gap+DATA itself). One ID arms
      exactly one data field.
   2. `anchor_sector`, the sector of the ID field last DELIVERED to the guest,
      which is the field the driver read to decide to write here. It is an
      input rather than derived here: a cumulative counter fails by writing
      through to an unrelated sector.

 With neither, a CRC-valid data field is REJECTED. `addr` takes track/side from
 the PHYSICAL inputs and only the sector number from the field, so a field
 claiming a cylinder the head is not on corrupts the current track at worst.
 `amark_cyl`/`amark_head` are exported to police a format, and never steer addr.

 Geometry is the encoder's, so addr is the offset the encoder would read from:
   sector_block = (track*2 + side)*SPT + (R-1)      SPT = 18 (HD) / 9 (DD)
   addr         = sector_block*512
 R is 1-based on the medium, so R == 0 or R > SPT is out of range and refused.
 The bounds check and the address it protects are evaluated in one state, on
 one registered copy of the sector number.

 CRC-16-CCITT, poly 0x1021 MSB-first, seeded 0xCDB4 at the last A1, identical
 to mfm_track_encoder.v. Feeding the two received CRC bytes in leaves 0 when
 the field is intact, so the check is `crc == 0`.
*/

module mfm_write_decoder (
	input             clk,
	input             rst,     // synchronous, active high

	input             ready,   // one incoming written byte per pulse
	input      [7:0]  idata,   // the byte the guest pushed
	input             imark,   // it is an A1 address mark (ISM M_MARK)

	// physical position of the head, and the medium's density
	input             side,
	input      [6:0]  track,
	input             hd,      // 1 = 1.44MB (18 spt), 0 = 720KB (9 spt)

	// positional anchor: the ID field most recently DELIVERED to the guest
	input      [4:0]  anchor_sector,  // 1-based, as on the medium
	input             anchor_valid,

	// pulses for one clk when a data field has been decoded and verified
	output reg        sector_valid,
	output reg [4:0]  sector,     // 1-based sector number written
	output reg [21:0] addr,       // SDRAM byte offset of this sector's byte 0

	// pulses for exactly one clk whenever a field is abandoned
	output reg        reject,

	// an ID field observed in the write stream, CRC-valid (a format)
	output reg        amark,
	output reg [4:0]  amark_sector,
	output reg [6:0]  amark_cyl,
	output reg        amark_head,

	// recovered 512-byte payload of the last completed sector; registered
	// read port (buf_data follows buf_addr by one clock), the protocol
	// floppy_sd.v expects
	input      [8:0]  buf_addr,
	output reg [7:0]  buf_data
);

	// ── CRC-16-CCITT, mfm_track_encoder.v's function verbatim ──────────────
	function [15:0] crc16;
		input [15:0] c;
		input [7:0]  d;
		integer i;
		reg [15:0] cc;
		begin
			cc = c ^ {d, 8'h00};
			for (i = 0; i < 8; i = i + 1)
				cc = cc[15] ? ((cc << 1) ^ 16'h1021) : (cc << 1);
			crc16 = cc;
		end
	endfunction
	localparam [15:0] CRC_SEED = 16'hCDB4;   // CRC over A1 A1 A1

	// ── address marks ──────────────────────────────────────────────────────
	localparam [7:0] AM_ID   = 8'hFE;   // ID address mark
	localparam [7:0] AM_DATA = 8'hFB;   // data address mark
	localparam [7:0] AM_DEL  = 8'hF8;   // deleted-data address mark
	localparam [7:0] BYTE_A1 = 8'hA1;

	// ── the recovered payload ──────────────────────────────────────────────
	reg [7:0] buf_mem [0:511];
	always @(posedge clk) buf_data <= buf_mem[buf_addr];

	// ── geometry, mfm_track_encoder.v's shift-add (no multiplier) ───────────
	wire [7:0]  track_side = {track, side};              // = track*2 + side
	wire [12:0] block_hd   = {track_side, 4'b0000} + {1'b0, track_side, 1'b0};
	wire [12:0] block_dd   = {1'b0, track_side, 3'b000} + {5'b0, track_side};
	wire [12:0] track_base = hd ? block_hd : block_dd;
	wire [4:0]  spt        = hd ? 5'd18 : 5'd9;

	// ── state ──────────────────────────────────────────────────────────────
	localparam S_SYNC = 3'd0,   // outside a field: wait for an A1 mark
	           S_MARK = 3'd1,   // in the A1 run: the next plain byte is the AM
	           S_ID   = 3'd2,   // C H R N
	           S_IDC  = 3'd3,   // the ID field's two CRC bytes
	           S_DATA = 3'd4,   // 512 payload bytes
	           S_DATC = 3'd5;   // the data field's two CRC bytes
	reg [2:0] state;

	reg [15:0] crc;
	reg  [9:0] cnt;             // bytes consumed within the current field
	reg  [2:0] mark_cnt;        // consecutive A1s seen (saturates)

	// the in-stream ID field, held between the ID and the data field it names
	reg        id_armed;
	reg  [4:0] id_sector;
	// ...and the reasons an otherwise CRC-valid ID must arm NOTHING; both
	// are silent-wrong-write paths, so they refuse rather than clamp:
	//   id_oor  - R > 31, which a truncating capture would alias
	//   id_nsz  - N != 2: a size other than 512, but we decode 512 anyway
	reg        id_oor, id_nsz;

	// the identity this data field will be committed under, and its bound,
	// both resolved from ONE registered source in the commit state below
	wire [4:0] use_sector = id_armed ? id_sector : anchor_sector;
	wire       use_valid  = id_armed ? 1'b1      : anchor_valid;
	wire       in_range   = (use_sector != 5'd0) && (use_sector <= spt);
	wire [12:0] block     = track_base + {8'd0, use_sector} - 13'd1;

	always @(posedge clk) begin
		sector_valid <= 1'b0;
		reject       <= 1'b0;
		amark        <= 1'b0;

		if (rst) begin
			state    <= S_SYNC;
			crc      <= 16'd0;
			cnt      <= 10'd0;
			mark_cnt <= 3'd0;
			id_armed <= 1'b0;
			id_sector <= 5'd0;
			id_oor   <= 1'b0;
			id_nsz   <= 1'b0;
			sector   <= 5'd0;
			addr     <= 22'd0;
			amark_sector <= 5'd0;
			amark_cyl    <= 7'd0;
			amark_head   <= 1'b0;
		end else if (ready) begin
			// An A1 mark is a resync point ANYWHERE. A mark arriving mid-field
			// means the field was cut short (the guest stopped, the head left,
			// a splice); abandon it and start the new one rather than folding
			// the mark into the payload.
			if (imark && idata == BYTE_A1) begin
				if (state != S_SYNC && state != S_MARK) reject <= 1'b1;
				state    <= S_MARK;
				mark_cnt <= (mark_cnt == 3'd7) ? mark_cnt : mark_cnt + 3'd1;
				crc      <= CRC_SEED;   // seeded at EVERY A1: the last one wins
				cnt      <= 10'd0;
			end else case (state)

			// ── outside a field ────────────────────────────────────────────
			// Gap and sync bytes (4E, 00) and the IAM (C2 C2 C2 FC, which the
			// encoder deliberately emits WITHOUT the mark flag) all land here
			// and are ignored.
			S_SYNC: mark_cnt <= 3'd0;

			// ── the byte after the A1 run is the address mark ──────────────
			S_MARK: begin
				mark_cnt <= 3'd0;
				// A real field is preceded by three A1s. Fewer means we joined
				// the stream mid-run or the sync was damaged; refuse it rather
				// than decode a field we did not see the start of.
				if (mark_cnt < 3'd3) begin
					reject <= 1'b1;
					state  <= S_SYNC;
				end else begin
					crc <= crc16(crc, idata);
					cnt <= 10'd0;
					case (idata)
					AM_ID:            state <= S_ID;
					AM_DATA, AM_DEL:  state <= S_DATA;
					default: begin
						// an address mark we do not implement
						reject <= 1'b1;
						state  <= S_SYNC;
					end
					endcase
				end
			end

			// ── ID field: C H R N ──────────────────────────────────────────
			S_ID: begin
				crc <= crc16(crc, idata);
				cnt <= cnt + 10'd1;
				case (cnt)
				10'd0: amark_cyl    <= idata[6:0];
				10'd1: amark_head   <= idata[0];
				10'd2: begin
					amark_sector <= idata[4:0];
					id_oor       <= (idata[7:5] != 3'd0);
				end
				default: id_nsz <= (idata != 8'h02);   // N: 2 => 512 bytes
				endcase
				if (cnt == 10'd3) begin cnt <= 10'd0; state <= S_IDC; end
			end

			S_IDC: begin
				crc <= crc16(crc, idata);
				cnt <= cnt + 10'd1;
				if (cnt == 10'd1) begin
					// crc16 of the two received CRC bytes leaves 0 when intact
					if (crc16(crc, idata) == 16'd0 && !id_oor && !id_nsz) begin
						// Arm the data field that follows, and tell the caller
						// an ID field went by (the format relay). amark_* are
						// already registered from S_ID.
						id_armed  <= 1'b1;
						id_sector <= amark_sector;
						amark     <= 1'b1;
					end else begin
						// A corrupt, oversized or wrong-sized ID must not arm
						// anything: the data field behind it falls back to the
						// anchor, or is refused if there is none.
						id_armed <= 1'b0;
						reject   <= 1'b1;
					end
					state <= S_SYNC;
				end
			end

			// ── data field: 512 payload bytes ──────────────────────────────
			S_DATA: begin
				crc <= crc16(crc, idata);
				buf_mem[cnt[8:0]] <= idata;
				cnt <= cnt + 10'd1;
				if (cnt == 10'd511) begin cnt <= 10'd0; state <= S_DATC; end
			end

			S_DATC: begin
				crc <= crc16(crc, idata);
				cnt <= cnt + 10'd1;
				if (cnt == 10'd1) begin
					// ★ ONE STATE: the CRC, the identity, its bound and the
					// address it protects are all decided here, on the same
					// registered use_sector. Nothing downstream re-derives it.
					if (crc16(crc, idata) == 16'd0 && use_valid && in_range) begin
						sector       <= use_sector;
						addr         <= {block, 9'd0};
						sector_valid <= 1'b1;
					end else
						reject <= 1'b1;
					// the ID armed exactly one data field, whatever its outcome
					id_armed <= 1'b0;
					state    <= S_SYNC;
				end
			end

			default: state <= S_SYNC;
			endcase
		end
	end

endmodule
