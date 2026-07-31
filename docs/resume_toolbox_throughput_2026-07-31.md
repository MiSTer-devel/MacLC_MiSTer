# Resume — BlueSCSI Toolbox throughput, CORE SIDE ONLY (2026-07-31)

Paste the block below as the opening message of the next session.

---

## THE PROMPT (paste this)

> Make BlueSCSI Toolbox file transfers faster on the MacLC core
> (`C:\Temp\mistercore\MacLC_MiSTer`). Read
> `docs/resume_toolbox_throughput_2026-07-31.md` first — it is the
> authoritative state and contains the arithmetic that scopes the work.
>
> Current on hardware: **upload ~300 KB/s, download ~125 KB/s**.
> Target: **600–800 KB/s**, which is what a real BlueSCSI does.
>
> **SCOPE: core RTL only** (`rtl/scsi.v`, `rtl/ncr5380.sv`, the bench).
> Main_MiSTer is already optimised and is NOT in scope. If you conclude
> an HPS change is required, STOP and write a separate handoff prompt
> for the `../Main_MiSTer` session — do not edit that repo.
>
> Start by MEASURING (§5), not by optimising. The one thing this
> project punishes hardest is acting on an unmeasured hypothesis.

---

## 1. Where transfers stand

Correctness is done and validated; this is purely a speed mission.

| | rate | ms per 4 KB chunk |
|---|---|---|
| upload (SEND, Mac→SD) | ~300 KB/s | 13.7 |
| download (GET, SD→Mac) | ~125 KB/s | 32.8 |
| **target** | **600–800 KB/s** | **5.1–6.8** |

Both directions move **4 KB per command** and cost **exactly 10 HPS
transactions** per chunk:

- SEND: 8 tail-block writes (LBA 1..8) + 1 CDB write + 1 status read
- GET: 1 CDB write + 1 status read + 8 data-sector reads (LBA 1..8)

## 2. The arithmetic that scopes the work — read this before theorising

Because the transaction count is identical in both directions but the
rates differ 2.4×, there are **two separate cost terms**:

1. **A common term** (round trips / HPS turnaround), bounded above by
   the faster direction: **≤ 13.7 ms per 4 KB**.
2. **A download-only term** of **~19 ms per 4 KB**, which lives in the
   DataIn serve path.

**Both must be attacked to reach the target**, because the target is
5.1–6.8 ms per 4 KB — *less than the common term already costs*. An
earlier session note said "round trips are not the bottleneck"; that is
only true of the *difference* between directions. In absolute terms the
common term alone already misses the target. Do not repeat that error.

At 10 transactions per 4 KB, the upload rate implies ~1.37 ms per HPS
transaction. Hitting 700 KB/s with the present structure would need
~0.58 ms per transaction — so either transactions get much cheaper
(HPS-side ⇒ out of scope), or the core must stop paying for them
serially. That points at overlap, not micro-optimisation.

## 3. Core-side levers, ranked

**(a) Overlap the HPS fetch with the SCSI serve.** Today `TBS_DATA`
fetches ALL 8 sectors before a single byte is served, so 8 HPS latencies
are fully exposed and nothing is hidden behind the transfer. The disk
read path solved exactly this with a ring + look-ahead prefetch — the
Toolbox path never got the same treatment. Serving sector *k* while
fetching *k+1* could hide most of the common term. **This is the most
promising lever and it is entirely core-side.**

**(b) The per-byte serve settle (`tb_srv_hold`).** Ported from MacIIvi to
fix a real dpram read race: for a few cycles after each word-address
change the port-B register holds the wrong word, so REQ is held down
~8 cycles per byte. Raw cost is only ~250 ns/byte (~3% at current
rates) — *but it gates `req_bus`, which drives DRQ*. If the client uses
pseudo-DMA rather than byte-at-a-time PIO, throttling DRQ once per byte
could cost far more than the raw cycles, and could also desynchronise
the host's polling loop so each byte waits a whole loop iteration.
**Determine first whether the Toolbox data phase runs as PIO or
pseudo-DMA** — that single fact decides whether this lever matters.
Do not simply delete the settle: it exists because removing it
corrupts every even byte.

**(c) Fewer, larger transactions.** `TB_ADDRW=12` (8 KB) is already in
place and `TB_MAXSEC=16`, so the buffer can stage 8 KB. Raising the
chunk to 8 KB halves the per-chunk transaction count. Cheap to try
*if* (a) does not already hide the cost — but see the RAM ceiling in §6,
and note the HPS handler currently caps `TB_CHUNK_MAX` at 4096, so
going beyond 4 KB **needs an HPS handoff** (out of scope here).

**(d) `CAP_LARGE_TRANSFERS` (0x01) for multi-block GET.** Deliberately
NOT advertised. It only reduces round-trip count, so it is a weaker
form of (c), and its read path has no bench coverage. Do not advertise
it without both.

## 4. What is already ruled out

- **Main / HPS file I/O.** Buffered 64 KB writes with a seek guard
  (`4370d00`) and 4 KB chunk support (`952994d`) are deployed and
  verified; the GET response is staged in an unbounded `std::vector`.
- **Chunk size on the wire.** Both directions already use 4 KB.
- **Correctness defects.** Short-final-chunk truncation, the 16-byte
  holes and the PIO serve race are fixed and hardware-validated.

## 5. FIRST MOVE — measure, do not guess

Build a probe RBF (the workflow from the volume-law mission works: set
`USE_DBG_PROBES=1` in `MacLC.qsf` **working-tree only**, repurpose a CDA
probe word, read with a Tcl script modelled on `scripts/vol_probe.tcl`).

Four free-running counters, sampled before and after one download of a
known size:

| counter | meaning |
|---|---|
| A | cycles in `TBS_REQ/REQ2/STAT/LATCH/DATA` — waiting on the HPS |
| B | cycles in the serve phase (`PHASE_DATA_OUT && cmd_tb_fs_in`) |
| C | cycles within B with `req` asserted and `!ack` — waiting on the Mac |
| D | bytes served |

Interpretation:
- **A dominates** ⇒ lever (a), overlap fetch with serve.
- **B dominates and C ≈ B** ⇒ the guest is the limit; check whether the
  data phase is PIO or pseudo-DMA before concluding anything, then
  consider (b).
- **B dominates and C ≪ B** ⇒ the core is stalling its own serve; that
  is a core bug and the counters will point at it.

Keep JTAG sessions SHORT — long probe loops wedge the HPS on this bench.

## 6. Constraints and laws

- **RAM is at 513/553 (93%)**. Each `TB_ADDRW` step doubles both lane
  dprams: 8→11 cost +2 blocks, 11→12 cost +4, so 13 ≈ +8 and 14 ≈ +16
  (~537/553 ≈ 97%). Any new memory re-rolls every unpinned RAM in the
  design — the "migrating victim" behaviour this project has been bitten
  by repeatedly. Audit `map.rpt` global totals against the last-good
  build BEFORE running the fitter.
- **Never advertise a capability ahead of the buffer.** A client that
  sees `CAP_LARGE_SEND` *will* send block-encoded chunks.
- **Serving law:** transfer EXACTLY what the initiator armed. Over- and
  under-serving are both hardware-witnessed bus wedges here.
- **Gate procedure:** CD image DETACHED from boot config
  (`config/MACLC.s4` moved aside), one screenshot at +118 s, PASS =
  MacAtrium browser with colour icons, reference md5 `94fedd19`.
  `scratch/gate.sh` automates it. One boot is never a verdict.
- `sys/` is off-limits. `MacLC.qsf` seed/macro flips are working-tree
  only and must never be committed.
- Do not push or open PRs — the owner does their own.

## 7. Branch and build state

Branch `toolbox-large-files` (cumulative, each layer revertable):

```
bfd7c6d  toolbox: core stage 1 — 4 KB block-encoded SEND (CAP_LARGE_SEND)
5d87ace  toolbox: port the large-file transfer fix from MacIIvi
a0b665c  docs: carry the CD volume-law evidence onto the shippable branch
0089c82  cd_audio: apply the MEASURED hardware volume law
...       (cd-volume-v2: six SCSI commands + the 12-byte CDB fix)
```

Deployed and gated: **`066e4d44`** (seed 5, STA +0.251, RAM 513/553).
Main on the bench: **`cbd9db75`**, verified byte-identical to a clean
rebuild of the committed stage-1 source.

Bench coverage: `--mode toolbox` includes a large-send case that pushes
9728 bytes as 4 KB block-encoded chunks plus a short final chunk and
byte-compares the result. `--mode toolboxslow` models an HPS that stalls
past the watchdog. Run the full set before any build:
`toolbox / toolboxslow / cdvol / gapcmds / longskew / --id 0 sweep`.

## 8. Reference

A real BlueSCSI sustains **600–800 KB/s**, which is the bar. It is worth
establishing early whether that figure is for PIO or DMA transfers on
comparable hardware, because it decides whether §3(b) is the whole story
or a footnote.
