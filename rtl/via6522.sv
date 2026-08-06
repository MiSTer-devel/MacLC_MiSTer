///////////////////////////////////////////////////////////////////////////////
// Title      : VIA 6522
///////////////////////////////////////////////////////////////////////////////
// Author     : Gideon Zweijtzer  <gideon.zweijtzer@gmail.com>
///////////////////////////////////////////////////////////////////////////////
// Description: This module implements the 6522 VIA chip.
//              A LOT OF REVERSE ENGINEERING has been done to make this module
//              as accurate as it is now.
//              Thanks to gyurco for ironing out some
//              differences that were left unnoticed.
///////////////////////////////////////////////////////////////////////////////
// License:     GPL 3.0 - Free to use, distribute and change to your own needs.
//              Leaving a reference to the author will be highly appreciated.
///////////////////////////////////////////////////////////////////////////////

module via6522 (
    input  wire        clock,
    input  wire        rising,
    input  wire        falling,
    input  wire        reset,
    
    input  wire [3:0]  addr,
    input  wire        wen,
    input  wire        ren,
 
    input  wire [7:0]  data_in,
    output reg  [7:0]  data_out,

    output reg         phi2_ref,

    // pio
    output wire [7:0]  port_a_o,
    output wire [7:0]  port_a_t,
    input  wire [7:0]  port_a_i,
    
    output wire [7:0]  port_b_o,
    output wire [7:0]  port_b_t,
    input  wire [7:0]  port_b_i,

    // handshake pins
    
    input  wire        ca1_i,

    output wire        ca2_o,
    input  wire        ca2_i,
    output wire        ca2_t,
    
    output wire        cb1_o,
    input  wire        cb1_i,
    output wire        cb1_t,
    
  
    output wire        cb2_o,
    input  wire        cb2_i,
    output wire        cb2_t,

    output wire        irq,

    // Shift register status (for CUDA interface)
    output wire        sr_out_active,  // Shift register is actively shifting
    output wire        sr_out_dir,     // Shift direction: 0=in, 1=out
    output wire        sr_ext_clk,     // Using external clock (CB1)

    // Debug outputs for FPGA SR diagnostics
    output wire [2:0]  sr_dbg_bit_cnt,     // Current bit counter (7→0)
    output wire        sr_dbg_edge_pending, // Rising edge pending (shift-in)
    output wire        sr_dbg_fall_pending, // Falling edge pending (shift-out)
    output wire [7:0]  sr_dbg_shift_reg     // Current shift register value
);
    localparam [15:0] latch_reset_pattern = 16'h5550;

    // PIO signals (replaces record type)
    reg [7:0] pio_i_pra  = 8'h00;
    reg [7:0] pio_i_ddra = 8'h00;
    reg [7:0] pio_i_prb  = 8'hFF;  // Default high (TIP bit 3 = 1 = not asserted)
    reg [7:0] pio_i_ddrb = 8'h00;
    reg [7:0] port_a_c = 8'h00;
    reg [7:0] port_b_c = 8'h00;
    
    reg [6:0] irq_mask   = 7'h00;
    reg [6:0] irq_flags  = 7'h00;
    reg [6:0] irq_events = 7'h00;
    reg       irq_out;
    reg [15:0] timer_a_latch = latch_reset_pattern;
    reg [15:0] timer_b_latch = latch_reset_pattern;
    reg [15:0] timer_a_count = latch_reset_pattern;
    reg [15:0] timer_b_count = latch_reset_pattern;
    reg        timer_a_out;
    reg        timer_b_tick;
    reg [7:0] acr = 8'h00;
    reg [7:0] pcr = 8'h00;
    reg [7:0] shift_reg = 8'h00;
    reg       serport_en;
    reg       ser_cb2_o;
    reg       hs_cb2_o;
    reg       cb1_t_int;
    reg       cb1_o_int;
    reg       cb2_t_int;
    reg       cb2_o_int;

    // Aliases for irq_events
    wire ca2_event     = irq_events[0];
    wire ca1_event     = irq_events[1];
    
    // FIXED: Removed assignments here to prevent multiple drivers
    wire serial_event;  
    wire cb2_event     = irq_events[3];
    wire cb1_event     = irq_events[4];
    wire timer_b_event;
    wire timer_a_event;

    // Aliases for irq_flags
    wire ca2_flag     = irq_flags[0];
    wire ca1_flag     = irq_flags[1];
    wire serial_flag  = irq_flags[2];
    wire cb2_flag     = irq_flags[3];
    wire cb1_flag     = irq_flags[4];
    wire timer_b_flag = irq_flags[5];
    wire timer_a_flag = irq_flags[6];

    // Aliases for ACR bits
    wire       tmr_a_output_en       = acr[7];
    wire       tmr_a_freerun         = acr[6];
    wire       tmr_b_count_mode      = acr[5];
    wire       shift_dir             = acr[4];
    wire [1:0] shift_clk_sel         = acr[3:2];
    wire [2:0] shift_mode_control    = acr[4:2];
    // External clock modes: Mode 3 (011) = Shift In Ext, Mode 7 (111) = Shift Out Ext
    wire       si_ext_control        = (shift_mode_control == 3'b011);  // Mode 3
    wire       so_ext_control        = (shift_mode_control == 3'b111);  // Mode 7
    wire       ext_clock_mode        = si_ext_control | so_ext_control;
    wire       pb_latch_en           = acr[1];
    wire       pa_latch_en           = acr[0];
    // Aliases for PCR bits
    wire       cb2_is_output         = pcr[7];
    wire       cb2_edge_select       = pcr[6];
    wire       cb2_no_irq_clr        = pcr[5];
    wire [1:0] cb2_out_mode          = pcr[6:5];
    wire       cb1_edge_select       = pcr[4];
    wire       ca2_is_output         = pcr[3];
    wire       ca2_edge_select       = pcr[2];
    wire       ca2_no_irq_clr        = pcr[1];
    wire [1:0] ca2_out_mode          = pcr[2:1];
    wire       ca1_edge_select       = pcr[0];
    reg [7:0] ira = 8'h00;

    // Port A read value. Pins configured as OUTPUTS read back the output
    // latch; input pins read the (optionally CA1-latched) pin level. This is
    // what MAME's 6522 does (6522via.cpp input_pa(): the result always ORs in
    // `m_out_a & m_ddr_a`) and what real hardware does, since an output pin's
    // level IS the driven level.
    //
    // Returning `ira` for every bit -- as this did -- corrupts every
    // read-modify-write instruction that touches Port A: the CPU reads the
    // INPUT pattern, modifies one bit, and writes the result back over the
    // output latch. On the Mac LC the Sony floppy driver toggles PA5/HDSEL
    // with BSET #5 / BCLR #5 on ORA ($F01E00, ROM A6D432/A6D43A), and PA5 is
    // the drive's SEL line: it picks the sense-register bank (regs 8-F, which
    // carry the SuperDrive/HD identity) and, at an LSTRB strobe, forms the
    // command {SEL,ca2,ca1,ca0}. A dropped PA5 turns the driver's $9
    // "MFMModeOn" strobe into $1 "StepOn", so the head walks off track instead
    // of entering MFM mode. Same hazard for PA6/vid_alt and PA0-2 (sound
    // volume), which any unrelated Port A RMW would rewrite from `ira`.
    wire [7:0] pra_read = (ira & ~pio_i_ddra) | (pio_i_pra & pio_i_ddra);
    reg [7:0] irb = 8'h00;

    reg write_t1c_l;
    reg write_t1c_h;
    reg write_t2c_h;

    reg ca1_c = 1'b0;
    reg ca2_c = 1'b0;
    reg cb1_c = 1'b0;
    reg cb2_c = 1'b0;
    reg ca1_d = 1'b0;
    reg ca2_d = 1'b0;
    reg cb1_d = 1'b0;
    reg cb2_d = 1'b0;
    
    reg ca2_handshake_o = 1'b1;
    reg ca2_pulse_o = 1'b1;
    reg cb2_handshake_o = 1'b1;
    reg cb2_pulse_o = 1'b1;
    reg shift_active;

    // Assignments
    assign irq = irq_out;
    always @(*) begin
        write_t1c_l = ((addr == 4'h4 || addr == 4'h6) && wen && falling);
        write_t1c_h = (addr == 4'h5 && wen && falling);
        write_t2c_h = (addr == 4'h9 && wen && falling);
    end

    always @(*) begin
        irq_events[1] = (ca1_c ^ ca1_d) & (ca1_d ^ ca1_edge_select);
        irq_events[0] = (ca2_c ^ ca2_d) & (ca2_d ^ ca2_edge_select);
        irq_events[4] = (cb1_c ^ cb1_d) & (cb1_d ^ cb1_edge_select);
        irq_events[3] = (cb2_c ^ cb2_d) & (cb2_d ^ cb2_edge_select);
        
        // FIXED: Added assignments here to drive irq_events from the wires
        irq_events[2] = serial_event;
        irq_events[5] = timer_b_event;
        irq_events[6] = timer_a_event;
    end

    assign ca2_t = ca2_is_output;
    always @(*) begin
        cb2_t_int = serport_en ? shift_dir : cb2_is_output;
        cb2_o_int = serport_en ? ser_cb2_o : hs_cb2_o;
    end

    assign cb1_t = cb1_t_int;
    assign cb1_o = cb1_o_int;
    assign cb2_t = cb2_t_int;
    assign cb2_o = cb2_o_int;

    assign ca2_o = (ca2_out_mode == 2'b00) ?
                   ca2_handshake_o :
                   (ca2_out_mode == 2'b01) ?
                   ca2_pulse_o :
                   (ca2_out_mode == 2'b10) ?
                   1'b0 : 1'b1;
        
    always @(*) begin
        hs_cb2_o = (cb2_out_mode == 2'b00) ?
                   cb2_handshake_o :
                   (cb2_out_mode == 2'b01) ?
                   cb2_pulse_o :
                   (cb2_out_mode == 2'b10) ?
                   1'b0 : 1'b1;
    end

    always @(*) begin
        if ((irq_flags & irq_mask) == 7'h00) begin
            irq_out = 1'b0;
        end else begin
            irq_out = 1'b1;
        end
    end

    always @(posedge clock) begin
        if (rising) begin
            phi2_ref <= 1'b1;
        end else if (falling) begin
            phi2_ref <= 1'b0;
        end
    end

    always @(posedge clock) begin
        // CA1/CA2/CB1/CB2 edge detect flipflops
        ca1_c <= ca1_i;
        ca2_c <= ca2_i;
        if (cb1_t_int == 1'b0) begin
            cb1_c <= cb1_i;
        end else begin
            cb1_c <= cb1_o_int;
        end
        if (cb2_t_int == 1'b0) begin
            cb2_c <= cb2_i;
        end else begin
            cb2_c <= cb2_o_int;
        end

        ca1_d <= ca1_c;
        ca2_d <= ca2_c;
        cb1_d <= cb1_c;
        cb2_d <= cb2_c;
        // input registers
        port_a_c <= port_a_i;
        port_b_c <= port_b_i;
        // input latch emulation
        if (pa_latch_en == 1'b0 || ca1_event == 1'b1) begin
            ira <= port_a_c;
        end
        
        if (pb_latch_en == 1'b0 || cb1_event == 1'b1) begin
            irb <= port_b_c;
        end

        // CA2 logic
        if (ca1_event == 1'b1) begin
            ca2_handshake_o <= 1'b1;
        end else if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h1 && falling == 1'b1) begin
            ca2_handshake_o <= 1'b0;
        end
        
        if (falling == 1'b1) begin
            if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h1) begin
                ca2_pulse_o <= 1'b0;
            end else begin
                ca2_pulse_o <= 1'b1;
            end
        end

        // CB2 logic
        if (cb1_event == 1'b1) begin
            cb2_handshake_o <= 1'b1;
        end else if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h0 && falling == 1'b1) begin
            cb2_handshake_o <= 1'b0;
        end
        
        if (falling == 1'b1) begin
            if ((ren == 1'b1 || wen == 1'b1) && addr == 4'h0) begin
                cb2_pulse_o <= 1'b0;
            end else begin
                cb2_pulse_o <= 1'b1;
            end
        end

        // Interrupt logic
        irq_flags <= irq_flags |
                     irq_events;
        
        // Ensure serial flag is set directly from event
        if (serial_event) begin
            irq_flags[2] <= 1'b1;
        end

`ifdef VERBOSE_TRACE
        // Debug: trace when serial_event gets captured into irq_flags
        if (irq_events[2] == 1'b1) begin
            $display("VIA: IRQ event serial! irq_events=0x%02x, irq_flags before=0x%02x, will be 0x%02x, rising=%b, falling=%b",
                     irq_events, irq_flags, irq_flags | irq_events, rising, falling);
        end
`endif

        // Writes
        if (wen == 1'b1 && falling == 1'b1) begin
// VIA write debug disabled - too verbose during boot
            case (addr)
                4'h0: begin // ORB
                    pio_i_prb <= data_in;
`ifdef SIMULATION
                    $display("VIA_ORB[%0t]: W 0x%02x TIP=%b TACK=%b TREQ_in=%b",
                             $time, data_in, data_in[5], data_in[4], port_b_i[3]);
`endif
                    if (cb2_no_irq_clr == 1'b0) begin
                        irq_flags[3] <= 1'b0;
                    end
                    irq_flags[4] <= 1'b0;
                end
                
                4'h1: begin // ORA
                    pio_i_pra <= data_in;
                    if (ca2_no_irq_clr == 1'b0) begin
                        irq_flags[0] <= 1'b0;
                    end
                    irq_flags[1] <= 1'b0;
                end
                    
                4'h2: begin // DDRB
                    pio_i_ddrb <= data_in;
`ifdef VERBOSE_TRACE
                    $display("VIA DDRB_W[%0t]: %02x (PB5_dir=%b PB4_dir=%b PB3_dir=%b)",
                             $time, data_in, data_in[5], data_in[4], data_in[3]);
`endif
                end
                
                4'h3: begin // DDRA
                    pio_i_ddra <= data_in;
                end
                    
                4'h4: begin // TA LO counter (write=latch)
                    timer_a_latch[7:0] <= data_in;
                end
                    
                4'h5: begin // TA HI counter
                    timer_a_latch[15:8] <= data_in;
                    irq_flags[6] <= 1'b0;
                end
                    
                4'h6: begin // TA LO latch
                    timer_a_latch[7:0] <= data_in;
                end
                    
                4'h7: begin // TA HI latch
                    timer_a_latch[15:8] <= data_in;
                    irq_flags[6] <= 1'b0;
                end
                    
                4'h8: begin // TB LO latch
                    timer_b_latch[7:0] <= data_in;
                end
                    
                4'h9: begin // TB HI counter
                    irq_flags[5] <= 1'b0;
                end
                    
                4'hA: begin // Serial port (SR write)
                    irq_flags[2] <= 1'b0;
`ifdef SIMULATION
                    $display("VIA_SR[%0t]: WRITE 0x%02x mode=%d dir=%b active=%b cnt=%d",
                             $time, data_in, shift_mode_control, shift_dir, shift_active, bit_cnt);
`endif
                end
                    
                4'hB: begin // ACR (Auxiliary Control Register)
                    acr <= data_in;
`ifdef VERBOSE_TRACE
                    $display("VIA: ACR WRITE = 0x%02x (shift_mode=%d, shift_dir=%b, ext_clk=%b)",
                             data_in, data_in[4:2], data_in[4], (data_in[3:2] == 2'b11));
`endif
                end
                    
                4'hC: begin // PCR (Peripheral Control Register)
                    pcr <= data_in;
                end
                                    
                4'hD: begin // IFR
                    irq_flags <= irq_flags & ~data_in[6:0];
                end
                    
                4'hE: begin // IER
                    if (data_in[7] == 1'b1) begin // set
                        irq_mask <= irq_mask | data_in[6:0];
`ifdef VERBOSE_TRACE
                        $display("VIA: IER SET = 0x%02x, mask now 0x%02x", data_in, irq_mask | data_in[6:0]);
`endif
                    end else begin // clear
                        irq_mask <= irq_mask & ~data_in[6:0];
`ifdef VERBOSE_TRACE
                        $display("VIA: IER CLEAR = 0x%02x, mask now 0x%02x", data_in, irq_mask & ~data_in[6:0]);
`endif
                    end
                end
                
                4'hF: begin // ORA no handshake
                    pio_i_pra <= data_in;
                end
                
                default: begin
                end
            endcase
        end
        
        // Reads - Output only
        data_out <= 8'h00;
        case (addr)
            4'h0: begin // ORB
                // Port B ALWAYS reads the actual pin level for ALL bits, unlike
                // Port A which reads output latch for outputs. Per 6522 datasheet,
                // ORB reads perform a read-modify-write on the actual pin state.
                data_out <= irb;
                if (tmr_a_output_en == 1'b1) begin
                    data_out[7] <= timer_a_out;
                end
`ifdef VERBOSE_TRACE
                // Log ORB reads when TREQ changes or during SR activity
                if (shift_active || !irb[3]) begin
                    $display("VIA ORB_R[%0t]: %02x TREQ=%b TIP=%b BYTEACK=%b [SR=%b cnt=%d]",
                             $time, irb, ~irb[3], ~irb[5], ~irb[4], shift_active, bit_cnt);
                end
`endif
            end
            4'h1: begin // ORA
                data_out <= pra_read;
            end
            4'h2: begin // DDRB
                data_out <= pio_i_ddrb;
            end
            4'h3: begin // DDRA
                data_out <= pio_i_ddra;
            end
            4'h4: begin // TA LO counter
                data_out <= timer_a_count[7:0];
            end
            4'h5: begin // TA HI counter
                data_out <= timer_a_count[15:8];
            end
            4'h6: begin // TA LO latch
                data_out <= timer_a_latch[7:0];
            end
            4'h7: begin // TA HI latch
                data_out <= timer_a_latch[15:8];
            end
            4'h8: begin // TA LO counter
                data_out <= timer_b_count[7:0];
            end
            4'h9: begin // TA HI counter
                data_out <= timer_b_count[15:8];
            end
            4'hA: begin // SR
                data_out <= shift_reg;
            end
            4'hB: begin // ACR
                data_out <= acr;
            end
            4'hC: begin // PCR
                data_out <= pcr;
            end
            4'hD: begin // IFR
                data_out <= {irq_out, irq_flags};
`ifdef VERBOSE_TRACE
                if (shift_active || irq_flags[2]) begin
                    $display("VIA_SR[%0t]: IFR_READ 0x%02x SR_bit=%b active=%b cnt=%d",
                             $time, {irq_out, irq_flags}, irq_flags[2], shift_active, bit_cnt);
                end
`endif
            end
            4'hE: begin // IER
                data_out <= {1'b1, irq_mask};
            end
            4'hF: begin // ORA
                data_out <= pra_read;
            end
            default: begin
            end
        endcase
        
        // Read actions
        if (ren == 1'b1 && falling == 1'b1) begin
            case (addr)
                4'h0: begin // ORB
 
                    if (cb2_no_irq_clr == 1'b0) begin
                        irq_flags[3] <= 1'b0;
                    end
                    irq_flags[4] <= 1'b0;
                end
                                            
                4'h1: begin // ORA
                    if (ca2_no_irq_clr == 1'b0) begin
             
                        irq_flags[0] <= 1'b0;
                    end
                    irq_flags[1] <= 1'b0;
                end
                    
                4'h4: begin // TA LO counter
                    irq_flags[6] <= 1'b0;
                end
                    
                4'h8: begin // TB LO counter
                    irq_flags[5] <= 1'b0;
                end
                    
                4'hA: begin // SR
                    irq_flags[2] <= 1'b0;
`ifdef SIMULATION
                    $display("VIA_SR[%0t]: READ 0x%02x mode=%d dir=%b active=%b cnt=%d",
                             $time, shift_reg, shift_mode_control, shift_dir, shift_active, bit_cnt);
`endif
                end

                default: begin
                end
            endcase
        end

        if (reset == 1'b1) begin
            pio_i_pra       <= 8'h00;
            pio_i_ddra      <= 8'h00;
            pio_i_prb       <= 8'hFF;  // Default high (TIP bit 3 = 1 = not asserted)
            pio_i_ddrb      <= 8'h00;
            irq_mask        <= 7'h00;
            irq_flags       <= 7'h00;
            acr             <= 8'h00;
            pcr             <= 8'h00;
            ca2_handshake_o <= 1'b1;
            ca2_pulse_o     <= 1'b1;
            cb2_handshake_o <= 1'b1;
            cb2_pulse_o     <= 1'b1;
            timer_a_latch   <= latch_reset_pattern;
            timer_b_latch   <= latch_reset_pattern;
        end
    end

    // PIO Out select
    assign port_a_o = pio_i_pra;
    assign port_b_o[6:0] = pio_i_prb[6:0];
    assign port_b_o[7] = (tmr_a_output_en == 1'b0) ? pio_i_prb[7] : timer_a_out;
    
    assign port_a_t = pio_i_ddra;
    assign port_b_t[6:0] = pio_i_ddrb[6:0];
    assign port_b_t[7] = pio_i_ddrb[7] | tmr_a_output_en;
    // ------------------------------------------------------------------
    // Mac LC timer cadence: count on EVERY falling enable — the enables
    // already arrive at the real VIA phi2 rate. The V8 clocks the real VIA
    // at C15M/20 = 783.36 kHz (MAME v8.cpp: R65NC22(..., 15.6672_MHz_XTAL
    // / 20)); our TG68 is instantiated with E_div=1 (MacLC.sv/sim.v), which
    // halves its 68000-style E to CPU/20 ≈ 812.5 kHz — the VIA phi2
    // emulation itself (+3.7%, the clock-audit-blessed rate).
    //
    // ★ HISTORY (2026-08-05): a /2 prescaler lived here from 1850a7f
    // (2026-06-05) to 606224b+1, justified by "enables come at CPU/10 =
    // 1.56672 MHz". That was true in March (E_div was status_turbo, i.e. 0
    // at normal speed) but E_div was pinned to 1'b1 before the prescaler
    // landed, so it double-halved: T1/T2 counted at 406 kHz and EVERY VIA
    // timer interval ran 2.0x long. Measured on hardware via the floppy
    // SCAN-WITNESS: the Time Manager (VIA1 T2, unit = 16 ticks, ROM
    // a0afbe reads T2C and asr #4) stretched the Sony driver's 7 ms
    // inter-attempt sleep to ~13.5 ms, landing every re-arm ~3 ms past the
    // next sector's ID sync — a stride-2 rotational phase lock (run=130,
    // par=ODD-only, hunt=8 ms at every -81 post). Do NOT reintroduce a
    // prescaler here without first checking what rate the enables really
    // run at (tg68k.v en_E / E_div).
    // ------------------------------------------------------------------
    wire timer_tick = 1'b1;  // every falling enable = phi2 rate

    // Timer A
    reg        timer_a_reload = 1'b0;
    reg        timer_a_toggle = 1'b1;
    reg        timer_a_may_interrupt = 1'b0;
    always @(posedge clock) begin
        if (falling == 1'b1) begin
            // always count, or load

            if (timer_a_reload == 1'b1) begin
                timer_a_count <= timer_a_latch;
                if (write_t1c_l == 1'b1) begin
                    timer_a_count[7:0] <= data_in;
                end
                timer_a_reload <= 1'b0;
                timer_a_may_interrupt <= timer_a_may_interrupt & tmr_a_freerun;
            end else if (timer_tick == 1'b1) begin
                if (timer_a_count == 16'h0000) begin
                    // generate an event if we were triggered
                    timer_a_reload <= 1'b1;
                end
                // Timer continues to count in both free run and one shot.
                timer_a_count <= timer_a_count - 16'h0001;
            end
        end
        
        if (rising == 1'b1) begin
            if (timer_a_event == 1'b1 && tmr_a_output_en == 1'b1) begin
                timer_a_toggle <= ~timer_a_toggle;
            end
        end

        if (write_t1c_h == 1'b1) begin
            timer_a_may_interrupt <= 1'b1;
            timer_a_toggle <= ~tmr_a_output_en;
            timer_a_count <= {data_in, timer_a_latch[7:0]};
            timer_a_reload <= 1'b0;
        end

        if (reset == 1'b1) begin
            timer_a_may_interrupt <= 1'b0;
            timer_a_toggle <= 1'b1;
            timer_a_count <= latch_reset_pattern;
            timer_a_reload <= 1'b0;
        end
    end

    assign timer_a_out = timer_a_toggle;
    assign timer_a_event = rising & timer_a_reload & timer_a_may_interrupt;

    // Timer B
    reg        timer_b_reload_lo = 1'b0;
    reg        timer_b_oneshot_trig = 1'b0;
    reg        timer_b_timeout = 1'b0;
    reg        pb6_c = 1'b0;
    reg        pb6_d = 1'b0;
    always @(posedge clock) begin
        reg timer_b_decrement;
        
        timer_b_decrement = 1'b0;
        if (rising == 1'b1) begin
            pb6_c <= port_b_i[6];
            pb6_d <= pb6_c;
        end
                        
        if (falling == 1'b1) begin
            timer_b_timeout <= 1'b0;
            timer_b_tick <= 1'b0;

            if (tmr_b_count_mode == 1'b1) begin
                // PB6 pulse counting stays at full rate (counts external edges)
                if (pb6_d == 1'b1 && pb6_c == 1'b0) begin
                    timer_b_decrement = 1'b1;
                end
            end else begin // one shot or used for shift register
                // Timed mode: prescaled to 783.36 kHz (see timer_phase above)
                timer_b_decrement = timer_tick;
            end
                
            if (timer_b_decrement == 1'b1) begin
                if (timer_b_count == 16'h0000) begin
                    if (timer_b_oneshot_trig == 1'b1) begin
                        
                        timer_b_oneshot_trig <= 1'b0;
                        timer_b_timeout <= 1'b1;
                    end
                end
                if (timer_b_count[7:0] == 8'h00) begin
                    case (shift_mode_control)
                        3'b001, 3'b101, 3'b100: begin
          
                            timer_b_reload_lo <= 1'b1;
                            timer_b_tick <= 1'b1;
                        end
                        default: begin
                        end
                    endcase
                end
            
                timer_b_count <= timer_b_count - 16'h0001;
            end
            if (timer_b_reload_lo == 1'b1) begin
                timer_b_count[7:0] <= timer_b_latch[7:0];
                timer_b_reload_lo <= 1'b0;
            end
        end

        if (write_t2c_h == 1'b1) begin
            timer_b_count <= {data_in, timer_b_latch[7:0]};
            timer_b_oneshot_trig <= 1'b1;
        end

        if (reset == 1'b1) begin
            timer_b_count <= latch_reset_pattern;
            timer_b_reload_lo <= 1'b0;
            timer_b_oneshot_trig <= 1'b0;
        end
    end

    assign timer_b_event = rising & timer_b_timeout;
    // Serial port
    reg        trigger_serial;
    reg        shift_clock_d = 1'b1;
    reg        shift_clock = 1'b1;
    reg        shift_tick_r;
    reg        shift_tick_f;
    reg        shift_timer_tick;
    reg        ser_cb2_c = 1'b0;
    reg [2:0]  bit_cnt = 3'd0;
    reg        shift_pulse;
    reg        shift_active_prev_rising = 1'b0;  // For detecting shift completion
    reg        cb2_shift_out = 1'b1;             // Registered shift-out data bit on CB2
                                                 // (presents MSB, held across the CB1
                                                 // edge before rotating - MAME shift_out)

    always @(*) begin
        case (shift_clk_sel)
            2'b10: begin
                shift_pulse = 1'b1;
            end
                
            2'b00, 2'b01: begin
                shift_pulse = shift_timer_tick;
            end
            
            default: begin
                // In external clock mode, use the latched edge to ensure falling phase sees it
                shift_pulse = ext_edge_pending;
            end
        endcase

        if (shift_active == 1'b0) begin
            // Mode 0 still loads the shift register to external pulse (MMBEEB SD-Card interface uses this)
            // External clock mode (ext_clock_mode) also pulses without trigger - needed for CUDA
            if (shift_mode_control == 3'b000) begin
                shift_pulse = shift_clock & ~shift_clock_d;
            end else if (ext_clock_mode) begin
                shift_pulse = ext_edge_pending;
            end else begin
                shift_pulse = 1'b0;
            end
        end
    end

    // Debug: track CB1 input edges
`ifdef VERBOSE_TRACE
    reg cb1_i_prev;
    always @(posedge clock) begin
        if (reset) cb1_i_prev <= 1'b1;
        else if (rising) begin
            cb1_i_prev <= cb1_i;
            if (cb1_i != cb1_i_prev && ext_clock_mode) begin
                $display("VIA: CB1_i %s (ext_clk mode) - shift_active=%b bit_cnt=%d SR=0x%02x",
                         cb1_i ? "RISING" : "FALLING", shift_active, bit_cnt, shift_reg);
            end
        end
    end
`endif

    // In external clock mode, latch rising edges until consumed by falling phase
    reg ext_edge_pending = 1'b0;
    reg ext_fall_edge_pending = 1'b0;  // Latch CB1 falling edges for shift-out in ext clock mode
    reg cb2_latched = 1'b0;            // kept for debug port but not used in logic

    always @(posedge clock) begin
        ser_cb2_c <= cb2_i;

        // In external clock mode (ext_clock_mode), sample CB1 on EVERY clock
        // cycle to catch fast edges, then latch until consumed by falling phase
        if (ext_clock_mode) begin
            shift_clock <= cb1_i;
            shift_clock_d <= shift_clock;
            // Latch rising edge until falling phase consumes it
            if (~shift_clock_d & shift_clock) begin
                ext_edge_pending <= 1'b1;
            end
            // Latch falling edge until falling phase consumes it (for shift-out)
            if (shift_clock_d & ~shift_clock) begin
                ext_fall_edge_pending <= 1'b1;
            end
        end else if (rising == 1'b1) begin
            if (shift_active == 1'b0) begin
                if (shift_mode_control == 3'b000) begin
                    shift_clock <= cb1_i;
                end else begin
                    shift_clock <= 1'b1;
                end
            end else if (shift_pulse == 1'b1) begin
                shift_clock <= ~shift_clock;
            end
            shift_clock_d <= shift_clock;
        end

        if (falling == 1'b1) begin
            shift_timer_tick <= timer_b_tick;
            // Clear the pending edges after falling phase processes them
            if (ext_clock_mode && ext_edge_pending) begin
                ext_edge_pending <= 1'b0;
            end
            if (ext_clock_mode && ext_fall_edge_pending) begin
                ext_fall_edge_pending <= 1'b0;
            end
        end

        if (reset == 1'b1) begin
            shift_clock <= 1'b1;
            shift_clock_d <= 1'b1;
            ext_edge_pending <= 1'b0;
            ext_fall_edge_pending <= 1'b0;
        end
    end

    always @(*) begin
        cb1_t_int = (ext_clock_mode) ?
                    1'b0 : serport_en;
        cb1_o_int = shift_clock_d;
        ser_cb2_o = cb2_shift_out;   // registered MSB (see cb2_shift_out)
    end

    always @(*) begin
        serport_en = shift_dir |
                     shift_clk_sel[1] | shift_clk_sel[0];
        trigger_serial = ((ren == 1'b1 || wen == 1'b1) && addr == 4'hA);
        shift_tick_r = ~shift_clock_d & shift_clock;
        shift_tick_f = shift_clock_d & ~shift_clock;
    end

    always @(posedge clock) begin
        if (reset == 1'b1) begin
            shift_reg <= 8'hFF;
            cb2_shift_out <= 1'b1;
        end else begin
            // CPU writes the SR (E-timed bus access) - highest priority.
            if (falling == 1'b1 && wen == 1'b1 && addr == 4'hA) begin
                shift_reg <= data_in;
                cb2_shift_out <= data_in[7];   // present MSB immediately on load
                `ifdef SIMULATION
                $display("VIA: SR write = 0x%02x, ACR=0x%02x (mode=%d, dir=%b, serport_en=%b, cb2_o=%b)",
                         data_in, acr, shift_mode_control, shift_dir, serport_en, ser_cb2_o);
                `endif
            // External-clock mode (Egret): match MAME 6522via.cpp write_cb1() -
            // shift the SR on EACH CB1 edge, decoupled from the VIA E phase:
            // shift-in on CB1 rising, shift-out on CB1 falling. Using the
            // per-clk edge pulses (shift_tick_r/shift_tick_f) instead of the
            // E-consumed ext_edge_pending flags stops fast HC05 CB1 edges from
            // coalescing into one shift per E-period (the Egret SR hang).
            end else if (ext_clock_mode) begin
                if (shift_dir == 1'b1 && shift_tick_f == 1'b1) begin            // output (falling)
                    // MAME shift_out: latch the current MSB onto CB2 (held across
                    // the edge) BEFORE rotating, so the Egret - which reads CB2
                    // AFTER its CB1 falling+rising ($14EF-$14F3) - samples bit7
                    // first. Combinational CB2=shift_reg[7] was one bit early and
                    // rotated every received byte (the byte-4 turnaround stall).
                    cb2_shift_out <= shift_reg[7];
                    shift_reg <= {shift_reg[6:0], shift_reg[7]};
                end else if (shift_dir == 1'b0 && shift_mode_control != 3'b000 && shift_tick_r == 1'b1) begin // input (rising)
                    `ifdef SIMULATION
                    $display("VIA: shift-in cb2_i=%b SR_before=0x%02x bit_cnt=%0d", cb2_i, shift_reg, bit_cnt);
                    `endif
                    shift_reg <= {shift_reg[6:0], cb2_i};
                end
            // Internal-clock modes (T2 / O2): unchanged, E-paced.
            end else if (falling == 1'b1) begin
                if (shift_dir == 1'b1 && shift_tick_f == 1'b1) begin            // output
                    cb2_shift_out <= shift_reg[7];
                    shift_reg <= {shift_reg[6:0], shift_reg[7]};
                end else if (shift_mode_control != 3'b000 && shift_dir == 1'b0 && shift_clk_sel != 2'b11 && shift_tick_r == 1'b1) begin // input
                    shift_reg <= {shift_reg[6:0], cb2_i};
                end
            end
        end
    end

    // Tell people that we're ready!
    // FIX: In external clock mode, shift_active goes low on falling, but shift_tick_r
    // happens on rising. By the next rising, shift_tick_r is gone. So we detect the
    // falling edge of shift_active instead - when it transitions from 1 to 0.
    // shift_active_prev_rising samples shift_active on rising, so when shift_active
    // goes low (on falling), the next rising sees prev=1, current=0 -> edge detected.
    assign serial_event = (shift_active_prev_rising & ~shift_active) & rising & serport_en;
    always @(posedge clock) begin
        // Sample shift_active on rising edge for edge detection
        if (rising == 1'b1) begin
            shift_active_prev_rising <= shift_active;
        end

        if (falling == 1'b1) begin
`ifdef VERBOSE_TRACE
            if (addr == 4'hA && (ren == 1'b1 || wen == 1'b1)) begin
                $display("VIA: SR access check - trigger_serial=%b, shift_active=%b, mode=%d, wen=%b, ren=%b",
                         trigger_serial, shift_active, shift_mode_control, wen, ren);
            end
`endif
            if (shift_active == 1'b0 && shift_mode_control != 3'b000) begin
                if (trigger_serial == 1'b1) begin
                    // Start a transfer: 8 bits = 8 relevant CB1 edges. Per-edge
                    // counting (below, decoupled from E) handles edge timing, so
                    // no more "simultaneous edge" -6 hack is needed.
                    bit_cnt <= 3'd7;
                    `ifdef SIMULATION
                    $display("VIA: SR triggered - mode=%d, dir=%b, ext_clk=%b, start_cnt=7",
                             shift_mode_control, shift_dir, (ext_clock_mode));
                    `endif
                    shift_active <= 1'b1;
                end
            end else if (!ext_clock_mode) begin // internal-clock active decrement (E-paced, unchanged)
                if (shift_clk_sel == 2'b00) begin
                    shift_active <= shift_dir;
                end else if (shift_pulse == 1'b1 && shift_clock == 1'b1) begin
                    if (bit_cnt == 3'd0) begin
                        shift_active <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt - 3'd1;
                    end
                end
            end
        end
        // External-clock active count: match MAME (6522via.cpp shift_in/shift_out
        // called per CB1 edge from write_cb1). One count per CB1 edge, decoupled
        // from E: shift-in counts on CB1 rising, shift-out on CB1 falling. The
        // matching shift_reg shift happens on the same edge (above), so 8 edges
        // shift 8 bits and complete -> serial_event -> IFR[2].
        if (ext_clock_mode && shift_active == 1'b1) begin
            if ((shift_dir == 1'b0 && shift_tick_r == 1'b1) ||
                (shift_dir == 1'b1 && shift_tick_f == 1'b1)) begin
                if (bit_cnt == 3'd0) begin
                    shift_active <= 1'b0;
`ifdef SIMULATION
                    $display("VIA_SR[%0t]: COMPLETE (ext) SR=0x%02x dir=%b", $time, shift_reg, shift_dir);
`endif
                end else begin
                    bit_cnt <= bit_cnt - 3'd1;
                end
            end
        end

        `ifdef VERBOSE_TRACE
        if (rising == 1'b1 && serial_event == 1'b1) begin
            $display("VIA: SR IRQ fired! SR=0x%02x, IFR before=0x%02x", shift_reg, irq_flags);
        end
        `endif

        if (reset == 1'b1) begin
            shift_active <= 1'b0;
            shift_active_prev_rising <= 1'b0;
            bit_cnt <= 3'd0;
        end
    end

    // Shift register status outputs for CUDA interface
    assign sr_out_active = shift_active;
    assign sr_out_dir    = shift_dir;
    assign sr_ext_clk    = (ext_clock_mode);  // External clock mode (CB1)

    // Debug outputs for FPGA SR diagnostics (SignalTap / on-screen indicators)
    assign sr_dbg_bit_cnt     = bit_cnt;
    assign sr_dbg_edge_pending = ext_edge_pending;
    assign sr_dbg_fall_pending = ext_fall_edge_pending;
    assign sr_dbg_shift_reg   = shift_reg;

endmodule