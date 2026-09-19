// floppy_write_committer.v
//
// Drain a checksum-valid sector recovered by floppy_track_decoder.v into the
// SDRAM image. Ported from MacPlus_MiSTer rtl/floppy_write_committer.v; the
// FSM is theirs unchanged, and the LC differences are marked ★ below.
//
// This is the write-side twin of floppy_loader.v's drain sequence and shares
// the same port protocol (wr_addr/wr_data/wr_req/wr_ack, a LEVEL handshake) —
// see that module's header for why the port recurs roughly every 2us and why a
// whole-word commit sidesteps byte-granular SDRAM enables.
//
// THE READ PORT IS REGISTERED, AND THAT IS WHY THERE ARE THREE FETCH STATES.
// floppy_track_decoder.v's buf_addr/buf_data is a one-clock-latency read port:
// buf_data reflects whatever buf_addr was driven to one cycle earlier. So each
// 16-bit word needs a "let the read catch up" gap PER BYTE, not per word —
// FETCH_LO presents the even address and waits, FETCH_HI captures the now-valid
// even byte AND presents the odd address, ASSERT captures the odd byte and
// issues the word.
//   ★ MacPlus records that an earlier version paired with a COMBINATIONAL
//   decoder read and captured one state earlier throughout; when the decoder's
//   read was later made registered, that silently swapped every byte pair. Keep
//   this module and floppy_track_decoder.v's read latency in sync if either
//   changes. Our decoder is the registered one (`always @(posedge clk) buf_data
//   <= buf_mem[buf_addr]`), so the three-state form is the correct pairing.
//
// BYTE-PAIR -> WORD PACKING: the EVEN-addressed byte lands in the word's HIGH
// half, the ODD-addressed byte in the LOW half. That is not a free choice — it
// is what this core's read path already does, and writing the other way would
// transpose every pair. Verified against both ends before this module was
// written:
//   - read side, MacLC.sv extra_rom_data_demux: odd -> sdram_out[7:0],
//     even -> sdram_out[15:8];
//   - load side, floppy_loader.v sw_data = {dout[7:0], dout[15:8]}, which is
//     {even, odd} given the HPS delivers a little-endian word.
// A sector always starts at a multiple of 512, so byte 0 of a sector is always
// at an EVEN image address and the pairing never shifts.
//
// ★ LC DIFFERENCE — ADDRESSING. MacPlus's port is byte-addressed; this core's
// download write port takes a 24-bit WORD address. This module emits the same
// 22-bit image BYTE offset the read path uses (floppy.v's dskReadAddr
// convention) and leaves the base-add and the >>1 to the caller, so the two
// directions stay symmetrical and only one place knows where the image lives.
//
// ★ PHASE 4: the sd_buf_* persistence tap IS now ported (2026-09-16). It
// mirrors each committed word for rtl/floppy_sd_writer.v, which is what
// actually reaches the user's file. This module itself still only writes
// SDRAM — it has no sd_wr, no notion of the SD card, and no idea whether the
// tap is connected to anything. That separation is deliberate: the volatile
// commit is the part the guest's read-after-write verify exercises, and it
// stays independently testable (verilator/tb_floppy_commit.v) after the
// persistence layer exists.
module floppy_write_committer
(
	input             clk,
	input             rst,          // synchronous, active high — as floppy_loader.v

	// from floppy_track_decoder
	input             sector_valid, // 1-clk pulse: a verified sector is ready
	input      [21:0] sector_addr,  // the decoder's `addr`: image BYTE offset of byte 0
	output reg [8:0]  buf_addr,     // drives the decoder's buf_addr
	input      [7:0]  buf_data,     // the decoder's registered buf_data, 1 clk later

	// SDRAM write port, same LEVEL protocol as floppy_loader.v
	output reg [21:0] wr_addr,      // image BYTE offset of this word's EVEN byte
	output reg [15:0] wr_data,
	output reg        wr_req,       // LEVEL: held until wr_ack
	input             wr_ack,       // LEVEL

	output            busy,
	output reg        done,         // 1-clk pulse: sector fully in SDRAM
	output     [21:0] committed_addr,

	// ── Persistence tap (Phase 4) ───────────────────────────────────────
	// A mirror of the word stream this module is writing to SDRAM, for
	// rtl/floppy_sd_writer.v to shadow and push out to the .dsk on the SD
	// card. It is taken from the SAME registered wr_addr/wr_data the SDRAM
	// port drives, so the two destinations can never disagree about what was
	// committed.
	//   sd_buf_wr follows the LEVEL wr_req, so the shadow word is rewritten on
	// every cycle a word spends waiting for wr_ack. That is harmless — it is
	// the same address and the same data each time — and it keeps this a pure
	// combinational tap with no state of its own to get out of step.
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

			// buf_addr (even) is presented for this whole cycle; the decoder's
			// registered read captures it at this edge and it is valid next
			// cycle. Nothing to sample yet.
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
