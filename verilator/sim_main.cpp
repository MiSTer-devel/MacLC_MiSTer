#include <verilated.h>
#include <set>
#include "Vemu.h"
#include "Vemu__Syms.h"

#include "imgui.h"
#include "implot.h"
#ifndef _MSC_VER
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>
#else
#define WIN32
#include <dinput.h>
#endif

#define VERILATOR_MAJOR_VERSION (VERILATOR_VERSION_INTEGER / 1000000)

#if VERILATOR_MAJOR_VERSION >= 5
#define VERTOPINTERN top->rootp
#else
#define VERTOPINTERN top
#endif

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_blkdevice.h"
#include "sim_video.h"
#include "sim_audio.h"
#include "sim_input.h"
#include "sim_clock.h"
#include "sim_serial.h"
#include "m68k_dasm.h"

#include "../imgui/imgui_memory_editor.h"
#include "../imgui/ImGuiFileDialog.h"

#include <iostream>
#include <sstream>
#include <fstream>
#include <iterator>
#include <string>
#include <iomanip>
#include <vector>
#include <algorithm>
using namespace std;

// stb_image_write for PNG screenshots
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

// Simulation control
// ------------------
int initialReset = 48;
bool run_enable = 1;
int batchSize = 150000;
bool single_step = 0;
bool multi_step = 0;
int multi_step_amount = 1024;

// Machine configuration
// ---------------------
// Mac LC only (no longer supports Mac Plus)
// For TG68K: cpu = {status_cpu[1], |status_cpu}
//   cfg_cpuType=0  -> cpu="00" (68000)
//   cfg_cpuType=1  -> cpu="01" (68010)
//   cfg_cpuType=2  -> cpu="11" (68020)
//   cfg_cpuType=3  -> cpu="11" (68020)
// Mac LC needs 68020 mode (cfg_cpuType=2 or 3)
int cfg_cpuType = 2;       // 68020 mode via TG68K
int cfg_memSize = 1;       // 0=1MB, 1=4MB

// Verbose bring-up diagnostics (overlay/FC/march/STM/RAMCFG/bus/CPU-trace
// console spam). Off by default for a quiet console; enable with --verbose/-v.
bool verbose_diag = false;
#define DLOG(...) do { if (verbose_diag) fprintf(stderr, __VA_ARGS__); } while (0)

// CPU trace
// ---------
bool cpu_trace_enable = false;  // Enable after ROM download
bool cpu_trace_disabled = false; // --no-cpu-trace: skip per-instruction trace (long runs)
bool cpu_trace_started = false;  // Wait for ROM load and reset
FILE* cpu_trace_file = nullptr;
const char* cpu_trace_filename = "cpu_trace.log";
int cpu_trace_count = 0;
const int cpu_trace_max = 0;  // 0 = unlimited
int post_download_delay = 0;  // Delay after ROM load before tracing
uint32_t cpu_trace_last_pc = 0xFFFFFFFF;  // For edge detection (new instruction)
int cpu_trace_last_frame = -1;  // Track frame transitions in trace log

// Fetch buffer: sliding window of recent code-space fetches (PC -> word).
// Used to (a) skip extension-word fetches so only opcodes are logged and
// (b) feed the disassembler real extension words for correct operand display.
// TG68 fetches opcode then extension words sequentially, so we buffer up to
// 5 consecutive fetches and emit the oldest when we have enough context.
struct FetchEntry { uint32_t pc; uint16_t word; int frame; uint32_t data_addr; };
const int FETCH_BUF_SIZE = 8;
FetchEntry fetch_buf[FETCH_BUF_SIZE];
int fetch_buf_len = 0;
uint32_t next_opcode_pc = 0xFFFFFFFF;  // Expected PC of next real opcode (after last emit)

// RAM debug
// ---------
bool ram_debug_enable = false;  // Disable for speed
FILE* ram_debug_file = nullptr;
const char* ram_debug_filename = "ram_debug.log";
int ram_debug_count = 0;
const int ram_debug_max = 10000000;  // Stop after this many RAM accesses

// Peripheral debug
// ----------------
bool periph_debug_enable = false;  // Enable for peripheral access logging
FILE* periph_debug_file = nullptr;
const char* periph_debug_filename = "periph_debug.log";
int periph_debug_count = 0;
const int periph_debug_max = 5000000;  // Stop after this many peripheral accesses
bool periph_debug_prev_bus_control = false;  // For edge detection

// Screenshot functionality
// ------------------------
std::vector<int> screenshot_frames;
bool screenshot_mode = false;

// Stop at frame functionality
// ---------------------------
int stop_at_frame = -1;
bool stop_at_frame_enabled = false;

// Warm-reset test: pulse the top-level reset at a given frame WITHOUT reloading
// the ROM (it persists in the SDRAM model) — a faithful proxy for the FPGA's R0
// soft reset / OS restart, to test whether the machine warm-boots.
// -------------------------------------------------------------------
int  reset_at_frame = -1;
long long warm_reset_start = -1;   // main_time when the pulse began (<0 = not yet)
const long long WARM_RESET_LEN = 4000;  // hold reset asserted this many ticks

// Level-7 NMI test (--nmi-at-frame N): pulse the programmer's-switch NMI at frame
// N to verify the CPU+glue take the level-7 autovector (the MacsBug break path).
int  nmi_at_frame = -1;
long long nmi_start = -1;

// Headless mode (no GUI)
// ----------------------
bool headless = false;

// Debug GUI
// ---------
const char* windowTitle = "Verilator Sim: Macintosh LC";
const char* windowTitle_Control = "Simulation control";
const char* windowTitle_DebugLog = "Debug log";
const char* windowTitle_Video = "VGA output";
const char* windowTitle_Audio = "Audio output";
bool showDebugLog = true;
DebugConsole console;
MemoryEditor mem_edit;
SimSerialTerminal serialTerminal;

// HPS emulator
// ------------
SimBus bus(console);
SimBlockDevice blockdevice(console);

// Disk images (mirrors lbmactwo): SCSI -> block device (MountDisk),
// floppy -> ioctl download into SDRAM (QueueDownload). Set via --scsi0/1
// and --floppy0/1 on the command line.
std::string scsi_disk_files[2];
std::string cdrom_file;        // --cdrom <iso> -> block-device slot 2 (SCSI ID 3 CD)
std::string floppy_disk_files[2];

// Input handling
// --------------
SimInput input(13, console);
const int input_right = 0;
const int input_left = 1;
const int input_down = 2;
const int input_up = 3;
const int input_a = 4;
const int input_b = 5;
const int input_x = 6;
const int input_y = 7;
const int input_l = 8;
const int input_r = 9;
const int input_select = 10;
const int input_start = 11;
const int input_menu = 12;

// Video
// -----
// Mac LC VGA mode (monitor_id=6) is 640x480
#define VGA_WIDTH 640
#define VGA_HEIGHT 480
#define VGA_ROTATE 0
#define VGA_SCALE_X vga_scale
#define VGA_SCALE_Y vga_scale
SimVideo video(VGA_WIDTH, VGA_HEIGHT, VGA_ROTATE);
// Default 1:1 so the full 640x480 frame fits the video window on a typical
// display (at 1.5x the 960x720 image + panels overran many screens, clipping
// the bottom/right edges). Use the Zoom slider to scale up.
float vga_scale = 1.0;

// Verilog module
// --------------
Vemu* top = NULL;

vluint64_t main_time = 0;	// Current simulation time.
double sc_time_stamp() {	// Called by $time in Verilog.
	return main_time;
}

// 32 MHz system clock for Mac LC
int clk_sys_freq = 32000000;
SimClock clk_sys(1);

// Audio
// -----
#ifndef DISABLE_AUDIO
SimAudio audio(clk_sys_freq, false);
#endif

// Reset simulation variables and clocks
void resetSim() {
	main_time = 0;
	VERTOPINTERN->reset = 1;
	clk_sys.Reset();
}

int verilate() {

	if (!Verilated::gotFinish()) {

		// Assert reset during startup
		if (main_time < initialReset) { VERTOPINTERN->reset = 1; }
		// Deassert reset after startup
		if (main_time == initialReset) { VERTOPINTERN->reset = 0; }

		// Warm-reset test (--reset-at-frame N): once we reach frame N, hold the
		// top-level reset asserted for WARM_RESET_LEN ticks, then release. The ROM
		// already lives in the SDRAM model and is NOT reloaded, so this mirrors an
		// FPGA R0 / OS restart (warm boot against existing SDRAM).
		if (reset_at_frame >= 0) {
			if (warm_reset_start < 0 && (int)video.count_frame >= reset_at_frame) {
				warm_reset_start = main_time;
				printf("[F%d] WARM RESET: asserting reset (ROM kept in SDRAM)\n", (int)video.count_frame);
			}
			if (warm_reset_start >= 0 && main_time < warm_reset_start + WARM_RESET_LEN) {
				VERTOPINTERN->reset = 1;
			} else if (warm_reset_start >= 0 && main_time == warm_reset_start + WARM_RESET_LEN) {
				VERTOPINTERN->reset = 0;
				printf("[F%d] WARM RESET: released reset\n", (int)video.count_frame);
			}
		}

		// Level-7 NMI test (--nmi-at-frame N): pulse nmi_pulse at frame N. sim.v
		// edge-detects it and forces IPL=7; expect "NMI: cleared (level-7 IACK TAKEN)".
		if (nmi_at_frame >= 0) {
			if (nmi_start < 0 && (int)video.count_frame >= nmi_at_frame) {
				nmi_start = main_time;
				printf("[F%d] NMI TEST: pulsing Level-7 NMI\n", (int)video.count_frame);
			}
			VERTOPINTERN->nmi_pulse =
				(nmi_start >= 0 && main_time < nmi_start + WARM_RESET_LEN) ? 1 : 0;
		}

		// Clock dividers
		clk_sys.Tick();

		// Set system clock in core
		VERTOPINTERN->clk_sys = clk_sys.clk;

		// Set machine configuration (Mac LC only)
		VERTOPINTERN->cfg_cpuType = cfg_cpuType;
		VERTOPINTERN->cfg_memSize = cfg_memSize;

		// Simulate both edges of system clock
		if (clk_sys.clk != clk_sys.old) {
			if (clk_sys.IsRising() && *bus.ioctl_download != 1) {
				blockdevice.BeforeEval(main_time);
			}
			if (clk_sys.clk) {
				input.BeforeEval();
				bus.BeforeEval();
			}
			top->eval();
			if (clk_sys.clk) { bus.AfterEval(); blockdevice.AfterEval(); }

			// ROM overlay transition logger (one-shot edges)
			if (clk_sys.clk) {
				static int prev_ov = -1;
				int ov = (int)VERTOPINTERN->emu__DOT__ac0__DOT__rom_overlay;
				if (ov != prev_ov) {
					DLOG( "[OVERLAY] rom_overlay %d->%d at F%d cyc=%llu\n",
						prev_ov, ov, video.count_frame, (unsigned long long)main_time);
					prev_ov = ov;
				}
				static int prev_pend = -1, prev_rst = -1;
				int pend = (int)VERTOPINTERN->emu__DOT__ac0__DOT__overlay_disable_pending;
				int rst = (int)VERTOPINTERN->emu__DOT___cpuReset;
				if (pend != prev_pend) { DLOG( "[OVERLAY] pending %d->%d F%d cyc=%llu\n", prev_pend, pend, video.count_frame, (unsigned long long)main_time); prev_pend = pend; }
				if (rst != prev_rst) { DLOG( "[OVERLAY] _cpuReset %d->%d F%d cyc=%llu\n", prev_rst, rst, video.count_frame, (unsigned long long)main_time); prev_rst = rst; }
				// FC during $A0xxxx accesses (overlay-clear gate is cpuFC[1])
				static int fc_logs = 0;
				uint32_t ca = top->debug_cpuAddr;
				if ((ca & 0xF00000) == 0xA00000 && fc_logs < 24) {
					unsigned fc = VERTOPINTERN->emu__DOT__cpuFC;
					static uint32_t last_ca = 0xFFFFFFFF; static unsigned last_fc = 0xFF;
					if (ca != last_ca || fc != last_fc) {
						DLOG( "[FC] $A-access addr=%06X FC=%u (fc1=%u) F%d\n",
							ca & 0xFFFFFF, fc, (fc>>1)&1, video.count_frame);
						fc_logs++; last_ca = ca; last_fc = fc;
					}
				}
			}

			// March progress counters — independent of cpu_trace gating.
			// $A46910 = one full inner-march region pass completed (cmpi.w #21,d7)
			// $A4694C = march fully done; $A4A590 = bank-scan driver reached.
			if (VERTOPINTERN->debug_fetch_valid && !*bus.ioctl_download) {
				static uint32_t march_last_pc = 0xFFFFFFFF;
				static int hit_910 = 0, hit_694c = 0, hit_a590 = 0;
				uint32_t mpc = VERTOPINTERN->debug_pc & 0xFFFFFF;
				if (mpc != march_last_pc) {
					{   // STM-entry detector: first jump INTO the serial-monitor
						// region ($A49800-$A49FFF) from outside, with source PC.
						static int stm_logs = 0;
						bool in_stm   = (mpc >= 0xA49800 && mpc <= 0xA499FF);
						bool prev_stm = (march_last_pc >= 0xA49800 && march_last_pc <= 0xA499FF);
						if (in_stm && !prev_stm && stm_logs < 12) {
							DLOG( "[STM_ENTRY] -> %06X from %06X F%d\n", mpc, march_last_pc, video.count_frame);
							stm_logs++;
						}
					}
					{   // fatal-error / diagnostic handler entry ($A48CD0/$A48CDA sets
						// SP=$2600 + magic $87654321). Capture which error-check branch
						// fired (march_last_pc) and the registers, to find the failed test.
						static int en=0;
						if ((mpc==0xA48CD0 || mpc==0xA48CDA || mpc==0xA4638C || mpc==0xA46200) && en<12) {
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							DLOG( "[ERR] ->%06X from %06X F%d D0=%08X D1=%08X D2=%08X D6=%08X D7=%08X\n",
								mpc, march_last_pc, video.count_frame,
								(unsigned)rf[0],(unsigned)rf[1],(unsigned)rf[2],(unsigned)rf[6],(unsigned)rf[7]); DLOG("      D4(testmask)=%08X D3=%08X A0=%08X A1=%08X\n",(unsigned)rf[4],(unsigned)rf[3],(unsigned)rf[8],(unsigned)rf[9]); en++;
						}
					}
					{   // MOVES-BERR fix verification: machine-config word D2 (and D5
						// jump index) at the dispatch $A00AB0. MAME: D2=$CC000D07.
						static int n=0;
						if (mpc==0xA00AB0 && n<8) {
							auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
							DLOG( "[D2PROBE] $A00AB0 #%d F%d D2=%08X D5=%08X\n",
								n, video.count_frame, (unsigned)rf[2], (unsigned)rf[5]); n++;
						}
					}
					{   // boot state-machine: log entry into each of MAME's 11 handlers
						// (+ the STM-subsystem $A48Cxx) to find where our sequence diverges.
						static const uint32_t H[] = {0xA48468,0xA483FC,0xA47C30,0xA47942,
							0xA477D2,0xA473F4,0xA4730C,0xA4713E,0xA4703E,0xA46F5A,0xA46EC8};
						static uint32_t last_h=0; static int st=0;
						bool ish=false; for (unsigned i=0;i<11;i++) if (mpc==H[i]) ish=true;
						
						if (ish && mpc!=last_h && st<300) {
							DLOG( "[STATE] handler %06X F%d\n", mpc, video.count_frame); st++; last_h=mpc;
						}
					}
					march_last_pc = mpc;
					if (mpc == 0xA46910) { hit_910++;
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[MARCH] PASS#%d F%d D0=%08X D1=%08X D2=%08X D4=%08X D6=%08X D7=%08X A0=%08X A1=%08X A2=%08X A3=%08X A4=%08X A5=%08X\n",
							hit_910, video.count_frame,
							(unsigned)rf[0],(unsigned)rf[1],(unsigned)rf[2],(unsigned)rf[4],
							(unsigned)rf[6],(unsigned)rf[7],(unsigned)rf[8],(unsigned)rf[9],
							(unsigned)rf[10],(unsigned)rf[11],(unsigned)rf[12],(unsigned)rf[13]); }
					else if (mpc == 0xA4694C) { hit_694c++;
						DLOG( "[MARCH] *** DONE $A4694C hit#%d cyc=%llu F%d ***\n",
							hit_694c, (unsigned long long)main_time, video.count_frame); }
					else if (mpc == 0xA4A590) { hit_a590++;
						if (hit_a590 <= 3) DLOG( "[MARCH] bank-scan $A4A590 hit#%d cyc=%llu F%d\n",
							hit_a590, (unsigned long long)main_time, video.count_frame); }
					else if (mpc == 0xA467FE) { static int n=0; if(++n<=8) DLOG( "[PROBE] PASS $A467FE (bank present) #%d F%d\n", n, video.count_frame); }
					else if (mpc == 0xA467F6) { static int n=0; if(++n<=8) DLOG( "[PROBE] FAIL $A467F6 (bank absent) #%d F%d\n", n, video.count_frame); }
					else if (mpc == 0xA46584) { static int n=0; if(++n<=12) { // cmpaw #-1,a0 : A0=region start loaded, A5=table base
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A46584 #%d F%d D7=%08X A0(start)=%08X A4=%08X A5(tbl)=%08X SP=%08X\n",
							n, video.count_frame, (unsigned)rf[7], (unsigned)rf[8], (unsigned)rf[12], (unsigned)rf[13], (unsigned)rf[15]); } }
					else if (mpc == 0xA4658A) { static int n=0; if(++n<=12) { // movel a4@+,d0 : D0=region length
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A4658A #%d F%d D0(len)=%08X A0=%08X A4=%08X\n",
							n, video.count_frame, (unsigned)rf[0], (unsigned)rf[8], (unsigned)rf[12]); } }
					else if (mpc == 0xA4657E) { static int n=0; if(++n<=8) { // moveal sp@,a4 : about to read table ptr from SP
						auto &rf = VERTOPINTERN->emu__DOT__tg68k__DOT__tg68k__DOT__regfile;
						DLOG( "[TBL] $A4657E #%d F%d (D7=3 RAM-region entry) SP=%08X overlay=%d\n",
							n, video.count_frame, (unsigned)rf[15],
							(int)VERTOPINTERN->emu__DOT__ac0__DOT__rom_overlay);
						// READ-ONLY dump of built descriptor table memory before the march
						// writes it. CPU $9FFFE0..$9FFFFF -> SDRAM words $0FFFF0..$0FFFFF
						// (motherboard_high: word = {3'b000, cpuAddr[20:1]}). 68k longwords
						// are big-endian word pairs in the 16-bit mem[] array.
						auto &M = VERTOPINTERN->emu__DOT__ram__DOT__mem;
						DLOG( "[TBLMEM] #%d F%d CPU$9FFFE0:", n, video.count_frame);
						for (uint32_t w = 0xFFFF0; w <= 0xFFFFE; w += 2)
							DLOG( " %08X", ((unsigned)M[w] << 16) | (unsigned)M[w+1]);
						DLOG( "\n"); } }
				}
			}

			// --- Candidate-B gating verification: track pseudovia V8 RAM-config
			// register (ram_cfg) changes vs the F45 enumeration / table build.
			// Logs reset-init + every ROM write, with frame, PC and bits[7:6].
			{
				static int prev_ramcfg = -1;
				int rc = (int)VERTOPINTERN->emu__DOT__pvia__DOT__ram_cfg;
				if (rc != prev_ramcfg) {
					DLOG( "[RAMCFG] %02X->%02X F%d pc=%06X bits76=%d%d\n",
						prev_ramcfg & 0xFF, rc & 0xFF, video.count_frame,
						VERTOPINTERN->debug_pc & 0xFFFFFF, (rc>>7)&1, (rc>>6)&1);
					prev_ramcfg = rc;
				}
				// Decisive: did the ram_configured latch ever trip (ROM wrote
				// config reg $01)? If it stays 0, $0 low-mem globals stay unmapped
				// -> divergence at $A499xx (reads $19A.w/$DE0.w return garbage).
				static int prev_rcfgd = -1;
				int rcfgd = (int)VERTOPINTERN->emu__DOT__pvia_ram_configured;
				if (rcfgd != prev_rcfgd) {
					DLOG( "[RAMCFGD] ram_configured %d->%d F%d pc=%06X\n",
						prev_rcfgd, rcfgd, video.count_frame,
						VERTOPINTERN->debug_pc & 0xFFFFFF);
					prev_rcfgd = rcfgd;
				}
			}

			// CPU trace output - skip while ROM is downloading
			// TG68 issues a bus fetch for every code-space word (opcode AND extension
			// words). We buffer consecutive sequential fetches and only emit a log
			// entry when we have enough context to disassemble the full instruction,
			// using Musashi's reported length to advance past extension words.
			if (cpu_trace_enable && VERTOPINTERN->debug_fetch_valid && !*bus.ioctl_download) {
				uint32_t pc = VERTOPINTERN->debug_pc;
				uint16_t opcode = VERTOPINTERN->debug_opcode;

				if (pc != cpu_trace_last_pc) {
					cpu_trace_last_pc = pc;
					int cur_frame = video.count_frame;
					uint32_t dataAddr = VERTOPINTERN->debug_data_addr;

					// If this fetch breaks sequential order (branch/exception),
					// flush the buffer by emitting the oldest entry as an opcode
					// with whatever words we have (single-word disasm is correct
					// for most instructions).
					bool sequential = (fetch_buf_len > 0) &&
						(pc == fetch_buf[fetch_buf_len-1].pc + 2);

					if (!sequential && fetch_buf_len > 0) {
						// Emit buffered entries as individual opcode guesses.
						// For a branch, fetch_buf[0] is a real opcode; anything
						// after would be extensions of it. Use length to skip.
						int i = 0;
						while (i < fetch_buf_len) {
							FetchEntry &e = fetch_buf[i];
							unsigned short opwords[5] = {0};
							int avail = fetch_buf_len - i;
							for (int k = 0; k < avail && k < 5; k++)
								opwords[k] = fetch_buf[i+k].word;
							unsigned int len = 2;
							const char* disasm = disassemble_68k_ext_len(e.pc, opwords, avail, &len);
							if (len < 2) len = 2;
							int words = len / 2;
							cpu_trace_count++;
							console.AddLog("[F%d] %08X: %04X  %s  @%06X", e.frame, e.pc, e.word, disasm, e.data_addr);
							if (cpu_trace_file) {
								if (e.frame != cpu_trace_last_frame) {
									fprintf(cpu_trace_file, "--- frame %d ---\n", e.frame);
									cpu_trace_last_frame = e.frame;
								}
								fprintf(cpu_trace_file, "[F%d] %08X: %04X  %s  @%06X\n", e.frame, e.pc, e.word, disasm, e.data_addr);
							}
							i += words;
						}
						fetch_buf_len = 0;
					}

					// Append this fetch to the buffer.
					if (fetch_buf_len < FETCH_BUF_SIZE) {
						fetch_buf[fetch_buf_len++] = { pc, opcode, cur_frame, dataAddr };
					} else {
						// Buffer full — emit oldest then shift.
						// (Shouldn't happen in practice; longest 68020 instruction is 11 words.)
						FetchEntry &e = fetch_buf[0];
						unsigned short opwords[5] = {0};
						for (int k = 0; k < 5; k++) opwords[k] = fetch_buf[k].word;
						unsigned int len = 2;
						const char* disasm = disassemble_68k_ext_len(e.pc, opwords, 5, &len);
						if (len < 2) len = 2;
						int words = len / 2;
						if (words > FETCH_BUF_SIZE) words = FETCH_BUF_SIZE;
						cpu_trace_count++;
						console.AddLog("[F%d] %08X: %04X  %s  @%06X", e.frame, e.pc, e.word, disasm, e.data_addr);
						if (cpu_trace_file) {
							if (e.frame != cpu_trace_last_frame) {
								fprintf(cpu_trace_file, "--- frame %d ---\n", e.frame);
								cpu_trace_last_frame = e.frame;
							}
							fprintf(cpu_trace_file, "[F%d] %08X: %04X  %s  @%06X\n", e.frame, e.pc, e.word, disasm, e.data_addr);
						}
						// Shift out `words` entries
						int keep = fetch_buf_len - words;
						for (int k = 0; k < keep; k++) fetch_buf[k] = fetch_buf[k + words];
						fetch_buf_len = keep;
						fetch_buf[fetch_buf_len++] = { pc, opcode, cur_frame, dataAddr };
					}

					if (cpu_trace_max > 0 && cpu_trace_count >= cpu_trace_max && cpu_trace_file) {
						fprintf(stderr, "CPU trace limit reached (%d instructions)\n", cpu_trace_count);
						fclose(cpu_trace_file);
						cpu_trace_file = nullptr;
					}
				}
			}

			// RAM debug output - skip while ROM is downloading
			if (ram_debug_enable && !*bus.ioctl_download && ram_debug_file) {
				bool we = VERTOPINTERN->debug_ram_we;
				bool oe = VERTOPINTERN->debug_ram_oe;
				bool selectRAM = VERTOPINTERN->debug_selectRAM;
				bool selectROM = VERTOPINTERN->debug_selectROM;
				bool cpu_write = !VERTOPINTERN->debug_cpuRW;  // RW=0 means write
				bool bus_control = VERTOPINTERN->debug_cpuBusControl;

				// Log actual RAM/ROM accesses, or attempted writes during overlay (selectROM but CPU write)
				bool is_access = (we || oe) && (selectRAM || selectROM);
				bool is_failed_write = selectROM && cpu_write && bus_control && !selectRAM;  // Write to overlay ROM area

				if ((is_access || is_failed_write) && ram_debug_count < ram_debug_max) {
					uint32_t addr = VERTOPINTERN->debug_ram_addr;
					uint32_t cpuAddr = VERTOPINTERN->debug_cpuAddr;
					uint16_t din = VERTOPINTERN->debug_ram_din;
					uint16_t dout = VERTOPINTERN->debug_ram_dout;
					uint8_t ds = VERTOPINTERN->debug_ram_ds;

					const char* op = we ? "WR" : (is_failed_write ? "WR-FAIL" : "RD");
					fprintf(ram_debug_file, "%s cpuAddr=%06X ramAddr=%07X din=%04X dout=%04X ds=%d%d selRAM=%d selROM=%d\n",
						op,
						cpuAddr, addr, din, dout,
						(ds >> 1) & 1, ds & 1,
						selectRAM ? 1 : 0,
						selectROM ? 1 : 0);
					ram_debug_count++;
					if (ram_debug_count >= ram_debug_max) {
						fprintf(stderr, "RAM debug limit reached (%d accesses)\n", ram_debug_max);
						fclose(ram_debug_file);
						ram_debug_file = nullptr;
					}
				}
			}

			// Peripheral debug output - log on falling edge of cpuBusControl
			if (periph_debug_enable && !*bus.ioctl_download && periph_debug_file) {
				bool bus_control = VERTOPINTERN->debug_cpuBusControl;
				// Log on rising edge of bus control (start of CPU cycle) when a peripheral is selected
				if (bus_control && !periph_debug_prev_bus_control) {
					bool selectVIA = VERTOPINTERN->debug_selectVIA;
					bool selectAriel = VERTOPINTERN->debug_selectAriel;
					bool selectPseudoVIA = VERTOPINTERN->debug_selectPseudoVIA;
					bool selectSCSI = VERTOPINTERN->debug_selectSCSI;
					bool selectSCC = VERTOPINTERN->debug_selectSCC;
					bool selectIWM = VERTOPINTERN->debug_selectIWM;
					bool selectVRAM = VERTOPINTERN->debug_selectVRAM;

					if ((selectVIA || selectAriel || selectPseudoVIA || selectSCSI || selectSCC || selectIWM || selectVRAM)
					    && periph_debug_count < periph_debug_max) {
						uint32_t addr = VERTOPINTERN->debug_cpuAddr;
						uint16_t data_in = VERTOPINTERN->debug_cpuDataIn;
						uint16_t data_out = VERTOPINTERN->debug_cpuDataOut;
						bool rw = VERTOPINTERN->debug_cpuRW;

						const char* periph_name = selectVIA ? "VIA" :
						                          selectAriel ? "ARIEL" :
						                          selectPseudoVIA ? "PVIA" :
						                          selectSCSI ? "SCSI" :
						                          selectSCC ? "SCC" :
						                          selectIWM ? "IWM" : 
						                          selectVRAM ? "VRAM" : "???";

						fprintf(periph_debug_file, "[%llu] %s %s addr=%06X data_in=%04X data_out=%04X\n",
							(unsigned long long)main_time,
							rw ? "RD" : "WR",
							periph_name,
							addr,
							data_in,
							data_out);
						periph_debug_count++;
						if (periph_debug_count >= periph_debug_max) {
							fprintf(stderr, "Peripheral debug limit reached (%d accesses)\n", periph_debug_max);
							fclose(periph_debug_file);
							periph_debug_file = nullptr;
						}
					}
				}
				periph_debug_prev_bus_control = bus_control;
			}
		}

#ifndef DISABLE_AUDIO
		if (clk_sys.IsRising())
		{
			audio.Clock(VERTOPINTERN->AUDIO_L, VERTOPINTERN->AUDIO_R);
		}
#endif

					// Output pixels on rising edge of pixel clock
				if (clk_sys.IsRising() && VERTOPINTERN->CE_PIXEL) {
					uint32_t colour = 0xFF000000 | VERTOPINTERN->VGA_B << 16 | VERTOPINTERN->VGA_G << 8 | VERTOPINTERN->VGA_R;
					video.Clock(VERTOPINTERN->VGA_HB, VERTOPINTERN->VGA_VB, VERTOPINTERN->VGA_HS, VERTOPINTERN->VGA_VS, colour);
				}
		
				if (clk_sys.IsRising()) {
					// Serial terminal: tick soft UART and drive SCC RX
					{
						bool fpga_txd = VERTOPINTERN->serial_txd;
						bool sim_rxd = serialTerminal.Tick(fpga_txd);
						VERTOPINTERN->serial_rxd = sim_rxd;

						// Auto-detect baud rate from SCC's baud divider register
						static uint32_t last_baud_div = 0;
						uint32_t baud_div = VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__baud_divid_speed_a;
						if (baud_div != last_baud_div) {
							serialTerminal.UpdateConfigDirect(baud_div, 8, 1, false, false);
							last_baud_div = baud_div;
						}
					}

					main_time++;
					// Print progress every 10 million cycles (~300ms of simulated time at 32MHz)
					if ((main_time % 5000000) == 0) {
						DLOG( "Cycle %llu [F%d]: PC=%08X Op=%04X\n",
							(unsigned long long)main_time,
							video.count_frame,
							VERTOPINTERN->debug_pc,
							VERTOPINTERN->debug_opcode);
					}

					// --- Bus-stall measurement during the RAM-test march ---
					// Per clk_sys: classify the CPU bus state. AS asserted (=0) with
					// DTACK not yet acked (=1) => stalled waiting; AS asserted & DTACK
					// acked (=0) => transfer cycle; AS negated => internal/idle.
					{
						static uint64_t bm_total=0, bm_stall=0, bm_xfer=0, bm_idle=0, bm_accesses=0;
						static bool bm_as_prev=true; static int bm_last_report_frame=-1;
						uint32_t mpc = VERTOPINTERN->debug_pc & 0xFFFFFF;
						bool in_march = (mpc >= 0xA46880 && mpc <= 0xA46960);
						if (in_march) {
							bool as = VERTOPINTERN->debug_cpu_as;       // 1=negated,0=asserted
							bool dtack = VERTOPINTERN->debug_cpu_dtack; // 1=not acked,0=acked
							bm_total++;
							if (!as && dtack) bm_stall++;
							else if (!as && !dtack) bm_xfer++;
							else bm_idle++;
							if (bm_as_prev && !as) bm_accesses++; // AS falling edge = new access
							bm_as_prev = as;
							int f = video.count_frame;
							if (f != bm_last_report_frame && (f % 40)==0 && bm_total>0) {
								bm_last_report_frame = f;
								DLOG( "[BUS F%d] total=%llu stall=%llu xfer=%llu idle=%llu accesses=%llu | stall=%.0f%% xfer=%.0f%% idle=%.0f%% -> %.1f clk/access\n",
									f,
									(unsigned long long)bm_total,
									(unsigned long long)bm_stall,
									(unsigned long long)bm_xfer,
									(unsigned long long)bm_idle,
									(unsigned long long)bm_accesses,
									100.0*bm_stall/bm_total,
									100.0*bm_xfer/bm_total,
									100.0*bm_idle/bm_total,
									bm_accesses?(double)bm_total/bm_accesses:0.0);
							}
						}
					}
					// Enable trace after download completes to see initial 68K execution
					static bool last_download = false;
					if (last_download && !*bus.ioctl_download && !cpu_trace_enable && !cpu_trace_disabled) {
						cpu_trace_enable = true;
						DLOG( "*** Enabling CPU trace after ROM download ***\n");
						if (!cpu_trace_file) {
							cpu_trace_file = fopen(cpu_trace_filename, "w");
						}
					}
					last_download = *bus.ioctl_download;
				}
				return 1;
			}
	// Stop verilating and cleanup
	top->final();
	delete top;
	exit(0);
	return 0;
}

void show_help() {
	printf("Mac LC Hardware Simulator\n");
	printf("Usage: ./Vemu [options]\n\n");
	printf("Options:\n");
	printf("  -h, --help                    Show this help message\n");
	printf("  --headless, --no-gui          Run without SDL/ImGui (CI/headless)\n");
	printf("  --screenshot <frames>         Take screenshots at specified frame numbers\n");
	printf("                                (comma-separated list, e.g., 100,200,300)\n");
	printf("  --stop-at-frame <frame>       Exit simulation after specified frame\n");
	printf("  -v, --verbose                 Enable verbose bring-up diagnostics\n");
	printf("                                (overlay/FC/march/RAMCFG/bus/CPU-trace spam)\n");
	printf("  --scsi0 <file>                Mount SCSI-6 hard disk image (.img/.vhd/.hda)\n");
	printf("  --scsi1 <file>                Mount SCSI-5 hard disk image\n");
	printf("  --cdrom <file>                Mount CD-ROM image (.iso/.toast, 2048-byte sectors) on SCSI-3\n");
	printf("\n");
	printf("Examples:\n");
	printf("  ./Vemu                        Run simulator in windowed mode\n");
	printf("  ./Vemu --screenshot 245       Take screenshot at frame 245\n");
	printf("  ./Vemu --stop-at-frame 300    Stop simulation after frame 300\n");
	printf("  ./Vemu --headless --screenshot 50 --stop-at-frame 100\n");
	printf("                                Headless, take screenshot at frame 50, stop at 100\n");
}

void save_screenshot(int frame_number) {
	if (!output_ptr) {
		printf("Error: output_ptr is null, cannot save screenshot\n");
		return;
	}

	char filename[256];
	snprintf(filename, sizeof(filename), "screenshot_frame_%04d.png", frame_number);

	// Read from the video output buffer that video.Clock() writes to
	// The colour format is: 0xFF000000 | B << 16 | G << 8 | R (ABGR)
	// Mac LC screen dimensions come from the video module

	int width = video.output_width;
	int height = video.output_height;

	uint8_t* rgb_data = (uint8_t*)malloc(width * height * 3);
	if (!rgb_data) {
		printf("Error: Could not allocate memory for screenshot\n");
		return;
	}

	for (int y = 0; y < height; y++) {
		for (int x = 0; x < width; x++) {
			uint32_t pixel = output_ptr[y * width + x];
			int dst_index = (y * width + x) * 3;

			// Format: 0xFF000000 | B << 16 | G << 8 | R (ABGR)
			uint8_t b = (pixel >> 16) & 0xFF;
			uint8_t g = (pixel >> 8) & 0xFF;
			uint8_t r = (pixel >> 0) & 0xFF;

			rgb_data[dst_index + 0] = r;
			rgb_data[dst_index + 1] = g;
			rgb_data[dst_index + 2] = b;
		}
	}

	// Save as PNG using stb_image_write
	int result = stbi_write_png(filename, width, height, 3, rgb_data, width * 3);

	free(rgb_data);

	if (result) {
		printf("Screenshot saved: %s (%dx%d)\n", filename, width, height);
	} else {
		printf("Error: Failed to save screenshot %s\n", filename);
	}
}

unsigned char mouse_clock = 0;
unsigned char mouse_buttons = 0;
unsigned char mouse_x = 0;
unsigned char mouse_y = 0;

// Real SDL mouse capture (like lbmactwo_MiSTer): click the VGA image to capture
// the host mouse; move/click to drive the ADB mouse; press Esc or F1 to release.
// Relative motion is accumulated during each frame's SDL event poll, then applied
// to ps2_mouse below.
extern SDL_Window* window;
bool mouse_captured = false;
int  sdl_mouse_dx = 0;
int  sdl_mouse_dy = 0;
int  sdl_mouse_btn = 0;

int main(int argc, char** argv, char** env) {

	// Parse command-line arguments
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			show_help();
			return 0;
		} else if (strcmp(argv[i], "--headless") == 0 || strcmp(argv[i], "--no-gui") == 0) {
			headless = true;
		} else if (strcmp(argv[i], "--screenshot") == 0 && i + 1 < argc) {
			screenshot_mode = true;
			std::string frames_str = argv[i + 1];
			std::stringstream ss(frames_str);
			std::string frame_num;
			while (std::getline(ss, frame_num, ',')) {
				screenshot_frames.push_back(std::stoi(frame_num));
			}
			printf("Screenshot mode enabled for frames: %s\n", frames_str.c_str());
			i++;
		} else if (strcmp(argv[i], "--stop-at-frame") == 0 && i + 1 < argc) {
			stop_at_frame = std::stoi(argv[i + 1]);
			stop_at_frame_enabled = true;
			printf("Will stop at frame %d\n", stop_at_frame);
			i++;
		} else if (strcmp(argv[i], "--reset-at-frame") == 0 && i + 1 < argc) {
			reset_at_frame = std::stoi(argv[i + 1]);
			printf("Will pulse a WARM reset at frame %d (ROM kept in SDRAM)\n", reset_at_frame);
			i++;
		} else if (strcmp(argv[i], "--nmi-at-frame") == 0 && i + 1 < argc) {
			nmi_at_frame = std::stoi(argv[i + 1]);
			printf("Will pulse a Level-7 NMI at frame %d (MacsBug-path test)\n", nmi_at_frame);
			i++;
		} else if (strcmp(argv[i], "--no-cpu-trace") == 0) {
			cpu_trace_disabled = true;
			printf("Per-instruction CPU trace disabled (cpu_trace.log will not be written)\n");
		} else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
			verbose_diag = true;
			printf("Verbose bring-up diagnostics enabled\n");
		} else if (strcmp(argv[i], "--scsi0") == 0 && i + 1 < argc) {
			scsi_disk_files[0] = argv[++i];   // SCSI-6 (.img/.vhd) -> block device
		} else if (strcmp(argv[i], "--scsi1") == 0 && i + 1 < argc) {
			scsi_disk_files[1] = argv[++i];   // SCSI-5
		} else if (strcmp(argv[i], "--cdrom") == 0 && i + 1 < argc) {
			cdrom_file = argv[++i];           // CD-ROM (.iso/.toast, 2048-byte sectors) -> SCSI-3
		} else if (strcmp(argv[i], "--floppy0") == 0 && i + 1 < argc) {
			floppy_disk_files[0] = argv[++i]; // primary floppy (.dsk) -> SDRAM download
		} else if (strcmp(argv[i], "--floppy1") == 0 && i + 1 < argc) {
			floppy_disk_files[1] = argv[++i]; // secondary floppy
		}
	}

	// Create core and initialise
	top = new Vemu();
	Verilated::commandArgs(argc, argv);
	Verilated::traceEverOn(true);

	// Attach bus - using 16-bit ioctl_dout for MacLC
	bus.ioctl_addr = &VERTOPINTERN->ioctl_addr;
	bus.ioctl_index = &VERTOPINTERN->ioctl_index;
	bus.ioctl_wait = &VERTOPINTERN->ioctl_wait;
	bus.ioctl_download = &VERTOPINTERN->ioctl_download;
	bus.ioctl_wr = &VERTOPINTERN->ioctl_wr;
	bus.ioctl_dout = &VERTOPINTERN->ioctl_dout;  // 16-bit for MacLC
	input.ps2_key = &VERTOPINTERN->ps2_key;

	// Hookup block device for SCSI (2 devices for MacLC)
	blockdevice.sd_lba[0] = &VERTOPINTERN->sd_lba[0];
	blockdevice.sd_lba[1] = &VERTOPINTERN->sd_lba[1];
	blockdevice.sd_lba[2] = &VERTOPINTERN->sd_lba[2];
	blockdevice.sd_rd = &VERTOPINTERN->sd_rd;
	blockdevice.sd_wr = &VERTOPINTERN->sd_wr;
	blockdevice.sd_ack = &VERTOPINTERN->sd_ack;
	blockdevice.sd_buff_addr = &VERTOPINTERN->sd_buff_addr;
	blockdevice.sd_buff_dout = &VERTOPINTERN->sd_buff_dout;
	blockdevice.sd_buff_din[0] = &VERTOPINTERN->sd_buff_din[0];
	blockdevice.sd_buff_din[1] = &VERTOPINTERN->sd_buff_din[1];
	blockdevice.sd_buff_din[2] = &VERTOPINTERN->sd_buff_din[2];
	blockdevice.sd_buff_wr = &VERTOPINTERN->sd_buff_wr;
	blockdevice.img_mounted = &VERTOPINTERN->img_mounted;
	blockdevice.img_size = &VERTOPINTERN->img_size;
	for (int disk_index = 0; disk_index < 2; disk_index++) {
		if (!scsi_disk_files[disk_index].empty()) {
			blockdevice.MountDisk(scsi_disk_files[disk_index], disk_index);
			fprintf(stderr, "Mounting SCSI%d image: %s\n", disk_index, scsi_disk_files[disk_index].c_str());
		}
	}
	if (!cdrom_file.empty()) {
		blockdevice.MountDisk(cdrom_file, 2);
		fprintf(stderr, "Mounting CD-ROM image (SCSI-3): %s\n", cdrom_file.c_str());
	}

#ifndef DISABLE_AUDIO
	audio.Initialise();
#endif

	// Set up input module
	input.Initialise();
#ifdef WIN32
	input.SetMapping(input_up, DIK_UP);
	input.SetMapping(input_right, DIK_RIGHT);
	input.SetMapping(input_down, DIK_DOWN);
	input.SetMapping(input_left, DIK_LEFT);
	input.SetMapping(input_a, DIK_Z);
	input.SetMapping(input_b, DIK_X);
	input.SetMapping(input_x, DIK_A);
	input.SetMapping(input_y, DIK_S);
	input.SetMapping(input_l, DIK_Q);
	input.SetMapping(input_r, DIK_W);
	input.SetMapping(input_select, DIK_1);
	input.SetMapping(input_start, DIK_2);
	input.SetMapping(input_menu, DIK_M);
#else
	input.SetMapping(input_up, SDL_SCANCODE_UP);
	input.SetMapping(input_right, SDL_SCANCODE_RIGHT);
	input.SetMapping(input_down, SDL_SCANCODE_DOWN);
	input.SetMapping(input_left, SDL_SCANCODE_LEFT);
	input.SetMapping(input_a, SDL_SCANCODE_A);
	input.SetMapping(input_b, SDL_SCANCODE_B);
	input.SetMapping(input_x, SDL_SCANCODE_X);
	input.SetMapping(input_y, SDL_SCANCODE_Y);
	input.SetMapping(input_l, SDL_SCANCODE_L);
	input.SetMapping(input_r, SDL_SCANCODE_E);
	input.SetMapping(input_start, SDL_SCANCODE_1);
	input.SetMapping(input_select, SDL_SCANCODE_2);
	input.SetMapping(input_menu, SDL_SCANCODE_M);
#endif

	// Setup video output
	if (video.Initialise(windowTitle) == 1) { return 1; }

	// Open CPU trace file
	if (cpu_trace_enable) {
		cpu_trace_file = fopen(cpu_trace_filename, "w");
		if (cpu_trace_file) {
			fprintf(stderr, "CPU trace enabled, writing to %s\n", cpu_trace_filename);
		} else {
			fprintf(stderr, "Failed to open trace file %s\n", cpu_trace_filename);
			cpu_trace_enable = false;
		}
	}

	// Open RAM debug file
	if (ram_debug_enable) {
		ram_debug_file = fopen(ram_debug_filename, "w");
		if (ram_debug_file) {
			fprintf(stderr, "RAM debug enabled, writing to %s\n", ram_debug_filename);
		} else {
			fprintf(stderr, "Failed to open RAM debug file %s\n", ram_debug_filename);
			ram_debug_enable = false;
		}
	}

	// Open peripheral debug file
	if (periph_debug_enable) {
		periph_debug_file = fopen(periph_debug_filename, "w");
		if (periph_debug_file) {
			fprintf(stderr, "Peripheral debug enabled, writing to %s\n", periph_debug_filename);
		} else {
			fprintf(stderr, "Failed to open peripheral debug file %s\n", periph_debug_filename);
			periph_debug_enable = false;
		}
	}

	// Auto-load Mac LC ROM at startup
	const char* rom_file = "../releases/boot0.rom";
	bus.QueueDownload(rom_file, 0, 1);  // index 0 for ROM
	fprintf(stderr, "Machine type: Mac LC, loading ROM: %s\n", rom_file);

	// Floppy images stream into SDRAM via ioctl, same as a HPS mount.
	// MacLC uses ioctl_index 1 (F1/primary) and 2 (F2/secondary) — see
	// MacLC.sv dio_a decode. (lbmactwo uses 2/3 because index 1 is its NuBus ROM.)
	for (int disk_index = 0; disk_index < 2; disk_index++) {
		if (!floppy_disk_files[disk_index].empty()) {
			int ioctl_index = disk_index == 0 ? 1 : 2;
			bus.QueueDownload(floppy_disk_files[disk_index], ioctl_index, 1);
			fprintf(stderr, "Loading floppy%d image (ioctl_index %d): %s\n",
			        disk_index, ioctl_index, floppy_disk_files[disk_index].c_str());
		}
	}

	// Initial eval() to establish clock state for Verilator
	// This is needed for correct rising edge detection on the first cycle
	VERTOPINTERN->clk_sys = 0;
	VERTOPINTERN->reset = 1;
	top->eval();

#ifdef WIN32
	MSG msg;
	ZeroMemory(&msg, sizeof(msg));
	while (msg.message != WM_QUIT)
	{
		if (PeekMessage(&msg, NULL, 0U, 0U, PM_REMOVE))
		{
			TranslateMessage(&msg);
			DispatchMessage(&msg);
			continue;
		}
#else
	bool done = false;
	while (!done)
	{
		sdl_mouse_dx = 0;
		sdl_mouse_dy = 0;
		SDL_Event event;
		while (SDL_PollEvent(&event))
		{
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT)
				done = true;

			// Mouse capture uses SDL relative mode: the OS cursor is hidden and
			// confined, and motion.xrel/yrel give pure relative deltas, so the
			// pointer can never wander off the emulated screen.
			if (event.type == SDL_MOUSEMOTION && mouse_captured) {
				sdl_mouse_dx += event.motion.xrel;
				sdl_mouse_dy += event.motion.yrel;
			}
			if (mouse_captured) {
				if (event.type == SDL_MOUSEBUTTONDOWN && event.button.button == SDL_BUTTON_LEFT)
					sdl_mouse_btn = 1;
				if (event.type == SDL_MOUSEBUTTONUP && event.button.button == SDL_BUTTON_LEFT)
					sdl_mouse_btn = 0;
			}
			// Esc / F1 releases the captured mouse.
			if (event.type == SDL_KEYDOWN && mouse_captured &&
			    (event.key.keysym.sym == SDLK_ESCAPE || event.key.keysym.sym == SDLK_F1)) {
				mouse_captured = false;
				SDL_SetRelativeMouseMode(SDL_FALSE);
			}
		}
#endif
		video.StartFrame();

		input.Read();

		// Draw GUI
		// --------
		ImGui::NewFrame();

		// Simulation control window
		ImGui::Begin(windowTitle_Control);
		ImGui::SetWindowPos(windowTitle_Control, ImVec2(0, 0), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Control, ImVec2(500, 200), ImGuiCond_Once);
		if (ImGui::Button("Reset simulation")) { resetSim(); } ImGui::SameLine();
		if (ImGui::Button("Start running")) { run_enable = 1; } ImGui::SameLine();
		if (ImGui::Button("Stop running")) { run_enable = 0; } ImGui::SameLine();
		ImGui::Checkbox("RUN", &run_enable);
		ImGui::SliderInt("Run batch size", &batchSize, 1, 250000);
		if (single_step == 1) { single_step = 0; }
		if (ImGui::Button("Single Step")) { run_enable = 0; single_step = 1; }
		ImGui::SameLine();
		if (multi_step == 1) { multi_step = 0; }
		if (ImGui::Button("Multi Step")) { run_enable = 0; multi_step = 1; }
		ImGui::SliderInt("Multi step amount", &multi_step_amount, 8, 1024);

		if (ImGui::Button("Load ROM"))
			ImGuiFileDialog::Instance()->OpenDialog("ChooseFileDlgKey", "Choose ROM File", ".rom,.bin", ".");

		// CPU trace controls
		ImGui::Separator();
		ImGui::Checkbox("CPU Trace", &cpu_trace_enable);
		ImGui::SameLine();
		ImGui::Text("PC: %08X  Op: %04X", VERTOPINTERN->debug_pc, VERTOPINTERN->debug_opcode);

		// Machine configuration (display only - requires restart to change)
		ImGui::Separator();
		ImGui::Text("Machine: Mac LC | CPU: TG68K | RAM: %s",
			cfg_memSize ? "4MB" : "1MB");

		ImGui::End();

		// Debug log window
		console.Draw(windowTitle_DebugLog, &showDebugLog, ImVec2(500, 700));
		ImGui::SetWindowPos(windowTitle_DebugLog, ImVec2(0, 210), ImGuiCond_Once);

		// Memory debug - access sim_ram memory
		ImGui::Begin("RAM Editor");
		ImGui::Text("Note: Memory editor requires direct RAM access");
		ImGui::Text("RAM module is sim_ram with 8MB capacity");
		ImGui::End();

		int windowX = 550;
		int windowWidth = (VGA_WIDTH * VGA_SCALE_X) + 24;
		// +120: room for the zoom/rotate/flip controls, the stats line, and the
		// mouse-capture status line below the image, so the full frame is visible.
		int windowHeight = (VGA_HEIGHT * VGA_SCALE_Y) + 120;

		// Video window
		ImGui::Begin(windowTitle_Video);
		ImGui::SetWindowPos(windowTitle_Video, ImVec2(windowX, 0), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Video, ImVec2(windowWidth, windowHeight), ImGuiCond_Once);

		ImGui::SliderFloat("Zoom", &vga_scale, 1, 4); ImGui::SameLine();
		ImGui::SliderInt("Rotate", &video.output_rotate, -1, 1); ImGui::SameLine();
		ImGui::Checkbox("Flip V", &video.output_vflip);
		ImGui::Text("main_time: %ld frame_count: %d sim FPS: %f", main_time, video.count_frame, video.stats_fps);

		// Draw VGA output, and let a click on it capture the host mouse.
		ImVec2 vga_size(video.output_width * VGA_SCALE_X, video.output_height * VGA_SCALE_Y);
		ImVec2 vga_cursor = ImGui::GetCursorPos();
		ImGui::Image(video.texture_id, vga_size);
		ImGui::SetCursorPos(vga_cursor);
		ImGui::InvisibleButton("##vga_capture", vga_size);
		if (ImGui::IsItemClicked(0)) {
			mouse_captured = true;
			SDL_SetRelativeMouseMode(SDL_TRUE);   // hide + confine the host cursor
		}
		ImGui::Text("%s", mouse_captured ? "Mouse captured - press Esc or F1 to release"
		                                  : "Click display to capture mouse");
		ImGui::End();

		// Serial terminal window
		serialTerminal.UpdateSCCStatus(
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr3_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr4_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr5_a,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr9,
			VERTOPINTERN->emu__DOT__dc0__DOT__s__DOT__wr14_a);
		static bool showSerial = true;
		serialTerminal.Draw("Serial Terminal A", &showSerial);

		if (ImGuiFileDialog::Instance()->Display("ChooseFileDlgKey"))
		{
			if (ImGuiFileDialog::Instance()->IsOk())
			{
				std::string filePathName = ImGuiFileDialog::Instance()->GetFilePathName();
				std::string filePath = ImGuiFileDialog::Instance()->GetCurrentPath();
				fprintf(stderr, "Loading ROM: %s\n", filePathName.c_str());
				bus.QueueDownload(filePathName, 0, 1);  // index 0 for ROM
			}
			ImGuiFileDialog::Instance()->Close();
		}

#ifndef DISABLE_AUDIO
		ImGui::Begin(windowTitle_Audio);
		ImGui::SetWindowPos(windowTitle_Audio, ImVec2(windowX, windowHeight), ImGuiCond_Once);
		ImGui::SetWindowSize(windowTitle_Audio, ImVec2(windowWidth, 250), ImGuiCond_Once);

		if (run_enable) {
			audio.CollectDebug((signed short)VERTOPINTERN->AUDIO_L, (signed short)VERTOPINTERN->AUDIO_R);
		}
		int channelWidth = (windowWidth / 2) - 16;
		ImPlot::CreateContext();
		if (ImPlot::BeginPlot("Audio - L", ImVec2(channelWidth, 220), ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
			ImPlot::SetupAxes("T", "A", ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks);
			ImPlot::SetupAxesLimits(0, 1, -1, 1, ImPlotCond_Once);
			ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_l, audio.debug_max_samples, audio.debug_pos);
			ImPlot::EndPlot();
		}
		ImGui::SameLine();
		if (ImPlot::BeginPlot("Audio - R", ImVec2(channelWidth, 220), ImPlotFlags_NoLegend | ImPlotFlags_NoMenus | ImPlotFlags_NoTitle)) {
			ImPlot::SetupAxes("T", "A", ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks, ImPlotAxisFlags_AutoFit | ImPlotAxisFlags_NoLabel | ImPlotAxisFlags_NoTickMarks);
			ImPlot::SetupAxesLimits(0, 1, -1, 1, ImPlotCond_Once);
			ImPlot::PlotStairs("", audio.debug_positions, audio.debug_wave_r, audio.debug_max_samples, audio.debug_pos);
			ImPlot::EndPlot();
		}
		ImPlot::DestroyContext();
		ImGui::End();
#endif

		video.UpdateTexture();

		// Handle screenshots at specified frames
		bool took_screenshot_this_frame = false;
		if (screenshot_mode) {
			auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(), video.count_frame);
			if (it != screenshot_frames.end()) {
				save_screenshot(video.count_frame);
				screenshot_frames.erase(it);
				took_screenshot_this_frame = true;
			}
		}

		// Check if we should stop at this frame
		if (stop_at_frame_enabled && video.count_frame >= stop_at_frame) {
			if (took_screenshot_this_frame) {
				printf("Reached stop frame %d after taking screenshot, exiting...\n", stop_at_frame);
			} else {
				printf("Reached stop frame %d, exiting...\n", stop_at_frame);
			}
			break;
		}

		// Pass inputs to sim - PS2 mouse for Mac.  Build the MiSTer ps2_mouse
		// packet with the X/Y SIGN bits (bit4 = X<0, bit5 = Y<0) — the core reads
		// these as the 9th (sign) bit of the delta, so without them every negative
		// move looks like a large positive one (mouse only goes right/down).
		int dx = 0, dy = 0;
		int btn = 0;
		if (mouse_captured) {
			// Real host mouse: relative motion accumulated this frame.  SDL screen
			// Y is down-positive; the Mac wants up-positive, so negate dy.
			dx =  sdl_mouse_dx;
			dy = -sdl_mouse_dy;
			if (sdl_mouse_btn) btn |= 0x01;
		} else {
			// Fallback: arrow keys / A,B buttons when the mouse isn't captured.
			if (input.inputs[input_left])  dx = -2;
			if (input.inputs[input_right]) dx =  2;
			if (input.inputs[input_up])    dy =  2;
			if (input.inputs[input_down])  dy = -2;
			if (input.inputs[input_a])     btn |= 0x01;
			if (input.inputs[input_b])     btn |= 0x02;
		}
		if (dx >  127) dx =  127; if (dx < -127) dx = -127;
		if (dy >  127) dy =  127; if (dy < -127) dy = -127;

		unsigned char status_byte = (unsigned char)(btn & 0x07) | 0x08;
		if (dx < 0) status_byte |= 0x10;   // X sign  -> ps2_mouse[4]
		if (dy < 0) status_byte |= 0x20;   // Y sign  -> ps2_mouse[5]

		unsigned long mouse_temp = status_byte;
		mouse_temp |= ((unsigned char)dx << 8);
		mouse_temp |= ((unsigned char)dy << 16);
		if (mouse_clock) { mouse_temp |= (1UL << 24); }
		mouse_clock = !mouse_clock;

		VERTOPINTERN->ps2_mouse = mouse_temp;

		// Run simulation
		if (run_enable) {
			for (int step = 0; step < batchSize; step++) { verilate(); }
		}
		else {
			if (single_step) { verilate(); }
			if (multi_step) {
				for (int step = 0; step < multi_step_amount; step++) { verilate(); }
			}
		}
	}

	// Clean up before exit
	// --------------------

#ifndef DISABLE_AUDIO
	audio.CleanUp();
#endif
	video.CleanUp();
	input.CleanUp();

	return 0;
}
