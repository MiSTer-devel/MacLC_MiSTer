// Mac LC Pseudo-VIA
// Based on MAME's pseudovia.cpp by R. Belmont
//
// Mapped at $F26000-$F27FFF in CPU space (V8 internal 0x526000)
// Two access modes:
//   - Native mode (offset < 0x100): Direct register access
//   - VIA-compat mode (offset >= 0x100): Aliases native Group 0 registers
//
// Native mode decodes only addr[4] (group) and addr[1:0] (register):
//   Group 0 (addr[4]=0): Port B, RAM Config, Slot Status, IFR
//   Group 1 (addr[4]=1): Video Config, (unused), Slot IER, IER
//
// VIA-compat mode (offset >= 0x100) uses addr[12:9] as 6522 register number.
// Only registers 13 (IFR) and 14 (IER) are meaningful (per MAME).
// VIA-compat IER is a separate register from native $13, used for IRQ masking.

module pseudovia(
    input clk_sys,
    input reset,
    // RESET-instruction soft reset (2026-08-08 warm-restart fix): on a real
    // LC the 68020 RESET instruction drives the external reset line, which
    // resets the V8's interrupt state. Our soft restart path (Special ▸
    // Restart / shutdown-screen Restart both execute RESET + jump, NO Egret
    // reset — HUD row-12 witnessed) left the OS's slot_ier/ier live, and
    // any_slot_irq re-asserts from vblank EVERY FRAME — so the warm boot,
    // on first lowering IPL, lived forever in the slot-interrupt handler
    // probing $F1xxxx (the phantom-PDS space) for a source it could never
    // silence: the user-visible "black screen after restart" (video still
    // blanked at cfg $40). Clears INTERRUPT state only — ram_cfg/
    // ram_configured/video_config survive, exactly as on a real LC (the
    // ROM's own T+4s cold-boot RESET would otherwise unmap RAM under the
    // running boot).
    input soft_rst,

    // CPU interface - full offset within $F26000-$F27FFF range
    input [12:0] addr,  // Offset 0x0000-0x1FFF
    input [7:0] data_in,
    output reg [7:0] data_out,
    input we,
    input req,

    // Interrupts
    input vblank_irq,    // Active high VBlank signal
    input slot_irq,      // Slot interrupt
    input asc_irq,       // ASC interrupt
    input scsi_irq,      // NCR5380 latched interrupt (LEVEL) -> IFR bit 3 ("CB2")
    input scsi_drq,      // NCR5380 DREQ (LEVEL)              -> IFR bit 0 ("CA2")
    output reg irq_out,

    // Config from top level
    input [7:0] ram_config,  // V8 RAM config byte (MAME encoding)
    input [3:0] monitor_id,  // Monitor ID for video config

    // Video config output (set by ROM, bits 2:0 = bpp mode)
    output reg [7:0] video_config,

    // RAM config output (active value, writable by ROM)
    output [7:0] ram_config_out,

    // Candidate B: set on the ROM's first write to the V8 RAM-config register.
    // Mirrors MAME v8.cpp: the $0 motherboard-low mirror is installed only once
    // the ROM programs the config (via2_config_w -> ram_size(data)). Before that,
    // the overlay-clear map is ram_size(0xc0) == only $800000-$9FFFFF, so the
    // boot RAM-bank probe never finds a (phantom) bank at $0.
    output reg ram_configured
);

// RAM config output: expose current value for address controller
assign ram_config_out = ram_cfg;

// Native registers (8 total, 2 groups of 4)
// Group 0: port_b, ram_cfg, slot_status, ifr
// Group 1: video_cfg, (unused), slot_ier, ier
reg [7:0] port_b;
reg [7:0] ram_cfg;      // Writable RAM config register
reg [7:0] ifr;          // Interrupt flag register
reg [7:0] slot_ier;     // Slot interrupt enable register
reg [7:0] ier;          // IER (shared between native $13 and compat reg 14, per MAME RBV)

// Slot interrupt status - active LOW (matches MAME m_pseudovia_regs[2]).
// Bit 6: VBlank (active low = VBlank is happening)
// Bit 5: Slot IRQ
// Bits 4,3: other slot sources (unused here, held inactive = 1)
// NOTE: ASC is NOT a slot source. In MAME the ASC interrupt is IFR bit 4
// (set by asc_irq_w), gated by the main IER ($13) — NOT by the slot IER ($12).
// Folding asc into slot_status[4] here made it fire a spurious level-2 IRQ
// (gated only by slot_ier=$7f) that preempted the level-1 VIA1 timer the
// boot POST's interrupt-timing self-test relies on.
wire [7:0] slot_status = {1'b0, ~vblank_irq, ~slot_irq, 1'b1, 3'b111, 1'b1};

// Slot/VBL summary, gated by the slot IER ($12) -> IFR bit 1 (any slot).
wire [7:0] slot_irqs = (~slot_status) & 8'h78;  // Check bits 3-6 (slots + vblank)
wire [7:0] slot_irqs_masked = slot_irqs & (slot_ier & 8'h78);
wire any_slot_irq = |slot_irqs_masked;

// Live IFR source bits, mirroring MAME pseudovia_recalc_irqs():
//   bit4 = ASC, bit3 = SCSI IRQ, bit1 = any-slot summary, bit0 = SCSI DRQ;
//   others keep stored value. (bit3 previously carried slot_irq — that
//   contradicted MAME pseudovia.cpp, where scsi_irq_w owns bit 3 and slot
//   sources live in slot_status + the bit-1 summary; the slot input is tied
//   0 in both tops, so nothing depended on the old mapping.)
wire [7:0] ifr_live = { ifr[7], ifr[6], ifr[5], asc_irq, scsi_irq, ifr[2], any_slot_irq, scsi_drq };

// MAME: IRQ asserts when (IFR & IER[$13] & 0x1B) != 0. The main IER ($13)
// gates the final interrupt; the slot IER ($12) only gates the slot summary.
wire irq_pending = |(ifr_live & ier & 8'h1B);

// Debug counter
integer pvia_reg10_reads = 0;

// Register decode: use full byte offset for native mode (matching MAME)
// Valid native registers: 0x00-0x03 (Group 0), 0x10-0x13 (Group 1), 0x20-0x2F (MSC)
// Only addr[4] and addr[1:0] select the register, but other bits must be zero
wire [7:0] native_offset = addr[7:0];
wire [2:0] reg_sel = {addr[4], addr[1:0]};
wire native_reg_valid = (native_offset[7:5] == 3'b000) && (native_offset[3:2] == 2'b00);

// VIA-compat mode uses addr[12:9] as 6522 register number (512-byte spacing)
wire is_native = (addr[12:8] == 5'b00000);
wire [3:0] compat_reg = addr[12:9];

always @(posedge clk_sys) begin
    if (reset) begin
        port_b <= 8'h00;
        ram_cfg <= ram_config;  // Init from hardware config (MAME: ram_size(0xC0))
        ram_configured <= 1'b0; // $0 mirror disabled until ROM programs config
        ifr <= 8'h00;
        slot_ier <= 8'h00;
        ier <= 8'h00;
        irq_out <= 1'b0;
        video_config <= 8'h03;  // Default to 8bpp mode
    end else if (soft_rst) begin
        // RESET instruction: interrupt state only (see the port comment).
        ifr      <= 8'h00;
        slot_ier <= 8'h00;
        ier      <= 8'h00;
        irq_out  <= 1'b0;
    end else begin
        // Update slot IRQ summary in IFR (bit 1 = any slot)
        if (any_slot_irq)
            ifr[1] <= 1'b1;
        else
            ifr[1] <= 1'b0;

        // Per-source IFR bits — match MAME pseudovia.cpp asc_irq_w /
        // scsi_irq_w / scsi_drq_w pattern (set when source asserts, clear
        // when source deasserts). MAME's recalc reads
        // `regs[3] & regs[0x13] & 0x1B` — mask 0x1B includes bit 4 (ASC),
        // bit 3 (SCSI IRQ), bit 1 (any slot), bit 0 (SCSI DRQ). So these
        // per-source bits matter for the boot ROM's IRQ-source decode.
        // Previously only bit 1 (summary) was set; the ROM could see "an
        // IRQ fired" but couldn't tell WHICH source, and any handler that
        // dispatched off IFR[4] / IFR[3] saw 0 and fell through to a wrong
        // path.
        if (asc_irq)
            ifr[4] <= 1'b1;
        else
            ifr[4] <= 1'b0;

        // SCSI flags are LEVEL-driven — NEVER edge-latch these here. The
        // LBMacTwo round-3 HW test proved an edge model deadlocks: the
        // latched IRQ from the previous chunk holds the line, so no new
        // edge fires at the next pseudo-DMA chunk boundary and the HD SC
        // 4.3 driver's IFR poll sleeps forever (lbmactwo 1ee80e8). The
        // 5380's own irq_latch (cleared by a reg-7 read) provides the
        // handshake; these flags just FOLLOW it. A W1C IFR write below may
        // clear a bit for one cycle; the level re-asserts on the next —
        // self-correcting, Snow semantics.
        if (scsi_irq)
            ifr[3] <= 1'b1;
        else
            ifr[3] <= 1'b0;

        if (scsi_drq)
            ifr[0] <= 1'b1;
        else
            ifr[0] <= 1'b0;

        // Update IRQ output
        if (irq_pending) begin
            ifr[7] <= 1'b1;
            irq_out <= 1'b1;
        end else begin
            ifr[7] <= 1'b0;
            irq_out <= 1'b0;
        end

        if (req) begin
            if (is_native && native_reg_valid) begin
                // Native mode: decode {addr[4], addr[1:0]}
                if (we) begin
                    case (reg_sel)
                        3'b000: begin  // $00: Port B
                            port_b <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Port B = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b001: begin  // $01: RAM Config (writable per MAME)
                            ram_cfg <= data_in;
                            ram_configured <= 1'b1;  // enables $0 motherboard mirror
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE RAM Config = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b010: begin  // $02: Slot Status
                            // Write 1 to bit 6 to clear VBlank flag
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot Status = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b011: begin  // $03: IFR - write-1-to-clear (per MAME pseudovia.cpp:269)
                            // MAME does unconditional `regs[3] &= ~(data & 0x7F)` — i.e.
                            // writing 1 to a bit ACKs/clears that bit, writing 0 leaves it.
                            // Our previous code conditioned on data_in[7]: writing $82 was
                            // SETTING bit 1 instead of clearing it, so any ROM ack with the
                            // 6522-style "1 bits clear" convention would re-arm the IRQ on
                            // every write and the CPU would loop in the ISR.
                            ifr <= ifr & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IFR ACK %02x (clearing bits) @%0t", data_in & 8'h7F, $time);
                            `endif
                        end

                        3'b100: begin  // $10: Video Config
                            video_config <= data_in;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Video Config = %02x (bpp mode = %d) addr=%h @%0t",
                                     data_in, data_in[2:0], addr, $time);
                            `endif
                        end

                        3'b101: ;  // $11: unused

                        3'b110: begin  // $12: Slot IER
                            if (data_in[7])
                                slot_ier <= slot_ier | (data_in & 8'h7F);
                            else
                                slot_ier <= slot_ier & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE Slot IER = %02x @%0t", data_in, $time);
                            `endif
                        end

                        3'b111: begin  // $13: IER
                            if (data_in[7]) begin
                                ier <= ier | (data_in & 8'h7F);
                                if (data_in == 8'hFF)
                                    ier <= 8'h1F;
                            end else begin
                                ier <= ier & ~(data_in & 8'h7F);
                            end
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: WRITE IER = %02x @%0t", data_in, $time);
                            `endif
                        end
                    endcase
                end else begin
                    // Read native mode
                    case (reg_sel)
                        3'b000: begin  // $00: Port B
                            data_out <= port_b;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Port B -> %02x @%0t", port_b, $time);
                            `endif
                        end

                        3'b001: begin  // $01: RAM Config (OR bit 2 on read)
                            data_out <= ram_cfg | 8'h04;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ RAM Config -> %02x @%0t", ram_cfg | 8'h04, $time);
                            `endif
                        end

                        3'b010: begin  // $02: Slot Status
                            data_out <= slot_status;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Slot Status -> %02x @%0t", slot_status, $time);
                            `endif
                        end

                        3'b011: begin  // $03: IFR
                            data_out <= ifr;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ IFR -> %02x @%0t", ifr, $time);
                            `endif
                        end

                        3'b100: begin  // $10: Video Config
                            // MAME v8.cpp via2_video_config_r returns ONLY the
                            // monitor sense (montype << 3) — the stored config
                            // byte is write-only. Leaking the written depth bits
                            // into the readback can make the ROM/Monitors
                            // misclassify the display (grayscale-only / wrong
                            // depth list).
                            data_out <= {1'b0, monitor_id[3:0], 3'b000};  // montype << 3
                            pvia_reg10_reads <= pvia_reg10_reads + 1;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Video Config -> %02x @%0t",
                                     {1'b0, monitor_id[3:0], 3'b000}, $time);
                            `endif
                        end

                        3'b101: begin  // $11: unused
                            data_out <= 8'h00;
                        end

                        3'b110: begin  // $12: Slot IER
                            data_out <= slot_ier & 8'h7F;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ Slot IER -> %02x @%0t", slot_ier & 8'h7F, $time);
                            `endif
                        end

                        3'b111: begin  // $13: IER
                            data_out <= ier & 8'h7F;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA: READ IER -> %02x @%0t", ier & 8'h7F, $time);
                            `endif
                        end
                    endcase
                end
            end else if (!is_native) begin
                // VIA-compat mode: offset >= 0x100
                // Emulates 6522 register layout with 512-byte spacing
                // addr[12:9] gives the VIA register number (0-15)
                // Per MAME: only registers 13 (IFR) and 14 (IER) are meaningful
                if (we) begin
                    case (compat_reg)
                        4'd13: begin  // IFR - write-1-to-clear (per MAME pseudovia.cpp:269)
                            // Compat IFR write must mirror native IFR write semantics: the
                            // 6522-aliased path is the SAME register inside MAME, so the ACK
                            // behavior is identical. Previous code dropped the write entirely
                            // (just $display) which meant the ROM's compat-mode IRQ ack was
                            // a no-op and the IFR bit stayed set.
                            ifr <= ifr & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE IFR ACK %02x @%0t", data_in & 8'h7F, $time);
                            `endif
                        end
                        4'd14: begin  // IER (standard VIA set/clear behavior)
                            if (data_in[7])
                                ier <= ier | (data_in & 8'h7F);
                            else
                                ier <= ier & ~(data_in & 8'h7F);
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE IER = %02x @%0t", data_in, $time);
                            `endif
                        end
                        default: begin
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: WRITE unknown reg %0d = %02x @%0t", compat_reg, data_in, $time);
                            `endif
                        end
                    endcase
                end else begin
                    case (compat_reg)
                        4'd13: begin  // IFR
                            data_out <= ifr;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ IFR -> %02x @%0t", ifr, $time);
                            `endif
                        end
                        4'd14: begin  // IER
                            data_out <= ier;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ IER -> %02x @%0t", ier, $time);
                            `endif
                        end
                        default: begin
                            data_out <= 8'h00;
                            `ifdef VERBOSE_TRACE
                            $display("PVIA COMPAT: READ unknown reg %0d @%0t", compat_reg, $time);
                            `endif
                        end
                    endcase
                end
            end
        end
    end
end

endmodule
