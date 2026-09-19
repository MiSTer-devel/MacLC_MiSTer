/* tb_mfm_write_path.v — Stage 2 piece 3 gate: the WHOLE MFM write path
 * through floppy.v — anchor, decoder, committer — driven the way the machine
 * drives it.
 *
 * The three unit benches each prove one module against its own contract:
 * tb_mfm_write_decoder (encoder -> decoder), tb_ism_write_engine (engine ->
 * decoder). What none of them can prove is that the ANCHOR arriving at the
 * decoder is the sector the guest actually read, because that value is born in
 * mfm_track_encoder.v, latched in floppy.v beside the delivered byte, carried
 * through swim.v's staging ring and recovered on the CPU's pop. This bench
 * closes the half of that chain that lives in floppy.v, and checks the part
 * that matters most:
 *
 * ★ A SECTOR WRITTEN WHERE THE HEAD IS READING MUST LAND AT THAT SECTOR'S
 *   OFFSET IN THE IMAGE. Nothing else in the suite can catch an off-by-one in
 *   `osector`, a wrong latch point in floppy.v, or a decoder fed the live head
 *   position instead of the delivered one. Those all produce a WELL-FORMED
 *   sector written to the WRONG place — the exact failure mode plan §6.1
 *   records UK101 hitting twice, the second time catastrophically.
 *
 * ★ THE ANCHOR IS READ OFF THE DELIVERED BYTE, NOT THE LIVE HEAD (section 2).
 *   The bench captures `mfm_sector` at the delivery strobe, lets the encoder
 *   run on for a while, and only then writes — so a decoder wired to the live
 *   position would place the sector somewhere else and be caught. This is the
 *   16-byte-time separation the staging ring introduces, modelled at its worst.
 *
 * WHAT THIS BENCH DOES NOT COVER: swim.v's ring itself (the sector riding in
 * FIFO bits 15:11 and the pop that latches it), and the CPU-side register
 * protocol that arms write mode. Those need the full SWIM stack.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_mfm_write_path \
 *     -o scratch/mfm/tb_mwp.vvp verilator/tb_mfm_write_path.v \
 *     rtl/floppy.v rtl/floppy_track_encoder.v rtl/mfm_track_encoder.v \
 *     rtl/floppy_track_decoder.v rtl/mfm_write_decoder.v \
 *     rtl/floppy_write_committer.v
 *   /c/iverilog/bin/vvp scratch/mfm/tb_mwp.vvp
 */
`timescale 1ns/1ps

module tb_mfm_write_path;

   reg clk = 0;
   always #5 clk = ~clk;
   reg [1:0] ph = 0;
   always @(posedge clk) ph <= ph + 2'd1;
   wire cep = (ph == 2'd3);      // clk8_en_p = busPhase==3: 1 clk, 1-in-4
   wire cen = (ph == 2'd1);

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

   reg _reset = 0;
   reg insertDisk = 1;

   // the image the encoder reads from: a pure function of the address
   wire [21:0] dskReadAddr;
   reg         dskReadAck = 0;
   wire  [7:0] dskReadData = dskReadAddr[7:0] ^ dskReadAddr[15:8];

   wire  [7:0] mfm_byte;
   wire        mfm_mark, mfm_crc0, mfm_stb;
   wire  [4:0] mfm_sector;

   reg   [7:0] wr_byte = 8'h00;
   reg         wr_mark = 1'b0;
   reg         wr_stb  = 1'b0;
   reg   [4:0] wr_anchor = 5'd1;
   reg         wr_anchor_ok = 1'b0;

   wire        wrSecValid;
   wire  [4:0] wrSecNum;
   wire [21:0] wrSecAddr;
   wire [21:0] wrSdAddr, wrCommitAddr;
   wire [15:0] wrSdData;
   wire        wrSdReq, wrCommitDone;

   // the SDRAM write port: ack one cycle after req, and record the words
   reg wrSdAck = 0;
   always @(posedge clk) wrSdAck <= wrSdReq & ~wrSdAck;

   reg [15:0] img [0:8191];      // words, indexed by byte offset >> 1
   always @(posedge clk)
      if (wrSdReq && wrSdAck) img[wrSdAddr[13:1]] <= wrSdData;

   // A real byte-time is 129 cep ticks; 7 keeps the shape and makes a
   // whole sector crossing affordable. Nothing here depends on the
   // absolute rate - only on the head advancing while the bench writes.
   floppy #(.WRITE_SUPPORT(1), .MFM_PERIOD_HD(9'd7), .MFM_PERIOD_DD(9'd15)) dut (
      .clk(clk), .cep(cep), .cen(cen), ._reset(_reset),
      .ca0(1'b0), .ca1(1'b0), .ca2(1'b0), .SEL(1'b0), .lstrb(1'b0),
      ._enable(1'b0), .writeData(8'd0), .writeReq(1'b0),
      .writeProtect(1'b0),
      .insertDisk(insertDisk), .diskSides(1'b1), .mediaSides(1'b1),
      .writeMode(1'b0),   // IWM Q7 (GCR relay bound); this bench is ISM/MFM
      .advanceDriveHead(1'b0),
      .dskReadAddr(dskReadAddr), .dskReadAck(dskReadAck), .dskReadData(dskReadData),
      .ism_active(1'b1), .ism_action(1'b1), .ism_sel(1'b1),
      .mfm_disk(1'b1), .mfm_hd(1'b1),
      .mfm_byte(mfm_byte), .mfm_mark(mfm_mark), .mfm_crc0(mfm_crc0),
      .mfm_stb(mfm_stb), .mfm_sector(mfm_sector),
      .mfm_wr_byte(wr_byte), .mfm_wr_mark(wr_mark), .mfm_wr_stb(wr_stb),
      .mfm_wr_anchor(wr_anchor), .mfm_wr_anchor_ok(wr_anchor_ok),
      .wrSecValid(wrSecValid), .wrSecNum(wrSecNum), .wrSecAddr(wrSecAddr),
      .wrSdAddr(wrSdAddr), .wrSdData(wrSdData), .wrSdReq(wrSdReq), .wrSdAck(wrSdAck),
      .wrCommitDone(wrCommitDone), .wrCommitAddr(wrCommitAddr)
   );

   // ★ A ZERO-LATENCY MEMORY, AND THE ACK MUST BE A LEVEL. floppy.v samples
   // dskReadAck on **cen** (`dskReadAckD <= dskReadAck`), not cep. An earlier
   // version of this bench pulsed it one clock after cep, so the pulse was
   // already low by the cen sampling edge and no fetch ever completed: the
   // drive delivered exactly 206 bytes - the track preamble plus sector 1's ID
   // field - and then stalled forever on its first payload byte, hanging the
   // bench. If this bench ever stops making progress, check `mfm_needs_data`
   // and `mfm_fresh` in the DUT first.
   always @(posedge clk) dskReadAck <= 1'b1;

   // ── witnesses ──────────────────────────────────────────────────────────
   integer n_commit = 0;
   reg [21:0] last_commit;
   reg [4:0]  last_secnum;
   always @(posedge clk) begin
      if (wrCommitDone) begin
         n_commit    = n_commit + 1;
         last_commit = wrCommitAddr;
      end
      if (wrSecValid) last_secnum = wrSecNum;
   end

   // Capture what the guest would have seen delivered, AND check the tag
   // against the stream's own ID fields. The tag must be verified against
   // something the bench did not get from the tag itself, or a broken tag
   // simply moves the expectation with it (a mutant proved exactly that:
   // pinning mfm_sector to a constant left every check passing).
   reg [4:0]  delivered_sector = 5'd0;
   reg        saw_delivery = 1'b0;
   reg        stb_d = 1'b0;
   reg  [2:0] id_mark_run = 3'd0;   // consecutive A1s seen
   reg  [2:0] id_pos      = 3'd7;   // bytes since the FE (7 = not in an ID)
   integer    id_fields_seen = 0;
   integer    id_tag_ok     = 0;
   integer    id_tag_bad    = 0;
   always @(posedge clk) begin
      stb_d <= mfm_stb;
      if (mfm_stb && !stb_d) begin
         delivered_sector <= mfm_sector;
         saw_delivery     <= 1'b1;
         // walk the delivered stream: A1 A1 A1 FE C H R N
         if (mfm_mark && mfm_byte == 8'hA1) begin
            id_mark_run <= (id_mark_run == 3'd7) ? id_mark_run : id_mark_run + 3'd1;
            id_pos      <= 3'd7;
         end else begin
            if (id_mark_run >= 3'd3 && mfm_byte == 8'hFE)
               id_pos <= 3'd0;                       // next byte is C
            else if (id_pos != 3'd7)
               id_pos <= id_pos + 3'd1;
            id_mark_run <= 3'd0;
            if (id_pos == 3'd2) begin                // this byte is R
               id_fields_seen = id_fields_seen + 1;
               if (mfm_sector === mfm_byte[4:0]) id_tag_ok  = id_tag_ok + 1;
               else                              id_tag_bad = id_tag_bad + 1;
            end
         end
      end
   end

   // one written byte, at a byte-time
   task push(input [7:0] d, input m);
      begin
         @(posedge clk);
         #1 wr_byte = d; wr_mark = m; wr_stb = 1;
         @(posedge clk);
         #1 wr_stb = 0;
         repeat (6) @(posedge clk);
      end
   endtask

   // a whole data field for image block `blk`
   task write_data_field(input [12:0] blk, input bad);
      reg [15:0] k;
      integer i;
      begin
         for (i = 0; i < 12; i = i + 1) push(8'h00, 1'b0);
         for (i = 0; i < 3;  i = i + 1) push(8'hA1, 1'b1);
         k = CRC_SEED;
         push(8'hFB, 1'b0); k = crc16(k, 8'hFB);
         for (i = 0; i < 512; i = i + 1) begin
            push(pat(blk, i), 1'b0);
            k = crc16(k, pat(blk, i));
         end
         if (bad) k = k ^ 16'h0080;
         push(k[15:8], 1'b0);
         push(k[7:0],  1'b0);
      end
   endtask

   function [7:0] pat(input [12:0] blk, input integer i);
      pat = blk[7:0] ^ i[7:0] ^ 8'hA5;
   endfunction

   integer i;
   reg [12:0] exp_block;
   reg [4:0]  anchor_cap;
   integer    walk;
   reg ok;

   initial begin
      repeat (20) @(posedge clk);
      #1 _reset = 1;

      // ─── 1. the tag on a delivered byte IS that byte's sector ────────────
      // Checked against the ID fields in the stream itself, not against the
      // tag, so a constant or off-by-one tag cannot pass.
      $display("1. every delivered byte is tagged with the sector it came from");
      wait (saw_delivery);
      repeat (200000) @(posedge clk);
      $display("   (ID fields audited: %0d, mismatches: %0d)", id_fields_seen, id_tag_bad);
      check(id_fields_seen >= 4, "the bench saw enough ID fields to judge");
      check(id_tag_bad == 0, "every ID field's R byte matched the tag on that byte");
      check(id_tag_ok == id_fields_seen, "and every one of them was checked");

      // ─── 2. a write placed by the anchor lands at that sector ────────────
      // Capture the anchor from a DELIVERED byte, then let the head run on for
      // a few thousand cycles before writing. A decoder wired to the live head
      // instead of the delivered byte would place this somewhere else.
      $display("2. a data field written against the captured anchor lands at its sector");
      #1 anchor_cap = delivered_sector;
      #1 wr_anchor = anchor_cap; wr_anchor_ok = 1'b1;
      exp_block = (0 * 2 + 0) * 18 + (anchor_cap - 1);   // track 0, side 0
      // ★ WAIT FOR THE HEAD TO LEAVE THAT SECTOR before writing. Without this
      // the live head and the captured anchor are the same value and a
      // decoder wired to the wrong one passes anyway - a mutant that fed the
      // decoder the LIVE sector survived the first version of this bench for
      // exactly that reason. One sector is 682 byte-times; the write below is
      // about eight, so the head has to be walked on deliberately.
      // BOUNDED, deliberately. An unbounded wait here HANGS the bench when the
      // tag is broken (a mutant that pins mfm_sector to a constant makes this
      // condition true forever), and a bench that hangs on a defect is worse
      // than one that fails: it looks like a slow run, not a result.
      walk = 0;
      while (delivered_sector === anchor_cap && walk < 200000) begin
         @(posedge clk);
         walk = walk + 1;
      end
      check(delivered_sector !== anchor_cap,
            "the head must move off the anchor's sector before the write");
      n_commit = 0;
      write_data_field(exp_block, 1'b0);
      repeat (4000) @(posedge clk);
      check(n_commit == 1, "the field committed exactly once");
      check(last_secnum === anchor_cap,
            "it committed under the ANCHOR's sector, not wherever the head now is");
      check(last_secnum !== delivered_sector,
            "and the head really has moved on, so the two are distinguishable");
      check(last_commit === {exp_block, 9'd0},
            "and at that sector's byte offset in the image");
      ok = 1'b1;
      for (i = 0; i < 256; i = i + 1)
         if (img[(exp_block << 8) + i] !==
             {pat(exp_block, 2*i), pat(exp_block, 2*i+1)}) ok = 1'b0;
      check(ok, "every payload byte reached SDRAM, even byte high, odd byte low");

      // ─── 3. a corrupt field commits nothing ──────────────────────────────
      $display("3. a field with a bad CRC never reaches the image");
      n_commit = 0;
      write_data_field(exp_block, 1'b1);
      repeat (4000) @(posedge clk);
      check(n_commit == 0, "a bad CRC must not commit");

      // ─── 4. with no anchor, nothing is placed ────────────────────────────
      $display("4. with no anchor a well-formed field is still refused");
      #1 wr_anchor_ok = 1'b0;
      n_commit = 0;
      write_data_field(exp_block, 1'b0);
      repeat (4000) @(posedge clk);
      check(n_commit == 0, "an unplaceable field must not commit");

      $display("");
      $display("tb_mfm_write_path: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
