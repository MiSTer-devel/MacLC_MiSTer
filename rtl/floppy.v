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

	// MFM (ISM/SWIM) read path — 720K/1.44MB. The disk spins on its own: while
	// an MFM disk is in and the motor runs, a decoded byte falls off the head
	// every 16 us (HD) / 32 us (DD). Each delivery latches the encoder's output
	// and strobes mfm_stb for one cep period (the SWIM samples it on cen).
	input            ism_active, // SWIM is in ISM mode: the phase lines are ISM
	input            ism_action, // ISM Mode b3 (ACTION): the read/write engine runs
	                             // register traffic, not IWM drive commands
	input            ism_sel,    // ISM has THIS drive selected with Mode b7
	                             // (motor on) set — the ISM-mode motor command
	input            mfm_disk,   // this disk is MFM (use the MFM generator for fetch+bytes)
	input            mfm_hd,     // 1.44MB HD (18 spt) vs 720K DD (9 spt)
	output reg [7:0] mfm_byte,   // delivered decoded MFM byte
	output reg       mfm_mark,   // delivered byte is an address-mark (A1)
	output reg       mfm_crc0,   // delivered byte completes a valid CRC field
	output reg       mfm_stb,    // 1-cep-period delivery strobe

	// --- diagnostic ports (PFLP probes; safe to leave dangling when unused) ---
	// Ported from lbmactwo_MiSTer ac44312 (the debug deck that root-caused its
	// 800K "unreadable" bug). Counters wrap; the host reads deltas over a window.
	// dbg_byte_cnt : byte deliveries while the OS is actually reading (phases
	//                parked on RDDATA0/1 with the drive enabled).
	// dbg_miss_cnt : byte slots that expired in that same state with nothing to
	//                deliver (diskImageData empty = SDRAM refill starvation).
	output reg  [15:0] dbg_byte_cnt,
	output reg  [15:0] dbg_miss_cnt,
	output wire [7:0]  dbg_disk_image_data,  // live SDRAM-fed encoder byte
	output wire [6:0]  dbg_drive_track,
	output wire        dbg_drive_side,
	output reg  [15:0] dbg_step_cnt,         // STEP register writes committed
	output wire        dbg_byte_stb,         // 1-clk pulse: byte delivered THIS cycle
	                                         // (diskImageData is handed over AND
	                                         // cleared on this edge — sample it now)
	output wire [7:0]  dbg_raw_byte,         // pre-encoder SDRAM fetch latch (idata)
	output wire [21:0] dbg_gcr_addr          // live GCR encoder fetch address
);
	assign dbg_disk_image_data = diskImageData;
	assign dbg_drive_track     = driveTrack;
	assign dbg_drive_side      = driveSide;
	assign dbg_raw_byte        = dskReadDataLatch;
	assign dbg_gcr_addr        = gcrReadAddr;

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
	//   0000=400K GCR, 1010=800K GCR, x011=SuperDrive (x=is_2m of inserted disk).
	// ★ POLARITY (settled by the MAME 0.264 RUNTIME capture, which watched both
	// disks actually mount — findings_mame_floppy_groundtruth_2026-07-02.md §4;
	// it OVERTURNED the earlier source-reading guess that HD reports 1):
	//   is_2m = 1 -> DD disk -> the OS mounts via GCR/IWM  => SuperDrive+DD = 1011
	//   is_2m = 0 -> HD disk -> the OS mounts via MFM/ISM  => SuperDrive+HD = 0011
	// Do NOT "fix" this back; inverting it sends 800K disks down MFM and 1.44M
	// disks down GCR, and both then fail. HW-confirmed 2026-08-03: with is_2m=0
	// a 1.44M disk takes the ISM path (its dialog differs from the GCR one).
	// So we must report:
	//   reg 0xF (our [15] DRVIN)     = is_2m  = ~mfm_hd  (1 = DD disk, 0 = HD)
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

	// MFM (ISM-mode) track encoder — 720K/1.44MB. Free-runs at the byte-cell
	// rate below; shares the same SDRAM fetch latch (dskReadDataLatch) and head
	// position (driveTrack/driveSide) as the GCR path.
	wire [7:0] mfm_odata;
	wire       mfm_omark, mfm_ocrc0, mfm_needs_data, mfm_index;
	reg        mfm_ready_pulse;

	mfm_track_encoder menc
	(
		.clk    ( clk ),
		.ready  ( mfm_ready_pulse ),
		.rst    ( !_reset ),
		.side   ( driveSide ),
		.track  ( driveTrack ),
		.hd     ( mfm_hd ),
		.addr   ( mfmReadAddr ),
		.idata  ( dskReadDataLatch ),
		.odata  ( mfm_odata ),
		.omark  ( mfm_omark ),
		.ocrc0  ( mfm_ocrc0 ),
		.oneeds ( mfm_needs_data ),
		.oindex ( mfm_index )
	);

	// ---- MFM byte-cell delivery timer -----------------------------------
	// HD MFM = 500 kbit/s = 16 us/byte = 130 cep ticks @8.125 MHz; DD = 260.
	// Payload bytes (oneeds) additionally wait for a post-advance SDRAM fetch:
	// mfm_fresh means idata belongs to the encoder's CURRENT addr. One ack is
	// skipped after each advance so an in-flight pre-advance ack can't hand us
	// the previous byte's data. The internal-drive extra slot acks every ~2 us,
	// so a stall only stretches the odd byte (the driver is poll-driven).
	// The motor runs if EITHER path commanded it. In IWM mode that is the
	// MOTORON drive register (an LSTRB strobe); in ISM mode the driver spins the
	// drive with **Mode register bit 7 = motor on** (swim_ism_read_reference.md
	// §B) and need never touch MOTORON — so keying spinning on MOTORON alone
	// left the byte engine parked for the whole MFM session, the FIFO never
	// filled, Handshake b7 never set, and the driver saw an empty disk.
	wire       mfm_spinning = mfm_disk && (motor || ism_sel) &&
	                          ~driveRegs[`DRIVE_REG_CSTIN];
	wire [8:0] mfm_period   = mfm_hd ? 9'd129 : 9'd259;
	reg  [8:0] mfm_timer;
	reg        mfm_fresh;
	reg        mfm_ack_skip;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			mfm_timer       <= 9'd0;
			mfm_fresh       <= 1'b0;
			mfm_ack_skip    <= 1'b0;
			mfm_ready_pulse <= 1'b0;
			mfm_stb         <= 1'b0;
			mfm_byte        <= 8'h00;
			mfm_mark        <= 1'b0;
			mfm_crc0        <= 1'b0;
		end else begin
			mfm_ready_pulse <= 1'b0;   // 1-clk advance pulse to the encoder
			if (cep) begin
				mfm_stb <= 1'b0;
				// idata freshness: the fetch latch lands on cep && dskReadAckD
				if (dskReadAckD) begin
					if (mfm_ack_skip) mfm_ack_skip <= 1'b0;
					else              mfm_fresh    <= 1'b1;
				end
				if (!mfm_spinning) begin
					mfm_timer <= mfm_period;
				end
				else if (mfm_timer != 0) begin
					mfm_timer <= mfm_timer - 9'd1;
				end
				else if (!mfm_needs_data || mfm_fresh) begin
					// deliver the current byte, then advance the encoder
					mfm_byte        <= mfm_odata;
					mfm_mark        <= mfm_omark;
					mfm_crc0        <= mfm_ocrc0;
					mfm_stb         <= 1'b1;
					mfm_ready_pulse <= 1'b1;
					mfm_fresh       <= 1'b0;
					mfm_ack_skip    <= 1'b1;
					mfm_timer       <= mfm_period;
				end
				// else: payload byte not fetched yet — stall until an ack lands
			end
		end
	end

`ifdef SIMULATION
	// --- MFM/ISM protocol trace (diff against the MAME 0.264 runtime capture,
	// scratch/mame_floppy_0702/decoded_1440k_v3.txt) ---
	reg [13:0] dbgsim_strobe_cnt = 0;
	reg [13:0] dbgsim_dlv_cnt = 0;
	reg        dbgsim_spin_d = 0;
	reg        dbgsim_idx_d = 0;
	// Sense-register reads, run-length compressed on (addr,value): the driver
	// polls one register thousands of times (e.g. NoReady until 0), so only
	// transitions are interesting. Compare with the MAME capture's SENSE TRUTH
	// TABLE. Our index is {ca2,ca1,ca0,SEL}; MAME's is {ss,ca2,ca1,ca0}.
	reg [3:0]  dbgsim_sns_addr = 4'hF;
	reg        dbgsim_sns_val = 1'b1;
	reg [15:0] dbgsim_sns_rpt = 0;
	reg [11:0] dbgsim_sns_cnt = 0;
	wire       dbgsim_sns_now = readData[7];
	always @(posedge clk) begin
		if (cep && _enable == 1'b0) begin
			if (driveReadAddr != dbgsim_sns_addr || dbgsim_sns_now != dbgsim_sns_val) begin
				if (dbgsim_sns_cnt < 12'd800) begin
					dbgsim_sns_cnt <= dbgsim_sns_cnt + 1'd1;
					$display("FLOPPY %m sense[%x]=%b (prev[%x]=%b x%0d) SEL=%b @%0t",
					         driveReadAddr, dbgsim_sns_now, dbgsim_sns_addr,
					         dbgsim_sns_val, dbgsim_sns_rpt, SEL, $time);
				end
				dbgsim_sns_addr <= driveReadAddr;
				dbgsim_sns_val  <= dbgsim_sns_now;
				dbgsim_sns_rpt  <= 16'd1;
			end else if (dbgsim_sns_rpt != 16'hFFFF)
				dbgsim_sns_rpt <= dbgsim_sns_rpt + 1'd1;
		end
	end
	always @(posedge clk) begin
		if (cep && _enable == 1'b0 && lstrbEdge && dbgsim_strobe_cnt < 14'd8000) begin
			dbgsim_strobe_cnt <= dbgsim_strobe_cnt + 1'd1;
			$display("FLOPPY %m strobe(fall) cmd=%x track=%0d mfm=%b motor(reg)=%b @%0t",
			         {SEL, ca2, ca1, ca0}, driveTrack, m_mfm, driveRegs[`DRIVE_REG_MOTORON], $time);
		end
		// MAME latches the command on the LSTRB RISING edge; we act on falling.
		// Log both so a mid-pulse SEL/phase change shows up as a cmd mismatch.
		if (cep && _enable == 1'b0 && lstrb && !lstrbPrev && dbgsim_strobe_cnt < 14'd8000)
			$display("FLOPPY %m strobe(rise) cmd=%x track=%0d @%0t",
			         {SEL, ca2, ca1, ca0}, driveTrack, $time);
		if (cep) begin
			dbgsim_spin_d <= mfm_spinning;
			if (mfm_spinning != dbgsim_spin_d)
				$display("FLOPPY %m mfm_spinning -> %b (motor=%b ism_sel=%b cstin=%b) trk=%0d side=%b @%0t",
				         mfm_spinning, motor, ism_sel, driveRegs[`DRIVE_REG_CSTIN], driveTrack, driveSide, $time);
			dbgsim_idx_d <= mfm_index;
			if (mfm_spinning && mfm_index && !dbgsim_idx_d)
				$display("FLOPPY %m index pulse trk=%0d side=%b @%0t", driveTrack, driveSide, $time);
			if (mfm_stb && dbgsim_dlv_cnt < 14'd8000) begin
				dbgsim_dlv_cnt <= dbgsim_dlv_cnt + 1'd1;
				$display("FLOPPY %m mfm dlv %02x m=%b c0=%b trk=%0d side=%b needs=%b addr=%0d latch=%02x @%0t",
				         mfm_byte, mfm_mark, mfm_crc0, driveTrack, driveSide,
				         mfm_needs_data, mfmReadAddr, dskReadDataLatch, $time);
			end
		end
	end
`endif

	// SDRAM fetch address: the MFM generator for MFM disks, else the GCR encoder.
	assign dskReadAddr = mfm_disk ? mfmReadAddr : gcrReadAddr;

	// MFM index sense. On a SuperDrive with an MFM disk, sense regs 0x4/0xC
	// (RdData0/1) read the index: 1 with motor off / no disk, else !idx (MAME
	// mac_floppy wpt_r). The MAME 0.264 runtime capture shows the Sony driver
	// polling this 7M times during the MFM session (through ISM Handshake bit3
	// with phases parked on RdData) with 0.70% of reads low — the once-per-rev
	// index pulse that bounds its sector searches. The GCR byte-stream register
	// must NOT appear here for MFM disks (its GCR alphabet is MSB-set, which
	// reads as a permanent "no index" 1).
	wire mfm_idx_sense = mfm_spinning ? ~mfm_index : 1'b1;
	
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

			// Head (side) select — the RDDATA0/RDDATA1 sense address.
			// IWM/GCR: latch continuously while the address is parked there
			// (Plus Too lineage; the phase lines are dedicated to the sense
			// address during GCR reads, so any parked value is authoritative).
			// ISM: the SAME lines double as drive-command strobes and SEL
			// doubles as the strobe-bank selector, so transient combinations
			// lie about the head. The Welcome-time re-init raises SEL for the
			// MFMModeOn strobe while the phases still park on F4 (RdData0)
			// from the previous field — {F4,SEL=1} reads as RdData1 and
			// silently flipped the head to side 1; every later read served
			// wrong-side bytes and System 6.0.8's floppy boot looped at
			// "Welcome to Macintosh" retrying forever (HW 2026-08-03; MAME
			// F623 ground truth + tb_ism_reinit fetch trace addr 9368 =
			// side 1 byte 152). In ISM, sample the head only while ACTION is
			// set: the driver parks F4/SEL BEFORE arming and never touches
			// them mid-read, so the armed window is the authoritative one.
			if (ism_active ? ism_action : 1'b1) begin
				if (driveReadAddr == `DRIVE_REG_RDDATA0 && lstrb == 1'b0) begin
`ifdef SIMULATION
					if (driveSide != 1'b0)
						$display("FLOPPY %m driveSide 1->0 (ism=%b act=%b) @%0t", ism_active, ism_action, $time);
`endif
					driveSide <= 0;
				end
				if (driveReadAddr == `DRIVE_REG_RDDATA1 && lstrb == 1'b0) begin
`ifdef SIMULATION
					if (driveSide != 1'b1)
						$display("FLOPPY %m driveSide 0->1 (ism=%b act=%b) @%0t", ism_active, ism_action, $time);
`endif
					driveSide <= 1;
				end
			end
		end
	end
	end

	// --- diagnostic counters (PFLP probes) --------------------------------
	// Count only while the CPU is positioned to consume data (phases parked on
	// RDDATA0/1, drive enabled): dbg_byte_cnt = a byte was delivered on the
	// 128-clock slot boundary; dbg_miss_cnt = the slot boundary passed with
	// diskImageData still empty (the SDRAM extra-slot refill starved) or
	// delivery otherwise blocked. Healthy read: byte_cnt climbs at ~63 kB/s,
	// miss_cnt static. Observation-only — the delivery path is untouched.
	wire dbg_read_sel = (driveReadAddr == `DRIVE_REG_RDDATA0 ||
	                     driveReadAddr == `DRIVE_REG_RDDATA1) && (_enable == 1'b0);
	// Same-cycle delivery strobe for the MacLC.sv byte-capture ring: identical
	// qualification to the dbg_byte_cnt increment below. Must be consumed on
	// THIS clk edge — the delivery block latches diskImageData into diskDataIn
	// and zeroes it on the same edge, so one cycle later the byte is gone.
	assign dbg_byte_stb = cep && diskDataByteTimer == 0 && dbg_read_sel &&
	                      readyToAdvanceHead && (diskImageData != 0);
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			dbg_byte_cnt <= 16'd0;
			dbg_miss_cnt <= 16'd0;
		end
		else if (cep && diskDataByteTimer == 0 && dbg_read_sel) begin
			if (readyToAdvanceHead && diskImageData != 0)
				dbg_byte_cnt <= dbg_byte_cnt + 16'd1;
			else
				dbg_miss_cnt <= dbg_miss_cnt + 16'd1;
		end
	end

	// create a signal on the falling edge of lstrb
	reg lstrbPrev;
	always @(posedge clk) if(cep) lstrbPrev <= lstrb;

	wire lstrbEdge = lstrb == 1'b0 && lstrbPrev == 1'b1;

	assign readData = _enable ? 8'hFF :
	                  (driveReadAddr == `DRIVE_REG_RDDATA0 || driveReadAddr == `DRIVE_REG_RDDATA1) ?
	                      (mfm_disk ? {mfm_idx_sense, 7'h00} : diskDataIn) :
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
			// EJECT is ignored while the SWIM is in ISM mode. The ISM Phases
			// register drives the SAME ca0-2/LSTRB lines as the IWM soft
			// switches, and the register walks the driver/ROM perform there
			// pass through $FF = {LSTRB=1, ca2=1, ca1=1, ca0=1}, which this
			// layer decodes as driveWriteAddr 6 (EJECT) + ca2=1 = "eject the
			// disk". With a drive selected by ISM devsel that silently ejected
			// the just-inserted image on every per-mount ISM probe, so the
			// internal drive could never hold a disk (2026-08-03: the primary
			// drive stopped reacting to mounts entirely; the external drive was
			// unaffected because it is not the drive ISM selects). An ISM read
			// session never needs to eject.
			if (_enable == 1'b0 && !ism_active && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1) begin
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
			driveTrack   <= 0;
			dbg_step_cnt <= 16'd0;
		end
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0) begin
			dbg_step_cnt <= dbg_step_cnt + 16'd1;  // PFLP: seek activity meter
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
	
	reg [14:0] driveTachTimer;
	reg [14:0] driveTachPeriod;

	always @(*) begin
		if (mfm_disk) begin
			// SuperDrive MFM media (720K DD and 1.44MB HD) spin a CONSTANT
			// 300 RPM regardless of track (500 kbit/s CAV — swim_ism_read
			// reference §"MFM mode on"). The zoned table below is GCR-only.
			// Scaled from the experimentally-calibrated track-0 row:
			// 9996 clks @500 RPM -> x(500/300) = 16660 clks @300 RPM.
			// Without this the Welcome-time Sony driver install measured the
			// zoned GCR rate (500 RPM at track 0, 66% out of spec), failed
			// its drive-speed check, and System 6.0.8's floppy boot looped
			// at "Welcome to Macintosh" retrying the install (HW 2026-08-03;
			// MAME F616 tach-poll window is exactly this measurement).
			driveTachPeriod <= 15'd16660;
		end
		else case (driveTrack[6:4])
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
