// egret_wrapper.sv - Egret microcontroller for Mac LC
// Uses m68hc05_core CPU with real Egret ROM (341S0851)
//
// Based on MAME's egret.cpp by R. Belmont
// m68hc05_core converted from VHDL by Ulrich Riedel
//
// This is a drop-in replacement for egret.sv with the exact same interface

`default_nettype none

module egret_wrapper (
    input  wire        clk,
    input  wire        clk8_en,
    input  wire        reset,

    // RTC timestamp initialization (Unix time)
    input  wire [32:0] timestamp,

    // Direct VIA Port B connections
    input  wire        via_tip,          // VIA Port B bit 5 - Transaction In Progress (active low)
    input  wire        via_byteack_in,   // VIA Port B bit 4 - from VIA
    output wire        cuda_treq,        // Port B bit 3 - Transfer Request (active LOW)
    output wire        cuda_byteack,     // Port B bit 4 - Byte Acknowledge

    // VIA Shift Register interface (CB1/CB2)
    output wire        cuda_cb1,         // CB1 - Shift clock (Egret drives in external mode)
    input  wire        via_cb2_in,       // CB2 - Data from VIA (when VIA sending)
    output wire        cuda_cb2,         // CB2 - Data to VIA (when Egret sending)
    output wire        cuda_cb2_oe,      // CB2 output enable

    // VIA SR control signals
    input  wire        via_sr_read,      // VIA is reading SR (shift in mode)
    input  wire        via_sr_write,     // VIA has written SR (shift out mode)
    input  wire        via_sr_ext_clk,   // VIA is in external clock mode
    input  wire        via_sr_dir,       // VIA shift direction: 0=in, 1=out
    output reg         cuda_sr_irq,      // Request SR interrupt

    // Full port B for completeness
    output wire [7:0]  cuda_portb,       // Complete Port B output
    output wire [7:0]  cuda_portb_oe,    // Port B output enables

    // ADB signals (simplified)
    input  wire        adb_data_in,
    output reg         adb_data_out,

    // System control
    output reg         reset_680x0,
    output reg         nmi_680x0,

    // ---- PRAM persistence (additive: NVRAM save/restore via top-level SD DMA) ----
    // pram[] (below) is the canonical 256-byte PRAM: seeded into the HC05 RAM at
    // boot and kept in sync with firmware PRAM-region writes, so the top level can
    // snapshot/restore it. The Egret boot/SR logic is unchanged by these ports.
    input  wire        pram_load_wr,    // SD -> pram[]: write one byte
    input  wire  [7:0] pram_load_addr,
    input  wire  [7:0] pram_load_data,
    input  wire  [7:0] pram_save_addr,  // pram[] -> SD: read one byte (async)
    output wire  [7:0] pram_save_data,
    output wire        pram_wr_stb,      // 1-cyc strobe: firmware wrote a PRAM byte
    input  wire        pram_ready,       // top: SD load of pram[] complete (or no image / timeout)

    // Debug outputs for on-screen indicators
    output wire        dbg_cen,              // HC05 clock enable (pulse)
    output wire        dbg_port_test_done,   // Port test phase complete
    output wire        dbg_handshake_done,   // Handshake init complete
    output wire        dbg_treq,             // TREQ output (1=asserting)
    output wire        dbg_tip_in,           // TIP input from VIA (synced)
    output wire        dbg_byteack_in,       // BYTEACK input from VIA (synced)
    output wire [7:0]  dbg_pb_out,           // Egret Port B output register
    output wire [7:0]  dbg_pc_out,           // Egret Port C output register
    output wire        dbg_cpu_running       // HC05 is executing (not in reset)
);

// ============================================================================
// Clock generation for 68HC05
// MAME: M68HC05E1 runs at XTAL(32'768)*128 = 4.194304 MHz
// From 32 MHz system clock, divide by 8 gives 4 MHz (close to 4.19 MHz)
// ============================================================================
reg [2:0] clk_div;
wire cen = (clk_div == 3'b000);  // Pulse once every 8 cycles = 4 MHz

always @(posedge clk) begin
    if (reset)
        clk_div <= 3'b000;
    else
        clk_div <= clk_div + 3'b001;
end

// ============================================================================
// Memory map for Egret (68HC05E1 with 13-bit address space)
// ============================================================================
// 0x0000-0x001F: I/O registers (Ports A, B, C, DDR, Timer, etc.)
// 0x0090-0x01FF: Internal RAM (368 bytes for PRAM, RTC, stack, variables)
// 0x0F00-0x1FFF: ROM (4352 bytes = 0x1100)
//
// ROM file is 4352 bytes and maps directly:
// - CPU 0x0F00 → ROM offset 0x000 (first 256 bytes are copyright notice)
// - CPU 0x1FFF → ROM offset 0x10FF (last byte)
// - Reset vector at CPU 0x1FFE-0x1FFF → ROM offset 0x10FE-0x10FF

localparam ROM_SIZE = 4352;  // 0x1100 bytes - maps to CPU 0x0F00-0x1FFF

// CPU signals (from m68hc05_core)
wire [15:0] cpu_addr;
wire        cpu_wr;
wire [7:0]  cpu_din;
wire [7:0]  cpu_dout;
wire [3:0]  cpu_state;

// Port registers (68HC05 style)
reg  [7:0] pa_ddr, pb_ddr;
reg  [7:0] pa_latch, pb_latch;
reg  [7:0] pc_ddr, pc_latch;  // Full 8 bits for port test compatibility

// Port I/O
reg  [7:0] pa_out, pb_out;
reg  [7:0] pc_out;  // 8 bits for port test (only lower 4 bits used for actual I/O)

// Memory
// MLAB (ported 2026-08-08 from MacIIvi 9f5d0d3): as plain registers these two
// arrays cost ~1.5-2k ALMs (368:1 and 256:1 async byte read muxes + write
// decode) — the bulk of the wrapper's ~4.3k self-ALMs. MLAB keeps the
// async-read semantics the HC05's combinational RAM path needs (M10K could
// not). Inference additionally required the PRAM boot-copy below to become a
// sequential one-byte-per-cycle engine — a 256-parallel-write burst is not a
// RAM port. Same recipe as m10k-repack tier 1 (2026-07-18).
(* ramstyle = "MLAB" *) reg  [7:0] intram[0:367];    // Internal RAM: intram[x] = CPU addr 0x90+x (RAM at 0x90-0x1FF)
reg  [7:0] ram_dout;

// ROM
reg  [7:0] rom[0:8191];  // 2^13 to match 13-bit rom_addr width (only 4352 bytes used)
reg  [7:0] rom_dout;

// PRAM storage (256 bytes loaded from disk)
(* ramstyle = "MLAB" *) reg  [7:0] pram[0:255];
reg        pram_loaded;
reg        pc_bit3_prev;        // (legacy; PC3 edge no longer gates the boot-copy)

// Initialize ROM and PRAM from hex files
integer init_i;
initial begin
`ifdef SIMULATION
    $readmemh("../rtl/egret/egret_rom.hex", rom);
    $display("EGRET ROM: Loaded %0d bytes from ../rtl/egret/egret_rom.hex", ROM_SIZE);
    $readmemh("../rtl/egret/egret.pram", pram);
    $display("EGRET PRAM: Loaded 256 bytes from ../rtl/egret/egret.pram");
`else
    $readmemh("rtl/egret/egret_rom.hex", rom);
    $readmemh("rtl/egret/egret.pram", pram);
`endif

    // Initialize RAM to zeros (critical for proper Egret firmware operation)
    // 368 bytes = 0x170 = RAM from 0x90-0x1FF
    for (init_i = 0; init_i < 368; init_i = init_i + 1) begin
        intram[init_i] = 8'h00;
    end

    pram_loaded = 1'b0;
    pc_bit3_prev = 1'b0;
end

// Address decoding - M68HC05E1 memory map from MAME
// The M68HC05E1 uses 13-bit addressing (0x0000-0x1FFF), higher bits wrap
// Ports: 0x00-0x02, DDRs: 0x04-0x06, PLL: 0x07, Timer: 0x08-0x09, OneSecond: 0x12
// RAM: 0x90-0x1FF
// ROM: 4352 bytes (0x1100) mapped at CPU 0x0F00-0x1FFF
// Simple linear mapping: ROM offset = CPU address - 0x0F00
wire [12:0] addr13 = cpu_addr[12:0];  // Mask to 13 bits for M68HC05E1
wire port_cs = (addr13 < 13'h0020);  // I/O registers at 0x00-0x1F (includes timer, onesec)
wire ram_cs  = (addr13 >= 13'h0090) && (addr13 < 13'h0200);  // RAM at 0x90-0x1FF
wire rom_cs  = (addr13 >= 13'h0F00);  // ROM covers 0x0F00-0x1FFF
// ROM address: simple offset from 0x0F00
// CPU 0x0F00 -> ROM[0x000], CPU 0x1FFF -> ROM[0x10FF]
wire [12:0] rom_addr = addr13 - 13'h0F00;
wire [8:0]  ram_addr = addr13[8:0] - 9'h90;  // RAM offset

// ============================================================================
// 68HC05E1 Timer (from MAME m68hc05e1.cpp)
// ============================================================================
// 0x07: PLL Control - sets timer rate (bits 0-1 = clock divider)
// 0x08: Timer Control Register
//       Bit 7: Timer flag (set on tick, cleared by writing 0)
//       Bit 6: Alternate timer flag
//       Bit 5: Timer interrupt enable
// 0x09: Timer Counter - 8-bit free-running, (total_cycles / 4) % 256
// 0x12: One-second timer (for RTC)

reg [7:0]  pll_ctrl;     // PLL control (0x07)
reg [7:0]  timer_ctrl;   // Timer control (0x08)
reg [7:0]  onesec_ctrl;  // One-second control (0x12)
reg [31:0] cycle_total;  // Total cycles for timer counter

// Timer prescaler based on PLL setting
reg [15:0] timer_prescale;
reg [15:0] timer_prescale_max;
reg [15:0] pll_lock_counter;

// Timer hardware logic is merged into the port/register write block below
// to avoid multiple drivers on pll_ctrl, timer_ctrl, onesec_ctrl

// Timer IRQ is level-sensitive: stays asserted while timer flag (bit 7) AND enable (bit 5) are set
// Firmware clears by writing 0 to bit 7 of timer_ctrl
wire timer_irq_n = ~(timer_ctrl[7] & timer_ctrl[5]);

// Timer counter reads as (total_cycles / 4) % 256
wire [7:0] timer_counter = cycle_total[9:2];  // Divide by 4, take lower 8 bits

// ============================================================================
// One-second timer (M68HC05E1-specific)
// ============================================================================
// The M68HC05E1 has a dedicated one-second timer that:
// 1. Generates an interrupt (vector $FFF6) -> ISR at $1E10 increments $CC
// 2. Sets Port C bit 1 as a hardware flag (for polling by firmware)
// Register $12 bit 4 enables the timer, bit 6 is cleared by ISR
//
// Real hardware: 32.768 kHz crystal / 32768 = 1 Hz
// Our approximation: count cen ticks (4 MHz). Use shorter period for simulation.
`ifdef SIMULATION
localparam ONESEC_PERIOD = 22'd8192;    // ~2ms at 4 MHz (fast for simulation)
`else
localparam ONESEC_PERIOD = 22'd4000000; // ~1 second at 4 MHz
`endif

reg [21:0] onesec_counter;
reg        onesec_irq_flag;  // Sticky flag, generates interrupt edge
wire       onesec_irq_n = ~onesec_irq_flag;

always @(posedge clk) begin
    if (reset) begin
        onesec_counter <= 22'd0;
        onesec_irq_flag <= 1'b0;
    end else if (cen) begin
        // Count when one-second timer is enabled (onesec_ctrl bit 4)
        if (onesec_ctrl[4]) begin
            if (onesec_counter >= ONESEC_PERIOD) begin
                onesec_counter <= 22'd0;
                onesec_irq_flag <= 1'b1;
                `ifdef VERBOSE_TRACE
                $display("EGRET_ONESEC[%0d]: Timer fired! Setting PC1 and IRQ", cycle_count);
                `endif
            end else begin
                onesec_counter <= onesec_counter + 22'd1;
            end
        end

        // Clear IRQ flag when firmware clears bit 6 of onesec_ctrl ($12)
        // The ISR does "BCLR 6,$12" as its last action before RTI
        if (port_cs && !cpu_wr && cpu_addr[4:0] == 5'h12) begin
            if (!(cpu_dout & 8'h40)) begin  // Writing 0 to bit 6
                onesec_irq_flag <= 1'b0;
            end
        end
    end
end

// ============================================================================
// Port A - ADB and system control
// ============================================================================
// Bit 7 (O): ADB data line out
// Bit 6 (I): ADB data line in
// Bit 5 (I): System type (1 = Egret controls power)
// Bit 4 (O): DFAC latch
// Bit 3 (O): 680x0 reset pulse
// Bit 2 (I): Keyboard power switch
// Bit 1-0: PSU control

// Port A input - bit 5 is system type (1 = Mac LC)
wire [7:0] pa_external = {
    1'b1,                   // Bit 7: tied high
    adb_data_in,            // Bit 6: ADB data in
    1'b1,                   // Bit 5: System type (1 = Mac LC)
    1'b1,                   // Bit 4: tied high
    1'b1,                   // Bit 3: tied high
    1'b1,                   // Bit 2: tied high
    1'b1,                   // Bit 1: tied high
    1'b1                    // Bit 0: tied high
};

wire [7:0] pa_in = port_test_done ?
    ((pa_latch & pa_ddr) | (pa_external & ~pa_ddr)) :
    pa_latch;

always @(*) begin
    adb_data_out = pa_out[7];
end

`ifdef SIMULATION
// Log ADB line drive edges with timestamps so we can derive the HC05's wire-level
// ADB cell timing (attention/sync/data cells) when designing the ADB device.
reg adb_out_prev;
always @(posedge clk) begin
    if (cen) begin
        if (adb_data_out !== adb_out_prev) begin
            $display("ADBLINE[%0d]: out=%b (line=%b) PA7=%b", cycle_count, adb_data_out, ~adb_data_out, pa_out[7]);
            adb_out_prev <= adb_data_out;
        end
    end
end
`endif

// ============================================================================
// Port B - VIA interface (this is the key interface)
// ============================================================================
// Bit 7 (O): DFAC clock (I2C SCL)
// Bit 6 (I/O): DFAC data (I2C SDA)
// Bit 5 (I/O): VIA shift register data = CB2
// Bit 4 (O): VIA clock = CB1
// Bit 3 (I): VIA SYS_SESSION = TIP from VIA
// Bit 2 (I): VIA_FULL (tied high for now)
// Bit 1 (O): VIA XCEIVER SESSION = TREQ to VIA
// Bit 0 (I): +5V sense

// Port B input handling:
// - During port test: use latch mode (so test passes)
// - After port test: use DDR-based mixing (for VIA communication)
//
// External signals (matching MAME's pb_r()):
// - bit 0: +5V sense (always 1)
// - bit 2: via_full/byteack from VIA
// - bit 3: sys_session (TIP from VIA PB5)
// - bit 5: via_data (CB2 from VIA)
// - bit 6: DFAC data (tied high)
// - bit 7: DFAC clock (output, external = 0)
// Clock domain crossing synchronizers for VIA signals
// CRITICAL: Sample on every system clock (32MHz), not just cen (4MHz)!
// The 68020 runs at 8MHz+ and can set TIP=0, then TIP=1 before Egret
// would see TIP=0 if we only sample at 4MHz. Sampling at 32MHz gives
// Egret 3 system cycles (~94ns) to see TIP changes.
reg [2:0] via_tip_sync;
reg [2:0] via_cb2_in_sync;
reg [2:0] via_byteack_in_sync;

always @(posedge clk) begin
    if (reset) begin
        via_tip_sync <= 3'b111;       // TIP idle high initially
        via_cb2_in_sync <= 3'b111;
        via_byteack_in_sync <= 3'b111;
    end else begin
        // Sample on EVERY clock, not just cen, to catch fast TIP changes
        via_tip_sync <= {via_tip_sync[1:0], via_tip};
        via_cb2_in_sync <= {via_cb2_in_sync[1:0], via_cb2_in};
        via_byteack_in_sync <= {via_byteack_in_sync[1:0], via_byteack_in};
    end
end

wire via_tip_stable = via_tip_sync[2];
wire via_cb2_in_stable = via_cb2_in_sync[2];
wire via_byteack_in_stable = via_byteack_in_sync[2];

// pb_external represents external signals read by Egret firmware
// BYTEACK (bit 2): LOW when VIA is ready for data, HIGH when VIA has data pending
// The firmware uses BYTEACK in two contexts:
// - At 0x12AF: brset 2, $01, $12A1 - needs BYTEACK=0 to proceed (start of communication)
// - At 0x14CE: brset 2, $01, $14D6 - needs BYTEACK=1 to call CB1 clocking (VIA has data)
wire [7:0] pb_external = {
    1'b0,                   // Bit 7: DFAC clock (external reads as 0)
    1'b1,                   // Bit 6: DFAC data (tied high)
    via_cb2_in_stable,      // Bit 5: CB2 data from VIA (synchronized)
    1'b0,                   // Bit 4: CB1 clock (external reads as 0)
    via_tip_effective,      // Bit 3: TIP from VIA (gated after reset release)
    via_byteack_in_stable,  // Bit 2: VIA_FULL/BYTEACK - from VIA PB4
    1'b0,                   // Bit 1: TREQ (external reads as 0)
    1'b1                    // Bit 0: +5V sense (always active)
};

// Port test mode: use latch reads for first N cycles, then switch to DDR mode
reg port_test_done;
reg [15:0] port_test_counter;

always @(posedge clk) begin
    if (reset) begin
        port_test_done <= 1'b0;
        port_test_counter <= 16'h0;
    end else if (cen && !port_test_done) begin
        port_test_counter <= port_test_counter + 1;
        if (port_test_counter >= 16'd500) begin  // ~500 cycles for port test
            port_test_done <= 1'b1;
        end
    end
end

// Use latch during port test, DDR-based mixing after
wire [7:0] pb_in = port_test_done ?
    ((pb_latch & pb_ddr) | (pb_external & ~pb_ddr)) :
    pb_latch;

// Handshake initialization state machine
// CRITICAL: XCVR_SESSION (TREQ) must be LOW before CB1 clocking starts (per MAME)
typedef enum logic [2:0] {
    INIT_WAIT,    // Wait for stable power
    INIT_ASSERT,  // Assert TREQ (XCVR_SESSION)
    INIT_DELAY,   // Hold TREQ before allowing clocking
    RUNNING       // Normal operation
} init_state_t;

init_state_t init_state;
reg [15:0] handshake_timer;
reg handshake_done;
reg force_treq;

// TIP gate: hold TIP at idle level (0 = no session) from Egret's perspective
// until the Egret firmware has entered its idle/communication loop. The firmware's main init loop at
// $1034-$1066 probes for ADB devices (dozens of iterations with timeouts),
// which takes far longer than the 68020's boot-to-first-Egret-command time.
// We detect when the Egret PC reaches $12AC (the TIP polling instruction in
// the idle loop) and only then release the gate, letting Egret see TIP.
reg        tip_gate_holding;
reg        egret_idle_reached;  // Set once Egret PC hits $12AC

always @(posedge clk) begin
    if (reset) begin
        tip_gate_holding <= 1'b0;
        egret_idle_reached <= 1'b0;
    end else if (cen) begin
        // Start holding TIP when 68020 is released from reset
        if (!reset_680x0_latched && !tip_gate_holding && !egret_idle_reached) begin
            tip_gate_holding <= 1'b1;
`ifdef SIMULATION
            $display("EGRET[%0d]: TIP gate started (waiting for idle loop at $12AC)", cycle_count);
`endif
        end

        // Detect Egret firmware reaching idle loop TIP poll at $12AC
        // addr13 is the 13-bit ROM address; $12AC in CPU space = $12AC
        if (!egret_idle_reached && rom_cs && cpu_wr && addr13 == 13'h12AC) begin
            egret_idle_reached <= 1'b1;
            tip_gate_holding <= 1'b0;
`ifdef SIMULATION
            $display("EGRET[%0d]: Idle loop reached! TIP gate released (real TIP=%b)", cycle_count, via_tip_stable);
`endif
        end
    end
end

// Gate value 0 = idle (PB5=0 on host = no session). Matches MAME: sys_session=0 means idle.
wire via_tip_effective = tip_gate_holding ? 1'b0 : via_tip_stable;

always @(posedge clk) begin
    if (reset) begin
        handshake_timer <= 0;
        handshake_done <= 0;
        force_treq <= 0;
        init_state <= INIT_WAIT;
    end else if (cen) begin
        // Removed force_treq state machine - let firmware control TREQ from start
        // The firmware initializes Port B with 0x92 (TREQ inactive), then asserts
        // TREQ via bclr 1, $01 at address 0x1549 when ready to transfer data.
        // The old state machine was forcing TREQ active from cycle 8192-14336,
        // which conflicted with firmware's 0x92 write at cycle ~9520.
        case (init_state)
            INIT_WAIT: begin
                // Skip straight to RUNNING - firmware controls TREQ
                if (handshake_timer == 16'h2000) begin
                    handshake_done <= 1'b1;
                    init_state <= RUNNING;
                    `ifdef SIMULATION
                    $display("EGRET_INIT[%0d]: Entering RUNNING state (firmware controls TREQ)", handshake_timer);
                    `endif
                end else begin
                    handshake_timer <= handshake_timer + 1;
                end
            end

            INIT_ASSERT: begin
                // Not used anymore
                init_state <= RUNNING;
            end

            INIT_DELAY: begin
                // Not used anymore
                init_state <= RUNNING;
            end

            RUNNING: begin
                // Normal operation - Egret controls TREQ via pb_out[1]
            end
        endcase
    end
end

// Output assignments
// CB1: Pass directly from Egret firmware. The V8 protocol uses TIP pulses as part
// of the handshake, so we should NOT gate CB1 based on TIP. The firmware controls
// CB1 timing explicitly for shift register clocking.
assign cuda_cb1    = pb_out[4];
assign cuda_cb2    = pb_out[5];
assign cuda_cb2_oe = pb_ddr[5];
// TREQ signal polarity with DDR gating and port test guard:
// - pb_out[1]=0 AND pb_ddr[1]=1 means Egret asserts TREQ (drives pin LOW = has data)
// - pb_out[1]=1 or pb_ddr[1]=0 means TREQ released (pin floats HIGH = idle)
// CRITICAL: Must check DDR to prevent spurious TREQ assertion during early boot
// when firmware clears port latches before setting DDR (pb_out=0x00, pb_ddr=0x00)
// ALSO: Don't assert TREQ during port test phase (firmware init writes 0x00 to Port B)
// dataController expects cuda_treq=1 when TREQ is asserted
assign cuda_treq = port_test_done & pb_ddr[1] & ~pb_out[1];

`ifdef VERBOSE_TRACE
// Debug cuda_treq formula - trace each component
reg cuda_treq_prev;
always @(posedge clk) begin
    if (reset) begin
        cuda_treq_prev <= 0;
    end else if (cen) begin
        if (cuda_treq != cuda_treq_prev) begin
            $display("EGRET_TREQ[%0d]: cuda_treq=%b->%b (port_test_done=%b, pb_ddr[1]=%b, pb_out[1]=%b, pb_latch[1]=%b, pb_ddr=%02x, pb_out=%02x)",
                     cycle_count, cuda_treq_prev, cuda_treq,
                     port_test_done, pb_ddr[1], pb_out[1], pb_latch[1], pb_ddr, pb_out);
        end
        cuda_treq_prev <= cuda_treq;
    end
end
`endif
assign cuda_byteack = 1'b0;       // Not used in Egret

assign cuda_portb    = pb_out;
assign cuda_portb_oe = pb_ddr;

// Debug outputs
assign dbg_cen            = cen;
assign dbg_port_test_done = port_test_done;
assign dbg_handshake_done = handshake_done;
assign dbg_treq           = cuda_treq;
assign dbg_tip_in         = via_tip_stable;
assign dbg_byteack_in     = via_byteack_in_stable;
assign dbg_pb_out         = pb_out;
assign dbg_pc_out         = pc_out;
assign dbg_cpu_running    = ~reset;

// ============================================================================
// Port C - 68000 control
// ============================================================================
// Bit 3 (O): 680x0 reset
// Bit 2: IPL2
// Bit 1-0: IPL1-0

// Port C input - use latch values for port test, but handle bit 3 specially.
// Port C is mostly outputs (reset, IPL) so we don't need external reads.
// The port test writes a value and expects to read it back.
//
// CRITICAL: When bit 3 (reset) is configured as INPUT (DDR[3]=0), the firmware
// expects it to read as 0 (reset released). This happens at 0x1291 after the
// firmware re-asserts reset at 0x128F. If we return the latch value (1), the
// 68020 stays in reset forever.
wire [7:0] pc_in = {pc_latch[7:4], (pc_ddr[3] ? pc_latch[3] : 1'b0), pc_latch[2:0]};

// 68020 reset control - match MAME behavior exactly
// Per MAME egret.cpp and egret.sv: pc_out[3]=1 means RELEASE, pc_out[3]=0 means HOLD
// (egret.sv uses: reset_680x0 = ~pc_out[3], so pc_out[3]=1 → reset_680x0=0 → release)
//
// We latch the reset state so that when the firmware switches pc_ddr[3] back to input
// (at $1291: BCLR3 $06), the 68020 stays in its last commanded state (released).
// Hold in reset until port_test_done AND firmware has configured PC bit 3 as output.
reg reset_680x0_latched;

always @(posedge clk) begin
    if (reset) begin
        reset_680x0_latched <= 1'b1;  // Hold 68020 in reset during Egret reset
    end else if (cen && port_test_done && pc_ddr[3]) begin
        // Only update when firmware is actively driving PC bit 3 as output
        // Invert: pc_out[3]=1 means release (reset_680x0=0), pc_out[3]=0 means hold (reset_680x0=1)
        reset_680x0_latched <= ~pc_out[3];
    end
end

always @(*) begin
    // Also hold the 68020 in reset until the saved PRAM has been copied into the
    // Egret's working RAM (pram_loaded) — so the CPU never starts executing on
    // pre-load PRAM, no matter how late the SD load of pram[] completes.
    reset_680x0 = reset_680x0_latched | ~pram_loaded;
    nmi_680x0 = 1'b0;
end

// ============================================================================
// Port output logic (68HC05 style: out = (latch & ddr) | (in & ~ddr))
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_out <= 8'h00;
        pb_out <= 8'h00;
        pc_out <= 8'h08;  // Bit 3 = 1: hold 68020 in reset initially (MAME behavior)
        pc_bit3_prev <= 1'b1;  // Match initial pc_out[3]
    end else if (cen) begin
        pa_out <= (pa_latch & pa_ddr) | (pa_in & ~pa_ddr);
        pb_out <= (pb_latch & pb_ddr) | (pb_in & ~pb_ddr);
        pc_out <= (pc_latch & pc_ddr) | (pc_in & ~pc_ddr);

        // Track Port C bit 3 (the PRAM boot-copy block below latches the 1->0
        // edge and waits for pram_ready before copying / setting pram_loaded)
        pc_bit3_prev <= pc_out[3];
    end
end

// PRAM loading flag - actual copy is done in the intram write block below
// to avoid multiple drivers on intram

// ============================================================================
// Port and DDR register writes
// ============================================================================
always @(posedge clk) begin
    if (reset) begin
        pa_latch <= 8'h00;
        pb_latch <= 8'h02;  // Bit 1 = 1 means TREQ inactive on startup (firmware writes 0x92 later)
        pc_latch <= 8'h00;
        pa_ddr   <= 8'h00;
        pb_ddr   <= 8'h00;  // All inputs on reset (firmware sets 0x92 = bits 7,4,1 outputs)
        pc_ddr   <= 8'h00;
        pll_ctrl <= 8'h00;
        timer_ctrl <= 8'h00;
        onesec_ctrl <= 8'h00;
        cycle_total <= 32'h0;
        timer_prescale <= 16'h0;
        timer_prescale_max <= 16'd1024;
        pll_lock_counter <= 16'h0;
    end else if (cen) begin
        // --- Timer hardware (runs every cen tick) ---
        // PLL lock after 500 cycles
        if (pll_lock_counter < 16'd500) begin
            pll_lock_counter <= pll_lock_counter + 1;
        end else begin
            pll_ctrl[6] <= 1'b1;  // Set LOCK bit
        end
        // Total cycle counter for timer
        cycle_total <= cycle_total + 1;
        // Prescaled timer tick
        timer_prescale <= timer_prescale + 1;
        if (timer_prescale >= timer_prescale_max) begin
            timer_prescale <= 0;
            timer_ctrl[7] <= 1'b1;
            `ifdef VERBOSE_TRACE
            if (timer_ctrl[5] && !timer_ctrl[7])
                $display("TIMER[%0d]: Tick, flag set (timer_ctrl=%02x)", cycle_count, timer_ctrl);
            `endif
        end

        // --- Port/register writes from CPU ---
        if (port_cs && !cpu_wr) begin  // !cpu_wr means write
        case (cpu_addr[4:0])  // 5 bits for 0x00-0x1F
            5'h00: pa_latch <= cpu_dout;
            5'h01: begin
                pb_latch <= cpu_dout;
`ifdef SIMULATION
                if (cpu_dout[4] != pb_latch[4])  // CB1 changed
                    $display("EGRET[%0d]: PB_W 0x%02x CB1=%b PC=%04x", cycle_count, cpu_dout, cpu_dout[4], last_pc);
`endif
            end
            5'h02: pc_latch <= cpu_dout;
            5'h04: pa_ddr   <= cpu_dout;
            5'h05: pb_ddr <= cpu_dout;  // Allow DDR writes - cuda_treq DDR gating prevents early TREQ
            5'h06: pc_ddr   <= cpu_dout;
            // M68HC05E1 registers
            5'h07: begin  // PLL control - sets timer rate
                pll_ctrl <= cpu_dout;
                // Set timer prescaler based on PLL clock bits
                case (cpu_dout[1:0])
                    2'b00: timer_prescale_max <= 16'd2048;   // 512 kHz / 1024 = ~500 Hz
                    2'b01: timer_prescale_max <= 16'd1024;   // 1 MHz / 1024 = ~1 kHz
                    2'b10: timer_prescale_max <= 16'd512;    // 2 MHz / 1024 = ~2 kHz
                    2'b11: timer_prescale_max <= 16'd256;    // 4 MHz / 1024 = ~4 kHz
                endcase
                `ifdef VERBOSE_TRACE
                $display("EGRET[%0d]: PLL write = 0x%02x (clock rate %0d)", cycle_count, cpu_dout, cpu_dout[1:0]);
                `endif
            end
            5'h08: begin  // Timer control
                // Clear flags by writing 0 to bits 7 or 6
                if (!(cpu_dout & 8'h80)) timer_ctrl[7] <= 1'b0;
                if (!(cpu_dout & 8'h40)) timer_ctrl[6] <= 1'b0;
                timer_ctrl[5:0] <= cpu_dout[5:0];
                `ifdef VERBOSE_TRACE
                $display("EGRET[%0d]: Timer ctrl write = 0x%02x", cycle_count, cpu_dout);
                `endif
            end
            5'h12: begin  // One-second timer
                onesec_ctrl <= cpu_dout;
            end
        endcase
        end // port_cs write

        // One-second timer hardware: set Port C bit 1 when timer fires
        // Per MAME m68hc05e1: m_portc_data |= 0x02 on one-second tick
        // This flag persists until firmware clears it (via Port C write)
        if (onesec_irq_flag && !pc_latch[1]) begin
            pc_latch[1] <= 1'b1;
            `ifdef VERBOSE_TRACE
            $display("EGRET_ONESEC[%0d]: Setting PC1 flag (Port C bit 1)", cycle_count);
            `endif
        end
    end // cen
end

// ============================================================================
// RAM (368 bytes at 0x90-0x1FF for M68HC05E1)
// ============================================================================
// RAM read is combinational, write is synchronous
always @(*) begin
    if (ram_cs) begin
        ram_dout = intram[ram_addr];
    end else begin
        ram_dout = 8'h00;
    end
end

`ifdef VERBOSE_TRACE
// Debug RAM access around stack area - only log first 100 and critical writes
reg [31:0] stack_write_count;
always @(posedge clk) begin
    if (reset) begin
        stack_write_count <= 0;
    end else if (cen && ram_cs && (cpu_addr >= 16'h00F0) && (cpu_addr <= 16'h00FF)) begin
        if (!cpu_wr) begin  // Write
            if (stack_write_count < 100 || cpu_dout == 8'hFF)
                $display("HC05 RAM[%0d]: WRITE stack 0x%04x = 0x%02x (ram_addr=%d)", cycle_count, cpu_addr, cpu_dout, ram_addr);
            stack_write_count <= stack_write_count + 1;
        end
    end
end
`endif

// PRAM loading and normal RAM writes - single always block to avoid multiple drivers
// PRAM loading: copy to internal RAM when 680x0 reset asserts (PC bit 3: 1->0)
// Per MAME egret.cpp: write_internal_ram(0x70 + byte, data)
// intram[x] corresponds to CPU address 0x90 + x (RAM mapped at 0x90-0x1FF)
// So PRAM goes to intram[0x70-0x16F] = CPU addresses 0x100-0x1FF
//
// ★ SEQUENTIAL boot-copy (ported 2026-08-08 from MacIIvi 9f5d0d3, MLAB
// conversion): the old for-loop wrote all 256 bytes in ONE clk — 256 parallel
// write ports, which forced intram[] (and pram[], read 256-wide) to
// synthesize as registers + giant muxes (~1.5-2k ALMs). Now one byte per clk
// over 260 cycles (256 PRAM + 4 RTC-seed) ≈ 8 µs at clk32. Atomicity vs the
// HC05 is preserved by construction: pram_copy_busy gates the HC05 cen (see
// u_cpu instantiation), so the firmware observes the copy as a single instant
// exactly like the old one-cycle burst — it cannot read a half-copied PRAM
// region or land a store mid-copy. The 68020 is separately held in reset
// until pram_loaded (unchanged).
reg        pram_copy_busy = 1'b0;
reg [8:0]  pram_copy_idx;             // 0-255 = PRAM bytes, 256-259 = RTC seed
wire [7:0] pram_copy_rdata = pram[pram_copy_idx[7:0]];
always @(posedge clk) begin
    if (reset) begin
        pram_loaded    <= 1'b0;
        pram_copy_busy <= 1'b0;
    end else begin
        // Boot-copy the saved PRAM into the Egret's working RAM as the LAST write
        // before the 68k runs. Gate it on the HC05 firmware having RELEASED the 68k
        // (reset_680x0_latched==0) — which is AFTER the firmware's own startup
        // PRAM-clear. Our previous trigger fired on the reset-ASSERT edge (PC3 1->0,
        // pre-clear), so on a fast SD load the firmware's clear then wiped the loaded
        // image and the ROM ran InitUtil every boot (MAME ground truth: it injects
        // PRAM at the post-clear reset-release; see docs/mame_pram_findings.md). Also
        // require pram_ready (the SD image is in pram[], or no image/timeout). The
        // 68020 is held in reset until pram_loaded (see reset_680x0 above), so it
        // never reads pre-copy PRAM.
        if (!pram_loaded && !pram_copy_busy && !reset_680x0_latched && pram_ready) begin
            pram_copy_busy <= 1'b1;
            pram_copy_idx  <= 9'd0;
            `ifdef SIMULATION
            $display("EGRET_PRAM: Loading PRAM and RTC time (post-clear release, sequential)");
            `endif
        end else if (pram_copy_busy) begin
            // Copy PRAM to internal RAM: PRAM[0-255] -> CPU 0x100-0x1FF
            // (offset 0x70 = 0x100 - 0x90), then seed RTC seconds
            // (CPU 0xAB-0xAE -> intram[0x1B-0x1E]) from the host timestamp.
            case (pram_copy_idx)
                9'd256:  intram[16'hAB - 16'h90] <= timestamp[31:24];
                9'd257:  intram[16'hAC - 16'h90] <= timestamp[23:16];
                9'd258:  intram[16'hAD - 16'h90] <= timestamp[15:8];
                9'd259:  intram[16'hAE - 16'h90] <= timestamp[7:0];
                default: intram[pram_copy_idx + 9'h070] <= pram_copy_rdata;
            endcase
            if (pram_copy_idx == 9'd259) begin
                pram_copy_busy <= 1'b0;
                pram_loaded    <= 1'b1;
            end else
                pram_copy_idx <= pram_copy_idx + 9'd1;
        end else if (ram_cs && !cpu_wr && cen) begin  // !cpu_wr means write
            intram[ram_addr] <= cpu_dout;
        `ifdef VERBOSE_TRACE
        if (ram_addr == 9'h04) begin
            $display("EGRET_RAM_WRITE[%0d]: PC=%04x addr=$94 data=%02x",
                     cycle_count, last_pc, cpu_dout);
        end
        if (ram_addr == 9'h3C) begin
            $display("EGRET_RAM_WRITE[%0d]: PC=%04x addr=$CC data=%02x",
                     cycle_count, last_pc, cpu_dout);
        end
        if (ram_addr == 9'h13) begin
            $display("EGRET_A3_WRITE[%0d]: PC=%04x addr=$A3 data=%02x (bit7=%b)",
                     cycle_count, last_pc, cpu_dout, cpu_dout[7]);
        end
        `endif
        end   // close: else if (ram_cs ... write)
    end       // close: else (not in reset)
end

// ============================================================================
// PRAM persistence: keep pram[] (the canonical NVRAM image) in sync
// ============================================================================
// pram[] is seeded from egret.pram ($readmemh) and copied into intram by the
// boot-copy block above. AFTER that copy (pram_loaded), we mirror every firmware
// write to the PRAM region (intram 0x70..0x16F = CPU 0x100..0x1FF) into pram[],
// so the top level can snapshot it; the top level can also overwrite pram[] from
// a save file via pram_load_*. ONE always block (load wins over mirror) keeps
// Quartus to a single driver on pram[]. Gating the mirror on pram_loaded means
// the boot-copy still sees exactly the loaded image (boot behavior unchanged).
wire        pram_region_wr = ram_cs && !cpu_wr && cen && pram_loaded
                             && (ram_addr >= 9'h070) && (ram_addr < 9'h170);
wire  [7:0] pram_wr_idx    = ram_addr - 9'h070;   // 0..255 within the region
always @(posedge clk) begin
    if (pram_load_wr)
        pram[pram_load_addr] <= pram_load_data;
    else if (pram_region_wr)
        pram[pram_wr_idx]    <= cpu_dout;
end
assign pram_save_data = pram[pram_save_addr];
assign pram_wr_stb    = pram_region_wr;

`ifdef VERBOSE_TRACE
// Debug stack reads around RTS execution
always @(posedge clk) begin
    if (cen && ram_cs && cpu_wr) begin  // cpu_wr=1 means read
        // Log stack reads (addresses 0xF0-0xFF) during the RTS time window
        if (cpu_addr >= 16'h00F0 && cpu_addr <= 16'h00FF) begin
            if (cycle_count >= 279460 && cycle_count <= 279500) begin
                $display("EGRET_STACK_READ[%0d]: addr=0x%04x ram_addr=%d ram_dout=0x%02x intram=0x%02x cpu_din=0x%02x",
                         cycle_count, cpu_addr, ram_addr, ram_dout, intram[ram_addr], cpu_din);
            end
        end
    end
end
`endif

// ============================================================================
// ROM (4KB at 0x0F00-0x1FFF for M68HC05E1)
// ============================================================================
// CRITICAL: Make ROM read combinational (not registered) so data is available same cycle
always @(*) begin
    if (rom_cs) begin
        rom_dout = rom[rom_addr];
    end else begin
        rom_dout = 8'hFF;
    end
end

`ifdef SIMULATION
// Debug ROM reads (commented out - enable if needed for debugging)
/*
always @(posedge clk) begin
    if (rom_cs && cycle_count < 20) begin
        $display("EGRET_ROM_READ[%0d]: addr=%04x rom_addr=%03x data=%02x rom_cs=%b", 
                 cycle_count, cpu_addr, rom_addr, rom[rom_addr], rom_cs);
    end
end
*/
`endif

// ============================================================================
// CPU data input mux
// ============================================================================
reg [7:0] cpu_din_r;
always @(*) begin
    if (port_cs) begin
        case (cpu_addr[4:0])  // 5 bits for 0x00-0x1F
            5'h00: begin
                cpu_din_r = pa_in;
                `ifdef VERBOSE_TRACE
                if (cycle_count < 10000)
                    $display("EGRET[%0d]: PORT A READ = 0x%02x (pa_out=%02x pa_in=%02x pa_ddr=%02x)",
                             cycle_count, cpu_din_r, pa_out, pa_in, pa_ddr);
                `endif
            end
            5'h01: cpu_din_r = pb_in;
            5'h02: cpu_din_r = pc_out;  // Full 8-bit read for port test
            5'h04: cpu_din_r = pa_ddr;
            5'h05: cpu_din_r = pb_ddr;
            5'h06: cpu_din_r = pc_ddr;
            5'h07: begin
                cpu_din_r = pll_ctrl;       // PLL control
                `ifdef VERBOSE_TRACE
                // Log early PLL reads (during init) and later reads (during handshake)
                if (cycle_count <= 10000 || (cycle_count >= 276000 && cycle_count <= 280000))
                    $display("EGRET_PLL_READ[%0d]: PC~%04x pll_ctrl=0x%02x bit6=%b",
                             cycle_count, last_pc, cpu_din_r, cpu_din_r[6]);
                `endif
            end
            5'h08: cpu_din_r = timer_ctrl;     // Timer control
            5'h09: cpu_din_r = timer_counter;  // Timer counter (8-bit, free-running)
            5'h12: cpu_din_r = onesec_ctrl;    // One-second timer control
            default: cpu_din_r = 8'h00;  // Unmapped ports return 0 (makes bit tests fail safely)
        endcase
    end else if (ram_cs) begin
        cpu_din_r = ram_dout;
    end else if (rom_cs) begin
        cpu_din_r = rom_dout;
    end else begin
        // Unmapped space returns NOP (0x9D) instead of 0xFF to prevent runaway execution
        cpu_din_r = 8'h9D;
    end
end

assign cpu_din = cpu_din_r;

// ============================================================================
// IRQ generation - M68HC05E1 has three interrupt sources
// ============================================================================
// Each source has its own vector in the CPU core:
// - onesec_irq_n -> $FFF6 (one-second timer ISR)
// - timer_irq_n  -> $FFF8 (timer/counter ISR)
// - combined_irq_n -> $FFFA (external IRQ ISR)
wire combined_irq_n = 1'b1;  // No external IRQ source currently

// Track TIP for edge detection in debug/display only
reg via_tip_prev;
reg via_byteack_prev;

always @(posedge clk) begin
    if (reset) begin
        via_tip_prev <= 1'b1;  // TIP is idle high
        via_byteack_prev <= 1'b0;
    end else if (cen) begin
        via_tip_prev <= via_tip_stable;
        via_byteack_prev <= via_byteack_in_stable;
    end
end

// ============================================================================
// CPU instantiation - m68hc05_core
// ============================================================================
m68hc05_core u_cpu (
    .clk(clk),
    // cen gated by pram_copy_busy: the HC05 is frozen for the ~8 µs sequential
    // PRAM boot-copy so the copy stays atomic from firmware's point of view —
    // identical observable behavior to the old single-cycle burst copy. The
    // one-second timer keeps counting (8 µs once per boot is noise).
    .cen(cen && !pram_copy_busy),  // 4 MHz clock enable (32 MHz / 8)
    .rst(~reset),      // m68hc05_core uses active-low reset
    .irq(combined_irq_n),     // External IRQ (active-low) -> $FFFA
    .timer_irq(timer_irq_n),  // Timer interrupt (active-low) -> $FFF8
    .onesec_irq(onesec_irq_n),// One-second timer (active-low) -> $FFF6
    .addr(cpu_addr),
    .wr(cpu_wr),
    .datain(cpu_din),
    .state(cpu_state),
    .dataout(cpu_dout)
);

// ============================================================================
// Stub for cuda_sr_irq (not implemented yet)
// ============================================================================
always @(posedge clk) begin
    if (reset)
        cuda_sr_irq <= 1'b0;
    // TODO: Implement SR interrupt logic if needed
end

// ============================================================================
// Debug (simulation only)
// ============================================================================
`ifdef SIMULATION
reg [7:0] pb_out_prev, pb_latch_prev, pb_ddr_prev;
reg [7:0] pa_out_prev;
// via_tip_prev is declared and managed earlier
reg [31:0] cycle_count;
reg [15:0] last_pc;
reg       treq_prev;
reg       reset_680x0_prev;

always @(posedge clk) begin
    if (reset) begin
        cycle_count <= 0;
        pb_out_prev <= 8'hFF;
        pb_latch_prev <= 0;
        pb_ddr_prev <= 0;
        pa_out_prev <= 0;
        last_pc <= 0;
        treq_prev <= 1;  // pb_out[1]=1 means TREQ deasserted initially
        reset_680x0_prev <= 1;
    end else if (cen) begin
        cycle_count <= cycle_count + 1;
        pb_out_prev <= pb_out;
        pa_out_prev <= pa_out;
        treq_prev <= pb_out[1];  // Track pb_out[1] directly
        reset_680x0_prev <= reset_680x0;

        // Log 68020 reset release
        if (reset_680x0 != reset_680x0_prev) begin
            if (reset_680x0)
                $display("EGRET[%0d]: *** 68020 RESET ASSERTED ***", cycle_count);
            else
                $display("EGRET[%0d]: *** 68020 RESET RELEASED (pc_out[3]=%b, pc_ddr[3]=%b) ***",
                         cycle_count, pc_out[3], pc_ddr[3]);
        end

        `ifdef VERBOSE_TRACE
        // Log Port B and C latch/DDR writes
        if (port_cs && !cpu_wr) begin
            case (cpu_addr[4:0])
                5'h00: $display("EGRET[%0d] PC=%04x: Port A LATCH write = 0x%02x (was 0x%02x)",
                              cycle_count, cpu_addr, cpu_dout, pa_latch);
                5'h01: $display("EGRET[%0d] PC=%04x: Port B LATCH write = 0x%02x (was 0x%02x)",
                              cycle_count, cpu_addr, cpu_dout, pb_latch);
                5'h02: $display("EGRET[%0d] PC=%04x: Port C LATCH write = 0x%02x (bit3=%b -> reset_680x0 will be %b)",
                              cycle_count, cpu_addr, cpu_dout, cpu_dout[3], cpu_dout[3]);
                5'h04: $display("EGRET[%0d] PC=%04x: Port A DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                5'h05: $display("EGRET[%0d] PC=%04x: Port B DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                5'h06: $display("EGRET[%0d] PC=%04x: Port C DDR write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                5'h12: $display("EGRET[%0d] PC=%04x: One-second timer write = 0x%02x",
                              cycle_count, cpu_addr, cpu_dout);
                default: $display("EGRET[%0d] PC=%04x: Port write addr=%02x data=%02x",
                              cycle_count, cpu_addr, cpu_addr[4:0], cpu_dout);
            endcase
        end

        // Log Port B accesses (for communication tracking)
        if (port_cs && cpu_addr[4:0] == 5'h01) begin
            $display("EGRET[%0d]: PB %s data=0x%02x (PC=0x%04x) TIP=%b BYTEACK=%b",
                     cycle_count, cpu_wr ? "READ" : "WRITE", cpu_wr ? cpu_din : cpu_dout,
                     last_pc, ~via_tip_stable, ~via_byteack_in_stable);
        end

        // Log Port B output changes
        if (pb_out != pb_out_prev) begin
            $display("EGRET[%0d]: PB OUT 0x%02x->0x%02x (CB1=%b CB2=%b TREQ=%b) TIP_in=%b",
                     cycle_count, pb_out_prev, pb_out,
                     pb_out[4], pb_out[5], pb_out[1], via_tip_stable);
        end
        `endif

        // Log TREQ transitions (pb_out[1]=0 means TREQ active)
`ifdef SIMULATION
        if (pb_out[1] != treq_prev) begin
            if (~pb_out[1])
                $display("EGRET[%0d]: TREQ ACTIVE", cycle_count);
            else
                $display("EGRET[%0d]: TREQ INACTIVE", cycle_count);
        end
`endif

        // Log TIP input changes from VIA
`ifdef SIMULATION
        if (via_tip_stable != via_tip_prev) begin
            $display("EGRET[%0d]: TIP %b->%b (effective=%b)", cycle_count, via_tip_prev, via_tip_stable, via_tip_effective);
        end
`endif

`ifdef SIMULATION
        // Log CB1 clock edges
        if (pb_out[4] != pb_out_prev[4]) begin
            $display("EGRET[%0d]: CB1 %s", cycle_count, pb_out[4] ? "RISE" : "FALL");
        end
`endif

`ifdef SIMULATION
        // Log BYTEACK input changes
        if (via_byteack_in_stable != via_byteack_prev) begin
            $display("EGRET[%0d]: BYTEACK %b->%b", cycle_count, via_byteack_prev, via_byteack_in_stable);
        end
        // Periodic PC dump when TIP is active (every 256 cycles)
        if (!via_tip_effective && cycle_count[7:0] == 8'h00) begin
            $display("EGRET[%0d]: PC=%04x TIP_active PB_in=%02x PB_out=%02x PB_ddr=%02x",
                     cycle_count, last_pc, pb_in, pb_out, pb_ddr);
        end
`endif

        // Track program counter
        if (rom_cs && cpu_wr) begin  // cpu_wr=1 means read
            last_pc <= cpu_addr;
`ifdef EGRET_SRDEBUG
            // Focused stuck-loop finder for the byte-4 BYTEACK/TREQ turnaround.
            // Samples the HC05 PC + handshake inputs every ~32k fetches, so a hung
            // loop prints its PC repeatedly (a few dozen lines/run, no flood).
            // Enable with +define+EGRET_SRDEBUG; grep "EGRET_SRDBG" in the output.
            if (cycle_count[14:0] == 15'd0)
                $display("EGRET_SRDBG[%0d]: PC=0x%04x BYTEACK=%b TIP=%b TREQ_out=%b CB1out=%b",
                         cycle_count, addr13, via_byteack_in_stable, via_tip_stable, pb_out[1], pb_out[4]);
`endif
`ifdef SIMULATION
            // Track key init milestones
            if (addr13 == 13'h0FAF)
                $display("EGRET[%0d]: >>> INIT RESTART ($0FAF)", cycle_count);
            if (addr13 == 13'h12C2)
                $display("EGRET[%0d]: >>> COMM HANDLER ($12C2) TIP=%b BYTEACK=%b", cycle_count, via_tip_effective, via_byteack_in_stable);
            if (addr13 == 13'h132B)
                $display("EGRET[%0d]: >>> SESSION HANDLER ($132B) TIP=%b", cycle_count, via_tip_effective);
            if (addr13 == 13'h14C8)
                $display("EGRET[%0d]: >>> CB1 HANDLER ($14C8) TIP=%b BYTEACK=%b", cycle_count, via_tip_effective, via_byteack_in_stable);
            if (addr13 == 13'h14EC)
                $display("EGRET[%0d]: >>> CB1 STROBING ($14EC)", cycle_count);
            if (addr13 == 13'h1034)
                $display("EGRET[%0d]: >>> PROBE LOOP ($1034)", cycle_count);
            if (addr13 == 13'h1068)
                $display("EGRET[%0d]: >>> PROBE DONE ($1068) — post-probe init", cycle_count);
            if (addr13 == 13'h1445)
                $display("EGRET[%0d]: >>> SESSION XFER ($1445) TIP=%b", cycle_count, via_tip_effective);
            if (addr13 == 13'h1549)
                $display("EGRET[%0d]: >>> WAIT_BYTEACK ($1549) TIP=%b", cycle_count, via_tip_effective);
`endif
            `ifdef VERBOSE_TRACE
            // Key firmware addresses (match MAME trace points)
            if (addr13 == 13'h120A ||  // Init check loop entry
                addr13 == 13'h1210 ||  // BCLR 6, $A3
                addr13 == 13'h1212 ||  // BRSET 6, $07 (PLL check)
                addr13 == 13'h1219 ||  // JSR $1E01
                addr13 == 13'h121C ||  // BCLR 4, $07
                addr13 == 13'h121E ||  // JSR $1E01 (2nd)
                addr13 == 13'h1221 ||  // BRCLR 0, $01
                addr13 == 13'h1224 ||  // BSET 6, $07 (set PLL bit)
                addr13 == 13'h1226 ||  // After PLL check branch
                addr13 == 13'h1228 ||  // "Ready" branch target
                addr13 == 13'h1236 ||  // BSET 7, $A3 (set init flag)
                addr13 == 13'h123B ||  // Error exit
                addr13 == 13'h1246 ||  // Continue init
                addr13 == 13'h1251 ||  // Main loop JSR $120A
                addr13 == 13'h1E01 ||  // PLL wait subroutine
                addr13 == 13'h12A3 ||  // CLI (enable interrupts)
                addr13 == 13'h12AD ||  // TIP polling loop (BRSET 3, $01)
                addr13 == 13'h14C8 ||  // Main message handler (JSR $1149)
                addr13 == 13'h14CD ||  // Main loop TIP check
                addr13 == 13'h1549 ||  // TREQ assertion (BCLR 1, $01)
                addr13 == 13'h1640 ||  // TREQ setup
                (addr13 >= 13'h14EF && addr13 <= 13'h152B))  // CB1 clocking
                $display("EGRET[%0d]: KEY PC=0x%04x TIP=%b TREQ=%b",
                         cycle_count, addr13, ~via_tip_stable, ~pb_out[1]);
            `endif
        end

        `ifdef VERBOSE_TRACE
        // MAME-format Port B read logging
        if (port_cs && cpu_wr && cpu_addr[4:0] == 5'h01) begin
            if (!via_tip_stable || (cycle_count[7:0] == 8'h00 && last_pc >= 16'h12A0 && last_pc <= 16'h12B5)) begin
                $display("EGRET pb_r: %02x TIP=%b BYTEACK=%b (PC=%04x) [ext=%02x]",
                         pb_in, ~via_tip_stable, ~via_byteack_in_stable, last_pc, pb_external);
            end
        end

        // MAME-format Port B write logging
        if (port_cs && !cpu_wr && cpu_addr[4:0] == 5'h01) begin
            $display("EGRET pb_w: %02x CB1=%b CB2=%b TREQ=%b (PC=%04x)",
                     cpu_dout, cpu_dout[4], cpu_dout[5], ~cpu_dout[1], last_pc);
        end

        // Log first 100 CPU cycles
        if (cycle_count < 100) begin
            $display("EGRET_CPU[%0d]: pc=%04x din=%02x dout=%02x",
                     cycle_count, cpu_addr, cpu_din, cpu_dout);
        end
        `endif
    end
end

// Periodic status - only log every ~1M cycles to reduce output
reg [19:0] status_timer;
always @(posedge clk) begin
    if (reset) begin
        status_timer <= 0;
    end else if (cen) begin
        status_timer <= status_timer + 1;
        `ifdef VERBOSE_TRACE
        if (status_timer == 0) begin
            // MAME-style status: show key signals
            $display("EGRET[%0d] STATUS: PC=%04x TIP=%b TREQ=%b CB1=%b",
                     cycle_count, last_pc, ~via_tip_stable, ~pb_out[1], pb_out[4]);
        end
        `endif
    end
end
`endif

endmodule

`default_nettype wire