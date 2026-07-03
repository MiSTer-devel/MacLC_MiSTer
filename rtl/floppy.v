/* Synchronous 8-bit replica of 3.5 inch floppy disk drive.

	Differences from the true floppy interace at the Mac's DB-19 port:
	True interface has a writeReq control line, only 1-bit readData and writeData, and no clk.
	True interface does not have newByteReady signal. Instead the IWM must watch the data in bit and synchronize with it to
	   determine the timing and framing of bytes.
	
*/

/* Disk register (read):	
	    State-control lines       Register
  CA2    CA1    CA0    SEL    addressed    Information in register

  0      0      0      0      DIRTN        Head step direction (0=toward track 79, 1=toward track 0)
  0      0      0      1      CSTIN        Disk in place (0=disk is inserted)
  0      0      1      0      STEP         Drive head stepping (setting to 0 performs a step, returns to 1 when step is complete)
  0      0      1      1      WRTPRT       Disk locked (0=locked)
  0      1      0      0      MOTORON      Drive motor running (0=on, 1=off)
  0      1      0      1      TKO          Head at track 0 (0=at track 0)
  0		1		 1		  0		SWITCHED   	 Disk switched (1=yes?)
  0      1      1      1      TACH         Tachometer (produces 60 pulses for each rotation of the drive motor)
  1      0      0      0      RDDATA0      Read data, lower head, side 0
  1      0      0      1      RDDATA1      Read data, upper head, side 1 
  1      0      1      0      SUPERDR      Drive is a Superdrive (0=no, 1=yes)
  1      1      0      0      SIDES        Single- or double-sided drive (0=single side, 1=double side)
  1      1      0      1      READY        0 = yes
  1      1      1      0      INSTALLED	 0 = yes
  1      1      1      1      DRVIN        400K/800K: Drive installed (0=drive is present), Superdrive: Inserted disk capacity (0=HD, 1=DD)
	
	Disk registers (write):
    Control lines      Register
  CA1    CA0    SEL    addressed    Register function

  0      0      0      DIRTN        Set stepping direction (0=toward track 79, 1=toward track 0)
  0      0      1      SWITCHED		Reset disk switched flag (writing 1 sets switch flag to 0)
  0      1      0      STEP         Step the drive head one track (setting to 0 performs a step, returns to 1 when step is complete)
  1      0      0      MOTORON      Turn on/off drive motor (0=on, 1=off)
  1      1      0      EJECT        Eject the disk (writing 1 ejects the disk)
	
*/

`define DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
`define DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
	                           /* W: ?? reset disk switch flag ? */
`define DRIVE_REG_STEP		2  /* R: drive head is stepping (1 = complete) */
	                           /* W: 0 = step drive head */
`define DRIVE_REG_WRTPRT	3  /* R: 0 = disk is write-protected */
`define DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
`define DRIVE_REG_TK0		5  /* R: 0 = head at track 0 */
`define DRIVE_REG_EJECT		6  /* R: disk switched (1=yes?)*/
	                           /* W: 1 = eject the disk */
`define DRIVE_REG_TACH		7  /* R: tach-o-meter */
`define DRIVE_REG_RDDATA0	8  /* R: activate lower head: side 0 */
`define DRIVE_REG_RDDATA1	9  /* R: activate upper head: side 1 */
`define DRIVE_REG_SUPERDR	10 /* R: drive is a superdrive (0=no, 1=yes) */
`define DRIVE_REG_SIDES		12 /* R: number of sides (0=single, 1=dbl) */
`define DRIVE_REG_READY		13 /* R: drive ready (head loaded) (0=ready) */
`define DRIVE_REG_INSTALLED	14 /* R: drive present (0 = yes ??) */
`define DRIVE_REG_DRVIN		15 /* R: 400K/800k: drive present (0=yes, 1=no), Superdrive: disk capacity (0=HD, 1=DD) */

module floppy
(
	input clk,
	input cep,
	input cen,

	input _reset,
	input ca0,				// PH0
	input ca1,				// PH1
	input ca2,				// PH2
	input SEL, 				// HDSEL from VIA
	input lstrb,			// aka PH3
	input _enable, 			
	input [7:0] writeData,		
	output [7:0] readData,
	
	input advanceDriveHead,  // prevents overrun when debugging, does not exist on a real Mac!
	output reg newByteReady,
	input insertDisk,
	input diskSides,
	output diskEject,

	output motor,
	output act,

	output [21:0] dskReadAddr,
	input dskReadAck,
	input [7:0] dskReadData,

	// MFM (ISM/SWIM) read path — 720K/1.44MB
	input        mfm_disk,   // this disk is MFM (use the MFM generator for fetch+bytes)
	input        mfm_hd,     // 1.44MB HD (18 spt) vs 720K DD (9 spt)
	input        mfm_pull,   // SWIM ISM read: advance one decoded byte
	output [7:0] mfm_byte,   // current decoded MFM byte
	output       mfm_mark,   // current byte is an address-mark (A1)
	output       mfm_crc0    // current byte completes a valid CRC field
);

	assign motor = ~driveRegs[`DRIVE_REG_MOTORON];
	assign act = lstrbEdge;

	reg [15:0] driveRegs;
	reg [6:0] driveTrack;
	reg driveSide;
	reg [7:0] diskDataIn; // incoming byte from the floppy disk
	
	// read drive registers
	// Drive-ID sense bits. Our register index = {ca2,ca1,ca0,SEL}; physically the
	// same wires as MAME's m_reg = {ss,ca2,ca1,ca0} (floppy.cpp mac_floppy::wpt_r).
	// THE OS IDENTIFIES THE DRIVE by reading sense regs 0xC,0xD,0xE,0xF and matching
	// a 4-bit pattern (wpt_r comment "Initial state of bits f-c = 2M,ready,MFM,rd1"):
	//   0000=400K GCR, 1010=800K GCR, x011=SuperDrive (x=HD hole of inserted disk).
	// => SuperDrive+HD = 1011, SuperDrive+DD = 0011. So we must report:
	//   reg 0xF (our [15] DRVIN)     = is_2m  = mfm_hd   (1 = 1.44MB HD disk)
	//   reg 0xE (our [13] READY)     = 0      (0 = ready, Apple active-low)
	//   reg 0xD (our [11] MFMModeOn) = 1      (m_mfm dflt = has_mfm on a SuperDrive)
	//   reg 0xC (our [9]  RDDATA1)   = 1      (motor-off RdData reads 1)
	//   reg 0x5 (our [10] SUPERDR)   = 1      (the drive IS a SuperDrive)
	// Previously [9]=0 and [11]=mfm_disk, giving signature 0000(800K)/1010(1.44M) =
	// "GCR drive" -> the OS never saw a SuperDrive, never tried MFM. FIXED below.
	// See docs/findings_mame_floppy_driveid_2026-06-13.md (MAME 0.264 ground truth).
	// HW-VALIDATE: is_2m/DRVIN polarity; whether MFMModeOn must track $9/$D strobes.
	wire [15:0] driveRegsAsRead = {
		// DRVIN ($F): MAME is_2m — 1 = DD disk present, 0 = HD disk or empty.
		// (Was `mfm_hd` = 1-for-HD, INVERTED: the OS then routed 800K DD disks to
		// the MFM path and 1.44M HD disks to GCR, so BOTH failed. F3, MAME 0.264.)
		(~driveRegs[`DRIVE_REG_CSTIN] & ~mfm_hd),
		1'b0, // INSTALLED = yes
		1'b0, // READY = yes
		1'b1, // SIDES = double-sided drive
		m_mfm,    // ($B = MAME reg 0xD MFMModeOn): SuperDrive mode flag. Resets to 1
		          // (has_mfm); the $9 (MFMModeOn) strobe sets it, $D (GCRModeOn)
		          // clears it, and the OS reads it back to verify the mode switch
		          // took effect. Was constant 1, which derailed both mount paths.
		          // F4/F5, MAME 0.264.
		1'b1, // SUPERDR = yes (SuperDrive/FDHD)  (MAME reg 0x5)
		1'b1,     // RDDATA1 ($9 here = MAME reg 0xC). = 1: the other '1' in the
		          // SuperDrive identify signature x011 (motor-off RdData1 reads 1).
		1'b0, // RDDATA0
		driveRegs[`DRIVE_REG_TACH], // TACH: 60 pules for each rotation of the drive motor
		1'b0, // disk switched?
		~(driveTrack == 7'h00), // TK0: track 0 indicator
		driveRegs[`DRIVE_REG_MOTORON], // motor on
		1'b0, // WRTPRT = locked
		1'b1, // STEP = complete
		driveRegs[`DRIVE_REG_CSTIN], // disk in drive
		driveRegs[`DRIVE_REG_DIRTN] // step direction
	};

	// MFMModeOn flag (MAME m_mfm), read back as sense reg 0xD. SuperDrive powers up
	// with it SET (has_mfm); the seek-phase strobe $9 (MFMModeOn) sets it and $D
	// (GCRModeOn) clears it. Command = {SEL,ca2,ca1,ca0} latched on the LSTRB edge
	// (SEL = V8 PA5 on the LC; the same edge/phase logic serves ISM-mode Phases-
	// register strobes). The OS reads 0xD after strobing to confirm the mode. F4/F5.
	reg m_mfm;
	wire [3:0] strobeCmd = {SEL, ca2, ca1, ca0};
	always @(posedge clk or negedge _reset) begin
		if (!_reset)
			m_mfm <= 1'b1;
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1) begin
			if (strobeCmd == 4'h9) m_mfm <= 1'b1;   // MFMModeOn
			if (strobeCmd == 4'hD) m_mfm <= 1'b0;   // GCRModeOn
		end
	end

	reg dskReadAckD;
	always @(posedge clk) if(cen) dskReadAckD <= dskReadAck;

	// latch incoming data
	reg [7:0] dskReadDataLatch;
	always @(posedge clk) if(cep && dskReadAckD) dskReadDataLatch <= dskReadData;
		
	wire [7:0] dskReadDataEnc;
	wire [21:0] gcrReadAddr;   // GCR (IWM) encoder fetch addr
	wire [21:0] mfmReadAddr;   // MFM (ISM) encoder fetch addr

	reg old_newByteReady;
	always @(posedge clk) old_newByteReady <= newByteReady;

	// GCR (IWM-mode) track encoder — 400K/800K
	floppy_track_encoder enc
	(

		.clk		( clk ),
		.ready	( ~old_newByteReady & newByteReady ),

		.rst     ( !_reset ),

		.side    ( driveSide ),
		.sides   ( doubleSidedDisk ),
		.track   ( driveTrack ),

		.addr    ( gcrReadAddr ),
		.idata   ( dskReadDataLatch ),
		.odata   ( dskReadDataEnc )
	);

	// MFM (ISM-mode) track encoder — 720K/1.44MB. Advances one decoded byte each
	// time the SWIM pulls (mfm_pull rising edge); shares the same SDRAM fetch latch
	// (dskReadDataLatch) and head position (driveTrack/driveSide) as the GCR path.
	reg mfm_pull_d;
	always @(posedge clk) mfm_pull_d <= mfm_pull;
	wire mfm_adv = mfm_pull & ~mfm_pull_d;

	mfm_track_encoder menc
	(
		.clk   ( clk ),
		.ready ( mfm_adv ),
		.rst   ( !_reset ),
		.side  ( driveSide ),
		.track ( driveTrack ),
		.hd    ( mfm_hd ),
		.addr  ( mfmReadAddr ),
		.idata ( dskReadDataLatch ),
		.odata ( mfm_byte ),
		.omark ( mfm_mark ),
		.ocrc0 ( mfm_crc0 )
	);

	// SDRAM fetch address: the MFM generator for MFM disks, else the GCR encoder.
	assign dskReadAddr = mfm_disk ? mfmReadAddr : gcrReadAddr;
	
	// TODO: auto-detect doubleSidedDisk from image file size
	wire doubleSidedDisk = diskSides;
	
	wire [3:0] driveReadAddr = {ca2,ca1,ca0,SEL};
	
	// a byte is read or written every 128 clocks (2 us per bit * 8 bits = 16 us, @ 8 MHz = 128 clocks)
	// The CPU must poll for data at least this often, or else an overrun will occur.
	reg [6:0] diskDataByteTimer; 
	reg [7:0] diskImageData;	
	reg readyToAdvanceHead;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 0) begin		
			driveSide <= 0;
			diskImageData <= 8'h00;
			diskDataIn <= 8'hFF;
			diskDataByteTimer <= 0;
			readyToAdvanceHead <= 1;
			newByteReady <= 1'b0;
		end 
		else begin			
			if(cep) begin
			// at time 0, latch a new byte and advance the drive head
			if (diskDataByteTimer == 0 && readyToAdvanceHead && diskImageData != 0) begin
				diskDataIn <= diskImageData;
				newByteReady <= 1;
				diskDataByteTimer <= 1;  // make timer run again

				// clear diskImageData after it's used, so we can tell when we get a new one from the disk	
				diskImageData <= 0;

				// for debugging, don't advance the head until the IWM says it's ready
				readyToAdvanceHead <= 1'b1; // TEMP: treat IWM as always ready
			end

			// extraRomReadAck comes every hsync which is every 21us. The iwm data rates
			// is 8MHZ/128 = 16us
			else begin
				// a timer governs when the next disk byte will become available
				diskDataByteTimer <= diskDataByteTimer + 1'b1;

				newByteReady <= 1'b0;

				if (dskReadAck) begin
					// whenever ACK is received, store the data from the current diskImageAddr 
					diskImageData <= dskReadDataEnc;  // xyz
 				end

				if (advanceDriveHead) begin
					readyToAdvanceHead <= 1'b1;
				end
			end

			// switch drive sides if DRIVE_REG_RDDATA0 or DRIVE_REG_RDDATA1 are read
			// TODO: we don't know if this is a true read, since we don't know if IWM is selected or 
			// could be bad if we use this test to flush a cache of encoded disk data
			if (driveReadAddr == `DRIVE_REG_RDDATA0 && lstrb == 1'b0)
				driveSide <= 0;
			if (driveReadAddr == `DRIVE_REG_RDDATA1 && lstrb == 1'b0)
				driveSide <= 1;	
		end
	end
	end

	// create a signal on the falling edge of lstrb
	reg lstrbPrev;
	always @(posedge clk) if(cep) lstrbPrev <= lstrb;

	wire lstrbEdge = lstrb == 1'b0 && lstrbPrev == 1'b1;

	assign readData = _enable ? 8'hFF :
	                  (driveReadAddr == `DRIVE_REG_RDDATA0 || driveReadAddr == `DRIVE_REG_RDDATA1) ? diskDataIn :
							{ driveRegsAsRead[driveReadAddr], 7'h00 };
		
	// write drive registers
	wire [2:0] driveWriteAddr = {ca1,ca0,SEL};
	
	// DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_DIRTN] <= 1'b0;
		end 
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_DIRTN) begin
			driveRegs[`DRIVE_REG_DIRTN] <= ca2;
		end
	end


	// DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
										/* W: ?? reset disk switch flag ? */
	// disk in drive indicators
	reg [23:0] ejectIndicatorTimer;
	assign diskEject = (ejectIndicatorTimer != 0);
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
			ejectIndicatorTimer <= 24'd0;
		end 
		else if(cep) begin
			if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1) begin
				// eject the disk
				driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
				ejectIndicatorTimer <= 24'hFFFFFF;
			end
			else if (insertDisk) begin
				// insert a disk
				driveRegs[`DRIVE_REG_CSTIN] <= 1'b0;
			end
			else begin
				if (ejectIndicatorTimer != 0)
					ejectIndicatorTimer <= ejectIndicatorTimer - 1'b1;
			end
		end
	end									
									
	//`define DRIVE_REG_STEP		2  /* R: drive head stepping (1 = complete) */
												/* W: 0 = step drive head */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin	
			driveTrack <= 0; 
		end 
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0) begin
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b0 && driveTrack != 7'h4F) begin
				driveTrack <= driveTrack + 1'b1;
			end
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b1 && driveTrack != 0) begin
				driveTrack <= driveTrack - 1'b1;
			end
		end
	end
	
	// DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_MOTORON] <= 1'b1;
		end 
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_MOTORON) begin
			driveRegs[`DRIVE_REG_MOTORON] <= ca2;
		end
	end

	// DRIVE_REG_TACH  7  Tachometer (produces 60 pulses for each rotation of the drive motor)
	/* Data from MESS, sonydriv.c:
	   Tracks	RPM   Timing Value
	   00-15:   500   timing value $117B (acceptable range {1135-11E9})
	   16-31:   550   timing value $???? (acceptable range {12C6-138A})
	   32-47:   600   timing value $???? (acceptable range {14A7-157F})
	   48-63:   675   timing value $???? (acceptable range {16F2-17E2})
	   64-79:   750   timing value $???? (acceptable range {19D0-1ADE})
		
		Experimentally determined toggle rates with 8.125 MHz CPU clock:
		TACH Half Period Clocks		Resulting Timing Value
					9996					$117B (4475)
					9122  				$1328 (4904)
					8292  				$1513 (5395)
					7463  				$176A (5994)
					6634					$1A56 (6742)
	*/
	
	reg [13:0] driveTachTimer; 
	reg [13:0] driveTachPeriod;
	
	always @(*) begin
		case (driveTrack[6:4])
			0: // tracks 0-15
				driveTachPeriod <= 9996;
			1: // tracks 16-31
				driveTachPeriod <= 9122;
			2: // tracks 32-47
				driveTachPeriod <= 8292;
			3: // tracks 48-63
				driveTachPeriod <= 7463;
			default: // tracks 64-79
				driveTachPeriod <= 6634;	
		endcase
	end
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_TACH] <= 1'b0;
			driveTachTimer <= 0;
		end 
		else if(cep) begin
			if (driveTachTimer == driveTachPeriod) begin
				driveTachTimer <= 0;
				driveRegs[`DRIVE_REG_TACH] <= ~driveRegs[`DRIVE_REG_TACH];
			end
			else begin
				driveTachTimer <= driveTachTimer + 1'b1;
			end
		end
	end	
endmodule
