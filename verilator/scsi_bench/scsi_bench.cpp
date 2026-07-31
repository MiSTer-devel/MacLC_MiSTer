// scsi_bench.cpp — LC-family SCSI pseudo-DMA latching harness.
//
// Reproduces the Mac SCSI Manager's blind pseudo-DMA read sequence against
// rtl/ncr5380.sv + rtl/scsi.v with a known ramp preloaded in the "disk"
// (byte at global offset d == d & 0xFF) and checks the stream the host
// reads back for swapped / dropped / duplicated bytes.
//
// The real system paces DACK reads with DTACK = ~dreq (MacLC.sv:637): the
// CPU *starts* the bus cycle unconditionally (i_dma_rd rises immediately,
// which is when ncr5380 pre-latches the longword second word), then stalls
// until dreq. How many clk32 cycles after dreq-rise the CPU samples rdata
// (ds) and how soon after one cycle ends the next begins (gap) depend on
// CPU speed / clock-enable phase — so the harness SWEEPS (ds, gap) and maps
// which alignments corrupt.
//
// Modes: byte (MacPlus-equivalent, expected clean), word (UDS+LDS), long
// (68020 move.l = two word cycles; first pre-latches din_pair_next, second
// is ACK-suppressed replay).
//
// Usage: ./obj_dir/Vscsi_bench_top                 full sweep matrix
//        ... --mode word --ds 0 --gap 2 --detail   single run, per-read log
//        ... --sectors 4 --hps 6000                transfer size / HPS latency
//        ... --id 6                                target SCSI ID (slot 0 = 6 @HEAD)

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <deque>
#include <algorithm>

#include "Vscsi_bench_top.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif

// ---- 5380 register map ----
enum { RREG_CDR=0, RREG_ICR=1, RREG_MR=2, RREG_TCR=3, RREG_CSR=4, RREG_BSR=5, RREG_IDR=6, RREG_RST=7 };
enum { WREG_ODR=0, WREG_ICR=1, WREG_MR=2, WREG_TCR=3, WREG_SER=4, WREG_DMAS=5, WREG_DMATR=6, WREG_IDMAR=7 };
enum { CSR_RST=0x80, CSR_BSY=0x40, CSR_REQ=0x20, CSR_MSG=0x10, CSR_CD=0x08, CSR_IO=0x04, CSR_SEL=0x02 };
enum { ICR_RST=0x80, ICR_ACK=0x10, ICR_BSY=0x08, ICR_SEL=0x04, ICR_ATN=0x02, ICR_DATA=0x01 };
enum { BSR_EODMA=0x80, BSR_DRQ=0x40, BSR_IRQ=0x10, BSR_PMATCH=0x08 };

static Vscsi_bench_top* top;
static uint64_t cyc = 0;
#if VM_TRACE
static VerilatedFstC* tfp = nullptr;
#endif

// Data pattern. NOT a plain (off & 0xff) ramp: that has period 256, so the
// content of every ring block is byte-identical to the block that occupied
// the same ring slot one ring-depth earlier — a stale-slot serve (the
// 2026-07-29 CD boundary bug: bytes served from the slot's PREVIOUS
// occupant) verifies as CLEAN against it. Folding the higher offset bytes
// in makes every 512-multiple displacement change the value, so stale
// serves from any block distance are detectable.
static uint8_t ramp(uint64_t off) {
	return (uint8_t)((off & 0xff) ^ ((off >> 8) & 0xff) ^ ((off >> 16) & 0xff));
}

// ---------------- HPS BlueSCSI Toolbox model ----------------
// Faithful mirror of ../Main_MiSTer/toolbox.cpp, so the desk bench exercises the
// exact wire contract the box runs:
//   request  (tb_wr @LBA0) : CDB at [0..9], SEND payload at [16..]
//   request  (tb_wr @LBA1) : the SEND payload bytes that do not fit under the
//                            CDB (payload[496..511]) — the 2026-07-30 tail block
//   status   (tb_rd @LBA0) : {status, 0xB5, len_hi, len_lo}
//   data     (tb_rd @LBA1+k): DataIn payload, 512 bytes per block
// The upload store uses fseek/fwrite semantics (a write past the end leaves a
// zero-filled hole) so transport byte-slip shows up as it does on the SD card.
static const uint8_t TB_SIG = 0xB5;    // status-block signature (Main: toolbox.cpp)
struct TbFile { std::string name; std::vector<uint8_t> data; };
struct TbHps {
	std::vector<TbFile>  files;
	std::vector<uint8_t> resp;
	uint8_t              status = 0x02;
	int                  get_idx = -1;         // file open for GET
	std::vector<uint8_t> upload;               // SEND destination bytes
	std::string          upload_name;
	bool                 upload_open = false;
	uint8_t              tail[512];            // last LBA-1 request block
	uint64_t             reqs = 0, fills = 0;

	TbHps() { memset(tail, 0, sizeof(tail)); }

	void reset() {
		resp.clear(); status = 0x02; get_idx = -1;
		upload.clear(); upload_name.clear(); upload_open = false;
		memset(tail, 0, sizeof(tail)); reqs = fills = 0;
	}

	// ---- 0xD2 COUNT / 0xD0 LIST ----
	void op_count() { resp.push_back((uint8_t)files.size()); status = 0x00; }
	void op_list() {
		for (size_t i = 0; i < files.size(); i++) {
			uint8_t fe[40] = {};
			fe[0] = (uint8_t)i; fe[1] = 0x01;                 // index, type=file
			for (size_t c = 0; c < files[i].name.size() && c < 32; c++) fe[2+c] = (uint8_t)files[i].name[c];
			uint32_t sz = (uint32_t)files[i].data.size();
			fe[36] = sz >> 24; fe[37] = sz >> 16; fe[38] = sz >> 8; fe[39] = sz;
			resp.insert(resp.end(), fe, fe + 40);
		}
		status = 0x00;
	}
	// ---- 0xD1 GET (host -> Mac), 4096-byte blocks ----
	void op_get(const uint8_t* cdb) {
		const uint32_t BLOCK = 4096;
		uint32_t offset = ((uint32_t)cdb[2]<<24)|((uint32_t)cdb[3]<<16)|((uint32_t)cdb[4]<<8)|cdb[5];
		uint32_t blocks = cdb[6] ? cdb[6] : 1;
		uint32_t want   = blocks * BLOCK;
		if (want > 4096) want = 4096;                          // core tb buffer bound
		if (offset == 0) get_idx = (cdb[1] < files.size()) ? cdb[1] : -1;
		if (get_idx < 0) { status = 0x02; return; }
		const std::vector<uint8_t>& d = files[get_idx].data;
		uint64_t base = (uint64_t)offset * BLOCK;
		uint32_t got  = (base >= d.size()) ? 0 : (uint32_t)std::min<uint64_t>(want, d.size() - base);
		resp.assign(d.begin() + (size_t)base, d.begin() + (size_t)base + got);
		if (!got) get_idx = -1;
		status = 0x00;
	}
	// ---- 0xD3/D4/D5 SEND (Mac -> host) ----
	void op_send_prep(const uint8_t* buf) {
		char name[33]; int n = 0;
		for (int i = 0; i < 32; i++) { uint8_t c = buf[16+i]; if (!c) break; name[n++] = (char)c; }
		name[n] = 0;
		if (!n) { status = 0x02; return; }
		upload_name = name; upload.clear(); upload_open = true; status = 0x00;
	}
	void op_send_data(const uint8_t* buf) {
		if (!upload_open) { status = 0x02; return; }
		uint32_t off   = ((uint32_t)buf[3]<<16)|((uint32_t)buf[4]<<8)|buf[5];        // 512-blocks
		uint32_t bytes = buf[6] ? (uint32_t)buf[6]*512 : (((uint32_t)buf[1]<<8)|buf[2]);
		if (bytes > 512) bytes = 512;
		uint8_t chunk[512];
		uint32_t head = bytes < 496 ? bytes : 496;
		memcpy(chunk, buf + 16, head);
		if (bytes > 496) memcpy(chunk + 496, tail, bytes - 496);   // tail block
		size_t pos = (size_t)off * 512;
		if (upload.size() < pos + bytes) upload.resize(pos + bytes, 0);  // fseek hole = zeros
		memcpy(&upload[pos], chunk, bytes);
		status = 0x00;
	}
	void op_send_end() {
		if (!upload_open) { status = 0x02; return; }
		upload_open = false; status = 0x00;
	}

	void request(uint32_t lba, const uint8_t* buf) {
		reqs++;
		if (lba == 1) { memcpy(tail, buf, 512); return; }   // SEND payload tail block
		if (lba != 0) return;
		resp.clear(); status = 0x02;
		switch (buf[0]) {
		case 0xD2: op_count();         break;
		case 0xD0: op_list();          break;
		case 0xD1: op_get(buf);        break;
		case 0xD3: op_send_prep(buf);  break;
		case 0xD4: op_send_data(buf);  break;
		case 0xD5: op_send_end();      break;
		default:   status = 0x02;      break;
		}
	}
	void fill(uint32_t lba, uint8_t* buf) {
		fills++;
		memset(buf, 0, 512);
		if (lba == 0) {
			uint16_t len = (resp.size() > 0xFFFF) ? 0xFFFF : (uint16_t)resp.size();
			buf[0] = status; buf[1] = TB_SIG; buf[2] = len >> 8; buf[3] = len & 0xFF;
		} else {
			size_t off = (size_t)(lba - 1) * 512;
			if (off < resp.size()) memcpy(buf, resp.data() + off, std::min<size_t>(512, resp.size() - off));
		}
	}
};
static TbHps tbx;

// ---------------- HPS block-device model ----------------
// READ fetch (io_rd): (latency) -> io_ack=1, stream 256 words into the target
// (1 word / 2 cycles, sim byte-packing: disk byte0 in sd_buff_dout[15:8]),
// io_ack=0. WRITE flush (io_wr): (latency) -> io_ack=1, sweep sd_buff_addr and
// capture sd_buff_din_N into the written-image store, io_ack=0.
// scsi.v bumps lba / rd_hps_blk / sd_buff_sel on the io_ack falling edge.
struct Hps {
	enum St { IDLE, WAIT, STREAM, WWAIT, WCAP, FINISH,
	          TBWWAIT, TBWCAP, TBRWAIT, TBRSTREAM, TBFINISH, TBAHOLD } st = IDLE;
	int t = 0, wi = 0, tgt = 0;
	bool was_write = false;
	uint32_t lba = 0;
	int latency = 600;
	uint64_t fetches = 0, flushes = 0;
	std::vector<uint8_t> written;   // captured write-flush image (lba*512 indexed)
	uint8_t tbblk[512] = {};        // in-flight Toolbox request/response block

	// Slow-HPS injection. /media/fat is mounted sync,dirsync, so one SEND chunk
	// is a synchronous card write and the card can stall well past the core's
	// ~262144-cycle (~8 ms) watchdog. Every tb_slow_every'th tb READ is answered
	// after tb_slow_latency cycles instead of `latency`.
	int tb_slow_every = 0, tb_slow_latency = 0;
	uint64_t tb_reads = 0;
	int cur_tb_latency = 600;

	// Ack-fall model. The core's 2026-07-21 comment records that on HW the tb
	// READ ack fall is NOT observed, so the ~8 ms watchdog — not the ack — is
	// what advances the round trip. This bench completes on the ack fall by
	// default, i.e. it exercises a path HW does not use, which is exactly how a
	// core regression that broke every Toolbox command on hardware still passed
	// every mode. tb_ack_hold > the watchdog holds tb_ack high past the
	// force-latch so the WATCHDOG is the completion path and the ack fall lands
	// late and stale, the way HW appears to behave.
	int tb_ack_hold = 0;   // 0 = drop tb_ack promptly (original model)

	void reset() {
		st = IDLE; t = wi = tgt = 0; was_write = false; fetches = flushes = 0; written.clear();
		tb_reads = 0; cur_tb_latency = latency;
	}

	void service() {
		switch (st) {
		case IDLE:
			top->sd_buff_wr = 0;
			top->io_ack = 0;
			top->tb_ack = 0;
			for (int i = 0; i < 2; i++) {
				if ((top->io_rd >> i) & 1) {
					tgt = i;
					lba = (i == 0) ? top->io_lba_0 : top->io_lba_1;
					was_write = false;
					st = WAIT; t = 0;
					break;
				}
				if ((top->io_wr >> i) & 1) {
					tgt = i;
					lba = (i == 0) ? top->io_lba_0 : top->io_lba_1;
					was_write = true;
					st = WWAIT; t = 0;
					break;
				}
			}
			// Toolbox slot (target 0). Disk io and tb round-trips never overlap:
			// the target is mid-command in PHASE_TB while the tb transfer runs.
			if (st == IDLE && top->tb_wr) { lba = top->tb_lba; st = TBWWAIT; t = 0; }
			else if (st == IDLE && top->tb_rd) {
				lba = top->tb_lba;
				tbx.fill(lba, tbblk);
				tb_reads++;
				cur_tb_latency = (tb_slow_every && (tb_reads % tb_slow_every) == 0)
				                 ? tb_slow_latency : latency;
				st = TBRWAIT; t = 0;
			}
			break;
		case WAIT:
			if (++t >= latency) { top->io_ack = 1 << tgt; st = STREAM; wi = 0; t = 0; }
			break;
		case STREAM:
			if ((t & 1) == 0) {
				top->sd_buff_addr = wi;
				uint8_t b0 = ramp((uint64_t)lba*512 + wi*2);
				uint8_t b1 = ramp((uint64_t)lba*512 + wi*2 + 1);
				top->sd_buff_dout = ((uint16_t)b0 << 8) | b1; // sim packing: byte0 HIGH
				top->sd_buff_wr = 1;
			} else {
				top->sd_buff_wr = 0;
				if (++wi == 256) st = FINISH;
			}
			t++;
			break;
		case WWAIT:
			if (++t >= latency) { top->io_ack = 1 << tgt; st = WCAP; wi = 0; t = 0; }
			break;
		case WCAP:
			// address on even sub-cycle, dpram q registered -> capture 2 later
			if ((t % 3) == 0) top->sd_buff_addr = wi;
			else if ((t % 3) == 2) {
				uint16_t w = (tgt == 0) ? top->sd_buff_din_0 : top->sd_buff_din_1;
				size_t off = (size_t)lba*512 + wi*2;
				if (written.size() < off + 2) written.resize(off + 2, 0xEE);
				written[off]   = (uint8_t)(w >> 8);   // sim packing: byte0 HIGH
				written[off+1] = (uint8_t)(w & 0xff);
				if (++wi == 256) st = FINISH;
			}
			t++;
			break;
		case FINISH:
			top->sd_buff_wr = 0;
			top->io_ack = 0;
			if (was_write) flushes++; else fetches++;
			st = IDLE;
			break;

		// ---- Toolbox request: core -> HPS (tb_wr). Same registered-q_a capture
		// cadence as WCAP; the block is handed to the handler once complete.
		case TBWWAIT:
			if (++t >= latency) { top->tb_ack = 1; st = TBWCAP; wi = 0; t = 0; }
			break;
		case TBWCAP:
			if ((t % 3) == 0) top->sd_buff_addr = wi;
			else if ((t % 3) == 2) {
				uint16_t w = top->tb_buff_din;
				tbblk[wi*2]   = (uint8_t)(w >> 8);     // sim packing: even byte HIGH
				tbblk[wi*2+1] = (uint8_t)(w & 0xff);
				if (++wi == 256) { tbx.request(lba, tbblk); st = TBFINISH; }
			}
			t++;
			break;
		// ---- Toolbox response: HPS -> core (tb_rd), block already staged ----
		case TBRWAIT:
			if (++t >= cur_tb_latency) { top->tb_ack = 1; st = TBRSTREAM; wi = 0; t = 0; }
			break;
		case TBRSTREAM:
			if ((t & 1) == 0) {
				top->sd_buff_addr = wi;
				top->sd_buff_dout = ((uint16_t)tbblk[wi*2] << 8) | tbblk[wi*2+1];
				top->sd_buff_wr = 1;
			} else {
				top->sd_buff_wr = 0;
				if (++wi == 256) st = TBFINISH;
			}
			t++;
			break;
		case TBFINISH:
			top->sd_buff_wr = 0;
			if (tb_ack_hold) { st = TBAHOLD; t = 0; break; }   // hold tb_ack high
			top->tb_ack = 0;
			st = IDLE;
			break;
		// tb_ack stays asserted past the core's watchdog, so the force-latch is
		// what completes the round trip and the eventual fall arrives stale.
		case TBAHOLD:
			if (++t >= tb_ack_hold) { top->tb_ack = 0; st = IDLE; }
			break;
		}
	}
};
static Hps hps;

static void tick() {
	top->clk = 1; top->eval();
#if VM_TRACE
	if (tfp) tfp->dump(cyc*10);
#endif
	hps.service();          // reacts to post-edge outputs, drives next-edge inputs
	top->clk = 0; top->eval();
#if VM_TRACE
	if (tfp) tfp->dump(cyc*10+5);
#endif
	cyc++;
}

// ---------------- host bus primitives ----------------
static void bus_release() {
	top->bus_cs = 0; top->ior = 0; top->iow = 0; top->dack = 0;
	top->dma_word = 0; top->dma_longword = 0; top->dma_second_word = 0;
}

static void reg_write(int rs, uint8_t v) {
	top->bus_cs = 1; top->dack = 0; top->iow = 1; top->ior = 0;
	top->bus_rs = rs;
	top->wdata = ((uint16_t)v << 8) | v;  // byte on UDS lane; regs take [7:0], ODR takes [15:8]
	tick(); tick();                        // edge detect + reg_wr pulse consumed
	bus_release();
	tick();
}

static uint8_t reg_read(int rs) {
	top->bus_cs = 1; top->dack = 0; top->ior = 1; top->iow = 0;
	top->bus_rs = rs;
	top->eval();
	uint8_t v = (uint8_t)(top->rdata & 0xff);
	tick();                                // csr_rd edge registered
	bus_release();
	tick();                                // falling edge: deferred-REQ reveal
	return v;
}

// ---------------- per-read record (post-mortem ring) ----------------
struct ReadRec {
	uint64_t cyc_start = 0, cyc_sample = 0;
	int      idx = 0;                 // stream byte offset of first byte
	uint16_t rdata = 0, first_seen = 0;
	uint16_t din_pair = 0, din_pair_next = 0, second_word_data = 0;
	uint16_t data_cnt_start = 0, data_cnt_sample = 0;
	uint8_t  holdoff = 0;
	bool     suppress = false, pending = false;
	bool     word = false, lw = false, second = false;
	bool     unstable = false;
	int      wait_cycles = 0;
};

static void print_rec(const ReadRec& r) {
	printf("  [%s%s%s] idx=%5d cyc=%8llu wait=%5d dcnt %u->%u rdata=%04x%s "
	       "pair=%04x next=%04x 2nd=%04x sup=%d pend=%d hold=%d\n",
	       r.lw ? "LW" : (r.word ? "W " : "B "),
	       r.second ? "2" : " ",
	       r.unstable ? "*" : " ",
	       r.idx, (unsigned long long)r.cyc_start, r.wait_cycles,
	       r.data_cnt_start, r.data_cnt_sample,
	       r.rdata,
	       r.unstable ? "(!)" : "   ",
	       r.din_pair, r.din_pair_next, r.second_word_data,
	       r.suppress, r.pending, r.holdoff);
	if (r.unstable)
		printf("      UNSTABLE while dreq=1: first seen %04x, sampled %04x\n",
		       r.first_seen, r.rdata);
}

static const int DREQ_TIMEOUT = 500000;

// One pseudo-DMA read bus cycle. Asserts the cycle (rising edge = where the
// RTL pre-latches), stalls on dreq like the DTACK gate, samples rdata `ds`
// cycles after dreq first high, holds 1 more cycle, releases, idles `gap`.
static bool dma_read16(bool word, bool lw, bool second, int ds, int gap,
                       uint16_t& out, ReadRec& rec) {
	top->bus_cs = 1; top->dack = 1; top->ior = 1; top->iow = 0;
	top->bus_rs = 0;
	top->dma_word = word; top->dma_longword = lw; top->dma_second_word = second;
	rec.cyc_start = cyc;
	rec.word = word; rec.lw = lw; rec.second = second;
	rec.data_cnt_start = (uint16_t)(top->dbg_wr & 0xffff);
	tick();                                // rising edge registered here
	int waited = 0;
	while (!top->dreq) {
		tick();
		if (++waited >= DREQ_TIMEOUT) { rec.wait_cycles = waited; bus_release(); return false; }
	}
	rec.wait_cycles = waited;
	uint16_t first = top->rdata;
	for (int i = 0; i < ds; i++) tick();
	out = (uint16_t)top->rdata;
	rec.first_seen = first;
	rec.unstable = (ds > 0) && (first != out);
	rec.rdata = out;
	rec.cyc_sample = cyc;
	rec.data_cnt_sample = (uint16_t)(top->dbg_wr & 0xffff);
	rec.din_pair = top->tap_din_pair;
	rec.din_pair_next = top->tap_din_pair_next;
	rec.second_word_data = top->tap_second_word_data;
	rec.holdoff = top->tap_holdoff;
	rec.suppress = top->tap_suppress_ack;
	rec.pending = top->tap_second_pending;
	tick();                                // hold post-sample (S4-ish)
	bus_release();
	for (int i = 0; i < gap; i++) tick();  // falling edge + inter-cycle gap
	return true;
}

// One pseudo-DMA write bus cycle. wdata is held for the whole cycle (like the
// CPU). Rising edge latches width + low byte; completion is DTACK(dreq)-gated;
// the falling edge fires the ACK train that pushes the byte(s) to the target.
static bool dma_write16(bool word, uint16_t wdata, int gap) {
	top->bus_cs = 1; top->dack = 1; top->iow = 1; top->ior = 0;
	top->bus_rs = 0;
	top->dma_word = word; top->dma_longword = 0; top->dma_second_word = 0;
	top->wdata = wdata;
	tick();                                // rising edge registered
	int waited = 0;
	while (!top->dreq) {
		tick();
		if (++waited >= DREQ_TIMEOUT) { bus_release(); return false; }
	}
	tick();                                // hold post-DTACK
	bus_release();
	for (int i = 0; i < gap; i++) tick();  // falling edge + ACK train + gap
	return true;
}

// ---------------- SCSI Manager-style PIO ----------------
// Initiator patience, in CSR polls. The default matches a Mac driver that gives
// up quickly; the slow-HPS test raises it because a legitimately stalled SD
// write holds the target far longer than any normal round trip.
static int csr_patience = 50000;

static bool wait_csr(uint8_t mask, uint8_t val, int max_polls = 0) {
	if (max_polls <= 0) max_polls = csr_patience;
	for (int i = 0; i < max_polls; i++)
		if ((reg_read(RREG_CSR) & mask) == val) return true;
	return false;
}

static bool pio_put(uint8_t b) {
	if (!wait_csr(CSR_REQ, CSR_REQ)) return false;
	reg_write(WREG_ODR, b);
	reg_write(WREG_ICR, ICR_DATA | ICR_ACK);
	if (!wait_csr(CSR_REQ, 0)) return false;
	reg_write(WREG_ICR, ICR_DATA);
	return true;
}

static int pio_get() {
	if (!wait_csr(CSR_REQ, CSR_REQ)) return -1;
	uint8_t v = reg_read(RREG_CDR);
	reg_write(WREG_ICR, ICR_ACK);
	if (!wait_csr(CSR_REQ, 0)) return -1;
	reg_write(WREG_ICR, 0);
	return v;
}

static void reset_dut(int id_slot) {
	bus_release();
	top->img_mounted = 0; top->img_size = 0;
	top->io_ack = 0; top->sd_buff_wr = 0; top->sd_buff_addr = 0; top->sd_buff_dout = 0;
	top->tb_ack = 0; top->tb_mounted = 0;
	hps.reset();
	top->reset = 1;
	for (int i = 0; i < 8; i++) tick();
	top->reset = 0;
	for (int i = 0; i < 4; i++) tick();
	// mount a 64MB image on the chosen slot
	top->img_size = 131072;               // blocks
	top->img_mounted = (1 << id_slot);
	tick();
	top->img_mounted = 0;
	for (int i = 0; i < 4; i++) tick();
}

// ---------------- one full READ(6) run ----------------
// M_MIX: deterministic pseudo-random interleave of byte/word/longword reads
// with per-read (ds, gap) jitter — torture for the width-latch state machine.
// M_LONGSKEW / M_WORDSKEW: the Mac driver consumes a byte/word PREFIX before
// switching to its wide blind-transfer loop, so the wide-access grid is
// SKEWED off the 512-byte block grid and every block boundary is crossed
// mid-access: longskew = word prefix + longword body (din_pair_next capture
// reaches 2 bytes into the next ring block — the 2026-07-29 CD defect),
// wordskew = byte prefix + odd-aligned word body (din_pair itself crosses).
// Both need the host to catch the fetch frontier (hps latency > host pace)
// to expose a serve of not-yet-filled ring bytes.
enum Mode { M_BYTE, M_WORD, M_LONG, M_MIX, M_LONGSKEW, M_WORDSKEW };
static const char* mode_name(Mode m) {
	return m == M_BYTE ? "byte" : m == M_WORD ? "word" : m == M_LONG ? "long" :
	       m == M_MIX ? "mix" : m == M_LONGSKEW ? "longskew" : "wordskew";
}

static uint32_t lcg_state;
static uint32_t lcg() { lcg_state = lcg_state * 1664525u + 1013904223u; return lcg_state >> 16; }

struct RunResult {
	bool selected = false, cmd_sent = false;
	bool dreq_timeout = false;
	int  mismatches = 0;
	int  first_bad = -1;
	int  unstable = 0;
	int  status = -1, message = -1;
	bool completion_ok = false;
	uint64_t cycles_used = 0;
};

// detail_log: print every read record around mismatches (ring of 12)
static RunResult run_read(Mode mode, int sectors, int ds, int gap, int hps_lat,
                          int scsi_id, int id_slot, bool detail_log) {
	RunResult res;
	uint64_t cyc0 = cyc;
	reset_dut(id_slot);
	hps.latency = hps_lat;

	// ---- selection ----
	reg_write(WREG_ODR, (uint8_t)(1 << scsi_id));
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY, 20000)) { bus_release(); return res; }
	res.selected = true;
	reg_write(WREG_ICR, ICR_DATA);        // drop SEL

	// ---- command: READ(6) lba=0, tlen=sectors ----
	uint8_t cdb[6] = { 0x08, 0, 0, 0, (uint8_t)sectors, 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(cdb[i])) { bus_release(); return res; }
	res.cmd_sent = true;

	// ---- data phase setup (blind transfer) ----
	reg_write(WREG_ICR, 0);               // stop driving the data bus
	reg_write(WREG_TCR, 0x01);            // expect DATA IN (I/O=1)
	reg_write(WREG_MR, 0x02);             // DMA mode
	reg_write(WREG_IDMAR, 0);             // start DMA initiator receive

	const int len = sectors * 512;
	std::vector<uint8_t> got;
	got.reserve(len);
	std::deque<ReadRec> ring;
	auto push_rec = [&](const ReadRec& r) {
		ring.push_back(r);
		if (ring.size() > 12) ring.pop_front();
	};

	bool aborted = false;
	if (mode == M_BYTE) {
		for (int d = 0; d < len && !aborted; d++) {
			uint16_t v; ReadRec r; r.idx = d;
			if (!dma_read16(false, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; break; }
			if (r.unstable) res.unstable++;
			push_rec(r);
			got.push_back((uint8_t)(v & 0xff));
		}
	} else if (mode == M_WORD) {
		for (int d = 0; d < len && !aborted; d += 2) {
			uint16_t v; ReadRec r; r.idx = d;
			if (!dma_read16(true, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; break; }
			if (r.unstable) res.unstable++;
			push_rec(r);
			got.push_back((uint8_t)(v >> 8));
			got.push_back((uint8_t)(v & 0xff));
		}
	} else if (mode == M_LONG) {
		for (int d = 0; d < len && !aborted; d += 4) {
			uint16_t v1, v2; ReadRec r1, r2; r1.idx = d; r2.idx = d + 2;
			if (!dma_read16(true, true, false, ds, gap, v1, r1)) { res.dreq_timeout = true; aborted = true; break; }
			if (r1.unstable) res.unstable++;
			push_rec(r1);
			if (!dma_read16(true, true, true, ds, gap, v2, r2)) { res.dreq_timeout = true; aborted = true; break; }
			if (r2.unstable) res.unstable++;
			push_rec(r2);
			got.push_back((uint8_t)(v1 >> 8));
			got.push_back((uint8_t)(v1 & 0xff));
			got.push_back((uint8_t)(v2 >> 8));
			got.push_back((uint8_t)(v2 & 0xff));
		}
	} else if (mode == M_LONGSKEW) {
		// word prefix, longword body, word tail — every 512-boundary is
		// crossed by a longword whose SECOND word (din_pair_next capture at
		// the end of cycle 1) lies in the next block.
		int d = 0;
		{
			uint16_t v; ReadRec r; r.idx = 0;
			if (!dma_read16(true, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; }
			else {
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v >> 8));
				got.push_back((uint8_t)(v & 0xff));
				d = 2;
			}
		}
		while (!aborted && len - d >= 6) {
			uint16_t v1, v2; ReadRec r1, r2; r1.idx = d; r2.idx = d + 2;
			if (!dma_read16(true, true, false, ds, gap, v1, r1)) { res.dreq_timeout = true; aborted = true; break; }
			if (r1.unstable) res.unstable++;
			push_rec(r1);
			if (!dma_read16(true, true, true, ds, gap, v2, r2)) { res.dreq_timeout = true; aborted = true; break; }
			if (r2.unstable) res.unstable++;
			push_rec(r2);
			got.push_back((uint8_t)(v1 >> 8));
			got.push_back((uint8_t)(v1 & 0xff));
			got.push_back((uint8_t)(v2 >> 8));
			got.push_back((uint8_t)(v2 & 0xff));
			d += 4;
		}
		if (!aborted && d < len) {          // final word (d == len-2)
			uint16_t v; ReadRec r; r.idx = d;
			if (!dma_read16(true, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; }
			else {
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v >> 8));
				got.push_back((uint8_t)(v & 0xff));
			}
		}
	} else if (mode == M_WORDSKEW) {
		// byte prefix, odd-aligned word body, byte tail — every 512-boundary
		// is crossed INSIDE din_pair itself (bytes 511|512 in one word).
		int d = 0;
		{
			uint16_t v; ReadRec r; r.idx = 0;
			if (!dma_read16(false, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; }
			else {
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v & 0xff));
				d = 1;
			}
		}
		while (!aborted && len - d >= 3) {
			uint16_t v; ReadRec r; r.idx = d;
			if (!dma_read16(true, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; break; }
			if (r.unstable) res.unstable++;
			push_rec(r);
			got.push_back((uint8_t)(v >> 8));
			got.push_back((uint8_t)(v & 0xff));
			d += 2;
		}
		if (!aborted && d < len) {          // final byte (d == len-1)
			uint16_t v; ReadRec r; r.idx = d;
			if (!dma_read16(false, false, false, ds, gap, v, r)) { res.dreq_timeout = true; aborted = true; }
			else {
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v & 0xff));
			}
		}
	} else { // M_MIX: width + pacing jitter, seeded by the sweep params
		lcg_state = 0xC0FFEE ^ (ds * 7919) ^ (gap * 104729) ^ hps_lat;
		int d = 0;
		while (d < len && !aborted) {
			int remain = len - d;
			int pick = lcg() % 3;             // 0=byte 1=word 2=long
			int jds = lcg() % 4;              // per-read sample delay 0..3
			int jgap = 1 + (lcg() % 8);       // per-read gap 1..8
			if (remain < 4 && pick == 2) pick = 1;
			if (remain < 2) pick = 0;
			if (pick == 0) {
				uint16_t v; ReadRec r; r.idx = d;
				if (!dma_read16(false, false, false, jds, jgap, v, r)) { res.dreq_timeout = true; aborted = true; break; }
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v & 0xff));
				d += 1;
			} else if (pick == 1) {
				uint16_t v; ReadRec r; r.idx = d;
				if (!dma_read16(true, false, false, jds, jgap, v, r)) { res.dreq_timeout = true; aborted = true; break; }
				if (r.unstable) res.unstable++;
				push_rec(r);
				got.push_back((uint8_t)(v >> 8));
				got.push_back((uint8_t)(v & 0xff));
				d += 2;
			} else {
				uint16_t v1, v2; ReadRec r1, r2; r1.idx = d; r2.idx = d + 2;
				int jds2 = lcg() % 4, jgap2 = 1 + (lcg() % 8);
				if (!dma_read16(true, true, false, jds, jgap, v1, r1)) { res.dreq_timeout = true; aborted = true; break; }
				if (r1.unstable) res.unstable++;
				push_rec(r1);
				if (!dma_read16(true, true, true, jds2, jgap2, v2, r2)) { res.dreq_timeout = true; aborted = true; break; }
				if (r2.unstable) res.unstable++;
				push_rec(r2);
				got.push_back((uint8_t)(v1 >> 8));
				got.push_back((uint8_t)(v1 & 0xff));
				got.push_back((uint8_t)(v2 >> 8));
				got.push_back((uint8_t)(v2 & 0xff));
				d += 4;
			}
		}
	}

	// ---- verify stream ----
	int shown = 0;
	for (size_t d = 0; d < got.size(); d++) {
		if (got[d] != ramp(d)) {
			res.mismatches++;
			if (res.first_bad < 0) res.first_bad = (int)d;
			if (detail_log && shown < 16) {
				printf("  MISMATCH off=%5zu expect=%02x got=%02x (ctx exp:", d, ramp(d), got[d]);
				for (int k = -2; k <= 2; k++) {
					long dd = (long)d + k;
					if (dd >= 0 && dd < (long)got.size()) printf(" %02x", ramp(dd)); else printf(" --");
				}
				printf(" | got:");
				for (int k = -2; k <= 2; k++) {
					long dd = (long)d + k;
					if (dd >= 0 && dd < (long)got.size()) printf(" %02x", got[dd]); else printf(" --");
				}
				printf(")\n");
				shown++;
			}
		}
	}
	if (detail_log && (res.mismatches || res.dreq_timeout)) {
		printf("  --- last %zu DMA reads before end/abort ---\n", ring.size());
		for (const auto& r : ring) print_rec(r);
		printf("  dbg_ncr=%08x dbg_ncr2=%08x dbg_wr=%08x dreq=%d\n",
		       top->dbg_ncr, top->dbg_ncr2, top->dbg_wr, (int)top->dreq);
	}

	// ---- completion (driver style): clear DMA, read status + message ----
	if (!aborted) {
		(void)reg_read(RREG_RST);          // clear latched IRQ
		reg_write(WREG_MR, 0);             // DMA mode off
		res.status = pio_get();
		res.message = pio_get();
		res.completion_ok = (res.status == 0x00 && res.message == 0x00);
	}
	res.cycles_used = cyc - cyc0;
	return res;
}

// ---------------- one full WRITE(6) run ----------------
// Host blind-writes the ramp; the HPS model captures the target's 512-byte
// flushes; verify the captured image equals the ramp. Modes: byte, word
// (a "longword" write is just two word cycles on this hardware — no
// second-word latch on the write side).
static RunResult run_write(bool word_mode, int sectors, int gap, int hps_lat,
                           int scsi_id, int id_slot, bool detail_log) {
	RunResult res;
	uint64_t cyc0 = cyc;
	reset_dut(id_slot);
	hps.latency = hps_lat;

	reg_write(WREG_ODR, (uint8_t)(1 << scsi_id));
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY, 20000)) { bus_release(); return res; }
	res.selected = true;
	reg_write(WREG_ICR, ICR_DATA);

	uint8_t cdb[6] = { 0x0a, 0, 0, 0, (uint8_t)sectors, 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(cdb[i])) { bus_release(); return res; }
	res.cmd_sent = true;

	// data phase: target in DATA_IN (initiator->target), I/O=0 C/D=0 MSG=0
	reg_write(WREG_ICR, ICR_DATA);        // keep driving the bus for DMA writes
	reg_write(WREG_TCR, 0x00);
	reg_write(WREG_MR, 0x02);
	reg_write(WREG_DMAS, 0);              // start DMA send

	const int len = sectors * 512;
	bool aborted = false;
	if (word_mode) {
		for (int d = 0; d < len && !aborted; d += 2) {
			uint16_t w = ((uint16_t)ramp(d) << 8) | ramp(d + 1);
			if (!dma_write16(true, w, 3)) { res.dreq_timeout = true; aborted = true; }
		}
	} else {
		for (int d = 0; d < len && !aborted; d++) {
			uint16_t w = ((uint16_t)ramp(d) << 8) | ramp(d);
			if (!dma_write16(false, w, 3)) { res.dreq_timeout = true; aborted = true; }
		}
	}

	if (!aborted) {
		// wait for the final flush to drain, then complete
		for (int i = 0; i < 200000 && (top->io_wr || top->io_ack); i++) tick();
		(void)reg_read(RREG_RST);
		reg_write(WREG_MR, 0);
		reg_write(WREG_ICR, 0);
		res.status = pio_get();
		res.message = pio_get();
		res.completion_ok = (res.status == 0x00 && res.message == 0x00);
	}

	// verify the captured flush image
	int shown = 0;
	for (int d = 0; d < len; d++) {
		uint8_t gotb = (d < (int)hps.written.size()) ? hps.written[d] : 0xEE;
		if (gotb != ramp(d)) {
			res.mismatches++;
			if (res.first_bad < 0) res.first_bad = d;
			if (detail_log && shown < 16) {
				printf("  WMISMATCH off=%5d expect=%02x got=%02x\n", d, ramp(d), gotb);
				shown++;
			}
		}
	}
	if ((int)hps.written.size() < len && detail_log)
		printf("  WSHORT: only %zu of %d bytes flushed\n", hps.written.size(), len);
	res.cycles_used = cyc - cyc0;
	return res;
}

// ---------------- CD volume page test (cdvol) ----------------
// Drives the CD target (ID 3, selectable via cd_enable with no media): sends
// MODE SELECT(6) page 0x0E with distinctive port volumes, reads them back
// with MODE SENSE(6) page 0x0E, and checks the echo byte-for-byte. This is
// the AppleCD Audio Player volume-slider transaction (2026-07-29 feature).
// Everything is PIO — the parameter transfer exercises the byte-beat parse.
static int run_cdvol() {
	reset_dut(0);

	// ---- selection (CD target = SCSI ID 3) ----
	reg_write(WREG_ODR, (uint8_t)(1 << 3));
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY, 20000)) { printf("cdvol: CD target did not select\n"); return 1; }
	reg_write(WREG_ICR, ICR_DATA);

	// ---- MODE SELECT(6): param list = 4B header (bdlen 0) + page 0x0E ----
	static const uint8_t msel[20] = {
		0x00, 0x00, 0x00, 0x00,            // mode parameter header, bdlen=0
		0x0E, 0x0E,                        // page code, page length 14
		0x04, 0x00, 0x00, 0x00, 75, 75,    // IMMED; obsolete 75/75
		0x01, 0x55,                        // port 0: channel L, volume 0x55
		0x02, 0x66,                        // port 1: channel R, volume 0x66
		0x04, 0x11,                        // port 2
		0x08, 0x22                         // port 3
	};
	uint8_t cdb_sel[6] = { 0x15, 0x10, 0, 0, sizeof(msel), 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(cdb_sel[i])) { printf("cdvol: MODE SELECT CDB stalled at %d\n", i); return 1; }
	for (size_t i = 0; i < sizeof(msel); i++)
		if (!pio_put(msel[i])) { printf("cdvol: MODE SELECT data stalled at %zu\n", i); return 1; }
	reg_write(WREG_ICR, 0);                // release the data bus before status
	int st = pio_get(), msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("cdvol: MODE SELECT status %02x msg %02x\n", st, msg); return 1; }

	// ---- re-select, MODE SENSE(6) page 0x0E, verify the echo ----
	reg_write(WREG_ODR, (uint8_t)(1 << 3));
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY, 20000)) { printf("cdvol: reselect failed\n"); return 1; }
	reg_write(WREG_ICR, ICR_DATA);
	uint8_t cdb_sns[6] = { 0x1A, 0x00, 0x0E, 0, 28, 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(cdb_sns[i])) { printf("cdvol: MODE SENSE CDB stalled at %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);                // release the data bus: DataIn follows
	uint8_t got[28];
	for (int i = 0; i < 28; i++) {
		int v = pio_get();
		if (v < 0) { printf("cdvol: MODE SENSE data stalled at %d\n", i); return 1; }
		got[i] = (uint8_t)v;
	}
	st = pio_get(); msg = pio_get();

	static const uint8_t expect_tail[8] = { 0x01, 0x55, 0x02, 0x66, 0x04, 0x11, 0x08, 0x22 };
	int fails = 0;
	if (got[0] != 27)   { printf("cdvol: mode data length %02x != 27\n", got[0]); fails++; }
	if (got[12] != 0x0E || got[13] != 0x0E)
		{ printf("cdvol: page hdr %02x %02x != 0E 0E\n", got[12], got[13]); fails++; }
	for (int i = 0; i < 8; i++)
		if (got[20 + i] != expect_tail[i]) {
			printf("cdvol: port byte [%d] = %02x expect %02x\n", 20 + i, got[20 + i], expect_tail[i]);
			fails++;
		}
	if (st != 0x00 || msg != 0x00) { printf("cdvol: MODE SENSE status %02x msg %02x\n", st, msg); fails++; }
	printf("cdvol: %s (sense page:", fails ? "FAIL" : "PASS");
	for (int i = 0; i < 28; i++) printf(" %02x", got[i]);
	printf(")\n");
	return fails ? 1 : 0;
}

// ---------------- CD target selection helper ----------------
// Selects the CD target (SCSI ID 3). Needs the harness's cd_img_mounted=1,
// or media-gated CD commands CHECK with the no-disc sense first.
static bool select_cd() {
	reg_write(WREG_ODR, (uint8_t)(1 << 3));
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY, 20000)) return false;
	reg_write(WREG_ICR, ICR_DATA);
	return true;
}

// ---------------- gap-pass command tests (gapcmds) ----------------
// Coverage the 2026-07-29 gap pass never had (it was only "boots in sim"):
// 0x42 formats 2/3 SERVED layouts, 0x44 READ HEADER LBA form + MSF reject,
// 0x45 PLAY AUDIO(10) acceptance. Run only on a build that carries them.
static int run_gapcmds() {
	reset_dut(0);
	int fails = 0;

	// --- 0x42 format 2 (MCN): 24 B, hdr len 20, format echo at [4] ---
	if (!select_cd()) { printf("gapcmds: select failed (f2)\n"); return 1; }
	uint8_t c_f2[10] = { 0x42, 0x02, 0x40, 0x02, 0, 0, 0, 0, 24, 0 };
	for (int i = 0; i < 10; i++)
		if (!pio_put(c_f2[i])) { printf("gapcmds: f2 CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	uint8_t g2[24];
	for (int i = 0; i < 24; i++) {
		int v = pio_get();
		if (v < 0) { printf("gapcmds: f2 data stalled at %d (not implemented?)\n", i); return 1; }
		g2[i] = (uint8_t)v;
	}
	int st = pio_get(), msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: f2 status %02x msg %02x\n", st, msg); fails++; }
	if (g2[3] != 20 || g2[4] != 0x02) {
		printf("gapcmds: f2 len %02x fmt %02x (want 14/02)\n", g2[3], g2[4]); fails++;
	}

	// --- 0x42 format 3 (ISRC): format echo + track echo at [6] ---
	if (!select_cd()) { printf("gapcmds: select failed (f3)\n"); return 1; }
	uint8_t c_f3[10] = { 0x42, 0x02, 0x40, 0x03, 0, 0, 0x05, 0, 24, 0 };
	for (int i = 0; i < 10; i++)
		if (!pio_put(c_f3[i])) { printf("gapcmds: f3 CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	uint8_t g3[24];
	for (int i = 0; i < 24; i++) {
		int v = pio_get();
		if (v < 0) { printf("gapcmds: f3 data stalled at %d\n", i); return 1; }
		g3[i] = (uint8_t)v;
	}
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: f3 status %02x msg %02x\n", st, msg); fails++; }
	if (g3[3] != 20 || g3[4] != 0x03 || g3[6] != 0x05) {
		printf("gapcmds: f3 len %02x fmt %02x trk %02x (want 14/03/05)\n", g3[3], g3[4], g3[6]);
		fails++;
	}

	// --- 0x44 READ HEADER, LBA form: 8 B, LBA echoed at [4..7] ---
	if (!select_cd()) { printf("gapcmds: select failed (hdr)\n"); return 1; }
	uint8_t c_hdr[10] = { 0x44, 0x00, 0x00, 0x00, 0x12, 0x34, 0, 0, 8, 0 };
	for (int i = 0; i < 10; i++)
		if (!pio_put(c_hdr[i])) { printf("gapcmds: hdr CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	uint8_t gh[8];
	for (int i = 0; i < 8; i++) {
		int v = pio_get();
		if (v < 0) { printf("gapcmds: hdr data stalled at %d (0x44 absent?)\n", i); return 1; }
		gh[i] = (uint8_t)v;
	}
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: hdr status %02x msg %02x\n", st, msg); fails++; }
	if (gh[4] != 0x00 || gh[5] != 0x00 || gh[6] != 0x12 || gh[7] != 0x34) {
		printf("gapcmds: hdr addr %02x%02x%02x%02x (want 00001234)\n", gh[4], gh[5], gh[6], gh[7]);
		fails++;
	}

	// --- 0x44 MSF form must CHECK with 5/0x24 ---
	if (!select_cd()) { printf("gapcmds: select failed (hdr msf)\n"); return 1; }
	uint8_t c_hm[10] = { 0x44, 0x02, 0, 0, 0, 0, 0, 0, 8, 0 };
	for (int i = 0; i < 10; i++)
		if (!pio_put(c_hm[i])) { printf("gapcmds: hdrmsf CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	st = pio_get(); msg = pio_get();
	if (st != 0x02) { printf("gapcmds: hdrmsf status %02x (want CHECK 02)\n", st); fails++; }
	if (!select_cd()) { printf("gapcmds: sense select failed\n"); return 1; }
	uint8_t c_rs[6] = { 0x03, 0, 0, 0, 18, 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(c_rs[i])) { printf("gapcmds: sense CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	uint8_t sns[18];
	for (int i = 0; i < 18; i++) {
		int v = pio_get();
		if (v < 0) { printf("gapcmds: sense stalled at %d\n", i); return 1; }
		sns[i] = (uint8_t)v;
	}
	(void)pio_get(); (void)pio_get();
	if ((sns[2] & 0x0F) != 0x05 || sns[12] != 0x24) {
		printf("gapcmds: hdrmsf sense %x/%02x (want 5/24)\n", sns[2] & 0x0F, sns[12]);
		fails++;
	}

	// --- 0xA5 PLAY AUDIO(12): 12-byte CDB must COMPLETE (cmd12_cpl) ---
	// Before group-5 completion existed this hung the target in CMD_IN forever.
	if (!select_cd()) { printf("gapcmds: select failed (play12)\n"); return 1; }
	uint8_t c_p12[12] = { 0xA5, 0x00, 0x00, 0x00, 0x00, 0x64, 0, 0, 0, 0x0A, 0, 0 };
	for (int i = 0; i < 12; i++)
		if (!pio_put(c_p12[i])) { printf("gapcmds: play12 CDB stalled %d (12B CDB unsupported?)\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: play12 status %02x msg %02x\n", st, msg); fails++; }

	// --- 0xBB SET CD SPEED (12-byte): accept-noop, GOOD ---
	if (!select_cd()) { printf("gapcmds: select failed (speed)\n"); return 1; }
	uint8_t c_sp[12] = { 0xBB, 0, 0x01, 0x76, 0x01, 0x76, 0, 0, 0, 0, 0, 0 };
	for (int i = 0; i < 12; i++)
		if (!pio_put(c_sp[i])) { printf("gapcmds: speed CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: setspeed status %02x msg %02x\n", st, msg); fails++; }

	// --- MODE SENSE(6) page 0x2A: capability payload, 38 bytes ---
	if (!select_cd()) { printf("gapcmds: select failed (ms2a)\n"); return 1; }
	uint8_t c_2a[6] = { 0x1A, 0x00, 0x2A, 0, 38, 0 };
	for (int i = 0; i < 6; i++)
		if (!pio_put(c_2a[i])) { printf("gapcmds: ms2a CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	uint8_t m2a[38];
	for (int i = 0; i < 38; i++) {
		int v = pio_get();
		if (v < 0) { printf("gapcmds: ms2a data stalled at %d (page absent?)\n", i); return 1; }
		m2a[i] = (uint8_t)v;
	}
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: ms2a status %02x msg %02x\n", st, msg); fails++; }
	if (m2a[0] != 37 || m2a[12] != 0x2A || m2a[13] != 0x18) {
		printf("gapcmds: ms2a hdr len %02x page %02x plen %02x (want 25/2A/18)\n",
		       m2a[0], m2a[12], m2a[13]); fails++;
	}
	if (m2a[16] != 0x71 || m2a[19] != 0x03 || m2a[22] != 0x01 || m2a[23] != 0x00) {
		printf("gapcmds: ms2a caps %02x mute/vol %02x levels %02x%02x (want 71/03/0100)\n",
		       m2a[16], m2a[19], m2a[22], m2a[23]); fails++;
	}

	// --- unknown 12-byte opcode: must CHECK invalid-op, NOT wedge ---
	if (!select_cd()) { printf("gapcmds: select failed (unk12)\n"); return 1; }
	uint8_t c_uk[12] = { 0xAF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	for (int i = 0; i < 12; i++)
		if (!pio_put(c_uk[i])) { printf("gapcmds: unk12 CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	st = pio_get(); msg = pio_get();
	if (st != 0x02) { printf("gapcmds: unk12 status %02x (want CHECK 02)\n", st); fails++; }

	// --- 0x45 PLAY AUDIO(10) LBA form: command accepted, GOOD status ---
	if (!select_cd()) { printf("gapcmds: select failed (play)\n"); return 1; }
	uint8_t c_pl[10] = { 0x45, 0x00, 0x00, 0x00, 0x00, 0x64, 0, 0x00, 0x0A, 0 };
	for (int i = 0; i < 10; i++)
		if (!pio_put(c_pl[i])) { printf("gapcmds: play CDB stalled %d\n", i); return 1; }
	reg_write(WREG_ICR, 0);
	st = pio_get(); msg = pio_get();
	if (st != 0x00 || msg != 0x00) { printf("gapcmds: play status %02x msg %02x\n", st, msg); fails++; }

	printf("gapcmds: %s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}

// ---------------- BlueSCSI Toolbox transport test (toolbox) ----------------
// Desk reproduction of the 2026-07-30 hardware failure "a lot of errors copying
// from the Mac to the SD card". Drives target 0 (TOOLBOX_ENABLE) through the
// real client sequence against the TbHps mirror of Main's handler:
//
//   0xD2 COUNT -> 0xD0 LIST (>512 B: multi-sector DataIn)
//   0xD3 SEND PREP / 0xD4 SEND DATA x3 / 0xD5 SEND END, then byte-compare the
//        uploaded image against the source
//   0xD1 GET  (4096-byte block: multi-sector DataIn)
//
// Client model for 0xD4 (BlueSCSI SEND_FILE_10): the DataOut phase is ALWAYS a
// full 512-byte block; CDB[6] (512-blocks) or CDB[1..2] (legacy byte count) says
// how many of those bytes are valid. The last chunk of a file is therefore a
// full block carrying a short valid count.
static bool tb_select() {
	reg_write(WREG_ODR, 0x01);                   // target SCSI ID 0
	reg_write(WREG_ICR, ICR_DATA | ICR_SEL);
	if (!wait_csr(CSR_BSY, CSR_BSY)) return false;
	reg_write(WREG_ICR, ICR_DATA);
	return true;
}

// One command: 10-byte CDB, optional DataOut payload, optional DataIn read,
// then status + message. Returns status, or -1 on any stall.
static int tb_cmd(const uint8_t* cdb, const uint8_t* payload, int paylen,
                  uint8_t* din, int dinlen, const char* what) {
	if (!tb_select()) { printf("toolbox: %s select failed\n", what); return -1; }
	for (int i = 0; i < 10; i++)
		if (!pio_put(cdb[i])) { printf("toolbox: %s CDB stalled at %d\n", what, i); return -1; }
	for (int i = 0; i < paylen; i++)
		if (!pio_put(payload[i])) {
			printf("toolbox: %s DataOut stalled at byte %d of %d "
			       "(target ended the data phase early)\n", what, i, paylen);
			return -1;
		}
	reg_write(WREG_ICR, 0);                       // release the data bus
	for (int i = 0; i < dinlen; i++) {
		int v = pio_get();
		if (v < 0) { printf("toolbox: %s DataIn stalled at %d of %d\n", what, i, dinlen); return -1; }
		din[i] = (uint8_t)v;
	}
	int st = pio_get(), msg = pio_get();
	if (msg != 0x00) { printf("toolbox: %s message %02x\n", what, msg); return -1; }
	return st;
}

static int run_toolbox() {
	reset_dut(0);
	tbx.reset();
	top->tb_mounted = 1;                          // HPS mounted the shared folder
	for (int i = 0; i < 8; i++) tick();

	// virtual shared folder: 14 entries -> LIST is 560 B (2 sectors)
	tbx.files.clear();
	for (int i = 0; i < 13; i++) {
		char nm[32]; snprintf(nm, sizeof(nm), "file_%02d.bin", i);
		tbx.files.push_back({ nm, std::vector<uint8_t>((size_t)(i * 37), (uint8_t)i) });
	}
	std::vector<uint8_t> big(9000);
	for (size_t i = 0; i < big.size(); i++) big[i] = ramp(0x50000 + i);
	tbx.files.push_back({ "big.bin", big });

	int fails = 0;
	uint8_t buf[8192];

	// ---- 0xD2 COUNT FILES: 1 byte ----
	{
		uint8_t cdb[10] = { 0xD2, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		int st = tb_cmd(cdb, nullptr, 0, buf, 1, "COUNT");
		if (st != 0x00) { printf("toolbox: COUNT status %02x\n", st); return 1; }
		if (buf[0] != tbx.files.size()) {
			printf("toolbox: COUNT = %u, want %zu\n", buf[0], tbx.files.size()); fails++;
		}
	}

	// ---- 0xD0 LIST FILES: 14 x 40 = 560 bytes (crosses the 512-byte sector) ----
	{
		int want = (int)tbx.files.size() * 40;
		uint8_t cdb[10] = { 0xD0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		int st = tb_cmd(cdb, nullptr, 0, buf, want, "LIST");
		if (st != 0x00) { printf("toolbox: LIST status %02x\n", st); return 1; }
		if ((int)tbx.resp.size() != want) {
			printf("toolbox: LIST staged %zu bytes, want %d\n", tbx.resp.size(), want); fails++;
		} else {
			int bad = -1, nbad = 0;
			for (int i = 0; i < want; i++) if (buf[i] != tbx.resp[i]) { if (bad < 0) bad = i; nbad++; }
			if (bad >= 0) {
				printf("toolbox: LIST %d/%d bytes wrong, first at %d\n", nbad, want, bad);
				int w0 = bad > 8 ? bad - 8 : 0;
				printf("   got :"); for (int i = w0; i < w0 + 24 && i < want; i++) printf(" %02x", buf[i]);
				printf("\n   want:"); for (int i = w0; i < w0 + 24 && i < want; i++) printf(" %02x", tbx.resp[i]);
				printf("\n");
				fails++;
			}
		}
	}

	// ---- 0xD3/D4/D5 SEND FILE: 1408 bytes = 2 full blocks + a 384-byte tail ----
	{
		const int SRC = 1408;
		std::vector<uint8_t> src(SRC);
		for (int i = 0; i < SRC; i++) src[i] = ramp(0x90000 + i);

		uint8_t name[33] = {};
		memcpy(name, "upload.bin", 10);
		uint8_t cdb_prep[10] = { 0xD3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		int st = tb_cmd(cdb_prep, name, 33, nullptr, 0, "SEND PREP");
		if (st != 0x00) { printf("toolbox: SEND PREP status %02x\n", st); return 1; }

		for (int blk = 0; blk * 512 < SRC; blk++) {
			int valid = SRC - blk * 512; if (valid > 512) valid = 512;
			uint8_t chunk[512];
			memset(chunk, 0xFF, sizeof(chunk));            // client sends a full block
			memcpy(chunk, &src[blk * 512], valid);
			uint8_t cdb[10] = { 0xD4, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
			if (valid == 512) cdb[6] = 1;                   // block encoding
			else { cdb[1] = (uint8_t)(valid >> 8); cdb[2] = (uint8_t)valid; }  // legacy count
			cdb[3] = (uint8_t)(blk >> 16); cdb[4] = (uint8_t)(blk >> 8); cdb[5] = (uint8_t)blk;
			char what[32]; snprintf(what, sizeof(what), "SEND DATA blk%d", blk);
			st = tb_cmd(cdb, chunk, 512, nullptr, 0, what);
			if (st != 0x00) { printf("toolbox: %s status %02x\n", what, st); return 1; }
		}

		uint8_t cdb_end[10] = { 0xD5, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		st = tb_cmd(cdb_end, nullptr, 0, nullptr, 0, "SEND END");
		if (st != 0x00) { printf("toolbox: SEND END status %02x\n", st); return 1; }

		if (tbx.upload.size() != (size_t)SRC) {
			printf("toolbox: uploaded %zu bytes, want %d (%+d)\n",
			       tbx.upload.size(), SRC, (int)tbx.upload.size() - SRC);
			fails++;
		}
		int bad = 0, first = -1;
		for (size_t i = 0; i < src.size() && i < tbx.upload.size(); i++)
			if (tbx.upload[i] != src[i]) { if (first < 0) first = (int)i; bad++; }
		if (bad) {
			printf("toolbox: upload %d/%d bytes wrong, first at %d (got %02x want %02x)\n",
			       bad, SRC, first, tbx.upload[first], src[first]);
			fails++;
		}
	}

	// ---- SEND with a SHORT final DataOut: the alternate client model, where the
	// initiator transfers only the CDB's valid-byte count instead of a full
	// block. The fixed 512-byte phase length would hang the bus without the
	// inter-byte watchdog; check it closes the phase and the file still lands.
	{
		const int SRC = 700;                       // 1 full block + 188 bytes
		std::vector<uint8_t> src(SRC);
		for (int i = 0; i < SRC; i++) src[i] = ramp(0xA1000 + i);

		uint8_t name[33] = {};
		memcpy(name, "short.bin", 9);
		uint8_t cdb_prep[10] = { 0xD3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		int st = tb_cmd(cdb_prep, name, 33, nullptr, 0, "SHORT PREP");
		if (st != 0x00) { printf("toolbox: SHORT PREP status %02x\n", st); return 1; }

		for (int blk = 0; blk * 512 < SRC; blk++) {
			int valid = SRC - blk * 512; if (valid > 512) valid = 512;
			uint8_t cdb[10] = { 0xD4, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
			if (valid == 512) cdb[6] = 1;
			else { cdb[1] = (uint8_t)(valid >> 8); cdb[2] = (uint8_t)valid; }
			cdb[3] = (uint8_t)(blk >> 16); cdb[4] = (uint8_t)(blk >> 8); cdb[5] = (uint8_t)blk;
			if (!tb_select()) { printf("toolbox: SHORT blk%d select failed\n", blk); return 1; }
			for (int i = 0; i < 10; i++)
				if (!pio_put(cdb[i])) { printf("toolbox: SHORT blk%d CDB stalled %d\n", blk, i); return 1; }
			for (int i = 0; i < valid; i++)
				if (!pio_put(src[blk*512 + i])) { printf("toolbox: SHORT blk%d stalled at %d\n", blk, i); return 1; }
			reg_write(WREG_ICR, 0);
			// wait out the watchdog: phase flips to STATUS (IO=1) on its own
			if (!wait_csr(CSR_IO, CSR_IO, 200000)) {
				printf("toolbox: SHORT blk%d wedged in DataOut (watchdog did not fire)\n", blk);
				return 1;
			}
			int s2 = pio_get(), m2 = pio_get();
			if (s2 != 0x00 || m2 != 0x00) { printf("toolbox: SHORT blk%d status %02x msg %02x\n", blk, s2, m2); fails++; }
		}
		uint8_t cdb_end[10] = { 0xD5, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		st = tb_cmd(cdb_end, nullptr, 0, nullptr, 0, "SHORT END");
		if (st != 0x00) { printf("toolbox: SHORT END status %02x\n", st); fails++; }

		if (tbx.upload.size() != (size_t)SRC || memcmp(tbx.upload.data(), src.data(), SRC)) {
			printf("toolbox: short-send upload %zu bytes (want %d), content %s\n",
			       tbx.upload.size(), SRC,
			       (tbx.upload.size() == (size_t)SRC && !memcmp(tbx.upload.data(), src.data(), SRC))
			         ? "ok" : "MISMATCH");
			fails++;
		}
	}

	// ---- 0xD1 GET FILE: one 4096-byte block out of big.bin (8 sectors) ----
	{
		uint8_t cdb[10] = { 0xD1, 13, 0, 0, 0, 0, 1, 0, 0, 0 };   // index 13 = big.bin, offset 0, 1 block
		int st = tb_cmd(cdb, nullptr, 0, buf, 4096, "GET");
		if (st != 0x00) { printf("toolbox: GET status %02x\n", st); return 1; }
		if (tbx.resp.size() != 4096) {
			printf("toolbox: GET staged %zu bytes, want 4096\n", tbx.resp.size()); fails++;
		} else {
			int bad = 0, first = -1;
			for (int i = 0; i < 4096; i++)
				if (buf[i] != tbx.resp[i]) { if (first < 0) first = i; bad++; }
			if (bad) {
				printf("toolbox: GET %d/4096 bytes wrong, first at %d (got %02x want %02x)\n",
				       bad, first, buf[first], tbx.resp[first]);
				fails++;
			}
		}
	}

	printf("toolbox: %s (tb reqs=%llu fills=%llu)\n", fails ? "FAIL" : "PASS",
	       (unsigned long long)tbx.reqs, (unsigned long long)tbx.fills);
	return fails ? 1 : 0;
}

// ---------------- DIFFERENTIAL probe: stale ack fall (toolboxwdog) -----------
// The toolbox suite re-run with tb_ack held high past the core's ~8 ms watchdog,
// so the force-latch completes each round trip and the ack fall arrives stale.
//
// THIS IS NOT A PASS/FAIL GATE. The silicon-proven pre-fix RTL (52715a7) fails
// it too — TBS_DATA clears tb_rd_r on the stale ack, the fetch never issues, and
// the status block gets served as LIST data. Since LIST works on real hardware,
// the model is over-constrained: the ack fall must normally be caught there, and
// the watchdog only covers occasional misses.
//
// Its value is DIFFERENTIAL — compare a candidate against 52715a7:
//   52715a7 (good) : LIST corrupt at byte 1, SEND stalls at byte 23
//   7ec4e2b (bad)  : dies on the FIRST command (COUNT) — the HW symptom, where
//                    every Toolbox command returned CHECK and nothing listed
//   d4c70e6 (fix)  : byte-for-byte identical to 52715a7 => no divergence
// A candidate that fails EARLIER or DIFFERENTLY than 52715a7 has changed the
// handshake and must not be deployed.
static int run_toolbox_wdog() {
	const int saved_patience = csr_patience;
	hps.tb_ack_hold = 300000;    // > the 262144-cycle watchdog
	csr_patience    = 3000000;   // the initiator must outwait the force-latch
	printf("toolboxwdog: DIFFERENTIAL probe — tb_ack held %d cycles.\n"
	       "toolboxwdog: known-good 52715a7 ALSO fails here; compare the failure\n"
	       "toolboxwdog: SHAPE against it, do not read this as pass/fail.\n",
	       hps.tb_ack_hold);
	int rc = run_toolbox();
	hps.tb_ack_hold = 0;
	csr_patience    = saved_patience;
	printf("toolboxwdog: probe complete (rc=%d — expected nonzero, see above)\n", rc);
	return 0;   // differential probe: never gates
}

// ---------------- Toolbox transport under a stalling HPS (toolboxslow) -------
// The HW failure this covers: a 2.7 MiB Mac->SD copy died ~1769 blocks in with
// "the SD card refused the transfer", leaving a file of exactly 1769*512 bytes.
// /media/fat is exFAT mounted sync,dirsync, so every SEND chunk is a synchronous
// card write; when the card hits an erase cycle the handler does not answer
// inside the core's ~8 ms watchdog. The core then looked at a buffer that still
// held the CDB it wrote, found no 0xB5 signature, and reported CHECK CONDITION
// as if no handler existed. One slow round trip in ~1770 is enough to abort a
// whole copy, which is why small files always worked.
static int run_toolbox_slow() {
	reset_dut(0);
	tbx.reset();
	top->tb_mounted = 1;
	for (int i = 0; i < 8; i++) tick();

	tbx.files.clear();
	tbx.files.push_back({ "seed.bin", std::vector<uint8_t>(16, 0x5A) });

	// Stall every 3rd tb READ for ~3 watchdog periods (786432 > 3*262144), so
	// the retry path has to survive several re-looks, not just one.
	hps.tb_reads = 0;
	hps.tb_slow_every = 3;
	hps.tb_slow_latency = 786432;
	const int saved_patience = csr_patience;
	// A stalled card legitimately holds the target; a 4096-byte GET fetches 8
	// data sectors, so several stalls can stack inside one command.
	csr_patience = 3000000;

	const int SRC = 512 * 6;
	std::vector<uint8_t> src(SRC);
	for (int i = 0; i < SRC; i++) src[i] = ramp(0xC0000 + i);

	int fails = 0;
	uint8_t name[33] = {};
	memcpy(name, "stall.bin", 9);
	uint8_t cdb_prep[10] = { 0xD3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	int st = tb_cmd(cdb_prep, name, 33, nullptr, 0, "SLOW PREP");
	if (st != 0x00) { printf("toolboxslow: PREP status %02x (want 00)\n", st); fails++; }

	for (int blk = 0; blk * 512 < SRC; blk++) {
		uint8_t chunk[512];
		memcpy(chunk, &src[blk * 512], 512);
		uint8_t cdb[10] = { 0xD4, 0, 0, 0, 0, 0, 1, 0, 0, 0 };
		cdb[3] = (uint8_t)(blk >> 16); cdb[4] = (uint8_t)(blk >> 8); cdb[5] = (uint8_t)blk;
		char what[32]; snprintf(what, sizeof(what), "SLOW DATA blk%d", blk);
		st = tb_cmd(cdb, chunk, 512, nullptr, 0, what);
		if (st != 0x00) {
			printf("toolboxslow: %s status %02x (want 00) "
			       "<-- the HW abort: a slow HPS read as CHECK CONDITION\n", what, st);
			fails++;
		}
	}

	uint8_t cdb_end[10] = { 0xD5, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	st = tb_cmd(cdb_end, nullptr, 0, nullptr, 0, "SLOW END");
	if (st != 0x00) { printf("toolboxslow: END status %02x (want 00)\n", st); fails++; }

	if (tbx.upload.size() != (size_t)SRC) {
		printf("toolboxslow: uploaded %zu bytes, want %d (%+d)\n",
		       tbx.upload.size(), SRC, (int)tbx.upload.size() - SRC);
		fails++;
	} else {
		int bad = 0, first = -1;
		for (int i = 0; i < SRC; i++)
			if (tbx.upload[i] != src[i]) { if (first < 0) first = i; bad++; }
		if (bad) {
			printf("toolboxslow: upload %d/%d bytes wrong, first at %d\n", bad, SRC, first);
			fails++;
		}
	}

	// ---- KNOWN GAP probe, reported but NOT counted as a failure --------------
	// A GET whose data blocks are stalled. TBS_DATA advances on the bare
	// watchdog and a data block carries no signature, so a stalled sector serves
	// the previous one's bytes. Verified pre-existing: the same probe fails
	// identically on 52715a7 (the RTL deployed before any of this work), so it is
	// a gap, not a regression. Fixing it needs positive fill evidence in the
	// core; a 2026-07-31 attempt at that broke every Toolbox command on HW and
	// was reverted. Do not retry it without an HW-faithful model of the
	// watchdog-primary path this transport actually runs on.
	int gap_bad = 0;
	{
		uint8_t buf[4096];
		std::vector<uint8_t> big(4096);
		for (size_t i = 0; i < big.size(); i++) big[i] = ramp(0xD0000 + i);
		tbx.files.push_back({ "big.bin", big });
		uint8_t cdb[10] = { 0xD1, 1, 0, 0, 0, 0, 1, 0, 0, 0 };
		st = tb_cmd(cdb, nullptr, 0, buf, 4096, "SLOW GET");
		if (st != 0x00 || tbx.resp.size() != 4096) gap_bad = -1;
		else for (int i = 0; i < 4096; i++) if (buf[i] != tbx.resp[i]) gap_bad++;
	}

	if (gap_bad)
		printf("toolboxslow: KNOWN GAP (pre-existing, not a regression) - GET under a "
		       "stalled HPS corrupts %d/4096 bytes; TBS_DATA has no fill evidence to "
		       "wait on. Not counted as a failure.\n", gap_bad);

	hps.tb_slow_every = 0;
	csr_patience = saved_patience;
	printf("toolboxslow: %s (tb reads=%llu, %d stalled past the watchdog)\n",
	       fails ? "FAIL" : "PASS", (unsigned long long)hps.tb_reads,
	       (int)(hps.tb_reads / 3));
	return fails ? 1 : 0;
}

// ---------------- main ----------------
int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	top = new Vscsi_bench_top;

	// defaults
	int sectors = 2, hps_lat = 600, scsi_id = 6, id_slot = 0;
	int one_ds = -1, one_gap = -1;
	const char* one_mode = nullptr;
	bool detail = false;
	const char* wave = nullptr;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--mode") && i+1 < argc) one_mode = argv[++i];
		else if (!strcmp(argv[i], "--ds") && i+1 < argc) one_ds = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--gap") && i+1 < argc) one_gap = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--sectors") && i+1 < argc) sectors = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--hps") && i+1 < argc) hps_lat = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--id") && i+1 < argc) scsi_id = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--slot") && i+1 < argc) id_slot = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--detail")) detail = true;
		else if (!strcmp(argv[i], "--wave") && i+1 < argc) wave = argv[++i];
		else if (!strcmp(argv[i], "--help")) {
			printf("scsi_bench: see header comment. Default = full (mode x ds x gap x hps) sweep.\n");
			return 0;
		}
	}

#if VM_TRACE
	if (wave) {
		Verilated::traceEverOn(true);
		tfp = new VerilatedFstC;
		top->trace(tfp, 99);
		tfp->open(wave);
	}
#else
	(void)wave;
#endif

	Mode modes[6] = { M_BYTE, M_WORD, M_LONG, M_MIX, M_LONGSKEW, M_WORDSKEW };

	if (one_mode && !strcmp(one_mode, "gapcmds")) {
		int rc = run_gapcmds();
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return rc;
	}

	if (one_mode && !strcmp(one_mode, "toolbox")) {
		int rc = run_toolbox();
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return rc;
	}

	if (one_mode && !strcmp(one_mode, "toolboxwdog")) {
		int rc = run_toolbox_wdog();
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return rc;
	}

	if (one_mode && !strcmp(one_mode, "toolboxslow")) {
		int rc = run_toolbox_slow();
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return rc;
	}

	if (one_mode && !strcmp(one_mode, "cdvol")) {
		int rc = run_cdvol();
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return rc;
	}

	// write-mode single runs (separate path: verifies the flushed image)
	if (one_mode && (!strcmp(one_mode, "wbyte") || !strcmp(one_mode, "wword"))) {
		bool wm = !strcmp(one_mode, "wword");
		int gap = one_gap >= 0 ? one_gap : 3;
		printf("RUN mode=%s sectors=%d gap=%d hps=%d id=%d\n",
		       one_mode, sectors, gap, hps_lat, scsi_id);
		RunResult r = run_write(wm, sectors, gap, hps_lat, scsi_id, id_slot, true);
		printf("=> sel=%d cmd=%d timeout=%d mismatches=%d first_bad=%d "
		       "status=%02x msg=%02x flushes=%llu cycles=%llu\n",
		       r.selected, r.cmd_sent, r.dreq_timeout, r.mismatches, r.first_bad,
		       r.status, r.message, (unsigned long long)hps.flushes,
		       (unsigned long long)r.cycles_used);
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return (r.mismatches || r.dreq_timeout || !r.completion_ok) ? 1 : 0;
	}

	if (one_mode || one_ds >= 0 || one_gap >= 0) {
		// single run
		Mode m = M_WORD;
		if (one_mode) {
			if (!strcmp(one_mode, "byte")) m = M_BYTE;
			else if (!strcmp(one_mode, "word")) m = M_WORD;
			else if (!strcmp(one_mode, "long")) m = M_LONG;
			else if (!strcmp(one_mode, "mix")) m = M_MIX;
			else if (!strcmp(one_mode, "longskew")) m = M_LONGSKEW;
			else if (!strcmp(one_mode, "wordskew")) m = M_WORDSKEW;
		}
		int ds = one_ds >= 0 ? one_ds : 0;
		int gap = one_gap >= 0 ? one_gap : 2;
		printf("RUN mode=%s sectors=%d ds=%d gap=%d hps=%d id=%d\n",
		       mode_name(m), sectors, ds, gap, hps_lat, scsi_id);
		RunResult r = run_read(m, sectors, ds, gap, hps_lat, scsi_id, id_slot, true);
		printf("=> sel=%d cmd=%d timeout=%d mismatches=%d first_bad=%d unstable=%d "
		       "status=%02x msg=%02x cycles=%llu\n",
		       r.selected, r.cmd_sent, r.dreq_timeout, r.mismatches, r.first_bad,
		       r.unstable, r.status, r.message, (unsigned long long)r.cycles_used);
#if VM_TRACE
		if (tfp) tfp->close();
#endif
		return (r.mismatches || r.dreq_timeout || !r.completion_ok) ? 1 : 0;
	}

	// ---- full sweep ----
	const int ds_list[]  = { 0, 1, 2, 3, 4, 6 };
	const int gap_list[] = { 1, 2, 3, 4, 6, 8, 12 };
	const int hps_list[] = { 600, 6000 };
	int total_fail = 0;

	for (int hi = 0; hi < 2; hi++) {
		int hl = hps_list[hi];
		for (Mode m : modes) {
			printf("\n=== mode=%s sectors=%d hps_latency=%d (cell = mismatches, T = DREQ timeout, . = clean) ===\n",
			       mode_name(m), sectors, hl);
			printf("        gap:");
			for (int g : gap_list) printf("%6d", g);
			printf("\n");
			int first_bad_ds = -1, first_bad_gap = -1;
			for (int ds : ds_list) {
				printf("  ds=%2d     ", ds);
				for (int g : gap_list) {
					RunResult r = run_read(m, sectors, ds, g, hl, scsi_id, id_slot, false);
					if (r.dreq_timeout) { printf("     T"); total_fail++; }
					else if (!r.selected || !r.cmd_sent) { printf("     S"); total_fail++; }
					else if (r.mismatches) {
						printf("%6d", r.mismatches);
						total_fail++;
						if (first_bad_ds < 0) { first_bad_ds = ds; first_bad_gap = g; }
					} else if (r.unstable) printf("    u.");
					else printf("     .");
					fflush(stdout);
				}
				printf("\n");
			}
			if (first_bad_ds >= 0) {
				printf("--- detail of first failing cell: ds=%d gap=%d ---\n", first_bad_ds, first_bad_gap);
				run_read(m, sectors, first_bad_ds, first_bad_gap, hl, scsi_id, id_slot, true);
			}
		}
	}

	// ---- write sweep (gap only; writes have no host sampling point) ----
	for (int hi = 0; hi < 2; hi++) {
		int hl = hps_list[hi];
		for (int wm = 0; wm < 2; wm++) {
			printf("\n=== mode=%s sectors=%d hps_latency=%d ===\n        gap:",
			       wm ? "wword" : "wbyte", sectors, hl);
			for (int g : gap_list) printf("%6d", g);
			printf("\n            ");
			int first_bad_gap = -1;
			for (int g : gap_list) {
				RunResult r = run_write(wm != 0, sectors, g, hl, scsi_id, id_slot, false);
				if (r.dreq_timeout) { printf("     T"); total_fail++; }
				else if (!r.selected || !r.cmd_sent) { printf("     S"); total_fail++; }
				else if (r.mismatches) {
					printf("%6d", r.mismatches);
					total_fail++;
					if (first_bad_gap < 0) first_bad_gap = g;
				} else printf("     .");
				fflush(stdout);
			}
			printf("\n");
			if (first_bad_gap >= 0) {
				printf("--- detail of first failing cell: gap=%d ---\n", first_bad_gap);
				run_write(wm != 0, sectors, first_bad_gap, hl, scsi_id, id_slot, true);
			}
		}
	}

	printf("\nTOTAL failing cells: %d\n", total_fail);
#if VM_TRACE
	if (tfp) tfp->close();
#endif
	delete top;
	return total_fail ? 1 : 0;
}
