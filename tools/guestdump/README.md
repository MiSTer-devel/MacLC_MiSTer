# guestdump — frozen-guest RAM post-mortem via the PDS-ethernet DMA engine

The pds_enet card's guest-RAM DMA engine (DMA_CMD/DMA_STAT mailbox words at
ARM phys `0x1FF200B0`/`0x1FF200B8`) reads guest SDRAM independently of the
68020. That makes a full 10 MB guest-RAM dump possible from the ARM in ~8 s —
including when the guest is hard-frozen, which is exactly when you want one.

* `memdump.c` — mmap-based /dev/mem reader (`dd`/`read()` EFAULT on the
  reserved DDR3 window). Cross-compile in WSL:
  `arm-none-linux-gnueabihf-gcc -O2 -static -o memdump memdump.c`
  and scp to `/tmp/memdump` on the MiSTer.
* `ramdump.sh` — drives one 32 KB DMA_CMD per block (guest→XFER, dir=0,
  read-only for the guest) and appends the XFER window to the output file.

Post-mortem recipe (all offline, from the 2026-08-23 freeze):
1. Two dumps a minute apart; `cmp` → identical = CPU parked/halted,
   differing = CPU executing (diff regions = what the loop touches).
2. A live mailbox check first: write a zero-length DMA_CMD with a fresh seq
   and watch DMA_STAT echo — proves the card's serve path is alive and
   exonerates card DTACK for the freeze.
3. `Ticks` at guest `$16A` = when it froze (60ths since boot).
4. Stack tips churn between dumps; static return addresses above them are
   the frozen call chain. 68020 exception frames (SR, PC, format|vector,
   e.g. vector $68 = level-2 autovector = the card) pin the interrupted PC.
5. Disassemble driver code straight out of the dump (python capstone,
   CS_ARCH_M68K / CS_MODE_M68K_020).
