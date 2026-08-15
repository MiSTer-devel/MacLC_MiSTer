/*
 * enet_iface.c — network side of the maclc_eth daemon.
 *
 * Lean port of Main_MiSTer support/minimig/minimig_a2065_ethernet.cpp (GPL):
 * two modes, chosen by interface name —
 *   "tapN"       TUN/TAP device (IFF_TAP|IFF_NO_PI), private subnet / NAT on
 *                the MiSTer side; the only mode that works over WiFi.
 *   anything     AF_PACKET raw socket bound to that interface, promiscuous
 *   else         membership while open. Use a macvlan child (ip link add ...
 *                type macvlan mode bridge) to give the Mac its own MAC on the
 *                LAN without disturbing the MiSTer's address.
 *
 * Frame-level filtering (our MAC / broadcast / multicast) is done by the
 * DP8390 model, so no BPF is attached here — the daemon just hands every
 * frame up. SOCK_CLOEXEC everywhere: leaked promiscuous sockets outlive the
 * card and keep queueing frames with nobody to read them (a2065 lesson).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <arpa/inet.h>
#include "maclc_eth.h"

static int sock_fd = -1;
static int is_tap = 0;
static uint8_t host_mac[6];

int iface_fd(void) { return sock_fd; }
int iface_get_mac(uint8_t mac[6]) { memcpy(mac, host_mac, 6); return sock_fd >= 0; }

static void iface_up(const char *name)
{
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s < 0) return;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0 && !(ifr.ifr_flags & IFF_UP)) {
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(s, SIOCSIFFLAGS, &ifr) == 0)
            LOG("[eth] brought %s up\n", name);
    }
    close(s);
}

static int open_tap(const char *name)
{
    int fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { perror("[eth] open /dev/net/tun"); return 0; }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("[eth] TUNSETIFF");
        close(fd);
        return 0;
    }
    sock_fd = fd;
    is_tap = 1;

    memset(host_mac, 0, 6);
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (s >= 0) {
        struct ifreq m;
        memset(&m, 0, sizeof m);
        strncpy(m.ifr_name, ifr.ifr_name, IFNAMSIZ - 1);
        if (ioctl(s, SIOCGIFHWADDR, &m) == 0)
            memcpy(host_mac, m.ifr_hwaddr.sa_data, 6);
        close(s);
    }
    iface_up(ifr.ifr_name);
    LOG("[eth] opened tap %s MAC=%02X:%02X:%02X:%02X:%02X:%02X\n", ifr.ifr_name,
        host_mac[0], host_mac[1], host_mac[2], host_mac[3], host_mac[4], host_mac[5]);
    return 1;
}

static int open_raw(const char *name)
{
    struct ifreq ifr;
    struct sockaddr_ll addr;

    is_tap = 0;
    sock_fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, htons(ETH_P_ALL));
    if (sock_fd < 0) { perror("[eth] socket"); return 0; }

    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(sock_fd, SIOCGIFINDEX, &ifr) < 0) {
        perror("[eth] SIOCGIFINDEX");
        close(sock_fd); sock_fd = -1;
        return 0;
    }
    int ifindex = ifr.ifr_ifindex;

    memset(host_mac, 0, 6);
    if (ioctl(sock_fd, SIOCGIFHWADDR, &ifr) == 0)
        memcpy(host_mac, ifr.ifr_hwaddr.sa_data, 6);

    iface_up(name);

    memset(&addr, 0, sizeof addr);
    addr.sll_family   = AF_PACKET;
    addr.sll_protocol = htons(ETH_P_ALL);
    addr.sll_ifindex  = ifindex;
    if (bind(sock_fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("[eth] bind");
        close(sock_fd); sock_fd = -1;
        return 0;
    }

    struct packet_mreq mreq;
    memset(&mreq, 0, sizeof mreq);
    mreq.mr_ifindex = ifindex;
    mreq.mr_type    = PACKET_MR_PROMISC;
    if (setsockopt(sock_fd, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mreq, sizeof mreq) < 0)
        perror("[eth] PACKET_ADD_MEMBERSHIP (promisc)");

    LOG("[eth] opened raw %s ifindex=%d MAC=%02X:%02X:%02X:%02X:%02X:%02X\n", name, ifindex,
        host_mac[0], host_mac[1], host_mac[2], host_mac[3], host_mac[4], host_mac[5]);
    return 1;
}

int iface_open(const char *name)
{
    if (sock_fd >= 0) iface_close();
    if (!strncmp(name, "tap", 3)) return open_tap(name);
    return open_raw(name);
}

void iface_close(void)
{
    if (sock_fd >= 0) close(sock_fd);
    sock_fd = -1;
}

int iface_send(const uint8_t *frame, int len)
{
    if (sock_fd < 0) return -1;
    int n = write(sock_fd, frame, len);
    if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
        LOG("[eth] send errno=%d\n", errno);
    return n;
}

int iface_recv(uint8_t *buf, int maxlen)
{
    if (sock_fd < 0) return -1;
    int n = read(sock_fd, buf, maxlen);
    if (n < 0) return -1;                     /* EAGAIN: nothing pending */
    return n;
}
