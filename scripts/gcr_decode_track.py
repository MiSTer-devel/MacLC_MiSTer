#!/usr/bin/env python3
"""
Phase 0 -- reference GCR decoder: the algebraic inverse of
rtl/floppy_track_encoder.v, and the Phase 0 gate that drives it.

Scans a raw track stream for address fields (D5 AA 96) and data fields
(D5 AA AD), decodes both, and verifies every checksum. It NEVER returns
sector data without a valid checksum -- this exists to prove the format is
understood well enough to build Phase 2's RTL decoder, and a decoder that
repairs bad data instead of rejecting it would defeat that purpose.

Sector layout, read off the encoder's FSM (state -> byte count):
    SYN0 56 | ADDR 10 | SYN1 5 | DHDR 4 | DZRO 12 | DPRE 4 | DATA 683
    | DSUM 4 | DTRL 3 | WAIT 1   = 782 bytes, which is the observed pitch.
Note DZRO is 12 bytes: the RTL comment says "8 zero bytes" but the FSM
counts to 11. Note also the encoder uses an INTERLEAVE OF 2, so sectors come
off the track 0,2,4,... then 1,3,5,... -- decoding is keyed by the sector
number carried in the field, so interleave does not matter here, but a
positional decoder would be wrong.

THE ONE SUBTLETY (this is what MacPlus's Phase 0 got wrong first, and only
the RTL round-trip caught it): nib_xor_0/1/2 are REGISTERS. The si/odata
path reads them combinationally, so it always sees the pre-edge value --
whatever the PREVIOUS occurrence of that cnt phase computed. The nonblocking
update for the current occurrence only becomes visible one cnt-cycle later.
Net effect: group g's four output bytes (cnt=0..3) do not encode group g's
own three data bytes; they encode group (g-1)'s three bytes in full -- top
bits via cnt=0, low six via cnt=1/2/3. Decoding therefore needs a ONE-GROUP
LOOKBACK, not a lookahead split within a group.

PROVENANCE: ported from MacPlus_MiSTer sim/decode_track.py; the encoder RTL
is byte-identical between the cores (see scripts/gcr_common.py).

Usage:
  python scripts/gcr_decode_track.py [--dir scratch/gcr_phase0] [-v]
Exit code 0 = Phase 0 gate PASS, 1 = FAIL.
"""
import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gcr_common import spt_of, rol1_8, SONY_TABLE, REVERSE_SONY_TABLE
from gcr_gen_image import sector_pattern

ADDR_MARK = bytes([0xD5, 0xAA, 0x96])
DATA_MARK = bytes([0xD5, 0xAA, 0xAD])
TRAILER = bytes([0xDE, 0xAA])
N_DZRO = 12
N_SI = 687          # DPRE(4) + DATA(683); cnt runs continuously across the join


class DecodeError(Exception):
    pass


def _lookup(byte_val):
    if byte_val not in REVERSE_SONY_TABLE:
        raise DecodeError("byte 0x%02x is not a valid encoded nibble" % byte_val)
    return REVERSE_SONY_TABLE[byte_val]


def _need(stream, pos, n):
    """Slice n bytes or raise. A truncated stream must produce a clean
    DecodeError, never an IndexError or a silently short slice."""
    chunk = stream[pos:pos + n]
    if len(chunk) != n:
        raise DecodeError("stream truncated: wanted %d bytes at %d, got %d"
                          % (n, pos, len(chunk)))
    return chunk


def decode_address_field(stream, pos):
    if _need(stream, pos, 3) != ADDR_MARK:
        raise DecodeError("bad address prologue")
    track_low, sec_in_tr, track_hi, fmt, checksum = [
        _lookup(b) for b in _need(stream, pos + 3, 5)]
    expect = track_low ^ sec_in_tr ^ track_hi ^ fmt
    if checksum != expect:
        raise DecodeError("address checksum 0x%02x != 0x%02x" % (checksum, expect))
    if _need(stream, pos + 8, 2) != TRAILER:
        raise DecodeError("bad address trailer")
    return dict(track=((track_hi & 1) << 6) | track_low,
                side=(track_hi >> 5) & 1,
                sector=sec_in_tr & 0x3F,
                sides=(fmt >> 5) & 1)


def decode_data_field(stream, pos):
    """Returns (sector, 512 bytes) or raises DecodeError."""
    if _need(stream, pos, 3) != DATA_MARK:
        raise DecodeError("bad data prologue")
    p = pos + 3
    sector = _lookup(_need(stream, p, 1)[0])
    p += 1

    for i, b in enumerate(_need(stream, p, N_DZRO)):
        if b != SONY_TABLE[0]:
            raise DecodeError("DZRO byte %d is 0x%02x, not the sync-zero byte" % (i, b))
    p += N_DZRO

    si = [_lookup(b) for b in _need(stream, p, N_SI)]
    p += N_SI
    groups = [si[i:i + 4] for i in range(0, len(si), 4)]

    # Re-run the encoder's c1/c2/c3 chain, one group behind (see module
    # docstring). prev = (c1, c2, c3) as of just before this group.
    c1 = c2 = c3 = 0
    prev = (0, 0, 0)
    recovered = []

    for g in range(1, len(groups)):
        grp = groups[g]
        if len(grp) < 3:
            break
        s0, s1 = grp[0], grp[1]
        s2 = grp[2] if len(grp) > 2 else None
        s3 = grp[3] if len(grp) > 3 else None
        c1s, c2s, c3s = prev

        nib_xor_0 = (((s0 >> 4) & 3) << 6) | s1
        nib_in_1 = nib_xor_0 ^ rol1_8(c1s)
        new_c1 = rol1_8(c1s)
        acc = c3s + nib_in_1 + ((c1s >> 7) & 1)
        new_c3x, new_c3 = (acc >> 8) & 1, acc & 0xFF
        if len(recovered) < 512:
            recovered.append(nib_in_1)

        if s2 is not None:
            nib_xor_1 = (((s0 >> 2) & 3) << 6) | s2
            nib_in_2 = nib_xor_1 ^ new_c3
            acc = c2s + nib_in_2 + new_c3x
            new_c2x, new_c2 = (acc >> 8) & 1, acc & 0xFF
            if len(recovered) < 512:
                recovered.append(nib_in_2)
        else:
            new_c2, new_c2x = c2s, 0

        if s3 is not None:
            nib_xor_2 = ((s0 & 3) << 6) | s3
            nib_in_3 = nib_xor_2 ^ new_c2
            new_c1 = (new_c1 + nib_in_3 + new_c2x) & 0xFF
            if len(recovered) < 512:
                recovered.append(nib_in_3)

        c1, c2, c3 = new_c1, new_c2, new_c3
        prev = (c1, c2, c3)

    if len(recovered) != 512:
        raise DecodeError("recovered %d bytes, expected 512" % len(recovered))

    got_top, got_c3, got_c2, got_c1 = [_lookup(b) for b in _need(stream, p, 4)]
    p += 4
    want_top = (((c3 >> 6) & 3) << 4) | (((c2 >> 6) & 3) << 2) | ((c1 >> 6) & 3)
    if (got_top, got_c3, got_c2, got_c1) != (want_top, c3 & 0x3F, c2 & 0x3F, c1 & 0x3F):
        raise DecodeError(
            "data checksum (0x%02x,0x%02x,0x%02x,0x%02x) != (0x%02x,0x%02x,0x%02x,0x%02x)"
            % (got_top, got_c3, got_c2, got_c1,
               want_top, c3 & 0x3F, c2 & 0x3F, c1 & 0x3F))

    if _need(stream, p, 2) != TRAILER:
        raise DecodeError("bad data trailer")
    return sector, bytes(recovered)


def find_marks(stream, marker):
    out, start = [], 0
    while True:
        i = stream.find(marker, start)
        if i < 0:
            return out
        out.append(i)
        start = i + 1


def decode_track_stream(stream):
    """Returns ({sector: 512 bytes}, [(pos, reason), ...])."""
    sectors, errors = {}, []
    for pos in find_marks(stream, ADDR_MARK):
        try:
            addr = decode_address_field(stream, pos)
        except DecodeError:
            continue    # not a real address field; D5 AA 96 can occur inside data
        rel = find_marks(stream[pos + 10:pos + 30], DATA_MARK)
        if not rel:
            errors.append((pos, "no data field after address field"))
            continue
        data_pos = pos + 10 + rel[0]
        try:
            sector, data = decode_data_field(stream, data_pos)
        except DecodeError as e:
            errors.append((data_pos, str(e)))
            continue
        if sector != addr["sector"]:
            errors.append((data_pos, "data sector %d != address sector %d"
                           % (sector, addr["sector"])))
            continue
        sectors[sector] = data
    return sectors, errors


def main():
    ap = argparse.ArgumentParser(
        description="Phase 0 gate: RTL encoder dumps -> sectors, byte-exact")
    ap.add_argument("--dir", default="scratch/gcr_phase0")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    d = pathlib.Path(args.dir)
    dumps = sorted(d.glob("track*_side*.bin"),
                   key=lambda p: tuple(int(x) for x in re.findall(r"\d+", p.name)))
    if not dumps:
        print("no track dumps in %s -- run the Icarus bench first" % d)
        return 1

    all_ok, checked = True, 0
    for f in dumps:
        track, side = (int(x) for x in re.findall(r"\d+", f.name))
        sectors, errors = decode_track_stream(f.read_bytes())
        want_spt = spt_of(track)
        ok = True
        for s in range(want_spt):
            want = sector_pattern(track, side, s)
            if s not in sectors:
                print("track %2d side %d: sector %d NOT RECOVERED" % (track, side, s))
                ok = False
            elif sectors[s] != want:
                got = sectors[s]
                bad = next(i for i in range(512) if got[i] != want[i])
                print("track %2d side %d: sector %d MISMATCH at byte %d (got 0x%02x want 0x%02x)"
                      % (track, side, s, bad, got[bad], want[bad]))
                ok = False
        if len(sectors) != want_spt:
            print("track %2d side %d: %d sectors recovered, expected %d"
                  % (track, side, len(sectors), want_spt))
            ok = False
        checked += want_spt
        all_ok = all_ok and ok
        if args.verbose and ok:
            print("track %2d side %d: all %d sectors byte-exact" % (track, side, want_spt))

    print("\n%d track dumps, %d sectors checked" % (len(dumps), checked))
    print("PHASE 0 GATE: PASS" if all_ok else "PHASE 0 GATE: FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
