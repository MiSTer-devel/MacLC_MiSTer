# Resume — 800K floppy controller investigation (PARKED 2026-07-07)

**Read this first; it is the single authoritative handoff.** It supersedes the
morning doc `docs/findings_floppy_sdram_not_image_2026-07-07.md` (still valid as
backing analysis) and the night doc `docs/resume_floppy_content_bug_2026-07-06.md`.

Parked mid-investigation at the user's request. The bug is reproducible on demand
(protocol below — **do NOT rediscover it**), the instrumented build is HW-stable,
and this session added one new-but-**inconclusive** data point that the next
session should resolve in a single clean capture.

Branch `new-disk-features`. Nothing pushed; the user pushes.

---

## 0. TL;DR — where we are

- **Symptom (unchanged):** mounting an 800K GCR floppy (`Disk605.dsk`, a real
  HFS disk) pops **"This disk is unreadable: Do you want to initialize it?"**
- **Localization chain so far (all still standing):**
  1. Sector **headers/address fields are PERFECT** (valid checksums, `fmt=0x22`)
     — the IWM byte-syncs, the OS finds every sector. (night session, ring v1)
  2. The prior "data fields are all zero" verdict was **overturned offline**:
     `Disk605` track-0 sectors 5–11 are legitimately zero *in the file*, and the
     earlier MAME diff compared a *different* disk. (morning doc)
  3. A backward-solve of the 6-and-2 nibbler on the v1 capture recovered 138
     input bytes that exist in **no** local image, at trk0 sec7 (whose file
     content is all-zero) ⇒ **SDRAM's floppy region held stale garbage, not the
     image.** Leading theory: **the mount-time download never lands its content
     in the floppy SDRAM region.** (morning doc)
- **This session:** built the DL-counter instrument (ring v2), fought a fitter
  seed lottery to get an HW-stable build, reproduced the bug, and read the
  download counters — but the read is **INCONCLUSIVE** because the mount almost
  certainly went to the **wrong floppy drive** (see §3). One clean re-capture
  settles it.

---

## 1. ★ THE REPRODUCTION — exact, ~4 board-minutes (do NOT rediscover)

**Build to use:** `releases/MacLC_Unstable_20260707_e322926s3.rbf`
(**seed 3**, md5 `35e049246afe38e32b48c56a78d1ad50`). This is the ONLY
HW-stable instrumented build — see §5 for why seed 1/2 are unusable. It is a
descendant of `78e484c`, so the HW-validated pixel-clock fix rides along.

```bash
source scripts/local.env
# keep ONE launchable (OSD off-by-one trap): disable others first
ssh -i ~/.ssh/mister_only root@192.168.99.143 \
  'cd /media/fat/_Unstable && for f in MacLC_Unstable_*.rbf; do mv "$f" "$f.disabled" 2>/dev/null; done; \
   mv MacLC_Unstable_20260707_e322926s3.rbf.disabled MacLC_Unstable_20260707_e322926s3.rbf'
python tools/misterdeploy/launch_unstable_core.py \
  --push releases/MacLC_Unstable_20260707_e322926s3.rbf \
  --core MacLC_Unstable_20260707_e322926s3.rbf --delay 0.3 --max-tries 3

# verify a CLEAN boot BEFORE trusting any capture:
bash scripts/grab.sh boot.png                        # 7.1 desktop, Tools window populated
bash scripts/read_probes.sh | grep -E "PSDT|PRC0"    # MUST be berr_fires=0, boot_inits=2
```

Arm → mount → read (each is ONE bounded JTAG session — never loop, never reopen):

```bash
export PATH="/c/intelFPGA_lite/17.0/quartus/bin64:$PATH"
quartus_stp_tcl -t scripts/floppy_ring.tcl arm

# ---- MOUNT: see §3, the drive matters. Verify PRIMARY. ----
python tools/misterdeploy/ws_send.py \
  kbd:osd sleep:0.8 kbd:confirm sleep:1.0 kbdRaw:32 sleep:0.5 kbd:confirm
#   ^ NOTE: NO 'kbd:down' — the OSD cursor already lands on "Mount Pri Floppy".
#     The old sequence (with 'kbd:down') selected "Mount Sec Floppy" — see §3.
#     ALWAYS screenshot the browser to confirm which drive before selecting.

# "This disk is unreadable" dialog = repro confirmed. Then:
quartus_stp_tcl -t scripts/floppy_ring.tcl status                 # DL counters, §2
quartus_stp_tcl -t scripts/floppy_ring.tcl dump ring_<tag>.txt    # ★ DO the dump this time
python scripts/raw_compare.py ring_<tag>.txt ../Disk605.dsk       # raw-vs-image verdict
python scripts/gcr_analyze.py ring_<tag>.txt \
       scratch/mame_floppy_0702/mame_800k_delivered_flat.hex.sample
```

`Disk605.dsk` lives at `../Disk605.dsk` (i.e. `C:\Temp\mistercore\Disk605.dsk`),
raw 819200 bytes, first bytes `4c 4b 60 00 …` = "LK" HFS boot block (proves
track-0 IS real content).

---

## 2. ★ DL-counter reference (what the numbers MEAN) — from the ring v2 RTL

`floppy_ring.tcl status` prints four download counters. They are keyed on
**index-1 (Primary floppy, `F1`)** downloads and reset on each index-1 download's
rising edge (`MacLC.sv` ~1657-1211, 1665-1684):

| field | meaning | GOOD 800K value (Disk605) |
|---|---|---|
| `dl_words`   | accepted index-1 write slots (words that GOT a slot) | **409600** (0x64000) |
| `dl_nonzero` | of those, `dio_data != 0`                            | **382785** |
| `dl_xor`     | XOR of accepted `dio_data` words                     | **0x0926** |
| size-latch `ds/ss/mfm/hd` | disk-geometry flags latched at index-1 download end | ds=1 (double-sided 800K) |
| `last dio_addr` | **LIVE** wire `dio_addr[19:0]` (NOT latched) — shared across ALL indices | ~0x64000 after any 800K dl |

Reference values recomputed offline this session from the actual file
(`img[i]<<8 | img[i+1]` per the core's `dio_data` packing) — they match the
values the instrument was designed to expect.

**Discriminator (for a CONFIRMED-primary mount):**
- `dl_words < 409600` → write slots dropped **core-side** (the original demux/
  ioctl_wait suspicion).
- `dl_words=409600` **and** `dl_nonzero=382785` **and** `dl_xor=0x0926` → the
  stream landed **perfectly** → bug is **downstream** of the download: SDRAM
  write doesn't stick, or the read path fetches the wrong region. This would
  corroborate the morning "SDRAM region ≠ image" theory and point at the
  extra-slot **write** path (live floppy writes vs the ROM download that runs in
  reset — the untested combination).
- `dl_words=409600` but `dl_nonzero`/`dl_xor` wrong → the **HPS stream itself**
  carried bad/zero data (unlikely; SD file is md5-clean).

---

## 3. ★ THIS SESSION's data point — and why it's INCONCLUSIVE (resolve first)

Reproduced the unreadable dialog on `e322926s3`. `status` returned:

```
RING: done=0 capturing=1 arm_cnt=1 strobes=10
DL: dl_words=0 (expect 409600)  dl_nonzero=0  dl_xor=0x0000
DL: size-latch ds=0 ss=0 mfm=0 hd=0   last dio_addr=0x64000 (409600)
```

**The contradiction:** index-1 counters are all **zero**, yet `last dio_addr`
walked to `0x64000` = byte 819200 = the **end of a full 800K download**. So an
800K image DID fully stream over the ioctl bus — but **not as index 1**.

**Leading explanation — wrong drive.** The CONF_STR order is:
```
"-;"                              (separator)
"F1,DSKIMG,Mount Pri Floppy;"     <- index 1 — cursor lands HERE on OSD open
"F2,DSKIMG,Mount Sec Floppy;"     <- index 2
```
The mount sequence used `kbd:osd → kbd:down → kbd:confirm`, i.e. it pressed
**down once before confirming**, which moves off "Mount Pri Floppy" onto
**"Mount Sec Floppy" (index 2)**. Disk605 therefore downloaded as **index 2**,
so the index-1 counters stayed 0 while the shared `dio_addr` wire still showed
the index-2 walk. This is the classic OSD off-by-one this project has hit before
([[shared-mister-hps-exhaustion]] ops notes). **`strobes=10` / `byte_cnt 45→55`
(only ~10 delivered bytes)** is also consistent with a brief secondary-drive
poke rather than the OS hammering the primary boot floppy.

**⇒ The DL=0 reading does NOT confirm "download never lands."** It most likely
means "we read the wrong drive's counter." The morning "SDRAM ≠ image" theory is
still the leading root cause but is **not** additionally confirmed by this
session. Resolve with a **verified-primary** re-mount (§1 sequence, no `down`,
screenshot the browser) before drawing any conclusion.

---

## 4. ★ DECISIVE next steps (ranked, all cheap)

1. **Clean primary-drive capture + DUMP (not just status).** Re-arm, mount
   Disk605 into the **Primary** floppy (verify via a browser screenshot), let
   the unreadable-retry loop generate reads, then **`dump`** the ring and run
   BOTH `raw_compare.py` (raw byte vs image at fetch addr) and `gcr_analyze.py`.
   This session only ran `status`; the **dump** is what actually answers the
   root question (are the raw fetched bytes image-content, zeros, or stale
   garbage?) independent of the drive/counter confusion. Then read DL counters
   and apply the §2 discriminator.
2. **If DL counters confirm a full clean download** (409600/382785/0x0926) yet
   reads are still garbage: instrument/audit the **extra-slot floppy WRITE
   path** — the ROM download works because it runs while the CPU is in reset;
   live floppy-image writes into `$600000+` during a running core are the
   **untested combination** (morning doc's prime suspect). Compare
   `MacLC.sv` `extra_rom`/`dsk_byte_odd`/`sdram_*` + addrController disk-address
   math against lbmactwo (`../lbmactwo_MiSTer.3/rtl/`), which works.
3. **If DL `dl_words` is short even for a confirmed-primary mount:** the write
   slots are genuinely dropped; chase `ioctl_wait`/`dioBusControl` handshake.
4. Consider a **direct-mount API** path (MiSTer Remote) to eliminate OSD
   off-by-one entirely, or bake a verified "mount Pri Floppy" macro that
   screenshots the browser title before confirming.

---

## 5. Build lineage + the seed lottery (why e322926**s3**, not e322926)

The instrumented RTL is identical across these; only the fitter **SEED** differs.
STA "met" did NOT predict HW behaviour — this is the marginal-fit class from the
June cold-boot hunt ([[cold-boot-reboot-welcome-handoff]] cousin).

| build | seed | STA | HARDWARE |
|---|---|---|---|
| `e322926`   | 1 | met +0.113 ns, SCSI gate 28.042 ns | **0-for-3**: BERR storm (241 fires), BERR storm (201), Finder **bad F-line** crash |
| (rebuild)   | 2 | **VIOLATED −0.012 ns** on `pll_hdmi` scaler clock | not shipped |
| `e322926s3` | 3 | met +0.093 ns, SCSI gate 28.205 ns | **CLEAN**: berr_fires=0, boot_inits=2, populated 7.1 desktop ✓ |

A/B control: known-good parent `0dcf73e` booted clean on the same box in the same
hour, proving the box was healthy and the flakiness was purely seed-1 placement.

**`MacLC.qsf` SEED is committed as 3** this session (was 1). If a future build
storms again, do NOT just roll seeds forever — the structural fix is the June
prescription: **register the peripheral/SCSI status read** so the marginal path
STA doesn't model stops mattering. Seed rolling is a stopgap.

---

## 6. Hardware state at park

- `.143` is UP on `MacLC_Unstable_20260707_e322926s3` (seed 3). Disk605 was
  mounted (probably as **Secondary**, per §3) and the unreadable dialog was on
  screen; harmless to leave, eject anytime.
- Known-good `0dcf73e` and pixel-clock `78e484c` are on the SD as `.disabled`.
- **Ops rules (unchanged, load-bearing):** ONE launchable at a time (OSD
  off-by-one onto stale MACLC rbfs); `scripts/floppy_ring.tcl` = SHORT bounded
  JTAG only, never reopen/loop (`scripts/floppy_rapid.tcl` looping crashed the
  board — [[shared-mister-hps-exhaustion]]); if the box was recently shared /
  churned, power-cycle + re-validate a clean boot BEFORE trusting a verdict.
- `.188`: untouched, lower priority, no JTAG (can't capture).

## 7. Tooling index (all committed on `new-disk-features`)

- `scripts/floppy_ring.tcl` — arm | status | dump (ring v2: `{gcrReadAddr[15:0],
  raw dskReadDataLatch[7:0], enc[7:0]}` per delivery strobe + DL counters).
- `scripts/raw_compare.py <dump> <img>` — raw fetched byte vs image content at
  the captured fetch address; prints the zero/match/other breakdown + the image
  nonzero/xor reference.
- `scripts/gcr_analyze.py <cap> <flat>` — 6-and-2 GCR structural decoder
  (headers/data-fields/checksums), diff vs MAME ground truth.
- `tools/misterdeploy/ws_send.py` — OSD keystroke sender (see its header for key
  names; `osd`=F12, `kbdRaw:32`='D' to jump to Disk605 in the browser).
- `scripts/read_probes.sh`, `scripts/grab.sh` — probe readout + screenshot.
- MAME ref: `scratch/mame_floppy_0702/mame_800k_delivered_flat.hex(.sample)`.

## 8. Deferred / parked

- **User has a NEW high-priority item** to raise next session — take it before
  resuming this floppy work unless told otherwise.
- SDRAM disk-data fetch path map (file:line hops) is in
  `docs/findings_floppy_sdram_not_image_2026-07-07.md` and the 07-06 night doc —
  don't re-derive it.
- Pixel clock (#6): **CLOSED** — user confirmed 07-07 that both 512x384 12" and
  VGA modes work. `[[pixel-clock-berr-rootcause]]`.
- Floppy Build 2 (ISM 1.44MB), TG68K 020-mode cycle audit: unstarted, offline-safe.
