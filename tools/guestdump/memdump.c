// memdump <phys_hex> <len_hex> [outfile] - mmap /dev/mem, write region to file/stdout
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: memdump <phys_hex> <len_hex> [out]\n"); return 2; }
    uint64_t phys = strtoull(argv[1], 0, 16), len = strtoull(argv[2], 0, 16);
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    uint64_t pa = phys & ~0xFFFULL, off = phys - pa;
    uint8_t *m = mmap(0, len + off, PROT_READ, MAP_SHARED, fd, pa);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    FILE *o = (argc > 3) ? fopen(argv[3], "wb") : stdout;
    if (!o) { perror("out"); return 1; }
    // copy via a bounce so writes are ordinary memory, 64-bit reads
    static uint8_t buf[1 << 16];
    for (uint64_t p = 0; p < len; ) {
        uint64_t n = len - p; if (n > sizeof buf) n = sizeof buf;
        memcpy(buf, m + off + p, n);
        fwrite(buf, 1, n, o);
        p += n;
    }
    if (o != stdout) fclose(o);
    return 0;
}
