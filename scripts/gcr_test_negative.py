#!/usr/bin/env python3
"""
Phase 0 -- negative tests for the reference GCR decoder.

A decoder that recovers good sectors but does not reliably REJECT bad ones is
not usable as ground truth for Phase 2's RTL decoder, which must never commit a
corrupt sector into the disk image or back to the SD card. Phase 3 makes that
consequence concrete: a wrongly-accepted field is a silent write of wrong data
to the user's file.

Each case corrupts a copy of a real RTL dump and asserts the SPECIFIC sector
disappears from the recovered set while every other sector survives. That is a
much stronger claim than "an error was reported somewhere near here", which is
all MacPlus's version checked -- its truncation case asserted only
`len(errors) >= 0`, which is vacuously true.

★ ONE REVOLUTION, NOT THE WHOLE CAPTURE. The bench captures 20000 bytes = 2+
revolutions, so every sector appears ~twice and decode_track_stream keeps the
last copy. Corrupting one occurrence would leave the other intact and the
sector would still be "recovered" -- the test would pass while proving nothing.
So each case runs against exactly one revolution (spt * 782 bytes), where every
sector appears exactly once.

Usage:  python scripts/gcr_test_negative.py [--dir scratch/gcr_phase0]
Exit code 0 = all negative tests pass.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gcr_common import spt_of, SONY_TABLE, REVERSE_SONY_TABLE
from gcr_decode_track import (ADDR_MARK, DATA_MARK, N_DZRO, N_SI, DecodeError,
                              decode_data_field, decode_track_stream, find_marks)

SECTOR_PITCH = 782      # SYN0 56 + ADDR 10 + SYN1 5 + DHDR 4 + DZRO 12
                        # + DPRE 4 + DATA 683 + DSUM 4 + DTRL 3 + WAIT 1
PAYLOAD_OFF = 3 + 1 + N_DZRO        # from the D5 AA AD mark to the first si byte
DSUM_OFF = PAYLOAD_OFF + N_SI       # from the mark to the 4-byte checksum


def one_revolution(stream, track):
    """The first full revolution, where each sector appears exactly once."""
    return stream[:spt_of(track) * SECTOR_PITCH]


def first_field(stream):
    """(address_pos, data_pos, sector_number) of the first sector in the stream."""
    addr_pos = find_marks(stream, ADDR_MARK)[0]
    rel = find_marks(stream[addr_pos + 10:addr_pos + 30], DATA_MARK)[0]
    data_pos = addr_pos + 10 + rel
    sector, _ = decode_data_field(stream, data_pos)
    return addr_pos, data_pos, sector


def expect_only_missing(stream, corrupted, target, label):
    """The target sector must vanish; every other sector must survive intact."""
    clean, _ = decode_track_stream(stream)
    dirty, errors = decode_track_stream(corrupted)
    if target not in clean:
        return False, "%s: target sector %d was not in the CLEAN decode" % (label, target)
    if target in dirty:
        return False, "%s: corrupt sector %d was ACCEPTED" % (label, target)
    survivors = set(clean) - {target}
    if set(dirty) != survivors:
        return False, ("%s: collateral damage -- expected %s, got %s"
                       % (label, sorted(survivors), sorted(dirty)))
    for s in survivors:
        if dirty[s] != clean[s]:
            return False, "%s: sector %d changed but should not have" % (label, s)
    if not errors:
        return False, "%s: sector was dropped but no error was reported" % label
    return True, "%s: rejected, %d other sectors intact" % (label, len(survivors))


def case_corrupt_payload(stream):
    _, data_pos, sector = first_field(stream)
    c = bytearray(stream)
    c[data_pos + PAYLOAD_OFF + 100] ^= 0xFF
    return expect_only_missing(stream, bytes(c), sector, "corrupt payload byte")


def case_corrupt_checksum(stream):
    _, data_pos, sector = first_field(stream)
    c = bytearray(stream)
    # swap the first checksum byte for a DIFFERENT valid encoded byte, so the
    # failure is a genuine checksum mismatch rather than an invalid-nibble reject
    cur = c[data_pos + DSUM_OFF]
    c[data_pos + DSUM_OFF] = SONY_TABLE[(REVERSE_SONY_TABLE[cur] + 1) & 0x3F]
    return expect_only_missing(stream, bytes(c), sector, "corrupt checksum byte")


def case_invalid_nibble(stream):
    _, data_pos, sector = first_field(stream)
    c = bytearray(stream)
    c[data_pos + PAYLOAD_OFF + 50] = 0x00   # 0x00 is not in the 64-entry table
    return expect_only_missing(stream, bytes(c), sector, "invalid encoded nibble")


def case_corrupt_address(stream):
    addr_pos, _, sector = first_field(stream)
    c = bytearray(stream)
    c[addr_pos + 7] = SONY_TABLE[(REVERSE_SONY_TABLE[c[addr_pos + 7]] + 1) & 0x3F]
    clean, _ = decode_track_stream(stream)
    dirty, _ = decode_track_stream(bytes(c))
    if sector in dirty:
        return False, "corrupt address checksum: sector %d was ACCEPTED" % sector
    if set(dirty) != set(clean) - {sector}:
        return False, "corrupt address checksum: collateral damage"
    return True, "corrupt address checksum: rejected, field never decoded"


def case_truncated(stream):
    """Cut mid-payload. Must raise a clean DecodeError, not IndexError, and the
    partial sector must not be recovered."""
    _, data_pos, sector = first_field(stream)
    cut = stream[:data_pos + PAYLOAD_OFF + 300]
    try:
        decode_data_field(cut, data_pos)
        return False, "truncated field: decode_data_field ACCEPTED a cut-off field"
    except DecodeError:
        pass
    except Exception as e:                      # noqa: BLE001 - that is the point
        return False, ("truncated field: raised %s instead of DecodeError"
                       % type(e).__name__)
    sectors, _ = decode_track_stream(cut)
    if sector in sectors:
        return False, "truncated field: sector %d recovered from a cut stream" % sector
    return True, "truncated field: clean DecodeError, sector not recovered"


def main():
    ap = argparse.ArgumentParser(description="Phase 0 negative tests")
    ap.add_argument("--dir", default="scratch/gcr_phase0")
    args = ap.parse_args()

    src = pathlib.Path(args.dir) / "track0_side0.bin"
    if not src.exists():
        print("missing %s -- run the Icarus bench first" % src)
        return 1
    stream = one_revolution(src.read_bytes(), track=0)

    # positive control: one revolution must yield exactly spt sectors with no
    # errors at all. If this fails, every rejection below is meaningless.
    sectors, errors = decode_track_stream(stream)
    want = spt_of(0)
    results = [(len(sectors) == want and not errors,
                "positive control: %d/%d sectors, %d errors"
                % (len(sectors), want, len(errors)))]

    for case in (case_corrupt_payload, case_corrupt_checksum, case_invalid_nibble,
                 case_corrupt_address, case_truncated):
        results.append(case(stream))

    all_ok = True
    for ok, msg in results:
        print("%s: %s" % ("PASS" if ok else "FAIL", msg))
        all_ok = all_ok and ok

    print("\nNEGATIVE TESTS: PASS" if all_ok else "\nNEGATIVE TESTS: FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
