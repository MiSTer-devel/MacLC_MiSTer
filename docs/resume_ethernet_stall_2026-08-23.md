# RESUME — PDS Ethernet: throughput fixed, TX stall + guest freeze still open

Paste this as the opening prompt of a new session. Two trees:

- **Core:** `C:\Temp\mistercore\MacLC_MiSTer`, branch **`pds-enet-icache-fix`**, HEAD `88d1db5`
- **Main (HPS):** `C:\Temp\mistercore\Main_MiSTer`, branch **`mac-ethernet`**, HEAD `15696e6`
- **Bench:** `192.168.99.143` (creds/paths in `scripts/local.env`; `$MISTER_HOST`, `$MISTER_SSH_KEY`)

Read `CLAUDE.md`'s ethernet section and `docs/pds_ethernet_scope.md` (the mailbox
contract) first. The card is Apple's Ethernet LC Twisted Pair (SONIC DP83934);
the FPGA half is `rtl/pds/pds_enet.sv`, the host half is the Main fork's
`support/mac/mac_eth*` + `mac_sonic*`. **The modified Main is REQUIRED.**

## The three problems, and where each stands

**1. Throughput ~2 KB/s — ROOT-CAUSED AND FIXED (Main `00161b5`).**
`dma_rpc()` checked the mailbox once then called `usleep(50)`. **`usleep(50)`
does not sleep 50 us** — it costs a scheduler round trip, ~1 ms here. The FPGA
answers in ~32 us, so the first check nearly always missed and every RPC paid a
millisecond. At **5 DMA-RPCs per received frame** that is ~5 ms of work inside a
1 ms poll budget: the RX pump starved, the AF_PACKET socket buffer (default
~160 KB, never enlarged) overflowed, and TCP answered the loss with retransmit
timeouts. Fix = spin on the uncached mailbox word before ever sleeping, plus
`SO_RCVBUF` 1 MB and a time-bounded RX drain. **Measured after: `rpc_us_avg`
85-91 us, `sock_drops` 0.** ★ General law: never `usleep()` waiting on FPGA
mailbox latency — spin first, sleep only for the pathological tail.

**2. Periodic TX stall — OPEN.** `tx_frames` freezes 8+ s, emits 1-4 frames,
freezes again, indefinitely. The guest driver is ALIVE during the stall
(~110 register writes/s, all `WT0`/`WT1` watchdog re-arms per the `regwr`
histogram) and is still taking and clearing PKTRX interrupts. It simply never
asks to transmit. Untested hypothesis at handoff: the ~8 s rhythm matches **ARP
retry timing**, not TCP RTO — `arp rx/tx` counters were added for exactly this
(`15696e6`) but have **never been read on hardware**.

**3. Guest hard freeze — BACKSTOP BUILT, ROOT CAUSE UNKNOWN.** On 2026-08-23 a
guest froze: dead screen, **zero bus activity** (the FPGA doorbell `wptr` frozen
solid), Linux and Main perfectly healthy. `card_ack` IS the guest's DTACK, and
nothing bounded it: a register write waits for a ring slot, a declROM read for
the DDR3 mailbox, and if either starves, `hstate` parks in `H_RUN` and the
68020 waits forever mid-cycle. Core `5725991` + `88d1db5` add a ~4 ms watchdog
that retires the cycle with open-bus `$FFFF`, plus `h_abort` (an abandoned
read's late DDR3 answer must not retire the NEXT access with stale data) and
CPU-priority gating on the DMA dispatch. **The watchdog is a backstop, not a
cure** — something still starves that FSM for >4 ms. `h_wd_fired` (sticky reg)
and the stats' `ring_max` say whether it fires in practice.

## RULED OUT BY MEASUREMENT — do not re-tread

| theory | how it died |
|---|---|
| RX resources exhausted (RDE/RBE) causing the stall | ISR shows `0x40` only AFTER the guest is already dead; during stalls `isr=1000`/`1400` and `crda` keeps cycling |
| Doorbell ring overflow losing register writes | `wptr`==`rptr` continuously, backlog ~0, `ring_max` 200 (cap 256) |
| Lost interrupt | PKTRX both sets AND clears; INT word read directly via `devmem 0x1FF20090` = 1 exactly when `ISR & IMR` is nonzero |
| Socket-level packet loss (after the fix) | `sock_drops` 0 across every run |
| "The DMA-RPC fix made it worse" | FALSE — those hangs were measured against the OLD binary that was still running |

## Instrumentation you already have

`/tmp/mac_eth_stats`, rewritten once a second (counters only in the packet path):

```
rpc / rpc_slept / rpc_fail / rpc_us_avg / rpc_us_max
rx_frames rx_bytes      <- ALL promiscuous traffic INCLUDING YOUR OWN SSH. Not a transfer rate.
rx_ours   bytes         <- broadcast/multicast + frames addressed to the guest MAC. Use THIS.
rx_refused              <- model refused (RXEN clear, or RDE/RBE latched)
tx_frames tx_bytes tx_fail
txp_cmds                <- CR writes carrying TXP: transmits the guest ASKED for
sock_drops
ring_max  ring_ovf
arp rx/tx   ip rx/tx    <- ethertype split, never yet read on HW
regwr XX=count          <- per-register write histogram (05=ISR, 29/2A=WT0/WT1, 00=CR)
sonic cr= isr= imr= crda= rrp= rwp=
```

Decision table at the next stall:

- `txp_cmds` climbing, `tx_frames` flat → transmits requested and swallowed in
  `transmit_chain` (our bug, in the model).
- `tx_fail` climbing → the guest transmitted, we failed to put it on the wire.
- both flat, `regwr` busy → the guest genuinely stops asking; read the histogram.
- `arp tx` climbing with `arp rx` flat → ARP replies aren't passing the address
  filter. Suspect the CAM — **and note the guest MAC changed on 2026-08-23**.

Watcher: `/media/fat/linux/ethwatch.sh` — silent until the instrumented Main is
live, then emits `TX-STALL` (with the histogram), `TX-RESUME`, and alarms on
`tx_fail`/`ring_ovf`/`rpc_fail`. Drive it with the Monitor tool over one
persistent ssh; do NOT poll in a loop (your own traffic pollutes the counters).

Direct DDR3 peeks (window base ARM `0x1FF00000`):
`devmem 0x1FF20000 64` MAGIC ("McLCETH2"), `0x1FF20008` WPTR, `0x1FF200A8` RPTR,
`0x1FF20090` INT.

## Deploy state at handoff

| what | value |
|---|---|
| Main on the box (disk) | `6148f025` — **verify what is RUNNING, not the file** |
| RBF on the box | `ed223ac8` (OSD-options build, no watchdog) |
| Validated rollback Main | `/media/fat/MiSTer.bak_pre_osdopts` = `932ed605` |
| Last released pair | `releases/MacLC_20260822.rbf` (`4f31e0dd`) + `releases/MiSTer` (`932ed605`) |
| Watchdog RBF | **building at handoff** — check `scratch/build_wd2.log`; the FIRST attempt FAILED timing (hold −0.573 ns, `clk_sys→clk_mem`) and was restructured in `88d1db5` |

## Gates (all must pass before any deploy)

```bash
# core unit TB — 48 checks (43 + 5 watchdog)
cd verilator && verilator --binary -j 0 -Wno-fatal --timescale 1ns/1ps \
  tb_pds_enet.v sim_ddr3.v ../rtl/pds/pds_enet.sv -o tb && ./obj_dir/tb
# host model — 36 checks
cd support/mac/test && g++ -O1 -Wall -o /tmp/mst mac_sonic_test.cpp ../mac_sonic.cpp && /tmp/mst
# boot gate, card ABSENT and card PRESENT
./obj_dir/Vemu --screenshot 450 --stop-at-frame 451
./obj_dir/Vemu +pds_magic +pds_rom=pds_declrom.hex --screenshot 450 --stop-at-frame 451
```
Frame 450 must show the 50% dither grey desktop **with the arrow cursor**.
`check_boot.sh` has CRLF on this checkout — run a `tr -d '\r'` copy.
Quartus: STA must be met **including hold** — this feature sits on the
`clk_sys→clk_mem` crossing and wide combinational logic there costs hold slack.
A green STA is NOT sufficient: per-seed video on HW is law for this core.

## Process laws (each cost real time today)

1. **A Main binary swapped on disk does not take effect until reboot** —
   `/etc/inittab` launches it once at Linux boot. Always verify
   `md5sum /proc/<pid>/exe`, never the file. Two hangs were attributed to a fix
   that had never run.
2. **"Reboot" means the MiSTer, not the Mac guest.** Replacing Main needs a full
   Linux reboot; reloading the core is not enough.
3. Overwrite a running Main by **scp to `MiSTer.new` then `mv`** — writing in
   place fails with `ETXTBSY`.
4. `eth0` is promiscuous: `rx_frames`/`rx_bytes` include your own ssh. Use
   `rx_ours`, and keep polling minimal while measuring.
5. Busybox on the box has **no `pgrep`** (use `ps | grep`) and no `tcpdump`.
6. Patching files via python from git-bash: run scripts through
   `wsl.exe -e bash -c 'python3 /mnt/c/...'` (bare `wsl.exe -e python3 /mnt/...`
   gets its path mangled), anchor replacements on text **without leading
   whitespace**, and build C escapes explicitly (`chr(92)+'n'`) — a `\n` written
   naively lands as a real newline inside a C string literal and breaks the build.

## Suggested next steps

1. Confirm the watchdog build met timing; run both boot gates; deploy RBF + Main
   together; reboot; verify the RUNNING hashes.
2. Reproduce the stall and read `/tmp/mac_eth_stats` once — the decision table
   above should name the cause. The ARP counters are the freshest lead.
3. If `h_wd_fired` is set on HW, the freeze path is real and still needs a root
   cause: instrument WHICH `req_kind` was parked and what the mailbox FSM state
   was, rather than only that it fired.
4. Separately: even healthy throughput was only ~9 KB/s (frames ~193 B average).
   Expect far more from a real LC. Prime suspect is interrupt latency —
   `IRQ_SUPP` (~1.85 ms after each guest ISR write, `pds_enet.sv`) plus Main's
   ~1 ms poll inflating the RTT of a window-limited TCP connection. `IRQ_SUPP`
   is the documented lever to tune DOWN, and it has never been tried.
