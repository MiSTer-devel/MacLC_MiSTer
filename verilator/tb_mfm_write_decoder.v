/* tb_mfm_write_decoder.v — Stage 2 gate: RTL MFM encoder -> RTL MFM write
 * decoder round-trip, plus the cases the round-trip structurally cannot reach.
 *
 * WHY RTL-TO-RTL, as tb_floppy_track_decoder.v does for GCR: a decoder
 * validated against a model shares that model's misunderstandings. This one is
 * driven by the exact byte stream `rtl/mfm_track_encoder.v` emits — the stream
 * this core has already been read-validated against MAME and real hardware.
 *
 * WHAT A FAILURE HERE MEANS DOWNSTREAM. floppy_write_committer.v commits
 * whatever this module declares valid straight into the SDRAM image, and
 * floppy_sd_writer.v puts it in the user's file. A wrongly-ACCEPTED field is a
 * silent write of wrong data to a real disk, so the negative sections carry
 * more weight than the positive ones, and each names the sector that must NOT
 * appear rather than asserting "an error happened".
 *
 * ★ THE ANCHOR IS THE WHOLE POINT (sections 3-4, 6, 8). An MFM data field does
 * not name its sector, and on an ordinary sector write the ID field is not in
 * the stream at all — the head passed it before the ISM started writing. The
 * decoder therefore takes the identity from an in-stream ID field when there is
 * one (the FORMAT case) and otherwise from `anchor_sector`, the ID most
 * recently DELIVERED to the guest. UK101 reached that design after two wrong
 * answers, the second of which (a cumulative counter) failed catastrophically
 * by writing through to an unrelated sector — see plan §6.1. So:
 *   - section 4 proves that with NEITHER source the field is refused, never
 *     guessed;
 *   - section 8 proves one ID arms exactly ONE data field, so a stale identity
 *     cannot be reused by the field behind it.
 *
 * ★ POSITION COMES FROM THE MEDIUM, IDENTITY FROM THE FIELD (section 10). The
 * address is built from the PHYSICAL track/side inputs; only the sector number
 * comes from the field or the anchor. A format that writes an ID claiming a
 * different cylinder must therefore be unable to reach another track. That is a
 * containment property, so it is checked explicitly rather than assumed.
 *
 * TWO INDEPENDENT POSITIVE CHECKS, as in the GCR bench. The synthetic image is
 * a pure function of the byte address whose first three bytes of every 512-byte
 * block ENCODE THAT BLOCK NUMBER:
 *   1. recovered[0..2] decode to the block the bench is driving -> the
 *      recovered PAYLOAD is this sector's data. Uses no address at all.
 *   2. recovered[k] == img_byte(dec_addr + k) for all 512 bytes -> `addr`
 *      points at exactly this sector. Because bytes 0..2 name the source
 *      block, a wrong `addr` cannot pass this even though the pattern is
 *      synthetic.
 *
 * `ready` IS A SPARSE PULSE, NOT A LEVEL, and every stimulus change happens #1
 * AFTER a clock edge. Both conventions are inherited from the GCR benches,
 * where the reasoning is written out: a continuously-asserted ready starves the
 * encoder's address settle time and produces a self-consistent but wrong byte
 * stream, and driving at zero delay after @(posedge clk) lets process ordering
 * decide what the DUT sees — a hazard that bit the MacPlus benches four times.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT):
 *   /c/iverilog/bin/iverilog -g2012 -s tb_mfm_write_decoder \
 *     -o scratch/mfm/tb_mwd.vvp verilator/tb_mfm_write_decoder.v \
 *     rtl/mfm_track_encoder.v rtl/mfm_write_decoder.v
 *   /c/iverilog/bin/vvp scratch/mfm/tb_mwd.vvp
 */
`timescale 1ns/1ps

module tb_mfm_write_decoder;

   localparam READY_GAP = 8;         // clk cycles per ready pulse (real HW: ~128)

   reg clk = 0;
   always #5 clk = ~clk;

   integer checks = 0;
   integer fails  = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   // ── the synthetic image: a pure function of the byte address ───────────
   // Bytes 0..2 of every 512-byte block name the block; the rest is keyed on
   // it, so no two blocks share a byte sequence.
   function [7:0] img_byte(input [21:0] a);
      reg [12:0] blk;
      reg  [8:0] off;
      begin
         blk = a[21:9];
         off = a[8:0];
         case (off)
         9'd0:    img_byte = blk[7:0];
         9'd1:    img_byte = {3'b000, blk[12:8]};
         9'd2:    img_byte = blk[7:0] ^ {3'b000, blk[12:8]} ^ 8'h5A;
         default: img_byte = blk[7:0] + {blk[12:8], 3'b000} + off[7:0] + 8'h11;
         endcase
      end
   endfunction

   // ── CRC-16-CCITT, the encoder's function, for the hand-built fields ────
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
   localparam [15:0] CRC_SEED = 16'hCDB4;   // CRC over A1 A1 A1

   // ── the encoder (section 1-2 stimulus) ─────────────────────────────────
   reg        rst   = 1;
   reg        ready = 0;
   reg        side  = 0;
   reg  [6:0] track = 0;
   reg        hd    = 1;

   wire [21:0] enc_addr;
   wire  [7:0] enc_idata = img_byte(enc_addr);
   wire  [7:0] enc_odata;
   wire        enc_omark, enc_ocrc0, enc_oneeds, enc_oindex;

   mfm_track_encoder enc (
      .clk(clk), .ready(ready & enc_drive), .rst(rst),
      .side(side), .track(track), .hd(hd),
      .addr(enc_addr), .idata(enc_idata),
      .odata(enc_odata), .omark(enc_omark), .ocrc0(enc_ocrc0),
      .oneeds(enc_oneeds), .oindex(enc_oindex)
   );

   // when 0 the encoder is parked and the bench drives the decoder by hand
   reg enc_drive = 1'b1;

   // ── the decoder under test ─────────────────────────────────────────────
   reg  [7:0] man_data = 8'h00;   // hand-driven byte (enc_drive == 0)
   reg        man_mark = 1'b0;
   reg  [4:0] anchor_sector = 5'd0;
   reg        anchor_valid  = 1'b0;

   wire [7:0] dec_idata = enc_drive ? enc_odata : man_data;
   wire       dec_imark = enc_drive ? enc_omark : man_mark;

   wire        sector_valid;
   wire  [4:0] dec_sector;
   wire [21:0] dec_addr;
   wire        reject;
   wire        amark;
   wire  [4:0] amark_sector;
   wire  [6:0] amark_cyl;
   wire        amark_head;
   reg   [8:0] buf_addr = 9'd0;
   wire  [7:0] buf_data;

   mfm_write_decoder dut (
      .clk(clk), .rst(rst),
      .ready(ready), .idata(dec_idata), .imark(dec_imark),
      .side(side), .track(track), .hd(hd),
      .anchor_sector(anchor_sector), .anchor_valid(anchor_valid),
      .sector_valid(sector_valid), .sector(dec_sector), .addr(dec_addr),
      .reject(reject),
      .amark(amark), .amark_sector(amark_sector),
      .amark_cyl(amark_cyl), .amark_head(amark_head),
      .buf_addr(buf_addr), .buf_data(buf_data)
   );

   // ── witnesses, updated by the step tasks ───────────────────────────────
   integer n_valid   = 0;
   integer n_reject  = 0;
   integer n_amark   = 0;
   reg [21:0] last_addr;
   reg  [4:0] last_sector;
   reg        saw_valid;      // this step committed a sector
   reg        saw_reject;

   // one ready pulse; afterwards the DUT outputs for THIS byte are visible
   task step;
      begin
         repeat (READY_GAP - 1) @(posedge clk);
         #1 ready = 1;
         @(posedge clk);
         #1 ready = 0;
         saw_valid  = sector_valid;
         saw_reject = reject;
         if (sector_valid) begin
            n_valid     = n_valid + 1;
            last_addr   = dec_addr;
            last_sector = dec_sector;
         end
         if (reject) n_reject = n_reject + 1;
         if (amark)  n_amark  = n_amark + 1;
      end
   endtask

   // a hand-driven byte (the encoder is parked)
   task push(input [7:0] d, input m);
      begin
         #1 man_data = d; man_mark = m;
         step;
      end
   endtask

   // ── hand-built fields, for the cases the encoder cannot produce ────────
   task push_sync;
      integer i;
      begin
         for (i = 0; i < 12; i = i + 1) push(8'h00, 1'b0);
      end
   endtask

   task push_marks(input integer n);
      integer i;
      begin
         for (i = 0; i < n; i = i + 1) push(8'hA1, 1'b1);
      end
   endtask

   // an ID field naming (c, h, r) with size code n; `bad` corrupts its CRC.
   // r and n are FULL BYTES so the bench can present the values the medium
   // cannot hold (section 12).
   task push_id_raw(input [6:0] c, input h, input [7:0] r, input [7:0] n, input bad);
      reg [15:0] k;
      begin
         push_sync;
         push_marks(3);
         k = CRC_SEED;
         push(8'hFE, 1'b0);          k = crc16(k, 8'hFE);
         push({1'b0, c}, 1'b0);      k = crc16(k, {1'b0, c});
         push({7'd0, h}, 1'b0);      k = crc16(k, {7'd0, h});
         push(r, 1'b0);              k = crc16(k, r);
         push(n, 1'b0);              k = crc16(k, n);
         if (bad) k = k ^ 16'h0001;
         push(k[15:8], 1'b0);
         push(k[7:0],  1'b0);
      end
   endtask

   // the ordinary case: an in-range sector, N=2 (512 bytes)
   task push_id(input [6:0] c, input h, input [4:0] r, input bad);
      begin
         push_id_raw(c, h, {3'd0, r}, 8'h02, bad);
      end
   endtask

   // a data field carrying block `blk`'s payload; `bad` corrupts its CRC,
   // `cut` aborts it with a fresh A1 run after 100 payload bytes
   task push_data(input [12:0] blk, input bad, input cut);
      reg [15:0] k;
      integer i;
      begin
         push_sync;
         push_marks(3);
         k = CRC_SEED;
         push(8'hFB, 1'b0);          k = crc16(k, 8'hFB);
         for (i = 0; i < 512; i = i + 1) begin
            if (cut && i == 100) begin
               push_marks(3);        // a splice mid-field
               i = 512;              // abandon the rest
            end else begin
               push(img_byte({blk, 9'd0} + i[8:0]), 1'b0);
               k = crc16(k, img_byte({blk, 9'd0} + i[8:0]));
            end
         end
         if (!cut) begin
            if (bad) k = k ^ 16'h0100;
            push(k[15:8], 1'b0);
            push(k[7:0],  1'b0);
         end
      end
   endtask

   // ── drain the recovered payload; the caller has stopped pulsing ready ──
   reg [7:0] recovered [0:511];
   task drain;
      integer i;
      begin
         for (i = 0; i < 512; i = i + 1) begin
            #1 buf_addr = i[8:0];
            @(posedge clk);          // buf_data <= buf_mem[buf_addr] here
            #1 recovered[i] = buf_data;
         end
      end
   endtask

   // the two independent positive checks, against the block we expect
   task verify(input [12:0] blk, input [639:0] tag);
      integer i;
      reg ok_id, ok_all;
      begin
         ok_id = (recovered[0] === blk[7:0]) &&
                 (recovered[1] === {3'b000, blk[12:8]}) &&
                 (recovered[2] === (blk[7:0] ^ {3'b000, blk[12:8]} ^ 8'h5A));
         check(ok_id, tag);          // payload names its own block
         ok_all = 1'b1;
         for (i = 0; i < 512; i = i + 1)
            if (recovered[i] !== img_byte(last_addr + i[21:0])) ok_all = 1'b0;
         check(ok_all, "every payload byte must match the image at `addr`");
         check(last_addr === {blk, 9'd0}, "`addr` must be this block's offset");
      end
   endtask

   task do_reset;
      begin
         #1 rst = 1; enc_drive = 1; ready = 0;
         repeat (4) @(posedge clk);
         @(posedge clk);
         #1 rst = 0;
         #1;                         // let combinational odata settle
      end
   endtask

   // ── the encoder-driven round trip over one whole track ─────────────────
   integer spt;
   reg [17:0] seen;
   integer i, guard;
   reg [12:0] exp_block;

   task round_trip(input [6:0] t, input s, input is_hd, input [639:0] tag);
      begin
         #1 track = t; side = s; hd = is_hd;
         spt = is_hd ? 18 : 9;
         do_reset;
         seen  = 18'd0;
         guard = 0;
         // one revolution is 12422 bytes (HD) / 6674 (DD); allow 1.5
         while (guard < 20000 && seen != ((1 << spt) - 1)) begin
            step;
            if (saw_valid) begin
               exp_block = (t * 2 + s) * spt + (last_sector - 1);
               drain;
               verify(exp_block, tag);
               check(last_sector >= 5'd1 && last_sector <= spt[4:0],
                     "the committed sector number is on the medium");
               if (last_sector >= 1 && last_sector <= spt)
                  seen[last_sector - 1] = 1'b1;
            end
            guard = guard + 1;
         end
         check(seen === ((1 << spt) - 1), "every sector of the track was recovered exactly once");
      end
   endtask

   initial begin
      // ─── 1. HD: the encoder's own track decodes back, sector for sector ──
      $display("1. HD 18spt: encoder track -> decoder, payload and address byte-exact");
      round_trip(7'd3, 1'b1, 1'b1, "HD payload must name its own block");
      check(n_reject == 0, "a clean encoder track must produce no rejects");
      check(n_amark == 18, "all 18 ID fields were seen and CRC-checked");

      // ─── 2. DD: the same, at 9 sectors ──────────────────────────────────
      $display("2. DD 9spt: the same round trip at the 720K geometry");
      n_reject = 0; n_amark = 0;
      round_trip(7'd40, 1'b0, 1'b0, "DD payload must name its own block");
      check(n_reject == 0, "a clean DD track must produce no rejects");
      check(n_amark == 9, "all 9 ID fields were seen");

      // ─── 3. the ordinary sector write: a DATA FIELD ALONE, plus the anchor
      $display("3. a lone data field is placed by the anchor");
      #1 track = 7'd5; side = 1'b0; hd = 1'b1;
      do_reset;
      #1 enc_drive = 0;
      #1 anchor_sector = 5'd7; anchor_valid = 1'b1;
      exp_block = (5 * 2 + 0) * 18 + (7 - 1);
      n_valid = 0; n_reject = 0;
      push_data(exp_block, 1'b0, 1'b0);
      check(n_valid == 1, "a CRC-valid data field with an anchor commits");
      check(last_sector === 5'd7, "it commits under the anchor's sector number");
      drain;
      verify(exp_block, "the anchored payload must name its own block");

      // ─── 4. no anchor, no ID: REFUSE, never guess ───────────────────────
      $display("4. with neither an ID nor an anchor the field is refused");
      #1 anchor_valid = 1'b0;
      n_valid = 0; n_reject = 0;
      push_data(exp_block, 1'b0, 1'b0);
      check(n_valid == 0, "an unplaceable data field must NOT commit");
      check(n_reject == 1, "and must be counted as a refusal");

      // ─── 5. a corrupt data CRC never reaches the image ──────────────────
      $display("5. a data field with a bad CRC is refused");
      #1 anchor_sector = 5'd4; anchor_valid = 1'b1;
      n_valid = 0; n_reject = 0;
      push_data((5 * 2 + 0) * 18 + (4 - 1), 1'b1, 1'b0);
      check(n_valid == 0, "a bad data CRC must never commit");
      check(n_reject == 1, "and must be counted as a refusal");

      // ─── 6. a corrupt ID arms nothing; the anchor still places the data ──
      $display("6. a bad ID CRC arms nothing - the data falls back to the anchor");
      #1 anchor_sector = 5'd9; anchor_valid = 1'b1;
      n_valid = 0; n_reject = 0; n_amark = 0;
      push_id(7'd5, 1'b0, 5'd2, 1'b1);            // claims sector 2, bad CRC
      check(n_amark == 0, "a bad ID must not be announced");
      check(n_reject == 1, "a bad ID is a refusal");
      exp_block = (5 * 2 + 0) * 18 + (9 - 1);
      push_data(exp_block, 1'b0, 1'b0);
      check(n_valid == 1, "the data field still commits, via the anchor");
      check(last_sector === 5'd9, "under the ANCHOR's sector, not the bad ID's");
      drain;
      verify(exp_block, "the fallback payload must name its own block");

      // ─── 7. an out-of-range sector number is refused ────────────────────
      $display("7. sector 0 and sector spt+1 are both off the medium");
      n_valid = 0; n_reject = 0;
      #1 anchor_sector = 5'd0; anchor_valid = 1'b1;      // 1-based: 0 is invalid
      push_data(13'd0, 1'b0, 1'b0);
      check(n_valid == 0, "sector 0 must not commit");
      #1 anchor_sector = 5'd19; anchor_valid = 1'b1;     // 18spt: 19 is off
      push_data(13'd0, 1'b0, 1'b0);
      check(n_valid == 0, "a sector past spt must not commit");
      check(n_reject == 2, "both were counted as refusals");

      // ─── 8. one ID arms exactly ONE data field ──────────────────────────
      $display("8. an ID arms one data field; the next falls back to the anchor");
      #1 anchor_sector = 5'd11; anchor_valid = 1'b1;
      n_valid = 0; n_reject = 0;
      push_id(7'd5, 1'b0, 5'd3, 1'b0);
      exp_block = (5 * 2 + 0) * 18 + (3 - 1);
      push_data(exp_block, 1'b0, 1'b0);
      check(last_sector === 5'd3, "the first data field takes the ID's sector");
      exp_block = (5 * 2 + 0) * 18 + (11 - 1);
      push_data(exp_block, 1'b0, 1'b0);
      check(last_sector === 5'd11, "the second falls back to the anchor, not the stale ID");
      check(n_valid == 2, "both fields committed");

      // ─── 9. a splice mid-field abandons it ──────────────────────────────
      $display("9. an A1 run inside a field abandons it");
      #1 anchor_sector = 5'd6; anchor_valid = 1'b1;
      n_valid = 0; n_reject = 0;
      push_data(13'd0, 1'b0, 1'b1);       // cut after 100 payload bytes
      check(n_valid == 0, "a cut data field must not commit");
      check(n_reject >= 1, "and must be counted as a refusal");

      // ─── 10. an ID cannot reach another track ───────────────────────────
      $display("10. position comes from the head, identity only from the field");
      #1 track = 7'd3; side = 1'b0; hd = 1'b1;
      do_reset;
      #1 enc_drive = 0;
      #1 anchor_valid = 1'b0;
      n_valid = 0;
      push_id(7'd60, 1'b1, 5'd5, 1'b0);   // claims cyl 60 head 1 while on 3/0
      exp_block = (3 * 2 + 0) * 18 + (5 - 1);
      push_data(exp_block, 1'b0, 1'b0);
      check(n_valid == 1, "the field commits");
      check(last_addr === {exp_block, 9'd0},
            "at the PHYSICAL track/side - the ID's cylinder must not steer `addr`");
      check(amark_cyl === 7'd60 && amark_head === 1'b1,
            "the claimed cylinder/head are still reported for the caller to police");

      // ─── 11. the sync run and the address mark itself ───────────────
      // Added after a mutant survived: removing the "three A1s" guard changed
      // nothing the bench measured, so the guard was untested. A field reached
      // with a short mark run is one we joined part-way through - the start we
      // never saw could have been anything.
      $display("11. a short A1 run, and an address mark we do not implement");
      #1 anchor_sector = 5'd6; anchor_valid = 1'b1;
      n_valid = 0; n_reject = 0;
      push_sync;
      push_marks(2);                      // only two: not a field we saw start
      push(8'hFB, 1'b0);
      for (i = 0; i < 8; i = i + 1) push(8'h00, 1'b0);
      check(n_valid == 0, "a data field behind fewer than three A1s must not commit");
      check(n_reject >= 1, "and the short run is a refusal");

      n_valid = 0; n_reject = 0;
      push_sync;
      push_marks(3);
      push(8'hF0, 1'b0);                  // not FE/FB/F8
      for (i = 0; i < 8; i = i + 1) push(8'h00, 1'b0);
      check(n_valid == 0, "an unimplemented address mark must not commit");
      check(n_reject == 1, "and is refused once, at the mark");

      // F8 (deleted data) is decoded as data. The Mac never writes one, but a
      // real separator does not distinguish them, and pinning the behaviour
      // here stops it drifting silently.
      n_valid = 0;
      #1 anchor_sector = 5'd6; anchor_valid = 1'b1;
      exp_block = (3 * 2 + 0) * 18 + (6 - 1);
      begin : deleted_data
         reg [15:0] k;
         push_sync;
         push_marks(3);
         k = CRC_SEED;
         push(8'hF8, 1'b0);  k = crc16(k, 8'hF8);
         for (i = 0; i < 512; i = i + 1) begin
            push(img_byte({exp_block, 9'd0} + i[8:0]), 1'b0);
            k = crc16(k, img_byte({exp_block, 9'd0} + i[8:0]));
         end
         push(k[15:8], 1'b0);
         push(k[7:0],  1'b0);
      end
      check(n_valid == 1, "a deleted-data mark decodes as data");
      check(last_addr === {exp_block, 9'd0}, "and lands at the anchor's sector");

      // ─── 12. an ID the medium could not hold arms nothing ────────────
      // Both of these reach the arming decision with a PERFECT CRC, so the
      // CRC cannot be what stops them. R is captured into five bits, so a
      // truncating capture would turn sector 33 into sector 1 and write a
      // format's payload there; N names the sector size, and we decode 512
      // bytes whatever it says. Silent-wrong-write paths, hence refusals.
      $display("12. an oversized R and a non-512 N are refused, CRC notwithstanding");
      #1 track = 7'd3; side = 1'b0; hd = 1'b1;
      do_reset;
      #1 enc_drive = 0;
      #1 anchor_valid = 1'b0;             // no fallback: an arm is the only way in
      n_valid = 0; n_reject = 0; n_amark = 0;
      push_id_raw(7'd3, 1'b0, 8'd33, 8'h02, 1'b0);   // R = 33: not in five bits
      check(n_amark == 0, "an R past 31 must not be announced as an ID");
      check(n_reject == 1, "and is a refusal");
      push_data((3 * 2 + 0) * 18 + (1 - 1), 1'b0, 1'b0);
      check(n_valid == 0, "the data field behind it must not commit as sector 1");

      n_valid = 0; n_reject = 0; n_amark = 0;
      push_id_raw(7'd3, 1'b0, 8'd5, 8'h03, 1'b0);    // N = 3: 1024-byte sectors
      check(n_amark == 0, "a sector size other than 512 must not be announced");
      check(n_reject == 1, "and is a refusal");
      push_data((3 * 2 + 0) * 18 + (5 - 1), 1'b0, 1'b0);
      check(n_valid == 0, "and arms no data field");

      $display("");
      $display("tb_mfm_write_decoder: %0d checks, %0d failures", checks, fails);
      if (fails == 0) $display("PASS"); else $display("FAIL");
      $finish;
   end

endmodule
