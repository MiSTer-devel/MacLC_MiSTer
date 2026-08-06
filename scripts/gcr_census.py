#!/usr/bin/env python3
"""Decode + validate the Apple GCR (400/800K) byte stream captured by
verilator/tb_gcr_read.v.

The address field is:  D5 AA 96 | e(trk_lo) e(sec) e(trk_hi) e(fmt) e(cksum) | DE AA
with cksum = trk_lo ^ sec ^ trk_hi ^ fmt, all five 6-bit values 6-and-2
encoded through the Apple "disk byte" alphabet. Because the encoder computes
that checksum over exactly the values it emits, a field that arrives with a
BAD checksum proves the byte stream was damaged in transit — dropped,
duplicated or mis-latched — not that the encoder built it wrong. That is the
whole point of this script: it separates the two.

Usage: gcr_census.py <stream.txt> [more.txt ...]
"""
import sys

# Canonical Apple 6-and-2 "disk byte" alphabet (64 entries), same table as
# rtl/floppy_track_encoder.v's sony_to_disk_byte.
DISK_BYTES = [
    0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6,
    0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
    0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC,
    0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
    0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE,
    0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
    0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6,
    0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
]
DEC = {b: i for i, b in enumerate(DISK_BYTES)}


def load(path):
    out = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        for tok in line.split():
            try:
                out.append(int(tok, 16))
            except ValueError:
                pass
    return out


def census(path):
    s = load(path)
    print(f"== {path}: {len(s)} bytes captured")
    if not s:
        print("   (empty — the reader never saw a valid byte)")
        return

    fields, good, bad, undec = 0, 0, 0, 0
    seen_sectors, problems = [], []
    i = 0
    while i < len(s) - 9:
        if s[i] == 0xD5 and s[i + 1] == 0xAA and s[i + 2] == 0x96:
            fields += 1
            raw = s[i + 3:i + 8]
            if any(b not in DEC for b in raw):
                undec += 1
                problems.append((fields, 'non-alphabet byte in field',
                                 ' '.join(f'{b:02x}' for b in raw)))
                i += 3
                continue
            trk_lo, sec, trk_hi, fmt, cks = (DEC[b] for b in raw)
            want = trk_lo ^ sec ^ trk_hi ^ fmt
            trailer_ok = (s[i + 8] == 0xDE and s[i + 9] == 0xAA)
            if cks == want and trailer_ok:
                good += 1
                seen_sectors.append((trk_lo | ((trk_hi & 1) << 6),
                                     (trk_hi >> 5) & 1, sec, fmt))
            else:
                bad += 1
                why = []
                if cks != want:
                    why.append(f'cksum {cks:#04x} != {want:#04x}')
                if not trailer_ok:
                    why.append(f'trailer {s[i+8]:02x} {s[i+9]:02x} != de aa')
                problems.append((fields,
                                 f'trk{trk_lo} sec{sec} hi{trk_hi:#04x} fmt{fmt:#04x}',
                                 '; '.join(why)))
            i += 10
        else:
            i += 1

    print(f"   address fields: {fields}   good: {good}   bad-checksum: {bad}"
          f"   undecodable: {undec}")
    if seen_sectors:
        trks = sorted({t for t, _, _, _ in seen_sectors})
        sides = sorted({h for _, h, _, _ in seen_sectors})
        secs = sorted({x for _, _, x, _ in seen_sectors})
        fmts = sorted({f for _, _, _, f in seen_sectors})
        print(f"   tracks {trks}  sides {sides}  fmt {[hex(f) for f in fmts]}")
        print(f"   sectors seen ({len(secs)}): {secs}")
        order = [x for _, _, x, _ in seen_sectors][:14]
        print(f"   sector order: {order}")
    for n, what, why in problems[:8]:
        print(f"   ** field {n}: {what} -- {why}")

    if fields == 0:
        print("   ==> NO address marks found: the reader never saw D5 AA 96.")
    elif bad == 0 and undec == 0:
        print("   ==> CLEAN: every address field survived intact at this "
              "poll rate.")
    else:
        print(f"   ==> DAMAGED: {bad + undec}/{fields} fields corrupt. The "
              "encoder builds these self-consistently, so the stream is "
              "being damaged in delivery.")


for p in sys.argv[1:]:
    census(p)
