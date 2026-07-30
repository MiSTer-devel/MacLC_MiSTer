# CD SCSI command work — night of 2026-07-29/30 (branch `cd-volume-v2`)

Read `scratch/overnight_cdcmds_log.md` for the blow-by-blow; this file
is the durable summary.

## 1. Headline

The CD **volume slider works on hardware** (confirmed by ear: swept
down and back up on a playing track), and **six more SCSI commands plus
a latent bus-wedge fix** landed on top of it — all sim-gated with zero
regressions, all built and hardware-gated.

The bigger result is a correction: **the 2026-07-29 daytime session's
"this build fails the hardware gate" verdicts were false.** They were
the project's known, still-open **CUE/CHD-attached-at-boot hang**, which
fires intermittently on *any* build. Everything derived from those
verdicts — the fit-marginality theory, the serve-mux-depth hypothesis,
the "revert the gap pass" bisect — was chasing a bench bug.

## 2. What is on the branch

| commit | what | oracle |
|---|---|---|
| `24ac11a` | **MODE SELECT/SENSE page 0x0E** — CD Audio Control: the volume slider. Four {channel, volume} ports parsed and echoed; ports 0/1 scale CD-DA PCM. | Snow CDU-8004 |
| `783573a` | **0x42 READ SUB-CHANNEL formats 2/3** (MCN / ISRC) — were served as format-1 garbage. | BlueSCSI 2486 |
| `dfc3505` | **0x44 READ HEADER** (LBA form; MSF form CHECKs 5/0x24). | BlueSCSI 2327 |
| `789179f` | **0x45 PLAY AUDIO(10)** LBA form (+0xA5 decode). | BlueSCSI 2379 |
| `4938734` | **12-byte (group-5) CDB completion** — *bug fix*, see §3. | SCSI-2 |
| `77e8295` | **0xBB SET CD SPEED** — accept-noop. | BlueSCSI 2451 |
| `46540cc` | **MODE SENSE page 0x2A** — MM capabilities: audio play, separate volume levels, 256 steps. | Snow |
| `5a294a8` | `scsi_bench` **gapcmds** mode — first real test coverage for all of the above. | — |
| `dcb7b5a` | `ws_send.py` accepts `kbdRawDown/Up` (Cmd-key chords). | — |
| `6cf140b` | `docs/SCSI_CMD_GAPS.md` updated: closed rows, reasons for the rest. | — |

Each command is its own commit, so any one can be reverted alone.
Tag `attempt/subq-reject-guard` preserves a dropped alternative (a
Snow-style *reject* of 0x42 formats 2/3, superseded by serving them).

## 3. The 12-byte CDB fix is the sleeper

`scsi.v`'s command collector completed only 6-byte and 10-byte CDBs.
A group-5 (0xA0–0xBF) command therefore **never completed**: the target
sat in `PHASE_CMD_IN` forever and the bus wedged. Latent only because
MacOS sends none — but it applied to the **disk targets too**, not just
the CD. Now unknown 12-byte opcodes CHECK with invalid-op (correct SCSI),
and 0xA5 / 0xBB became reachable.

## 4. Provenance — why the hardware verdict is trustworthy

Build 3 was compiled from the committed tree at seed 5 and produced
md5 **`dab8f7c6`** — *byte-identical* to the bitstream that passed the
hardware gate at 23:11. Same netlist + same seed ⇒ same bits. So the
commits are not merely "equivalent to" the validated build; they **are**
it. (Useful trick for this project generally.)

## 5. ★ Bench law: detach the CD before gating

The hang that faked all those failures is triggered by having a CUE/BIN
attached **at boot** from config. Evidence: the known-good RBF
`01bf2d76` — the very build whose volume slider we heard working —
booted to a dead, input-ignoring grey desktop with the CD attached, and
its screenshot md5 `57bcea2a` is *byte-identical* to the image last
night's dossier cites as proof that `dab8f7c6` "fails to mount volumes".
Detaching the CD and reloading the same RBF booted a healthy Finder.

**Procedure that works** (`scratch/gate.sh` automates it):
1. `mv /media/fat/config/MACLC.s4 …bak_cdattach` (CD detached at boot).
2. Clean Shut Down the previous guest, then `load_core`.
3. ONE screenshot at +118 s. PASS = MacAtrium browser, colour icons —
   reference md5 `94fedd19`.
4. Liveness check before trusting any verdict: move the mouse, confirm
   the cursor moved. A hung guest ignores **both** the mouse
   (`/dev/input/event3` writes) and the keyboard (ws Remote) while both
   still "succeed".
5. To test CD behaviour, OSD-mount the disc **after** the desktop is up.

Restore the boot attach with:
`cp /media/fat/config/MACLC.s4.bak_cdattach /media/fat/config/MACLC.s4`

## 6. Open items

- **CUE/CHD-at-boot-attach hang** — now characterised (intermittent,
  hangs after the Finder draws, ignores all input) but NOT fixed. This
  is the highest-value CD bug left, and it has been silently poisoning
  hardware verdicts.
- **0xCD AUDIO SCAN (FF/RW)** — implemented, user reported "still not
  working correctly". Neither oracle implements it properly; Snow's
  fallback is accept-and-keep-playing. Needs a human ear to choose.
- **0xA5 PLAY AUDIO(12)** is now reachable but untested against real
  software (nothing sends it).
- Deliberately skipped, with reasons, in `docs/SCSI_CMD_GAPS.md`:
  0xA8 READ(12), mode pages 0x01/0x03, 0x51/0x52/0x4A/0xBD,
  0xBE/0xB9/0xD8 raw-audio extraction.

## 7. Deviations to disclose

Two HPS reboots on guests that were **provably hung** (both input paths
dead, identical frames) — no clean-shutdown path exists in that state,
and both guests had just booted with no work in them. Every other core
swap this session was preceded by a verified clean Shut Down.
