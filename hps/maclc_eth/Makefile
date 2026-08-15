# maclc_eth — HPS daemon for the MacLC PDS Ethernet card.
# Cross-build (WSL/Linux): sudo apt install gcc-arm-linux-gnueabihf
#   make            -> maclc_eth (armhf, static — runs on any MiSTer)
#   make native     -> maclc_eth_native (host arch, for unit poking only)
# Deploy: copy maclc_eth to /media/fat/linux/ and launch from
# /media/fat/linux/user-startup.sh:
#   /media/fat/linux/maclc_eth -i tap0
# plus the declROM at /media/fat/games/MacLC/maccon.rom (releases/maccon.rom).

CROSS   ?= arm-linux-gnueabihf-
CFLAGS  ?= -O2 -Wall -Wextra -static
SRCS     = maclc_eth.c dp8390.c enet_iface.c
HDRS     = maclc_eth.h

maclc_eth: $(SRCS) $(HDRS)
	$(CROSS)gcc $(CFLAGS) -o $@ $(SRCS)

native: $(SRCS) $(HDRS)
	gcc $(CFLAGS) -o maclc_eth_native $(SRCS)

clean:
	rm -f maclc_eth maclc_eth_native

.PHONY: native clean
