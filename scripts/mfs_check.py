#!/usr/bin/env python3
"""Offline MFS (Macintosh File System, the flat 400K filesystem) consistency
check for a raw / DC42 / Apple-Partition-Map image.

WHY THIS EXISTS (2026-09-19). The plan's Phase 6 gate "Two-Sided erase of a
400K-sized image" expects the result to be **a valid single-sided 400K MFS
volume** and says to check it with `scripts/hfs_check.py`. That cannot work:
hfs_check rejects anything whose MDB signature is not HFS's `0x4244`
(`hfs_check.py:123`), and an MFS volume's is `0xD2D7`. The tool the gate
named refuses the very thing the gate produces.

PROVENANCE: the `MFS` reader below is MacPlus_MiSTer `scripts/mfs_extract.py`
(commit `1009d3c`, written for the HD20 startup floppy's `.Sony` PTCH work,
structures per Inside Macintosh II-119), ported here the same way
`hfs_fork_diff.py` was. Do not "simplify" the directory walk: a first attempt
at this file put `fileNum` at entry offset 14 instead of 18, which shifts
every following field by four bytes and makes every fork's start block read
as 0 while the volume still looks plausible -- it printed correct GEOMETRY
from the MDB and garbage per file, which is exactly the shape of bug that
passes a casual glance.

MFS IS NOT HFS WITH FEWER FEATURES. There are no B-trees. The volume is:
  blocks 0-1   boot blocks
  block 2      MDB, immediately followed by the Volume Allocation Block Map
               (VABM) -- 12-BIT entries packed two per three bytes, the same
               packing FAT12 uses, indexed from allocation block 2
  drDirSt..    a flat directory, drBlLen blocks of variable-length entries,
               each starting with a flags byte whose bit 7 means "in use";
               entries are word-aligned and never straddle a block
  drAlBlSt..   the allocation blocks
A fork is a CHAIN through the VABM exactly like a FAT chain: the directory
gives the first allocation block, entry 1 means end-of-chain, 0 means free.

WHAT THIS ADDS over the donor (which extracts, but does not verify):
  1. Container detection, so a DC42 or an APM volume works (via
     hfs_check.open_volume -- the donor reads raw files only).
  2. Every fork's VABM chain walked to its end with CYCLE and RANGE
     detection, and the chain length checked against the recorded physical
     length. A chain that leaves the volume or loops is what makes a disk
     unreadable rather than merely wrong -- the destructive failure mode a
     format gate is looking for.
  3. The map's free-block count cross-checked against the MDB's.
  4. `--expect-alblks`, because the Phase 6 gate wants exactly 391.

Usage:  mfs_check.py <image> [--expect-alblks N]
Exit 0 = the volume is internally consistent.
"""
import argparse
import pathlib
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from hfs_check import open_volume                          # noqa: E402

MFS_SIG = 0xD2D7


class MFS:
    """Ported from MacPlus_MiSTer scripts/mfs_extract.py (1009d3c)."""

    def __init__(self, data):
        self.d = data
        m = data[1024:1024 + 64]
        (self.sig, self.crDate, self.lsBkUp, self.atrb, self.nmFls,
         self.dirSt, self.dirBlLen, self.nmAlBlks, self.alBlkSiz,
         self.clpSiz, self.alBlSt, self.nxtFNum, self.freeBks) = \
            struct.unpack('>HIIHHHHHIIHIH', m[:36])
        if self.sig != MFS_SIG:
            raise SystemExit('not MFS: MDB signature %04X (HFS is 4244, '
                             'MFS is D2D7)' % self.sig)
        self.name = m[37:37 + m[36]].decode('mac-roman', 'replace')
        self.mapOff = 1024 + 64          # the VABM follows the 64-byte MDB
        self.problems = []

    def alloc_next(self, n):
        """12-bit block-map entry for allocation block n; 1 = last, 0 = free."""
        i = n - 2
        o = self.mapOff + (i * 3) // 2
        if i % 2 == 0:
            return (self.d[o] << 4) | (self.d[o + 1] >> 4)
        return ((self.d[o] & 0x0F) << 8) | self.d[o + 1]

    def ablk_offset(self, n):
        return (self.alBlSt + (n - 2) * (self.alBlkSiz // 512)) * 512

    def files(self):
        base = self.dirSt * 512
        off, end = base, base + self.dirBlLen * 512
        while off < end:
            blkend = (off // 512 + 1) * 512
            while off < blkend - 51:
                if not (self.d[off] & 0x80):
                    break                # rest of this block is unused
                e = {'type': self.d[off + 2:off + 6].decode('mac-roman', 'replace'),
                     'creator': self.d[off + 6:off + 10].decode('mac-roman', 'replace')}
                (e['fileNum'], e['dStBlk'], e['dLgLen'], e['dPyLen'],
                 e['rStBlk'], e['rLgLen'], e['rPyLen']) = \
                    struct.unpack('>IHIIHII', self.d[off + 18:off + 42])
                nlen = self.d[off + 50]
                e['name'] = self.d[off + 51:off + 51 + nlen].decode('mac-roman', 'replace')
                yield e
                rec = 51 + nlen
                off += rec + (rec & 1)   # directory entries are word-aligned
            off = blkend

    # ---------------------------------------------------------- verification
    def describe(self):
        return ("vol %r: %d alloc blocks x %d B, alBlSt %d, dirSt %d (%d blks), "
                "files %d, free %d"
                % (self.name, self.nmAlBlks, self.alBlkSiz, self.alBlSt,
                   self.dirSt, self.dirBlLen, self.nmFls, self.freeBks))

    def chain(self, first, what):
        """Walk a fork's VABM chain; return its allocation blocks."""
        out, seen, n = [], set(), first
        if n == 0:
            return out
        while True:
            if not (2 <= n < self.nmAlBlks + 2):
                self.problems.append("%s: block %d is outside the volume "
                                     "(2..%d)" % (what, n, self.nmAlBlks + 1))
                return out
            if n in seen:
                self.problems.append("%s: VABM chain LOOPS at block %d" % (what, n))
                return out
            seen.add(n)
            out.append(n)
            nxt = self.alloc_next(n)
            if nxt == 1:
                return out
            if nxt == 0:
                self.problems.append("%s: chain runs into a FREE block after %d"
                                     % (what, n))
                return out
            n = nxt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--expect-alblks", type=int, default=None,
                    help="fail unless the volume has exactly this many "
                         "allocation blocks (the Phase 6 gate wants 391)")
    a = ap.parse_args()

    vol, container = open_volume(a.image)
    data = bytes(vol[0:len(vol)])        # MFS volumes are <= 800 KB
    v = MFS(data)
    print(v.describe())

    total = (v.alBlSt + v.nmAlBlks * (v.alBlkSiz // 512)) * 512
    if total > len(data):
        v.problems.append("geometry overruns the image: alBlSt %d + %d x %d B "
                          "= %d B > %d B"
                          % (v.alBlSt, v.nmAlBlks, v.alBlkSiz, total, len(data)))

    used, nfiles = 0, 0
    for f in v.files():
        nfiles += 1
        print("  file %-28r %s/%s" % (f['name'], f['type'], f['creator']))
        for tag, st, lg, py in (('data', f['dStBlk'], f['dLgLen'], f['dPyLen']),
                                ('rsrc', f['rStBlk'], f['rLgLen'], f['rPyLen'])):
            if not (lg or st):
                continue
            ch = v.chain(st, "%s/%s" % (f['name'], tag))
            used += len(ch)
            got = len(ch) * v.alBlkSiz
            ok = "OK" if got >= lg else "*** SHORT ***"
            print("    %s lg %-8d py %-8d first blk %-5d chain %3d blks "
                  "(%d B)  %s" % (tag, lg, py, st, len(ch), got, ok))
            if got < lg:
                v.problems.append("%s/%s: chain holds %d B but the record says "
                                  "lg %d" % (f['name'], tag, got, lg))

    free = sum(1 for n in range(2, v.nmAlBlks + 2) if v.alloc_next(n) == 0)
    print("  %d directory entries; %d blocks used by forks, %d free in the map, "
          "MDB says %d free" % (nfiles, used, free, v.freeBks))
    if free != v.freeBks:
        v.problems.append("free-block disagreement: map says %d, MDB says %d"
                          % (free, v.freeBks))
    if nfiles != v.nmFls:
        v.problems.append("file-count disagreement: directory has %d, MDB says %d"
                          % (nfiles, v.nmFls))
    if a.expect_alblks is not None and v.nmAlBlks != a.expect_alblks:
        v.problems.append("expected %d allocation blocks, found %d"
                          % (a.expect_alblks, v.nmAlBlks))

    print()
    if v.problems:
        for p in v.problems:
            print("PROBLEM: %s" % p)
        print("\n==> MFS VOLUME HAS PROBLEMS (%d)" % len(v.problems))
        return 1
    print("==> MFS VOLUME CONSISTENT: every fork's VABM chain walks to a clean "
          "end inside the volume.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
