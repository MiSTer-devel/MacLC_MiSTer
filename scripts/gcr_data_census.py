#!/usr/bin/env python3
"""Decode + verify the DATA fields of the GCR stream captured by
verilator/tb_gcr_read.v (with the 2026-08-05 track/side sweep extension).

gcr_census.py already proves the ADDRESS fields are intact; this script goes
after the wrong-but-checksum-valid class: the data-field checksum is computed
by floppy_track_encoder.v over exactly the bytes it emits, so a mis-mapped
image fetch still validates perfectly and the Sony driver reports success
with wrong content.  The testbench image is self-addressing (512-byte block B
holds [B.lo, B.hi, (B+j)&0xFF ...]), so for every decoded sector this script
can state:
  - which (track, side, sector) the address field advertises,
  - which image offset the standard 800K GCR layout says that sector holds,
  - which image block the decoded payload ACTUALLY came from.

Layout law (two-sided 800K): offset(T,H,S) = (2*soff(T) + H*spt(T) + S)*512
  spt  = 12/11/10/9/8 for tracks 0-15/16-31/32-47/48-63/64-79
  soff = cumulative sectors of all previous tracks, one side.

Data field: D5 AA AD | e(sector) | 699 six-bit payload (12 zero tag bytes +
512 data, Sony 6:2 with the 3-byte rolling checksum) | 4 checksum bytes |
DE AA.  The decoder below mirrors the RTL nibbler exactly (rol-c1 carry into
c3, c3 carry into c2, c2 carry into c1).

Usage: gcr_data_census.py <stream.txt> [more.txt ...]
Exit code: 0 if every decoded data field is clean AND content-correct.
"""
import sys

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

PAYLOAD_SIX = 699           # six-bit values carrying 12 tags + 512 data
PAYLOAD_BYTES = 524


def spt_of(t):
    return [12, 11, 10, 9, 8][min(t >> 4, 4)]


def soff_of(t):
    s = 0
    for zone, n in enumerate([12, 11, 10, 9, 8]):
        lo, hi = zone * 16, zone * 16 + 16
        if t <= lo:
            break
        s += n * (min(t, hi) - lo)
    return s


def expected_block(track, side, sector, sides=1):
    """floppy_track_encoder.v's address arithmetic. `sides`=1 (800K, two-sided)
    counts each track's sectors on BOTH surfaces before the next track; `sides`=0
    (400K) is a single spiral with no side term."""
    if sides:
        return 2 * soff_of(track) + side * spt_of(track) + sector
    return soff_of(track) + sector


def pattern_block(b):
    """The testbench's self-addressing 512-byte block."""
    out = bytearray(512)
    out[0] = b & 0xFF
    out[1] = (b >> 8) & 0xFF
    for j in range(2, 512):
        out[j] = (b + j) & 0xFF
    return bytes(out)


def sony_decode(six):
    """six = 699 six-bit values -> (524 bytes, c1, c2, c3). Mirrors the RTL."""
    c1 = c2 = c3 = 0
    out = bytearray()
    i = 0
    while len(out) < PAYLOAD_BYTES and i < len(six):
        tops = six[i]
        i += 1
        for k in range(3):
            if len(out) >= PAYLOAD_BYTES or i >= len(six):
                break
            x = six[i] | (((tops >> (4 - 2 * k)) & 3) << 6)
            i += 1
            if k == 0:
                carry = (c1 >> 7) & 1
                c1 = ((c1 << 1) | carry) & 0xFF
                b = x ^ c1
                t = c3 + b + carry
                c3, c3x = t & 0xFF, (t >> 8) & 1
            elif k == 1:
                b = x ^ c3
                t = c2 + b + c3x
                c2, c2x = t & 0xFF, (t >> 8) & 1
            else:
                b = x ^ c2
                c1 = (c1 + b + c2x) & 0xFF
            out.append(b)
    return bytes(out), c1, c2, c3


def load(path):
    hdr, out = [], []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line.startswith('#'):
            hdr.append(line)
            continue
        for tok in line.split():
            try:
                out.append(int(tok, 16))
            except ValueError:
                pass
    return hdr, out


def census(path):
    hdr, s = load(path)
    want_track = want_side = None
    for h in hdr:
        if 'track=' in h and 'side=' in h:
            try:
                want_track = int(h.split('track=')[1].split()[0])
                want_side = int(h.split('side=')[1].split()[0])
            except ValueError:
                pass
    print(f"== {path}: {len(s)} bytes, TB requested track={want_track} "
          f"side={want_side}")

    # fmt in the address field encodes it: 0x22 = double-sided, 0x02 = single
    sides = 1
    ok = True
    naddr = ndata = ngood = 0
    last_addr = None            # (track, side, sector) of last good addr field
    i = 0
    while i < len(s) - 10:
        if s[i] == 0xD5 and s[i + 1] == 0xAA and s[i + 2] == 0x96:
            raw = s[i + 3:i + 8]
            if all(b in DEC for b in raw):
                trk_lo, sec, trk_hi, fmt, cks = (DEC[b] for b in raw)
                if cks == trk_lo ^ sec ^ trk_hi ^ fmt and \
                   s[i + 8] == 0xDE and s[i + 9] == 0xAA:
                    naddr += 1
                    track = trk_lo | ((trk_hi & 1) << 6)
                    side = (trk_hi >> 5) & 1
                    sides = 1 if (fmt & 0x20) else 0
                    last_addr = (track, side, sec)
                    if want_track is not None and \
                       (track != want_track or side != want_side):
                        ok = False
                        print(f"   ** addr field advertises trk{track} "
                              f"side{side} but TB parked on "
                              f"trk{want_track} side{want_side}")
            i += 10
            continue
        if s[i] == 0xD5 and s[i + 1] == 0xAA and s[i + 2] == 0xAD:
            end = i + 3 + 1 + PAYLOAD_SIX + 4 + 2
            if end > len(s):
                break               # truncated tail capture
            ndata += 1
            fld = s[i + 3:end]
            if not all(b in DEC for b in fld[:1 + PAYLOAD_SIX + 4]):
                ok = False
                print(f"   ** data field {ndata}: non-alphabet byte")
                i += 3
                continue
            dsec = DEC[fld[0]]
            six = [DEC[b] for b in fld[1:1 + PAYLOAD_SIX]]
            csum = [DEC[b] for b in fld[1 + PAYLOAD_SIX:1 + PAYLOAD_SIX + 4]]
            trailer_ok = (fld[-2] == 0xDE and fld[-1] == 0xAA)
            payload, c1, c2, c3 = sony_decode(six)
            w3 = csum[1] | (((csum[0] >> 4) & 3) << 6)
            w2 = csum[2] | (((csum[0] >> 2) & 3) << 6)
            w1 = csum[3] | ((csum[0] & 3) << 6)
            cks_ok = (c1 == w1 and c2 == w2 and c3 == w3)
            tags, data = payload[:12], payload[12:]

            where = ''
            if last_addr is None:
                where = 'no preceding addr field'
                verdict = 'ORPHAN'
            else:
                track, side, asec = last_addr
                blk = expected_block(track, side, dsec, sides)
                exp = pattern_block(blk)
                claimed = data[0] | (data[1] << 8)
                if dsec != asec:
                    ok = False
                    verdict = 'SECTOR-MISMATCH'
                    where = f'addr field sec{asec} but data header sec{dsec}'
                elif not cks_ok or not trailer_ok:
                    ok = False
                    verdict = 'BAD-CHECKSUM'
                    where = (f'c1c2c3 {c1:02x}{c2:02x}{c3:02x} != '
                             f'{w1:02x}{w2:02x}{w3:02x} trailer_ok={trailer_ok}')
                elif any(tags):
                    ok = False
                    verdict = 'TAGS-NONZERO'
                    where = ' '.join(f'{b:02x}' for b in tags)
                elif data != exp:
                    ok = False
                    verdict = 'WRONG-CONTENT'
                    ndiff = sum(a != b for a, b in zip(data, exp))
                    where = (f'expected image block {blk} '
                             f'(offset {blk*512}), payload claims block '
                             f'{claimed} ({ndiff}/512 bytes differ)')
                else:
                    ngood += 1
                    verdict = 'OK'
                    where = f'trk{track} side{side} sec{dsec} = block {blk}'
            if verdict != 'OK':
                print(f"   ** data field {ndata}: {verdict} -- {where}")
            i = end
            continue
        i += 1

    print(f"   addr fields: {naddr}  data fields: {ndata}  "
          f"content-verified OK: {ngood}")
    if ndata == 0:
        ok = False
        print("   ==> NO data fields found")
    elif ok:
        print("   ==> CLEAN: every data field checksum-valid, tags zero, "
              "content at the standard-layout offset.")
    else:
        print("   ==> FAIL: see ** lines above.")
    return ok


all_ok = True
for p in sys.argv[1:]:
    all_ok = census(p) and all_ok
sys.exit(0 if all_ok else 1)
