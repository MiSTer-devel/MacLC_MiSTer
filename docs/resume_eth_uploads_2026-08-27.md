# RESUME (autonomous): FIX BULK GUEST UPLOADS — the one open ethernet item

Work autonomously to root-cause and fix. Everything below is verified state
as of 2026-08-26 ~16:30 EDT session close. Read the memory index +
`eth-tx-and-throughput-fixed` first — it holds the full seven-layer defect
history; this doc is the operational continuation.

## The mission, in priority order

1. **Bulk guest UPLOADS (Fetch Put) must complete.** A 3 MB PUT from the
   .143 guest to .94's FTP currently stalls at ~5–11 KB and leaves MacTCP
   mute. Downloads are FIXED and must not regress (60–110 KB/s on both
   boxes is the floor — regression-gate every change against a download).
2. Validate the SONIC **watchdog timer** (already implemented, branch head
   `1cbb0e1`, NOT in the release) or refute it cleanly.
3. 32-bit-mode spot check (Memory control panel → 32-Bit On → Restart →
   one download). Low risk: every fix is mode-agnostic, but it was promised.
4. Then: seed-roll the RBF for the +0.009 ns margin, refresh releases/, and
   prep the mister-devel publish package (the push itself is the user's call).

## Verified state (both repos pushed)

- Core repo branch `pds-enet-icache-fix` @ `9426615`. Release cut `638a70b`:
  `releases/MacLC_20260826.rbf` (= fc2657a8, RTL untouched all session) +
  `releases/MiSTer` (= Main `73e34262`, commit `11651c7`).
- Main fork `mac-ethernet` @ `1cbb0e1` = the watchdog commit — **one past
  the blessed binary**. `73e34262` (= `11651c7`) is deployed on BOTH boxes
  and is the known-good download baseline. `mac_sonic_test` = 86 checks
  (build cmd in its header; g++ on WSL; the ARM cross build:
  PATH=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin,
  `make -j8` in /mnt/c/Temp/mistercore/Main_MiSTer → `bin/MiSTer`).
  Builds are md5-reproducible same-day (verified: `73e34262` twice).
- Boxes (subnet is **192.168.99.x** — NOT .1.x; ssh -i ~/.ssh/mister_only):
  `.94` = tester twin (guest MAC suffix :01 via games/MacLC/eth.cfg — two
  boxes on one LAN with the same suffix BLACKHOLE each other, switch
  MAC-flap, watched live), `.143` = bench (suffix :00). Both: Main
  `73e34262` running (verify `/proc/$(pidof MiSTer)/exe` md5, never the
  file), cores loaded, guests at desktops, clocks correct (16:20 EDT
  verified on both screens).
- Guest time is SOLVED: .94 was missing `/media/fat/linux/timezone`
  (installed, Eastern TZif; /etc/localtime symlinks there) — and cores
  loaded <~30 s after Linux boot seed pre-NTP/TZ time, so **sleep ≥20 s
  after reboot before `load_core`**, ≥120 s for the guest desktop.
- FTP: both boxes run a daemon on :21, login `root`/`1`, lands in /root
  (read-only!) — use Directory `/media/fat`. Test file: `dd urandom →
  /media/fat/testfile.bin bs=1M count=3` on the PEER box. ★ A stalled
  upload TRUNCATES the server file (seen at 1 K/7 K/11 K) — **restage 3 MB
  before every download test.**

## The upload stall — exact evidence at close

Round-numbered stalls, each on a better Main (layers already fixed and
SHIPPED: EA 24-bit mask, GRO-off, wire-FCS strip, elasticity queue, ring
slurp, chain budget + tight apply/resume, 250 ms RPC patience — see memory):

- Stalls #1–#4 had plumbing causes (EMSGSIZE / ring throttle deadlock /
  chain monopoly / a hard guest FREEZE with stopped clock). All fixed; the
  tight apply/resume loop (`11651c7`) ended the freezes — the guest clock
  now TICKS through stalls.
- **Stall #5 (the live fingerprint, Main `73e34262`): deterministic-ish
  early stop** — server received exactly 5,684 bytes twice in a row, then
  11,240 on the watchdog build — with EVERYTHING clean: ring_ovf 0,
  rpc_fail 0, tx_fail 0, ea_strip 0, rx_jumbo 0, sock_drops 0. End state:
  `crda=0001` — the RX ring parked on a bare odd link; every subsequent
  frame refused (rx_refused climbing hundreds), so no PKTRX, so the guest
  ISR never runs (`regwr 05=` frozen), so nothing ever repairs the ring.
  Guest alive (clock ticking) but MacTCP deaf and mute; ping 100 % loss
  (it answered 3.7 ms during download crawls — the layer-splitting
  measurement). `regwr 0E=1`: the driver NEVER writes CRDA at runtime — it
  re-arms rings purely by link rewrites, and its ring-repair path lives in
  a timer handler.

## Lead hypothesis (check FIRST): the driver's deadman = the SONIC watchdog

`regwr 29/2A` = WT0/WT1 written **10,567×/session** (re-armed on ~every
interrupt), `cr=0028` includes CR.ST (timer STARTED), IMR 0x66F1 unmasks
ISR_TC (0x0080). On real silicon, when traffic stops (parked ring), WT
expires → TC interrupt → the driver's timeout handler repairs the ring and
kicks the stack. The model never counted → TC never fired → **every wedge
real silicon shakes off was permanent here.**

Implemented at `1cbb0e1`: 32-bit {WT1,WT0} down-counter, ~8 counts/µs
(datasheet: one count per two bus clocks), ticked from mac_eth_poll with
wall time, ISR_TC once per expiry, quiet until re-armed. 86 unit checks
incl. rate/expiry/IMR-gate/no-refire/re-arm. **Two HW runs, both dirty —
neither validates nor refutes it:**
- Run 1 confounded: .143's core VIDEO/capture died mid-test (capture-dead
  oracle; a LINUX REBOOT restored it — transient, not the fit) and the
  card stats reset mid-run (card_stop/start — suspect a sel_snapshot()
  status-read glitch during the video event). Upload reached 11,240 =
  2× the old stall before the collapse — weak evidence FOR the watchdog.
- Run 2 suspicious: a DOWNLOAD (previously bulletproof) crawled at 71 B/s
  then "no connection in place". If TC fires too often/too fast it could
  flood the guest with timer interrupts — **calibrate before blaming**:
  the SONIC's own bus clock is likely 20 MHz (→10 counts/µs, not my 8),
  and MAME `src/devices/machine/dp83932c.cpp` is the semantics oracle
  (does WT reload? does TC re-fire? exact rate?). docs/mame_compare.md
  has the MAME workflow.

Checks, in order:
1. **MAME first** (cheap, no HW): read dp83932c.cpp's watchdog + CRDA-
   reload semantics. Fix rate/semantics diffs in `sonic_time_tick()` +
   add a unit test pinning the MAME behavior.
2. Redeploy the (corrected) watchdog Main to BOTH boxes; gate order:
   **download 3 MB first** (must hold 60+ KB/s — this is the regression
   gate run 2 failed), then the 3 MB PUT watched to completion
   (`stat -c %s` on the server file ≥ 3145856).
3. If the PUT still stalls: the deterministic 5,684-byte point says a
   specific protocol moment — capture it: tcpsnoop on BOTH boxes (in the
   Main fork `support/mac/test/tcpsnoop.c`, static ARM, build cmd in
   header; /tmp is WIPED by reboots — redeploy each time) covering the
   upload START, plus `ss -ti` on .94 (the receiving side). Compare what
   the guest wired (tx_bytes) vs what arrived (bytes_received) vs what
   got ACKed.
4. If the ring still parks (`crda=0001` again): suspect the CRDA-reload
   race — `sonic_rx_frame()` re-reads DA(URDA,LLFA) on EVERY refused
   frame (thousands of ~100 µs RPC reads racing the driver's ISR-time
   recycler; real silicon's read is µs-atomic). Options: read the link
   once per park-episode with a re-read only after an ISR write applies;
   or validate reload values (a bare 0x0001 = stay parked, only a value
   pointing into the RDA page rejoins). Check MAME's reload behavior
   first. tb: extend mac_sonic_test with refuse/redeliver/recycle
   interleavings (the harness already has alog ordering assertions).
5. The HUD fingerprint if the guest wedges NON-ring-wise:
   `MacLC_HUDDBG.rbf` (= c48648a9, HUD rows 12/13 = last two distinct bus
   addresses + IPL, row 14 = card witnesses, marker row 0 = A5C3F00F,
   bottom-left 4 px cells, decode scripts/parse_hud.py) sits in
   .94:/media/fat/_Computer/ — copy to .143, `load_core` it, repro,
   screenshot the rows → the guest's loop address + IPL.

## Bench choreography crib (hard-won today — saves an hour of misses)

- Remote: `python tools/misterdeploy/ws_send.py --host 192.168.99.<43|94>
  "steps..."`; screenshots `bash scripts/grab_fresh.sh out.png` (.143) /
  `bash scratch/grab94.sh out.png` (.94) — grab_fresh FAILS LOUDLY on
  dead capture (exit 3); capture-dead → Linux reboot restores.
- Core load, OSD-free: `echo 'load_core /media/fat/_Unstable/MacLC.rbf' >
  /dev/MiSTer_cmd` (.143) / `_Computer/MacLC_relcand.rbf` (.94).
- Deploy cycle (Main): guest Shut Down (choreography below) or accept the
  boot advisory; `killall MiSTer` (else scp = "Text file busy") → scp to
  /media/fat/MiSTer → `reboot` → wait pidof → **sleep 20** → load_core →
  **sleep 120** → verify `/proc/$(pidof MiSTer)/exe` md5.
- Guest Shut Down (from Finder): recovery tap (`kbdRawDown:42 sleep:0.2
  kbdRawUp:42 sleep:0.8 mouseMove:16,16`), park 12×`mouseMove:-60,-60`,
  14×`mouseMove:8,0`+`4,0` → Special, `left_down`, 8×`mouseMove:0,8`+`0,4`
  → verify "Shut Down" highlighted via zoom crop (180,0,420,180), `left_up`,
  12 s → dark screen. Clicks = `left_down` sleep:1.3 `left_up`.
- Boot advisory after any hard reload ("not shut down properly") = one
  `kbdRaw:28`. Harmless; disk was idle in every case today.
- Fetch flow (.143 desktop): park top-left, 22×(8,0)+(4,0),
  24×(0,8)+(0,4) → icon at ~(359,395); select-click; Cmd-O
  (`kbdRawDown:56 kbdRaw:24 kbdRawUp:56`); dialog pre-fills stale
  .5/oldsoftware, FOCUS STARTS IN DIRECTORY: type `/media/fat`
  (53 50 18 32 23 30 53 33 30 20), Tab(15), host `192.168.99.94`
  (2 10 3 52 2 7 9 52 10 10 52 10 5), Tab, `root` (19 24 24 20), Tab,
  `1` (2), Return(28). Passwords are NEVER remembered; Host/User/Dir are.
- Get = **Cmd-G** (34), Put = **Cmd-P** (25) — button clicks near window
  edges are unreliable. 't' (20) type-selects testfile.bin but FIRE IT
  AFTER the listing finishes (re-fire if it landed mid-load). Save dialog
  = Return. **"Replace existing?" default is CANCEL** — must CLICK
  Replace (position varies; screenshot, then aim). Put's file dialog:
  't' → TattleTech, 2× `kbd:down` → testfile.bin, Return, Return
  ("Put file as"). Fetch wraps uploads in MacBinary (3,145,856 for the
  3 MB file).
- MacTCP loads LAZILY: a fresh guest answers no ARP/ping until a TCP app
  opens — not eth-dead. A wedged upload's Cancel can hang minutes
  ("Canceling…") — reboot is the recovery, don't wait.
- Samplers: upload completion = `stat -c %s /media/fat/testfile.bin` on
  .94 to ≥3145856; download rate = rx_ours bytes deltas from
  /tmp/mac_eth_stats (subtract ~2–3 KB/s ambient broadcast). stats
  decode: `rx_held/max_depth` (elasticity queue), `rx_jumbo` (GRO leak),
  `ea_strip` (24-bit dirty pointers), regwr `05`=ISR acks, `29/2A`=WT
  arms, `0E`=CRDA writes, `sonic crda=` health (0001 = parked orbit).

## Gates for any change

mac_sonic_test (86+, extend for what you fix); **downloads 3 MB at
60+ KB/s on BOTH boxes = the regression gate, run before celebrating any
upload result**; the 3 MB PUT completing with the guest ALIVE after
(clock ticking, ping answers once Fetch is open, a second transfer
works). RTL is untouched — no Quartus/sim gates needed unless that
changes. One boot is never a verdict (per-fit laws stand); the .143
video-capture death was transient (Linux reboot fixed) — retry before
blaming a build.

## Parked (don't lose)

- 32-bit re-validation post-fix (promised; fixes are mode-agnostic).
- Seed-roll fc2657a8 (+0.009 ns) + re-gate before any org publish;
  mister-devel publish = the user pushes (org repo still ships pre-v2).
- Release notes must tell multi-box testers: distinct MAC suffixes
  (OSD o03 nibble or eth.cfg `mac=08:00:07:4D:4C:0N`).
- .94 restock when all done (remove user-startup.sh + remote, restore
  MiSTer.bak_stock_20260826) — user's call.
- tcpsnoop.c stays in the Main fork test/ dir — the tool that cracked
  GRO and the FCS EMSGSIZE; use it on both endpoints for any TCP mystery.
