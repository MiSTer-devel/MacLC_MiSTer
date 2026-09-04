# CLOSED 2026-08-26 (same day): eth TX + throughput mission — see memory
# ★ NEXT MISSION (uploads) = docs/resume_eth_uploads_2026-08-27.md

This resume doc's mission is COMPLETE except one precisely-fingerprinted
open item. Full record: memory `eth-tx-and-throughput-fixed` +
`CLAUDE.md` ethernet section. Release cut: `releases/MacLC_20260826.rbf`
(= fc2657a8, RTL untouched) + `releases/MiSTer` (= Main fork `11651c7`,
md5 73e34262). Main fork branch `mac-ethernet` pushed through `1cbb0e1`.

Delivered, HW-measured on BOTH boxes (fresh 24-bit 7.5.5 guests):
- TX + RX both ways, FTP download 3MB end-to-end at 58-60 KB/s average,
  70-110 KB/s sustained (was 796 B/s). Two guests on one LAN concurrently.
- Seven stacked defects fixed (all Main-side): 24-bit pointer top-byte
  masking, kernel-GRO jumbo coalescing (THE 2 KB/s cause), software FCS
  making max-size TX frames EMSGSIZE-dead, RX elasticity queue, doorbell
  ring slurp during RPC waits (deadlock circle), bounded transmit chain
  with tight apply/resume, 250 ms RPC patience.
- Guest clocks: .94 had NO /media/fat/linux/timezone (installed); load
  cores >30 s after Linux boot or the seed can predate NTP/TZ.

OPEN (next session): bulk guest UPLOADS stall early (~5-11 KB) with all
plumbing clean; the SONIC watchdog timer (the driver's recovery deadman,
regwr 29/2A ×10,567) is implemented at branch head `1cbb0e1` (86 unit
checks) but its two HW runs were confounded/regressed — re-validate with
the HUD RBF (c48648a9: bus-addr rows + IPL) and calibrate the WT rate
against MAME dp83932c before shipping it. Also parked: 32-bit-mode
re-validation post-fix (low risk — fixes are mode-agnostic), the
mister-devel publish (user's call), seed-roll for the +0.009 ns margin.
