// Mac LC V8 Video Controller - FIXED
// Supports 1, 2, 4, 8, and 16 bpp modes correctly

module maclc_v8_video(
    input clk_sys,
    input clk8_en_p,
    input reset,

    input [2:0] video_mode,
    input [3:0] monitor_id,

    // Test/diagnostic controls
    input        test_bypass_vram,  // 1 = ignore VRAM, generate synthetic pattern
    input [1:0]  test_pattern_sel,  // 0=hbar, 1=vbar, 2=checker, 3=h^v xor

    output reg hsync,
    output reg vsync,
    output reg hblank,
    output reg vblank,

    output reg [7:0] vga_r,
    output reg [7:0] vga_g,
    output reg [7:0] vga_b,
    output reg de,
    output reg ce_pix,

    output [7:0] palette_addr,
    input [23:0] palette_data,

    // Active words per scanline (= h_active*bpp/16). Exported so addrController
    // can pack CPU VRAM writes into the on-chip framebuffer (stride-gap removed).
    output [10:0] words_per_line,

    // On-chip framebuffer (BRAM) read port (Phase 2): the scanline prefetch now
    // reads from vram_bram instead of the shared SDRAM slot. Registered read.
    output [17:0] vram_raddr,
    input  [15:0] vram_rdata
);

reg [10:0] h_total, h_active, h_sync_start, h_sync_end;
reg [9:0] v_total, v_active, v_sync_start, v_sync_end;

// Bits per pixel and fetch mask configuration
reg [4:0] bits_per_pixel; // 1, 2, 4, 8, 16
reg [3:0] fetch_mask;     // When to fetch new word

always @(*) begin
    case (video_mode)
        3'd0: begin bits_per_pixel = 1;  fetch_mask = 4'hF; end // 1bpp: Fetch every 16
        3'd1: begin bits_per_pixel = 2;  fetch_mask = 4'h7; end // 2bpp: Fetch every 8
        3'd2: begin bits_per_pixel = 4;  fetch_mask = 4'h3; end // 4bpp: Fetch every 4
        3'd3: begin bits_per_pixel = 8;  fetch_mask = 4'h1; end // 8bpp: Fetch every 2
        3'd4: begin bits_per_pixel = 16; fetch_mask = 4'h0; end // 16bpp: Fetch every 1
        default: begin bits_per_pixel = 1; fetch_mask = 4'hF; end
    endcase
end

always @(*) begin
    // Standard V8 monitor timings
    case (monitor_id)
        4'h1: begin // 12" RGB (512x384)
             h_total = 11'd832; h_active = 11'd640; // Note: MAME maps active to 512, but V8 uses 640 timing
             h_sync_start = 11'd656; h_sync_end = 11'd752;
             v_total = 10'd918; v_active = 10'd870;
             v_sync_start = 10'd871; v_sync_end = 10'd877;
        end
        4'h2: begin // 12" RGB Alternate
            h_total = 11'd640; h_active = 11'd512;
            h_sync_start = 11'd528; h_sync_end = 11'd576;
            v_total = 10'd407; v_active = 10'd384;
            v_sync_start = 10'd385; v_sync_end = 10'd388;
        end
        default: begin // VGA 640x480 (Monitor ID 6)
            h_total = 11'd800; h_active = 11'd640;
            h_sync_start = 11'd656; h_sync_end = 11'd752;
            v_total = 10'd525; v_active = 10'd480;
            v_sync_start = 10'd490; v_sync_end = 10'd492;
        end
    endcase
end

reg [10:0] h_count;
reg [9:0] v_count;

// Pixel clock enable: divide clk_sys by 2
// clk_sys=32.5MHz / 2 = 16.25MHz pixel clock (close to Mac LC's 15.6672MHz)
// NOTE: a fractional (Bresenham) pix_en for a 25.175MHz VGA dot clock was tried
// and REVERTED — with CLK_VIDEO fixed at clk_sys, a non-uniform CE_PIXEL makes
// the clk_sys-cycles-per-line jitter, which the scaler renders as a shaky image.
// A proper 640x480@60Hz needs a dedicated 25.175MHz PLL clock, not a fractional enable.
reg pix_div;
always @(posedge clk_sys) begin
    if (reset)
        pix_div <= 0;
    else
        pix_div <= ~pix_div;
end

wire pix_en = pix_div;

always @(posedge clk_sys) begin
    ce_pix <= pix_en;
    if (reset) begin
        h_count <= 0;
        v_count <= 0;
    end else if (pix_en) begin
        if (h_count == h_total - 1) begin
            h_count <= 0;
            v_count <= (v_count == v_total - 1) ? 10'd0 : v_count + 10'd1;
        end else
            h_count <= h_count + 11'd1;
    end
end

reg de_raw;  // Internal DE before pipeline delay

always @(posedge clk_sys) begin
    if (pix_en) begin
        hsync <= (h_count >= h_sync_start && h_count < h_sync_end);
        vsync <= (v_count >= v_sync_start && v_count < v_sync_end);
        hblank <= (h_count >= h_active);
        vblank <= (v_count >= v_active);
        de_raw <= (h_count < h_active) && (v_count < v_active);
    end
end

// COMBINATIONAL blanks (aligned to h_count/v_count), used by the fetch and display
// FSMs. The registered hblank/vblank OUTPUTS above lag h_count/v_count by one
// pix_en, so gating internal logic on them slipped the first-pixel / first-line
// work one step late — a white col 0 (display FSM) and a corrupted first scanline
// at the left edge (fetch side). Use these non-lagged versions internally.
wire hblank_c = (h_count >= h_active);
wire vblank_c = (v_count >= v_active);

`ifdef SIMULATION
reg [3:0] monitor_id_prev;
always @(posedge clk_sys) begin
    if (monitor_id != monitor_id_prev) begin
        `ifdef VERBOSE_TRACE
        $display("V8: monitor_id changed to %h @%0t", monitor_id, $time);
        `endif
        monitor_id_prev <= monitor_id;
    end
end
`endif

// --- Video Address Generation (packed on-chip framebuffer) ---
// vram_bram stores each scanline as words_per_line CONTIGUOUS words (the V8's
// 1024-byte stride gap is removed by the packing in addrController). Display
// line L therefore lives at packed word offset L*words_per_line, which we
// accumulate per scanline to avoid a per-pixel multiply.

// Words (16-bit) per displayed scanline = h_active*bpp/16.
// 640-wide: 1bpp=40, 2bpp=80, 4bpp=160, 8bpp=320. 512-wide 16bpp=512.
//
// The product MUST be computed at full width before the >>4. words_per_line is
// only 11 bits, and `(h_active * bits_per_pixel) >> 4` evaluates the multiply in
// that 11-bit context, so it wraps mod 2048 for any mode whose product reaches
// 2048 — corrupting exactly the high-bpp modes: 4bpp@640 (640*4=2560 -> 512 ->
// /16 = 32 not 160), 8bpp@640 (5120 -> 1024 -> 64 not 320), 4bpp@512 (2048 -> 0
// -> ALL WHITE), 16bpp@512 (8192 -> 0). 1/2bpp (<=1280) stayed under 2048, which
// is why they always rendered full-width. This single truncation was the
// long-hunted "bpp-dependent video cut" (NOT memory bandwidth/backend).
wire [15:0] wpl_product = h_active * bits_per_pixel;   // full width (max 640*16=10240)
assign words_per_line = wpl_product[14:4];             // /16; max 640 fits 11 bits

// Packed word base of the current (display) scanline.
reg [17:0] packed_row_start;
always @(posedge clk_sys) begin
    if (reset || (pix_en && h_count == h_total - 1 && v_count == v_total - 1))
        packed_row_start <= 18'd0;
    else if (pix_en && h_count == h_total - 1 && v_count < v_active)
        packed_row_start <= packed_row_start + {7'd0, words_per_line};
end

// ============================================================
// Scanline line-buffer (ping-pong) — decouples the VRAM fetch
// rate from the pixel display rate. While line L displays from
// one buffer, the next line is prefetched into the other. Buffer
// is chosen by scanline PARITY (no explicit swap): even lines ->
// buffer 0, odd lines -> buffer 1. So disp_buf = v_count[0] and
// the fetch fills ~v_count[0] (the next line). One word now feeds
// exactly 16/bpp pixels — the old "shift distribution" stretching
// and the 1bpp dedup hack are gone, so every depth renders its
// true horizontal resolution. Async (combinational) read keeps the
// first pixel of each line correct across the parity flip; the
// 512-word/buffer array maps to MLAB/LUTRAM (simple dual port).
// 16bpp@512 = 512 words exactly; 8bpp@640 = 320 (the 640-wide max).
// ============================================================
(* ramstyle = "MLAB,no_rw_check" *) reg [15:0] linebuf [0:1023];  // {buf, idx[8:0]}

// --- Fetch side: prefetch the NEXT scanline into ~disp_buf from vram_bram ---
// One word per clk_sys, no bus arbitration: the whole line fills in
// <= words_per_line clocks of the ~1600-clock line, always completing before it
// displays. vram_bram reads are registered, so the linebuf write lags the issued
// address by one cycle (fetch_pend / fetch_wr_idx / fetch_buf_d).
reg        fetch_buf;
reg [17:0] fetch_packed_base;
always @(*) begin
    if (vblank_c) begin   // combinational: registered vblank lags one pix_en and
                          // corrupted the first scanline's prefetch (left-edge artifact)
        fetch_buf         = 1'b0;        // prefetch line 0 into buffer 0
        fetch_packed_base = 18'd0;
    end else begin
        fetch_buf         = ~v_count[0]; // next line's parity
        fetch_packed_base = packed_row_start + {7'd0, words_per_line};
    end
end

reg [9:0] fetch_idx;      // address-phase word index
reg [9:0] fetch_wr_idx;   // write-phase index (1 cycle behind = BRAM read latency)
reg       fetch_pend;     // a read was issued last cycle (its data is valid now)
reg       fetch_buf_d;    // fetch_buf aligned to the write phase

assign vram_raddr = fetch_packed_base + {8'd0, fetch_idx};

// SDRAM video path retired in Phase 2 — video reads the on-chip framebuffer.

always @(posedge clk_sys) begin
    if (reset) begin
        fetch_idx    <= 10'd0; fetch_pend  <= 1'b0;
        fetch_wr_idx <= 10'd0; fetch_buf_d <= 1'b0;
    end else if (pix_en && h_count == h_total - 1) begin
        fetch_idx <= 10'd0; fetch_pend <= 1'b0;   // restart prefetch each scanline
    end else begin
        // Address phase: issue one BRAM read per clk while words remain.
        if (fetch_idx < words_per_line) begin
            fetch_pend   <= 1'b1;
            fetch_wr_idx <= fetch_idx;
            fetch_buf_d  <= fetch_buf;
            fetch_idx    <= fetch_idx + 1'b1;
        end else begin
            fetch_pend <= 1'b0;
        end
        // Write phase: commit the word whose read was issued last cycle.
        if (fetch_pend)
            linebuf[{fetch_buf_d, fetch_wr_idx[8:0]}] <= vram_rdata;
    end
end

// --- Display side: read the current line from buffer v_count[0] at
// the pixel rate. px_in_word counts down the pixels left in the word. ---
reg [15:0] pixel_shift;
reg [15:0] video_data;     // current word (for 16bpp direct color)
reg [8:0]  disp_idx;       // next word to load from the line buffer
reg [3:0]  px_in_word;     // pixels remaining in the loaded word

wire [15:0] disp_word = linebuf[{v_count[0], disp_idx}];  // async read

wire [3:0] px_per_word =
    (bits_per_pixel == 5'd1)  ? 4'd15 :   // 16 px/word
    (bits_per_pixel == 5'd2)  ? 4'd7  :   //  8
    (bits_per_pixel == 5'd4)  ? 4'd3  :   //  4
    (bits_per_pixel == 5'd8)  ? 4'd1  :   //  2
                                4'd0;     // 16bpp: 1 px/word

// Display side gates on hblank_c/vblank_c (declared up top): the registered blanks
// lag one pix_en, which left col 0 showing the primed pixel_shift (=0 -> 0x7F white
// in 1bpp) and shifted each line right by one. At h_count==0 v_count has already
// advanced to this line, so the word-0 read linebuf[{v_count[0],0}] is correct.
always @(posedge clk_sys) begin
    if (reset) begin
        disp_idx    <= 0;
        px_in_word  <= 0;
        pixel_shift <= 16'h0000;
        video_data  <= 16'h0000;
    end else if (pix_en) begin
        if (hblank_c || vblank_c) begin
            // Prime for the first pixel of the next line.
            disp_idx    <= 0;
            px_in_word  <= 0;
            pixel_shift <= 16'h0000;
            video_data  <= 16'h0000;
        end else if (px_in_word == 0) begin
            // Load a fresh word (async read of word disp_idx), advance pointer.
            pixel_shift <= disp_word;
            video_data  <= disp_word;
            disp_idx    <= disp_idx + 1'b1;
            px_in_word  <= px_per_word;
        end else begin
            px_in_word <= px_in_word - 1'b1;
            case (bits_per_pixel)
                5'd1:  pixel_shift <= {pixel_shift[14:0], 1'b0};
                5'd2:  pixel_shift <= {pixel_shift[13:0], 2'b0};
                5'd4:  pixel_shift <= {pixel_shift[11:0], 4'b0};
                5'd8:  pixel_shift <= {pixel_shift[7:0],  8'b0};
                5'd16: ;
            endcase
        end
    end
end

reg [7:0] pixel_index_real;
reg [7:0] pixel_index_test;
wire [7:0] pixel_index;

// --- Pixel Extraction ---
// We extract from the MSB (Big Endian Mac format)
// MAME uses specific palette index patterns (see v8.cpp:530, 554, 575, 593):
// 1bpp: 0x7F | (bit ? 0x80 : 0) → 0x7F (white) or 0xFF (black)
// 2bpp: 0x3F | (2-bit << 6) → 0x3F, 0x7F, 0xBF, 0xFF
// 4bpp: 0x0F | (4-bit << 4) → 0x0F, 0x1F, 0x2F, ..., 0xFF
// 8bpp: direct 0x00-0xFF
always @(*) begin
    case (video_mode)
        3'd0: pixel_index_real = {pixel_shift[15], 7'b1111111};            // 1bpp: 0x7F or 0xFF
        3'd1: pixel_index_real = {pixel_shift[15:14], 6'b111111};          // 2bpp: 0x3F, 0x7F, 0xBF, 0xFF
        3'd2: pixel_index_real = {pixel_shift[15:12], 4'b1111};            // 4bpp: 0x0F-0xFF
        3'd3: pixel_index_real = pixel_shift[15:8];                        // 8bpp: direct
        default: pixel_index_real = 8'd0;
    endcase
end

// Synthetic test patterns (don't need VRAM data to render):
//   0 = horizontal color bars  (vertical stripes shown by h_count[8:1])
//   1 = vertical color bars    (horizontal stripes shown by v_count[7:0])
//   2 = 8x8 checker            (h_count[3] XOR v_count[3] selects two extreme indices)
//   3 = h XOR v gradient       (classic XOR pattern, exercises all 256 entries)
always @(*) begin
    case (test_pattern_sel)
        2'd0: pixel_index_test = h_count[8:1];
        2'd1: pixel_index_test = v_count[7:0];
        2'd2: pixel_index_test = (h_count[3] ^ v_count[3]) ? 8'h00 : 8'hFF;
        2'd3: pixel_index_test = h_count[7:0] ^ v_count[7:0];
        default: pixel_index_test = 8'd0;
    endcase
end

assign pixel_index = test_bypass_vram ? pixel_index_test : pixel_index_real;
assign palette_addr = pixel_index;

// Pipeline delay: palette RAM read is synchronous (1-cycle latency),
// so delay de, video_mode, and video_data to align with palette_data output.
reg        de_d1;
reg [2:0]  video_mode_d1;
reg [15:0] video_data_d1;

always @(posedge clk_sys) begin
    de_d1         <= de_raw;
    video_mode_d1 <= video_mode;
    video_data_d1 <= video_data;
end

always @(posedge clk_sys) begin
    de <= de_d1;  // Align DE output with RGB (1-cycle palette latency)
    if (de_d1) begin
        if (video_mode_d1 == 3'd4) begin
            // 16bpp Direct Color (X-5-5-5)
            vga_r <= {video_data_d1[14:10], 3'b000};
            vga_g <= {video_data_d1[9:5],   3'b000};
            vga_b <= {video_data_d1[4:0],   3'b000};
        end else begin
            // Palette Lookup
            vga_r <= palette_data[23:16];
            vga_g <= palette_data[15:8];
            vga_b <= palette_data[7:0];
        end
    end else begin
        vga_r <= 8'd0;
        vga_g <= 8'd0;
        vga_b <= 8'd0;
    end
end

endmodule