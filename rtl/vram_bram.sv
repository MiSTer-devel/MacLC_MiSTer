// ============================================================================
// vram_bram.sv — On-chip dual-port framebuffer (VRAM) for the Mac LC V8 core.
//
// WHY: the Mac LC framebuffer was kept in external memory (shared SDRAM, then an
// HPS-DDR3 experiment). Both starved the video fetch (~64 of 160 words/line at
// 4bpp) — not from lack of *bandwidth* (4bpp needs only ~9 MB/s) but from bus
// sharing + read latency. On-chip BRAM is true dual-port and single-cycle, so the
// CPU can write port A while video reads port B every clock with zero contention.
//
// SIZE: DEPTH = 196,608 words (384 KB) = the largest supported framebuffer,
// 16bpp @ 512x384. 640x480 @ 16bpp is not a Mac LC mode and is out of scope.
//
// INFERENCE: this MUST map to M10K block RAM. A single 16-bit array written with
// a sub-word *byte enable* (mem[a][7:0] <= ...) did NOT infer as block RAM in
// Quartus 17 Lite — it was built in logic and Analysis & Synthesis ballooned to
// ~20 GB. The robust fix is to split the framebuffer into two BYTE-WIDE simple-
// dual-port RAMs, each written with a plain (whole-word) write enable. That is the
// textbook M10K template and infers reliably; it also stays plain Verilog so the
// sim builds it identically. Reads are registered (1-cycle latency).
//
// Dual-clock (pixel-clock scanout): port A (CPU write) runs on clk_sys, port B
// (video read) on the V8 pixel clock. M10K is true dual-port with independent
// port clocks, so the crossing lives INSIDE the RAM primitive — no timed
// cross-domain paths (no_rw_check applies; a CPU write racing a video read of
// the same word can only produce one transiently stale pixel).
// ============================================================================
module vram_bram #(
    parameter integer DEPTH = 196608,   // 16bpp @ 512x384 = 384KB / 2 bytes
    parameter integer AW    = 18         // ceil(log2(DEPTH))
)(
    // Port A — CPU write (byte-masked), a_clk (= clk_sys) domain. a_dout is
    // reserved for a later phase (CPU VRAM reads still come from SDRAM today).
    input             a_clk,
    input  [AW-1:0]   a_addr,
    input  [15:0]     a_din,
    input  [1:0]      a_be,     // {upper, lower} byte write strobes
    input             a_we,
    output reg [15:0] a_dout,

    // Port B — video read, b_clk (= pixel clock) domain
    input             b_clk,
    input  [AW-1:0]   b_addr,
    output [15:0]     b_dout
);

    // Two byte-wide simple-dual-port RAMs (lower/upper byte lane). Each has a
    // plain write enable -> clean M10K inference (no sub-word byte-enable).
    (* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_lo [0:DEPTH-1];
    (* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_hi [0:DEPTH-1];

    reg [7:0] q_lo, q_hi;

    // Port A: byte-masked write (whole-byte WE per lane).
    always @(posedge a_clk) if (a_we && a_be[0]) mem_lo[a_addr] <= a_din[7:0];
    always @(posedge a_clk) if (a_we && a_be[1]) mem_hi[a_addr] <= a_din[15:8];

    // Port B: registered read (video).
    always @(posedge b_clk) q_lo <= mem_lo[b_addr];
    always @(posedge b_clk) q_hi <= mem_hi[b_addr];
    assign b_dout = {q_hi, q_lo};

    // Reserved CPU read port — unused in Phase 1/2 (CPU reads come from SDRAM).
    always @(posedge a_clk) a_dout <= 16'h0000;

endmodule
