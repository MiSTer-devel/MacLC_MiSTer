#!/usr/bin/env python3
"""Byte-for-byte fork comparison between a WRITTEN volume and its SOURCE.

    python scripts/hfs_fork_diff.py <written image> <source volume> [substring]

Walks the catalog of the WRITTEN volume (a floppy image this core wrote to)
and, for every file on it, finds the file of the same name on the SOURCE
volume the copy came from, then compares both forks byte for byte.

THIS IS THE STRONG HALF OF THE FLOPPY-WRITE GATE. `hfs_check.py` passes on a
volume whose sectors carry the WRONG CONTENT -- the card-sourced Phase 4
writer produced exactly that on 2026-09-16: a consistent volume with four
silently corrupt sectors inside a copied application. A structural check
cannot see it; only the source comparison can.

Ported 2026-09-18 from MacPlus_MiSTer's script of the same name (commit
e45a231) for the Stage 2 MFM soak, on this repo's `hfs_check.py` instead of
MacPlus's `hfs_integrity.py` -- which matters: hfs_check walks the
EXTENTS-OVERFLOW tree, so forks spanning more than three extents are compared
here rather than skipped, and a disk filled to capacity (the point of a soak)
is precisely where fragmented forks appear.

Containers are detected, not declared: DiskCopy 4.2 (84-byte header stripped,
and its stored data checksum verified against the payload), an Apple
Partition Map volume such as `boot.vhd` (the first Apple_HFS partition), or a
raw image. Large files are read lazily, so a source may be an 80 MB .vhd.

RESOURCE-FORK HEADER BYTES $30..$7D ARE THE FILE MANAGER'S, NOT THE FILE'S.
When a resource fork is created the system writes a "directory copy" of the
catalog entry (name, type, creator, out of an uncleared buffer) into the
header's reserved area, so a Finder copy differs there from its original BY
DESIGN (Apple Technical Note 74). Those bytes are reported, never counted as
a difference. Learned the hard way on MacPlus, 2026-09-17, at a cost of a day.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Container detection (raw / DC42 / Apple Partition Map) and the lazy file
# view live in hfs_check.py so both tools share one implementation.
from hfs_check import (HFS, be16, be32, pstr,       # noqa: E402,F401
                       LazySlice, dc42_checksum, open_volume)


def catalog(v):
    """{full path: (fileid, dlg, dpy, dext, rlg, rpy, rext)}."""
    nodes = v.btree_nodes(v.ct_ext, v.ct_size, 4, "catalog")
    if nodes is None:
        raise SystemExit("catalog B-tree unreadable")
    dirs = {}
    files = {}
    for rec in v.walk_leaves(nodes, "catalog") or []:
        klen = rec[0]
        k = 1 + klen
        if k & 1:
            k += 1                      # record data is word-aligned
        parent = be32(rec, 2)
        name = pstr(rec, 6, 31)
        d = rec[k:]
        if not d:
            continue
        if d[0] == 1:                   # folder record
            dirs[be32(d, 6)] = (parent, name)
        elif d[0] == 2:                 # file record
            files[(parent, name)] = (be32(d, 20),
                                     be32(d, 26), be32(d, 30), HFS.extrec(d, 74),
                                     be32(d, 36), be32(d, 40), HFS.extrec(d, 86))

    def path(parent, name):
        parts = [name]
        seen = set()
        while parent not in (1, 2) and parent in dirs and parent not in seen:
            seen.add(parent)
            parent, n = dirs[parent]
            parts.append(n)
        return "/".join(reversed(parts))

    return {path(p, n): rec for (p, n), rec in files.items()}


def forks(v, rec):
    """(data bytes, rsrc bytes), each None if unreadable. Logical lengths."""
    fid, dlg, dpy, dext, rlg, rpy, rext = rec
    d = v.fork_bytes(dext, dpy, fid, 0, "data fork") if dpy else b''
    r = v.fork_bytes(rext, rpy, fid, 0xFF, "rsrc fork") if rpy else b''
    return (None if d is None else d[:dlg],
            None if r is None else r[:rlg])


def rsrc_same(a, b):
    """Is this resource fork the same FILE, allowing for the Resource Manager's
    own bookkeeping?

    RESOURCE DATA IS COMPARED EXACTLY AND IS NEVER EXCUSED. Only two regions
    may differ, because neither is file content and both get rewritten by the
    system on an ordinary copy:

      * the header's `$30..$7D` reserved area — the File Manager's "directory
        copy" of the catalog entry (Apple TN 74);
      * the resource MAP — its reference-list entries carry a 4-byte in-memory
        HANDLE field, so a file that has been opened since it was written
        differs there from its original at a 12-byte stride.

    Seen for real 2026-09-18 on `System Picker 1.1a3` during the MFM fill: 54
    bytes differed, 52 of them in the map at exactly that stride, 2 in the
    header window, and **0 of 37 482 bytes of resource data**. The blanket
    all-or-nothing mask this replaced called that a FAILURE.

    Keeping data exact is what preserves sensitivity: a dropped CRC byte
    corrupts a contiguous 512-byte sector, which lands in resource data and
    still fails here.
    """
    if a == b:
        return True, ""
    if len(a) != len(b) or len(a) < 16:
        return False, ""
    try:
        do, mo, dl, ml = struct.unpack('>IIII', a[:16])
    except struct.error:
        return False, ""
    # A differing layout means a different file, not bookkeeping.
    if a[:16] != b[:16] or do + dl > len(a) or mo + ml > len(a):
        return False, ""
    diffs = [i for i in range(len(a)) if a[i] != b[i]]
    if any(do <= i < do + dl for i in diffs):
        return False, ""                      # resource DATA differs: real
    hdr = sum(1 for i in diffs if 0x30 <= i <= 0x7D)
    mapd = [i for i in diffs if mo <= i < mo + ml]
    if hdr + len(mapd) != len(diffs):
        return False, ""                      # somewhere else entirely: real
    # SHAPE, not just region. Bookkeeping is scattered SHORT runs — a handle is
    # 4 bytes, so 8 covers a field pair. A corrupt sector landing in the map
    # would be one long contiguous run, and the map can be larger than 512 B,
    # so without this the excuse would swallow exactly the defect we are
    # hunting.
    longest = 0
    run = 0
    prev = None
    for i in mapd:
        run = run + 1 if prev is not None and i == prev + 1 else 1
        longest = max(longest, run)
        prev = i
    if longest > 8:
        return False, ""
    return True, ("  [%d B of Resource-Manager bookkeeping differ: %d in the "
                  "$30-$7D header window, %d in the resource map in runs of "
                  "<=%d B; resource DATA identical]"
                  % (len(diffs), hdr, len(mapd), longest))


# Files the Finder/System mint ON the target volume. They have no original to
# compare against, and a soak's freshly-formatted disk grows several. They are
# counted and named separately rather than silently skipped: "no file of that
# name on the source" must keep meaning something went wrong.
GENERATED = re.compile(
    r'^(Desktop|Desktop DB|Desktop DF|Icon\r?|DesktopPrinters DB|'
    r'OpenFolderListDF|TheFindByContentFolder|Move&Rename)$')
GENERATED_DIR = re.compile(r'^(TheVolumeSettingsFolder|Trash)(/|$)')


def main(written, source, needle=""):
    print("=== written: %s" % written)
    wv = HFS(open_volume(written)[0])
    print("=== source:  %s" % source)
    sv = HFS(open_volume(source)[0])

    wf, sf = catalog(wv), catalog(sv)
    by_name = {}
    for p, rec in sf.items():
        by_name.setdefault(p.rsplit("/", 1)[-1], []).append((p, rec))
    print("\nwritten volume %r: %d files    source volume %r: %d files"
          % (wv.volname, len(wf), sv.volname, len(sf)))

    ok = bad = skipped = generated = 0
    for p in sorted(wf):
        name = p.rsplit("/", 1)[-1]
        if needle and needle not in p:
            continue
        if GENERATED.match(name) or GENERATED_DIR.match(p):
            print("  %-46s  (Finder-generated on the target, no original)" % p)
            generated += 1
            continue
        cands = by_name.get(name, [])
        if not cands:
            print("  %-46s  NO FILE OF THAT NAME ON THE SOURCE" % p)
            skipped += 1
            continue
        wd, wr = forks(wv, wf[p])
        # Several files on the source may share a name (an alias in Recent
        # Applications outranked the real application once). Try the ones
        # whose fork LENGTHS match first, so the reported verdict is the
        # best candidate rather than whichever the catalog walk met first.
        want = (len(wd or b''), len(wr or b''))
        cands = sorted(cands, key=lambda c: (c[1][1], c[1][4]) != want)
        verdicts = []
        for sp, srec in cands:
            sd, sr = forks(sv, srec)
            if None in (wd, wr, sd, sr):
                verdicts.append("%s: a fork would not read (see problems above)" % sp)
                continue
            same_r, note = rsrc_same(wr, sr)
            if wd == sd and same_r:
                verdicts = ["IDENTICAL to %s  (data %d B, rsrc %d B)%s"
                            % (sp, len(wd), len(wr), note)]
                break
            verdicts.append("%s: data %s (%d vs %d B), rsrc %s (%d vs %d B)" % (
                sp,
                "same" if wd == sd else "DIFFERS", len(wd), len(sd),
                "same" if same_r else "DIFFERS", len(wr), len(sr)))
        v = verdicts[0]
        if len(cands) > 1 and not v.startswith("IDENTICAL"):
            v += "   (best of %d same-named source files)" % len(cands)
        if v.startswith("IDENTICAL"):
            ok += 1
        elif "would not read" in v:
            skipped += 1
        else:
            bad += 1
        print("  %-46s  %s" % (p, v))

    print("\n%d identical, %d differ, %d not compared, %d Finder-generated"
          % (ok, bad, skipped, generated))
    if skipped:
        print("NOTE: %d file(s) on the written volume have no counterpart on the"
              " source. That is not counted as a difference, but on a soak it is"
              " worth a look: a damaged catalog can invent a name." % skipped)
    print("FORK DIFF: %s" % ("PASS" if bad == 0 and ok > 0 else "FAIL"))
    return 0 if (bad == 0 and ok > 0) else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2],
                  sys.argv[3] if len(sys.argv) > 3 else ""))
