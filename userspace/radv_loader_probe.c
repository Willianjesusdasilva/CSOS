#include <stdint.h>
#include <vulkan/vulkan_core.h>

extern int vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *version);
extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);
/* Count-only libdrm API: no drmDevice layout is needed when devices is NULL. */
extern int drmGetDevices2(uint32_t flags, void *devices, int max_devices);

static volatile uint32_t constructor_cookie;

static void report_device_count(uint32_t count) {
    char message[] = "RADV physical device count: 0x00000000\n";
    static const char digits[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i)
        message[sizeof(message)-3-i] = digits[(count >> (i*4)) & 15];
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

__attribute__((constructor)) static void verify_constructor(int argc, char **argv, char **envp) {
    if (argc == 1 && argv && argv[0] && argv[1] == 0 && envp == argv + argc + 1)
        constructor_cookie = 0x43534f53;
}

/* ELF entry has no return address. Establish the SysV C call alignment. */
__attribute__((naked, noreturn)) void _start(void) {
    __asm__ volatile("andq $-16, %rsp\n\tcall probe_main\n\tud2");
}

__attribute__((used, noreturn)) void probe_main(void) {
    uint32_t version = 7;
    long status = constructor_cookie == 0x43534f53 &&
        vk_icdNegotiateLoaderICDInterfaceVersion(&version) == 0 && version != 0 ? 0 : 1;
    if (status == 0) {
        int drm_count = drmGetDevices2(0, 0, 0);
        if (drm_count <= 0) status = 5;
    }
    if (status == 0) {
        PFN_vkCreateInstance create = (PFN_vkCreateInstance)
            vk_icdGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
        const VkInstanceCreateInfo info = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        VkInstance instance = VK_NULL_HANDLE;
        if (!create || create(&info, 0, &instance) != VK_SUCCESS || !instance) {
            status = 2;
        } else {
            PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)
                vk_icdGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices");
            uint32_t device_count = 0;
            if (!enumerate || enumerate(instance, &device_count, 0) != VK_SUCCESS)
                status = 4;
            else report_device_count(device_count);
            PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)
                vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance");
            if (!destroy) status = 3;
            else destroy(instance, 0);
        }
    }
    __asm__ volatile("syscall" : : "a"(60L), "D"(status) : "rcx", "r11", "memory");
    __builtin_unreachable();
}
