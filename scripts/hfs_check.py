#!/usr/bin/env python3
"""Offline HFS (classic, not HFS+) consistency check for a raw floppy/disk
image. Written 2026-08-05 for the 800K GCR "mounts + lists, but copying a
file fails with 'could not be found' and NO driver error" bug: with the whole
GCR read datapath exonerated by tb_gcr_read + gcr_data_census (every sector
serves checksum-valid bytes from the standard-layout offset), the next
suspect is the IMAGE itself — a broken catalog / extents tree reproduces the
symptom exactly (verification-reference trap).

Checks, in the order the guest File Manager would trip over them:
  1. MDB sanity (sig, geometry, B-tree file extents).
  2. Catalog B-tree: header, node walk, leaf enumeration (what LISTING uses).
  3. For every file: inline extent records vs physical fork lengths; missing
     tail extents must exist in the extents-overflow B-tree (what OPEN/COPY
     uses and listing does NOT).
  4. All referenced allocation blocks in range.
  5. Extract every fork end-to-end (proves full readability).

Usage: hfs_check.py <image> [--dump-dir DIR]
Exit 0 = volume is internally consistent.
"""
import struct
import sys


def be16(b, o):
    return struct.unpack_from('>H', b, o)[0]


def be32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def pstr(b, o, maxlen):
    n = b[o]
    return bytes(b[o + 1:o + 1 + min(n, maxlen)]).decode('mac_roman')


class HFS:
    def __init__(self, img):
        self.img = img
        self.problems = []
        mdb = img[1024:1536]
        if be16(mdb, 0) != 0x4244:
            raise SystemExit(f"not HFS: MDB sig {be16(mdb,0):#06x}")
        self.nmalblks = be16(mdb, 18)
        self.alblksiz = be32(mdb, 20)
        self.alblst = be16(mdb, 28)
        self.vbmst = be16(mdb, 14)
        self.volname = pstr(mdb, 36, 27)
        self.nfiles = be32(mdb, 84)
        self.ndirs = be32(mdb, 88)
        self.xt_size = be32(mdb, 130)
        self.xt_ext = self.extrec(mdb, 134)
        self.ct_size = be32(mdb, 146)
        self.ct_ext = self.extrec(mdb, 150)
        print(f"vol '{self.volname}': {self.nmalblks} alloc blocks x "
              f"{self.alblksiz} B, alBlSt {self.alblst}, files {self.nfiles},"
              f" dirs {self.ndirs}")
        print(f"  catalog size {self.ct_size} ext {self.ct_ext}; "
              f"extents-tree size {self.xt_size} ext {self.xt_ext}")
        span = self.alblst * 512 + self.nmalblks * self.alblksiz
        if span > len(img):
            self.problems.append(
                f"MDB claims {span} B but image is {len(img)} B")
        # extents overflow tree records, keyed (fork, fileID, startBlock)
        self.overflow = {}
        self.load_overflow()

    @staticmethod
    def extrec(b, o):
        return [(be16(b, o + i * 4), be16(b, o + i * 4 + 2)) for i in range(3)]

    def ablk(self, a):
        off = self.alblst * 512 + a * self.alblksiz
        return self.img[off:off + self.alblksiz]

    def fork_bytes(self, ext3, pylen, fileid, fork, what):
        """Walk inline extents + overflow tree; return fork bytes or None."""
        need = (pylen + self.alblksiz - 1) // self.alblksiz
        out = bytearray()
        got = 0
        exts = list(ext3)
        while got < need:
            progressed = False
            for st, cnt in exts:
                if cnt == 0:
                    continue
                for a in range(st, st + cnt):
                    if a >= self.nmalblks:
                        self.problems.append(
                            f"{what}: extent block {a} out of range "
                            f"({self.nmalblks})")
                        return None
                    out += self.ablk(a)
                got += cnt
                progressed = True
            if got >= need:
                break
            nxt = self.overflow.get((fork, fileid, got))
            if nxt is None:
                self.problems.append(
                    f"{what}: fork needs {need} blocks, inline+overflow "
                    f"records provide only {got} — extents-overflow record "
                    f"(fork {fork}, id {fileid}, start {got}) MISSING")
                return None
            exts = nxt
            if not progressed and not any(c for _, c in exts):
                self.problems.append(f"{what}: empty extent record loop")
                return None
        return bytes(out[:pylen])

    # ---- B-tree plumbing -------------------------------------------------
    def btree_nodes(self, ext3, size, fileid, name):
        """Yield (nodenum, 512-byte node) for a B-tree file."""
        raw = self.fork_bytes(ext3, size, fileid, 0, f"{name} B-tree file")
        if raw is None:
            return None
        return [raw[i:i + 512] for i in range(0, len(raw), 512)]

    def walk_leaves(self, nodes, name):
        """Follow fLink from firstLeaf; yield records of every leaf node."""
        hdr = nodes[0]
        ntype = hdr[8]
        if ntype != 1:
            self.problems.append(f"{name}: node 0 type {ntype} != header")
            return
        first_leaf = be32(hdr, 14 + 10)
        node_size = be16(hdr, 14 + 18)
        total = be32(hdr, 14 + 22)
        root = be32(hdr, 14 + 2)
        depth = be16(hdr, 14 + 0)
        nrecs = be32(hdr, 14 + 4)
        print(f"  {name} tree: depth {depth} root {root} leafrecs {nrecs} "
              f"firstLeaf {first_leaf} nodeSize {node_size} nodes {total}")
        if node_size != 512:
            self.problems.append(f"{name}: nodeSize {node_size} != 512")
            return
        seen = set()
        n = first_leaf
        while n != 0:
            if n in seen or n >= len(nodes):
                self.problems.append(f"{name}: leaf chain bad node {n}")
                return
            seen.add(n)
            node = nodes[n]
            cnt = be16(node, 10)
            offs = [be16(node, 512 - 2 * (i + 1)) for i in range(cnt + 1)]
            for i in range(cnt):
                yield node[offs[i]:offs[i + 1]]
            n = be32(node, 0)   # fLink

    def load_overflow(self):
        nodes = self.btree_nodes(self.xt_ext, self.xt_size, 3, "extents")
        if nodes is None:
            return
        for rec in self.walk_leaves(nodes, "extents") or []:
            klen = rec[0]
            if klen != 7:
                self.problems.append(f"extents key len {klen} != 7")
                continue
            fork = rec[1]
            fid = be32(rec, 2)
            start = be16(rec, 6)
            data = rec[8:]
            if len(data) < 12:
                self.problems.append(f"extents rec for id {fid} truncated")
                continue
            self.overflow[(fork, fid, start)] = self.extrec(data, 0)
        if self.overflow:
            print(f"  extents-overflow records: "
                  f"{[(k, v) for k, v in self.overflow.items()]}")
        else:
            print("  extents-overflow tree: empty")

    def files(self):
        nodes = self.btree_nodes(self.ct_ext, self.ct_size, 4, "catalog")
        if nodes is None:
            return
        for rec in self.walk_leaves(nodes, "catalog") or []:
            klen = rec[0]
            k = 1 + klen
            if k & 1:
                k += 1          # record data is word-aligned
            parent = be32(rec, 2)
            name = pstr(rec, 6, 31)
            data = rec[k:]
            if not data:
                continue
            if data[0] == 2:    # file record
                yield parent, name, data


def main():
    path = sys.argv[1]
    img = open(path, 'rb').read()
    v = HFS(img)
    nfiles = 0
    for parent, name, d in v.files() or []:
        nfiles += 1
        fid = be32(d, 20)
        dlg, dpy = be32(d, 26), be32(d, 30)
        rlg, rpy = be32(d, 36), be32(d, 40)
        dext = v.extrec(d, 74)
        rext = v.extrec(d, 86)
        ftype = d[4:8].decode('mac_roman', 'replace')
        creat = d[8:12].decode('mac_roman', 'replace')
        print(f"  file '{name}' (parent {parent}, id {fid}, {ftype}/{creat})")
        print(f"    data fork lg {dlg} py {dpy} ext {dext}")
        print(f"    rsrc fork lg {rlg} py {rpy} ext {rext}")
        dbytes = v.fork_bytes(dext, dpy, fid, 0, f"'{name}' data") \
            if dpy else b''
        rbytes = v.fork_bytes(rext, rpy, fid, 0xFF, f"'{name}' rsrc") \
            if rpy else b''
        okd = dbytes is not None
        okr = rbytes is not None
        print(f"    -> data fork read {'OK' if okd else 'FAIL'}, "
              f"rsrc fork read {'OK' if okr else 'FAIL'}")
        if okr and rlg >= 16:
            rb = rbytes[:rlg]
            data_off = be32(rb, 0)
            map_off = be32(rb, 4)
            if map_off >= rlg or data_off >= rlg:
                v.problems.append(
                    f"'{name}': resource map header out of range "
                    f"(dataOff {data_off} mapOff {map_off} len {rlg})")
    print(f"  catalog file records: {nfiles} (MDB says {v.nfiles})")
    if nfiles != v.nfiles:
        v.problems.append(f"catalog lists {nfiles} files, MDB says {v.nfiles}")

    if v.problems:
        print("\n==> PROBLEMS:")
        for p in v.problems:
            print(f"  ** {p}")
        sys.exit(1)
    print("\n==> VOLUME CONSISTENT: every fork fully readable through "
          "catalog + extents trees.")
    sys.exit(0)


main()
