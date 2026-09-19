/* tb_floppy_track_encoder.v — Phase 0 standalone bench for the GCR track encoder.
 *
 * WHY THIS EXISTS (2026-09-14, docs/floppy_write_plan.md Phase 0): writing to a
 * floppy means DECODING the GCR stream the guest hands back, and a decoder is
 * only trustworthy if it is the algebraic inverse of the encoder we actually
 * ship. This bench produces the ground truth for that: it drives the real
 * rtl/floppy_track_encoder.v over a synthetic 800K image and dumps the raw byte
 * stream, which scripts/gcr_decode_track.py must round-trip byte-exactly.
 * Validating the decoder against a Python MODEL of the encoder instead would
 * prove only that two readings of the same Verilog agree with each other.
 *
 * `ready` IS A SPARSE ONE-CYCLE PULSE, NOT A LEVEL. In the real system
 * (rtl/floppy.v) ready is `~old_newByteReady & newByteReady`, one pulse per
 * disk byte time (~128 clk). The encoder's `addr` register updates every clk
 * REGARDLESS of ready, so it has those idle cycles to settle onto the current
 * (sector, src_offset) before each ready-gated fetch. Holding ready high every
 * cycle starves that settle time and produces an address-pipeline artifact —
 * some source bytes fetched twice, others never — that cannot happen on
 * hardware. MacPlus hit exactly this and it was caught by the round-trip, not
 * by inspection. READY_GAP=8 keeps the ratio honest without simulating 128.
 *
 * EDGE DISCIPLINE: every stimulus change happens #1 AFTER a clock edge, never
 * at one. Driving a signal at zero delay after @(posedge clk) leaves it to the
 * simulator's process ordering whether the DUT sees the old or new value — a
 * hazard that bit the MacPlus benches four separate times.
 *
 * Build + run (Icarus 12.x, from the REPO ROOT so the relative paths resolve):
 *   python scripts/gcr_gen_image.py --hex
 *   /c/iverilog/bin/iverilog -g2012 -o scratch/gcr_phase0/tb_enc.vvp \
 *     verilator/tb_floppy_track_encoder.v rtl/floppy_track_encoder.v
 *   /c/iverilog/bin/vvp scratch/gcr_phase0/tb_enc.vvp
 *   python scripts/gcr_decode_track.py
 *
 * Plusargs:
 *   +alltracks   sweep all 80 tracks x 2 sides (default: 0, 16, 40, 79 x 2)
 *   +ncap=N      bytes captured per track (default 20000, >2 revolutions even
 *                at the densest track: spt=12 x ~778 B/sector = ~9336 B/rev)
 *   +outdir=DIR  where the dumps go (default scratch/gcr_phase0)
 *   +imghex=F    $readmemh source (default scratch/gcr_phase0/image.hex)
 */
`timescale 1ns/1ps

module tb_floppy_track_encoder;

   localparam READY_GAP = 8;   // clk cycles per ready pulse (real HW: ~128)

   reg        clk   = 0;
   reg        ready = 0;
   reg        rst   = 1;
   reg        side  = 0;
   reg        sides = 1;       // double-sided, matching the synthetic image
   reg [6:0]  track = 0;

   wire [21:0] addr;
   wire [7:0]  odata;

   reg [7:0] mem [0:819199];
   wire [7:0] idata = mem[addr];

   floppy_track_encoder dut (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .addr(addr), .idata(idata), .odata(odata),
      // format relay idle (plan Phase 6A): this bench drives the read side only
      .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0)
   );

   always #5 clk = ~clk;

   integer CYCLES;
   integer i, t, s, fd, total;
   reg [8*256-1:0] outdir, imghex, fname;
   reg alltracks;

   // One ready-gated encoder step. Idle low for READY_GAP-1 cycles (the
   // diskDataByteTimer counting between bytes), then exactly one cycle high.
   task tick;
      begin
         repeat (READY_GAP - 1) @(posedge clk);
         #1 ready = 1;
         @(posedge clk);        // the DUT advances on THIS edge
         #1 ready = 0;          // released after it, and odata settles in the gap
      end
   endtask

   task run_track;
      input [6:0] tt;
      input       ss;
      begin
         track = tt;
         side  = ss;
         rst   = 1;
         @(posedge clk);
         @(negedge clk);        // deassert away from the posedge: the DUT's
         #1 rst = 0;            // reset is `posedge clk or posedge rst`
         @(negedge clk);
         #1;                    // let combinational odata settle before sample 0

         $sformat(fname, "%0s/track%0d_side%0d.bin", outdir, tt, ss);
         fd = $fopen(fname, "wb");
         if (fd == 0) begin
            $display("ERROR: cannot open %0s for writing", fname);
            $finish;
         end
         for (i = 0; i < CYCLES; i = i + 1) begin
            $fwrite(fd, "%c", odata);   // sample, THEN advance
            tick;
         end
         $fclose(fd);
         total = total + 1;
      end
   endtask

   initial begin
      CYCLES = 20000;
      outdir = "scratch/gcr_phase0";
      imghex = "scratch/gcr_phase0/image.hex";
      total  = 0;
      alltracks = $test$plusargs("alltracks");
      if ($value$plusargs("ncap=%d",   CYCLES)) ;
      if ($value$plusargs("outdir=%s", outdir)) ;
      if ($value$plusargs("imghex=%s", imghex)) ;

      $readmemh(imghex, mem);
      $display("tb_floppy_track_encoder: image=%0s ncap=%0d gap=%0d %0s",
               imghex, CYCLES, READY_GAP, alltracks ? "ALL TRACKS" : "representative");

      if (alltracks) begin
         for (t = 0; t < 80; t = t + 1)
            for (s = 0; s < 2; s = s + 1)
               run_track(t[6:0], s[0]);
      end else begin
         run_track(7'd0,  1'b0);  run_track(7'd0,  1'b1);
         run_track(7'd16, 1'b0);  run_track(7'd16, 1'b1);
         run_track(7'd40, 1'b0);  run_track(7'd40, 1'b1);
         run_track(7'd79, 1'b0);  run_track(7'd79, 1'b1);
      end

      $display("wrote %0d track dumps of %0d bytes each to %0s", total, CYCLES, outdir);
      $finish;
   end

endmodule
