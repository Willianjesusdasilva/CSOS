/* Private ld-csos interface, built against the pinned musl internal headers.
 * Module slots retain the loader's DTPMOD64 numbering, including empty slots.
 * The loader must call this once, after relocation and before constructors.
 */
#define SYSCALL_NO_TLS 1
#include <stdint.h>
#include "pthread_impl.h"
#include "libc.h"

struct csos_tls_image {
    const void *image;
    size_t file_size;
    size_t memory_size;
    size_t alignment;
};

static struct tls_module modules[16];
static int initialized;

__attribute__((visibility("default")))
int csos_musl_bootstrap(size_t argc, char **argv, size_t count,
                        const struct csos_tls_image *images)
{
    if (initialized || !argv || !argc || count > 16 || (count && !images)) return -1;
    size_t used = 0, alignment = _Alignof(struct pthread);
    for (size_t i = 0; i < count; ++i) {
        size_t a = images[i].alignment ? images[i].alignment : 1;
        if ((a & (a-1)) || a > 65536 || images[i].memory_size > 65536 ||
            images[i].file_size > images[i].memory_size ||
            (images[i].file_size && !images[i].image)) return -2;
        if (a > alignment) alignment = a;
        used += images[i].memory_size;
        used += (-(uintptr_t)images[i].image - used) & (a-1);
        modules[i] = (struct tls_module){
            .next = i+1 < count ? &modules[i+1] : 0,
            .image = (void *)images[i].image,
            .len = images[i].file_size, .size = images[i].memory_size,
            .align = a, .offset = used,
        };
    }
    libc.tls_cnt = count;
    libc.tls_head = count ? modules : 0;
    libc.tls_align = alignment;
    libc.tls_size = (used + (count+1)*sizeof(uintptr_t) + sizeof(struct pthread)
                     + 2*alignment + alignment-1) & -alignment;
    long allocation = __syscall(SYS_mmap, 0, libc.tls_size,
        PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if ((unsigned long)allocation > -4096UL) return -3;
    if (__init_tp(__copy_tls((unsigned char *)allocation)) < 0) {
        __syscall(SYS_munmap, allocation, libc.tls_size);
        return -4;
    }
    __init_libc(argv + argc + 1, argv[0]);
    initialized = 1;
    return 0;
}
