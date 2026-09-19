#!/usr/bin/env python3
"""
Phase 0 -- synthetic 800K disk image for the floppy_track_encoder.v harness.

Replicates the encoder's own address arithmetic (soff/spt/addr from
rtl/floppy_track_encoder.v) so the memory image handed to the testbench is
laid out exactly the way the RTL fetches it: track-major, side-minor,
sides=1 (double-sided), i.e. an 80-track/2-side/512B-sector Sony 800K disk
(1600 sectors, 819200 bytes).

Each sector's 512 bytes are a deterministic SELF-IDENTIFYING pattern --
track, side and sector in the first three bytes, a keyed counter after that
-- so a decode failure names the sector and the byte within it instead of
just saying "mismatch". A generic counter would let a wrong-sector fetch
decode "correctly"; this cannot.

Writes to scratch/ (gitignored), never into the repo proper.

PROVENANCE: ported from MacPlus_MiSTer sim/gen_image.py; see
scripts/gcr_common.py for why the port is sound.

Usage:  python scripts/gcr_gen_image.py [--outdir scratch/gcr_phase0] [--hex]
        python scripts/gcr_gen_image.py --hex --single   # 400K: image400.bin/.hex

--single (added 2026-09-16) builds the SINGLE-SIDED 400K layout the encoder
and decoder use with sides=0: soff*512 with no doubling, side 0 only, 800
sectors, 409600 bytes. It exists because 400K writes had no bench at all --
both GCR benches hard-coded sides=1 -- and the double-sided image cannot
stand in: its self-identifying bytes describe the tuple double-sided
geometry puts at that address, so under sides=0 every track but 0 reads
"payload wrong" while the address check passes.
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gcr_common import spt_of, soff_of, IMAGE_SIZE_800K, TOTAL_SECTORS_PER_SIDE

SIDES_PARAM = 1  # the encoder's `sides` port for this synthetic disk; --single sets 0

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "scratch" / "gcr_phase0"


def addr_of(track: int, side: int, sector: int, offset: int) -> int:
    """Byte address the RTL will fetch for (track, side, sector, offset)."""
    base = soff_of(track) * 512
    if SIDES_PARAM:
        base += soff_of(track) * 512
    if side:
        base += spt_of(track) * 512
    return base + sector * 512 + offset


def sector_pattern(track: int, side: int, sector: int) -> bytes:
    b = bytearray(512)
    b[0] = track & 0xFF
    b[1] = side & 0xFF
    b[2] = sector & 0xFF
    for i in range(3, 512):
        b[i] = (track * 7 + side * 13 + sector * 29 + i) & 0xFF
    return bytes(b)


def build_image() -> bytearray:
    # 0xEE poison: a sector still holding it was never written, which means
    # addr_of and the zone geometry disagree about where that sector lives.
    img = bytearray(b"\xee" * (IMAGE_SIZE_800K if SIDES_PARAM else IMAGE_SIZE_800K // 2))
    nsides = 2 if SIDES_PARAM else 1
    written = 0
    for track in range(80):
        for side in range(nsides):
            for sector in range(spt_of(track)):
                a = addr_of(track, side, sector, 0)
                if a + 512 > len(img):
                    raise RuntimeError(
                        f"track {track} side {side} sector {sector} addresses past end of image")
                img[a:a + 512] = sector_pattern(track, side, sector)
                written += 1
    if written != TOTAL_SECTORS_PER_SIDE * nsides:
        raise RuntimeError(f"wrote {written} sectors, expected {TOTAL_SECTORS_PER_SIDE * nsides}")
    if b"\xee" * 512 in bytes(img):
        raise RuntimeError("a 512-byte run of poison survived: the geometry leaves a hole")
    return img


def self_check() -> None:
    """soff must advance by exactly one track's worth of sectors per track."""
    for t in range(79):
        step = soff_of(t + 1) - soff_of(t)
        if step != spt_of(t):
            raise RuntimeError(f"soff step at track {t}: {step} != spt {spt_of(t)}")
    if soff_of(80) != TOTAL_SECTORS_PER_SIDE:
        raise RuntimeError(f"soff(80) = {soff_of(80)}, expected {TOTAL_SECTORS_PER_SIDE}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--outdir", default=str(DEFAULT_OUT))
    ap.add_argument("--hex", action="store_true",
                    help="also write image.hex for $readmemh (the RTL testbench needs it)")
    ap.add_argument("--single", action="store_true",
                    help="single-sided 400K layout (sides=0); writes image400.bin/.hex")
    args = ap.parse_args()
    global SIDES_PARAM
    SIDES_PARAM = 0 if args.single else 1
    stem = "image400" if args.single else "image"

    self_check()
    out = pathlib.Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)

    img = build_image()
    (out / f"{stem}.bin").write_bytes(img)
    print(f"image: {len(img)} bytes ({len(img)/1024:.1f} KB) -> {out / (stem + '.bin')}")

    if args.hex:
        hex_path = out / f"{stem}.hex"
        with hex_path.open("w", newline="\n") as f:
            f.write("".join(f"{b:02x}\n" for b in img))
        print(f"hex:   {hex_path.stat().st_size} bytes -> {hex_path}")

    print(f"geometry self-check OK: soff(80) = {soff_of(80)} sectors/side")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
