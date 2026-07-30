# Upstream report / PR prompt — CD-DA volume is applied linearly but real
# AppleCD hardware applies it as roughly the fifth power

Copy everything below the line into an issue, a PR description, or as a
brief to an AI agent. It is written to be project-agnostic; the
"Per-project pointers" section at the end is the only part that needs
editing. Keep the caveats — they are what make the report credible.

---

## Summary

Emulated SCSI CD-ROM targets apply the MODE SENSE/SELECT page 0x0E
(CD Audio Control) volume byte as a **linear amplitude multiplier**,
`gain = volume / 255`. Measurements against a real Apple CD-ROM drive
show the hardware instead applies approximately the **fifth power** of
that ratio, `gain ≈ (volume / 255)^5`.

The practical consequence is that the volume control in Apple's "AppleCD
Audio Player" is nearly useless under emulation. Its full 16-step range
compresses into **5.85 dB** instead of the ~**28 dB** real hardware
delivers, and the upper steps change the level by about **0.1 dB** each —
inaudible. Users perceive this as "the volume slider does nothing until
it suddenly cuts out at the bottom".

The fix is a one-line change to the transfer function. Everything else —
the mode page layout, the byte offsets, the per-port channel routing —
is already correct and is unaffected.

## Evidence

### Reference: real hardware

Quadra 800 with an Apple CD-ROM drive, AppleCD Audio Player, a pressed
disc containing a steady 1 kHz sine, stepping volume from mute to maximum
with the keyboard arrow keys (uniform steps), captured digitally off the
line output. Per-step RMS in dBFS:

| step | level (dBFS) | Δ dB |
|---|---|---|
| mute | −62 (noise floor) | |
| 1 | −29.84 | |
| 2 | −21.88 | 7.96 |
| 3 | −17.80 | 4.08 |
| 4 | −13.93 | 3.87 |
| 5 | −11.78 | 2.15 |
| 6 | −9.84 | 1.94 |
| 7 | −7.81 | 2.02 |
| 8 | −5.82 | 1.99 |
| 9 | −3.82 | 2.00 |
| 10 | −1.82 | 2.00 |

**Usable range 28.0 dB, with the upper steps landing on almost exactly
2.00 dB each.** Presses beyond step 10 produced no change — the drive
saturates before the player's ladder ends.

### The player's byte ladder

The same player was instrumented on an emulated target to capture the
actual bytes it writes (one MODE SELECT per arrow press, 16 steps,
saturating at 255):

```
0, 130, 161, 179, 192, 202, 210, 217, 223, 229, 234, 238, 242, 246, 249, 252, 255
```

Note the shape: the deficit from 255 decays geometrically (125, 94, 76,
63, 53, 45 …, ratio ≈ 0.82). This ladder is designed for a drive that
expands it. Under a linear multiplier it wastes 14 of its 16 steps
inside the top 4 dB.

### The fit

Comparing measured hardware attenuation against what the linear law
produces for the same byte values:

| byte | hardware dB | linear-law dB | ratio |
|---|---|---|---|
| 130 | −28.02 | −5.85 | 4.79 |
| 161 | −20.06 | −3.99 | 5.02 |
| 179 | −15.98 | −3.07 | 5.20 |
| 192 | −12.11 | −2.46 | 4.91 |
| 202 | −9.96 | −2.02 | 4.92 |
| 210 | −8.02 | −1.69 | 4.76 |

Least squares over this region: **hardware_dB ≈ 4.92 × linear_dB**, i.e.
`gain = (volume/255)^5`. The ratio is stable with no trend across a
20 dB span.

## Proposed fix

```
gain = (volume / 255) ^ 5
```

equivalently `attenuation_dB = 100 · log10(volume / 255)`, which is
exactly 5× the current value. `volume = 0` stays exact mute and
`volume = 255` stays exact unity, so bit-perfect passthrough at full
volume is preserved.

Compute once when the mode page is written, not per sample. In a tight
audio loop or in hardware, use a 256-entry table:

```c
uint32_t vol_table[256];
for (int v = 0; v < 256; v++)
    vol_table[v] = (uint32_t)lrint(65536.0 * pow(v / 255.0, 5.0));

/* per sample, per output port; the product needs 32 bits */
out = (int16_t)(((int32_t)sample * (int32_t)vol_table[vol]) >> 16);
```

Spot values for verifying a table: 255→65536, 229→38279, 202→20443,
161→6575, 130→2257, 64→65, 0→0.

Apply per output port independently — ports 0 and 1 carry their own
volume bytes. The channel-routing bytes are unchanged.

## What NOT to copy from hardware

Real hardware also quantises to ~2 dB steps and saturates to full output
near byte 234. Both look like artifacts of an analog attenuator in one
specific drive. Reproducing them discards resolution and makes bytes 234
and 255 indistinguishable. A smooth curve is the better emulation
choice.

## Caveats (please keep these in the report)

- **One drive, one player.** The reference is a single Apple CD-ROM
  mechanism driven by AppleCD Audio Player. Other Apple drive
  generations may differ, and the exponent may be a coincidence of this
  mechanism's attenuator rather than a spec-mandated curve. I have not
  found a documented curve in MMC — the standard describes the field as
  a volume level without specifying linearity.
- **Verified over bytes 130–210 only.** That is the region the player's
  ladder exercises. Behaviour below 130 is extrapolated: a `^5` law puts
  byte 64 at −60 dB and byte 32 at −90 dB, which is untested. Projects
  that care about volume ramps may want to floor the curve near −60 dB.
- **Above ~229 the hardware diverges** from the power law because it
  saturates early, so the fit is not expected to hold at the very top.
- The measurement captured only the left channel, so this says nothing
  about inter-channel balance.

## Per-project pointers (edit or delete)

- **MAME** — `src/devices/bus/nscsi/cd.cpp`, in the MODE SELECT handler
  for page 0x0e:
  `cdda->set_output_gain(0, mode_data[pagedata_offset+9] / 255.0f)` and
  the matching `+11` line for port 1.
- **Snow** — `core/src/mac/scsi/cdrom/mod.rs`, `make_out_sample`:
  `sample as f32 / 32768.0 * port.volume as f32 / 255.0`.
- **BlueSCSI** — volume is stored as a 0–255 pair via `audio_set_volume`
  and applied in the audio backend; the table approach fits best there.
