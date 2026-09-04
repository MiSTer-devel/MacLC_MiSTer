# Handoff: ALL guest-time fixes — frozen clock, 1960 dates, DST hour (for the Pocket port)

**Do not edit the Pocket tree from the MiSTer repo.** This is a self-contained
description of three time defects found and fixed on the MiSTer side on
2026-08-23/24, with the exact mechanism, the diffs, and the gates — enough to
apply and verify the equivalent changes on the Pocket. All three were
HW-validated on MiSTer (menu clock ticks, lowmem Time `$20C` advances 1/s).

MiSTer reference commits (branch `pds-enet-icache-fix` unless noted):

| commit | what |
|---|---|
| `8c62ccf` | one-second interrupt deadlock fix (level-sensitive HC05 interrupts) + `$12` bit-6 read-back + exact ONESEC_PERIOD |
| `97b7928` | Egret RTC seeded in the Mac epoch (1904), not Unix (1970) |
| Main fork `289c21a` (`mac-ethernet`) | MiSTer-host-side DST-aware local time — see §4 for what the Pocket needs instead |

## Background: how a Mac LC gets its one-second heartbeat

There is **no VIA1 CA2 one-second wire on this machine** (MAME v8.cpp has zero
CA2 references — any CA2 feed in a port is decorative; the ROM never enables
it). The real mechanism, confirmed against MAME 0.288 + the 341S0851 firmware
disassembly:

1. During boot the ROM sends Egret pseudo-command **`[01 1B mode]`**
   (`0x1B` = one-second mode, same number as Cuda's; the ROM uses mode 3).
   Diskless boot enables at t≈8-10 s, an HDA boot at t≈22 s.
2. Every second the HC05's one-second hardware timer fires its ISR ($1E10),
   which increments the RTC seconds and sets RAM flag `$A2.3`.
3. The firmware **main loop** ($104C → $1ACE) sees `$A2.4 && $A2.3` and sends
   an unsolicited **TIMER packet `[00 03]`** to the host over the VIA SR
   channel (TREQ handshake, same transport as ADB autopoll).
4. The guest's Egret driver increments lowmem Time (`$20C`) per packet; the
   menu clock follows.

**The law:** MAME steady state shows one `[00 03]` packet **every 60 frames
exactly**. If the enable arrives and packets don't recur ~1/s, delivery is
broken.

## Defect 1 — one-second interrupts deadlock permanently (THE frozen clock)

**Symptom:** menu clock shows the boot time forever; `$20C` bit-identical
minutes apart; the mouse and everything else keep working. The HC05's internal
RTC freezes too, but a host-timestamp re-seed at every core load hides that.

**Root cause (`rtl/egret/m68hc05_core.sv`):** the converted HC05 core
edge-detected its interrupt inputs and **discarded an edge that landed while
the firmware had I masked** (`SEI` … `CLI` wraps every VIA byte-shift routine).
The one-second line is held asserted until the ISR acks `$12` bit 6 — and with
the edge swallowed the ISR never runs, so no new falling edge can ever form:
**permanent deadlock**. Polled paths survive, so only the clock dies. At a 1 Hz
tick and the boot's dense Egret traffic, death lands within seconds of the
enable — the guest sees 0-2 ticks, ever.

**Fix (commit `8c62ccf`, applies verbatim if the Pocket shares this RTL):**
make the two internal sources **level-sensitive** (real 68HC05 semantics; MAME
holds ASSERT_LINE until the `$12` write clears it), and latch requests only at
opcode fetch (`mainFSM == 4'h2`) so a pending level can't hijack an in-flight
SWI's vector selection. The external IRQ pin (unused, tied high) keeps edge
semantics via a pending latch. See the commit for the exact block — it
replaces the `(onesec_irq==0 && onesec_irq_d==1)` edge terms with level tests
plus the fetch-state gate.

Pre/post signature (Verilator, 700-frame boot, 2 ms sim tick): pre-fix
unsolicited sends per second run `…316, 325, 2, 1, 0, 0…` (one stale tick after
the enable, then silence); post-fix holds ~470/s to the end of the run with the
wrapper's FIRE/ACK witness at exactly 1:1 (8970/8970).

## Defect 2 — `$12` reads hide the fired flag (secondary, same commit)

MAME's m68hc05e1 sets **bit 6 of register `$12` itself** when the second fires
(`m_onesec |= 0x40`), visible on reads until the firmware writes bit6=0. The
wrapper kept the flag in a hidden side register, so any firmware
read-modify-write bit op on `$12` (e.g. `BSET 5,$12` in the set-time path)
read bit6=0 and wrote bit6=0 back — **spuriously acking a pending second**.
Fix in `rtl/egret/egret_wrapper.sv`: OR the fired flag into bit 6 on reads.
The ISR's `BCLR 6,$12` still clears through the same write path.

## Defect 3 — one-second period constant vs the real clock-enable rate

`ONESEC_PERIOD` assumed the HC05 `cen` was exactly 4 MHz. On MiSTer it is
`clk_sys/8 = 32.5 MHz/8 = 4.0625 MHz`, so 4,000,000 made the guest clock run
1.56% fast. The counter spans `0..PERIOD` inclusive (PERIOD+1 ticks/fire), so
the correct value is `cen_Hz − 1` — 4,062,499 on MiSTer.

**Pocket action:** derive the constant from the POCKET's actual Egret clock
tree — count the real `cen` frequency, set `ONESEC_PERIOD = cen_Hz − 1`. Do
NOT copy 4,062,499 unless the Pocket's cen is also exactly 4.0625 MHz.

## Defect 4 — the guest lives in 1960 (and, on MiSTer, an hour behind in DST)

Two stacked seeding errors:

**(a) Missing Mac epoch (fix `97b7928`, applies to the Pocket):** the RTC seed
wrote a **Unix** epoch (seconds since 1970) into the Egret's seconds counter,
but Mac Time counts from **1904-01-01**. The 2,082,844,800 s difference is
exactly 24,107 days, and 1904→1970 has the same number of leap days as
1960→2026 — so the wall time and month/day were CORRECT while the year was
1960. It hides in the menu-bar clock (no date) and shows in Finder file dates.
Fix: add the offset at the seed:

```verilog
wire [31:0] mac_seconds = timestamp[31:0] + 32'd2082844800;
// seed intram $AB..$AE from mac_seconds[31:24..7:0]
```

**(b) The seed must be DST-correct LOCAL time.** Mac Time is local wall time —
classic Mac OS has no timezone concept in the clock itself. On MiSTer, the
host's stock conversion (`t += t - mktime(gmtime(&t))`) feeds `mktime()` a
`tm_isdst = 0` struct, which applies the standard-time offset year-round — one
hour behind all summer; the Main fork now uses a DST-aware conversion for
maclc* cores (`289c21a`). **On the Pocket this is probably a non-issue**: the
Analogue RTC is user-set local wall time with no timezone math. Just verify
the chain: whatever converts the Pocket RTC (BCD date/time) into the 32-bit
seed must produce *local* seconds — then add the 1904 offset from (a). If the
port converts calendar fields → seconds itself, that conversion can target the
Mac epoch directly (seconds since 1904-01-01 00:00 local) and skip the
constant.

Note the seed overwrites the guest clock at **every core load** — a
deliberate host-wins policy. Anything set in the guest's Date & Time control
panel lasts only until the next load. Keep that behavior unless you also build
guest-set-time persistence (SET_TIME deltas are not persisted; the RTC seconds
live in HC05 RAM `$AB-$AE`, outside the PRAM region that gets saved).

## Gates (run all of them)

1. **Boot gate**: your port's equivalent of the frame-450 grey-desktop+cursor
   screenshot. The Egret interrupt retiming touches the ADB/timer path — a
   boot regression or a dead mouse would show here.
2. **Tick cadence (sim)**: after the ROM's `[01 1B 03]` enable, unsolicited
   Egret sends must RECUR at the sim tick rate to the end of the run — not
   "once then silence". Grep the SR-read stream for the `[00 03]` (or longer
   time-bearing) packets; the MiSTer scratch analyzers keyed on
   `TREQ ACTIVE` / `SR READ` lines.
3. **HW**: boot to Finder; the menu clock must advance across a minute
   boundary; a file created in the guest must carry the current year (2026,
   not 1960); mouse still works.
4. **Time math spot-check**: guest `$20C` (if you can read guest RAM) should
   equal `local_unix_epoch + 2,082,844,800` within a few seconds.

## Traps we hit (don't repeat)

- A CA2 "one-second" feed derived from the 60 Hz tick looks plausible and does
  nothing — the ROM never enables VIA1 CA2 on this machine. Don't fix that
  path; fix the Egret delivery.
- The interrupt deadlock is probabilistic per tick: short sims and light
  traffic can look healthy. The kill signature is "exactly one tick after the
  enable, then silence, while autopoll keeps flowing."
- The RTC-frozen half of the bug is masked by the boot-time re-seed — "clock
  right at boot, then frozen" is the tell, not "clock wrong".
- MAME comparison: run `maclc` with `-ramsize 10M` (2M hangs a 7.5 HDA boot
  black), and the VIA SR tap at `$F01400` (rw) captures the whole Egret
  conversation, PCs included.
