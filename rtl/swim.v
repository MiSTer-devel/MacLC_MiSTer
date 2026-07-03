/* SWIM (Sander/Wozniak Integrated Machine)

   Dual-mode floppy controller supporting:
   - IWM mode (backward compatible) - the mode the ROM boots in
   - ISM mode (SWIM native) - activated by a specific write sequence

   Mapped to $F16000 - $F17FFF

	IWM mode: The 16 IWM one-bit registers are {8'hDF, 8'b111xxxx1, 8'hFF}:
		0	$0		ca0L		CA0 off (0)
		1	$200	ca0H		CA0 on (1)
		2	$400	ca1L		CA1 off (0)
		3	$600	ca1H		CA1 on (1)
		4	$800	ca2L		CA2 off (0)
		5	$A00	ca2H		CA2 on (1)
		6	$C00	ph3L		LSTRB off (low)
		7	$E00	ph3H		LSTRB on (high)
		8	$1000	mtrOff	ENABLE disk enable off
		9	$1200	mtrOn		ENABLE disk enable on
		10	$1400	intDrive	SELECT select internal drive
		11	$1600	extDrive	SELECT select external drive
		12	$1800	q6L		Q6 off
		13	$1A00	q6H		Q6 on
		14	$1C00	q7L		Q7 off, read register
		15	$1E00	q7H		Q7 on, write register

	ISM mode registers (offset 0-7):
		Read:
		0 - FIFO data pop
		1 - FIFO mark pop
		2 - Error register (cleared on read)
		3 - Param[idx] (auto-increment)
		4 - Phases (ca0-ca2, lstrb)
		5 - Setup register
		6 - Mode register
		7 - Handshake (FIFO status)

		Write:
		0 - Push data to FIFO
		1 - Push data+mark to FIFO
		2 - Push CRC to FIFO
		3 - Write param[idx] (auto-increment)
		4 - Set phases
		5 - Set setup register
		6 - Mode clear (AND ~data)
		7 - Mode set (OR data)

	Notes from IWM manual:
	Serial data is shifted in/out MSB first, with a bit transferred every 2 microseconds.
	When writing data, a 1 is written as a transition on writeData at a bit cell boundary time, and a 0 is written as no transition.
	When reading data, a falling transition within a bit cell window is considered to be a 1, and no falling transition is considered a 0.
	When reading data, the read data register will latch the shift register when a 1 is shifted into the MSB.
	The read data register will be cleared 14 fclk periods (about 2 microseconds) after a valid data read takes place-- a valid data read
	   being defined as both /DEV being low and D7 (the MSB) outputting a one from the read data register for at least one fclk period.
*/

module swim
(
	input clk,
	input cep,
	input cen,

	input _reset,
	input selectSWIM,
	input _cpuRW,
	input _cpuUDS,  // LC V8 maps the SWIM on the UPPER byte (even addresses), not LDS like Mac Plus
	input [15:0] dataIn,
	input [3:0] cpuAddrRegHi,
	input SEL, // from VIA
	input driveSel, // internal drive select, 0 - upper, 1 - lower
	output [15:0] dataOut,
	input [1:0] insertDisk,
	output [1:0] diskEject,
	input [1:0] diskSides,
	input [1:0] diskMFM,    // disk is MFM-format (ISM path): {ext,int}
	input [1:0] diskHD,     // disk is 1.44MB HD: {ext,int}

	output [1:0] diskMotor,
	output [1:0] diskAct,

	// interface to fetch data for internal drive
	output [21:0] dskReadAddrInt,
	input dskReadAckInt,
	output [21:0] dskReadAddrExt,
	input dskReadAckExt,
	input [7:0] dskReadData
);

	wire [7:0] dataInLo = dataIn[7:0];
	reg [7:0] dataOutLo;
	// LC V8 reads the SWIM on the upper byte (D15-D8); lower byte is don't-care.
	assign dataOut = { dataOutLo, 8'hBE };

	// ================================================================
	// ISM mode state
	// ================================================================
	reg        ism_mode;           // 0=IWM mode, 1=ISM mode
	reg [7:0]  ism_mode_reg;       // ISM mode register
	reg [7:0]  ism_setup;          // ISM setup register
	reg [7:0]  ism_error;          // ISM error register (cleared on read)
	reg [7:0]  ism_param[0:15];    // 16-byte parameter RAM
	reg [3:0]  ism_param_idx;      // Auto-incrementing param index
	reg [15:0] ism_fifo[0:1];      // 2-entry FIFO (data + mark/CRC flags)
	reg [1:0]  ism_fifo_pos;       // FIFO fill level (0=empty, 1=one, 2=full)
	reg [1:0]  iwm_to_ism_counter; // Mode switch sequence detector

	// ISM FIFO flag bits (stored in upper byte of fifo entries)
	localparam FIFO_MARK = 8'h01;
	localparam FIFO_CRC  = 8'h02;

	// IWM state
	reg ca0, ca1, ca2, lstrb, selectExternalDrive, q6, q7;
	reg ca0Next, ca1Next, ca2Next, lstrbNext, selectExternalDriveNext, q6Next, q7Next;
	wire advanceDriveHead; // prevents overrun when debugging, does not exit on a real Mac!
	reg [7:0] writeData;
	reg [7:0] readDataLatch;
	wire _iwmBusy, _writeUnderrun;
	assign _iwmBusy = 1'b1; // for writes, a value of 1 here indicates the IWM write buffer is empty
	assign _writeUnderrun = 1'b1;

	// floppy disk drives
	reg diskEnableExt, diskEnableInt;
	reg diskEnableExtNext, diskEnableIntNext;
	wire newByteReadyInt;
	wire [7:0] readDataInt;
	wire senseInt = readDataInt[7]; // bit 7 doubles as the sense line here
	wire newByteReadyExt;
	wire [7:0] readDataExt;
	wire senseExt = readDataExt[7]; // bit 7 doubles as the sense line here

	// MFM (ISM) read stream from each drive + the pull/advance one-shot
	wire [7:0] mfm_byte_int, mfm_byte_ext;
	wire mfm_mark_int, mfm_mark_ext, mfm_crc0_int, mfm_crc0_ext;
	reg  mfm_advance;    // 1-cen pull to the active drive's MFM generator
	reg  ism_rd_armed;   // one advance per ISM reg0/1 read access
	wire mfm_pull_int = mfm_advance && !selectExternalDrive;
	wire mfm_pull_ext = mfm_advance &&  selectExternalDrive;

	// Head-select (SEL/HDSEL) source. On the Mac LC this is V8 VIA1 Port-A bit5 in
	// EVERY mode: maclc.cpp never wires the SWIM's hdsel_cb, so ISM Mode bit5 does
	// nothing (v8.cpp:258 drives write_hdsel from PA5). The MFM session and the
	// high sense-register bank (0xC-0xF, incl. the 0xD MFMModeOn verify) are all
	// reached with PA5, not Mode[5]. (Reverts the 06-13 "Fix C" effSEL=Mode[5],
	// which left SEL stuck 0 in ISM and made side 1 / high sense regs unreadable.)
	// F11, MAME 0.264 ground truth. On hdsel_cb machines (Quadras) Mode[5] matters.
	wire effSEL = SEL;

	floppy floppyInt
	(
		.clk(clk),
		.cep(cep),
		.cen(cen),

		._reset(_reset),
		.ca0(ca0),
		.ca1(ca1),
		.ca2(ca2),
		.SEL(effSEL),
		.lstrb(lstrb),
		._enable(~(diskEnableInt & driveSel)),
		.writeData(writeData),
		.readData(readDataInt),
		.advanceDriveHead(advanceDriveHead),
		.newByteReady(newByteReadyInt),
		.insertDisk(insertDisk[0]),
		.diskSides(diskSides[0]),
		.diskEject(diskEject[0]),

		.motor(diskMotor[0]),
		.act(diskAct[0]),

		.dskReadAddr(dskReadAddrInt),
		.dskReadAck(dskReadAckInt),
		.dskReadData(dskReadData),
		.mfm_disk(diskMFM[0]),
		.mfm_hd(diskHD[0]),
		.mfm_pull(mfm_pull_int),
		.mfm_byte(mfm_byte_int),
		.mfm_mark(mfm_mark_int),
		.mfm_crc0(mfm_crc0_int)
	);

	floppy floppyExt
	(
		.clk(clk),
		.cep(cep),
		.cen(cen),

		._reset(_reset),
		.ca0(ca0),
		.ca1(ca1),
		.ca2(ca2),
		.SEL(effSEL),
		.lstrb(lstrb),
		._enable(~diskEnableExt),
		.writeData(writeData),
		.readData(readDataExt),
		.advanceDriveHead(advanceDriveHead),
		.newByteReady(newByteReadyExt),
		.insertDisk(insertDisk[1]),
		.diskSides(diskSides[1]),
		.diskEject(diskEject[1]),

		.motor(diskMotor[1]),
		.act(diskAct[1]),

		.dskReadAddr(dskReadAddrExt),
		.dskReadAck(dskReadAckExt),
		.dskReadData(dskReadData),
		.mfm_disk(diskMFM[1]),
		.mfm_hd(diskHD[1]),
		.mfm_pull(mfm_pull_ext),
		.mfm_byte(mfm_byte_ext),
		.mfm_mark(mfm_mark_ext),
		.mfm_crc0(mfm_crc0_ext)
	);

	wire [7:0] readData = selectExternalDrive ? readDataExt : readDataInt;
	wire newByteReady = selectExternalDrive ? newByteReadyExt : newByteReadyInt;

	// active drive's MFM (ISM) decoded byte + flags
	wire [7:0] mfm_byte_sel = selectExternalDrive ? mfm_byte_ext : mfm_byte_int;
	wire mfm_mark_sel = selectExternalDrive ? mfm_mark_ext : mfm_mark_int;
	wire mfm_crc0_sel = selectExternalDrive ? mfm_crc0_ext : mfm_crc0_int;
	wire mfm_sense    = selectExternalDrive ? senseExt : senseInt;  // write-protect/sense
	// ISM MFM-read active: ISM personality + ACTION (mode bit3) + read (mode bit4=0)
	wire ism_read_active = ism_mode && ism_mode_reg[3] && !ism_mode_reg[4];

	reg [4:0] iwmMode;
	/* IWM mode register: S C M H L
 	 S	Clock speed:
			0 = 7 MHz
			1 = 8 MHz
		Should always be 1 for Macintosh.
	 C	Bit cell time:
			0 = 4 usec/bit (for 5.25 drives)
			1 = 2 usec/bit (for 3.5 drives) (Macintosh mode)
	 M	Motor-off timer:
			0 = leave drive on for 1 sec after program turns
			    it off
			1 = no delay (Macintosh mode)
		Should be 0 for 5.25 and 1 for 3.5.
	 H	Handshake protocol:
			0 = synchronous (software must supply proper
			    timing for writing data)
			1 = asynchronous (IWM supplies timing) (Macintosh Mode)
		Should be 0 for 5.25 and 1 for 3.5.
	 L	Latch mode:
			0 = read-data stays valid for about 7 usec
			1 = read-data stays valid for full byte time (Macintosh mode)
		Should be 0 for 5.25 and 1 for 3.5.
	*/

	// ISM register address = (addr>>9)&7 = the LOW 3 bits of cpuAddrRegHi.
	// MAME swim1.cpp ism_read/ism_write use `offset & 7`, and the maclc ROM's own
	// behaviour confirms it: it does WR $F16800(n=4) then RD $F17800(n=12) and the
	// value reads back, so both alias to ISM reg 4 (Phases) — only n&7 makes 4==12.
	// (Was cpuAddrRegHi[3:1] = n>>1, which scrambled every ISM register and broke
	// all ISM-mode floppy access.  See docs/findings_mame_floppy_driveid_2026-06-13.md.)
	wire [2:0] ism_reg_addr = cpuAddrRegHi[2:0];

	// ================================================================
	// IWM bit register updates (active in IWM mode only)
	// ================================================================
	always @(*) begin
		ca0Next <= ca0;
		ca1Next <= ca1;
		ca2Next <= ca2;
		lstrbNext <= lstrb;
		diskEnableExtNext <= diskEnableExt;
		diskEnableIntNext <= diskEnableInt;
		selectExternalDriveNext <= selectExternalDrive;
		q6Next <= q6;
		q7Next <= q7;

		if (!ism_mode && selectSWIM == 1'b1 && _cpuUDS == 1'b0) begin
			case (cpuAddrRegHi[3:1])
				3'h0: // ca0
					ca0Next <= cpuAddrRegHi[0];
				3'h1: // ca1
					ca1Next <= cpuAddrRegHi[0];
				3'h2: // ca2
					ca2Next <= cpuAddrRegHi[0];
				3'h3: // lstrb
					lstrbNext <= cpuAddrRegHi[0];
				3'h4: // disk enable
					if (selectExternalDrive)
						diskEnableExtNext <= cpuAddrRegHi[0];
					else
						diskEnableIntNext <= cpuAddrRegHi[0];
				3'h5: // external drive
					selectExternalDriveNext <= cpuAddrRegHi[0];
				3'h6: // Q6
					q6Next <= cpuAddrRegHi[0];
				3'h7: // Q7
					q7Next <= cpuAddrRegHi[0];
			endcase
		end
	end

	// IWM bit register update is merged into the write logic block below
	// to avoid multiple drivers on ca0/ca1/ca2/lstrb (Quartus requirement)

	// ================================================================
	// Read mux: IWM mode vs ISM mode
	// ================================================================
	always @(*) begin
		dataOutLo = 8'hEF;

		if (ism_mode) begin
			// ISM mode reads
			case (ism_reg_addr)
				// Data ($0) / Mark ($1): during an MFM read, return the generator's
				// current decoded byte (mark status is in the handshake); otherwise
				// the legacy CPU-written FIFO.
				3'h0:
					dataOutLo = ism_read_active ? mfm_byte_sel
					          : (ism_fifo_pos == 0) ? 8'h00 : ism_fifo[0][7:0];
				3'h1:
					dataOutLo = ism_read_active ? mfm_byte_sel
					          : (ism_fifo_pos == 0) ? 8'h00 : ism_fifo[0][7:0];
				3'h2: // Error register
					dataOutLo = ism_error;
				3'h3: // Param[idx]
					dataOutLo = ism_param[ism_param_idx];
				3'h4: // Phases
					dataOutLo = {4'b0000, lstrb, ca2, ca1, ca0};
				3'h5: // Setup register
					dataOutLo = ism_setup;
				3'h6: // Mode register
					dataOutLo = ism_mode_reg;
				// Handshake ($7), MAME swim1.cpp: b7 data-avail, b6 full, b5 error,
				// b3/b2 sense/wprot (SWIM1 drives both), b1 CRC (0=good), b0 mark.
				// In MFM read a byte is always ready, so b7/b6=1.
				3'h7:
					dataOutLo = ism_read_active
						? {1'b1, 1'b1, (ism_error != 0), 1'b0,
						   mfm_sense, mfm_sense, ~mfm_crc0_sel, mfm_mark_sel}
						: {(ism_fifo_pos != 0), (ism_fifo_pos < 2), (ism_error != 0),
						   1'b0, mfm_sense, 3'b000};
			endcase
		end
		else begin
			// IWM mode reads (original logic)
			case ({q7Next,q6Next})
				2'b00: // data-in register (from disk drive)
					dataOutLo <= readDataLatch;
				2'b01: // IWM status register: bit7=sense, bit5=ACTIVE (any drive
				       // selected — MAME ORs the enables; was AND = never active
				       // unless both drives on). bits4:0 = IWM mode. F9.
					dataOutLo <= { (selectExternalDriveNext ? senseExt : senseInt), 1'b0, diskEnableExt | diskEnableInt, iwmMode };
				2'b10: // handshake
					dataOutLo <= { _iwmBusy, _writeUnderrun, 6'b000000 };
				2'b11: // IWM mode register (write-only) or write data register
					dataOutLo <= 0;
			endcase
		end
	end

	// ================================================================
	// Write logic: IWM mode (with ISM switch detection) + ISM mode
	// ================================================================
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			iwmMode <= 0;
			writeData <= 0;
			ism_mode <= 0;
			ism_mode_reg <= 0;
			ism_setup <= 0;
			ism_error <= 0;
			ism_param_idx <= 0;
			ism_fifo_pos <= 0;
			iwm_to_ism_counter <= 0;
			ism_fifo[0] <= 0;
			ism_fifo[1] <= 0;
			// IWM bit registers (merged here to avoid multiple drivers)
			ca0 <= 0;
			ca1 <= 0;
			ca2 <= 0;
			lstrb <= 0;
			diskEnableExt <= 0;
			diskEnableInt <= 0;
			selectExternalDrive <= 0;
			q6 <= 0;
			q7 <= 0;
			mfm_advance <= 1'b0;
			ism_rd_armed <= 1'b1;
		end
		else if(cen) begin
			// Default: update IWM bit registers from combinational next-state
			ca0 <= ca0Next;
			ca1 <= ca1Next;
			ca2 <= ca2Next;
			lstrb <= lstrbNext;
			diskEnableExt <= diskEnableExtNext;
			diskEnableInt <= diskEnableIntNext;
			selectExternalDrive <= selectExternalDriveNext;
			q6 <= q6Next;
			q7 <= q7Next;

			if (_cpuRW == 0 && selectSWIM == 1'b1 && _cpuUDS == 1'b0) begin
				if (ism_mode) begin
					// ============================================
					// ISM mode writes
					// ============================================
					case (ism_reg_addr)
						3'h0: begin // Push data to FIFO
							if (ism_fifo_pos < 2) begin
								ism_fifo[ism_fifo_pos] <= {8'h00, dataInLo};
								ism_fifo_pos <= ism_fifo_pos + 1'b1;
							end else begin
								ism_error[0] <= 1'b1; // FIFO overflow
							end
						end
						3'h1: begin // Push data + mark to FIFO
							if (ism_fifo_pos < 2) begin
								ism_fifo[ism_fifo_pos] <= {FIFO_MARK, dataInLo};
								ism_fifo_pos <= ism_fifo_pos + 1'b1;
							end else begin
								ism_error[0] <= 1'b1;
							end
						end
						3'h2: begin // Push CRC to FIFO
							if (ism_fifo_pos < 2) begin
								ism_fifo[ism_fifo_pos] <= {FIFO_CRC, 8'h00};
								ism_fifo_pos <= ism_fifo_pos + 1'b1;
							end else begin
								ism_error[0] <= 1'b1;
							end
						end
						3'h3: begin // Write param[idx], auto-increment
							ism_param[ism_param_idx] <= dataInLo;
							ism_param_idx <= ism_param_idx + 1'b1;
						end
						3'h4: begin // Set phases
							ca0 <= dataInLo[0];
							ca1 <= dataInLo[1];
							ca2 <= dataInLo[2];
							lstrb <= dataInLo[3];
						end
						3'h5: // Set setup register
							ism_setup <= dataInLo;
						3'h6: begin // Mode clear (AND ~data)
							ism_mode_reg <= ism_mode_reg & ~dataInLo;
							// If bit 6 is cleared, switch back to IWM mode
							if (dataInLo[6]) begin
								ism_mode <= 0;
								iwm_to_ism_counter <= 0;
							end
							// If bit 0 (clear) is set after write, clear FIFO
							if ((ism_mode_reg & ~dataInLo) & 8'h01) begin
								ism_fifo_pos <= 0;
							end
						end
						3'h7: begin // Mode set (OR data)
							ism_mode_reg <= ism_mode_reg | dataInLo;
							// If bit 0 (clear) is set, clear FIFO
							if ((ism_mode_reg | dataInLo) & 8'h01) begin
								ism_fifo_pos <= 0;
							end
						end
					endcase
				end
				else begin
					// ============================================
					// IWM mode writes
					// ============================================
					case ({q7Next,q6Next})
						2'b11: begin
							if (diskEnableExt | diskEnableInt) begin
								writeData <= dataInLo;

								// IWM-to-ISM mode switch detector
								// Sequence: bit6=1, bit6=0, bit6=1, bit6=1
								// Reference: MAME swim1.cpp lines 554-579
								case (iwm_to_ism_counter)
									2'd0: begin
										if (dataInLo[6])
											iwm_to_ism_counter <= 2'd1;
									end
									2'd1: begin
										if (!dataInLo[6])
											iwm_to_ism_counter <= 2'd2;
										else
											iwm_to_ism_counter <= 2'd0;
									end
									2'd2: begin
										if (dataInLo[6])
											iwm_to_ism_counter <= 2'd3;
										else
											iwm_to_ism_counter <= 2'd0;
									end
									2'd3: begin
										if (dataInLo[6]) begin
											// Switch to ISM mode!
											ism_mode <= 1;
											ism_mode_reg <= 8'h40; // bit 6 = ISM mode active
											ism_error <= 0;
											ism_fifo_pos <= 0;
											ism_param_idx <= 0;
											iwm_to_ism_counter <= 0;
`ifdef SIMULATION
											$display("SWIM: Switched to ISM mode @%0t", $time);
`endif
										end
										else
											iwm_to_ism_counter <= 2'd0;
									end
								endcase
							end
							else begin
								iwmMode <= dataInLo[4:0];
								iwm_to_ism_counter <= 0; // reset counter when not enabled
							end
						end
						default: begin
							iwm_to_ism_counter <= 0; // reset on non-Q7Q6 writes
						end
					endcase
				end
			end

			// ISM mode: clear error register on read
			if (ism_mode && _cpuRW == 1 && selectSWIM == 1'b1 && _cpuUDS == 1'b0) begin
				if (ism_reg_addr == 3'h2) begin
					ism_error <= 0;
				end
				// Auto-increment param index on read
				if (ism_reg_addr == 3'h3) begin
					ism_param_idx <= ism_param_idx + 1'b1;
				end
				// FIFO pop on data or mark read
				if (ism_reg_addr == 3'h0 || ism_reg_addr == 3'h1) begin
					if (ism_fifo_pos > 0) begin
						ism_fifo[0] <= ism_fifo[1];
						ism_fifo[1] <= 0;
						ism_fifo_pos <= ism_fifo_pos - 1'b1;
					end
				end
			end

			// ISM MFM-read: advance the generator once per reg0/1 read access (one-
			// shot, re-armed between accesses). A reg0 read of a mark byte flags
			// Error bit1 (mark-read-from-data), per MAME swim1.cpp.
			if (ism_read_active && _cpuRW && selectSWIM && (_cpuUDS == 1'b0) &&
			    (ism_reg_addr == 3'h0 || ism_reg_addr == 3'h1)) begin
				if (ism_rd_armed) begin
					ism_rd_armed <= 1'b0;
					mfm_advance  <= 1'b1;
					if (ism_reg_addr == 3'h0 && mfm_mark_sel) ism_error[1] <= 1'b1;
				end else
					mfm_advance <= 1'b0;
			end else begin
				ism_rd_armed <= 1'b1;
				mfm_advance  <= 1'b0;
			end
		end
	end

	// ================================================================
	// IWM read data latch (unchanged from original)
	// ================================================================
	wire iwmRead = (_cpuRW == 1'b1 && selectSWIM == 1'b1 && _cpuUDS == 1'b0 && !ism_mode);
	reg [3:0] readLatchClearTimer;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			readDataLatch <= 0;
			readLatchClearTimer <= 0;
		end
		else if(cen) begin
			// a countdown timer governs how long after a data latch read before the latch is cleared
			if (readLatchClearTimer != 0) begin
				readLatchClearTimer <= readLatchClearTimer - 1'b1;
			end

			// the conclusion of a valid CPU read from the IWM will start the timer to clear the latch
			if (iwmRead && readDataLatch[7]) begin
				readLatchClearTimer <= 4'hD; // clear latch 14 clocks after the conclusion of a valid read
			end

			// when the drive indicates that a new byte is ready, latch it
			// NOTE: the real IWM must self-synchronize with the incoming data to determine when to latch it
			if (newByteReady) begin
				readDataLatch <= readData;
			end
			else if (readLatchClearTimer == 1'b1) begin
				readDataLatch <= 0;
			end
		end
	end
	assign advanceDriveHead = readLatchClearTimer == 1'b1; // prevents overrun when debugging, does not exist on a real Mac!
endmodule
