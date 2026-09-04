// m68hc05_core.sv - 68HC05 CPU Core
// Converted from VHDL implementation by Ulrich Riedel
// Original: UR6805
// 
// This is a complete 68HC05 microcontroller core suitable for Egret emulation
// Supports the full 68HC05 instruction set with interrupt handling

module m68hc05_core (
    input  logic        clk,
    input  logic        cen,    // Clock enable (active high)
    input  logic        rst,
    input  logic        irq,        // External IRQ (active-low) -> vector $FFFA
    input  logic        timer_irq,  // Timer interrupt (active-low) -> vector $FFF8
    input  logic        onesec_irq, // One-second timer (active-low) -> vector $FFF6
    output logic [15:0] addr,
    output logic        wr,
    input  logic [7:0]  datain,
    output logic [3:0]  state,
    output logic [7:0]  dataout
);

    // Constants
    localparam CPUread  = 1'b1;
    localparam CPUwrite = 1'b0;
    
    // Address mux selectors
    localparam [2:0] addrPC = 3'b000;
    localparam [2:0] addrSP = 3'b001;
    localparam [2:0] addrHX = 3'b010;
    localparam [2:0] addrTM = 3'b011;
    localparam [2:0] addrX2 = 3'b100;
    localparam [2:0] addrS2 = 3'b101;
    localparam [2:0] addrX1 = 3'b110;
    localparam [2:0] addrS1 = 3'b111;
    
    // Data mux selectors
    localparam [3:0] outA    = 4'b0000;
    localparam [3:0] outH    = 4'b0001;
    localparam [3:0] outX    = 4'b0010;
    localparam [3:0] outSPL  = 4'b0011;
    localparam [3:0] outSPH  = 4'b0100;
    localparam [3:0] outPCL  = 4'b0101;
    localparam [3:0] outPCH  = 4'b0110;
    localparam [3:0] outTL   = 4'b0111;
    localparam [3:0] outTH   = 4'b1000;
    localparam [3:0] outHelp = 4'b1001;
    localparam [3:0] outCode = 4'b1010;
    
    // Bit masks for BSET/BCLR
    logic [7:0] mask0 [0:7];
    logic [7:0] mask1 [0:7];
    
    // CPU registers
    logic [7:0]  regA;
    logic [7:0]  regX;
    logic [15:0] regSP;
    logic [15:0] regPC;
    
    // CPU flags
    logic flagH;  // Half carry
    logic flagI;  // Interrupt mask
    logic flagN;  // Negative
    logic flagZ;  // Zero
    logic flagC;  // Carry
    
    // Internal registers
    logic [7:0]  help;
    logic [15:0] temp;
    logic [3:0]  mainFSM;
    logic [2:0]  addrMux;
    logic [3:0]  dataMux;
    logic [7:0]  opcode;
    logic [15:0] prod;
    
    // IRQ handling
    logic irq_d;
    logic timer_irq_d;
    logic onesec_irq_d;
    logic ext_irq_pending;   // latched falling edge of the external IRQ pin
    logic irqRequest;
    logic [1:0] irq_source;  // 0=ext IRQ, 1=timer, 2=one-second
    
    // Trace support (for debugging)
    logic trace;
    logic trace_i;
    logic [7:0] traceOpCode;
    
    // Multiplier instantiation
    mul8 mul (
        .a(regA),
        .b(regX),
        .prod(prod)
    );
    
    // Address multiplexer
    always_comb begin
        case (addrMux)
            addrPC: addr = regPC;
            addrSP: addr = regSP;
            addrHX: addr = {8'h00, regX};
            addrTM: addr = temp;
            addrX2: addr = {8'h00, regX} + temp;
            addrS2: addr = regSP + temp;
            addrX1: addr = {8'h00, regX} + {8'h00, temp[7:0]};
            addrS1: addr = regSP + {8'h00, temp[7:0]};
            default: addr = 16'h0000;
        endcase
    end
    
    // Data output multiplexer
    always_comb begin
        case (dataMux)
            outA:    dataout = regA;
            outH:    dataout = regX;
            outX:    dataout = regX;
            outSPL:  dataout = regSP[7:0];
            outSPH:  dataout = regSP[15:8];
            outPCL:  dataout = regPC[7:0];
            outPCH:  dataout = regPC[15:8];
            outTL:   dataout = temp[7:0];
            outTH:   dataout = temp[15:8];
            outHelp: dataout = help;
            outCode: dataout = traceOpCode;
            default: dataout = 8'h00;
        endcase
    end
    
    assign state = mainFSM;
    
    // Main CPU state machine
    always_ff @(posedge clk or negedge rst) begin
        automatic logic [7:0] tres;
        automatic logic [15:0] lres;
        
        if (!rst) begin
            // Initialize bit masks
            mask0[0] <= 8'b11111110;
            mask0[1] <= 8'b11111101;
            mask0[2] <= 8'b11111011;
            mask0[3] <= 8'b11110111;
            mask0[4] <= 8'b11101111;
            mask0[5] <= 8'b11011111;
            mask0[6] <= 8'b10111111;
            mask0[7] <= 8'b01111111;
            
            mask1[0] <= 8'b00000001;
            mask1[1] <= 8'b00000010;
            mask1[2] <= 8'b00000100;
            mask1[3] <= 8'b00001000;
            mask1[4] <= 8'b00010000;
            mask1[5] <= 8'b00100000;
            mask1[6] <= 8'b01000000;
            mask1[7] <= 8'b10000000;
            
            wr <= CPUread;
            flagH <= 1'b0;
            flagI <= 1'b1;  // IRQ disabled at reset
            flagN <= 1'b0;
            flagZ <= 1'b0;
            flagC <= 1'b0;
            
            regA    <= 8'h00;
            regX    <= 8'h02;  // Initialize X=2 for Egret firmware (expects port test loop counter)
            regSP   <= 16'h00FF;
            regPC   <= 16'hFFFE;
            temp    <= 16'hFFFE;
            help    <= 8'h00;
            dataMux <= outA;
            addrMux <= addrTM;
            irq_d   <= 1'b1;
            timer_irq_d <= 1'b1;
            onesec_irq_d <= 1'b1;
            ext_irq_pending <= 1'b0;
            irqRequest <= 1'b0;
            irq_source <= 2'd0;
            mainFSM <= 4'h0;
            
            trace   <= 1'b0;
            trace_i <= 1'b0;

        end else if (cen) begin
            // Clock enabled - normal operation
            // Maskable interrupt sensing.  Priority: one-second > timer > ext IRQ.
            //
            // onesec/timer are LEVEL-sensitive (real 68HC05 / MAME semantics):
            // each source's flag register holds its line asserted until the ISR
            // acks it ($12 bit 6 / $08 bit 7), so a tick that lands while I is
            // masked (the firmware's SEI shift windows, other ISRs) fires as soon
            // as I clears.  The old edge detection DROPPED such edges — and the
            // ack lives in the never-run ISR, so the line stayed low forever and
            // the one-second interrupt deadlocked permanently (frozen guest
            // clock/RTC, while everything polled kept working).
            //
            // Requests latch only at opcode fetch (mainFSM 4'h2) so a pending
            // level cannot hijack the vector selection of an SWI sequence already
            // in flight (states 3-7 check !irqRequest), and a pending interrupt
            // is taken on instruction boundaries exactly like the real core.
            irq_d <= irq;
            timer_irq_d <= timer_irq;
            onesec_irq_d <= onesec_irq;
            if ((irq == 1'b0) && (irq_d == 1'b1))
                ext_irq_pending <= 1'b1;   // edge-latched; pin is tied high today
            if (flagI == 1'b0 && !irqRequest && mainFSM == 4'h2) begin
                if (onesec_irq == 1'b0) begin
                    irqRequest <= 1'b1;
                    irq_source <= 2'd2;
                    `ifdef VERBOSE_TRACE
                    $display("HC05: ONE-SEC IRQ request! PC=%04x", regPC);
                    `endif
                end else if (timer_irq == 1'b0) begin
                    irqRequest <= 1'b1;
                    irq_source <= 2'd1;
                    `ifdef VERBOSE_TRACE
                    $display("HC05: TIMER IRQ request! PC=%04x", regPC);
                    `endif
                end else if (ext_irq_pending) begin
                    irqRequest <= 1'b1;
                    irq_source <= 2'd0;
                    ext_irq_pending <= 1'b0;
                    `ifdef VERBOSE_TRACE
                    $display("HC05: EXT IRQ request! PC=%04x", regPC);
                    `endif
                end
            end
            `ifdef VERBOSE_TRACE
            if (flagI == 1'b1) begin
                if ((onesec_irq == 1'b0) && (onesec_irq_d == 1'b1))
                    $display("HC05: ONE-SEC IRQ edge BLOCKED (flagI=1) PC=%04x", regPC);
                if ((timer_irq == 1'b0) && (timer_irq_d == 1'b1))
                    $display("HC05: TIMER IRQ edge BLOCKED (flagI=1) PC=%04x", regPC);
                if ((irq == 1'b0) && (irq_d == 1'b1))
                    $display("HC05: EXT IRQ edge BLOCKED (flagI=1) PC=%04x", regPC);
            end
            `endif
            
            case (mainFSM)
                4'h0: begin  // Reset - fetch PCH from FFFE
                    regPC[15:8] <= datain;
                    temp <= temp + 16'h0001;
                    mainFSM <= 4'h1;
                end
                
                4'h1: begin  // Reset - fetch PCL from FFFF
                    regPC[7:0] <= datain;
                    addrMux <= addrPC;
                    mainFSM <= 4'h2;
                end
                
                4'h2: begin  // Fetch opcode - instruction cycle 1
                    trace <= trace_i;
                    
                    if (trace) begin
                        opcode <= 8'h83;  // Special SWI trace
                        traceOpCode <= datain;
                        addrMux <= addrSP;
                        mainFSM <= 4'h3;
                    end else if (irqRequest) begin
                        opcode <= 8'h83;  // Special SWI interrupt
                        addrMux <= addrSP;
                        mainFSM <= 4'h3;
                    end else begin
                        opcode <= datain;
                        `ifdef VERBOSE_TRACE
                        $display("HC05: TRACE PC=%04x opcode=%02x A=%02x X=%02x SP=%04x SR=%b%b%b%b%b @%0t",
                                 regPC, datain, regA, regX, regSP, flagH, flagI, flagN, flagZ, flagC, $time);
                        `endif
                        
                        case (datain)
                            8'h82: begin  // RTT - return from trace
                                trace_i <= 1'b1;
                                regSP <= regSP + 16'h0001;
                                addrMux <= addrSP;
                                mainFSM <= 4'h3;
                            end
                            
                            // BRSET/BRCLR/BSET/BCLR and direct mode instructions
                            8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
                            8'h08, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F,
                            8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
                            8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F,
                            8'h30, 8'h33, 8'h34, 8'h36, 8'h37, 8'h38, 8'h39, 8'h3A, 8'h3C, 8'h3D, 8'h3F,
                            8'hB0, 8'hB1, 8'hB2, 8'hB3, 8'hB4, 8'hB5, 8'hB6, 8'hB7,
                            8'hB8, 8'hB9, 8'hBA, 8'hBB, 8'hBC, 8'hBE, 8'hBF: begin
                                temp <= 16'h0000;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            // Branch and extended addressing
                            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27,
                            8'h28, 8'h29, 8'h2A, 8'h2B, 8'h2C, 8'h2D, 8'h2E, 8'h2F,
                            8'hC0, 8'hC1, 8'hC2, 8'hC3, 8'hC4, 8'hC5, 8'hC6, 8'hC7,
                            8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCC, 8'hCE, 8'hCF,
                            8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4, 8'hD5, 8'hD6, 8'hD7,
                            8'hD8, 8'hD9, 8'hDA, 8'hDB, 8'hDC, 8'hDE, 8'hDF: begin
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            // Indexed ,X read-modify-write
                            8'h70, 8'h73, 8'h74, 8'h76, 8'h77, 8'h78, 8'h79, 8'h7A, 8'h7C, 8'h7D: begin
                                addrMux <= addrHX;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h4;
                            end
                            
                            // Immediate mode
                            8'hA0, 8'hA1, 8'hA2, 8'hA3, 8'hA4, 8'hA5, 8'hA6,
                            8'hA8, 8'hA9, 8'hAA, 8'hAB, 8'hAE: begin
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h5;
                            end
                            
                            // Indexed with 8-bit offset
                            8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hE4, 8'hE5, 8'hE6, 8'hE7,
                            8'hE8, 8'hE9, 8'hEA, 8'hEB, 8'hEC, 8'hEE, 8'hEF: begin
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h4;
                            end
                            
                            // Indexed no offset
                            8'hF0, 8'hF1, 8'hF2, 8'hF3, 8'hF4, 8'hF5, 8'hF6,
                            8'hF8, 8'hF9, 8'hFA, 8'hFB, 8'hFE: begin
                                addrMux <= addrHX;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h5;
                            end
                            
                            8'hFC: begin  // JMP ,X
                                regPC <= {8'h00, regX};
                                mainFSM <= 4'h2;
                            end
                            
                            8'hF7: begin  // STA ,X
                                wr <= CPUwrite;
                                flagN <= regA[7];
                                flagZ <= (regA == 8'h00);
                                dataMux <= outA;
                                addrMux <= addrHX;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h5;
                            end
                            
                            8'hFF: begin  // STX ,X
                                wr <= CPUwrite;
                                flagN <= regX[7];
                                flagZ <= (regX == 8'h00);
                                dataMux <= outX;
                                addrMux <= addrHX;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h5;
                            end
                            
                            // Accumulator A operations
                            8'h40: begin  // NEGA
                                tres = 8'h00 - regA;
                                regA <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                flagC <= (tres != 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h42: begin  // MUL
                                flagH <= 1'b0;
                                flagC <= 1'b0;
                                regA <= prod[7:0];
                                regX <= prod[15:8];
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h43: begin  // COMA
                                tres = regA ^ 8'hFF;
                                regA <= tres;
                                flagC <= 1'b1;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h44: begin  // LSRA
                                tres = {1'b0, regA[7:1]};
                                regA <= tres;
                                flagN <= 1'b0;
                                flagC <= regA[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h46: begin  // RORA
                                tres = {flagC, regA[7:1]};
                                regA <= tres;
                                flagN <= flagC;
                                flagC <= regA[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h47: begin  // ASRA
                                tres = {regA[7], regA[7:1]};
                                regA <= tres;
                                flagN <= regA[7];
                                flagC <= regA[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h48: begin  // LSLA
                                tres = {regA[6:0], 1'b0};
                                regA <= tres;
                                flagN <= regA[6];
                                flagC <= regA[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h49: begin  // ROLA
                                tres = {regA[6:0], flagC};
                                regA <= tres;
                                flagN <= regA[6];
                                flagC <= regA[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h4A: begin  // DECA
                                tres = regA - 8'h01;
                                regA <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h4C: begin  // INCA
                                tres = regA + 8'h01;
                                regA <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h4D: begin  // TSTA
                                flagN <= regA[7];
                                flagZ <= (regA == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h4F: begin  // CLRA
                                regA <= 8'h00;
                                flagN <= 1'b0;
                                flagZ <= 1'b1;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            // X register operations
                            8'h50: begin  // NEGX
                                tres = 8'h00 - regX;
                                regX <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                flagC <= (tres != 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h53: begin  // COMX
                                tres = regX ^ 8'hFF;
                                regX <= tres;
                                flagC <= 1'b1;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h54: begin  // LSRX
                                tres = {1'b0, regX[7:1]};
                                regX <= tres;
                                flagN <= 1'b0;
                                flagC <= regX[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h56: begin  // RORX
                                tres = {flagC, regX[7:1]};
                                regX <= tres;
                                flagN <= flagC;
                                flagC <= regX[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h57: begin  // ASRX
                                tres = {regX[7], regX[7:1]};
                                regX <= tres;
                                flagN <= regX[7];
                                flagC <= regX[0];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h58: begin  // LSLX
                                tres = {regX[6:0], 1'b0};
                                regX <= tres;
                                flagN <= regX[6];
                                flagC <= regX[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h59: begin  // ROLX
                                tres = {regX[6:0], flagC};
                                regX <= tres;
                                flagN <= regX[6];
                                flagC <= regX[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h5A: begin  // DECX
                                tres = regX - 8'h01;
                                regX <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h5C: begin  // INCX
                                tres = regX + 8'h01;
                                regX <= tres;
                                flagN <= tres[7];
                                flagZ <= (tres == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h5D: begin  // TSTX
                                flagN <= regX[7];
                                flagZ <= (regX == 8'h00);
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h5F: begin  // CLRX
                                regX <= 8'h00;
                                flagN <= 1'b0;
                                flagZ <= 1'b1;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            // Indexed with 8-bit offset RMW
                            8'h60, 8'h63, 8'h64, 8'h66, 8'h67, 8'h68, 8'h69, 8'h6A, 8'h6C, 8'h6D, 8'h6F: begin
                                temp <= {8'h00, regX};
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            8'h7F: begin  // CLR ,X
                                flagN <= 1'b0;
                                flagZ <= 1'b1;
                                addrMux <= addrHX;
                                dataMux <= outHelp;
                                wr <= CPUwrite;
                                help <= 8'h00;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            8'h80, 8'h81: begin  // RTI, RTS
                                regSP <= regSP + 16'h0001;
                                addrMux <= addrSP;
                                mainFSM <= 4'h3;
                            end
                            
                            8'h83: begin  // SWI
                                regPC <= regPC + 16'h0001;
                                addrMux <= addrSP;
                                mainFSM <= 4'h3;
                            end
                            
                            8'h8E, 8'h8F: begin  // STOP, WAIT - unsupported
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h97: begin  // TAX
                                regX <= regA;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h98, 8'h99: begin  // CLC, SEC
                                flagC <= datain[0];
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h9A, 8'h9B: begin  // CLI, SEI
                                flagI <= datain[0];
                                `ifdef VERBOSE_TRACE
                                if (datain[0] == 0)
                                    $display("HC05: CLI - Interrupts ENABLED at PC=%04x (flagI: 1->0)", regPC);
                                else
                                    $display("HC05: SEI - Interrupts DISABLED at PC=%04x (flagI: 0->1)", regPC);
                                `endif
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h9C: begin  // RSP
                                regSP <= 16'h00FF;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            8'h9F: begin  // TXA
                                regA <= regX;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                            
                            // JSR/BSR instructions
                            8'hAD, 8'hBD, 8'hED: begin  // BSR, JSR opr8a, JSR oprx8,X
                                temp <= regPC + 16'h0002;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            8'hCD, 8'hDD: begin  // JSR opr16a, JSR oprx16,X
                                temp <= regPC + 16'h0003;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h3;
                            end
                            
                            8'hFD: begin  // JSR ,X
                                temp <= regPC + 16'h0001;
                                wr <= CPUwrite;
                                addrMux <= addrSP;
                                dataMux <= outTL;
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h4;
                            end
                            
                            // Illegal/NOP
                            default: begin
                                regPC <= regPC + 16'h0001;
                                mainFSM <= 4'h2;
                            end
                        endcase
                    end
                end
                
                4'h3: begin  // Instruction cycle 2
                    `ifdef VERBOSE_TRACE
                    if (opcode == 8'h81)
                        $display("HC05_STATE3: opcode=0x%02x SP=0x%04x PC=0x%04x addr=0x%04x datain=0x%02x", opcode, regSP, regPC, addr, datain);
                    `endif
                    case (opcode)
                        // BRSET/BRCLR/BSET/BCLR with direct addressing
                        8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
                        8'h08, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F,
                        8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
                        8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F,
                        8'h30, 8'h33, 8'h34, 8'h36, 8'h37, 8'h38, 8'h39, 8'h3A, 8'h3C, 8'h3D: begin
                            temp[7:0] <= datain;
                            addrMux <= addrTM;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h4;
                        end
                        
                        // Extended addressing modes
                        8'hC0, 8'hC1, 8'hC2, 8'hC3, 8'hC4, 8'hC5, 8'hC6, 8'hC7,
                        8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCC, 8'hCE, 8'hCF,
                        8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4, 8'hD5, 8'hD6, 8'hD7,
                        8'hD8, 8'hD9, 8'hDA, 8'hDB, 8'hDC, 8'hDE, 8'hDF: begin
                            temp[15:8] <= datain;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h4;
                        end
                        
                        8'hB7: begin  // STA opr8a
                            wr <= CPUwrite;
                            dataMux <= outA;
                            temp[7:0] <= datain;
                            addrMux <= addrTM;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hBF: begin  // STX opr8a
                            wr <= CPUwrite;
                            dataMux <= outX;
                            temp[7:0] <= datain;
                            addrMux <= addrTM;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hB0, 8'hB1, 8'hB2, 8'hB3, 8'hB4, 8'hB5, 8'hB6,
                        8'hB8, 8'hB9, 8'hBA, 8'hBB, 8'hBE: begin
                            temp[7:0] <= datain;
                            addrMux <= addrTM;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        // Branch instructions
                        8'h20: begin  // BRA
                            if (datain[7])
                                regPC <= regPC + {8'hFF, datain} + 16'h0001;
                            else
                                regPC <= regPC + {8'h00, datain} + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h21: begin  // BRN
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h22, 8'h23: begin  // BHI, BLS
                            if ((flagC | flagZ) == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h24, 8'h25: begin  // BCC, BCS
                            if (flagC == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h26, 8'h27: begin  // BNE, BEQ
                            if (flagZ == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h28, 8'h29: begin  // BHCC, BHCS
                            if (flagH == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h2A, 8'h2B: begin  // BPL, BMI
                            if (flagN == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h2C, 8'h2D: begin  // BMC, BMS
                            if (flagI == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h2E, 8'h2F: begin  // BIL, BIH
                            if (irq == opcode[0]) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            mainFSM <= 4'h2;
                        end
                        
                        8'h3F, 8'h6F: begin  // CLR opr8a, CLR oprx8,X
                            wr <= CPUwrite;
                            if (opcode == 8'h3F)
                                temp[7:0] <= datain;
                            else
                                temp <= temp + {8'h00, datain};
                            addrMux <= addrTM;
                            dataMux <= outHelp;
                            flagZ <= 1'b1;
                            flagN <= 1'b0;
                            help <= 8'h00;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h4;
                        end
                        
                        8'h60, 8'h63, 8'h64, 8'h66, 8'h67, 8'h68, 8'h69, 8'h6A, 8'h6C, 8'h6D: begin
                            temp <= temp + {8'h00, datain};
                            regPC <= regPC + 16'h0001;
                            addrMux <= addrTM;
                            mainFSM <= 4'h4;
                        end
                        
                        8'h7F: begin  // CLR ,X
                            wr <= CPUread;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h80, 8'h82: begin  // RTI, RTT
                            flagH <= datain[4];
                            flagI <= datain[3];
                            flagN <= datain[2];
                            flagZ <= datain[1];
                            flagC <= datain[0];
                            `ifdef VERBOSE_TRACE
                            $display("HC05: RTI restoring flags from 0x%02x - flagI will be %b, PC=%04x", datain, datain[3], regPC);
                            `endif
                            regSP <= regSP + 16'h0001;
                            mainFSM <= 4'h4;
                        end

                        8'h81: begin  // RTS
                            `ifdef VERBOSE_TRACE
                            $display("HC05_RTS[state3]: SP=0x%04x datain=0x%02x addr=0x%04x PC=0x%04x -> regPC[15:8]=0x%02x, next=state4", regSP, datain, addr, regPC, datain);
                            `endif
                            regPC[15:8] <= datain;
                            regSP <= regSP + 16'h0001;
                            mainFSM <= 4'h4;
                        end
                        
                        8'h83: begin  // SWI
                            wr <= CPUwrite;
                            dataMux <= outPCL;
                            mainFSM <= 4'h4;
                        end
                        
                        8'hAD, 8'hBD, 8'hED: begin  // BSR, JSR opr8a, JSR oprx8,X
                            regPC <= regPC + 16'h0001;
                            wr <= CPUwrite;
                            help <= datain;
                            addrMux <= addrSP;
                            dataMux <= outPCL;
                            mainFSM <= 4'h4;
                        end
                        
                        8'hBC: begin  // JMP opr8a
                            regPC <= {8'h00, datain};
                            mainFSM <= 4'h2;
                        end
                        
                        8'hCD, 8'hDD: begin  // JSR opr16a, JSR oprx16,X
                            temp[15:8] <= datain;
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h4;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h4: begin  // Instruction cycle 3
                    `ifdef VERBOSE_TRACE
                    // Unconditional state4 debug to catch missing RTS state4
                    if (regPC >= 16'h12A0 && regPC <= 16'h12C0)
                        $display("HC05_STATE4_ENTRY: opcode=0x%02x SP=0x%04x PC=0x%04x addr=0x%04x datain=0x%02x", opcode, regSP, regPC, addr, datain);
                    if (opcode == 8'h81)
                        $display("HC05_STATE4: opcode=0x%02x SP=0x%04x PC=0x%04x addr=0x%04x datain=0x%02x regPC_high=0x%02x", opcode, regSP, regPC, addr, datain, regPC[15:8]);
                    `endif
                    case (opcode)
                        // BRSET/BRCLR
                        8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
                        8'h08, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F: begin
                            flagC <= ((datain & mask1[opcode[3:1]]) != 8'h00);
                            addrMux <= addrPC;
                            mainFSM <= 4'h5;
                        end
                        
                        // BSET/BCLR
                        8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
                        8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F: begin
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            if (opcode[0])
                                help <= datain & mask0[opcode[3:1]];
                            else
                                help <= datain | mask1[opcode[3:1]];
                            mainFSM <= 4'h5;
                        end
                        
                        // Extended and indexed addressing
                        8'hC0, 8'hC1, 8'hC2, 8'hC3, 8'hC4, 8'hC5, 8'hC6,
                        8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCE,
                        8'hD0, 8'hD1, 8'hD2, 8'hD3, 8'hD4, 8'hD5, 8'hD6,
                        8'hD8, 8'hD9, 8'hDA, 8'hDB, 8'hDE,
                        8'hE0, 8'hE1, 8'hE2, 8'hE3, 8'hE4, 8'hE5, 8'hE6,
                        8'hE8, 8'hE9, 8'hEA, 8'hEB, 8'hEE: begin
                            temp[7:0] <= datain;
                            case (opcode[7:4])
                                4'hC: addrMux <= addrTM;
                                4'hD: addrMux <= addrX2;
                                4'hE: addrMux <= addrX1;
                                default: addrMux <= addrTM;
                            endcase
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hCC: begin  // JMP opr16a
                            regPC <= {temp[15:8], datain};
                            mainFSM <= 4'h2;
                        end
                        
                        8'hDC: begin  // JMP oprx16,X
                            regPC <= {temp[15:8], datain} + {8'h00, regX};
                            mainFSM <= 4'h2;
                        end
                        
                        8'hEC: begin  // JMP oprx8,X
                            regPC <= {8'h00, datain} + {8'h00, regX};
                            mainFSM <= 4'h2;
                        end
                        
                        // Store instructions
                        8'hC7, 8'hD7, 8'hE7: begin  // STA variants
                            wr <= CPUwrite;
                            flagN <= regA[7];
                            flagZ <= (regA == 8'h00);
                            dataMux <= outA;
                            temp[7:0] <= datain;
                            case (opcode[7:4])
                                4'hC: addrMux <= addrTM;
                                4'hD: addrMux <= addrX2;
                                4'hE: addrMux <= addrX1;
                                default: addrMux <= addrTM;
                            endcase
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hCF, 8'hDF, 8'hEF: begin  // STX variants
                            wr <= CPUwrite;
                            flagN <= regX[7];
                            flagZ <= (regX == 8'h00);
                            dataMux <= outX;
                            temp[7:0] <= datain;
                            case (opcode[7:4])
                                4'hC: addrMux <= addrTM;
                                4'hD: addrMux <= addrX2;
                                4'hE: addrMux <= addrX1;
                                default: addrMux <= addrTM;
                            endcase
                            regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        // Read-modify-write operations
                        8'h30, 8'h60, 8'h70: begin  // NEG
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = 8'h00 - datain;
                            help <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagC <= (tres != 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h33, 8'h63, 8'h73: begin  // COM
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = datain ^ 8'hFF;
                            help <= tres;
                            flagC <= 1'b1;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h34, 8'h64, 8'h74: begin  // LSR
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = {1'b0, datain[7:1]};
                            help <= tres;
                            flagN <= 1'b0;
                            flagC <= datain[0];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h36, 8'h66, 8'h76: begin  // ROR
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = {flagC, datain[7:1]};
                            help <= tres;
                            flagN <= flagC;
                            flagC <= datain[0];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h37, 8'h67, 8'h77: begin  // ASR
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = {datain[7], datain[7:1]};
                            help <= tres;
                            flagN <= datain[7];
                            flagC <= datain[0];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h38, 8'h68, 8'h78: begin  // LSL
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = {datain[6:0], 1'b0};
                            help <= tres;
                            flagN <= datain[6];
                            flagC <= datain[7];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h39, 8'h69, 8'h79: begin  // ROL
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = {datain[6:0], flagC};
                            help <= tres;
                            flagN <= datain[6];
                            flagC <= datain[7];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h3A, 8'h6A, 8'h7A: begin  // DEC
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = datain - 8'h01;
                            help <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h3C, 8'h6C, 8'h7C: begin  // INC
                            wr <= CPUwrite;
                            dataMux <= outHelp;
                            tres = datain + 8'h01;
                            help <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            mainFSM <= 4'h5;
                        end
                        
                        8'h3D, 8'h6D, 8'h7D: begin  // TST
                            flagN <= datain[7];
                            flagZ <= (datain == 8'h00);
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h3F, 8'h6F: begin  // CLR
                            wr <= CPUread;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h80, 8'h82: begin  // RTI, RTT
                            regA <= datain;
                            regSP <= regSP + 16'h0001;
                            mainFSM <= 4'h5;
                        end
                        
                        8'h81: begin  // RTS
                            `ifdef VERBOSE_TRACE
                            $display("HC05_RTS[state4]: SP=0x%04x datain=0x%02x -> regPC[7:0] (final PC=0x%04x)", regSP, datain, {regPC[15:8], datain});
                            `endif
                            regPC[7:0] <= datain;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end

                        8'h83: begin  // SWI
                            regSP <= regSP - 16'h0001;
                            dataMux <= outPCH;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hAD, 8'hBD, 8'hED: begin  // BSR, JSR
                            regSP <= regSP - 16'h0001;
                            dataMux <= outPCH;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hFD: begin  // JSR ,X
                            regSP <= regSP - 16'h0001;
                            dataMux <= outTH;
                            mainFSM <= 4'h5;
                        end
                        
                        8'hCD, 8'hDD: begin  // JSR opr16a, JSR oprx16,X
                            wr <= CPUwrite;
                            temp[7:0] <= datain;
                            regPC <= regPC + 16'h0001;
                            addrMux <= addrSP;
                            dataMux <= outPCL;
                            mainFSM <= 4'h5;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h5: begin  // Instruction cycle 4
                    case (opcode)
                        // BRSET/BRCLR
                        8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
                        8'h08, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F: begin
                            if ((opcode[0] ^ flagC)) begin
                                if (datain[7])
                                    regPC <= regPC + {8'hFF, datain} + 16'h0001;
                                else
                                    regPC <= regPC + {8'h00, datain} + 16'h0001;
                            end else begin
                                regPC <= regPC + 16'h0001;
                            end
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        // BSET/BCLR and RMW operations complete
                        8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
                        8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F,
                        8'h30, 8'h33, 8'h34, 8'h36, 8'h37, 8'h38, 8'h39, 8'h3A, 8'h3C,
                        8'h60, 8'h63, 8'h64, 8'h66, 8'h67, 8'h68, 8'h69, 8'h6A, 8'h6C,
                        8'h70, 8'h73, 8'h74, 8'h76, 8'h77, 8'h78, 8'h79, 8'h7A, 8'h7C,
                        8'hB7, 8'hBF, 8'hC7, 8'hCF, 8'hD7, 8'hDF, 8'hE7, 8'hEF,
                        8'hF7, 8'hFF: begin
                            wr <= CPUread;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h80, 8'h82: begin  // RTI, RTT
                            regX <= datain;
                            regSP <= regSP + 16'h0001;
                            mainFSM <= 4'h6;
                        end
                        
                        8'h83: begin  // SWI
                            regSP <= regSP - 16'h0001;
                            dataMux <= outX;
                            help[7:5] <= 3'b111;
                            help[4] <= flagH;
                            help[3] <= flagI;
                            help[2] <= flagN;
                            help[1] <= flagZ;
                            help[0] <= flagC;
                            mainFSM <= 4'h6;
                        end
                        
                        // ALU operations
                        8'hA0, 8'hB0, 8'hC0, 8'hD0, 8'hE0, 8'hF0: begin  // SUB
                            addrMux <= addrPC;
                            tres = regA - datain;
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagC <= ((~regA[7]) & datain[7]) | (datain[7] & tres[7]) | (tres[7] & (~regA[7]));
                            if (opcode == 8'hA0)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA1, 8'hB1, 8'hC1, 8'hD1, 8'hE1, 8'hF1: begin  // CMP
                            addrMux <= addrPC;
                            tres = regA - datain;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagC <= ((~regA[7]) & datain[7]) | (datain[7] & tres[7]) | (tres[7] & (~regA[7]));
                            if (opcode == 8'hA1)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA2, 8'hB2, 8'hC2, 8'hD2, 8'hE2, 8'hF2: begin  // SBC
                            addrMux <= addrPC;
                            tres = regA - datain - {7'b0, flagC};
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagC <= ((~regA[7]) & datain[7]) | (datain[7] & tres[7]) | (tres[7] & (~regA[7]));
                            if (opcode == 8'hA2)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA3, 8'hB3, 8'hC3, 8'hD3, 8'hE3, 8'hF3: begin  // CPX
                            addrMux <= addrPC;
                            tres = regX - datain;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagC <= ((~regX[7]) & datain[7]) | (datain[7] & tres[7]) | (tres[7] & (~regX[7]));
                            if (opcode == 8'hA3)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA4, 8'hB4, 8'hC4, 8'hD4, 8'hE4, 8'hF4: begin  // AND
                            addrMux <= addrPC;
                            tres = regA & datain;
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            if (opcode == 8'hA4)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA5, 8'hB5, 8'hC5, 8'hD5, 8'hE5, 8'hF5: begin  // BIT
                            addrMux <= addrPC;
                            tres = regA & datain;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            if (opcode == 8'hA5)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA6, 8'hB6, 8'hC6, 8'hD6, 8'hE6, 8'hF6: begin  // LDA
                            addrMux <= addrPC;
                            regA <= datain;
                            flagN <= datain[7];
                            flagZ <= (datain == 8'h00);
                            if (opcode == 8'hA6)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA8, 8'hB8, 8'hC8, 8'hD8, 8'hE8, 8'hF8: begin  // EOR
                            addrMux <= addrPC;
                            tres = regA ^ datain;
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            if (opcode == 8'hA8)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hA9, 8'hB9, 8'hC9, 8'hD9, 8'hE9, 8'hF9: begin  // ADC
                            addrMux <= addrPC;
                            tres = regA + datain + {7'b0, flagC};
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagH <= (regA[3] & datain[3]) | (datain[3] & (~tres[3])) | ((~tres[3]) & regA[3]);
                            flagC <= (regA[7] & datain[7]) | (datain[7] & (~tres[7])) | ((~tres[7]) & regA[7]);
                            if (opcode == 8'hA9)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hAA, 8'hBA, 8'hCA, 8'hDA, 8'hEA, 8'hFA: begin  // ORA
                            addrMux <= addrPC;
                            tres = regA | datain;
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            if (opcode == 8'hAA)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hAB, 8'hBB, 8'hCB, 8'hDB, 8'hEB, 8'hFB: begin  // ADD
                            addrMux <= addrPC;
                            tres = regA + datain;
                            regA <= tres;
                            flagN <= tres[7];
                            flagZ <= (tres == 8'h00);
                            flagH <= (regA[3] & datain[3]) | (datain[3] & (~tres[3])) | ((~tres[3]) & regA[3]);
                            flagC <= (regA[7] & datain[7]) | (datain[7] & (~tres[7])) | ((~tres[7]) & regA[7]);
                            if (opcode == 8'hAB)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hAE, 8'hBE, 8'hCE, 8'hDE, 8'hEE, 8'hFE: begin  // LDX
                            addrMux <= addrPC;
                            regX <= datain;
                            flagN <= datain[7];
                            flagZ <= (datain == 8'h00);
                            if (opcode == 8'hAE)
                                regPC <= regPC + 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hAD: begin  // BSR
                            wr <= CPUread;
                            addrMux <= addrPC;
                            if (help[7])
                                regPC <= regPC + {8'hFF, help};
                            else
                                regPC <= regPC + {8'h00, help};
                            regSP <= regSP - 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hBD: begin  // JSR opr8a
                            wr <= CPUread;
                            addrMux <= addrPC;
                            regPC <= {8'h00, help};
                            regSP <= regSP - 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hCD, 8'hDD: begin  // JSR opr16a, oprx16,X
                            regSP <= regSP - 16'h0001;
                            dataMux <= outPCH;
                            mainFSM <= 4'h6;
                        end
                        
                        8'hED: begin  // JSR oprx8,X
                            wr <= CPUread;
                            addrMux <= addrPC;
                            regPC <= {8'h00, help} + {8'h00, regX};
                            regSP <= regSP - 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hFD: begin  // JSR ,X
                            wr <= CPUread;
                            addrMux <= addrPC;
                            regPC <= {8'h00, regX};
                            regSP <= regSP - 16'h0001;
                            mainFSM <= 4'h2;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h6: begin  // Instruction cycle 5
                    case (opcode)
                        8'h80, 8'h82: begin  // RTI, RTT
                            regPC[15:8] <= datain;
                            regSP <= regSP + 16'h0001;
                            mainFSM <= 4'h7;
                        end
                        
                        8'h83: begin  // SWI
                            regSP <= regSP - 16'h0001;
                            dataMux <= outA;
                            mainFSM <= 4'h7;
                        end
                        
                        8'hCD: begin  // JSR opr16a
                            wr <= CPUread;
                            addrMux <= addrPC;
                            regSP <= regSP - 16'h0001;
                            regPC <= temp;
                            mainFSM <= 4'h2;
                        end
                        
                        8'hDD: begin  // JSR oprx16,X
                            wr <= CPUread;
                            addrMux <= addrPC;
                            regSP <= regSP - 16'h0001;
                            regPC <= temp + {8'h00, regX};
                            mainFSM <= 4'h2;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h7: begin  // Instruction cycle 6
                    case (opcode)
                        8'h80, 8'h82: begin  // RTI, RTT
                            regPC[7:0] <= datain;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        8'h83: begin  // SWI / IRQ entry
                            regSP <= regSP - 16'h0001;
                            dataMux <= outHelp;
                            flagI <= 1'b1;

                            if (!trace) begin
                                if (!irqRequest) begin
                                    temp <= 16'hFFFC;  // SWI vector
                                    `ifdef SIMULATION
                                    $display("HC05: SWI at PC=%04x, vector=FFFC", regPC);
                                    `endif
                                end else begin
                                    irqRequest <= 1'b0;
                                    // M68HC05E1 interrupt vectors by source
                                    case (irq_source)
                                        2'd2: begin
                                            temp <= 16'hFFF6;  // One-second timer vector
                                            `ifdef VERBOSE_TRACE
                                            $display("HC05: ONE-SEC IRQ taken at PC=%04x, vector=FFF6", regPC);
                                            `endif
                                        end
                                        2'd1: begin
                                            temp <= 16'hFFF8;  // Timer vector
                                            `ifdef VERBOSE_TRACE
                                            $display("HC05: TIMER IRQ taken at PC=%04x, vector=FFF8", regPC);
                                            `endif
                                        end
                                        default: begin
                                            temp <= 16'hFFFA;  // External IRQ vector
                                            `ifdef VERBOSE_TRACE
                                            $display("HC05: EXT IRQ taken at PC=%04x, vector=FFFA", regPC);
                                            `endif
                                        end
                                    endcase
                                end
                                mainFSM <= 4'h8;
                            end else begin
                                temp <= 16'hFFF8;  // Trace vector
                                mainFSM <= 4'hB;
                            end
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h8: begin  // Instruction cycle 7
                    case (opcode)
                        8'h83: begin  // SWI
                            wr <= CPUread;
                            addrMux <= addrTM;
                            regSP <= regSP - 16'h0001;
                            mainFSM <= 4'h9;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'h9: begin  // Instruction cycle 8
                    case (opcode)
                        8'h83: begin  // SWI
                            regPC[15:8] <= datain;
                            temp <= temp + 16'h0001;
                            mainFSM <= 4'hA;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'hA: begin  // Instruction cycle 9
                    case (opcode)
                        8'h83: begin  // SWI
                            regPC[7:0] <= datain;
                            addrMux <= addrPC;
                            mainFSM <= 4'h2;
                        end
                        
                        default: begin
                            mainFSM <= 4'h0;
                        end
                    endcase
                end
                
                4'hB: begin  // Instruction cycle 6a - trace
                    regSP <= regSP - 16'h0001;
                    dataMux <= outCode;
                    trace <= 1'b0;
                    trace_i <= 1'b0;
                    mainFSM <= 4'h8;
                end
                
                default: begin
                    mainFSM <= 4'h0;
                end
            endcase
        end
    end

endmodule