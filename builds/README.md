# builds/ — HW-validated candidates awaiting release promotion

Bit-exact, hash-named (`MacLC_<md5-first-8>.rbf`) copies of builds that
passed the hardware gate but are deliberately **not** in `releases/` yet
(more work planned before cutting a release). Promotion = `git mv` into
`releases/` alongside a dated copy, per the provenance law in CLAUDE.md.
Quartus is deterministic (same netlist + same seed ⇒ same md5), so the
recorded commit is the ultimate provenance — the file here is convenience.

| rbf | built from | validated | notes |
|---|---|---|---|
| _(none pending)_ | | | Last promotion: `MacLC_7a3c33e7.rbf` (ariel shadow-M10K CLUT, `b541a78`) → `releases/MacLC_20260810.rbf` on 2026-08-09 |
