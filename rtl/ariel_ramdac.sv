// Ariel RAMDAC (343S1045/344S0145)
// Palette controller for Mac LC V8 video
//
// On real hardware the RAMDAC is clocked by V8's CULTDAC0 output (pixel
// clock). The video lookup port now IS in the pixel-clock domain (clk_pix,
// matching the schematic); the CPU register side stays on clk_sys. The
// palette RAM is a dual-clock M10K — the crossing lives inside the primitive
// (no_rw_check: a CPU palette write racing a lookup of the same entry can
// only tint one pixel for one frame).

module ariel_ramdac(
    input clk_sys,
    input clk_pix,   // pixel clock (video lookup port); sim passes clk_sys
    input reset,

    // CPU interface (mapped at 0x524000-0x525FFF)
    input [10:0] reg_addr,  // Word address bits (A1-A11)
    input uds_n,            // Upper data strobe (even byte)
    input lds_n,            // Lower data strobe (odd byte)
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,
    input mem_latch,       // memoryLatch (busPhase==3): one pulse per bus transaction
    input cpu_as_n,        // 68k _AS: low during a bus cycle, high between accesses

    // Palette lookup interface
    input [7:0] pixel_index,
    output reg [23:0] rgb_out,

    // Debug
    output reg ariel_written  // Goes high when any CPU write occurs
);

// Ariel register map (matching MAME ariel.cpp - byte offsets)
// 68k A0 is implicit in UDS/LDS, A1 is reg_addr[0]
// Byte offset 0 ($524000): Address register - A1=0, UDS active
// Byte offset 1 ($524001): Palette data     - A1=0, LDS active
// Byte offset 2 ($524002): Control register - A1=1, UDS active
// Byte offset 3 ($524003): Key color        - A1=1, LDS active
// Register select = {A1, ~LDS} = {reg_addr[0], ~lds_n}
localparam REG_ADDR       = 2'd0;
localparam REG_PALETTE    = 2'd1;
localparam REG_CTRL       = 2'd2;
localparam REG_KEY_COLOR  = 2'd3;

// Compute byte register from A1 and LDS
wire [1:0] byte_reg = {reg_addr[0], ~lds_n};

// Dual-port palette RAM: port A = CPU (clk_sys), port B = video lookup
// (clk_pix). 256 entries x 24 bits (8:8:8 RGB). no_rw_check: the two ports
// are in different clock domains (see header).
(* ramstyle = "M10K,no_rw_check" *) reg [23:0] palette [0:255];

// Palette address counter
reg [7:0] palette_addr;
reg [1:0] color_comp; // 0=R, 1=G, 2=B
reg [7:0] control_reg;
reg [7:0] key_color;

// Latched palette entry for CPU read/modify/write of individual components
reg [23:0] palette_latch;

// Reset-based initialization
reg        init_active;
reg [8:0]  init_addr;  // 9-bit to count to 256

// Compute an initial *colorful* palette so any pixel_index produces a
// distinguishable color at boot — much easier to recognize on screen than
// the old all-grey ramp. The pattern groups indices into 8 hue bins of 32
// entries each (idx[7:5] = hue), with brightness ramping inside each bin
// (idx[4:0] -> shade 0..255 in 8-step increments).
//   bin 0 = red, 1 = green, 2 = blue, 3 = yellow,
//   bin 4 = cyan, 5 = magenta, 6 = white-grey, 7 = orange
wire [7:0] init_bri = {init_addr[4:0], 3'b000};   // 0..248 brightness ramp
wire [7:0] init_r =
    (init_addr[7:5] == 3'd0) ? init_bri :              // red
    (init_addr[7:5] == 3'd3) ? init_bri :              // yellow
    (init_addr[7:5] == 3'd5) ? init_bri :              // magenta
    (init_addr[7:5] == 3'd6) ? init_bri :              // white/grey
    (init_addr[7:5] == 3'd7) ? init_bri :              // orange (full red)
                               8'h00;
wire [7:0] init_g =
    (init_addr[7:5] == 3'd1) ? init_bri :              // green
    (init_addr[7:5] == 3'd3) ? init_bri :              // yellow
    (init_addr[7:5] == 3'd4) ? init_bri :              // cyan
    (init_addr[7:5] == 3'd6) ? init_bri :              // white/grey
    (init_addr[7:5] == 3'd7) ? {1'b0, init_bri[7:1]} : // orange (half green)
                               8'h00;
wire [7:0] init_b =
    (init_addr[7:5] == 3'd2) ? init_bri :              // blue
    (init_addr[7:5] == 3'd4) ? init_bri :              // cyan
    (init_addr[7:5] == 3'd5) ? init_bri :              // magenta
    (init_addr[7:5] == 3'd6) ? init_bri :              // white/grey
                               8'h00;

// Video lookup (port B) - synchronous read for block RAM inference.
// Pixel-clock domain: maclc_v8_video issues pixel_index and consumes rgb_out
// one clk_pix later (its de_d1 pipeline compensates exactly this latency).
always @(posedge clk_pix) begin
    rgb_out <= palette[pixel_index];
end

// `req`/`we`/`mem_latch` are asserted across SEVERAL bus slots during one CPU
// access. The palette data register AUTO-INCREMENTS R->G->B on every fire, so
// firing on every mem_latch advanced the DAC several times per write — the
// single byte the OS sent for one component got stored into all three, so
// every CLUT entry collapsed to grey (R=G=B) and color rendered as greyscale.
// (memoryLatch alone is NOT once-per-access: a 68k write spans multiple bus
// cycles, each with its own busPhase==3 pulse.)
//
// Arm a one-shot per CPU access using _AS, which deasserts between every
// access — even back-to-back ones — so exactly one register action happens per
// CPU access. This is the same proven pattern the ASC uses (rtl/asc.sv) and it
// directly fixes the auto-increment over-advance. Data is still captured at
// mem_latch, where it is stable; only the COUNT of advances changes.
// Fire only when a data strobe is actually asserted (~uds_n | ~lds_n). On a 68k
// WRITE, _LDS/_UDS assert LATER than _AS; without this gate the one-shot could
// capture at a mem_latch before the strobe settled and misdecode byte_reg =
// {reg_addr[0],~lds_n} — REG_PALETTE (lds) writes would alias to REG_ADDR (uds),
// so the CLUT fill lands in the address register and the palette is never written
// (uniform color cast). This was latent until the SDRAM slot-00 reclaim (commit
// 90c7696) gave the CPU an earlier DTACK slot, firing the one-shot before _LDS.
// The one-shot must DISARM on the same gated condition it fires on, else it could
// disarm on an early strobe-less mem_latch and drop the access entirely.
reg ariel_armed;
wire req_stb = ariel_armed && req && mem_latch && (~uds_n | ~lds_n);
always @(posedge clk_sys) begin
    if (reset)         ariel_armed <= 1'b1;
    else if (cpu_as_n) ariel_armed <= 1'b1; // access ended -> re-arm
    else if (req_stb)  ariel_armed <= 1'b0; // captured this access (strobe valid)
end

// CPU register access (matching MAME ariel.cpp behavior)
// byte_reg = {A1, ~LDS} selects register 0-3
always @(posedge clk_sys) begin
    if (reset) begin
        palette_addr <= 8'd0;
        color_comp <= 2'd0;
        control_reg <= 8'd0;
        ariel_written <= 1'b0;
        key_color <= 8'd0;
        palette_latch <= 24'h0;
        init_active <= 1'b1;
        init_addr <= 9'd0;
    end else if (init_active) begin
        // Initialize palette from reset counter (one entry per clock).
        // Rainbow init replaces old greyscale ramp — every pixel_index value
        // now maps to a visually distinct color.
        palette[init_addr[7:0]] <= {init_r, init_g, init_b};
        if (init_addr == 9'd255)
            init_active <= 1'b0;
        init_addr <= init_addr + 9'd1;
    end else if (req_stb) begin
        if (we) begin
            ariel_written <= 1'b1;
            case (byte_reg)
                REG_ADDR: begin
                    // Writing address resets the R/G/B component counter
                    palette_addr <= data_in;
                    color_comp <= 2'd0;
                    // Latch current palette entry for component writes
                    palette_latch <= palette[data_in];
                end
                REG_PALETTE: begin
                    // Write to current color component, cycle through R, G, B
                    case (color_comp)
                        2'd0: begin
                            palette_latch[23:16] <= data_in;
                            palette[palette_addr] <= {data_in, palette_latch[15:0]};
                        end
                        2'd1: begin
                            palette_latch[15:8] <= data_in;
                            palette[palette_addr] <= {palette_latch[23:16], data_in, palette_latch[7:0]};
                        end
                        2'd2: begin
                            palette_latch[7:0] <= data_in;
                            palette[palette_addr] <= {palette_latch[23:8], data_in};
                        end
                        default: ;
                    endcase

                    // Auto-increment: cycle R->G->B, then advance address
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                        // Latch next entry for subsequent writes
                        palette_latch <= palette[palette_addr + 8'd1];
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                REG_CTRL: control_reg <= data_in;
                REG_KEY_COLOR: key_color <= data_in;
            endcase
        end else begin
            // Read registers
            case (byte_reg)
                REG_ADDR: begin
                    data_out <= palette_addr;
                    color_comp <= 2'd0;  // Reading address also resets component counter
                end
                REG_PALETTE: begin
                    case (color_comp)
                        2'd0: data_out <= palette_latch[23:16];
                        2'd1: data_out <= palette_latch[15:8];
                        2'd2: data_out <= palette_latch[7:0];
                        default: data_out <= 8'hFF;
                    endcase

                    // Auto-increment on read too
                    if (color_comp == 2'd2) begin
                        color_comp <= 2'd0;
                        palette_addr <= palette_addr + 8'd1;
                        palette_latch <= palette[palette_addr + 8'd1];
                    end else begin
                        color_comp <= color_comp + 2'd1;
                    end
                end
                REG_CTRL: data_out <= control_reg;
                REG_KEY_COLOR: data_out <= key_color;
            endcase
        end
    end
end

endmodule
