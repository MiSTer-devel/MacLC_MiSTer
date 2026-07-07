#!/usr/bin/env python3
"""Send raw MiSTer Remote keystroke/sleep sequences over the ws API.

Usage:
  python tools/misterdeploy/ws_send.py [--host 192.168.99.143] [--port 8182] \
         "kbd:osd" "sleep:0.8" "kbd:down" "kbd:confirm" "kbdRaw:32" ...

Steps:
  kbd:<name>    named key (keyboard.go): up down left right menu back confirm
                cancel osd screenshot core_select user reset console
                exit_console computer_osd change_background
                (osd = F12 opens the core OSD; API names case-SENSITIVE)
  kbdRaw:<n>    raw uinput code (F12=88; letters jump the file browser:
                D=32, S=31, I=23 ...)
  sleep:<sec>   pause between steps (OSD needs ~0.3-0.8 s to redraw)

In-Mac OSD flow for "Mount Pri Floppy" + a file starting with 'D' (7.1 up):
  kbd:osd sleep:0.8 kbd:down sleep:0.3 kbd:confirm sleep:1.0 kbdRaw:32 \
  sleep:0.5 kbd:confirm
(F1,DSKIMG "Mount Pri Floppy" is the first selectable row under the top
separator; verify against /api/menu/view if the OSD layout changed.)
"""
import argparse
import asyncio
import sys

import websockets


async def run(host, port, steps):
    url = f"ws://{host}:{port}/api/ws"
    async with websockets.connect(url) as ws:
        # drain the state the server pushes on connect
        try:
            while True:
                await asyncio.wait_for(ws.recv(), timeout=0.5)
        except asyncio.TimeoutError:
            pass
        for step in steps:
            if step.startswith("sleep:"):
                await asyncio.sleep(float(step.split(":", 1)[1]))
            elif step.startswith(("kbd:", "kbdRaw:")):
                await ws.send(step)
                print(f"sent {step}")
                await asyncio.sleep(0.12)  # let the remote coalesce events
            else:
                sys.exit(f"unknown step '{step}' (want kbd:/kbdRaw:/sleep:)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.99.143")
    ap.add_argument("--port", type=int, default=8182)
    ap.add_argument("steps", nargs="+")
    args = ap.parse_args()
    asyncio.run(run(args.host, args.port, args.steps))


if __name__ == "__main__":
    main()
