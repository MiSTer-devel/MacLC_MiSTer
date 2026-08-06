#!/usr/bin/env python3
"""Decode the USE_DBG_HUD binary pixel strip from a MiSTer screenshot.

HUD layout (MacLC.sv USE_DBG_HUD block): 8 rows x 32 cells, top-left corner.
Cell = 8px wide x 8 lines tall at core resolution (screenshot may be integer-
scaled; a ~1px right shift comes from the pipeline stage). MSB first,
white=1 / black=0.
  row 0  32'hA5C3F00F                          marker (self-calibration)
  row 1  {byte_cnt[15:0], miss_cnt[15:0]}
  row 2  {side, track[6:0], step_cnt[15:0], 5'b0, ism_error[2:0]}
  row 3  {10'b0, dskReadAddrInt[21:0]}         live fetch BYTE address
  row 4  {err_onset_cnt[7:0], arm[7:0], ovr[7:0], unr[7:0]}
  row 5  {e142_first[15:0], e142_last[15:0]}   Sony driver result codes
  row 6  {e142_nz_cnt[15:0], e142_all_cnt[15:0]}
  row 7  MEDIA witness (2026-08-06+): {CSTIN,switched,insertDisk,ism,
         ej[3:0],clr[3:0],edges[3:0],poll1[7:0],poll6[7:0]}
         (pre-887ebba fits: SCAN-WITNESS latched at the LAST -81 post)
         {run[7:0], hunt_ms[7:0], par[1:0], gap_us[13:0]}
  row 8  LIVE {mfm stall_us[15:0], stall_cnt[7:0], e81_cnt[7:0]}
  row 10 latch @ first nonzero $142 {side, track[6:0], 2'b0, addr[21:0]}

The $142 watcher (2026-08-05): the ROM Sony driver posts every MFM read
result as a word write to low-mem $142 (ROM a6ea60); nonzero = the exact
Mac error code behind the guest's "disk error" dialog.

Usage: parse_hud.py <frame.png> [more.png ...]
"""
import sys
import numpy as np
from PIL import Image

MARKER = 0xA5C3F00F
NROWS = 12

# Two deck geometries are supported so ARCHIVED captures stay readable:
#   cell 4 px, bottom-left  — current (MacLC.sv, 2026-08-05 pm)
#   cell 8 px, top-left     — original
# Each entry is (base_cell_px, where) with where in {'bottom','top'}.
LAYOUTS = ((4, 'bottom'), (8, 'top'))


def _row_bits(g, x0, yr, cw):
    w = 0
    for i in range(32):
        xc = x0 + i * cw + cw // 2
        # 3-sample majority along x for noise robustness
        v = int(g[yr, xc]) + int(g[yr, xc - 1]) + int(g[yr, xc + 1])
        w = (w << 1) | (1 if v >= 2 else 0)
    return w


def find_and_decode(img):
    g = np.array(img.convert('L')) > 128
    H, W = g.shape
    for base, where in LAYOUTS:
        for s in (1, 2, 3, 4):              # integer screenshot scale
            cw = base * s                   # cell width/height in screen px
            deck_h = NROWS * cw
            if deck_h + 2 > H or 32 * cw + 2 > W:
                continue
            if where == 'bottom':
                cands = range(max(0, H - deck_h - 4), H - deck_h + 1)
            else:
                cands = range(0, min(40, H - deck_h) + 1)
            for y0 in cands:
                yc = y0 + cw // 2           # sample line of row 0 (marker)
                for x0 in range(0, min(3 * s + 4, W - 32 * cw)):
                    if _row_bits(g, x0, yc, cw) != MARKER:
                        continue
                    words = [_row_bits(g, x0, y0 + r * cw + cw // 2, cw)
                             for r in range(NROWS)]
                    return (x0, y0, s, base, where), words
    return None, None


def decode_frame(path):
    """Decode a screenshot -> list of 12 HUD words, or None. For importers
    (e.g. scratch/copy_babysit2.sh) so the decoder lives in exactly one place."""
    _, words = find_and_decode(Image.open(path))
    return words

def sec_geom(byte_addr):
    sec = byte_addr >> 9
    ts, s_in = divmod(sec, 18)
    cyl, head = divmod(ts, 2)
    return f"sector {sec} (cyl {cyl} head {head} sec {s_in}, +{byte_addr & 511} B)"

SONY_ERR = {
    0xFFC0: "-64 noDriveErr", 0xFFBF: "-65 offLinErr", 0xFFBE: "-66 noNybErr (byte poll budget expired)",
    0xFFBD: "-67 noAdrMkErr (address-mark hunt exhausted)",
    0xFFBC: "-68 dataVerErr (verify mismatch)",
    0xFFBB: "-69 badCksmErr (ID field CRC/error verdict)",
    0xFFBA: "-70 badBtSlpErr", 0xFFB9: "-71 noDtaMkErr (data-mark compare failed)",
    0xFFB8: "-72 badDCksum (data field CRC/error verdict)",
    0xFFB7: "-73 badDBtSlp", 0xFFB6: "-74 wrUnderrun", 0xFFB5: "-75 cantStepErr",
    0xFFB4: "-76 tk0BadErr", 0xFFB3: "-77 initIWMErr", 0xFFB2: "-78 twoSideErr",
    0xFFB1: "-79 spdAdjErr", 0xFFB0: "-80 seekErr", 0xFFAF: "-81 sectNFErr",
    0xFFAE: "-82 fmt1Err", 0xFFAD: "-83 fmt2Err (ROM a6e7dc posts this literal)",
    0xFFAC: "-84 verErr",
}

def sony_err(v):
    if v == 0:
        return "0 (none)"
    name = SONY_ERR.get(v)
    signed = v - 0x10000 if v & 0x8000 else v
    return name if name else f"{signed} ({v:#06x} — not a Sony -64..-81 code)"

def decode(words):
    w = words
    print(f"  w1 byte_cnt={w[1] >> 16:5d}  miss_cnt={w[1] & 0xFFFF:5d}")
    print(f"  w2 LIVE side={w[2] >> 31} track={(w[2] >> 24) & 0x7F:3d} "
          f"step_cnt={(w[2] >> 8) & 0xFFFF:5d} ism_error={w[2] & 7:03b}")
    print(f"  w3 LIVE fetch addr {w[3] & 0x3FFFFF:#08x} = {sec_geom(w[3] & 0x3FFFFF)}")
    print(f"  w4 onset_cnt={w[4] >> 24:3d} arm={(w[4] >> 16) & 0xFF:3d} "
          f"ovr={(w[4] >> 8) & 0xFF:3d} unr={w[4] & 0xFF:3d}")
    print(f"  w5 $142 FIRST err = {sony_err(w[5] >> 16)}")
    print(f"     $142 LAST  err = {sony_err(w[5] & 0xFFFF)}")
    print(f"  w6 $142 error completions={w[6] >> 16:5d}  ALL completions={w[6] & 0xFFFF:5d}")
    # w7 = MEDIA-CHANGE WITNESS as of 2026-08-06 (floppy.v dbg_media; the
    # disk-swap mission). Fits older than 887ebba carried the -81
    # SCAN-WITNESS here instead — for those read the raw hex.
    m7 = w[7]
    e81 = w[8] & 0xFF if len(w) > 8 else 0
    print(f"  w7 MEDIA: CSTIN={'EMPTY' if (m7 >> 31) & 1 else 'disk-IN'} "
          f"switched={(m7 >> 30) & 1} insertDisk={(m7 >> 29) & 1} "
          f"ism={(m7 >> 28) & 1}")
    print(f"     ejects={(m7 >> 24) & 0xF} dskchg_clears={(m7 >> 20) & 0xF} "
          f"cstin_edges={(m7 >> 16) & 0xF} "
          f"poll_CSTIN={(m7 >> 8) & 0xFF} poll_SWITCHED={m7 & 0xFF} "
          f"(raw {m7:#010x})")
    if len(w) > 8:
        stall_us, stall_cnt = w[8] >> 16, (w[8] >> 8) & 0xFF
        print(f"  w8 LIVE mfm stalls: worst {stall_us} us, {stall_cnt} stalled "
              f"deliveries, e81 posts latched: {e81}")
        if stall_us >= 1000:
            print(f"     ** MFM DELIVERY STALLED ms-scale ({stall_us} us): the "
                  "SDRAM fetch starved the byte engine — the rotation stretched. "
                  "SDRAM-contention suspect REVIVED.")
        elif stall_us <= 8:
            print("     fetch path healthy (worst stall within one byte cell) — "
                  "SDRAM contention excluded at this scale")
    if len(w) > 9:
        m = w[9]
        mode, setup = m >> 24, (m >> 16) & 0xFF
        rej = m & 0x1FF
        print(f"  w9 MODE={mode:#04x} [motor={mode >> 7} ism={(mode >> 6) & 1} "
              f"hdsel={(mode >> 5) & 1} write={(mode >> 4) & 1} action={(mode >> 3) & 1} "
              f"drvsel={(mode >> 1) & 3:02b} clrfifo={mode & 1}]  SETUP={setup:#04x}")
        if rej & 0x100:
            print(f"     ** REJECTED STEPS: {rej & 0xFF} "
                  f"(well-formed STEP dropped because _enable was high)")
        else:
            print("     no rejected steps recorded")
    if len(w) > 10 and w[10]:
        print(f"  w10 AT FIRST $142 ERROR: side={w[10] >> 31} track={(w[10] >> 24) & 0x7F:3d} "
              f"addr {w[10] & 0x3FFFFF:#08x} = {sec_geom(w[10] & 0x3FFFFF)}")
    if len(w) > 11:
        st = w[11] >> 24
        ii, ie = (w[11] >> 17) & 1, (w[11] >> 16) & 1
        print(f"  w11 LIVE spinning={st >> 7} motor={(st >> 6) & 1} ism_sel={(st >> 5) & 1} "
              f"MOTORONreg={(st >> 4) & 1} side={(st >> 3) & 1} ism_active={(st >> 2) & 1} "
              f"action={(st >> 1) & 1} diskin={st & 1}")
        print(f"      insertDisk: internal={ii} external={ie}   "
              f"disk_data={(w[11] >> 8) & 0xFF:#04x} raw={w[11] & 0xFF:#04x}")
        if ii and not (st & 1):
            print("      ** image IS mounted to the internal slot but the drive says NO DISK")
        elif ie and not ii:
            print("      ** image landed in the EXTERNAL slot (unreachable in ISM mode)")
    nz, unr = w[6] >> 16, w[4] & 0xFF
    if e81:
        # Interpretation grid (ground truth: budget seed 64, MAME max healthy
        # scan 17, -67/-69 own the outage/CRC-bad classes — so -81 = the scan
        # consumed ~64 CRC-good unwanted IDs).
        if run7 >= 40:
            print(f"  ==> -81 MODEL CONFIRMED: {run7} consecutive IDs consumed "
                  "(budget seed is 64; one revolution is 18) — the target was "
                  "skipped on 3+ consecutive revolutions.")
            if par7 in (1, 2):
                print(f"  ==> STROBOSCOPE CONFIRMED: the whole burn saw {par_s} "
                      "sector numbers — the timer-paced re-arm lands past every "
                      "other ID and 18 sectors split into two closed 9-cycles. "
                      "Fix class: break the wake/rotation phase lock.")
            else:
                print("  ==> both parities seen: not a clean stride-2 lock — "
                      "longer-cycle alias, or the skip is positional. Compare "
                      "run vs 64 and look at gap/hunt.")
        elif run7 <= 20 and run7 > 0:
            print(f"  ==> run={run7} at -81: the budget died within ONE "
                  "revolution — contradicts the 64-seed model. Re-derive "
                  "(is +47 being reseeded mid-scan? different caller?).")
        if hunt7 >= 100:
            print(f"  ==> last armed window was {hunt7} ms: a DRY HUNT at -81 "
                  "contradicts the -67 ownership of that class — re-derive.")
    if nz:
        print(f"  ==> VERDICT: driver posted {nz} error completion(s); "
              f"first {sony_err(w[5] >> 16)}, last {sony_err(w[5] & 0xFFFF)}")
    elif unr:
        print(f"  ==> VERDICT: zero driver errors, but {unr} unr event(s). "
              "Disarmed probes are gated since c372f97, so these are REAL "
              "armed events.")

if __name__ == '__main__':
    for path in sys.argv[1:]:
        geom, words = find_and_decode(Image.open(path))
        if words is None:
            print(f"{path}: no HUD marker found")
            continue
        print(f"{path}: HUD at x={geom[0]} y={geom[1]} scale={geom[2]} "
              f"cell={geom[3]}px {geom[4]}-left")
        decode(words)
