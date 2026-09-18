// tb_mul_modes.v - directed equivalence bench for the TG68 kernel's MULU/MULS
// datatype path (the combinational-loop fix of 2026-09-15).
//
// WHY THIS EXISTS. The kernel fix moved the execute-phase "long" override for
// MULU/MULS from `datatype` to `set_datatype` so that setexecOPC no longer
// feeds the EA-build block (rtl/tg68k/TG68KdotC_Kernel.vhd, MUL site). The
// argument that this is behaviour-preserving turns on the (An)-source forms,
// where old and new `datatype` differ transiently. The 400-frame boot trace
// exercises register, immediate and (d16,An) multiplies but NEVER a plain (An),
// (An)+ or -(An) source, so this bench drives those directly.
//
// WHAT IT DOES. Instantiates the generated kernel with clkena_in tied high and
// a combinational 64 KB word memory (1-cycle bus). Runs a hand-assembled
// program that executes every word and long multiply addressing mode, stores
// D0-D7 and CCR after each phase, then spins. Every cycle with bus activity is
// printed as one line; the memory results are dumped at the end.
//
// HOW TO USE. Build+run once per kernel netlist and diff the two logs; they
// must be byte-identical:
//   cd verilator
//   git show <old>:rtl/tg68k/TG68KdotC_Kernel.v > /tmp/old_kernel.v
//   $ verilator --binary --timing -Wno-fatal -Wno-lint -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
//         -Wno-CASEINCOMPLETE -Wno-LATCH --Mdir /tmp/tbmul_old tb_mul_modes.v /tmp/old_kernel.v \
//       --top-module tb_mul_modes && /tmp/tbmul_old/Vtb_mul_modes > /tmp/mul_old.log
//   (same with ../rtl/tg68k/TG68KdotC_Kernel.v -> /tmp/mul_new.log)
//   diff /tmp/mul_old.log /tmp/mul_new.log     # must be empty
//
// The generated kernel defines the same module names in both netlists, so the
// two cannot be compiled into one simulation; run twice and diff.

`timescale 1ns/1ps

module tb_mul_modes;
    reg         clk = 0;
    reg         nReset = 0;
    wire [15:0] data_in;
    wire [31:0] addr_out;
    wire [15:0] data_write;
    wire        nWr, nUDS, nLDS, longword, nResetOut, clr_berr, skipFetch;
    wire [1:0]  busstate;
    wire [2:0]  FC;
    wire [31:0] regin_out, VBR_out;
    wire [3:0]  CACR_out;

    // 64 KB of 16-bit words, addressed by addr_out[15:1].
    reg [15:0] mem [0:32767];

    TG68KdotC_Kernel cpu (
        .clk            (clk),
        .nReset         (nReset),
        .clkena_in      (1'b1),
        .data_in        (data_in),
        .IPL            (3'b111),
        .IPL_autovector (1'b0),
        .berr           (1'b0),
        .CPU            (2'b11),        // 68020, as tg68k.v drives it
        .addr_out       (addr_out),
        .data_write     (data_write),
        .nWr            (nWr),
        .nUDS           (nUDS),
        .nLDS           (nLDS),
        .busstate       (busstate),
        .longword       (longword),
        .nResetOut      (nResetOut),
        .FC             (FC),
        .clr_berr       (clr_berr),
        .skipFetch      (skipFetch),
        .regin_out      (regin_out),
        .CACR_out       (CACR_out),
        .VBR_out        (VBR_out)
    );

    assign data_in = mem[addr_out[15:1]];

    integer i, cycle;

    // Program image ------------------------------------------------------
    task w(input [15:0] a, input [15:0] d); begin mem[a[15:1]] = d; end endtask

    initial begin
        for (i = 0; i < 32768; i = i + 1) mem[i] = 16'h4E71;   // nop everywhere
        // reset vectors: SSP=$3000, PC=$0400
        w(16'h0000, 16'h0000); w(16'h0002, 16'h3000);
        w(16'h0004, 16'h0000); w(16'h0006, 16'h0400);
        // data
        w(16'h1000, 16'h0007); w(16'h1002, 16'h0005);
        w(16'h1004, 16'h0003); w(16'h1006, 16'h0009);
        w(16'h1008, 16'hFFFE); w(16'h100A, 16'h0002);

        // ---- code at $0400 -------------------------------------------------
        // word multiplies, one per addressing mode
        w(16'h0400, 16'h41F8); w(16'h0402, 16'h1000);   // lea   ($1000).w,a0
        w(16'h0404, 16'h43F8); w(16'h0406, 16'h2000);   // lea   ($2000).w,a1
        w(16'h0408, 16'h7003);                          // moveq #3,d0
        w(16'h040A, 16'h7205);                          // moveq #5,d1
        w(16'h040C, 16'h7407);                          // moveq #7,d2
        w(16'h040E, 16'h7601);                          // moveq #1,d3
        w(16'h0410, 16'h7802);                          // moveq #2,d4
        w(16'h0412, 16'h7A03);                          // moveq #3,d5
        w(16'h0414, 16'h7C04);                          // moveq #4,d6
        w(16'h0416, 16'h7E05);                          // moveq #5,d7
        w(16'h0418, 16'hCCF0); w(16'h041A, 16'h4000);   // mulu.w (0,a0,d4.w),d6   mode 110  (d4=2 -> $1002)
        w(16'h041C, 16'hC0D0);                          // mulu.w (a0),d0          mode 010  <- the loop case
        w(16'h041E, 16'hC3D8);                          // muls.w (a0)+,d1         mode 011
        w(16'h0420, 16'hC4E0);                          // mulu.w -(a0),d2         mode 100
        w(16'h0422, 16'hC6FC); w(16'h0424, 16'h1234);   // mulu.w #$1234,d3        mode 111/100
        w(16'h0426, 16'hC8C0);                          // mulu.w d0,d4            mode 000
        w(16'h0428, 16'hCAE8); w(16'h042A, 16'h0002);   // mulu.w (2,a0),d5        mode 101
        w(16'h042C, 16'hCEF8); w(16'h042E, 16'h1000);   // mulu.w ($1000).w,d7     mode 111/000
        w(16'h0430, 16'h22C0); w(16'h0432, 16'h22C1);   // move.l d0,(a1)+ ; d1
        w(16'h0434, 16'h22C2); w(16'h0436, 16'h22C3);   // d2 ; d3
        w(16'h0438, 16'h22C4); w(16'h043A, 16'h22C5);   // d4 ; d5
        w(16'h043C, 16'h22C6); w(16'h043E, 16'h22C7);   // d6 ; d7
        w(16'h0440, 16'h42D9);                          // move ccr,(a1)+
        // a signed multiply that sets N, then CCR
        w(16'h0442, 16'h7003);                          // moveq #3,d0
        w(16'h0444, 16'hC1E8); w(16'h0446, 16'h0008);   // muls.w (8,a0),d0  (-2 * 3 = -6)
        w(16'h0448, 16'h22C0);                          // move.l d0,(a1)+
        w(16'h044A, 16'h42D9);                          // move ccr,(a1)+
        // long multiplies (68020), one per addressing mode
        w(16'h044C, 16'h7003);                          // moveq #3,d0
        w(16'h044E, 16'h4C10); w(16'h0450, 16'h0000);   // mulu.l (a0),d0          mode 010
        w(16'h0452, 16'h4C18); w(16'h0454, 16'h1800);   // muls.l (a0)+,d1         mode 011
        w(16'h0456, 16'h4C20); w(16'h0458, 16'h2000);   // mulu.l -(a0),d2         mode 100
        w(16'h045A, 16'h4C3C); w(16'h045C, 16'h3000);   // mulu.l #16,d3           mode 111/100
        w(16'h045E, 16'h0000); w(16'h0460, 16'h0010);
        w(16'h0462, 16'h4C00); w(16'h0464, 16'h4000);   // mulu.l d0,d4            mode 000
        w(16'h0466, 16'h4C28); w(16'h0468, 16'h5000);   // mulu.l (2,a0),d5        mode 101
        w(16'h046A, 16'h0002);
        w(16'h046C, 16'h4C38); w(16'h046E, 16'h7000);   // mulu.l ($1000).w,d7     mode 111/000
        w(16'h0470, 16'h1000);
        w(16'h0472, 16'h22C0); w(16'h0474, 16'h22C1);   // stores d0..d7
        w(16'h0476, 16'h22C2); w(16'h0478, 16'h22C3);
        w(16'h047A, 16'h22C4); w(16'h047C, 16'h22C5);
        w(16'h047E, 16'h22C6); w(16'h0480, 16'h22C7);
        w(16'h0482, 16'h42D9);                          // move ccr,(a1)+
        // 64-bit result form, (An) source
        w(16'h0484, 16'h4C10); w(16'h0486, 16'h0401);   // mulu.l (a0),d1:d0
        w(16'h0488, 16'h22C0); w(16'h048A, 16'h22C1);   // store d0, d1
        w(16'h048C, 16'h42D9);                          // move ccr,(a1)+
        // the 42ae7a6 path right after a multiply: cmp.l (An) then Bcc
        w(16'h048E, 16'hB090);                          // cmp.l (a0),d0
        w(16'h0490, 16'h6702);                          // beq.s +2
        w(16'h0492, 16'h7001);                          // moveq #1,d0   (taken when NE)
        w(16'h0494, 16'h22C0);                          // move.l d0,(a1)+
        w(16'h0496, 16'h42D9);                          // move ccr,(a1)+
        w(16'h0498, 16'h60FE);                          // bra.s *
    end

    // Clock and reset -----------------------------------------------------
    always #5 clk = ~clk;
    initial begin
        nReset = 0;
        repeat (8) @(posedge clk);
        nReset = 1;
    end

    // Memory writes + per-cycle log --------------------------------------
    always @(posedge clk) begin
        if (nReset && busstate == 2'b11 && !nWr) begin
            if (!nUDS) mem[addr_out[15:1]][15:8] <= data_write[15:8];
            if (!nLDS) mem[addr_out[15:1]][7:0]  <= data_write[7:0];
        end
    end

    initial begin
        cycle = 0;
        // give the CPU 3000 cycles: plenty for ~60 instructions on a 1-cycle bus
        while (cycle < 3000) begin
            @(negedge clk);
            if (nReset && busstate != 2'b01)
                $display("%5d %08x din=%04x dout=%04x wr=%b uds=%b lds=%b bs=%b lw=%b fc=%b",
                         cycle, addr_out, data_in, data_write, nWr, nUDS, nLDS, busstate, longword, FC);
            cycle = cycle + 1;
        end
        $display("---- results at $2000 ----");
        for (i = 0; i < 32; i = i + 1)
            $display("%04x: %04x", 16'h2000 + i*2, mem[16'h1000 + i]);
        $display("---- final PC area: addr=%08x bs=%b ----", addr_out, busstate);
        $finish;
    end
endmodule
