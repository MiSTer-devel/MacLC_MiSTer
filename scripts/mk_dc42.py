#!/usr/bin/env python3
"""Wrap a raw Mac floppy image in a DiskCopy 4.2 container.

WHY THIS EXISTS (2026-09-15, docs/floppy_write_plan.md Phase 1 gate): the gate
wants a floppy mounted BOTH raw and as DC42, and the only difference that should
survive the core's loader is the 84-byte header it strips. A disk that boots raw
and then boots DC42 makes that an exact comparison instead of two separate
observations of two different disks. No LC-bootable DC42 existed to test with --
every DC42 to hand is either 1985-87 era, a non-bootable application disk, or
truncated -- so this mints one from a raw image that is known to boot.

THE TAG SECTION IS DELIBERATE, and it is the whole point for 800K/400K. A DC42
may legally carry tagSize 0, and that would be the easy thing to emit. But the
core must NOT decide geometry from size: a DC42's payload includes the tags that
trail the sector data, so an 800K DC42 is 838400 payload bytes, not 819200, and
matches no size test (rtl/floppy_loader.v, the dc42_fmt comment). Emitting
tagSize 0 would make the payload exactly 819200 -- the size test would pass, and
a regression back to size-based geometry would be MASKED by the very image
meant to catch it. So the tags are written, zero-filled: HFS does not read them,
and their presence is what keeps the test honest.

CHECKSUMS ARE REAL. The core ignores them (it reads only the name length, byte
0x50 and the word-41 magic), but a half-formed container would fail in any other
tool and make a bad image look like a core bug later. The algorithm below --
16-bit big-endian add then rotate the 32-bit sum right by one, with the TAG
checksum skipping the first 12 bytes -- was verified against four known-good
DC42 files on 2026-09-15 before this script was written, matching data and tag
checksums exactly. Do not "tidy" it without re-running that check.

Usage:
  python scripts/mk_dc42.py <raw image> <output.dc42|.img|.dsk> [--name NAME]

Verifies its own output before exiting; exit 0 means the file round-trips.
"""
import argparse
import os
import struct
import sys

# raw payload size -> (encoding byte 0x50, format byte 0x51, tag bytes)
# Values confirmed against real DC42 images: 400K fmt 0x02 / 9600 tag bytes,
# 800K fmt 0x22 / 19200, 1440K fmt 0x02 / no tags.
GEOMETRY = {
    409600:  (0x00, 0x02,   800 * 12, "400K GCR"),
    819200:  (0x01, 0x22,  1600 * 12, "800K GCR"),
    737280:  (0x02, 0x22,          0, "720K MFM"),
    1474560: (0x03, 0x02,          0, "1440K MFM"),
}


def dc42_checksum(b: bytes) -> int:
    """DiskCopy 4.2 checksum: add each big-endian 16-bit word into a 32-bit
    accumulator, rotating the accumulator right by one bit after each add."""
    s = 0
    for i in range(0, len(b) - 1, 2):
        s = (s + ((b[i] << 8) | b[i + 1])) & 0xFFFFFFFF
        s = ((s >> 1) | ((s & 1) << 31)) & 0xFFFFFFFF
    return s


def volume_name(data: bytes) -> str:
    """The HFS volume name from the MDB, so the DC42 name matches the disk."""
    mdb = data[1024:1024 + 64]
    if mdb[0:2] != b'BD':
        return ""
    n = mdb[36]
    if not 1 <= n <= 27:
        return ""
    return mdb[37:37 + n].decode('mac-roman', errors='replace')


def build(raw: bytes, name: str) -> bytes:
    if len(raw) not in GEOMETRY:
        raise SystemExit("not a recognised floppy size: %d bytes (want one of %s)"
                         % (len(raw), ", ".join(str(k) for k in sorted(GEOMETRY))))
    enc, fmt, tag_len, label = GEOMETRY[len(raw)]

    nb = name.encode('mac-roman', errors='replace')[:63]
    hdr = bytearray(84)
    hdr[0] = len(nb)
    hdr[1:1 + len(nb)] = nb
    tags = b'\x00' * tag_len
    struct.pack_into('>IIII', hdr, 64,
                     len(raw), tag_len,
                     dc42_checksum(raw),
                     dc42_checksum(tags[12:]) if tag_len > 12 else 0)
    hdr[0x50] = enc
    hdr[0x51] = fmt
    hdr[0x52] = 0x01          # the 0x0100 private word; the core's detector
    hdr[0x53] = 0x00          # reads this as word 41 == 0x0001
    return bytes(hdr) + raw + tags, label


def verify(path: str, raw: bytes) -> None:
    """Re-read the file and apply the CORE's detection rule, not our own."""
    d = open(path, 'rb').read()
    ok = 1 <= d[0] <= 63 and d[82] == 0x01 and d[83] == 0x00
    if not ok:
        raise SystemExit("VERIFY FAILED: the core's detector would not see DC42")
    dsz, tsz, dck, tck = struct.unpack('>IIII', d[64:80])
    if 84 + dsz + tsz != len(d):
        raise SystemExit("VERIFY FAILED: header sizes do not account for the file")
    if d[84:84 + dsz] != raw:
        raise SystemExit("VERIFY FAILED: payload differs from the source image")
    if dc42_checksum(d[84:84 + dsz]) != dck:
        raise SystemExit("VERIFY FAILED: data checksum")
    tags = d[84 + dsz:84 + dsz + tsz]
    want = dc42_checksum(tags[12:]) if tsz > 12 else 0
    if want != tck:
        raise SystemExit("VERIFY FAILED: tag checksum")


def main():
    ap = argparse.ArgumentParser(description="wrap a raw floppy image as DiskCopy 4.2")
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--name", help="DC42 image name (default: the HFS volume name)")
    a = ap.parse_args()

    raw = open(a.source, 'rb').read()
    name = a.name or volume_name(raw) or os.path.splitext(os.path.basename(a.source))[0]
    blob, label = build(raw, name)
    with open(a.output, 'wb') as fh:
        fh.write(blob)
    verify(a.output, raw)

    print("%s -> %s" % (a.source, a.output))
    print("  %s, name %r, %d raw + 84 header + %d tag = %d bytes"
          % (label, name, len(raw), len(blob) - 84 - len(raw), len(blob)))
    print("  payload the core will present: %d bytes (matches no raw size test -- intended)"
          % (len(blob) - 84))
    print("  verified: core detector sees DC42, payload identical, both checksums good")


if __name__ == "__main__":
    main()
