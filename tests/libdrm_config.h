/* Linux x86-64 musl profile for the pinned upstream libdrm probe. */
#define _GNU_SOURCE 1
#define UDEV 0
#define HAVE_SECURE_GETENV 1
#define HAVE_SYS_SYSCTL_H 0
#define HAVE_SYS_SELECT_H 1
#define HAVE_ALLOCA_H 1
#define MAJOR_IN_SYSMACROS 1
#define HAVE_OPEN_MEMSTREAM 1
#define HAVE_VISIBILITY 1
#define HAVE_LIBDRM_ATOMIC_PRIMITIVES 1
#define HAVE_LIB_ATOMIC_OPS 0
#define AMDGPU_ASIC_ID_TABLE "/usr/share/libdrm/amdgpu.ids"
