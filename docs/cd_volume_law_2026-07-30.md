# CD volume law — measured, 2026-07-30 (branch `cd-volume-probe`)

## Verdict

**Our implementation is provably correct. The volume control is still
nearly useless, because the AppleCD Audio Player's 16-step ladder spans
only 5.85 dB under the linear volume law that every reference
implementation uses.**

Whether the *law* is right is the one open question, and only real
hardware can answer it. See "The prediction" below.

## Two independent measurements, in agreement

**1. HDMI audio capture** of a 1 kHz test tone (`scratch/voltest.wav`,
from the user's RECentral capture, analysed by `scratch/vol_analyze.py`):
10 uniform keyboard steps produced levels from −6.78 to −3.01 dBFS —
a 3.77 dB span, with six steps under 0.35 dB. Tone purity 1.000 and
L−R = 0.00 dB, so no distortion and no channel imbalance.

**2. JTAG probe of the actual bytes** (this branch's CDA2/3/4 taps, read
with `scripts/vol_probe.tcl`). The byte values recovered by inference
from measurement (1) — 165, 205, 221, 230, 235, 239, 242, 245, 248, 255
— match the ladder measured directly on the wire. Two methods, one
answer: the multiply executes exactly as written, `level = vol/255`.

## What the player actually sends

16 steps, one MODE SELECT per arrow-key press (`writes` increments by
exactly 1 each time), saturating at 255:

| press | byte | dB (linear law) | Δ dB |
|---|---|---|---|
| 0 | 0 | −∞ (mute) | |
| 1 | 130 | −5.85 | |
| 2 | 161 | −3.99 | +1.86 |
| 3 | 179 | −3.07 | +0.92 |
| 4 | 192 | −2.46 | +0.61 |
| 5 | 202 | −2.02 | +0.44 |
| 6 | 210 | −1.69 | +0.34 |
| 7 | 217 | −1.40 | +0.28 |
| 8 | 223 | −1.16 | +0.24 |
| 9 | 229 | −0.93 | +0.23 |
| 10 | 234 | −0.75 | +0.19 |
| 11 | 238 | −0.60 | +0.15 |
| 12 | 242 | −0.45 | +0.14 |
| 13 | 246 | −0.31 | +0.14 |
| 14 | 249 | −0.21 | +0.11 |
| 15 | 252 | −0.10 | +0.10 |
| 16 | 255 | 0.00 | +0.10 |

Note the shape: the *deficit from 255* decays geometrically (125, 94,
76, 63, 53, 45, …, ratio ≈ 0.82). That is not what you would design for
a drive that multiplies linearly — under a linear law it wastes 14 of
16 steps inside the top 4 dB.

## What is ruled out

- **Parser misalignment.** Page bytes 6/7 read `4B 4B` — the obsolete
  75/75 pair — on every read. The block-descriptor and page offsets are
  therefore correct by observation, so ports 0/1 are being taken from
  the right bytes. Channel routing reads `ch0=01 ch1=02` (L/R) as it
  should, and the audio capture confirms L−R = 0.00 dB.
- **Arithmetic fault.** Spectral purity of 1.000 at exactly 1000 Hz
  rules out a signedness or overflow bug in `(s × vol) >> 8`.
- **Deviation from the oracles.** MAME `nscsi_cdrom_device` does
  `cdda->set_output_gain(0, mode_data[pagedata_offset+9] / 255.0f)` —
  same offsets, same linear law. Snow does `sample/32768 × volume/255`.
  BlueSCSI keeps the same 0–255 pair. We match all three.

## The prediction (what the hardware test must decide)

If a real AppleCD drive interprets the volume byte as **attenuation in
dB** rather than a linear multiplier, the same ladder becomes a normal
control. At 0.384 dB per unit (a 48 dB range) it would give:

| press | byte | dB | Δ dB |
|---|---|---|---|
| 1 | 130 | −48.0 | |
| 2 | 161 | −36.1 | +11.9 |
| 4 | 192 | −24.2 | +5.0 |
| 8 | 223 | −12.3 | +2.3 |
| 12 | 242 | −5.0 | +1.5 |
| 16 | 255 | 0.0 | +1.2 |

**So: on real hardware, the first press above mute should sit roughly
30–48 dB below maximum.** Under the linear law it sits 5.85 dB below.

- Measures ≈30–48 dB ⇒ the linear law is wrong, in MAME, Snow, BlueSCSI
  *and* here. Fix = map the byte through a dB curve. The Snow PR is then
  justified with measured evidence.
- Measures ≈6 dB ⇒ this is authentic AppleCD behaviour and the player's
  slider is simply poor. Any change becomes a deliberate
  quality-of-life divergence from hardware, not a bug fix.

Reference test rig: Quadra 800 + AppleCD 300i or 600i. Record the drive
model, the player version and the System version; keep the Mac's own
sound level fixed; capture digitally; step with arrow keys from 0.

## Reproducing the probe

```bash
bash -c 'export PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH; quartus_stp_tcl -t scripts/vol_probe.tcl'
```
Needs the probe RBF (`scratch/MacLC_VOLPROBE_a965fb98s5.rbf`, seed 5,
STA +0.247) and `USE_DBG_PROBES=1` in `MacLC.qsf` — working-tree only,
never committed. `rtl/scsi.v` on this branch repurposes CDA2/3/4 and
carries a restore-before-merging note.
