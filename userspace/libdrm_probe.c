#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "xf86drm.h"
#ifdef CSOS_PROBE_AMDGPU
#include "amdgpu.h"
#include "amdgpu_drm.h"
#include <errno.h>

static int probe_amdgpu_memory(amdgpu_device_handle gpu)
{
    const uint64_t size = 4096, alignment = 2 * 1024 * 1024;
    struct amdgpu_bo_alloc_request request = {
        .alloc_size = size, .phys_alignment = alignment,
        .preferred_heap = AMDGPU_GEM_DOMAIN_GTT
    };
    amdgpu_bo_handle bo = NULL;
    amdgpu_va_handle va = NULL;
    uint64_t address = 0;
    void *cpu = NULL;
    int mapped = 0, result, cleanup;
    const char *stage = "BO allocation";
    result = amdgpu_bo_alloc(gpu, &request, &bo);
    if (result) goto done;
    stage = "CPU map";
    result = amdgpu_bo_cpu_map(bo, &cpu);
    if (result) goto done;
    stage = "CPU read/write";
    volatile uint32_t *words = cpu;
    for (unsigned i = 0; i < size / sizeof(*words); ++i)
        words[i] = 0x43534f53u ^ i;
    for (unsigned i = 0; i < size / sizeof(*words); ++i) {
        if (words[i] != (0x43534f53u ^ i)) { result = -EIO; goto done; }
    }
    stage = "GPU VA allocation";
    result = amdgpu_va_range_alloc(gpu, amdgpu_gpu_va_range_general,
                                  size, alignment, 0, &address, &va, 0);
    if (result) goto done;
    if (address % alignment) { result = -EINVAL; goto done; }
    stage = "GPU VA map";
    result = amdgpu_bo_va_op(bo, 0, size, address, 0, AMDGPU_VA_OP_MAP);
    if (result) goto done;
    mapped = 1;
done:
    if (result) fprintf(stderr, "libdrm_amdgpu %s failed: %d\n", stage, result);
    /* Attempt every applicable cleanup, retaining the first failure. */
    if (mapped) {
        cleanup = amdgpu_bo_va_op(bo, 0, size, address, 0, AMDGPU_VA_OP_UNMAP);
        if (cleanup) fprintf(stderr, "libdrm_amdgpu GPU VA unmap failed: %d\n", cleanup);
        if (!result) result = cleanup;
    }
    if (va) {
        cleanup = amdgpu_va_range_free(va);
        if (cleanup) fprintf(stderr, "libdrm_amdgpu VA free failed: %d\n", cleanup);
        if (!result) result = cleanup;
    }
    if (cpu) {
        cleanup = amdgpu_bo_cpu_unmap(bo);
        if (cleanup) fprintf(stderr, "libdrm_amdgpu CPU unmap failed: %d\n", cleanup);
        if (!result) result = cleanup;
    }
    if (bo) {
        cleanup = amdgpu_bo_free(bo);
        if (cleanup) fprintf(stderr, "libdrm_amdgpu BO free failed: %d\n", cleanup);
        if (!result) result = cleanup;
    }
    if (!result) puts("CSOS real libdrm_amdgpu GTT lifecycle ready");
    return result;
}
#endif

int main(void)
{
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("libdrm open"); return 1; }
    drmVersionPtr version = drmGetVersion(fd);
    if (!version) { perror("drmGetVersion"); close(fd); return 2; }
    printf("libdrm version: %.*s %d.%d\n", version->name_len,
           version->name, version->version_major, version->version_minor);
    drmFreeVersion(version);
    int node_type = drmGetNodeTypeFromFd(fd);
    if (node_type != DRM_NODE_RENDER) {
        fprintf(stderr, "libdrm render node classification failed: %d\n", node_type);
        close(fd); return 7;
    }
    puts("libdrm render node recognized");
    int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (duplicate < 0) { perror("libdrm duplicate render fd"); close(fd); return 8; }
    if (fcntl(fd, F_GETFD) != FD_CLOEXEC || fcntl(duplicate, F_GETFD) != FD_CLOEXEC ||
        fcntl(duplicate, F_SETFD, 0) != 0 || fcntl(duplicate, F_GETFD) != 0 ||
        fcntl(fd, F_GETFD) != FD_CLOEXEC) {
        fprintf(stderr, "libdrm descriptor flags mismatch\n");
        close(duplicate); close(fd); return 12;
    }
    if (duplicate == fd || drmGetNodeTypeFromFd(duplicate) != DRM_NODE_RENDER) {
        fprintf(stderr, "libdrm duplicate render identity mismatch\n");
        close(duplicate); close(fd); return 9;
    }
    drmVersionPtr duplicate_version = drmGetVersion(duplicate);
    if (!duplicate_version) {
        perror("libdrm duplicate version"); close(duplicate); close(fd); return 10;
    }
    drmFreeVersion(duplicate_version);
    close(duplicate);
    if (drmGetNodeTypeFromFd(fd) != DRM_NODE_RENDER) { close(fd); return 11; }
    puts("libdrm duplicate render lifecycle ready");
    drmDevicePtr device = NULL;
    int result = drmGetDevice2(fd, 0, &device);
    if (result != 0) {
        fprintf(stderr, "drmGetDevice2 failed: %d\n", result);
        close(fd); return 3;
    }
    if (device->bustype != DRM_BUS_PCI || !device->deviceinfo.pci) {
        drmFreeDevice(&device); close(fd); return 4;
    }
    printf("libdrm PCI: %04x:%04x\n", device->deviceinfo.pci->vendor_id,
           device->deviceinfo.pci->device_id);
    drmFreeDevice(&device);
#ifdef CSOS_PROBE_AMDGPU
    uint32_t major = 0, minor = 0;
    amdgpu_device_handle gpu = NULL;
    result = amdgpu_device_initialize(fd, &major, &minor, &gpu);
    if (result != 0) {
        fprintf(stderr, "amdgpu_device_initialize failed: %d\n", result);
        close(fd); return 5;
    }
    printf("libdrm_amdgpu initialized: %u.%u\n", major, minor);
    result = probe_amdgpu_memory(gpu);
    int deinitialize_result = amdgpu_device_deinitialize(gpu);
    if (result != 0) { close(fd); return 13; }
    result = deinitialize_result;
    if (result != 0) { close(fd); return 6; }
    puts("CSOS real libdrm_amdgpu initialization ready");
#endif
    close(fd);
    puts("CSOS real libdrm discovery ready");
    return 0;
}
