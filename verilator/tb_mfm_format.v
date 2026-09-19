/* tb_mfm_format.v — Phase 6C: a WHOLE-TRACK MFM format, driven over the CPU bus.
 *
 * WHY THIS EXISTS. Everything else in the MFM write path is gated one field at
 * a time. `tb_mfm_write_decoder` §1/§2 already round-trips a whole encoder
 * track through the decoder, so the FORMAT CASE is proven at the decoder — but
 * only with the bench holding the decoder's hand. `tb_swim_ism_arm` §5 drives
 * the real CPU bus but writes exactly one data field, against an anchor. A
 * format is neither: it is the guest laying down eighteen ID+DATA field PAIRS
 * back to back, through the 2-entry FIFO, with no anchor available at all
 * (an unformatted track has no ID field to have read first). Nothing covered
 * that, and it is the whole of Phase 6C.2/6C.3.
 *
 * ★ WHAT MAKES A FORMAT DIFFERENT FROM EIGHTEEN SECTOR WRITES, and what this
 * bench is really checking:
 *   1. NO ANCHOR. Each sector is placed by the ID field the guest itself just
 *      wrote (mfm_write_decoder's priority 1). §3 asserts `ism_anchor_ok`
 *      stayed LOW for the entire track, so the placements cannot have come
 *      from a stale anchor by luck.
 *   2. SUSTAINED. 12,276 bytes with no gap long enough to underrun, while the
 *      committer drains 256 words to SDRAM between one data field and the
 *      next. The committer gets gap3+sync+ID+gap2+sync ~= 160 byte-times to
 *      do it; if it needed more, sectors would start going missing partway
 *      down the track rather than all at once.
 *   3. ONE ID ARMS ONE DATA FIELD. Eighteen pairs in a row is the case where
 *      a decoder that let an ID linger would misplace every sector after the
 *      first.
 *
 * WHAT IS REAL: rtl/swim.v (register file, FIFO, handshake, ism_write_engine),
 * rtl/floppy.v, rtl/mfm_write_decoder.v and rtl/floppy_write_committer.v.
 * The bench supplies the CPU, an SDRAM model and the track bytes.
 *
 * ★ THE BYTES ARE BUILT HERE, NOT TAKEN FROM mfm_track_encoder.v, and that is
 * deliberate. The encoder is what the READ side serves; using it as the source
 * for the WRITE side would be testing the decoder against its own inverse
 * twice over and would hide any disagreement about what a real IBM track looks
 * like. The layout below is written out from the MAME pc_dsk tuple (the same
 * source the encoder's header cites) so the two agree by derivation, not by
 * construction.
 *
 * The drive is given a shortened byte cadence through floppy.v's MFM_PERIOD_*
 * parameters, reached by defparam through swim.v — see tb_swim_ism_arm.v's
 * header for why that is necessary and why it is safe.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_mfm_format \
 *     -o scratch/phase6/tb_fmt.vvp verilator/tb_mfm_format.v \
 *     rtl/swim.v rtl/ism_write_engine.v rtl/floppy.v \
 *     rtl/floppy_track_encoder.v rtl/mfm_track_encoder.v \
 *     rtl/floppy_track_decoder.v rtl/mfm_write_decoder.v \
 *     rtl/floppy_write_committer.v
 *   /c/iverilog/bin/vvp scratch/phase6/tb_fmt.vvp
 *
 * Plusargs:
 *   +verbose   print every check as it passes, not only the failures
 */
`timescale 1ns/1ps

module tb_mfm_format;

   reg clk = 0;
   always #5 clk = ~clk;
   reg [1:0] ph = 0;
   always @(posedge clk) ph <= ph + 2'd1;
   wire cep = (ph == 2'd3);      // clk8_en_p = busPhase==3
   wire cen = (ph == 2'd1);      // clk8_en_n = busPhase==1

   integer checks = 0, fails = 0;
   reg     verbose;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
         else if (verbose) $display("  ok:   %0s", what);
      end
   endtask

   // ── CPU bus ────────────────────────────────────────────────────────────
   reg        _reset     = 0;
   reg        selectSWIM = 0;
   reg        _cpuRW     = 1;
   reg        _cpuUDS    = 1;
   reg [15:0] dataIn     = 16'd0;
   reg  [3:0] addr       = 4'd0;
   wire [15:0] dataOut;

   reg  [1:0] diskHD  = 2'b01;   // switched between the HD and DD sections
   reg  [1:0] diskMFM = 2'b01;   // dropped to GCR for the cross-encoding case

   wire [21:0] dskReadAddrInt, dskReadAddrExt;
   wire  [7:0] dskReadData = dskReadAddrInt[7:0] ^ dskReadAddrInt[15:8];

   wire [21:0] wrSdAddr, wrCommitAddr;
   wire [15:0] wrSdData;
   wire        wrSdReq, wrCommitDone;
   reg         wrSdAck = 0;
   always @(posedge clk) wrSdAck <= wrSdReq & ~wrSdAck;

   // one track of either density fits: 18 sectors * 256 words = 4608
   reg [15:0] img [0:8191];
   reg        img_wr [0:8191];
   integer    stray = 0;
   always @(posedge clk)
      if (wrSdReq && wrSdAck) begin
         if (wrSdAddr[21:1] < 21'd8192) begin
            img   [wrSdAddr[13:1]] <= wrSdData;
            img_wr[wrSdAddr[13:1]] <= 1'b1;
         end else
            stray = stray + 1;    // outside this track: the address is wrong
      end

   defparam dut.floppyInt.MFM_PERIOD_HD = 9'd15;
   defparam dut.floppyInt.MFM_PERIOD_DD = 9'd31;
   defparam dut.WR_VOID_PERIOD = 9'd31;            // section 5's void cadence

   swim dut (
      .clk(clk), .cep(cep), .cen(cen), ._reset(_reset),
      .selectSWIM(selectSWIM), ._cpuRW(_cpuRW), ._cpuUDS(_cpuUDS),
      .dataIn(dataIn), .cpuAddrRegHi(addr), .dataOut(dataOut),
      .SEL(1'b0), .driveSel(1'b0),
      .insertDisk(2'b01),
      .diskSides(2'b11), .mediaSides(2'b11), .diskMFM(diskMFM), .diskHD(diskHD),
      .writeProtect(2'b10),
      .dskReadAddrInt(dskReadAddrInt), .dskReadAckInt(1'b1),
      .dskReadAddrExt(dskReadAddrExt), .dskReadAckExt(1'b1),
      .dskReadData(dskReadData),
      .wrSdAddr(wrSdAddr), .wrSdData(wrSdData), .wrSdReq(wrSdReq), .wrSdAck(wrSdAck),
      .wrCommitDone(wrCommitDone), .wrCommitAddr(wrCommitAddr)
   );

   // ── the CPU access protocol (tb_swim_ism_arm.v's, verbatim) ────────────
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
         #1 rd = dataOut[15:8];
         @(posedge clk);
         #1 selectSWIM = 0; _cpuUDS = 1;
         repeat (4) @(posedge clk);
      end
   endtask

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

   // ── witnesses ──────────────────────────────────────────────────────────
   integer n_commit = 0, n_rej = 0, n_unr = 0, n_sv = 0;
   integer anchor_ever = 0;
   reg [21:0] last_commit;
   reg [21:0] commit_at [0:31];
   integer    n_commit_log = 0;
   reg err_ovf = 0;
   always @(posedge clk) begin
      if (dut.ism_wr_underrun) n_unr = n_unr + 1;
      if (dut.floppyInt.wrpath.mdec.reject) n_rej = n_rej + 1;
      if (dut.floppyInt.wrpath.mdec.sector_valid) n_sv = n_sv + 1;
      if (dut.ism_error[2]) err_ovf = 1;
      // ★ THE ANCHOR MUST NEVER BECOME AVAILABLE during a format. If it did,
      // a decoder that ignored the in-stream ID could still place sectors and
      // this bench would pass for the wrong reason.
      if (dut.ism_anchor_ok) anchor_ever = anchor_ever + 1;
      if (wrCommitDone) begin
         last_commit = wrCommitAddr;
         if (n_commit_log < 32) commit_at[n_commit_log] = wrCommitAddr;
         n_commit_log = n_commit_log + 1;
         n_commit = n_commit + 1;
      end
   end

   // ── feed the engine the way the driver does (tb_swim_ism_arm.v's) ──────
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
         if (!rd[7]) push_giveups = push_giveups + 1;
         push_polls = push_polls + g;
         cpu_write(reg_n, d);
      end
   endtask

   // ── the track the guest writes ─────────────────────────────────────────
   // Self-identifying payload: a byte names its own block and offset, so a
   // sector that lands at the wrong address says so instead of matching.
   function [7:0] pat(input [12:0] blk, input integer off);
      pat = blk[7:0] ^ off[7:0] ^ (off[8] ? 8'hA5 : 8'h5A);
   endfunction

   // One sector's worth of an IBM System/34 MFM track, as the guest lays it
   // down. Gap/sync lengths are the MAME pc_dsk tuple (gap2=22, gap3=108,
   // sync=12) that rtl/mfm_track_encoder.v's header also cites.
   //   00 x12 | A1 A1 A1 | FE | C H R N | CRC | 4E x22
   //   00 x12 | A1 A1 A1 | FB | 512     | CRC | 4E x108
   // `prime` skips the first two sync bytes: they were pushed before the
   // engine was armed, because an armed engine with an empty FIFO underruns
   // on its very next byte-time.
   task write_sector(input [6:0] cyl, input side_i, input [4:0] r,
                     input [12:0] blk, input prime);
      integer i;
      begin
         for (i = 0; i < (prime ? 10 : 12); i = i + 1) fifo_push(4'h0, 8'h00);
         for (i = 0; i < 3;  i = i + 1) fifo_push(4'h1, 8'hA1);   // reg1 = mark
         fifo_push(4'h0, 8'hFE);                                  // ID address mark
         fifo_push(4'h0, {1'b0, cyl});                            // C
         fifo_push(4'h0, {7'd0, side_i});                         // H
         fifo_push(4'h0, {3'd0, r});                              // R, 1-based
         fifo_push(4'h0, 8'd2);                                   // N = 2 -> 512
         fifo_push(4'h2, 8'h00);                                  // reg2 = CRC token
         for (i = 0; i < 22; i = i + 1) fifo_push(4'h0, 8'h4E);   // gap 2
         for (i = 0; i < 12; i = i + 1) fifo_push(4'h0, 8'h00);   // sync
         for (i = 0; i < 3;  i = i + 1) fifo_push(4'h1, 8'hA1);
         fifo_push(4'h0, 8'hFB);                                  // data address mark
         for (i = 0; i < 512; i = i + 1) fifo_push(4'h0, pat(blk, i));
         fifo_push(4'h2, 8'h00);                                  // CRC token
         for (i = 0; i < 108; i = i + 1) fifo_push(4'h0, 8'h4E);  // gap 3
      end
   endtask

   // Bring the SWIM up in ISM mode with the MFM write datapath selected, the
   // FIFO clear and two bytes primed, then arm. Mirrors the driver's order:
   // fill first, set ACTION+WRITE together.
   task arm_for_write(input do_enter);
      begin
         if (do_enter) enter_ism;
         cpu_write(4'h5, 8'h20);         // Setup: IBM + MFM write datapath
         mode_set(8'hC0);                // motor on + ISM select
         mode_set(8'h02);                // drive select code
         mode_set(8'h01); mode_clear(8'h01);   // clear the FIFO
         cpu_read(4'h2);                 // clear any sticky error
         err_ovf = 0;
         cpu_write(4'h0, 8'h00);         // prime: the track's first two
         cpu_write(4'h0, 8'h00);         //        sync bytes
         mode_set(8'h18);                // ACTION + WRITE together -> armed
         repeat (20) @(posedge clk);
      end
   endtask

   task reset_dut;
      begin
         @(posedge clk); #1 _reset = 0;
         repeat (20) @(posedge clk);
         #1 _reset = 1;
         repeat (20) @(posedge clk);
      end
   endtask

   integer i, s, spt, guard;
   reg  [4:0] anchor_seen;
   integer bad_payload, bad_addr, missing;
   reg [12:0] blk;
   reg  [6:0] TRK;

   // ── format one whole track and check every sector of it ────────────────
   task format_track(input [6:0] cyl, input integer spt_i, input do_enter);
      integer si, wi;
      reg [12:0] b;
      begin
         for (i = 0; i < 8192; i = i + 1) img_wr[i] = 1'b0;
         n_commit = 0; n_rej = 0; n_unr = 0; n_sv = 0; n_commit_log = 0;
         anchor_ever = 0; stray = 0; push_giveups = 0; push_polls = 0;

         arm_for_write(do_enter);
         check(dut.ism_write_active === 1'b1, "the engine is armed for the track");

         for (si = 1; si <= spt_i; si = si + 1) begin
            b = (cyl * 2 + 0) * spt_i + (si - 1);
            write_sector(cyl, 1'b0, si[4:0], b, (si == 1));
         end

         // the last data field's commit is still draining; and the write ends
         // the way every real write ends — the engine starves and stops itself
         repeat (20000) @(posedge clk);
      end
   endtask

   task check_track(input [6:0] cyl, input integer spt_i);
      integer si, wi;
      reg [12:0] b;
      begin
         $display("   (to medium: %0d accepted, %0d committed, %0d rejected, %0d underruns)",
                  n_sv, n_commit, n_rej, n_unr);
         check(push_giveups == 0, "every byte of the track was accepted by the FIFO");
         check(!err_ovf, "no CPU push was dropped on a full FIFO (error 0x04)");
         check(n_rej == 0, "a well-formed track produces no rejects");
         check(n_commit == spt_i, "every sector of the track committed exactly once");
         check(stray == 0, "no sector landed outside the track's own address range");

         bad_addr = 0; bad_payload = 0; missing = 0;
         for (si = 1; si <= spt_i; si = si + 1) begin
            b = (cyl * 2 + 0) * spt_i + (si - 1);
            // the commit log must contain this sector's byte offset
            if (si - 1 < 32 && commit_at[si-1] !== {b, 9'd0}) bad_addr = bad_addr + 1;
            for (wi = 0; wi < 256; wi = wi + 1) begin
               if (!img_wr[(b << 8) + wi]) missing = missing + 1;
               else if (img[(b << 8) + wi] !== {pat(b, 2*wi), pat(b, 2*wi+1)})
                  bad_payload = bad_payload + 1;
            end
         end
         check(bad_addr == 0,
               "the sectors committed IN ORDER, each at its own byte offset");
         check(missing == 0, "every payload word of every sector reached SDRAM");
         check(bad_payload == 0,
               "and every one of them is byte-exact, even byte high, odd byte low");
      end
   endtask

   initial begin
      verbose = $test$plusargs("verbose");

      repeat (20) @(posedge clk);
      #1 _reset = 1;
      repeat (20) @(posedge clk);

      // ─── 1. HD: an 18-sector 1.44 MB track ──────────────────────────────
      $display("1. HD 18spt: the guest formats a whole track, ID+DATA pair by pair");
      diskHD = 2'b01;
      TRK = 7'd0;
      format_track(TRK, 18, 1'b1);
      check_track(TRK, 18);

      // ─── 2. no anchor was ever available ────────────────────────────────
      // ★ An unformatted track has no ID field to have read first, so a
      // format MUST place every sector from the ID it just wrote. If the
      // anchor were available, §1 could have passed on it instead.
      $display("2. the whole track was placed with NO anchor at any point");
      check(anchor_ever == 0,
            "ism_anchor_ok stayed low: every sector came from its own ID field");

      // ─── 3. the write ended the way a real one does ─────────────────────
      $display("3. the starved engine stopped the write and reported it");
      check(n_unr >= 1, "running out of bytes raises an underrun");
      check(dut.ism_mode_reg[3] === 1'b0, "ACTION was cleared by the engine itself");
      cpu_read(4'h2);
      check(rd[0] === 1'b1, "error bit 0 (0x01) is the write-underrun code");

      // ─── 4. DD: the same at the 720K geometry ───────────────────────────
      // 9 sectors, 32us byte-times. The 720K run of 2026-09-18 proved the READ
      // path tracks DD geometry; this is the write half of that.
      $display("4. DD 9spt: the same whole-track format at the 720K geometry");
      reset_dut;
      diskHD = 2'b00;
      TRK = 7'd0;
      format_track(TRK, 9, 1'b1);
      check_track(TRK, 9);
      check(anchor_ever == 0, "DD: still no anchor involved");

      // ─── 5. cross-encoding: an MFM write to a GCR medium commits NOTHING ─
      // ★ 6C.4, the SAFETY half. The encoding is pinned by the image's file
      // size and hps_io cannot resize a file, so "erase this 800K disk as DOS
      // 720K" is not supported. What must be true in RTL is that it cannot
      // DAMAGE the image: with mfm_disk low the committer's mux takes the GCR
      // decoder, so no MFM field can reach the medium however well-formed it
      // is. Whether the GUEST errors or hangs is a hardware question and is
      // listed as a hardware gate; this is the part we can prove offline.
      $display("5. cross-encoding: an MFM write to a GCR-mounted disk writes nothing");
      reset_dut;
      diskMFM = 2'b00;                 // the mounted image is GCR
      diskHD  = 2'b00;
      repeat (20) @(posedge clk);
      n_commit = 0; n_rej = 0; stray = 0; push_giveups = 0;
      arm_for_write(1'b1);
      // A SHORT burst, not a whole sector: the commit mux is what is under
      // test, and an ID field is enough to show it refusing.
      // ★ REVISED 2026-09-19 (gate 4a). This section used to ASSERT that the
      // engine never consumed here ("the guest's pushes backed up, as
      // expected") - that was the hang. On hardware the ROM's format loop
      // polls Handshake b7 alone, so an engine that does not pop is a machine
      // that never comes back. swim.v now paces the engine from its own void
      // cadence when the selected disk is not MFM, so the guest is released
      // every byte while the mux still commits nothing. tb_swim_ism_arm §7
      // is the full version; here the burst must simply go out at cadence.
      for (i = 0; i < 12; i = i + 1) fifo_push(4'h0, 8'h00);
      for (i = 0; i < 3;  i = i + 1) fifo_push(4'h1, 8'hA1);
      fifo_push(4'h0, 8'hFE);
      fifo_push(4'h0, 8'h00); fifo_push(4'h0, 8'h00);
      fifo_push(4'h0, 8'h01); fifo_push(4'h0, 8'd2);
      fifo_push(4'h2, 8'h00);
      repeat (20000) @(posedge clk);
      check(n_commit == 0, "nothing may commit through the GCR mux");
      check(stray == 0, "and nothing may reach SDRAM at all");
      check(push_giveups == 0,
            "and the engine consumed every byte: the guest is never left polling b7");

      // ─── 6. REFORMAT: a stale anchor must not steer the format ──────────
      // ★ THE COMMON CASE ON REAL HARDWARE, and the one nothing covered.
      // Sections 1 and 4 format with no anchor at all, which is what an
      // UNFORMATTED disk gives you. Erasing a disk that already holds a
      // volume does not: the driver reads it first, so swim.v's anchor is
      // live and names some sector of the old layout. The anchor survives
      // the switch to write mode by design -- it is cleared only on a
      // READ-ARM rising edge (swim.v:1247) -- so a decoder that preferred it
      // over the in-stream ID would put all eighteen sectors on top of one
      // another, and the disk would come back with one good sector and
      // seventeen holes.
      $display("6. reformat: an anchor left over from a read must not place the sectors");
      reset_dut;
      diskHD = 2'b01; diskMFM = 2'b01;
      enter_ism;
      cpu_write(4'h5, 8'h60);            // Setup: GCR write select = engine inert
      mode_set(8'hC0);                   // motor on + ISM select
      mode_set(8'h02);                   // drive select code
      mode_set(8'h08);                   // ACTION: read
      guard = 0;
      while (dut.ism_anchor_ok !== 1'b1 && guard < 400) begin
         cpu_read(4'h1);                 // pop a delivered byte
         repeat (40) @(posedge clk);
         guard = guard + 1;
      end
      check(dut.ism_anchor_ok === 1'b1, "the preceding read established an anchor");
      anchor_seen = dut.ism_anchor_sector;
      mode_clear(8'h08);                 // stop the read (this does NOT clear it)
      repeat (40) @(posedge clk);
      check(dut.ism_anchor_ok === 1'b1,
            "and it is still live when the format starts, as on real hardware");

      TRK = 7'd0;
      format_track(TRK, 18, 1'b0);       // already in ISM mode
      check(anchor_ever > 0,
            "the anchor really was available throughout this format");
      check_track(TRK, 18);

      $display("");
      $display("tb_mfm_format: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

   // deadlock guard
   initial begin
      #400_000_000;
      $display("FAIL: timeout — the bench never completed");
      $finish;
   end

endmodule
