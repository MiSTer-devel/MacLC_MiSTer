/*
 mfm_track_encoder.v

 Generate a full IBM System/34 MFM floppy track (DECODED byte stream) on the fly
 from raw logical sectors, for the SWIM ISM-mode read path (1.44 MB HD / 720 KB DD
 3.5" disks). This is the MFM counterpart to floppy_track_encoder.v (which does
 Apple GCR for the IWM-mode 400K/800K path) — the two are independent.

 WHY BYTE-LEVEL (not flux/bit-level): on real hardware the SWIM does the MFM data
 separation and the CPU only ever sees DECODED bytes + "mark" flags via the ISM
 FIFO. So we generate exactly that decoded stream. The consumer (swim.v ISM read
 path) pulls one byte per `ready` pulse and pushes {mark, crc0, byte} into the
 FIFO. Grounded in MAME swim1.cpp + docs/swim_ism_read_reference.md; the input
 sector layout (logical 512-byte sectors, in order) is confirmed by the DC42
 container (rusty-backup src/rbformats/dc42.rs).

 Track layout (MAME pc_dsk 1.44M tuple; gaps {gap4a=80, gap1=50, gap2=22, gap3=108}):

 Track preamble, once per revolution (the index pulse rides on it — see oindex):
   4E x80  (gap 4a)
   00 x12  (sync)
   C2 C2 C2 FC  (IAM — delivered as PLAIN bytes: SWIM1/Snow sync only on the
                 A1/0x4489 pattern, so C2 must NOT carry the mark flag)
   4E x50  (gap 1)

 Per sector (x18 HD / x9 DD), from MAME upd765_dsk get_desc_mfm:
   00 x12  (sync)
   A1 A1 A1   <- delivered as MARK bytes (omark=1)
   FE         (ID address mark)
   C H R N    (cyl, head, sector[1-based], N=2 => 512B)
   CRChi CRClo   (CRC-16-CCITT over [A1 A1 A1 FE C H R N], i.e. seed 0xCDB4 + FE..N)
   4E x22  (gap 2)
   00 x12  (sync)
   A1 A1 A1   <- MARK bytes
   FB         (data address mark)
   <512 data bytes>
   CRChi CRClo   (CRC over [A1 A1 A1 FB <512>], seed 0xCDB4 + FB + data)
   4E x108 (gap 3)
 = 682 bytes/sector. 18*682+146 = 12422 bytes/track; at 16us/byte ~= 198.8ms
 ~= 302 RPM (the driver verifies drive speed via the index period, so the
 preamble length is load-bearing, not cosmetic).

 Sector image address (logical, no interleave): the data fork stores sectors in
 (cyl, head, sector) order, so
   byte = ((track*2 + side)*SPT + sector)*512 + offset      SPT=18 (HD) / 9 (DD)
 Max for 1.44M: ((79*2+1)*18+17)*512+511 = 1,474,559 -> fits 22-bit addr.

 The track free-runs (a spinning disk); the SWIM/driver resyncs on the A1 marks.
 Byte cadence (16us HD / 32us DD) is set by the consumer's pacing of `ready`,
 not here — this module is rate-agnostic.
*/

/* verilator lint_off UNUSED */

module mfm_track_encoder
(
	input             clk,
	input             ready,   // pull: advance to the next track byte (1-clk pulse)
	input             rst,

	input             side,    // current head (0/1)
	input      [6:0]  track,   // current cylinder (0..79)
	input             hd,      // 1 = 1.44MB (18 spt), 0 = 720KB (9 spt)

	output     [21:0] addr,    // byte address into the disk image (logical sectors)
	input      [7:0]  idata,   // sector data byte at `addr` (externally latched)

	output reg [7:0]  odata,   // current decoded MFM byte
	output reg        omark,   // current byte is an address-mark (A1) -> ISM M_MARK
	output reg        ocrc0,   // current byte completes a valid CRC field -> ISM M_CRC0
	output            oneeds,  // current byte is sector payload (odata = idata):
	                           // the consumer must not deliver it until the SDRAM
	                           // fetch for `addr` has landed in idata
	output            oindex   // physical index "hole": high during gap 4a (80
	                           // bytes = 1.28ms low pulse on the !idx sense =
	                           // 0.64% duty, vs 0.70% in the MAME 0.264 capture)
);

	// ---- sector geometry ----------------------------------------------------
	wire [7:0] track_side = {track, side};            // = track*2 + side
	wire [4:0] spt_max    = hd ? 5'd17 : 5'd8;        // last sector index (18 / 9 spt)

	// sector_block = track_side*SPT + sector, via shift-add (no multiplier).
	//   *18 = <<4 + <<1 ;  *9 = <<3 + <<0
	wire [12:0] block_hd = {track_side, 4'b0000} + {1'b0, track_side, 1'b0};
	wire [12:0] block_dd = {1'b0, track_side, 3'b000} + {5'b0, track_side};
	wire [12:0] sector_block = (hd ? block_hd : block_dd) + {8'b0, sector};

	// addr = sector_block*512 + src_offset  (block in [21:9], offset in [8:0])
	assign addr = {sector_block[12:0], src_offset[8:0]};

	// ---- CRC-16-CCITT (poly 0x1021, MSB-first), one byte ---------------------
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
	// Seed 0xCDB4 == CRC-CCITT(0xFFFF) over A1 A1 A1 (verified), so we seed at the
	// last A1 and feed only FE.. / FB.. (the marks are not re-fed).
	localparam [15:0] CRC_SEED = 16'hCDB4;

	// ---- track byte-emission state machine ----------------------------------
	localparam S_PRE_GAP  = 4'd0;   // 80 x 4E (gap 4a) — once per revolution
	localparam S_PRE_SYNC = 4'd1;   // 12 x 00
	localparam S_PRE_IAM  = 4'd2;   // 4  : C2 C2 C2 FC (plain bytes, no mark)
	localparam S_PRE_GAP1 = 4'd3;   // 50 x 4E (gap 1)
	localparam S_ID_SYNC  = 4'd4;   // 12 x 00
	localparam S_ID_A1    = 4'd5;   // 3  x A1 (mark)
	localparam S_ID_AM    = 4'd6;   // 1  x FE
	localparam S_ID_CHRN  = 4'd7;   // 4  : C H R N
	localparam S_ID_CRC   = 4'd8;   // 2  : CRC hi/lo
	localparam S_GAP2     = 4'd9;   // 22 x 4E
	localparam S_DA_SYNC  = 4'd10;  // 12 x 00
	localparam S_DA_A1    = 4'd11;  // 3  x A1 (mark)
	localparam S_DA_AM    = 4'd12;  // 1  x FB
	localparam S_DATA     = 4'd13;  // 512: payload
	localparam S_DA_CRC   = 4'd14;  // 2  : CRC hi/lo
	localparam S_GAP3     = 4'd15;  // 108 x 4E

	reg [3:0] state;
	reg [9:0] cnt;          // byte index within the current state (max 511)
	assign oneeds = (state == S_DATA);
	assign oindex = (state == S_PRE_GAP);
	reg [4:0] sector;       // current sector index (0..spt_max)
	reg [8:0] src_offset;   // byte within the current sector's data (0..511)
	reg [15:0] crc;

	// length-1 of the current state's byte run
	reg [9:0] state_len_m1;
	always @(*) begin
		case (state)
			S_PRE_GAP:  state_len_m1 = 10'd79;   // 80
			S_PRE_SYNC: state_len_m1 = 10'd11;   // 12
			S_PRE_IAM:  state_len_m1 = 10'd3;    // 4
			S_PRE_GAP1: state_len_m1 = 10'd49;   // 50
			S_ID_SYNC:  state_len_m1 = 10'd11;   // 12
			S_ID_A1:    state_len_m1 = 10'd2;    // 3
			S_ID_AM:    state_len_m1 = 10'd0;    // 1
			S_ID_CHRN:  state_len_m1 = 10'd3;    // 4
			S_ID_CRC:   state_len_m1 = 10'd1;    // 2
			S_GAP2:     state_len_m1 = 10'd21;   // 22
			S_DA_SYNC:  state_len_m1 = 10'd11;   // 12
			S_DA_A1:    state_len_m1 = 10'd2;    // 3
			S_DA_AM:    state_len_m1 = 10'd0;    // 1
			S_DATA:     state_len_m1 = 10'd511;  // 512
			S_DA_CRC:   state_len_m1 = 10'd1;    // 2
			default:    state_len_m1 = 10'd107;  // S_GAP3: 108
		endcase
	end

	// CHRN field bytes (cyl, head, sector[1-based], N=2 for 512B)
	reg [7:0] chrn;
	always @(*) begin
		case (cnt[1:0])
			2'd0:    chrn = {1'b0, track};        // C: cylinder 0..79
			2'd1:    chrn = {7'b0, side};         // H: head 0/1
			2'd2:    chrn = {3'b0, sector + 5'd1};// R: sector, 1-based
			default: chrn = 8'h02;                // N: 128<<2 = 512
		endcase
	end

	// current decoded byte + flags (combinational from state/cnt)
	always @(*) begin
		omark = 1'b0;
		ocrc0 = 1'b0;
		case (state)
			S_PRE_SYNC,
			S_ID_SYNC, S_DA_SYNC: odata = 8'h00;
			S_PRE_GAP, S_PRE_GAP1,
			S_GAP2, S_GAP3:       odata = 8'h4E;
			S_PRE_IAM:            odata = (cnt == 10'd3) ? 8'hFC : 8'hC2;
			S_ID_A1, S_DA_A1: begin odata = 8'hA1; omark = 1'b1; end
			S_ID_AM:              odata = 8'hFE;
			S_DA_AM:              odata = 8'hFB;
			S_ID_CHRN:            odata = chrn;
			S_DATA:               odata = idata;
			S_ID_CRC, S_DA_CRC: begin
				odata = (cnt[0] == 1'b0) ? crc[15:8] : crc[7:0];
				ocrc0 = (cnt[0] == 1'b1);   // 2nd CRC byte -> running CRC == 0 here
			end
			default:              odata = 8'h4E;
		endcase
	end

	// advance on each `ready` pull; update CRC over the byte just consumed
	always @(posedge clk or posedge rst) begin
		if (rst) begin
			state      <= S_PRE_GAP;
			cnt        <= 10'd0;
			sector     <= 5'd0;
			src_offset <= 9'd0;
			crc        <= CRC_SEED;
		end else if (ready) begin
			// --- CRC: seed at the last A1, update over FE..N and FB..data ---
			if ((state == S_ID_A1 || state == S_DA_A1) && cnt == 10'd2)
				crc <= CRC_SEED;                       // consumed 3rd A1 -> seed
			else if (state == S_ID_AM || state == S_ID_CHRN ||
			         state == S_DA_AM || state == S_DATA)
				crc <= crc16(crc, odata);              // field byte -> fold in

			// --- DATA fetch pointer ---
			if (state == S_DATA)
				src_offset <= src_offset + 9'd1;
			else if (state != S_DATA)
				src_offset <= 9'd0;                    // park at sector base during preamble

			// --- state / sector advance ---
			if (cnt == state_len_m1) begin
				cnt <= 10'd0;
				if (state == S_GAP3) begin
					if (sector == spt_max) begin
						sector <= 5'd0;
						state  <= S_PRE_GAP;   // revolution wrap: emit the track preamble
					end else begin
						sector <= sector + 5'd1;
						state  <= S_ID_SYNC;
					end
				end else begin
					state <= state + 4'd1;
				end
			end else begin
				cnt <= cnt + 10'd1;
			end
		end
	end

endmodule
