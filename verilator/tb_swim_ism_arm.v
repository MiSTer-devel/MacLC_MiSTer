/* tb_swim_ism_arm.v — Stage 2: the CPU-SIDE half of the MFM write path.
 *
 * The other three benches all start downstream of the guest. This one starts
 * where the guest does: at the SWIM's register file, driven over the CPU bus
 * the way the Sony driver drives it. It is the bench that was missing when
 * pieces 1-3 were written, and it covers the two things that were until now
 * asserted only by inspection:
 *
 *   1. WHAT ARMS THE WRITE ENGINE. MAME's ism_write() enters write mode when
 *      (mode & 0x18) becomes 0x18 — ACTION *and* WRITE, not WRITE alone — and
 *      leaves when it stops being 0x18. Mode is SET through reg 7 and CLEARED
 *      through reg 6, so arming is a read-modify-write across two registers
 *      and getting it wrong in either direction is invisible downstream: arm
 *      too eagerly and the engine eats the guest's FIFO during a READ; arm too
 *      reluctantly and every write hangs on the unbounded Handshake b7 poll
 *      (plan §6.4 — that hang is the reason Phase 3a got its own hardware run).
 *
 *   2. THE RING -> ANCHOR HOP. floppy.v tags each delivered byte with its
 *      sector; swim.v carries that tag in staging-ring bits [15:11] and latches
 *      it as the anchor when the CPU POPS the byte. tb_mfm_write_path proves
 *      the tag is right and that the decoder honours an anchor, but the hop
 *      between them — the part that makes the anchor the byte the DRIVER read
 *      rather than wherever the head now is — lives here and was untested.
 *
 * ★ SECTION 5 IS THE ONE TO READ. It does what the driver does: read ID bytes
 *   in read mode, then switch to write mode and write a data field. The sector
 *   it lands on must be the one whose ID field the CPU actually POPPED. The
 *   head keeps turning throughout, so a design that sampled the live position
 *   anywhere in that chain puts the sector somewhere else.
 *
 * ★ THE HANDSHAKE INVERTS (section 3), and it is not cosmetic. In read mode
 *   b7 means "data available"; in write mode it means "space available"
 *   (swim1.cpp: fifo_pos==0 -> 0xc0, ==1 -> 0x80). The driver's write loop
 *   polls b7 in an unbounded loop, so an uninverted handshake is a hang, not a
 *   failed write.
 *
 * The drive is given a shortened byte cadence through floppy.v's MFM_PERIOD_*
 * parameters — see tb_mfm_write_path.v's header for why that is necessary and
 * why it is safe.
 *
 * ★ INVARIANCE MUTANT (review 2026-09-17): delay the engine's q_pop by ONE
 *   more clk (`reg q_pop_r2; always @(posedge clk) q_pop_r2 <= q_pop_r;
 *   assign q_pop = q_pop_r2;` in ism_write_engine.v) and this bench must
 *   STILL PASS. swim.v's FIFO block runs on cen, so before the pending latch
 *   (`ism_wr_pop_p`) that mutant lost every pop and the underrun with it:
 *   22,475 bytes to the medium, nothing committed, ACTION never cleared - a
 *   8/27 FAIL that proved the shipped RTL worked only by cep/cen phase luck.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_swim_ism_arm \
 *     -o scratch/mfm/tb_arm.vvp verilator/tb_swim_ism_arm.v \
 *     rtl/swim.v rtl/ism_write_engine.v rtl/floppy.v \
 *     rtl/floppy_track_encoder.v rtl/mfm_track_encoder.v \
 *     rtl/floppy_track_decoder.v rtl/mfm_write_decoder.v \
 *     rtl/floppy_write_committer.v
 *   /c/iverilog/bin/vvp scratch/mfm/tb_arm.vvp
 */
`timescale 1ns/1ps

module tb_swim_ism_arm;

   reg clk = 0;
   always #5 clk = ~clk;
   reg [1:0] ph = 0;
   always @(posedge clk) ph <= ph + 2'd1;
   wire cep = (ph == 2'd3);      // clk8_en_p = busPhase==3
   wire cen = (ph == 2'd1);      // clk8_en_n = busPhase==1

   integer checks = 0, fails = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

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
   localparam [15:0] CRC_SEED = 16'hCDB4;

   // ── CPU bus ────────────────────────────────────────────────────────────
   reg        _reset     = 0;
   reg        selectSWIM = 0;
   reg        _cpuRW     = 1;
   reg        _cpuUDS    = 1;
   reg [15:0] dataIn     = 16'd0;
   reg  [3:0] addr       = 4'd0;
   wire [15:0] dataOut;
   // The internal disk's encoding. MFM for sections 1-6; section 7 flips it to
   // GCR to put the SWIM in the state the Phase 6 gate 4a probe found.
   reg  [1:0] diskMFM = 2'b01;

   wire [21:0] dskReadAddrInt, dskReadAddrExt;
   wire  [7:0] dskReadData = dskReadAddrInt[7:0] ^ dskReadAddrInt[15:8];

   wire [21:0] wrSdAddr, wrCommitAddr;
   wire [15:0] wrSdData;
   wire        wrSdReq, wrCommitDone;
   reg         wrSdAck = 0;
   always @(posedge clk) wrSdAck <= wrSdReq & ~wrSdAck;

   reg [15:0] img [0:8191];
   always @(posedge clk) if (wrSdReq && wrSdAck) img[wrSdAddr[13:1]] <= wrSdData;

   // The internal drive runs at the real 129-cep byte cadence, which makes a
   // 512-byte field unaffordable in Icarus (see tb_mfm_write_path.v's header).
   // swim.v instantiates it, so the bench reaches in with defparam rather than
   // adding a pass-through parameter to swim.v for test convenience only.
   defparam dut.floppyInt.MFM_PERIOD_HD = 9'd15;
   defparam dut.floppyInt.MFM_PERIOD_DD = 9'd31;
   defparam dut.WR_VOID_PERIOD = 9'd31;            // section 7's void cadence

   swim dut (
      .clk(clk), .cep(cep), .cen(cen), ._reset(_reset),
      .selectSWIM(selectSWIM), ._cpuRW(_cpuRW), ._cpuUDS(_cpuUDS),
      .dataIn(dataIn), .cpuAddrRegHi(addr), .dataOut(dataOut),
      .SEL(1'b0), .driveSel(1'b0),
      .insertDisk(2'b01),        // internal drive only
      .diskSides(2'b11), .mediaSides(2'b11), .diskMFM(diskMFM), .diskHD(2'b01),
      .writeProtect(2'b10),      // internal drive writable, external locked
      .dskReadAddrInt(dskReadAddrInt), .dskReadAckInt(1'b1),
      .dskReadAddrExt(dskReadAddrExt), .dskReadAckExt(1'b1),
      .dskReadData(dskReadData),
      .wrSdAddr(wrSdAddr), .wrSdData(wrSdData), .wrSdReq(wrSdReq), .wrSdAck(wrSdAck),
      .wrCommitDone(wrCommitDone), .wrCommitAddr(wrCommitAddr)
   );

   // ── the CPU access protocol ────────────────────────────────────────────
   // swim.v latches the access while _cpuUDS is low and commits side effects
   // ONCE, at the deassert edge (`acc_end`). So an access must be held for a
   // few clocks and then released - a single-cycle poke commits nothing.
   task cpu_write(input [3:0] a, input [7:0] d);
      begin
         @(posedge clk);
         #1 selectSWIM = 1; _cpuUDS = 0; _cpuRW = 0; addr = a; dataIn = {8'h00, d};
         repeat (4) @(posedge clk);
         #1 selectSWIM = 0; _cpuUDS = 1; _cpuRW = 1;
         repeat (4) @(posedge clk);
      end
   endtask

   reg [7:0] rd;
   task cpu_read(input [3:0] a);
      begin
         @(posedge clk);
         #1 selectSWIM = 1; _cpuUDS = 0; _cpuRW = 1; addr = a;
         repeat (3) @(posedge clk);
         #1 rd = dataOut[15:8];         // SWIM is on the UPPER byte on the LC
         @(posedge clk);
         #1 selectSWIM = 0; _cpuUDS = 1;
         repeat (4) @(posedge clk);
      end
   endtask

   // the IWM->ISM switch: four offset-0xF writes, data bit6 = 1,0,1,1
   task enter_ism;
      begin
         cpu_write(4'hF, 8'h40);
         cpu_write(4'hF, 8'h00);
         cpu_write(4'hF, 8'h40);
         cpu_write(4'hF, 8'h40);
      end
   endtask

   task mode_set  (input [7:0] m); begin cpu_write(4'h7, m); end endtask
   task mode_clear(input [7:0] m); begin cpu_write(4'h6, m); end endtask

   // ── witnesses on the medium side ───────────────────────────────────────
   integer n_sv = 0;
   reg err_ovf = 0;
   integer n_wr_bytes = 0, n_commit = 0, n_unr = 0, n_rej = 0, n_pop = 0, n_tick = 0;
   reg [21:0] last_commit;
   always @(posedge clk) begin
      if (dut.mfm_wr_stb) n_wr_bytes = n_wr_bytes + 1;
      if (dut.ism_wr_underrun) n_unr = n_unr + 1;
      if (dut.floppyInt.wrpath.mdec.reject) n_rej = n_rej + 1;
      if (dut.floppyInt.wrpath.mdec.sector_valid) n_sv = n_sv + 1;
      if (dut.ism_wr_pop) n_pop = n_pop + 1;
      if (dut.ism_wr_tick) n_tick = n_tick + 1;
      if (dut.ism_error[2]) err_ovf = 1;
      if (wrCommitDone) begin n_commit = n_commit + 1; last_commit = wrCommitAddr; end
   end

   // ★ FEED THE ENGINE THE WAY THE DRIVER DOES: poll Handshake b7 for space,
   // then push. A fixed delay cannot work - too short overruns the 2-entry
   // FIFO (error 0x04), too long starves the engine and ends the write on an
   // underrun mid-field. The driver's own loop is this poll, so using it here
   // exercises the write-mode handshake in anger rather than by inspection.
   integer push_polls, push_giveups;
   task fifo_push(input [3:0] reg_n, input [7:0] d);
      integer g;
      begin
         g = 0;
         cpu_read(4'h7);
         while (!rd[7] && g < 300) begin
            cpu_read(4'h7);
            g = g + 1;
         end
         // ★ NEVER push blind. An earlier version pushed anyway when the poll
         // gave up; the byte that got dropped was the CRC TOKEN, so the field
         // went out with no CRC, the engine underran where the CRC should
         // have been, and the decoder simply never completed a field - no
         // reject, no commit, nothing to see. Counted and asserted instead.
         if (!rd[7]) push_giveups = push_giveups + 1;
         push_polls = push_polls + g;
         cpu_write(reg_n, d);
      end
   endtask

   integer i, guard;
   reg [15:0] k;
   reg [4:0]  anchor_seen;
   reg [12:0] exp_block;
   reg [7:0]  hs_read, hs_write;

   initial begin
      repeat (20) @(posedge clk);
      #1 _reset = 1;
      repeat (20) @(posedge clk);

      // ─── 1. the IWM -> ISM switch ───────────────────────────────────────
      $display("1. the 1,0,1,1 offset-F sequence enters ISM mode");
      check(dut.ism_mode === 1'b0, "the SWIM starts in IWM mode");
      enter_ism;
      check(dut.ism_mode === 1'b1, "four 0xF writes with bit6 1,0,1,1 enter ISM");
      check(dut.ism_mode_reg === 8'h40, "and the mode register comes up as ISM-select only");

      // ─── 2. ACTION alone does NOT arm the write engine ──────────────────
      // ★ THESE SECTIONS HOLD THE ENGINE INERT with Setup bit6 (the WRITE-side
      // datapath select: 1 = TSM/GCR, which is not stage 2). That separates
      // the two halves of arming and makes the test deterministic. Arming a
      // LIVE engine against an empty FIFO underruns within one byte-time and
      // the engine clears ACTION itself, so `ism_write_active` is only stable
      // for a race window - a real driver primes the FIFO first, and so does
      // section 5. `ism_write_arm` is the pure (mode & 0x18) condition.
      $display("2. ACTION without WRITE is a READ arm, and must not arm writes");
      cpu_write(4'h5, 8'h60);            // Setup: IBM + GCR write select (inert)
      mode_set(8'hC0);                   // motor on + ISM select
      mode_set(8'h02);                   // drive select code
      mode_set(8'h08);                   // ACTION
      repeat (200) @(posedge clk);
      check(dut.ism_write_arm === 1'b0,
            "(mode & 0x18) == 0x08 is a read arm, not a write arm");
      n_wr_bytes = 0;
      repeat (2000) @(posedge clk);
      check(n_wr_bytes == 0, "and no byte may reach the medium");

      // ─── 3. the handshake inverts on the MODE bit ───────────────────────
      $display("3. Handshake b7/b6 invert when WRITE is set");
      cpu_read(4'h7);
      hs_read = rd;
      check(hs_read[7] === 1'b0,
            "READ mode, empty FIFO: b7 = 0, no data available");
      mode_set(8'h10);                   // -> mode & 0x18 == 0x18
      repeat (40) @(posedge clk);
      check(dut.ism_write_arm === 1'b1, "ACTION+WRITE is the write arm");
      check(dut.ism_write_active === 1'b0,
            "but Setup b6 still gates the MFM engine off");
      cpu_read(4'h7);
      hs_write = rd;
      check(hs_write[7] === 1'b1 && hs_write[6] === 1'b1,
            "WRITE mode, empty FIFO: b7|b6 = all space free");
      // The inversion follows ism_mode_reg[4] alone, not the engine - which is
      // why it is still observable with the engine held inert here.

      // ─── 4. leaving 0x18 disarms ────────────────────────────────────────
      $display("4. clearing either bit leaves write mode");
      mode_clear(8'h10);                 // drop WRITE, keep ACTION
      repeat (40) @(posedge clk);
      check(dut.ism_write_arm === 1'b0, "clearing WRITE disarms");
      mode_set(8'h10);
      repeat (40) @(posedge clk);
      check(dut.ism_write_arm === 1'b1, "and setting it again re-arms");
      mode_clear(8'h08);                 // drop ACTION, keep WRITE
      repeat (40) @(posedge clk);
      check(dut.ism_write_arm === 1'b0, "clearing ACTION disarms it too");
      check(dut.ism_mode_reg[4] === 1'b1, "with WRITE itself still set");

      // ─── 5. ★ read an ID field, then write: the anchor is what was POPPED
      $display("5. the anchor is the sector of the byte the CPU actually popped");
      // back to read mode and let the ring fill
      mode_clear(8'h10);
      mode_set(8'h08);
      repeat (4000) @(posedge clk);
      // pop bytes until the anchor has been established
      guard = 0;
      while (dut.ism_anchor_ok !== 1'b1 && guard < 400) begin
         cpu_read(4'h1);                 // reg1: pop without the mark-error
         repeat (40) @(posedge clk);
         guard = guard + 1;
      end
      check(dut.ism_anchor_ok === 1'b1, "popping a delivered byte establishes the anchor");
      anchor_seen = dut.ism_anchor_sector;
      check(anchor_seen >= 5'd1 && anchor_seen <= 5'd18,
            "and it names a sector that exists on the medium");

      // Now write a data field for that sector. The head keeps turning while
      // we do, so anything that sampled the LIVE position would drift.
      exp_block = (0 * 2 + 0) * 18 + (anchor_seen - 1);   // track 0, side 0
      // ★ LEAVE READ MODE AND CLEAR THE FIFO FIRST. While ACTION is set for a
      // read the ring is still draining delivered bytes into the FIFO, so
      // priming on top of that overflows it (error 0x04) and the field goes
      // out a byte short - which reads downstream as a CRC failure and looks
      // like a decoder bug. Mode bit0 is the FIFO clear the driver uses.
      mode_clear(8'h08);                 // stop the read
      mode_set(8'h01);                   // clear FIFO (and, here, the ring)
      mode_clear(8'h01);
      cpu_write(4'h5, 8'h20);            // Setup: IBM + MFM write - engine live
      check(dut.ism_fifo_pos === 2'd0, "the FIFO really is empty before priming");
      // The error register is STICKY and the read-phase polling will have set
      // 0x04 (popping an empty FIFO is normal while hunting). Clear it here so
      // the write phase's own errors are the only ones this section sees.
      cpu_read(4'h2);
      err_ovf = 0;
      // ★ PRIME THE FIFO BEFORE ARMING. An armed engine with an empty FIFO
      // underruns on its very next byte-time and stops the write (section 6);
      // the driver fills first and then sets WRITE, so the bench does too.
      cpu_write(4'h0, 8'h00);
      cpu_write(4'h0, 8'h00);
      mode_set(8'h18);                   // ACTION + WRITE together -> armed
      repeat (20) @(posedge clk);
      check(dut.ism_write_active === 1'b1, "the engine is armed for the field");
      n_commit = 0; n_rej = 0; n_wr_bytes = 0; n_pop = 0; n_tick = 0; n_sv = 0;
      err_ovf = 0; push_giveups = 0;
      push_polls = 0;
      for (i = 0; i < 10; i = i + 1) fifo_push(4'h0, 8'h00);   // rest of sync
      for (i = 0; i < 3;  i = i + 1) fifo_push(4'h1, 8'hA1);   // marks (reg1)
      fifo_push(4'h0, 8'hFB);                                  // data AM
      for (i = 0; i < 512; i = i + 1) fifo_push(4'h0, i[7:0] ^ 8'h5A);
      fifo_push(4'h2, 8'h00);            // reg2 = the CRC token: TWO bytes
      // The committer drains 256 words through a 3-state-per-word fetch and a
      // LEVEL SDRAM handshake; that is ~1000 cycles after the last byte, so
      // this settle time is not slack, it is the commit itself.
      repeat (6000) @(posedge clk);
      $display("   (bytes to medium: %0d, decoder accepted: %0d, committed: %0d)",
               n_wr_bytes, n_sv, n_commit);
      check(push_polls > 0,
            "the guest really had to wait on b7 - the engine paced the write");
      check(push_giveups == 0, "the guest never had to push blind - every byte was accepted");
      check(!err_ovf, "no CPU push was dropped on a full FIFO (error 0x04)");
      check(n_commit == 1, "the field the guest wrote committed exactly once");
      check(last_commit === {exp_block, 9'd0},
            "at the ANCHOR's sector - the one whose byte the CPU popped");

      // ─── 6. an underrun stops the write and reports 0x01 ────────────────
      // The field above ends with the engine armed and the FIFO empty, so the
      // very next byte-time starves it. That is not a flaw in the test - it is
      // what happens on real hardware at the end of every written field, and
      // it is how the write stops.
      $display("6. a starved engine raises error 0x01 and clears ACTION itself");
      repeat (2000) @(posedge clk);
      check(n_unr >= 1, "running out of bytes raises an underrun");
      check(dut.ism_mode_reg[3] === 1'b0, "ACTION was cleared by the engine itself");
      check(dut.ism_write_active === 1'b0, "so the engine disarmed");
      cpu_read(4'h2);                    // reg2 read = error, clears on read
      check(rd[0] === 1'b1, "error bit 0 (0x01) is the write-underrun code");
      cpu_read(4'h2);
      check(rd[0] === 1'b0, "and reading the error register clears it");

      // ─── 7. ★ a NON-MFM disk under an MFM write: the engine still drains
      // Phase 6 gate 4a (2026-09-19, fit c447fbe9): an 800K GCR image erased
      // as DOS 720K HUNG the machine. The file size pins the encoding, so
      // mfm_disk is 0, floppy.v's MFM byte timer never runs, the engine never
      // pops, and the ROM's format loop at $A6F130 - `move.b (a4),d0 / bpl`
      // on Handshake b7, which tests FIFO SPACE and nothing else - polls
      // forever against the two gap bytes it primed. Raising an underrun
      // would not help: that clears ACTION but leaves the FIFO full, so b7
      // stays 0 (section 6 ends in exactly that state). The engine must keep
      // POPPING at the byte cadence with no medium behind it; nothing can
      // commit because floppy.v's wrIsMfm mux only takes MFM sectors for an
      // MFM file, and the ROM's own 13,500-byte wait-for-index timeout then
      // ends the format with an error instead of a hang.
      $display("7. a write over a non-MFM disk drains the FIFO into the void (gate 4a)");
      diskMFM = 2'b00;                   // the internal file is 819,200 B: GCR
      repeat (40) @(posedge clk);
      mode_set(8'h01);                   // clear FIFO
      mode_clear(8'h01);
      cpu_read(4'h2);                    // clear the sticky error
      check(dut.floppyInt.mfm_spinning === 1'b0,
            "the MFM read path is parked: this disk is not MFM");
      // the ROM's format prologue: prime two gap bytes, then ACTION+WRITE
      cpu_write(4'h0, 8'h4E);
      cpu_write(4'h0, 8'h4E);
      mode_set(8'h18);
      repeat (20) @(posedge clk);
      check(dut.ism_write_active === 1'b1,
            "armed with the FIFO full - the state the hardware probe found");
      n_commit = 0; n_wr_bytes = 0; n_pop = 0; n_tick = 0; n_sv = 0; n_rej = 0;
      n_unr = 0; push_polls = 0; push_giveups = 0; err_ovf = 0;
      // the ROM's gap loop: poll b7, push $4E, repeat (it allows 13,500)
      for (i = 0; i < 60; i = i + 1) fifo_push(4'h0, 8'h4E);
      check(push_giveups == 0,
            "Handshake b7 comes back every byte - the ROM's bpl loop is released");
      check(push_polls > 0, "and the guest is paced, not free-running");
      check(n_pop >= 60, "every gap byte was popped by the engine");
      check(n_unr == 0, "with no underrun while the guest keeps up");
      // then a whole data field, as the format's sector pass would write it:
      // the decoder must ACCEPT it and the commit mux must REFUSE it
      for (i = 0; i < 12; i = i + 1) fifo_push(4'h0, 8'h00);
      for (i = 0; i < 3;  i = i + 1) fifo_push(4'h1, 8'hA1);
      fifo_push(4'h0, 8'hFB);
      for (i = 0; i < 512; i = i + 1) fifo_push(4'h0, i[7:0] ^ 8'hC3);
      fifo_push(4'h2, 8'h00);
      repeat (6000) @(posedge clk);
      $display("   (bytes to medium: %0d, decoder accepted: %0d, committed: %0d)",
               n_wr_bytes, n_sv, n_commit);
      check(push_giveups == 0, "the field went out at the byte cadence too");
      check(n_sv >= 1, "the MFM decoder saw a complete field");
      check(n_commit == 0, "and NOTHING committed: the image is not MFM");
      check(dut.floppyInt.mfm_spinning === 1'b0,
            "the read path stayed parked throughout");
      // the FIFO is empty again: the engine stops itself exactly as it does
      // over an MFM disk (the ROM's exit clears ACTION anyway)
      repeat (2000) @(posedge clk);
      check(n_unr >= 1 && dut.ism_mode_reg[3] === 1'b0,
            "starved, it disarms itself as section 6 showed");
      cpu_read(4'h2);
      mode_clear(8'h18);
      diskMFM = 2'b01;
      repeat (40) @(posedge clk);
      check(dut.ism_write_active === 1'b0 && n_unr >= 1,
            "back to an MFM disk, disarmed, nothing left ticking");

      $display("");
      $display("tb_swim_ism_arm: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
