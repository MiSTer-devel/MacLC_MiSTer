# builds/ — HW-validated candidates awaiting release promotion

Bit-exact, hash-named (`MacLC_<md5-first-8>.rbf`) copies of builds that
passed the hardware gate but are deliberately **not** in `releases/` yet
(more work planned before cutting a release). Promotion = `git mv` into
`releases/` alongside a dated copy, per the provenance law in CLAUDE.md.
Quartus is deterministic (same netlist + same seed ⇒ same md5), so the
recorded commit is the ultimate provenance — the file here is convenience.

| rbf | built from | validated | notes |
|---|---|---|---|
| `MacLC_7a3c33e7.rbf` | `b541a78` (ariel shadow-M10K CLUT) | 2026-08-09 by user on HW — MacAtrium colour UI clean, CHD boot-attached | −2,252 ALMs / −6,147 regs / +1 M10K vs the 20260809 release fit; STA met +0.242 ns; `USE_DBG_HUD` **ON** (dev fit — a release refit needs it OFF) |
