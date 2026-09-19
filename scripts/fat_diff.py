#!/usr/bin/env python3
"""FAT12 reader and byte-for-byte verifier for DOS floppies this core wrote.

    python scripts/fat_diff.py <fat image>                     # list it
    python scripts/fat_diff.py <fat image> <HFS source volume> # verify it

WHY THIS EXISTS (2026-09-18). The 720K DD MFM gate cannot use `hfs_check.py`
or `hfs_fork_diff.py` at all: **720K is DOS-only by construction.** The Mac
formats DD media as 400K/800K GCR, so no HFS 720K format exists (plan doc
section 8) -- a 720K disk is FAT12 and reaches the guest through PC Exchange.
The DOS 1.44 read/write checks of 2026-09-17 were done BY HAND for want of
this, which does not scale to a soak.

PC EXCHANGE SPLITS A MAC FILE IN TWO. The data fork becomes the DOS file;
the resource fork is written to a `RESOURCE.FRK` subdirectory under the same
8.3 name, and Finder metadata goes to `FINDER.DAT`. So verifying a Mac file
copied onto a DOS disk means comparing the DOS file against the source's DATA
fork and `RESOURCE.FRK/<name>` against its RESOURCE fork.

★ THE $30..$7D EXEMPTION DOES APPLY HERE, contrary to what this file first
claimed. Measured 2026-09-18 on the 720K fill: Backgrounder 9 differing bytes,
MultiFinder 8, Chooser 10 -- **every one inside $30..$7D, none in the map,
none in resource data.** PC Exchange presents a DOS file as a Mac file WITH a
resource fork, so creating it goes through PBOpenRF and the File Manager
writes its "directory copy" exactly as it does on HFS (Apple TN 74). The
resource comparison therefore reuses `hfs_fork_diff.rsrc_same`, which keeps
resource DATA exact and excuses only that window and short map runs.

Containers are detected by `hfs_check.open_volume`, so a raw .img, a DC42 and
an Apple Partition Map volume all work as either argument.

Long-name (VFAT) directory entries are assembled when present; PC Exchange
normally writes 8.3 only.

VALIDATED BEFORE USE (2026-09-18) against 7-Zip as an independent oracle, on
all eight DOS images in `Test disks/DOS/`: every filename and every size
agrees on 8 of 8. The only two apparent discrepancies were `attr=0x28`
entries -- volume labels, which this reader skips as not-files and 7-Zip
lists as entries. Re-run that cross-check if the directory walk is ever
touched; it is a few lines of subprocess and it caught nothing only because
the reader was right.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hfs_check import HFS, open_volume                 # noqa: E402

ATTR_VOLUME = 0x08
ATTR_DIR = 0x10
ATTR_LFN = 0x0F


class FAT12:
    def __init__(self, img):
        self.img = img
        bs = img[0:512]
        self.sec = struct.unpack_from('<H', bs, 11)[0]
        self.spc = bs[13]
        self.reserved = struct.unpack_from('<H', bs, 14)[0]
        self.nfats = bs[16]
        self.rootents = struct.unpack_from('<H', bs, 17)[0]
        self.total = struct.unpack_from('<H', bs, 19)[0]
        self.media = bs[21]
        self.spf = struct.unpack_from('<H', bs, 22)[0]
        self.spt = struct.unpack_from('<H', bs, 24)[0]
        self.heads = struct.unpack_from('<H', bs, 26)[0]
        self.label = bytes(bs[43:54]).decode('cp437', 'replace').strip()
        if self.sec not in (512,) or self.spf == 0 or self.total == 0:
            raise SystemExit("not a FAT12 floppy (bytes/sector %d, "
                             "sectors/FAT %d, total %d)"
                             % (self.sec, self.spf, self.total))
        self.fat_off = self.reserved * self.sec
        self.root_off = (self.reserved + self.nfats * self.spf) * self.sec
        self.data_off = self.root_off + self.rootents * 32
        self.fat = img[self.fat_off:self.fat_off + self.spf * self.sec]
        self.fat2 = img[self.fat_off + self.spf * self.sec:
                        self.fat_off + 2 * self.spf * self.sec]
        self.problems = []
        if self.nfats >= 2 and self.fat != self.fat2:
            n = sum(1 for i in range(len(self.fat)) if self.fat[i] != self.fat2[i])
            self.problems.append("the two FAT copies differ in %d bytes" % n)

    def describe(self):
        return ("FAT12 %r: %d sectors x %d B, %d sectors/cluster, %d FATs x %d "
                "sectors, %d root entries, %d spt, %d heads, media %#04x"
                % (self.label, self.total, self.sec, self.spc, self.nfats,
                   self.spf, self.rootents, self.spt, self.heads, self.media))

    def entry(self, n):
        """FAT12 is 12 bits per entry, packed one and a half bytes."""
        o = (n * 3) // 2
        if o + 1 >= len(self.fat):
            return 0xFFF
        v = self.fat[o] | (self.fat[o + 1] << 8)
        return (v >> 4) if (n & 1) else (v & 0x0FFF)

    def chain(self, first):
        out, n, seen = [], first, set()
        while 2 <= n < 0xFF8 and n not in seen:
            seen.add(n)
            out.append(n)
            n = self.entry(n)
        return out

    def cluster(self, n):
        off = self.data_off + (n - 2) * self.spc * self.sec
        return self.img[off:off + self.spc * self.sec]

    def read(self, first, size):
        if size == 0:
            return b''
        b = b''.join(self.cluster(c) for c in self.chain(first))
        if len(b) < size:
            self.problems.append("cluster chain from %d gives %d B, "
                                 "directory says %d" % (first, len(b), size))
            return None
        return b[:size]

    def dir_at(self, data, path=""):
        """Yield (path, attr, firstCluster, size) for every live entry."""
        lfn = []
        for o in range(0, len(data), 32):
            e = data[o:o + 32]
            if len(e) < 32 or e[0] == 0x00:
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            attr = e[11]
            if attr == ATTR_LFN:
                seq = e[0] & 0x3F
                part = (bytes(e[1:11]) + bytes(e[14:26]) + bytes(e[28:32]))
                lfn.append((seq, part.decode('utf-16-le', 'replace')))
                continue
            if attr & ATTR_VOLUME:
                lfn = []
                continue
            if lfn:
                name = ''.join(p for _, p in sorted(lfn)).split('\x00')[0]
                lfn = []
            else:
                base = bytes(e[0:8]).decode('cp437', 'replace').rstrip()
                ext = bytes(e[8:11]).decode('cp437', 'replace').rstrip()
                name = base + ('.' + ext if ext else '')
            if name in ('.', '..'):
                continue
            first = struct.unpack_from('<H', e, 26)[0]
            size = struct.unpack_from('<I', e, 28)[0]
            yield (path + name, attr, first, size)

    def walk(self):
        """{path: (firstCluster, size)} for every file, recursing subdirs."""
        out = {}
        stack = [(self.img[self.root_off:self.root_off + self.rootents * 32], "")]
        seen = set()
        while stack:
            data, path = stack.pop()
            for name, attr, first, size in self.dir_at(data, path):
                if attr & ATTR_DIR:
                    if first in seen or first < 2:
                        continue
                    seen.add(first)
                    sub = b''.join(self.cluster(c) for c in self.chain(first))
                    stack.append((sub, name + "/"))
                else:
                    out[name] = (first, size)
        return out


def hfs_catalog(path):
    """{basename: (data bytes, rsrc bytes)} for an HFS source volume."""
    from hfs_fork_diff import catalog, forks
    v = HFS(open_volume(path)[0])
    out = {}
    for p, rec in catalog(v).items():
        d, r = forks(v, rec)
        out.setdefault(p.rsplit('/', 1)[-1], []).append((p, d, r))
    return out


def dos83(name):
    """The 8.3 stem a DOS file uses, upper-cased, for matching by name."""
    return name.rsplit('.', 1)[0].upper()


def main(fat_path, src_path=None):
    img = open_volume(fat_path)[0]
    f = FAT12(img)
    print(f.describe())
    files = f.walk()
    used = sum(1 for n in range(2, (f.total - f.data_off // f.sec) // f.spc + 2)
               if f.entry(n))
    print("%d file(s); %d clusters allocated (%d KB)"
          % (len(files), used, used * f.spc * f.sec // 1024))
    for p in sorted(files):
        first, size = files[p]
        print("   %-40s %8d B  first cluster %5d  %d extent-clusters"
              % (p, size, first, len(f.chain(first))))
    for msg in f.problems:
        print("   PROBLEM: %s" % msg)
    if not src_path:
        return 0 if not f.problems else 1

    print("\n=== comparing against %s" % src_path)
    src = hfs_catalog(src_path)
    # RESOURCE.FRK/<name> holds the resource fork PC Exchange split off
    rsrc = {p.rsplit('/', 1)[-1]: v for p, v in files.items()
            if 'RESOURCE.FRK/' in p.upper()}
    bylen = {}
    for name, lst in src.items():
        for sp, d, r in lst:
            bylen.setdefault((len(d or b''), len(r or b'')), []).append((sp, d, r))
    ok = bad = skipped = generated = 0
    for p in sorted(files):
        # PC Exchange puts a RESOURCE.FRK directory and a FINDER.DAT in EVERY
        # folder, not just the root, so these must be matched as path
        # COMPONENTS -- an anchored startswith misses the nested ones and then
        # content-matching pairs them with whatever random source file happens
        # to share their length.
        parts = p.upper().split('/')
        if 'RESOURCE.FRK' in parts[:-1] or parts[-1] == 'FINDER.DAT':
            continue
        if parts[-1] in ('DESKTOP', 'DESKTOP.DB', 'DESKTOP.DF', 'TRASH'):
            generated += 1          # the Finder's own, minted on the target
            print("   %-40s (Finder-generated on the target, no original)" % p)
            continue
        first, size = files[p]
        name = p.rsplit('/', 1)[-1]
        got_d = f.read(first, size)
        rf = rsrc.get(name) or rsrc.get(name.upper())
        got_r = f.read(rf[0], rf[1]) if rf else b''
        # MATCH BY CONTENT, NOT BY NAME. PC Exchange mangles a Mac name into
        # 8.3 with its own scheme ("Backgrounder" -> "!BACKGRO.UND"), and the
        # original name lives in FINDER.DAT rather than the directory entry.
        # Reverse-engineering that mangling would be guesswork; the fork
        # LENGTHS plus a byte compare identify the file exactly and verify it
        # in the same step. Name matching is tried first only because its
        # output is more informative when it happens to work.
        cands = list(src.get(name) or src.get(dos83(name)) or [])
        if got_d is not None:
            # ALWAYS append the length-matched candidates, never just fall
            # back to them: a name hit can be the WRONG file. "README" matched
            # Tetris Max's 16 907 B readme by name and reported a difference,
            # while the real source (987 B) sat in the length-matched set.
            key = (len(got_d), len(got_r))
            for c in bylen.get(key, []):
                if c not in cands:
                    cands.append(c)
        if not cands:
            print("   %-40s NO FILE ON THE SOURCE MATCHES (data %d B, rsrc %d B)"
                  % (p, size, len(got_r)))
            skipped += 1
            continue
        verdict = None
        for sp, sd, sr in cands:
            if got_d is None:
                verdict = "%s: data fork unreadable (short cluster chain)" % sp
                continue
            from hfs_fork_diff import rsrc_same
            same_d = got_d == (sd or b'')
            same_r, note = rsrc_same(got_r, sr or b'')
            if same_d and same_r:
                verdict = ("IDENTICAL to %s  (data %d B, rsrc %d B%s)%s"
                           % (sp, len(got_d), len(got_r),
                              "" if rf else ", no RESOURCE.FRK entry", note))
                break
            verdict = ("%s: data %s (%d vs %d B), rsrc %s (%d vs %d B)"
                       % (sp, "same" if same_d else "DIFFERS",
                          len(got_d), len(sd or b''),
                          "same" if same_r else "DIFFERS",
                          len(got_r), len(sr or b'')))
        if verdict.startswith("IDENTICAL"):
            ok += 1
        elif "unreadable" in verdict:
            skipped += 1
        else:
            bad += 1
        print("   %-40s %s" % (p, verdict))
    print("\n%d identical, %d differ, %d not compared" % (ok, bad, skipped))
    for msg in f.problems:
        print("PROBLEM: %s" % msg)
    print("FAT DIFF: %s" % ("PASS" if bad == 0 and ok > 0 and not f.problems
                            else "FAIL"))
    return 0 if (bad == 0 and ok > 0 and not f.problems) else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
