/*
 ism_write_engine.v

 The SWIM ISM's MFM WRITE engine: drain the CPU-facing 2-entry FIFO to the
 medium, one byte per byte-time, producing exactly the decoded byte stream
 rtl/mfm_write_decoder.v parses. Plan section 8, stage 2 piece 2.

 Ported from MAME swim1.cpp's ism_sync() write branch, reduced to BYTES. We
 model no flux layer — the SWIM does the data separation on real hardware and
 the CPU only ever sees decoded bytes plus a mark flag, so the read path is
 byte-level and this is its mirror. MAME's Tss/flux encoder and its TIME0/TIME1
 half-cycle pacing have no counterpart here; the byte cadence arrives as `tick`.

 ── WHY THIS IS ITS OWN MODULE ─────────────────────────────────────────────
 It could have lived in swim.v beside the FIFO. It does not, because swim.v is
 1200 lines of delicate ISM READ semantics that took a long time to get right,
 and because everything else in this path (floppy_track_decoder,
 floppy_write_committer, floppy_sd_writer, eth_port_arb) is a small module with
 its own bench. Driving the engine through swim.v would mean spinning a whole
 drive to test one state machine.

 ── THE THREE RULES THAT MATTER ────────────────────────────────────────────
 1. ONE CRC TOKEN EMITS TWO BYTES. The guest pushes a single token (ISM reg 2,
    FIFO bit 9) and the hardware writes both CRC bytes. MAME does it by keeping
    the M_CRC flag in the shift register: `sr = M_CRC | (crc >> 8)` emits the
    high byte, and the NEXT byte-time sees the flag still set and emits
    `crc >> 8` again. That works because feeding the first CRC byte through the
    register leaves the second on top:

        crc16(C, C>>8) == (C & 0x00ff) << 8

    (the XOR clears the top byte, so the eight shifts never trigger the poly).
    `crc_2nd` is that retained flag.

 2. A MARK BYTE IS STILL WRITTEN. MAME shifts its bits out like any other; what
    is special is that it does NOT feed the CRC (`if(!(m_ism_sr & M_MARK))
    ism_crc_update(bit)`) and it RESETS the CRC to 0xCDB4 (`ism_crc_clear()`).
    So the A1s reach the medium and the CRC restarts at the post-A1A1A1 seed.
    mfm_write_decoder.v seeds at every A1 and feeds only from the address mark
    onward — the two must agree or every field we write fails its own CRC.

 3. AN UNDERRUN STOPS THE WRITE. On a pop from an empty FIFO MAME sets error
    bit 0 (0x01 — the write-side code; 0x04 is the CPU-push-full one on the
    read side), calls write_end, and clears ACTION so the engine stops itself.
    `underrun` pulses for the caller to do those two things. MAME guards the
    error with `&& !m_ism_error` — only the FIRST error latches — so the caller
    applies that guard, since it owns the error register.

 Nothing here is armed unless `active`. The caller decides what that means
 ((mode & 0x18) == 0x18 with an MFM write datapath); this module only obeys it,
 and holds its CRC at the seed while idle so every arm starts known.
*/

module ism_write_engine (
	input             clk,
	input             rst,        // synchronous, active high

	input             active,     // the engine owns the head
	input             tick,       // 1 clk, one medium byte-time

	// CPU-facing queue: the head entry and whether there is one.
	// Layout is swim.v's FIFO word: [7:0] data, [8] MARK, [9] CRC token.
	input      [15:0] q_word,
	input             q_empty,
	output            q_pop,      // 1 clk: the caller retires q_word

	// to the medium (floppy.v -> mfm_write_decoder.v)
	output reg  [7:0] o_byte,
	output reg        o_mark,
	output reg        o_stb,      // 1 clk, coincident with `tick`

	// 1 clk: the caller sets error bit 0 (if none pending) and clears ACTION
	output reg        underrun
);

	localparam Q_B_MARK = 8;      // swim.v FIFO_B_MARK
	localparam Q_B_CRC  = 9;      // swim.v FIFO_B_CRC
	localparam [15:0] CRC_SEED = 16'hCDB4;   // CRC over A1 A1 A1

	function [15:0] crc16;
		input [15:0] c;
		input  [7:0] d;
		integer i;
		reg [15:0] cc;
		begin
			cc = c ^ {d, 8'h00};
			for (i = 0; i < 8; i = i + 1)
				cc = cc[15] ? ((cc << 1) ^ 16'h1021) : (cc << 1);
			crc16 = cc;
		end
	endfunction

	reg [15:0] crc;
	reg        crc_2nd;           // MAME's retained M_CRC: the token's 2nd byte

	// A tick consumes a queue entry unless it is generating the second CRC
	// byte (nothing is popped for that one) or the queue is empty (underrun).
	// `active` belongs HERE and not only on the caller's tick: swim.v does
	// gate the tick, but a module that eats the guest's queue when it is not
	// armed is wrong on its own terms, and the bench holds it to that.
	//
	// ★ REGISTERED, NOT COMBINATIONAL, and that is load-bearing. As a `wire`
	// this closes a same-cycle path through the caller: q_pop moves the
	// caller's FIFO level, which is q_empty, which is a term of q_pop. There
	// is a register in the ring so it is not a true combinational loop, but
	// whether the caller's own always block sees the pop on the edge that
	// produced it comes down to evaluation order - and in Icarus it did not:
	// a sibling always block counted 29,721 pops while the block that acts on
	// them counted ZERO, so the FIFO never drained and the engine re-emitted
	// one stale byte 29,689 times. Registering it costs one cycle of latency
	// the caller does not care about (the next tick is a whole byte-time away)
	// and makes the handshake unambiguous in any scheduler.
	//
	// It is still a 1-clk PULSE, and the caller's FIFO block runs on a clock
	// enable (swim.v: cen, one clk in four). The caller holds the pulse in a
	// pending bit until its block takes it - see swim.v `ism_wr_pop_p` - so
	// nothing here may assume which clk the pulse lands on. `underrun` is
	// held the same way.
	reg q_pop_r;
	assign q_pop = q_pop_r;
	wire consume = active && tick && !crc_2nd && !q_empty;

	always @(posedge clk) begin
		o_stb    <= 1'b0;
		underrun <= 1'b0;
		q_pop_r  <= consume;      // one cycle behind the tick that caused it

		if (rst) begin
			q_pop_r <= 1'b0;
			crc     <= CRC_SEED;
			crc_2nd <= 1'b0;
			o_byte  <= 8'h00;
			o_mark  <= 1'b0;
		end else if (!active) begin
			// idle: hold the post-A1A1A1 seed so an arm starts known
			crc     <= CRC_SEED;
			crc_2nd <= 1'b0;
		end else if (tick) begin
			if (crc_2nd) begin
				// second byte of the token: the same expression, because the
				// first byte has shifted the low half up (see the header)
				o_byte  <= crc[15:8];
				o_mark  <= 1'b0;
				o_stb   <= 1'b1;
				crc     <= crc16(crc, crc[15:8]);
				crc_2nd <= 1'b0;
			end else if (q_empty) begin
				// nothing reaches the medium on an underrun — a torn field is
				// better than a field with a wrong byte written into it
				underrun <= 1'b1;
			end else if (q_word[Q_B_CRC]) begin
				o_byte  <= crc[15:8];
				o_mark  <= 1'b0;
				o_stb   <= 1'b1;
				crc     <= crc16(crc, crc[15:8]);
				crc_2nd <= 1'b1;     // one token, two bytes
			end else if (q_word[Q_B_MARK]) begin
				o_byte <= q_word[7:0];
				o_mark <= 1'b1;
				o_stb  <= 1'b1;
				crc    <= CRC_SEED;  // reset, and NOT fed
			end else begin
				o_byte <= q_word[7:0];
				o_mark <= 1'b0;
				o_stb  <= 1'b1;
				crc    <= crc16(crc, q_word[7:0]);
			end
		end
	end

endmodule
