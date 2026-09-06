#include <stdint.h>
#include <vulkan/vulkan_core.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include "radv_triangle_shaders.h"

_Static_assert(sizeof(radv_triangle_vert_spv) >= 20, "vertex SPIR-V is truncated");
_Static_assert(sizeof(radv_triangle_frag_spv) >= 20, "fragment SPIR-V is truncated");

extern int vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *version);
extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);
static volatile uint32_t constructor_cookie;
static VkExtensionProperties instance_extension_scratch[64];
static VkExtensionProperties device_extension_scratch[512];
static VkPhysicalDevicePCIBusInfoPropertiesEXT pci_bus_scratch;
static VkPhysicalDeviceProperties2 properties2_scratch;

static int same_string(const char *left, const char *right) {
    while (*left && *left == *right) { ++left; ++right; }
    return *left == *right;
}

static int has_extension(const VkExtensionProperties *properties, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; ++i)
        if (same_string(properties[i].extensionName, name)) return 1;
    return 0;
}

static int physical_matches_drm_pci(VkPhysicalDevice physical,
                                    PFN_vkGetPhysicalDeviceProperties get_properties,
                                    PFN_vkGetPhysicalDeviceProperties2 get_properties2,
                                    PFN_vkEnumerateDeviceExtensionProperties enumerate_extensions,
                                    uint16_t vendor, uint16_t device, uint16_t domain,
                                    uint8_t bus, uint8_t slot, uint8_t function) {
    VkPhysicalDeviceProperties properties;
    get_properties(physical, &properties);
    if (properties.vendorID != vendor || properties.deviceID != device) return 0;
    uint32_t extension_count = 0;
    if (!get_properties2 || !enumerate_extensions ||
        enumerate_extensions(physical, 0, &extension_count, 0) != VK_SUCCESS ||
        extension_count == 0 || extension_count > 512) return 0;
    uint32_t fetched = extension_count;
    if (enumerate_extensions(physical, 0, &fetched, device_extension_scratch) != VK_SUCCESS ||
        fetched != extension_count ||
        !has_extension(device_extension_scratch, fetched, VK_EXT_PCI_BUS_INFO_EXTENSION_NAME)) return 0;
    pci_bus_scratch.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT;
    pci_bus_scratch.pNext = 0;
    pci_bus_scratch.pciDomain = UINT32_MAX;
    pci_bus_scratch.pciBus = UINT32_MAX;
    pci_bus_scratch.pciDevice = UINT32_MAX;
    pci_bus_scratch.pciFunction = UINT32_MAX;
    properties2_scratch.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    properties2_scratch.pNext = &pci_bus_scratch;
    get_properties2(physical, &properties2_scratch);
    return pci_bus_scratch.pciDomain == domain && pci_bus_scratch.pciBus == bus &&
        pci_bus_scratch.pciDevice == slot && pci_bus_scratch.pciFunction == function;
}

static int open_read_write(const char *path) {
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(257L), "D"(-100L),
        "S"(path), "d"(0x80002L), "r"(0L) : "rcx", "r11", "memory");
    return result < 0 ? -1 : (int)result;
}

static void close_fd(int fd) {
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(3L), "D"((long)fd) :
        "rcx", "r11", "memory");
}

static void report_count(char kind, uint32_t count) {
    char message[] = "RADV ? device count: 0x00000000\n";
    message[5] = kind;
    static const char digits[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i)
        message[sizeof(message)-3-i] = digits[(count >> (i*4)) & 15];
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_direct_display_ready(void) {
    static const char message[] = "RADV direct display instance extensions ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_direct_display_enumeration_ready(void) {
    static const char message[] = "RADV direct display modes and planes ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_kms_connector_ready(void) {
    static const char message[] = "RADV connected DRM KMS connector ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_kms_primary_plane_ready(void) {
    static const char message[] = "RADV DRM KMS primary plane ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_drm_display_acquired(void) {
    static const char message[] = "RADV DRM display acquired\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_vulkan_drm_identity_ready(void) {
    static const char message[] = "RADV Vulkan device matches DRM PCI identity\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_matched_pci_bdf(uint16_t domain, uint8_t bus, uint8_t slot, uint8_t function) {
    char message[] = "RADV matched PCI BDF: 0000:00:00.0\n";
    static const char digits[] = "0123456789abcdef";
    for (unsigned i = 0; i < 4; ++i) message[25-i] = digits[(domain >> (i*4)) & 15];
    message[27] = digits[(bus >> 4) & 15]; message[28] = digits[bus & 15];
    message[30] = digits[(slot >> 4) & 15]; message[31] = digits[slot & 15];
    message[33] = digits[function & 15];
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_direct_display_surface_ready(void) {
    static const char message[] = "RADV direct display surface ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static VkSurfaceKHR probe_direct_display(VkInstance instance, VkPhysicalDevice physical,
                                         int drm_fd, uint32_t connector_id) {
    PFN_vkGetPhysicalDeviceDisplayPropertiesKHR get_displays =
        (PFN_vkGetPhysicalDeviceDisplayPropertiesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceDisplayPropertiesKHR");
    PFN_vkGetDisplayModePropertiesKHR get_modes =
        (PFN_vkGetDisplayModePropertiesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetDisplayModePropertiesKHR");
    PFN_vkGetPhysicalDeviceDisplayPlanePropertiesKHR get_planes =
        (PFN_vkGetPhysicalDeviceDisplayPlanePropertiesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceDisplayPlanePropertiesKHR");
    PFN_vkGetDisplayPlaneSupportedDisplaysKHR get_supported =
        (PFN_vkGetDisplayPlaneSupportedDisplaysKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetDisplayPlaneSupportedDisplaysKHR");
    PFN_vkGetDisplayPlaneCapabilitiesKHR get_capabilities =
        (PFN_vkGetDisplayPlaneCapabilitiesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetDisplayPlaneCapabilitiesKHR");
    PFN_vkCreateDisplayPlaneSurfaceKHR create_surface =
        (PFN_vkCreateDisplayPlaneSurfaceKHR)vk_icdGetInstanceProcAddr(
            instance, "vkCreateDisplayPlaneSurfaceKHR");
    PFN_vkGetDrmDisplayEXT get_drm_display =
        (PFN_vkGetDrmDisplayEXT)vk_icdGetInstanceProcAddr(instance, "vkGetDrmDisplayEXT");
    PFN_vkAcquireDrmDisplayEXT acquire_drm_display =
        (PFN_vkAcquireDrmDisplayEXT)vk_icdGetInstanceProcAddr(instance, "vkAcquireDrmDisplayEXT");
    if (!get_displays || !get_modes || !get_planes || !get_supported ||
        !get_capabilities || !create_surface || !get_drm_display ||
        !acquire_drm_display || drm_fd < 0 || connector_id == 0) return VK_NULL_HANDLE;

    VkDisplayPropertiesKHR displays[8];
    uint32_t display_count = 8;
    VkResult result = get_displays(physical, &display_count, displays);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || display_count == 0) return VK_NULL_HANDLE;
    VkDisplayKHR display = VK_NULL_HANDLE;
    if (get_drm_display(physical, drm_fd, connector_id, &display) != VK_SUCCESS || !display ||
        acquire_drm_display(physical, drm_fd, display) != VK_SUCCESS) return VK_NULL_HANDLE;
    report_drm_display_acquired();
    VkDisplayPropertiesKHR *selected_display = 0;
    for (uint32_t i = 0; i < display_count && i < 8; ++i)
        if (displays[i].display == display) { selected_display = &displays[i]; break; }
    if (!selected_display || selected_display->physicalResolution.width == 0 ||
        selected_display->physicalResolution.height == 0) return VK_NULL_HANDLE;

    VkDisplayModePropertiesKHR modes[16];
    uint32_t mode_count = 16;
    result = get_modes(physical, display, &mode_count, modes);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || mode_count == 0 ||
        !modes[0].displayMode || modes[0].parameters.visibleRegion.width == 0 ||
        modes[0].parameters.visibleRegion.height == 0 || modes[0].parameters.refreshRate == 0) return VK_NULL_HANDLE;

    VkDisplayPlanePropertiesKHR planes[16];
    uint32_t plane_count = 16;
    result = get_planes(physical, &plane_count, planes);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || plane_count == 0) return VK_NULL_HANDLE;
    for (uint32_t plane = 0; plane < plane_count && plane < 16; ++plane) {
        VkDisplayKHR supported[8];
        uint32_t supported_count = 8;
        result = get_supported(physical, plane, &supported_count, supported);
        if (result != VK_SUCCESS && result != VK_INCOMPLETE) continue;
        for (uint32_t i = 0; i < supported_count && i < 8; ++i)
            if (supported[i] == display) {
                report_direct_display_enumeration_ready();
                VkDisplayPlaneCapabilitiesKHR capabilities;
                if (get_capabilities(physical, modes[0].displayMode, plane, &capabilities) != VK_SUCCESS)
                    return VK_NULL_HANDLE;
                VkExtent2D extent = modes[0].parameters.visibleRegion;
                if (extent.width < capabilities.minDstExtent.width ||
                    extent.height < capabilities.minDstExtent.height ||
                    extent.width > capabilities.maxDstExtent.width ||
                    extent.height > capabilities.maxDstExtent.height) return VK_NULL_HANDLE;
                VkDisplayPlaneAlphaFlagBitsKHR alpha = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR;
                if (!(capabilities.supportedAlpha & alpha)) {
                    VkDisplayPlaneAlphaFlagsKHR available = capabilities.supportedAlpha;
                    if (!available) return VK_NULL_HANDLE;
                    alpha = (VkDisplayPlaneAlphaFlagBitsKHR)(available & (~available + 1));
                }
                VkSurfaceTransformFlagBitsKHR transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
                if (!(selected_display->supportedTransforms & transform)) {
                    VkSurfaceTransformFlagsKHR available = selected_display->supportedTransforms;
                    if (!available) return VK_NULL_HANDLE;
                    transform = (VkSurfaceTransformFlagBitsKHR)(available & (~available + 1));
                }
                const VkDisplaySurfaceCreateInfoKHR surface_info = {
                    .sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR,
                    .displayMode = modes[0].displayMode,
                    .planeIndex = plane,
                    .planeStackIndex = planes[plane].currentStackIndex,
                    .transform = transform,
                    .globalAlpha = 1.0f,
                    .alphaMode = alpha,
                    .imageExtent = extent,
                };
                VkSurfaceKHR surface = VK_NULL_HANDLE;
                if (create_surface(instance, &surface_info, 0, &surface) == VK_SUCCESS && surface) {
                    report_direct_display_surface_ready();
                    return surface;
                }
                return VK_NULL_HANDLE;
            }
    }
    return VK_NULL_HANDLE;
}

static void report_display_swapchain_ready(void) {
    static const char message[] = "RADV direct display swapchain ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_display_clear_present_ready(void) {
    static const char message[] = "RADV direct display clear frame presented\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_display_triangle_present_ready(void) {
    static const char message[] = "RADV direct display triangle presented\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

typedef struct SwapchainTriangle {
    VkShaderModule vertex, fragment;
    VkRenderPass render_pass;
    VkPipelineLayout layout;
    VkPipeline pipeline;
} SwapchainTriangle;

static void destroy_swapchain_triangle(VkDevice device, PFN_vkGetDeviceProcAddr get_proc,
                                       SwapchainTriangle *triangle) {
    PFN_vkDestroyPipeline destroy_pipeline = (PFN_vkDestroyPipeline)get_proc(device, "vkDestroyPipeline");
    PFN_vkDestroyPipelineLayout destroy_layout = (PFN_vkDestroyPipelineLayout)get_proc(device, "vkDestroyPipelineLayout");
    PFN_vkDestroyRenderPass destroy_render_pass = (PFN_vkDestroyRenderPass)get_proc(device, "vkDestroyRenderPass");
    PFN_vkDestroyShaderModule destroy_shader = (PFN_vkDestroyShaderModule)get_proc(device, "vkDestroyShaderModule");
    if (triangle->pipeline && destroy_pipeline) destroy_pipeline(device, triangle->pipeline, 0);
    if (triangle->layout && destroy_layout) destroy_layout(device, triangle->layout, 0);
    if (triangle->render_pass && destroy_render_pass) destroy_render_pass(device, triangle->render_pass, 0);
    if (triangle->fragment && destroy_shader) destroy_shader(device, triangle->fragment, 0);
    if (triangle->vertex && destroy_shader) destroy_shader(device, triangle->vertex, 0);
}

static int create_swapchain_triangle(VkDevice device, PFN_vkGetDeviceProcAddr get_proc,
                                     VkFormat format, VkExtent2D extent,
                                     SwapchainTriangle *triangle) {
    PFN_vkCreateShaderModule create_shader = (PFN_vkCreateShaderModule)get_proc(device, "vkCreateShaderModule");
    PFN_vkCreateRenderPass create_render_pass = (PFN_vkCreateRenderPass)get_proc(device, "vkCreateRenderPass");
    PFN_vkCreatePipelineLayout create_layout = (PFN_vkCreatePipelineLayout)get_proc(device, "vkCreatePipelineLayout");
    PFN_vkCreateGraphicsPipelines create_pipeline = (PFN_vkCreateGraphicsPipelines)get_proc(device, "vkCreateGraphicsPipelines");
    if (!create_shader || !create_render_pass || !create_layout || !create_pipeline ||
        extent.width == 0 || extent.height == 0) return 0;
    const VkShaderModuleCreateInfo vertex_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = radv_triangle_vert_spv_bytes, .pCode = radv_triangle_vert_spv,
    };
    const VkShaderModuleCreateInfo fragment_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = radv_triangle_frag_spv_bytes, .pCode = radv_triangle_frag_spv,
    };
    if (create_shader(device, &vertex_info, 0, &triangle->vertex) != VK_SUCCESS || !triangle->vertex ||
        create_shader(device, &fragment_info, 0, &triangle->fragment) != VK_SUCCESS || !triangle->fragment)
        return 0;
    const VkAttachmentDescription attachment = {
        .format = format, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_LOAD, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    const VkAttachmentReference reference = {.attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    const VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &reference,
    };
    const VkRenderPassCreateInfo render_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &attachment,
        .subpassCount = 1, .pSubpasses = &subpass,
    };
    if (create_render_pass(device, &render_info, 0, &triangle->render_pass) != VK_SUCCESS || !triangle->render_pass)
        return 0;
    const VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    if (create_layout(device, &layout_info, 0, &triangle->layout) != VK_SUCCESS || !triangle->layout) return 0;
    const VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = triangle->vertex, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = triangle->fragment, .pName = "main"},
    };
    const VkPipelineVertexInputStateCreateInfo vertex_input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    const VkPipelineInputAssemblyStateCreateInfo assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    const VkViewport viewport = {.width = (float)extent.width, .height = (float)extent.height, .minDepth = 0.0f, .maxDepth = 1.0f};
    const VkRect2D scissor = {.extent = extent};
    const VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor,
    };
    const VkPipelineRasterizationStateCreateInfo raster = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f,
    };
    const VkPipelineMultisampleStateCreateInfo multisample = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    const VkPipelineColorBlendAttachmentState blend_attachment = {
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
            VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    };
    const VkPipelineColorBlendStateCreateInfo blend = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &blend_attachment,
    };
    const VkGraphicsPipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2, .pStages = stages,
        .pVertexInputState = &vertex_input, .pInputAssemblyState = &assembly,
        .pViewportState = &viewport_state, .pRasterizationState = &raster,
        .pMultisampleState = &multisample, .pColorBlendState = &blend,
        .layout = triangle->layout, .renderPass = triangle->render_pass,
    };
    return create_pipeline(device, VK_NULL_HANDLE, 1, &pipeline_info, 0,
        &triangle->pipeline) == VK_SUCCESS && triangle->pipeline;
}

static void probe_display_swapchain(VkInstance instance, VkPhysicalDevice physical,
                                    VkDevice device, VkQueue queue, uint32_t family,
                                    VkSurfaceKHR surface,
                                    PFN_vkGetDeviceProcAddr get_proc) {
    if (!surface || !get_proc) return;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR get_capabilities =
        (PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR get_formats =
        (PFN_vkGetPhysicalDeviceSurfaceFormatsKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceSurfaceFormatsKHR");
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR get_present_modes =
        (PFN_vkGetPhysicalDeviceSurfacePresentModesKHR)vk_icdGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceSurfacePresentModesKHR");
    PFN_vkCreateSwapchainKHR create_swapchain =
        (PFN_vkCreateSwapchainKHR)get_proc(device, "vkCreateSwapchainKHR");
    PFN_vkDestroySwapchainKHR destroy_swapchain =
        (PFN_vkDestroySwapchainKHR)get_proc(device, "vkDestroySwapchainKHR");
    PFN_vkGetSwapchainImagesKHR get_images =
        (PFN_vkGetSwapchainImagesKHR)get_proc(device, "vkGetSwapchainImagesKHR");
    PFN_vkAcquireNextImageKHR acquire_image = (PFN_vkAcquireNextImageKHR)get_proc(device, "vkAcquireNextImageKHR");
    PFN_vkQueuePresentKHR queue_present = (PFN_vkQueuePresentKHR)get_proc(device, "vkQueuePresentKHR");
    PFN_vkCreateSemaphore create_semaphore = (PFN_vkCreateSemaphore)get_proc(device, "vkCreateSemaphore");
    PFN_vkDestroySemaphore destroy_semaphore = (PFN_vkDestroySemaphore)get_proc(device, "vkDestroySemaphore");
    PFN_vkCreateCommandPool create_pool = (PFN_vkCreateCommandPool)get_proc(device, "vkCreateCommandPool");
    PFN_vkDestroyCommandPool destroy_pool = (PFN_vkDestroyCommandPool)get_proc(device, "vkDestroyCommandPool");
    PFN_vkAllocateCommandBuffers allocate_commands = (PFN_vkAllocateCommandBuffers)get_proc(device, "vkAllocateCommandBuffers");
    PFN_vkBeginCommandBuffer begin_command = (PFN_vkBeginCommandBuffer)get_proc(device, "vkBeginCommandBuffer");
    PFN_vkEndCommandBuffer end_command = (PFN_vkEndCommandBuffer)get_proc(device, "vkEndCommandBuffer");
    PFN_vkCmdPipelineBarrier barrier = (PFN_vkCmdPipelineBarrier)get_proc(device, "vkCmdPipelineBarrier");
    PFN_vkCmdClearColorImage clear_image = (PFN_vkCmdClearColorImage)get_proc(device, "vkCmdClearColorImage");
    PFN_vkCreateImageView create_view = (PFN_vkCreateImageView)get_proc(device, "vkCreateImageView");
    PFN_vkDestroyImageView destroy_view = (PFN_vkDestroyImageView)get_proc(device, "vkDestroyImageView");
    PFN_vkCreateFramebuffer create_framebuffer = (PFN_vkCreateFramebuffer)get_proc(device, "vkCreateFramebuffer");
    PFN_vkDestroyFramebuffer destroy_framebuffer = (PFN_vkDestroyFramebuffer)get_proc(device, "vkDestroyFramebuffer");
    PFN_vkCmdBeginRenderPass begin_render_pass = (PFN_vkCmdBeginRenderPass)get_proc(device, "vkCmdBeginRenderPass");
    PFN_vkCmdEndRenderPass end_render_pass = (PFN_vkCmdEndRenderPass)get_proc(device, "vkCmdEndRenderPass");
    PFN_vkCmdBindPipeline bind_pipeline = (PFN_vkCmdBindPipeline)get_proc(device, "vkCmdBindPipeline");
    PFN_vkCmdDraw draw = (PFN_vkCmdDraw)get_proc(device, "vkCmdDraw");
    PFN_vkQueueSubmit queue_submit = (PFN_vkQueueSubmit)get_proc(device, "vkQueueSubmit");
    PFN_vkQueueWaitIdle queue_wait_idle = (PFN_vkQueueWaitIdle)get_proc(device, "vkQueueWaitIdle");
    if (!get_capabilities || !get_formats || !get_present_modes ||
        !create_swapchain || !destroy_swapchain || !get_images || !acquire_image || !queue_present ||
        !create_semaphore || !destroy_semaphore || !create_pool || !destroy_pool ||
        !allocate_commands || !begin_command || !end_command || !barrier || !clear_image ||
        !create_view || !destroy_view || !create_framebuffer || !destroy_framebuffer ||
        !begin_render_pass || !end_render_pass || !bind_pipeline || !draw ||
        !queue_submit || !queue_wait_idle || !queue) return;

    VkSurfaceCapabilitiesKHR capabilities;
    VkSurfaceFormatKHR formats[16];
    VkPresentModeKHR present_modes[16];
    uint32_t format_count = 16, present_mode_count = 16;
    if (get_capabilities(physical, surface, &capabilities) != VK_SUCCESS ||
        get_formats(physical, surface, &format_count, formats) != VK_SUCCESS || format_count == 0 ||
        get_present_modes(physical, surface, &present_mode_count, present_modes) != VK_SUCCESS ||
        present_mode_count == 0) return;
    const VkImageUsageFlags required_usage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if ((capabilities.supportedUsageFlags & required_usage) != required_usage) return;
    VkSurfaceFormatKHR format = formats[0];
    if (format.format == VK_FORMAT_UNDEFINED) format.format = VK_FORMAT_B8G8R8A8_UNORM;
    VkPresentModeKHR present_mode = VK_PRESENT_MODE_FIFO_KHR;
    int has_fifo = 0;
    for (uint32_t i = 0; i < present_mode_count && i < 16; ++i)
        if (present_modes[i] == VK_PRESENT_MODE_FIFO_KHR) { has_fifo = 1; break; }
    if (!has_fifo) return;
    uint32_t image_count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount && image_count > capabilities.maxImageCount)
        image_count = capabilities.maxImageCount;
    VkExtent2D extent = capabilities.currentExtent;
    if (extent.width == UINT32_MAX || extent.height == UINT32_MAX) return;
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(capabilities.supportedCompositeAlpha & alpha)) {
        VkCompositeAlphaFlagsKHR available = capabilities.supportedCompositeAlpha;
        if (!available) return;
        alpha = (VkCompositeAlphaFlagBitsKHR)(available & (~available + 1));
    }
    const VkSwapchainCreateInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = required_usage,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = present_mode,
        .clipped = VK_TRUE,
    };
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    if (create_swapchain(device, &info, 0, &swapchain) != VK_SUCCESS || !swapchain) return;
    uint32_t actual_images = 0;
    if (get_images(device, swapchain, &actual_images, 0) == VK_SUCCESS && actual_images >= image_count && actual_images <= 8) {
        VkImage images[8];
        uint32_t fetched_images = actual_images;
        if (get_images(device, swapchain, &fetched_images, images) == VK_SUCCESS && fetched_images == actual_images) {
            report_display_swapchain_ready();
            SwapchainTriangle triangle = {0};
            const VkSemaphoreCreateInfo semaphore_info = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
            VkSemaphore acquired = VK_NULL_HANDLE, rendered = VK_NULL_HANDLE;
            VkCommandPool pool = VK_NULL_HANDLE;
            VkImageView view = VK_NULL_HANDLE;
            VkFramebuffer framebuffer = VK_NULL_HANDLE;
            if (create_swapchain_triangle(device, get_proc, format.format, extent, &triangle) &&
                create_semaphore(device, &semaphore_info, 0, &acquired) == VK_SUCCESS && acquired &&
                create_semaphore(device, &semaphore_info, 0, &rendered) == VK_SUCCESS && rendered) {
                uint32_t image_index = UINT32_MAX;
                VkResult acquired_result = acquire_image(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &image_index);
                const VkCommandPoolCreateInfo pool_info = {
                    .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                    .queueFamilyIndex = family,
                };
                const VkImageViewCreateInfo view_info = {
                    .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                    .image = image_index < actual_images ? images[image_index] : VK_NULL_HANDLE,
                    .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format.format,
                    .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                };
                if ((acquired_result == VK_SUCCESS || acquired_result == VK_SUBOPTIMAL_KHR) && image_index < actual_images &&
                    create_view(device, &view_info, 0, &view) == VK_SUCCESS && view &&
                    create_framebuffer(device, &(VkFramebufferCreateInfo){
                        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                        .renderPass = triangle.render_pass, .attachmentCount = 1, .pAttachments = &view,
                        .width = extent.width, .height = extent.height, .layers = 1,
                    }, 0, &framebuffer) == VK_SUCCESS && framebuffer &&
                    create_pool(device, &pool_info, 0, &pool) == VK_SUCCESS && pool) {
                    const VkCommandBufferAllocateInfo allocate_info = {
                        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1,
                    };
                    VkCommandBuffer command = VK_NULL_HANDLE;
                    if (allocate_commands(device, &allocate_info, &command) == VK_SUCCESS && command) {
                        const VkCommandBufferBeginInfo begin_info = {
                            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                        };
                        if (begin_command(command, &begin_info) == VK_SUCCESS) {
                            VkImageMemoryBarrier to_clear = {
                                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                                .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                .image = images[image_index], .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                            };
                            barrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                0, 0, 0, 0, 0, 1, &to_clear);
                            const VkClearColorValue black = {.float32 = {0.0f, 0.0f, 0.0f, 1.0f}};
                            clear_image(command, images[image_index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                &black, 1, &to_clear.subresourceRange);
                            VkImageMemoryBarrier to_attachment = to_clear;
                            to_attachment.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                            to_attachment.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                            to_attachment.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                            to_attachment.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
                            barrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                0, 0, 0, 0, 0, 1, &to_attachment);
                            const VkRenderPassBeginInfo pass_begin = {
                                .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                .renderPass = triangle.render_pass, .framebuffer = framebuffer,
                                .renderArea = {.extent = extent},
                            };
                            begin_render_pass(command, &pass_begin, VK_SUBPASS_CONTENTS_INLINE);
                            bind_pipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, triangle.pipeline);
                            draw(command, 3, 1, 0, 0);
                            end_render_pass(command);
                            if (end_command(command) == VK_SUCCESS) {
                                VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
                                const VkSubmitInfo submit = {
                                    .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                                    .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired, .pWaitDstStageMask = &wait_stage,
                                    .commandBufferCount = 1, .pCommandBuffers = &command,
                                    .signalSemaphoreCount = 1, .pSignalSemaphores = &rendered,
                                };
                                if (queue_submit(queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS) {
                                    const VkPresentInfoKHR present = {
                                        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
                                        .waitSemaphoreCount = 1, .pWaitSemaphores = &rendered,
                                        .swapchainCount = 1, .pSwapchains = &swapchain, .pImageIndices = &image_index,
                                    };
                                    VkResult present_result = queue_present(queue, &present);
                                    VkResult idle_result = queue_wait_idle(queue);
                                    if ((present_result == VK_SUCCESS || present_result == VK_SUBOPTIMAL_KHR) &&
                                        idle_result == VK_SUCCESS) {
                                        report_display_clear_present_ready();
                                        report_display_triangle_present_ready();
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (framebuffer) destroy_framebuffer(device, framebuffer, 0);
            if (view) destroy_view(device, view, 0);
            if (pool) destroy_pool(device, pool, 0);
            if (rendered) destroy_semaphore(device, rendered, 0);
            if (acquired) destroy_semaphore(device, acquired, 0);
            destroy_swapchain_triangle(device, get_proc, &triangle);
        }
    }
    destroy_swapchain(device, swapchain, 0);
}

static void report_logical_device_ready(void) {
    static const char message[] = "RADV logical device and graphics queue ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_submission_ready(void) {
    static const char message[] = "RADV command submission and fence ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_shaders_ready(void) {
    static const char message[] = "RADV triangle shader modules ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_pipeline_ready(void) {
    static const char message[] = "RADV triangle graphics pipeline ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_framebuffer_ready(void) {
    static const char message[] = "RADV triangle offscreen framebuffer ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_readback_buffer_ready(void) {
    static const char message[] = "RADV triangle readback buffer ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static long validate_submission(VkDevice device, VkQueue queue, uint32_t family,
                                PFN_vkGetDeviceProcAddr get_proc, VkRenderPass render_pass,
                                VkFramebuffer framebuffer, VkPipeline pipeline, VkImage image,
                                VkBuffer readback, VkDeviceMemory readback_memory, VkBool32 coherent);

static long validate_graphics_pipeline(VkPhysicalDevice physical, VkDevice device, VkQueue queue,
                                       uint32_t family,
                                       PFN_vkGetPhysicalDeviceMemoryProperties get_memory_properties,
                                       PFN_vkGetDeviceProcAddr get_proc) {
    PFN_vkCreateShaderModule create = (PFN_vkCreateShaderModule)get_proc(device, "vkCreateShaderModule");
    PFN_vkDestroyShaderModule destroy = (PFN_vkDestroyShaderModule)get_proc(device, "vkDestroyShaderModule");
    PFN_vkCreateRenderPass create_render_pass = (PFN_vkCreateRenderPass)get_proc(device, "vkCreateRenderPass");
    PFN_vkDestroyRenderPass destroy_render_pass = (PFN_vkDestroyRenderPass)get_proc(device, "vkDestroyRenderPass");
    PFN_vkCreatePipelineLayout create_layout = (PFN_vkCreatePipelineLayout)get_proc(device, "vkCreatePipelineLayout");
    PFN_vkDestroyPipelineLayout destroy_layout = (PFN_vkDestroyPipelineLayout)get_proc(device, "vkDestroyPipelineLayout");
    PFN_vkCreateGraphicsPipelines create_pipeline = (PFN_vkCreateGraphicsPipelines)get_proc(device, "vkCreateGraphicsPipelines");
    PFN_vkDestroyPipeline destroy_pipeline = (PFN_vkDestroyPipeline)get_proc(device, "vkDestroyPipeline");
    PFN_vkCreateImage create_image = (PFN_vkCreateImage)get_proc(device, "vkCreateImage");
    PFN_vkDestroyImage destroy_image = (PFN_vkDestroyImage)get_proc(device, "vkDestroyImage");
    PFN_vkGetImageMemoryRequirements get_image_requirements = (PFN_vkGetImageMemoryRequirements)get_proc(device, "vkGetImageMemoryRequirements");
    PFN_vkAllocateMemory allocate_memory = (PFN_vkAllocateMemory)get_proc(device, "vkAllocateMemory");
    PFN_vkFreeMemory free_memory = (PFN_vkFreeMemory)get_proc(device, "vkFreeMemory");
    PFN_vkBindImageMemory bind_image = (PFN_vkBindImageMemory)get_proc(device, "vkBindImageMemory");
    PFN_vkCreateImageView create_view = (PFN_vkCreateImageView)get_proc(device, "vkCreateImageView");
    PFN_vkDestroyImageView destroy_view = (PFN_vkDestroyImageView)get_proc(device, "vkDestroyImageView");
    PFN_vkCreateFramebuffer create_framebuffer = (PFN_vkCreateFramebuffer)get_proc(device, "vkCreateFramebuffer");
    PFN_vkDestroyFramebuffer destroy_framebuffer = (PFN_vkDestroyFramebuffer)get_proc(device, "vkDestroyFramebuffer");
    PFN_vkCreateBuffer create_buffer = (PFN_vkCreateBuffer)get_proc(device, "vkCreateBuffer");
    PFN_vkDestroyBuffer destroy_buffer = (PFN_vkDestroyBuffer)get_proc(device, "vkDestroyBuffer");
    PFN_vkGetBufferMemoryRequirements get_buffer_requirements = (PFN_vkGetBufferMemoryRequirements)get_proc(device, "vkGetBufferMemoryRequirements");
    PFN_vkBindBufferMemory bind_buffer = (PFN_vkBindBufferMemory)get_proc(device, "vkBindBufferMemory");
    if (!create || !destroy || !create_render_pass || !destroy_render_pass ||
        !create_layout || !destroy_layout || !create_pipeline || !destroy_pipeline ||
        !get_memory_properties || !create_image || !destroy_image || !get_image_requirements ||
        !allocate_memory || !free_memory || !bind_image || !create_view || !destroy_view ||
        !create_framebuffer || !destroy_framebuffer || !create_buffer || !destroy_buffer ||
        !get_buffer_requirements || !bind_buffer) return 18;
    const VkShaderModuleCreateInfo vertex_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = radv_triangle_vert_spv_bytes,
        .pCode = radv_triangle_vert_spv,
    };
    const VkShaderModuleCreateInfo fragment_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = radv_triangle_frag_spv_bytes,
        .pCode = radv_triangle_frag_spv,
    };
    VkShaderModule vertex = VK_NULL_HANDLE;
    VkShaderModule fragment = VK_NULL_HANDLE;
    if (create(device, &vertex_info, 0, &vertex) != VK_SUCCESS || !vertex) return 19;
    long status = 0;
    if (create(device, &fragment_info, 0, &fragment) != VK_SUCCESS || !fragment) status = 20;
    else {
        report_shaders_ready();
        const VkAttachmentDescription attachment = {
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        const VkAttachmentReference color_reference = {
            .attachment = 0,
            .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
        const VkSubpassDescription subpass = {
            .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_reference,
        };
        const VkSubpassDependency transfer_dependency = {
            .srcSubpass = 0,
            .dstSubpass = VK_SUBPASS_EXTERNAL,
            .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
            .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        };
        const VkRenderPassCreateInfo render_info = {
            .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &transfer_dependency,
        };
        VkRenderPass render_pass = VK_NULL_HANDLE;
        VkPipelineLayout layout = VK_NULL_HANDLE;
        VkPipeline pipeline = VK_NULL_HANDLE;
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        VkFramebuffer framebuffer = VK_NULL_HANDLE;
        VkBuffer readback = VK_NULL_HANDLE;
        VkDeviceMemory readback_memory = VK_NULL_HANDLE;
        if (create_render_pass(device, &render_info, 0, &render_pass) != VK_SUCCESS || !render_pass) {
            status = 21;
        } else {
            const VkPipelineLayoutCreateInfo layout_info = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
            if (create_layout(device, &layout_info, 0, &layout) != VK_SUCCESS || !layout) {
                status = 22;
            } else {
                const VkPipelineShaderStageCreateInfo stages[2] = {
                    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vertex, .pName = "main"},
                    {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment, .pName = "main"},
                };
                const VkPipelineVertexInputStateCreateInfo vertex_input = {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
                const VkPipelineInputAssemblyStateCreateInfo assembly = {
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                };
                const VkViewport viewport = {.width = 64.0f, .height = 64.0f, .minDepth = 0.0f, .maxDepth = 1.0f};
                const VkRect2D scissor = {.extent = {64, 64}};
                const VkPipelineViewportStateCreateInfo viewport_state = {
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                    .viewportCount = 1, .pViewports = &viewport,
                    .scissorCount = 1, .pScissors = &scissor,
                };
                const VkPipelineRasterizationStateCreateInfo raster = {
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                    .polygonMode = VK_POLYGON_MODE_FILL,
                    .cullMode = VK_CULL_MODE_NONE,
                    .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
                    .lineWidth = 1.0f,
                };
                const VkPipelineMultisampleStateCreateInfo multisample = {
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                    .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
                };
                const VkPipelineColorBlendAttachmentState blend_attachment = {
                    .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                        VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
                };
                const VkPipelineColorBlendStateCreateInfo blend = {
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                    .attachmentCount = 1,
                    .pAttachments = &blend_attachment,
                };
                const VkGraphicsPipelineCreateInfo pipeline_info = {
                    .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
                    .stageCount = 2, .pStages = stages,
                    .pVertexInputState = &vertex_input,
                    .pInputAssemblyState = &assembly,
                    .pViewportState = &viewport_state,
                    .pRasterizationState = &raster,
                    .pMultisampleState = &multisample,
                    .pColorBlendState = &blend,
                    .layout = layout,
                    .renderPass = render_pass,
                    .subpass = 0,
                };
                if (create_pipeline(device, VK_NULL_HANDLE, 1, &pipeline_info, 0, &pipeline) != VK_SUCCESS || !pipeline)
                    status = 23;
                else {
                    report_pipeline_ready();
                    const VkImageCreateInfo image_info = {
                        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                        .imageType = VK_IMAGE_TYPE_2D,
                        .format = VK_FORMAT_R8G8B8A8_UNORM,
                        .extent = {64, 64, 1},
                        .mipLevels = 1,
                        .arrayLayers = 1,
                        .samples = VK_SAMPLE_COUNT_1_BIT,
                        .tiling = VK_IMAGE_TILING_OPTIMAL,
                        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                    };
                    if (create_image(device, &image_info, 0, &image) != VK_SUCCESS || !image) {
                        status = 24;
                    } else {
                        VkMemoryRequirements requirements;
                        VkPhysicalDeviceMemoryProperties properties;
                        get_image_requirements(device, image, &requirements);
                        get_memory_properties(physical, &properties);
                        uint32_t memory_type = UINT32_MAX;
                        for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
                            if ((requirements.memoryTypeBits & (1u << i)) &&
                                (properties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                                memory_type = i;
                                break;
                            }
                        if (memory_type == UINT32_MAX)
                            for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
                                if (requirements.memoryTypeBits & (1u << i)) { memory_type = i; break; }
                        const VkMemoryAllocateInfo memory_info = {
                            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                            .allocationSize = requirements.size,
                            .memoryTypeIndex = memory_type,
                        };
                        if (memory_type == UINT32_MAX || requirements.size == 0 ||
                            allocate_memory(device, &memory_info, 0, &memory) != VK_SUCCESS || !memory ||
                            bind_image(device, image, memory, 0) != VK_SUCCESS) {
                            status = 25;
                        } else {
                            const VkImageViewCreateInfo view_info = {
                                .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                                .image = image,
                                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                                .format = VK_FORMAT_R8G8B8A8_UNORM,
                                .subresourceRange = {
                                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                                    .levelCount = 1,
                                    .layerCount = 1,
                                },
                            };
                            if (create_view(device, &view_info, 0, &view) != VK_SUCCESS || !view) {
                                status = 26;
                            } else {
                                const VkFramebufferCreateInfo framebuffer_info = {
                                    .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                    .renderPass = render_pass,
                                    .attachmentCount = 1,
                                    .pAttachments = &view,
                                    .width = 64, .height = 64, .layers = 1,
                                };
                                if (create_framebuffer(device, &framebuffer_info, 0, &framebuffer) != VK_SUCCESS || !framebuffer)
                                    status = 27;
                                else {
                                    report_framebuffer_ready();
                                    const VkBufferCreateInfo buffer_info = {
                                        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                        .size = 64 * 64 * 4,
                                        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                                    };
                                    if (create_buffer(device, &buffer_info, 0, &readback) != VK_SUCCESS || !readback) {
                                        status = 28;
                                    } else {
                                        VkMemoryRequirements buffer_requirements;
                                        get_buffer_requirements(device, readback, &buffer_requirements);
                                        uint32_t host_type = UINT32_MAX;
                                        for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
                                            if ((buffer_requirements.memoryTypeBits & (1u << i)) &&
                                                (properties.memoryTypes[i].propertyFlags &
                                                    (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) ==
                                                    (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
                                                host_type = i;
                                                break;
                                            }
                                        if (host_type == UINT32_MAX)
                                            for (uint32_t i = 0; i < properties.memoryTypeCount; ++i)
                                                if ((buffer_requirements.memoryTypeBits & (1u << i)) &&
                                                    (properties.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
                                                    host_type = i;
                                                    break;
                                                }
                                        const VkMemoryAllocateInfo readback_info = {
                                            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                            .allocationSize = buffer_requirements.size,
                                            .memoryTypeIndex = host_type,
                                        };
                                        if (host_type == UINT32_MAX || buffer_requirements.size < 64 * 64 * 4 ||
                                            allocate_memory(device, &readback_info, 0, &readback_memory) != VK_SUCCESS ||
                                            !readback_memory || bind_buffer(device, readback, readback_memory, 0) != VK_SUCCESS) {
                                            status = 29;
                                        } else {
                                            VkBool32 coherent = (properties.memoryTypes[host_type].propertyFlags &
                                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
                                            report_readback_buffer_ready();
                                            status = validate_submission(device, queue, family, get_proc,
                                                render_pass, framebuffer, pipeline, image, readback,
                                                readback_memory, coherent);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (framebuffer) destroy_framebuffer(device, framebuffer, 0);
        if (readback) destroy_buffer(device, readback, 0);
        if (readback_memory) free_memory(device, readback_memory, 0);
        if (view) destroy_view(device, view, 0);
        if (image) destroy_image(device, image, 0);
        if (memory) free_memory(device, memory, 0);
        if (pipeline) destroy_pipeline(device, pipeline, 0);
        if (layout) destroy_layout(device, layout, 0);
        if (render_pass) destroy_render_pass(device, render_pass, 0);
    }
    if (fragment) destroy(device, fragment, 0);
    destroy(device, vertex, 0);
    return status;
}

static void report_draw_ready(void) {
    static const char message[] = "RADV offscreen triangle draw ready\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static void report_pixels_ready(void) {
    static const char message[] = "RADV offscreen triangle pixels verified\n";
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(1L), "D"(1L),
        "S"(message), "d"(sizeof(message)-1) : "rcx", "r11", "memory");
}

static long validate_submission(VkDevice device, VkQueue queue, uint32_t family,
                                PFN_vkGetDeviceProcAddr get_proc, VkRenderPass render_pass,
                                VkFramebuffer framebuffer, VkPipeline pipeline, VkImage image,
                                VkBuffer readback, VkDeviceMemory readback_memory, VkBool32 coherent) {
    PFN_vkCreateCommandPool create_pool = (PFN_vkCreateCommandPool)get_proc(device, "vkCreateCommandPool");
    PFN_vkDestroyCommandPool destroy_pool = (PFN_vkDestroyCommandPool)get_proc(device, "vkDestroyCommandPool");
    PFN_vkAllocateCommandBuffers allocate = (PFN_vkAllocateCommandBuffers)get_proc(device, "vkAllocateCommandBuffers");
    PFN_vkBeginCommandBuffer begin = (PFN_vkBeginCommandBuffer)get_proc(device, "vkBeginCommandBuffer");
    PFN_vkEndCommandBuffer end = (PFN_vkEndCommandBuffer)get_proc(device, "vkEndCommandBuffer");
    PFN_vkCreateFence create_fence = (PFN_vkCreateFence)get_proc(device, "vkCreateFence");
    PFN_vkDestroyFence destroy_fence = (PFN_vkDestroyFence)get_proc(device, "vkDestroyFence");
    PFN_vkQueueSubmit submit = (PFN_vkQueueSubmit)get_proc(device, "vkQueueSubmit");
    PFN_vkWaitForFences wait = (PFN_vkWaitForFences)get_proc(device, "vkWaitForFences");
    PFN_vkCmdBeginRenderPass begin_render_pass = (PFN_vkCmdBeginRenderPass)get_proc(device, "vkCmdBeginRenderPass");
    PFN_vkCmdBindPipeline bind_pipeline = (PFN_vkCmdBindPipeline)get_proc(device, "vkCmdBindPipeline");
    PFN_vkCmdDraw draw = (PFN_vkCmdDraw)get_proc(device, "vkCmdDraw");
    PFN_vkCmdEndRenderPass end_render_pass = (PFN_vkCmdEndRenderPass)get_proc(device, "vkCmdEndRenderPass");
    PFN_vkCmdCopyImageToBuffer copy_image = (PFN_vkCmdCopyImageToBuffer)get_proc(device, "vkCmdCopyImageToBuffer");
    PFN_vkMapMemory map_memory = (PFN_vkMapMemory)get_proc(device, "vkMapMemory");
    PFN_vkUnmapMemory unmap_memory = (PFN_vkUnmapMemory)get_proc(device, "vkUnmapMemory");
    PFN_vkInvalidateMappedMemoryRanges invalidate = (PFN_vkInvalidateMappedMemoryRanges)get_proc(device, "vkInvalidateMappedMemoryRanges");
    if (!create_pool || !destroy_pool || !allocate || !begin || !end ||
        !create_fence || !destroy_fence || !submit || !wait || !begin_render_pass ||
        !bind_pipeline || !draw || !end_render_pass || !copy_image || !map_memory ||
        !unmap_memory || (!coherent && !invalidate)) return 12;

    const VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = family,
    };
    VkCommandPool pool = VK_NULL_HANDLE;
    if (create_pool(device, &pool_info, 0, &pool) != VK_SUCCESS || !pool) return 13;

    long status = 0;
    VkCommandBuffer command = VK_NULL_HANDLE;
    const VkCommandBufferAllocateInfo allocate_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    if (allocate(device, &allocate_info, &command) != VK_SUCCESS || !command) {
        status = 14;
    } else {
        const VkCommandBufferBeginInfo begin_info = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        if (begin(command, &begin_info) != VK_SUCCESS) {
            status = 15;
        } else {
            const VkClearValue clear = {.color = {{0.0f, 0.0f, 0.0f, 1.0f}}};
            const VkRenderPassBeginInfo render_begin = {
                .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .renderPass = render_pass,
                .framebuffer = framebuffer,
                .renderArea = {.extent = {64, 64}},
                .clearValueCount = 1,
                .pClearValues = &clear,
            };
            begin_render_pass(command, &render_begin, VK_SUBPASS_CONTENTS_INLINE);
            bind_pipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            draw(command, 3, 1, 0, 0);
            end_render_pass(command);
            const VkBufferImageCopy copy = {
                .imageSubresource = {
                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                    .layerCount = 1,
                },
                .imageExtent = {64, 64, 1},
            };
            copy_image(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback, 1, &copy);
            if (end(command) != VK_SUCCESS) status = 15;
        }
        if (status == 0) {
            const VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
            VkFence fence = VK_NULL_HANDLE;
            if (create_fence(device, &fence_info, 0, &fence) != VK_SUCCESS || !fence) {
                status = 16;
            } else {
                const VkSubmitInfo submit_info = {
                    .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                    .commandBufferCount = 1,
                    .pCommandBuffers = &command,
                };
                if (submit(queue, 1, &submit_info, fence) != VK_SUCCESS ||
                    wait(device, 1, &fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS)
                    status = 17;
                else {
                    report_submission_ready();
                    report_draw_ready();
                    void *mapped = 0;
                    if (map_memory(device, readback_memory, 0, 64 * 64 * 4, 0, &mapped) != VK_SUCCESS || !mapped) {
                        status = 30;
                    } else {
                        if (!coherent) {
                            const VkMappedMemoryRange range = {
                                .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                                .memory = readback_memory,
                                .offset = 0,
                                .size = VK_WHOLE_SIZE,
                            };
                            if (invalidate(device, 1, &range) != VK_SUCCESS) status = 31;
                        }
                        if (status == 0) {
                            const uint8_t *pixels = (const uint8_t *)mapped;
                            const uint8_t *corner = pixels;
                            const uint8_t *center = pixels + (32 * 64 + 32) * 4;
                            uint32_t black_count = 0;
                            uint32_t blue_count = 0;
                            uint32_t unexpected_count = 0;
                            for (uint32_t i = 0; i < 64 * 64; ++i) {
                                const uint8_t *pixel = pixels + i * 4;
                                if (pixel[0] <= 10 && pixel[1] <= 10 && pixel[2] <= 10 && pixel[3] >= 240)
                                    ++black_count;
                                else if (pixel[0] <= 80 && pixel[1] >= 100 && pixel[1] <= 180 &&
                                         pixel[2] >= 200 && pixel[3] >= 200)
                                    ++blue_count;
                                else
                                    ++unexpected_count;
                            }
                            report_count('B', blue_count);
                            report_count('K', black_count);
                            if (corner[0] > 10 || corner[1] > 10 || corner[2] > 10 || corner[3] < 240 ||
                                center[0] > 80 || center[1] < 100 || center[2] < 200 || center[3] < 200 ||
                                blue_count < 680 || blue_count > 760 || black_count < 3300 ||
                                unexpected_count > 16)
                                status = 32;
                            else report_pixels_ready();
                        }
                        unmap_memory(device, readback_memory);
                    }
                }
                destroy_fence(device, fence, 0);
            }
        }
    }
    destroy_pool(device, pool, 0);
    return status;
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
    int drm_primary_fd = -1;
    uint32_t drm_connector_id = 0;
    uint16_t drm_vendor_id = 0, drm_device_id = 0;
    uint16_t drm_pci_domain = 0;
    uint8_t drm_pci_bus = 0, drm_pci_slot = 0, drm_pci_function = 0;
    if (status == 0) {
        int drm_count = drmGetDevices2(0, 0, 0);
        report_count('D', (uint32_t)drm_count);
        if (drm_count <= 0) {
            status = 5;
        } else {
            drmDevicePtr devices[16] = {0};
            int fetched = drmGetDevices2(0, devices, 16);
            report_count('F', (uint32_t)fetched);
            int selected = -1;
            for (int i = 0; i < fetched && i < 16; ++i) {
                drmDevicePtr candidate = devices[i];
                if (!candidate || candidate->bustype != DRM_BUS_PCI || !candidate->businfo.pci ||
                    !candidate->deviceinfo.pci || candidate->deviceinfo.pci->vendor_id == 0 ||
                    !(candidate->available_nodes & (1 << DRM_NODE_PRIMARY)) ||
                    !(candidate->available_nodes & (1 << DRM_NODE_RENDER))) continue;
                if (selected < 0 || candidate->deviceinfo.pci->vendor_id == 0x1002) selected = i;
                if (candidate->deviceinfo.pci->vendor_id == 0x1002) break;
            }
            if (selected < 0) status = 6;
            if (status == 0) {
                drmDevicePtr selected_device = devices[selected];
                drm_vendor_id = selected_device->deviceinfo.pci->vendor_id;
                drm_device_id = selected_device->deviceinfo.pci->device_id;
                drm_pci_domain = selected_device->businfo.pci->domain;
                drm_pci_bus = selected_device->businfo.pci->bus;
                drm_pci_slot = selected_device->businfo.pci->dev;
                drm_pci_function = selected_device->businfo.pci->func;
                drm_primary_fd = open_read_write(selected_device->nodes[DRM_NODE_PRIMARY]);
                drmModeResPtr resources = drm_primary_fd >= 0 ? drmModeGetResources(drm_primary_fd) : 0;
                int primary_plane_ready = 0;
                if (resources) {
                    for (int i = 0; i < resources->count_connectors; ++i) {
                        drmModeConnectorPtr connector = drmModeGetConnector(
                            drm_primary_fd, resources->connectors[i]);
                        if (connector && connector->connection == DRM_MODE_CONNECTED &&
                            connector->count_modes > 0) {
                            drm_connector_id = connector->connector_id;
                            drmModeFreeConnector(connector);
                            break;
                        }
                        if (connector) drmModeFreeConnector(connector);
                    }
                    drmModePlaneResPtr plane_resources = drmModeGetPlaneResources(drm_primary_fd);
                    if (plane_resources) {
                        for (uint32_t i = 0; i < plane_resources->count_planes; ++i) {
                            drmModePlanePtr plane = drmModeGetPlane(drm_primary_fd, plane_resources->planes[i]);
                            if (plane) {
                                for (uint32_t format_index = 0; format_index < plane->count_formats; ++format_index)
                                    if ((plane->possible_crtcs & 1) && plane->formats[format_index] == 0x34325258) {
                                        primary_plane_ready = 1;
                                        break;
                                    }
                                drmModeFreePlane(plane);
                            }
                            if (primary_plane_ready) break;
                        }
                        drmModeFreePlaneResources(plane_resources);
                    }
                    drmModeFreeResources(resources);
                }
                if (drm_primary_fd < 0 || drm_connector_id == 0 || !primary_plane_ready) status = 34;
                else {
                    report_kms_connector_ready();
                    report_kms_primary_plane_ready();
                }
            }
            if (fetched > 0) drmFreeDevices(devices, fetched);
        }
    }
    if (status == 0) {
        PFN_vkCreateInstance create = (PFN_vkCreateInstance)
            vk_icdGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
        PFN_vkEnumerateInstanceExtensionProperties enumerate_extensions =
            (PFN_vkEnumerateInstanceExtensionProperties)vk_icdGetInstanceProcAddr(
                VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
        uint32_t extension_count = 0;
        const char *required_extensions[] = {
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_DISPLAY_EXTENSION_NAME,
            VK_EXT_DIRECT_MODE_DISPLAY_EXTENSION_NAME,
            VK_EXT_ACQUIRE_DRM_DISPLAY_EXTENSION_NAME,
            VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
        };
        if (!enumerate_extensions ||
            enumerate_extensions(0, &extension_count, 0) != VK_SUCCESS ||
            extension_count == 0 || extension_count > 64) {
            status = 33;
        } else {
            uint32_t fetched_extensions = extension_count;
            if (enumerate_extensions(0, &fetched_extensions, instance_extension_scratch) != VK_SUCCESS ||
                fetched_extensions != extension_count ||
                !has_extension(instance_extension_scratch, fetched_extensions, required_extensions[0]) ||
                !has_extension(instance_extension_scratch, fetched_extensions, required_extensions[1]) ||
                !has_extension(instance_extension_scratch, fetched_extensions, required_extensions[2]) ||
                !has_extension(instance_extension_scratch, fetched_extensions, required_extensions[3]) ||
                !has_extension(instance_extension_scratch, fetched_extensions, required_extensions[4]))
                status = 33;
            else report_direct_display_ready();
        }
        const VkInstanceCreateInfo info = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledExtensionCount = 5,
            .ppEnabledExtensionNames = required_extensions,
        };
        VkInstance instance = VK_NULL_HANDLE;
        if (status == 0 && (!create || create(&info, 0, &instance) != VK_SUCCESS || !instance)) {
            status = 2;
        }
        if (status == 0) {
            PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)
                vk_icdGetInstanceProcAddr(instance, "vkEnumeratePhysicalDevices");
            uint32_t device_count = 0;
            if (!enumerate || enumerate(instance, &device_count, 0) != VK_SUCCESS)
                status = 4;
            else {
                report_count('V', device_count);
                if (device_count != 0) {
                    VkPhysicalDevice physical = VK_NULL_HANDLE;
                    PFN_vkGetPhysicalDeviceProperties get_properties =
                        (PFN_vkGetPhysicalDeviceProperties)vk_icdGetInstanceProcAddr(
                            instance, "vkGetPhysicalDeviceProperties");
                    PFN_vkGetPhysicalDeviceProperties2 get_properties2 =
                        (PFN_vkGetPhysicalDeviceProperties2)vk_icdGetInstanceProcAddr(
                            instance, "vkGetPhysicalDeviceProperties2KHR");
                    PFN_vkEnumerateDeviceExtensionProperties enumerate_physical_extensions =
                        (PFN_vkEnumerateDeviceExtensionProperties)vk_icdGetInstanceProcAddr(
                            instance, "vkEnumerateDeviceExtensionProperties");
                    VkPhysicalDevice physical_devices[16];
                    uint32_t fetched = device_count;
                    if (!get_properties || device_count > 16 ||
                        enumerate(instance, &fetched, physical_devices) != VK_SUCCESS ||
                        fetched != device_count) {
                        status = 7;
                    } else {
                        for (uint32_t i = 0; i < fetched; ++i) {
                            if (physical_matches_drm_pci(physical_devices[i], get_properties, get_properties2,
                                enumerate_physical_extensions, drm_vendor_id, drm_device_id, drm_pci_domain,
                                drm_pci_bus, drm_pci_slot, drm_pci_function)) {
                                physical = physical_devices[i];
                                break;
                            }
                        }
                        if (!physical) status = 36;
                        else {
                            report_vulkan_drm_identity_ready();
                            report_matched_pci_bdf(drm_pci_domain, drm_pci_bus,
                                drm_pci_slot, drm_pci_function);
                        }
                    }
                    if (status == 0) {
                        VkSurfaceKHR display_surface = probe_direct_display(
                            instance, physical, drm_primary_fd, drm_connector_id);
                        PFN_vkGetPhysicalDeviceQueueFamilyProperties queue_properties =
                            (PFN_vkGetPhysicalDeviceQueueFamilyProperties)vk_icdGetInstanceProcAddr(
                                instance, "vkGetPhysicalDeviceQueueFamilyProperties");
                        VkQueueFamilyProperties families[16];
                        uint32_t family_count = 16;
                        if (!queue_properties) {
                            status = 8;
                        } else {
                            queue_properties(physical, &family_count, families);
                            uint32_t graphics_family = UINT32_MAX;
                            PFN_vkGetPhysicalDeviceSurfaceSupportKHR get_surface_support =
                                (PFN_vkGetPhysicalDeviceSurfaceSupportKHR)vk_icdGetInstanceProcAddr(
                                    instance, "vkGetPhysicalDeviceSurfaceSupportKHR");
                            for (uint32_t i = 0; i < family_count && i < 16; ++i) {
                                if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) {
                                    VkBool32 present = VK_FALSE;
                                    if (display_surface && (!get_surface_support ||
                                        get_surface_support(physical, i, display_surface, &present) != VK_SUCCESS || !present))
                                        continue;
                                    graphics_family = i;
                                    break;
                                }
                            }
                            PFN_vkCreateDevice create_device = (PFN_vkCreateDevice)
                                vk_icdGetInstanceProcAddr(instance, "vkCreateDevice");
                            if (graphics_family == UINT32_MAX || !create_device) {
                                status = 9;
                            } else {
                                float priority = 1.0f;
                                const VkDeviceQueueCreateInfo queue_info = {
                                    .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                    .queueFamilyIndex = graphics_family,
                                    .queueCount = 1,
                                    .pQueuePriorities = &priority,
                                };
                                const char *swapchain_extension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
                                uint32_t enabled_device_extension_count = 0;
                                PFN_vkEnumerateDeviceExtensionProperties enumerate_device_extensions =
                                    (PFN_vkEnumerateDeviceExtensionProperties)vk_icdGetInstanceProcAddr(
                                        instance, "vkEnumerateDeviceExtensionProperties");
                                uint32_t device_extension_count = 0;
                                if (display_surface && enumerate_device_extensions &&
                                    enumerate_device_extensions(physical, 0, &device_extension_count, 0) == VK_SUCCESS &&
                                    device_extension_count != 0 && device_extension_count <= 512) {
                                    uint32_t fetched_device_extensions = device_extension_count;
                                    if (enumerate_device_extensions(physical, 0, &fetched_device_extensions,
                                            device_extension_scratch) == VK_SUCCESS &&
                                        fetched_device_extensions == device_extension_count &&
                                        has_extension(device_extension_scratch, fetched_device_extensions,
                                            swapchain_extension))
                                        enabled_device_extension_count = 1;
                                }
                                const VkDeviceCreateInfo device_info = {
                                    .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                                    .queueCreateInfoCount = 1,
                                    .pQueueCreateInfos = &queue_info,
                                    .enabledExtensionCount = enabled_device_extension_count,
                                    .ppEnabledExtensionNames = enabled_device_extension_count ? &swapchain_extension : 0,
                                };
                                VkDevice device = VK_NULL_HANDLE;
                                if (create_device(physical, &device_info, 0, &device) != VK_SUCCESS || !device) {
                                    status = 10;
                                } else {
                                    PFN_vkGetDeviceProcAddr get_device_proc = (PFN_vkGetDeviceProcAddr)
                                        vk_icdGetInstanceProcAddr(instance, "vkGetDeviceProcAddr");
                                    PFN_vkGetDeviceQueue get_queue = get_device_proc ? (PFN_vkGetDeviceQueue)
                                        get_device_proc(device, "vkGetDeviceQueue") : 0;
                                    PFN_vkDestroyDevice destroy_device = get_device_proc ? (PFN_vkDestroyDevice)
                                        get_device_proc(device, "vkDestroyDevice") : 0;
                                    VkQueue queue = VK_NULL_HANDLE;
                                    if (get_queue) get_queue(device, graphics_family, 0, &queue);
                                    if (!get_queue || !destroy_device || !queue) status = 11;
                                    else {
                                        report_logical_device_ready();
                                        if (enabled_device_extension_count)
                                            probe_display_swapchain(instance, physical, device, queue,
                                                graphics_family, display_surface, get_device_proc);
                                        PFN_vkGetPhysicalDeviceMemoryProperties get_memory_properties =
                                            (PFN_vkGetPhysicalDeviceMemoryProperties)vk_icdGetInstanceProcAddr(
                                                instance, "vkGetPhysicalDeviceMemoryProperties");
                                        status = validate_graphics_pipeline(physical, device, queue, graphics_family,
                                            get_memory_properties, get_device_proc);
                                    }
                                    if (destroy_device) destroy_device(device, 0);
                                }
                            }
                        }
                        if (display_surface) {
                            PFN_vkDestroySurfaceKHR destroy_surface =
                                (PFN_vkDestroySurfaceKHR)vk_icdGetInstanceProcAddr(instance, "vkDestroySurfaceKHR");
                            if (destroy_surface) destroy_surface(instance, display_surface, 0);
                            else status = 35;
                        }
                    }
                }
            }
            PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)
                vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance");
            if (!destroy) status = 3;
            else destroy(instance, 0);
        }
    }
    if (drm_primary_fd >= 0) close_fd(drm_primary_fd);
    __asm__ volatile("syscall" : : "a"(60L), "D"(status) : "rcx", "r11", "memory");
    __builtin_unreachable();
}
