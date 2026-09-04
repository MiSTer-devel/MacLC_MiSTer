#!/bin/sh
# ramdump.sh — dump the guest's RAM ($000000-$9FFFFF, 10 MB) to a file, from
# the MiSTer's ARM side, THROUGH the PDS-ethernet card's guest-RAM DMA engine.
#
# Works even when the guest is HARD-FROZEN: the pds_enet mailbox FSM serves
# DMA_CMD regardless of the 68020's state (proven during the 2026-08-23
# freeze post-mortem, where two dumps a minute apart identified the driver's
# ISR self-orbit down to the exact spinning code).
#
# Requires: the ethernet core loaded with MAGIC up (Main's mac_eth running),
# /tmp/memdump (cross-compiled from memdump.c — mmap-based; dd/read() on
# /dev/mem EFAULTs on this reserved region), and Main RPC-quiescent if you
# care about not colliding with live RX DMA (a frozen guest guarantees it;
# on a live guest expect an occasional torn block and one confused RPC).
#
# usage (on the MiSTer):  sh ramdump.sh /tmp/ram.bin
# Two dumps + cmp = "is anything executing" (a spinning CPU keeps writing
# somewhere; a parked/halted one leaves RAM bit-identical).
OUT=$1
MEMDUMP=/media/fat/linux/memdump
[ -x "$MEMDUMP" ] || MEMDUMP=/tmp/memdump
: > "$OUT"
b=0
while [ $b -lt 320 ]; do
  ga=$((b*32768))
  sq=$(( (b % 250) + 1 ))
  cmd=$(( (32768<<40) | (ga<<16) | sq ))
  devmem 0x1FF200B0 64 0x$(printf %x $cmd)
  n=0
  while :; do
    st=$(devmem 0x1FF200B8 64)
    [ $(( st & 255 )) -eq $sq ] && break
    n=$((n+1)); [ $n -gt 500 ] && { echo "TIMEOUT block $b (stat $st)"; exit 1; }
  done
  [ $(( st & 256 )) -ne 0 ] && echo "ERRBIT block $b"
  "$MEMDUMP" 0x1FF00000 8000 >> "$OUT"
  b=$((b+1))
done
echo "DONE $(ls -l $OUT)"
