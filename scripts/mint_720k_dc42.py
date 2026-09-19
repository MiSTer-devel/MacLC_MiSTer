#!/usr/bin/env python3
"""Mint the 720K-DOS-in-DC42 gate images (docs/floppy_write_plan.md section 8).

WHY THIS EXISTS (2026-09-19). Phase 6D made a tagless DC42's partial final block
writable and was gated at 1.44 MB only. The DD cell was never run -- and it is
the one the plan's own worked example is about: a 720K FAT12 volume is 1440
sectors and uses every one, cluster 714 covering sectors 1438-1439, whose last
84 bytes are the DC42 partial block. HFS reserves slack at the end of a volume
and FAT does not, which is why the defect was latent at 1.44 MB HFS and sharp
here.

Geometry and the FAT12 writer come from mint_phase6_images.py, so these images
are minted by the same code its own images are, and mk_dc42.py verifies each
container against the core's detection rule. Deterministic: a lost baseline
regenerates byte-identically.

  python scripts/mint_720k_dc42.py [--outdir DIR]

THREE IMAGES, and the second is the one that matters:

  P6_DOS720K_tail       TAIL.BIN pinned to cluster 714, its last 84 bytes
                        carrying TAIL_SIG. Copy it off in the guest and compare
                        -- that tests the loader CEIL (the READ half).
  P6_DOS720K_lastfree   every cluster allocated EXCEPT 714. PC Exchange writes
                        DESKTOP / FINDER.DAT / RESOURCE.FRK at MOUNT, so with
                        one free cluster it is FORCED to put FINDER.DAT in the
                        tail -- that tests the WRITE half, at mount, with no
                        copying at all.
                        ! The guest then reports the disk COMPLETELY FULL and
                        refuses every file. That message is the PASS, not a
                        failure: diff the image, do not judge by the dialog.
  P6_DOS720K_nearfull   12 low clusters free plus 714, for a conventional
                        fill-to-zero-free run if the mount-time result is ever
                        in doubt.
"""
import argparse, importlib.util, shutil, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("m", REPO / "scripts" / "mint_phase6_images.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

G = m.G720
CL = G.spc * m.SEC                      # 1024 B per cluster
LAST_SEC = G.data_start + (G.last_cluster - 2) * G.spc + G.spc - 1


def wrap(raw_path, dc_path, name, force):
    if dc_path.exists() and not force:
        print("    SKIP (exists): %s" % dc_path.name)
        return True
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "mk_dc42.py"),
                        str(raw_path), str(dc_path), "--name", name])
    if r.returncode:
        return False
    shutil.copyfile(dc_path, dc_path.with_suffix(".baseline.img"))
    print("    %-38s %9d  + baseline" % (dc_path.name, dc_path.stat().st_size))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=str(m.DEFAULT_OUT))
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    out = Path(a.outdir); out.mkdir(parents=True, exist_ok=True)

    print("720K FAT12: %d sectors, %d sectors/cluster, data_start %d, clusters 2..%d"
          % (G.total, G.spc, G.data_start, G.last_cluster))
    print("last cluster %d = sectors %d-%d; DC42 partial block = last 84 B of sector %d\n"
          % (G.last_cluster, LAST_SEC - G.spc + 1, LAST_SEC, LAST_SEC))

    ok = True
    # TAIL.BIN fills the WHOLE cluster, so TAIL_SIG lands on the partial block.
    tail = m.sector_pattern(CL - 84, "T720") + m.TAIL_SIG
    assert len(tail) == CL
    specs = [
        ("P6_DOS720K_tail", "P6 tail 720",
         m.fat12_mint(G, "P6TAIL720", [("TAIL", "BIN", tail, G.last_cluster)])),
        ("P6_DOS720K_lastfree", "P6 last free 720",
         m.fat12_mint(G, "P6LAST720",
                      [("FILLER", "BIN",
                        m.sector_pattern((G.last_cluster - 2) * CL, "F720"), None)])),
        ("P6_DOS720K_nearfull", "P6 near full 720",
         m.fat12_mint(G, "P6NEAR720",
                      [("FILLER", "BIN",
                        m.sector_pattern((G.last_cluster - 2 - 12) * CL, "N720"), None)])),
    ]
    for stem, label, img in specs:
        assert len(img) == 737280, len(img)
        raw = out / (stem + ".img")
        raw.write_bytes(img)
        print("  raw  %-38s %9d" % (raw.name, raw.stat().st_size))
        ok = wrap(raw, out / ("%s (DC42).img" % stem), label, a.force) and ok

    print("\nVerify (independent reader):")
    for stem, _, _ in specs:
        p = out / ("%s (DC42).img" % stem)
        good = m.run(str(REPO / "scripts" / "fat_diff.py"), str(p))
        print("  fat_diff  %-38s %s" % (p.name, "OK" if good else "FAIL"))
        ok = ok and good
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
