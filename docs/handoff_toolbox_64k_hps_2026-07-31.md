# HPS handoff — Toolbox 64 KB chunks (Main_MiSTer), 2026-07-31

Paste the block below as the opening message of a `../Main_MiSTer` session.
The MacLC core side is being done separately; **both sides must deploy
together** — see §4.

---

## THE PROMPT (paste this)

> Raise the BlueSCSI Toolbox transfer chunk ceiling in `Main_MiSTer`
> (branch `add-bluescsi-toolbox-for-MacLC`) from 4 KB to 64 KB, in
> `support/mac/mac_toolbox.cpp`. Read
> `../MacLC_MiSTer/docs/handoff_toolbox_64k_hps_2026-07-31.md` first —
> it contains the hardware measurements that justify the change and the
> exact contract the core expects.
>
> This is a **correctness** fix first and a speed fix second: the official
> BlueSCSI SD Transfer app asks for 64 KB in both directions, today's
> handler silently returns/accepts 4 KB, and the client advances its
> offset by the full amount — so 15/16 of every download and ~94% of
> every upload is dropped with a GOOD status.
>
> Do NOT edit the MacLC core repo. Do not push or open PRs.

---

## 1. What was measured (hardware, 2026-07-31)

JTAG CDB capture on the MacLC bench, official BlueSCSI SD Transfer app:

| | client asks for | handler gives | client then advances |
|---|---|---|---|
| `0xD1` GET | `CDB[6]=16` → **65536 B** | 4096 B | the full 16 blocks |
| `0xD4` SEND | `CDB[6]=127` → **65024 B** | 4096 B | the full chunk |

Proof of the damage: a 2,097,152-byte file downloaded then uploaded back
returned **32 correct 4 KB blocks spaced exactly 16 apart, 480 all-zero
blocks, 0 wrong blocks**. The spacing IS the 16-block skip.

The client does **not** gate this on our capability byte — it was verified
with `CAP_LARGE_SEND` both advertised and cleared, and the `0xD1` request
stayed at `CDB[6]=16` either way. Capability flags cannot fix reads.

Speed context (also measured): the bottleneck is ~15 ms of guest overhead
**per command**, not per byte, so throughput scales with chunk size —
512 B chunks give 28 KiB/s, 64 KB chunks project to ~218 KiB/s against a
230 KiB/s data-phase ceiling.

## 2. The changes

Both in `support/mac/mac_toolbox.cpp`.

**(a) `tb_get()` — drop the read clamp.** Currently:

```c
// Never stage more than the core's tb buffer holds (TB_ADDRW=11 -> 4 KB)
if (want > 4096) want = 4096;
```

The premise is obsolete: the core no longer needs the whole response
resident (it streams the serve from an 8 KB ring). Raise the ceiling to
`TB_GET_MAX` (65536) and let `tb_ch.resp` hold it — it is already an
unbounded `std::vector`, and `tbx_fill()` already serves it by LBA, so a
128-sector response needs no other change. Keep a ceiling: an unbounded
`blocks` byte would otherwise let a bad CDB allocate 255×4096.

**(b) `TB_CHUNK_MAX` / `tb_tail` — accept a 64 KB write.**

```c
#define TB_CHUNK_MAX   4096      // -> 65536
#define TB_TAIL_BLKS   ((TB_CHUNK_MAX + TB_PAYLOAD_OFF - 1) / 512)   // 8 -> 128
```

`tb_send_data()` already reassembles `chunk` from the 16-byte-offset head
plus `tb_tail`; with the constants raised it works unchanged. Check that
`tb_tail` is a static/heap buffer, not on the coroutine stack (`chunk`
already carries a `static` for exactly this reason — 64 KB must not go on
the stack either).

## 3. The core↔HPS contract is UNCHANGED

Deliberately. The core still:

- writes the CDB into **block LBA 0**, payload starting at **byte 16** of
  that block (`TB_PAYLOAD_OFF`), and
- ships payload sectors as **LBA 1..N**, where logical sector *k* → LBA
  *k*, arriving **before** the LBA 0 block that runs the handler.

The only difference is that N can now be up to 127 instead of 8, and the
sectors arrive **interleaved with the Mac's data phase** rather than all
at once after it. The handler cannot tell the difference — it still acts
only when LBA 0 arrives. No layout change, no new opcode, no versioning.

## 4. Deploy order — they must land together

- New HPS + old core: harmless. The old core clamps the phase to 4 KB and
  never asks for more, so behaviour is exactly as today.
- New core + old HPS: also harmless **only because the core keeps
  `TB_CAPS = 0x00`** until the HPS is confirmed deployed. With the advert
  cleared the client uses 512-byte v0 sends and the streaming path is
  inert.

So: ship the HPS first, confirm it, then the core flips `TB_CAPS` to
`0x02` (a one-line change in `rtl/scsi.v`, already commented in place).
**Do not flip the advert before the HPS is live** — that is precisely the
`6ded62d` regression that dropped 94% of every upload.

## 5. Verification the core side cannot do

The core work is bench-verified only (`scsi_bench --mode toolbox`), because
the bench models the HPS. The end-to-end proof needs both sides:

1. Download a ≥2 MB file; upload it back; `md5sum` against the original.
   PASS = byte-identical. This is the test that caught the original bug —
   the block-spacing map makes any residual truncation obvious.
2. Confirm `blocks(CDB6)=16` GETs now return 65536, not 4096. The MacLC
   side has a JTAG CDB probe for this (`scratch/tbcdb.tcl` plus the patch
   in `scratch/tbcdb_probe_diff_20260731.patch`).
3. Watch for a short final chunk at EOF — `fread` returning less than
   `want` must still report GOOD and the client must stop cleanly.

## 6. Build/deploy crib (from the project memory)

- Toolchain: `/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin`
  (Linaro gcc 10.2, glibc-safe). Do **not** use Ubuntu's apt cross gcc 13 —
  its glibc 2.38+ binaries fail at runtime on the MiSTer.
- Syntax check: `wsl.exe -e bash -lc 'export PATH=/opt/gcc-arm-.../bin:$PATH && cd /mnt/c/Temp/mistercore/Main_MiSTer && arm-none-linux-gnueabihf-gcc <DFLAGS> -std=gnu++14 -fsyntax-only support/mac/mac_toolbox.cpp'`
- Deploy: the running binary cannot be overwritten in place (`ETXTBSY`) —
  `scp` to `MiSTer.new`, then `mv` over.
- Bench is `192.168.99.143`; current binary is `cbd9db75` (mtime 07-31
  12:16), and `/media/fat/MiSTer.prev` is the rollback.

---

## 7. ADDENDUM (2026-07-31, after the HPS session) — the 17-bit length

The HPS session implemented §2 and found a defect in this document's claim
that "the contract is unchanged". It is not quite: a **65536-byte GET is
not expressible**.

`tb_len` was a 16-bit register loaded from status-block bytes 2..3, so the
largest reportable length was 65535 — but a `CDB[6]=16` GET asks for
exactly 65536, and this client zero-fills whatever it does not receive and
advances by the full request. That is one corrupted byte per 64 KB chunk,
and it fails the §5.1 md5 round trip. SEND is immune: its lengths come
from the CDB (max 127×512 = 65024).

**Agreed encoding** (HPS session's proposal, implemented core-side):

- status block bytes 2..3 = `length[15:0]` (unchanged)
- status block **byte 4 bit 0 = `length[16]`** (was reserved-zero)

Core side is done: `tb_len` is now 17 bits, decoded as
`{byte4[0], byte2, byte3}`, and the status-only test looks at all 17 bits —
a 65536-byte response has bytes 2..3 == 0 and would otherwise be read as
"no data". HPS side is the one-line follow-up the session left pending.

**Transient risk, deliberately accepted.** New HPS writing the byte-4
encoding + an old core reading only bytes 2..3 sees length 0 for exactly
65536 and takes the status-only path — the client then gets nothing rather
than a short serve. This only bites in the mixed state, which §4's deploy
order already forbids. Note the *current* box is safe: the HPS clamps the
reported length to 0xFFFF (`mac_toolbox.cpp:70`), so today's new-HPS/
old-core combo degrades to a short serve, not a wedge. Whoever changes
that clamp to the byte-4 encoding must land the new core in the same pass.
