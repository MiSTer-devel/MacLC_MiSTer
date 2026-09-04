# RESUME — PDS Ethernet: RX-freeze FIXED & shipped to bench; a NO-TX stall is open

Paste as the opening prompt of a new session. Two trees:

- **Core:** `C:\Temp\mistercore\MacLC_MiSTer`, branch **`pds-enet-icache-fix`**, HEAD `3ac0d1c` (pushed to origin/danifunker)
- **Main (HPS):** `C:\Temp\mistercore\Main_MiSTer`, branch **`mac-ethernet`**, HEAD `b3b0ed1` (pushed to origin/danifunker)
- **Bench:** `192.168.99.143` (creds/paths in `scripts/local.env`; `$MISTER_HOST`, `$MISTER_SSH_KEY`). This host box is `192.168.99.83` on the same LAN.

Read `CLAUDE.md`'s ethernet section, `docs/pds_ethernet_scope.md` (the mailbox
contract — now carries the **ORDERING LAW**), and the memory files
`pds-ethernet-freeze-rootcause` + `pds-ethernet-perf-2026-08-23` first.

## What shipped this session (DONE, HW-validated)

**The guest HARD-FREEZE is root-caused and fixed.** `mac_sonic.cpp`
`sonic_rx_frame` published an RX descriptor's **status word first** and read its
link ~100 µs later (each host op is a DMA-RPC). The Apple driver recycles a
descriptor the instant status≠0 — rewriting its link — inside that window, so
the model followed a torn link: `CRDA` left the descriptor ring and the guest
spun forever in its ISR at IPL≥2 around a `link=0` self-orbit at guest `$0C0000`
(Ticks frozen, zero doorbells). Fix (**Main `b3b0ed1`**): body words → link read
→ in-use clear → **status published LAST as its own 1-word write**; nothing
touches the descriptor after publish. Root-caused offline from two guest-RAM
dumps taken *through the card's DMA engine while the guest was frozen*
(`tools/guestdump/`), disassembled with capstone.

Gates all green: `tb_pds_enet` 48/48, `mac_sonic_test` 43/43 (+7 publish-order
checks, they FAIL against the old code), STA met **including hold**, both sim
boot gates (card-absent AND card-present) PASS, HW clean color-desktop boot,
and a **10-min / 30k-broadcast-frame soak with zero rx_refused growth, zero
rpc_fail** (pre-fix, ~60 s of the same traffic froze the guest).

### Deploy state on the bench (verify, don't trust)

| what | hash | note |
|---|---|---|
| Main RUNNING (`md5sum /proc/<pid>/exe`) | `ccfa27a3` | = the `b3b0ed1` fix build |
| Main on disk `/media/fat/MiSTer` | `ccfa27a3` | |
| RBF `/media/fat/_Unstable/MacLC.rbf` | `0a5f8378` | watchdog build (core `88d1db5`), STA incl. hold |
| Rollback Main | `/media/fat/MiSTer.bak_pre_rxfix` = `6148f025` | also `.bak_pre_osdopts` = `932ed605` |
| Last RELEASE (not yet superseded) | `releases/MacLC_20260822.rbf` `4f31e0dd` + `releases/MiSTer` `932ed605` | **no new release cut yet — user's call** |
| Local build artifacts | `output_files/MacLC.rbf` = `0a5f8378`, `Main_MiSTer/bin/MiSTer` = `ccfa27a3` | |

No release stamped: waiting on the user's own credentialed Fetch session.

## OPEN — a NO-TX stall (what the user hit at end of session)

User relaunched Fetch and it hung on "Connecting…". Measured live:

- **NOT the freeze bug**: mouse tracks, guest RAM changes between dumps, lowmem
  `Ticks` ($16A) is incrementing, RPCs climb. Machine is alive.
- **NOT the ISR livelock**: ISR-write counter (`regwr 05=`) went **flat**, RPCs
  fell to ~6/s. No RX flood in progress.
- **The tell — ZERO outbound frames**: `txp_cmds` frozen at 96, `arp tx` 10,
  `ip tx` 67, unchanged across a 15 s watch. A genuine in-progress TCP connect
  retransmits its SYN every few seconds; this emits **nothing**. So the guest is
  handing the card no frames — the stall is **above the ethernet layer**
  (MacTCP / Fetch), not the card path.
- **Leading hypothesis**: earlier in the session I **force-quit** a stuck Fetch
  (Cmd-Opt-Esc → Force Quit). Force-quit does **not** `TCPRelease` the stream,
  so MacTCP's stream stays allocated and the next connect blocks on a stream it
  never gets back — a guest-OS consequence of force-quit, **not** a regression
  in today's RX fix.

**This narrows the handoff's old "periodic TX stall" #2**: when it stalls,
`txp_cmds` is frozen ⇒ the guest genuinely stops *asking* to transmit (the
decision-table branch "both flat, regwr busy"), it is **not** the model
swallowing frames in `transmit_chain`. Whether the field-reported TX stall is
the same MacTCP-side effect or a real card issue is the key open question.

### First moves next session
1. **Distinguish the two.** Cold-boot fresh, connect once, **quit Fetch
   cleanly** (not force-quit), connect again. If the 2nd connect is fine ⇒ the
   stall is force-quit/stream-leak fallout, benign. If a **first-ever** connect
   stalls with `txp_cmds` frozen and no SYN ⇒ a real guest/MacTCP or card TX
   issue to chase. (A clean FTP server with anon allowed avoids the login-reject
   detour; the bench `.5` = `daninas` FTP rejects `anonymous`. A throwaway
   no-auth server: `scratch/miniftp_local.py` here, or `/tmp/miniftp.py` on the
   box — but note the box's own IP is unreachable from the guest in eth0 mode;
   see the raw-socket law below. Run the no-auth server on a *third* LAN host.)
2. Recover the current stuck guest the Mac-authentic way: **Special ▸ Shut Down,
   then reload the core** (never hard-reload a running guest — memory
   `never-hard-reload-running-guest`). A leaked MacTCP stream also self-clears on
   a guest restart.

## Bugs/levers still open (none block the RX fix)

- **ISR stale-shadow spin — the throughput/latency lever, UNTRIED.** Under RX
  load the guest ISR re-reads the *stale* shadow ISR ~180×/frame until Main's
  ~1-2 ms shadow refresh clears it (seen as `regwr 05=` in the millions), pegging
  the CPU at IPL2. Fix sketch: serve guest ISR **reads** with the guest's own
  pending write-1-clears applied locally (mirror-own-writes) — NOT the
  deadlock-prone per-bit line-mask overlay that was already tried and reverted.
  `IRQ_SUPP` (~1.85 ms, `pds_enet.sv`) is the cruder existing lever, also untuned.
- **`tools/guestdump/ramdump.sh` collides with live RX.** During the frozen
  post-mortem it dumped a clean 10 MB; during *live* traffic this session it
  returned truncated files (4.6 MB / 590 KB) — the dump's `DMA_CMD` seq clashes
  with Main's RX-DMA sequence. Harden it: use a seq base Main won't use, or
  briefly pause Main's RX pump, or detect short blocks and retry. Only trustworthy
  today on a quiescent/frozen guest.
- **Menu-bar clock never ticks mid-session** — filed as a spawn-task chip
  (one-second-interrupt gap; lowmem `Time` $20C constant across a session while
  `Ticks` $16A advances). Pre-existing, cosmetic-plus. Separate from ethernet.

## Instrumentation & laws (each cost real time)

- `/tmp/mac_eth_stats` (rewritten 1/s). Decision table at a stall: `txp_cmds`
  climbing + `tx_frames` flat ⇒ swallowed in `transmit_chain` (model bug);
  `tx_fail` climbing ⇒ we failed to put it on the wire; **both flat + `regwr`
  busy ⇒ guest stopped asking** (this session's case); `arp tx` climbing + `rx`
  flat ⇒ replies failing the address filter (suspect CAM).
- Direct DDR3 peeks (ARM phys): MAGIC `0x1FF20000`, WPTR `0x1FF20008`, RPTR
  `0x1FF200A8`, INT `0x1FF20090`, DMA_CMD `0x1FF200B0`, DMA_STAT `0x1FF200B8`.
- `tools/guestdump/`: `memdump` (mmap /dev/mem; `dd`/`read()` EFAULT on the
  reserved DDR3 window) + `ramdump.sh` (dump 10 MB guest RAM via DMA). Both live
  at `/media/fat/linux/` on the box (persisted). Post-mortem recipe in the README.
- **Raw-socket (eth0) law**: the guest **cannot reach the MiSTer's own IP** —
  AF_PACKET egress never re-enters the host stack and switches don't hairpin.
  Guest↔box tests need tap0/macvlan, or a third LAN host. Not an ethernet bug.
- **A Main binary swapped on disk needs a full Linux REBOOT** (`/etc/inittab`
  launches it once). Always verify `md5sum /proc/<pid>/exe`, never the file.
  Overwrite via scp to `MiSTer.new` then `mv` (ETXTBSY otherwise). "Reboot" =
  the MiSTer, not the Mac guest.
- **Force-quit is not free**: it leaks the app's MacTCP stream. Prefer clean quit;
  recover a wedged app with Special ▸ Shut Down + core reload.
- OSD/mouse driving: `tools/misterdeploy/ws_send.py --host 192.168.99.143` (mouse
  is RELATIVE deltas, gain is ADB-poll-timing dependent → iterate with
  frame-diff bbox); `launch_unstable_core.py --host 192.168.99.143 --core MacLC.rbf`
  (needs explicit `--host`, default DNS name fails here). Capture with
  `scripts/grab_fresh.sh` (FAILS on dead video; stock `grab.sh` serves stale).

## Gates to re-run before ANY deploy

```bash
# core unit TB — 48 checks
cd verilator && verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
  tb_pds_enet.v sim_ddr3.v ../rtl/pds/pds_enet.sv -o tb && ./obj_dir/tb
# host model — 43 checks (incl. publish-order)
cd support/mac/test && g++ -O1 -Wall -o /tmp/mst mac_sonic_test.cpp ../mac_sonic.cpp && /tmp/mst
# boot gate, card ABSENT and card PRESENT (frame 450 = grey dither + arrow cursor)
cd verilator && ./obj_dir/Vemu --screenshot 450 --stop-at-frame 451
./obj_dir/Vemu +pds_magic +pds_rom=pds_declrom.hex --screenshot 450 --stop-at-frame 451
```
Quartus STA must be met **including hold** (this feature sits on the
`clk_sys→clk_mem` crossing). Per-seed HW video is law for this core.
