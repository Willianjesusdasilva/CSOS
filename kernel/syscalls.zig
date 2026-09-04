const serial = @import("serial");
const vfs = @import("vfs");
const net = @import("net");
const physical = @import("physical");
const gpu = @import("gpu");

var user_base: u64 = 0;
var user_size: u64 = 0;
var stack_base: u64 = 0;
var stack_size: u64 = 0;
var program_break: u64 = 0;
var break_limit: u64 = 0;
var mmap_next: u64 = 0;
var mmap_base: u64 = 0;
var mmap_limit: u64 = 0;
var device_mmap_next: u64 = 0;
var device_mmap_limit: u64 = 0;
var writes: usize = 0;
var process_exit_status: u64 = 0;
var process_pause: ?Pause = null;
var mmap_protect_hook: ?*const fn (u64, u64, bool, bool) callconv(.c) bool = null;
var mmap_unmap_hook: ?*const fn (u64, u64) callconv(.c) bool = null;
var device_mmap_hook: ?*const fn (u64, u64, u64, bool) callconv(.c) bool = null;
var stdin_hook: ?*const fn ([*]u8, usize) callconv(.c) usize = null;
var idle_hook: ?*const fn () callconv(.c) void = null;
pub var file_mmaps: u64 = 0;
pub var protected_mmaps: u64 = 0;
pub var unmapped_mmaps: u64 = 0;
pub var sendfile_calls: u64 = 0;
pub var framebuffer_ioctls: u64 = 0;
pub var framebuffer_mmaps: u64 = 0;
pub var drm_ioctls: u64 = 0;
pub var drm_mmaps: u64 = 0;
pub var drm_allocations: u64 = 0;
pub var drm_releases: u64 = 0;
pub var drm_last_request: u64 = 0;
pub var drm_last_result: u64 = 0;
var network_stack: ?*net.Stack = null;
var framebuffer = Framebuffer{};
const max_drm_objects = 8;
const drm_object_stride: u64 = 16 * 1024 * 1024;
const amdgpu_gem_create_cpu_access_required: u64 = 1 << 0;
const amdgpu_gem_create_no_cpu_access: u64 = 1 << 1;
const amdgpu_gem_create_cpu_gtt_uswc: u64 = 1 << 2;
const amdgpu_gem_create_vram_cleared: u64 = 1 << 3;
const amdgpu_gem_create_vm_always_valid: u64 = 1 << 6;
const amdgpu_gem_create_explicit_sync: u64 = 1 << 7;
const amdgpu_gem_create_discardable: u64 = 1 << 12;
const amdgpu_gem_create_supported = amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access |
    amdgpu_gem_create_cpu_gtt_uswc | amdgpu_gem_create_vram_cleared | amdgpu_gem_create_vm_always_valid |
    amdgpu_gem_create_explicit_sync | amdgpu_gem_create_discardable;
const DrmObject = struct {
    allocated: bool = false,
    handle_open: bool = false,
    framebuffer_reference: bool = false,
    handle: u32 = 0,
    size: u64 = 0,
    physical_address: u64 = 0,
    gpu_address: u64 = 0,
    vram_backed: bool = false,
    pages: u64 = 0,
    map_offset: u64 = 0,
    alignment: u64 = 0,
    domains: u64 = 0,
    allocation_flags: u64 = 0,
    metadata_flags: u64 = 0,
    tiling_info: u64 = 0,
    metadata_size: u32 = 0,
    metadata: [64]u32 = .{0} ** 64,
};
var drm_objects: [max_drm_objects]DrmObject = .{DrmObject{}} ** max_drm_objects;
var drm_pages: ?*physical.Allocator = null;
var drm_framebuffer_created = false;
var drm_framebuffer_handle: u32 = 0;
var drm_scanout_framebuffer: u32 = 0;
var drm_driver: DrmDriver = .csos;
var drm_vm_manager = gpu.AmdGpuVmManager{};
var drm_vm_vmid: u4 = 0;
var drm_vm_hardware: ?gpu.AmdGpuVmHardwareSession = null;
pub const AmdGpuCsEndpoint = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, u4, u64, u32) anyerror!u64,
};
var amdgpu_cs_endpoint: ?AmdGpuCsEndpoint = null;
pub const AmdGpuVramEndpoint = struct {
    context: *anyopaque,
    allocate: *const fn (*anyopaque, u64, u64) anyerror!gpu.AmdVramAllocation,
    release: *const fn (*anyopaque, gpu.AmdVramAllocation) anyerror!void,
    reserved_bytes: *const fn (*anyopaque) u64,
    largest_free_bytes: *const fn (*anyopaque) u64,
};
var amdgpu_vram_endpoint: ?AmdGpuVramEndpoint = null;
pub const AmdGpuInfoProfile = struct {
    pci_device: u16,
    pci_revision: u8,
    chip_revision: u8,
    external_revision: u8,
    family: u32,
    gfx_major: u8,
    gfx_minor: u8,
    gfx_revision: u8,
    topology: gpu.AmdGcInfo,
    cu_info: gpu.AmdGfx11CuInfo,
    clocks: gpu.AmdGpuClockInfo,
    pcie_generation: u8,
    pcie_width: u8,
    vm_info: gpu.AmdGpuVmInfo,
    vram_info: gpu.AmdAtomVramInfo,
    cache_info: gpu.AmdGfx11CacheInfo,
    mall_size: u64,
};
var amdgpu_info_profile: ?AmdGpuInfoProfile = null;
pub const AmdGpuMemoryProfile = struct {
    vram_bytes: u64,
    visible_vram_bytes: u64,
    reserved_vram_bytes: u64,
};
var amdgpu_memory_profile: ?AmdGpuMemoryProfile = null;
pub const AmdGpuFirmwareVersion = struct { version: u32, feature: u32 };
pub const AmdGpuFirmwareProfile = struct {
    me: AmdGpuFirmwareVersion,
    mec: AmdGpuFirmwareVersion,
    pfp: AmdGpuFirmwareVersion,
};
var amdgpu_firmware_profile: ?AmdGpuFirmwareProfile = null;
var amdgpu_abi_test_dispatches: u32 = 0;
fn amdgpuAbiTestSubmit(_: *anyopaque, vmid: u4, address: u64, dwords: u32) !u64 {
    if (vmid != 1 or address != 0x4000 or dwords != 4) return error.InvalidAmdGpuAbiTestSubmission;
    amdgpu_abi_test_dispatches += 1;
    return 0x100 + amdgpu_abi_test_dispatches;
}
fn amdgpuAbiTestVramAllocate(raw: *anyopaque, bytes: u64, alignment: u64) !gpu.AmdVramAllocation {
    const allocator: *gpu.AmdVramAllocator = @ptrCast(@alignCast(raw));
    return allocator.allocatePinned(bytes, alignment);
}
fn amdgpuAbiTestVramRelease(raw: *anyopaque, allocation: gpu.AmdVramAllocation) !void {
    const allocator: *gpu.AmdVramAllocator = @ptrCast(@alignCast(raw));
    try allocator.releasePinned(allocation);
}
fn amdgpuAbiTestVramReserved(raw: *anyopaque) u64 {
    const allocator: *gpu.AmdVramAllocator = @ptrCast(@alignCast(raw));
    return allocator.reservedBytes();
}
fn amdgpuAbiTestVramLargestFree(raw: *anyopaque) u64 {
    const allocator: *gpu.AmdVramAllocator = @ptrCast(@alignCast(raw));
    return allocator.largestFreeBytes();
}
const max_amdgpu_contexts = 8;
const AmdGpuContext = struct {
    allocated: bool = false,
    id: u32 = 0,
    priority: i32 = 0,
    next_handle: u64 = 1,
    completed_handle: u64 = 0,
    hardware_sequence: u64 = 0,
};
var amdgpu_contexts: [max_amdgpu_contexts]AmdGpuContext = .{AmdGpuContext{}} ** max_amdgpu_contexts;
const max_amdgpu_bo_lists = 8;
const AmdGpuBoList = struct {
    allocated: bool = false,
    handle: u32 = 0,
    count: u8 = 0,
    handles: [max_drm_objects]u32 = .{0} ** max_drm_objects,
    priorities: [max_drm_objects]u32 = .{0} ** max_drm_objects,
};
var amdgpu_bo_lists: [max_amdgpu_bo_lists]AmdGpuBoList = .{AmdGpuBoList{}} ** max_amdgpu_bo_lists;
const max_drm_syncobjs = 16;
const DrmSyncobj = struct { allocated: bool = false, point: u64 = 0 };
var drm_syncobjs: [max_drm_syncobjs]DrmSyncobj = .{DrmSyncobj{}} ** max_drm_syncobjs;
var sockets: [4]Socket = .{Socket{}} ** 4;
var unknown_seen: [512]bool = .{false} ** 512;
pub export var syscall_kernel_rsp: u64 = 0;
pub export var syscall_user_rsp: u64 = 0;

pub const Pause = struct { instruction: u64, stack: u64 };
pub const Framebuffer = struct { base: u64 = 0, size: u32 = 0, width: u32 = 0, height: u32 = 0, stride: u32 = 0, pixel_format: u32 = 0 };
pub const DrmDriver = enum { csos, amdgpu, nouveau };

extern fn syscall_entry() callconv(.naked) void;

pub fn install(kernel_stack: u64) !void {
    const extended = cpuid(0x80000000);
    if (extended.eax < 0x80000001 or (cpuid(0x80000001).edx & (1 << 20)) == 0) return error.NxUnsupported;
    syscall_kernel_rsp = kernel_stack;
    var efer = readMsr(0xc0000080);
    efer |= 1 | (1 << 11);
    writeMsr(0xc0000080, efer);
    writeMsr(0xc0000081, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    writeMsr(0xc0000082, @intFromPtr(&syscall_entry));
    writeMsr(0xc0000084, 0x200);
}

const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32) Cpuid {
    var eax = leaf;
    var ebx: u32 = undefined;
    var ecx: u32 = 0;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax), [ebx] "={ebx}" (ebx), [ecx] "+{ecx}" (ecx), [edx] "={edx}" (edx),
        :
        : .{ .memory = true });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub fn configure(base: u64, size: u64, stack: u64, stack_length: u64, initial_break: u64, maximum_break: u64, mmap_start: u64, mmap_end: u64) void {
    user_base = base;
    user_size = size;
    stack_base = stack;
    stack_size = stack_length;
    program_break = initial_break;
    break_limit = maximum_break;
    mmap_next = mmap_start;
    mmap_base = mmap_start;
    mmap_limit = mmap_end;
    device_mmap_next = mmap_end;
    device_mmap_limit = mmap_end + max_drm_objects * drm_object_stride;
    writes = 0;
    unknown_seen = .{false} ** unknown_seen.len;
    process_exit_status = 0xffffffffffffffff;
    process_pause = null;
    framebuffer_ioctls = 0;
    framebuffer_mmaps = 0;
    drm_ioctls = 0;
    drm_mmaps = 0;
    resetDrmVm();
    releaseAllDrmObjects();
    drm_allocations = 0;
    drm_releases = 0;
    drm_framebuffer_created = false;
    drm_framebuffer_handle = 0;
    drm_syncobjs = .{DrmSyncobj{}} ** max_drm_syncobjs;
    amdgpu_contexts = .{AmdGpuContext{}} ** max_amdgpu_contexts;
    amdgpu_bo_lists = .{AmdGpuBoList{}} ** max_amdgpu_bo_lists;
    drm_scanout_framebuffer = 0;
    sockets = .{Socket{}} ** sockets.len;
    vfs.reset();
}

pub fn completedWrites() usize {
    return writes;
}

pub fn configureNetwork(stack: *net.Stack) void {
    network_stack = stack;
}

pub fn configureFramebuffer(info: Framebuffer) void {
    framebuffer = info;
}

pub fn configureDrm(driver: DrmDriver) void { drm_driver = driver; }
pub fn configureDrmMemory(pages: *physical.Allocator) void { drm_pages = pages; }
pub fn configureDrmGpuVmHardware(hardware: ?gpu.AmdGpuVmHardware) void {
    if (drm_vm_hardware != null and drm_vm_hardware.?.bound_vmid != 0) return;
    drm_vm_hardware = if (hardware) |value| .{ .hardware = value } else null;
}
pub fn configureAmdGpuCsEndpoint(endpoint: ?AmdGpuCsEndpoint) void { amdgpu_cs_endpoint = endpoint; }
pub fn configureAmdGpuVramEndpoint(endpoint: ?AmdGpuVramEndpoint) void { amdgpu_vram_endpoint = endpoint; }
pub fn configureAmdGpuInfoProfile(profile: ?AmdGpuInfoProfile) void { amdgpu_info_profile = profile; }
pub fn configureAmdGpuMemoryProfile(profile: ?AmdGpuMemoryProfile) void { amdgpu_memory_profile = profile; }
pub fn configureAmdGpuFirmwareProfile(profile: ?AmdGpuFirmwareProfile) void { amdgpu_firmware_profile = profile; }

pub fn configureMmap(protect_hook: ?*const fn (u64, u64, bool, bool) callconv(.c) bool, unmap_hook: ?*const fn (u64, u64) callconv(.c) bool, device_hook: ?*const fn (u64, u64, u64, bool) callconv(.c) bool) void {
    mmap_protect_hook = protect_hook;
    mmap_unmap_hook = unmap_hook;
    device_mmap_hook = device_hook;
}

pub fn configureConsole(read_hook: ?*const fn ([*]u8, usize) callconv(.c) usize, wait_hook: ?*const fn () callconv(.c) void) void {
    stdin_hook = read_hook;
    idle_hook = wait_hook;
}

pub fn exitStatus() ?u8 {
    if (process_exit_status == 0xffffffffffffffff) return null;
    return @truncate(process_exit_status);
}

export fn process_exit_dispatch(status: u64) callconv(.c) void {
    process_exit_status = status;
}

export fn process_pause_dispatch(instruction: u64, stack: u64) callconv(.c) void {
    process_pause = .{ .instruction = instruction, .stack = stack };
}

pub fn takePause() ?Pause {
    const result = process_pause;
    process_pause = null;
    return result;
}

export fn user_syscall_dispatch(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.c) u64 {
    return switch (number) {
        0 => read(arg1, arg2, arg3),
        1 => write(arg1, arg2, arg3),
        2 => openat(@bitCast(@as(i64, -100)), arg1, arg2),
        3 => close(arg1),
        4 => stat(arg1, arg2, -100),
        5 => fstat(arg1, arg2),
        6 => stat(arg1, arg2, -100),
        8 => lseek(arg1, arg2, arg3),
        9 => mmap(arg1, arg2, arg3, arg4, arg5, arg6),
        10 => mprotect(arg1, arg2, arg3),
        11 => munmap(arg1, arg2),
        12 => brk(arg1),
        13 => rtSigaction(arg3),
        14 => rtSigprocmask(arg3, arg4),
        16 => ioctl(arg1, arg2, arg3),
        20 => writev(arg1, arg2, arg3),
        33 => duplicate(arg1, arg2),
        39 => 1,
        40 => sendfile(arg1, arg2, arg3, arg4),
        41 => socket(arg1, arg2, arg3),
        42 => connect(arg1, arg2, arg3),
        44 => sendTo(arg1, arg2, arg3),
        45 => receiveFrom(arg1, arg2, arg3),
        48 => shutdown(arg1),
        63 => uname(arg1),
        72 => fcntl(arg1, arg2, arg3),
        79 => getcwd(arg1, arg2),
        96 => writeTime(arg1, 16),
        102, 104 => 0,
        105, 106 => if (arg1 == 0) 0 else errno(1),
        110 => 0,
        158 => archPrctl(arg1, arg2),
        217 => getdents(arg1, arg2, arg3),
        218 => 1,
        228 => writeTime(arg2, 16),
        257 => openat(arg1, arg2, arg3),
        262 => stat(arg2, arg3, @bitCast(arg1)),
        else => unsupported(number),
    };
}

fn rtSigaction(old_action: u64) u64 {
    if (old_action == 0) return 0;
    if (!validUserSlice(old_action, 32)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(old_action);
    @memset(bytes[0..32], 0);
    return 0;
}

fn rtSigprocmask(old_set: u64, set_size: u64) u64 {
    if (old_set == 0) return 0;
    if (set_size > 128 or !validUserSlice(old_set, set_size)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(old_set);
    @memset(bytes[0..@intCast(set_size)], 0);
    return 0;
}

fn writeTime(address: u64, size: u64) u64 {
    if (address == 0) return 0;
    if (!validUserSlice(address, size)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..@intCast(size)], 0);
    return 0;
}

fn read(fd: u64, address: u64, length: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (fd == 0) {
        if (length == 0) return 0;
        const hook = stdin_hook orelse return 0;
        return hook(output, @intCast(length));
    }
    if (socketIndex(fd)) |index| return socketReceive(index, output[0..@intCast(length)]);
    return vfs.read(@intCast(fd), output[0..@intCast(length)]) catch |err| vfsError(err);
}

fn sendfile(output_fd: u64, input_fd: u64, offset_address: u64, count: u64) u64 {
    var explicit_offset: ?u64 = null;
    if (offset_address != 0) {
        if (!validUserSlice(offset_address, 8)) return errno(14);
        const pointer: *align(1) u64 = @ptrFromInt(offset_address);
        explicit_offset = pointer.*;
    }
    var buffer: [1024]u8 = undefined;
    var transferred: u64 = 0;
    while (transferred < count) {
        const wanted: usize = @intCast(@min(@as(u64, buffer.len), count - transferred));
        const read_count = if (explicit_offset) |position|
            vfs.pread(@intCast(input_fd), buffer[0..wanted], @intCast(position + transferred)) catch |err| return if (transferred == 0) vfsError(err) else transferred
        else
            vfs.read(@intCast(input_fd), buffer[0..wanted]) catch |err| return if (transferred == 0) vfsError(err) else transferred;
        if (read_count == 0) break;
        const written = writeKernel(output_fd, buffer[0..read_count]) catch |err| return if (transferred == 0) vfsError(err) else transferred;
        transferred += written;
        if (written != read_count) break;
    }
    if (offset_address != 0) {
        const pointer: *align(1) u64 = @ptrFromInt(offset_address);
        pointer.* = explicit_offset.? + transferred;
    }
    sendfile_calls += 1;
    return transferred;
}

fn writeKernel(fd: u64, bytes: []const u8) !usize {
    if (socketIndex(fd)) |index| {
        const result = socketSend(index, bytes);
        if (@as(i64, @bitCast(result)) < 0) return error.NetworkWriteFailed;
        return @intCast(result);
    }
    if (vfs.isDiskFile(@intCast(fd))) return vfs.write(@intCast(fd), bytes);
    if (!vfs.isConsole(@intCast(fd))) return error.BadFd;
    serial.write(bytes);
    writes += 1;
    return bytes.len;
}

fn close(fd: u64) u64 {
    if (socketIndex(fd)) |index| {
        if (sockets[index].connection) |*connection| if (network_stack) |stack| stack.tcpClose(connection) catch {};
        sockets[index] = .{};
        return 0;
    }
    if (fd <= 2 and !vfs.isOpen(@intCast(fd))) return 0;
    vfs.close(@intCast(fd)) catch |err| return vfsError(err);
    return 0;
}

fn duplicate(old_fd: u64, new_fd: u64) u64 {
    return vfs.duplicate(@intCast(old_fd), @intCast(new_fd)) catch |err| vfsError(err);
}

fn fcntl(fd: u64, command: u64, argument: u64) u64 {
    return switch (command) {
        0, 1030 => vfs.duplicateMinimum(@intCast(fd), @intCast(argument)) catch |err| vfsError(err),
        1, 3 => 0,
        2, 4 => 0,
        else => errno(22),
    };
}

fn ioctl(fd: u64, request: u64, address: u64) u64 {
    if (vfs.isFramebuffer(@intCast(fd))) {
        const result = switch (request) {
            0x4600 => framebufferVariable(address),
            0x4602 => framebufferFixed(address),
            else => errno(25),
        };
        if (result == 0) framebuffer_ioctls += 1;
        return result;
    }
    if (vfs.isDrm(@intCast(fd))) {
        const render = vfs.isDrmRender(@intCast(fd));
        const result = switch (request) {
            0xc0406400 => drmVersion(address),
            0xc010640c => drmGetCap(address),
            0x40086409 => drmGemClose(address),
            0xc02064b2 => if (render) errno(25) else drmCreateDumb(address),
            0xc01064b3 => if (render) errno(25) else drmMapDumb(address),
            0xc00464b4 => if (render) errno(25) else drmDestroyDumb(address),
            0xc04064a0 => if (render) errno(25) else drmGetResources(address),
            0xc06864a1 => if (render) errno(25) else drmGetCrtc(address),
            0xc06864a2 => if (render) errno(25) else drmSetCrtc(address),
            0xc01464a6 => if (render) errno(25) else drmGetEncoder(address),
            0xc05064a7 => if (render) errno(25) else drmGetConnector(address),
            0xc01c64ae => if (render) errno(25) else drmAddFramebuffer(address),
            0xc00464af => if (render) errno(25) else drmRemoveFramebuffer(address),
            0xc00864bf => drmSyncobjCreate(address),
            0xc00864c0 => drmSyncobjDestroy(address),
            0xc02864c3 => drmSyncobjWait(address),
            0xc01064c4 => drmSyncobjArray(address, false),
            0xc01064c5 => drmSyncobjArray(address, true),
            0xc03064ca => drmSyncobjTimelineWait(address),
            0xc01864cb => drmSyncobjTimelineQuery(address),
            0xc01864cd => drmSyncobjTimelineSignal(address),
            0xc0206440 => if (drm_driver == .amdgpu) amdgpuGemCreate(address) else errno(25),
            0xc0086441 => if (drm_driver == .amdgpu) amdgpuGemMmap(address) else errno(25),
            0xc0106442 => if (drm_driver == .amdgpu) amdgpuCtx(address) else errno(25),
            0xc0186443 => if (drm_driver == .amdgpu) amdgpuBoList(address) else errno(25),
            0xc0186444 => if (drm_driver == .amdgpu) amdgpuCs(address) else errno(25),
            0x40206445 => if (drm_driver == .amdgpu) amdgpuInfo(address) else errno(25),
            0xc1206446 => if (drm_driver == .amdgpu) amdgpuGemMetadata(address) else errno(25),
            0xc0106447 => if (drm_driver == .amdgpu) amdgpuGemWaitIdle(address) else errno(25),
            0x40286448 => if (drm_driver == .amdgpu) amdgpuGemVa(address, false) else errno(25),
            0x40406448 => if (drm_driver == .amdgpu) amdgpuGemVa(address, true) else errno(25),
            0xc0206449 => if (drm_driver == .amdgpu) amdgpuWaitCs(address) else errno(25),
            0xc0186450 => if (drm_driver == .amdgpu) amdgpuGemOp(address) else errno(25),
            0xc0106459 => if (drm_driver == .amdgpu) amdgpuGemListHandles(address) else errno(25),
            else => errno(25),
        };
        drm_last_request = request;
        drm_last_result = result;
        if (result == 0) drm_ioctls += 1;
        return result;
    }
    return errno(25);
}

fn drmVersion(address: u64) u64 {
    if (!validUserSlice(address, 64)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const name_length = read64(output + 16);
    const name_address = read64(output + 24);
    const date_length = read64(output + 32);
    const date_address = read64(output + 40);
    const description_length = read64(output + 48);
    const description_address = read64(output + 56);
    const amdgpu_minor: u32 = if (amdgpu_cs_endpoint != null and amdgpu_info_profile != null and
        amdgpu_memory_profile != null and amdgpu_firmware_profile != null and amdgpu_vram_endpoint != null) 54 else 0;
    put32(output + 0, if (drm_driver == .amdgpu) 3 else 1);
    put32(output + 4, if (drm_driver == .amdgpu) amdgpu_minor else 0);
    put32(output + 8, 0);
    const driver_name = switch (drm_driver) { .csos => "csosdrm", .amdgpu => "amdgpu", .nouveau => "nouveau" };
    const driver_description = switch (drm_driver) { .csos => "CSOS display DRM", .amdgpu => "AMD GPU", .nouveau => "NVIDIA GPU" };
    if (!copyDrmString(name_address, name_length, driver_name)) return errno(14);
    if (!copyDrmString(date_address, date_length, "20260830")) return errno(14);
    if (!copyDrmString(description_address, description_length, driver_description)) return errno(14);
    put64(output + 16, driver_name.len); put64(output + 32, 8); put64(output + 48, driver_description.len);
    return 0;
}

fn copyDrmString(address: u64, capacity: u64, value: []const u8) bool {
    if (capacity == 0) return true;
    const count = @min(capacity, value.len);
    if (address == 0 or !validUserSlice(address, count)) return false;
    const target: [*]u8 = @ptrFromInt(address);
    @memcpy(target[0..@intCast(count)], value[0..@intCast(count)]);
    return true;
}

fn drmGetCap(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const capability = read64(output);
    const value: u64 = switch (capability) {
        0x1, 0x6, 0x13, 0x14 => 1,
        else => 0,
    };
    put64(output + 8, value);
    return 0;
}

fn drmSyncobjCreate(address: u64) u64 {
    if (!validUserSlice(address, 8)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const flags = read32(output + 4);
    if ((flags & ~@as(u32, 1)) != 0) return errno(22);
    for (&drm_syncobjs, 0..) |*object, index| {
        if (object.allocated) continue;
        object.* = .{ .allocated = true, .point = if ((flags & 1) != 0) 1 else 0 };
        put32(output, @intCast(index + 1));
        return 0;
    }
    return errno(12);
}

fn drmSyncobjDestroy(address: u64) u64 {
    if (!validUserSlice(address, 8)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    if (read32(input + 4) != 0) return errno(22);
    const object = drmSyncobjForHandle(read32(input)) orelse return errno(22);
    object.* = .{};
    return 0;
}

fn drmSyncobjArray(address: u64, signal: bool) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const handles_address = read64(input);
    const count = read32(input + 8);
    if (count == 0 or count > max_drm_syncobjs or read32(input + 12) != 0 or !validUserSlice(handles_address, @as(u64, count) * 4)) return errno(22);
    const handles: [*]const u8 = @ptrFromInt(handles_address);
    var index: u32 = 0;
    while (index < count) : (index += 1) if (drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)) == null) return errno(22);
    index = 0;
    while (index < count) : (index += 1) drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)).?.point = if (signal) 1 else 0;
    return 0;
}

fn drmSyncobjWait(address: u64) u64 {
    if (!validUserSlice(address, 40)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const handles_address = read64(output);
    const count = read32(output + 16);
    const flags = read32(output + 20);
    if (count == 0 or count > max_drm_syncobjs or (flags & ~@as(u32, 1)) != 0 or read32(output + 28) != 0 or !validUserSlice(handles_address, @as(u64, count) * 4)) return errno(22);
    const handles: [*]const u8 = @ptrFromInt(handles_address);
    var signaled_count: u32 = 0;
    var first: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const object = drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)) orelse return errno(22);
        if (object.point != 0) { if (signaled_count == 0) first = index; signaled_count += 1; }
    }
    const ready = if ((flags & 1) != 0) signaled_count == count else signaled_count != 0;
    if (!ready) return errno(62);
    put32(output + 24, first);
    return 0;
}

fn drmSyncobjTimelineSignal(address: u64) u64 {
    if (!validUserSlice(address, 24)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const handles_address = read64(input);
    const points_address = read64(input + 8);
    const count = read32(input + 16);
    if (count == 0 or count > max_drm_syncobjs or read32(input + 20) != 0 or !validUserSlice(handles_address, @as(u64, count) * 4) or !validUserSlice(points_address, @as(u64, count) * 8)) return errno(22);
    const handles: [*]const u8 = @ptrFromInt(handles_address);
    const points: [*]const u8 = @ptrFromInt(points_address);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const object = drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)) orelse return errno(22);
        const point = read64(points + @as(usize, index) * 8);
        if (point == 0 or point < object.point) return errno(22);
    }
    index = 0;
    while (index < count) : (index += 1) drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)).?.point = read64(points + @as(usize, index) * 8);
    return 0;
}

fn drmSyncobjTimelineQuery(address: u64) u64 {
    if (!validUserSlice(address, 24)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const handles_address = read64(input);
    const points_address = read64(input + 8);
    const count = read32(input + 16);
    if (count == 0 or count > max_drm_syncobjs or (read32(input + 20) & ~@as(u32, 1)) != 0 or !validUserSlice(handles_address, @as(u64, count) * 4) or !validUserSlice(points_address, @as(u64, count) * 8)) return errno(22);
    const handles: [*]const u8 = @ptrFromInt(handles_address);
    const points: [*]u8 = @ptrFromInt(points_address);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const object = drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)) orelse return errno(22);
        put64(points + @as(usize, index) * 8, object.point);
    }
    return 0;
}

fn drmSyncobjTimelineWait(address: u64) u64 {
    if (!validUserSlice(address, 48)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const handles_address = read64(output);
    const points_address = read64(output + 8);
    const count = read32(output + 24);
    const flags = read32(output + 28);
    if (count == 0 or count > max_drm_syncobjs or (flags & ~@as(u32, 1)) != 0 or read32(output + 36) != 0 or !validUserSlice(handles_address, @as(u64, count) * 4) or !validUserSlice(points_address, @as(u64, count) * 8)) return errno(22);
    const handles: [*]const u8 = @ptrFromInt(handles_address);
    const points: [*]const u8 = @ptrFromInt(points_address);
    var ready_count: u32 = 0;
    var first: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const object = drmSyncobjForHandle(read32(handles + @as(usize, index) * 4)) orelse return errno(22);
        const wanted = read64(points + @as(usize, index) * 8);
        if (wanted != 0 and object.point >= wanted) { if (ready_count == 0) first = index; ready_count += 1; }
    }
    const ready = if ((flags & 1) != 0) ready_count == count else ready_count != 0;
    if (!ready) return errno(62);
    put32(output + 32, first);
    return 0;
}

fn drmSyncobjForHandle(handle: u32) ?*DrmSyncobj {
    if (handle == 0 or handle > drm_syncobjs.len) return null;
    const object = &drm_syncobjs[handle - 1];
    return if (object.allocated) object else null;
}

fn drmCreateDumb(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    var free_index: ?usize = null;
    for (drm_objects, 0..) |object, index| if (!object.allocated) { free_index = index; break; };
    const object_index = free_index orelse return errno(12);
    const output: [*]u8 = @ptrFromInt(address);
    const height = read32(output + 0);
    const width = read32(output + 4);
    const bpp = read32(output + 8);
    const flags = read32(output + 12);
    if (height == 0 or width == 0 or height > framebuffer.height or width > framebuffer.width or bpp != 32 or flags != 0) return errno(22);
    const pitch = @as(u64, width) * 4;
    const size = pitch * height;
    if (size > framebuffer.size) return errno(12);
    const page_count = (size + 4095) / 4096;
    const pages = drm_pages orelse return errno(19);
    const allocation = pages.allocate(page_count) orelse return errno(12);
    if (allocation >= (@as(u64, 1) << 44) or page_count > ((@as(u64, 1) << 44) - allocation) / 4096) {
        pages.release(allocation, page_count) catch {};
        return errno(12);
    }
    const memory: [*]u8 = @ptrFromInt(allocation);
    @memset(memory[0..@intCast(page_count * 4096)], 0);
    const handle: u32 = @intCast(object_index + 1);
    put32(output + 16, handle);
    put32(output + 20, @intCast(pitch));
    put64(output + 24, size);
    drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = allocation, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride };
    drm_allocations += 1;
    return 0;
}

fn amdgpuGemCreate(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const size = read64(io);
    const alignment = read64(io + 8);
    const domains = read64(io + 16);
    const flags = read64(io + 24);
    if (size == 0 or size > drm_object_stride or (alignment != 0 and (alignment > 4096 or (alignment & (alignment - 1)) != 0))) return errno(22);
    if (domains == 0 or (domains & ~@as(u64, 0x7)) != 0 or (flags & ~amdgpu_gem_create_supported) != 0) return errno(95);
    if ((flags & (amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access)) ==
        (amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access) or
        (flags & amdgpu_gem_create_vm_always_valid) != 0 and (domains & 0x6) == 0) return errno(22);
    var free_index: ?usize = null;
    for (drm_objects, 0..) |object, index| if (!object.allocated) { free_index = index; break; };
    const object_index = free_index orelse return errno(12);
    const page_count = (size + 4095) / 4096;
    if ((domains & 0x4) != 0) if (amdgpu_vram_endpoint) |endpoint| {
        const allocation = endpoint.allocate(endpoint.context, page_count * 4096, if (alignment == 0) 4096 else alignment) catch null;
        if (allocation) |vram| {
            const memory: [*]u8 = @ptrFromInt(vram.cpu_address);
            @memset(memory[0..@intCast(vram.bytes)], 0);
            const handle: u32 = @intCast(object_index + 1);
            drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = vram.cpu_address, .gpu_address = vram.mc_address, .vram_backed = true, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride, .alignment = if (alignment == 0) 4096 else alignment, .domains = 0x4, .allocation_flags = flags };
            put32(io, handle);
            put32(io + 4, 0);
            drm_allocations += 1;
            return 0;
        }
        if ((domains & 0x3) == 0) return errno(12);
    } else if ((domains & 0x3) == 0) return errno(19);
    const pages = drm_pages orelse return errno(19);
    const allocation = pages.allocate(page_count) orelse return errno(12);
    if (allocation >= (@as(u64, 1) << 44) or page_count > ((@as(u64, 1) << 44) - allocation) / 4096) {
        pages.release(allocation, page_count) catch {};
        return errno(12);
    }
    const memory: [*]u8 = @ptrFromInt(allocation);
    @memset(memory[0..@intCast(page_count * 4096)], 0);
    const handle: u32 = @intCast(object_index + 1);
    drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = allocation, .gpu_address = allocation, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride, .alignment = if (alignment == 0) 4096 else alignment, .domains = domains & 0x3, .allocation_flags = flags };
    put32(io, handle);
    put32(io + 4, 0);
    drm_allocations += 1;
    return 0;
}

fn amdgpuGemMmap(address: u64) u64 {
    if (!validUserSlice(address, 8)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    if (read32(io + 4) != 0) return errno(22);
    const object = drmObjectForHandle(read32(io)) orelse return errno(2);
    if ((object.allocation_flags & amdgpu_gem_create_no_cpu_access) != 0) return errno(1);
    put64(io, object.map_offset);
    return 0;
}

fn amdgpuCtx(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const op = read32(io);
    const flags = read32(io + 4);
    const id = read32(io + 8);
    const priority: i32 = @bitCast(read32(io + 12));
    if (flags != 0) return errno(22);
    if (op == 1) {
        if (id != 0 or priority < -1023 or priority > 0) return errno(if (priority > 0) 1 else 22);
        for (&amdgpu_contexts, 0..) |*context, index| if (!context.allocated) {
            const new_id: u32 = @intCast(index + 1);
            context.* = .{ .allocated = true, .id = new_id, .priority = priority };
            @memset(io[0..16], 0);
            put32(io, new_id);
            return 0;
        };
        return errno(28);
    }
    const context = amdgpuContextForId(id) orelse return errno(2);
    if (priority != 0) return errno(22);
    if (op == 2) {
        context.* = .{};
        return 0;
    }
    if (op == 3 or op == 4) {
        @memset(io[0..16], 0);
        return 0;
    }
    return errno(95);
}

fn amdgpuContextForId(id: u32) ?*AmdGpuContext {
    if (id == 0 or id > amdgpu_contexts.len) return null;
    const context = &amdgpu_contexts[id - 1];
    return if (context.allocated and context.id == id) context else null;
}

fn amdgpuBoList(address: u64) u64 {
    if (!validUserSlice(address, 24)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const operation = read32(io);
    const requested_handle = read32(io + 4);
    const count = read32(io + 8);
    const stride = read32(io + 12);
    const entries_address = read64(io + 16);
    if (operation == 1) {
        if (count != 0 or stride != 0 or entries_address != 0) return errno(22);
        const list = amdgpuBoListForHandle(requested_handle) orelse return errno(2);
        list.* = .{};
        return 0;
    }
    if (operation != 0 and operation != 2) return errno(95);
    if ((operation == 0 and requested_handle != 0) or count == 0 or count > max_drm_objects or stride < 8 or (stride & 3) != 0)
        return errno(22);
    const bytes = @as(u64, count) * stride;
    if (!validUserSlice(entries_address, bytes)) return errno(14);
    var handles: [max_drm_objects]u32 = .{0} ** max_drm_objects;
    var priorities: [max_drm_objects]u32 = .{0} ** max_drm_objects;
    const entries: [*]const u8 = @ptrFromInt(entries_address);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = entries + index * stride;
        const handle = read32(entry);
        if (drmObjectForHandle(handle) == null) return errno(2);
        var prior: usize = 0;
        while (prior < index) : (prior += 1) if (handles[prior] == handle) return errno(17);
        handles[index] = handle;
        priorities[index] = read32(entry + 4);
    }
    var list: *AmdGpuBoList = undefined;
    if (operation == 2) {
        list = amdgpuBoListForHandle(requested_handle) orelse return errno(2);
    } else {
        var free: ?usize = null;
        for (amdgpu_bo_lists, 0..) |candidate, candidate_index| if (!candidate.allocated) { free = candidate_index; break; };
        const list_index = free orelse return errno(28);
        list = &amdgpu_bo_lists[list_index];
        list.* = .{ .allocated = true, .handle = @intCast(list_index + 1) };
    }
    list.count = @intCast(count);
    list.handles = handles;
    list.priorities = priorities;
    @memset(io[0..24], 0);
    put32(io, list.handle);
    return 0;
}

fn amdgpuBoListForHandle(handle: u32) ?*AmdGpuBoList {
    if (handle == 0 or handle > amdgpu_bo_lists.len) return null;
    const list = &amdgpu_bo_lists[handle - 1];
    return if (list.allocated and list.handle == handle) list else null;
}

fn amdgpuCs(address: u64) u64 {
    if (!validUserSlice(address, 24)) return errno(14);
    const io: [*]const u8 = @ptrFromInt(address);
    const context = amdgpuContextForId(read32(io)) orelse return errno(2);
    const list_handle = read32(io + 4);
    var inline_list = AmdGpuBoList{};
    var list: ?*const AmdGpuBoList = null;
    if (list_handle != 0) list = amdgpuBoListForHandle(list_handle) orelse return errno(2);
    const chunk_count = read32(io + 8);
    if (chunk_count == 0 or chunk_count > 7 or read32(io + 12) != 0) return errno(95);
    const chunk_pointers_address = read64(io + 16);
    if (!validUserSlice(chunk_pointers_address, @as(u64, chunk_count) * 8)) return errno(14);
    const chunk_pointers: [*]const u8 = @ptrFromInt(chunk_pointers_address);
    var gpu_va: u64 = 0;
    var ib_bytes: u32 = 0;
    var saw_ib = false;
    var saw_binary_in = false;
    var saw_timeline_in = false;
    var saw_sync_out = false;
    var saw_dependencies = false;
    var saw_scheduled_dependencies = false;
    var dependency_count: usize = 0;
    var user_fence: ?*u64 = null;
    var output_syncobjs: [max_drm_syncobjs]*DrmSyncobj = undefined;
    var output_points: [max_drm_syncobjs]u64 = .{0} ** max_drm_syncobjs;
    var output_count: usize = 0;
    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const chunk_address = read64(chunk_pointers + chunk_index * 8);
        if (!validUserSlice(chunk_address, 16)) return errno(14);
        const chunk: [*]const u8 = @ptrFromInt(chunk_address);
        const chunk_id = read32(chunk);
        const length_dw = read32(chunk + 4);
        const data_address = read64(chunk + 8);
        if (chunk_id == 1) {
            if (saw_ib or length_dw != 8 or !validUserSlice(data_address, 32)) return errno(95);
            const ib: [*]const u8 = @ptrFromInt(data_address);
            const flags = read32(ib + 4);
            gpu_va = read64(ib + 8);
            ib_bytes = read32(ib + 16);
            if (read32(ib) != 0 or flags != 0 or gpu_va == 0 or (gpu_va & 3) != 0 or
                ib_bytes == 0 or (ib_bytes & 3) != 0 or ib_bytes > 0x003ffffc or
                read32(ib + 20) != 0 or read32(ib + 24) != 0 or read32(ib + 28) != 0)
                return errno(95);
            saw_ib = true;
            continue;
        }
        if (chunk_id == 2) {
            if (user_fence != null or length_dw != 2 or !validUserSlice(data_address, 8)) return errno(95);
            const fence_data: [*]const u8 = @ptrFromInt(data_address);
            const fence_handle = read32(fence_data);
            const fence_offset = read32(fence_data + 4);
            const fence_object = drmObjectForHandle(fence_handle) orelse return errno(2);
            if (fence_object.size != 4096 or (fence_object.domains & 2) == 0 or fence_object.physical_address == 0 or
                (fence_offset & 7) != 0 or fence_offset > 4096 - 8 or !amdgpuBoIsResident(list orelse &inline_list, fence_handle))
                return errno(22);
            user_fence = @ptrFromInt(fence_object.physical_address + fence_offset);
            continue;
        }
        if (chunk_id == 6) {
            if (list != null) return errno(22);
            const result = amdgpuCsInlineBoList(data_address, length_dw, &inline_list);
            if (result != 0) return result;
            list = &inline_list;
            continue;
        }
        if (chunk_id == 3 or chunk_id == 7) {
            if ((chunk_id == 3 and saw_dependencies) or (chunk_id == 7 and saw_scheduled_dependencies)) return errno(17);
            if (length_dw == 0 or (length_dw % 6) != 0 or dependency_count + length_dw / 6 > 16 or
                !validUserSlice(data_address, @as(u64, length_dw) * 4))
                return errno(22);
            if (chunk_id == 3) saw_dependencies = true else saw_scheduled_dependencies = true;
            const dependencies: [*]const u8 = @ptrFromInt(data_address);
            const entry_count = length_dw / 6;
            var dependency_index: usize = 0;
            while (dependency_index < entry_count) : (dependency_index += 1) {
                const dependency = dependencies + dependency_index * 24;
                if (read32(dependency) != 0 or read32(dependency + 4) != 0 or read32(dependency + 8) != 0)
                    return errno(95);
                const dependency_context = amdgpuContextForId(read32(dependency + 12)) orelse return errno(2);
                const dependency_handle = read64(dependency + 16);
                if (dependency_handle == 0 or dependency_handle > dependency_context.completed_handle) return errno(22);
            }
            dependency_count += entry_count;
            continue;
        }
        if (chunk_id != 4 and chunk_id != 5 and chunk_id != 8 and chunk_id != 9) return errno(95);
        const timeline = chunk_id == 8 or chunk_id == 9;
        const output = chunk_id == 5 or chunk_id == 9;
        const entry_dwords: u32 = if (timeline) 4 else 1;
        if (length_dw == 0 or (length_dw % entry_dwords) != 0 or length_dw / entry_dwords > max_drm_syncobjs or
            !validUserSlice(data_address, @as(u64, length_dw) * 4))
            return errno(22);
        if (output and saw_sync_out) return errno(17);
        if (!output and ((!timeline and saw_binary_in) or (timeline and saw_timeline_in))) return errno(17);
        if (output) saw_sync_out = true else if (timeline) saw_timeline_in = true else saw_binary_in = true;
        const entries: [*]const u8 = @ptrFromInt(data_address);
        const entry_count = length_dw / entry_dwords;
        var sync_index: usize = 0;
        while (sync_index < entry_count) : (sync_index += 1) {
            const entry = entries + sync_index * entry_dwords * 4;
            const object = drmSyncobjForHandle(read32(entry)) orelse return errno(22);
            const point = if (timeline) read64(entry + 8) else 0;
            if (timeline and read32(entry + 4) != 0) return errno(95);
            if (!output) {
                if ((point == 0 and object.point == 0) or (point != 0 and object.point < point)) return errno(62);
            } else {
                if (output_count == max_drm_syncobjs or (point != 0 and point < object.point)) return errno(22);
                var prior: usize = 0;
                while (prior < output_count) : (prior += 1) if (output_syncobjs[prior] == object) return errno(17);
                output_syncobjs[output_count] = object;
                output_points[output_count] = point;
                output_count += 1;
            }
        }
    }
    if (!saw_ib) return errno(95);
    if (drm_vm_vmid == 0 or !amdgpuBoListCoversGpuVa(list orelse &inline_list, gpu_va, ib_bytes)) return errno(22);
    const endpoint = amdgpu_cs_endpoint orelse return errno(95);
    if (context.next_handle == ~@as(u64, 0)) return errno(75);
    const hardware_sequence = endpoint.submit(endpoint.context, drm_vm_vmid, gpu_va, ib_bytes / 4) catch |err| return switch (err) {
        error.AmdGfxSubmissionQueueStopped, error.AmdGfxSubmissionRingNotIdle => errno(16),
        error.AmdGfxSubmissionTimeout, error.AmdGfxSubmissionDoorbellFailed,
        error.AmdCpGfxStopFailed => errno(5),
        error.AmdGpuVmContextNotBound, error.AmdGpuVmHardwareUnavailable => errno(19),
        else => errno(22),
    };
    const handle = context.next_handle;
    context.next_handle += 1;
    context.completed_handle = handle;
    context.hardware_sequence = hardware_sequence;
    if (user_fence) |fence| @atomicStore(u64, fence, handle, .seq_cst);
    var output_index: usize = 0;
    while (output_index < output_count) : (output_index += 1)
        output_syncobjs[output_index].point = if (output_points[output_index] == 0) 1 else output_points[output_index];
    const output: [*]u8 = @ptrFromInt(address);
    put64(output, handle);
    return 0;
}

fn amdgpuCsInlineBoList(address: u64, length_dw: u32, list: *AmdGpuBoList) u64 {
    if (length_dw < 6) return errno(22);
    if (!validUserSlice(address, @as(u64, length_dw) * 4)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const count = read32(input + 8);
    const stride = read32(input + 12);
    const entries_address = read64(input + 16);
    if (count > max_drm_objects or stride != 8) return errno(22);
    list.* = .{ .allocated = true };
    if (count == 0) return 0;
    if (!validUserSlice(entries_address, @as(u64, count) * 8)) return errno(14);
    const entries: [*]const u8 = @ptrFromInt(entries_address);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const handle = read32(entries + index * 8);
        if (drmObjectForHandle(handle) == null) return errno(2);
        list.handles[index] = handle;
        list.priorities[index] = @min(read32(entries + index * 8 + 4), 32);
    }
    list.count = @intCast(count);
    return 0;
}

fn amdgpuBoIsResident(list: *const AmdGpuBoList, handle: u32) bool {
    var index: usize = 0;
    while (index < list.count) : (index += 1) if (list.handles[index] == handle) return true;
    const object = drmObjectForHandle(handle) orelse return false;
    return (object.allocation_flags & amdgpu_gem_create_vm_always_valid) != 0;
}

fn amdgpuWaitCs(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const requested = read64(io);
    const ip_type = read32(io + 16);
    const ip_instance = read32(io + 20);
    const ring = read32(io + 24);
    const context = amdgpuContextForId(read32(io + 28)) orelse return errno(2);
    if (ip_type != 0 or ip_instance != 0 or ring != 0) return errno(95);
    const target = if (requested == ~@as(u64, 0)) context.completed_handle else requested;
    if (target > context.completed_handle) return errno(22);
    // CS submission is synchronous until an interrupt-backed fence wait exists:
    // every published context handle has already passed the physical 64-bit fence.
    @memset(io[0..32], 0);
    return 0;
}

pub fn validateAmdGpuDrmAbiSelfTest() !void {
    var memory: [16384]u8 align(4096) = .{0} ** 16384;
    var test_pages = physical.Allocator{ .free_pages = 255, .total_pages = 256, .installed_pages = 256 };
    configure(@intFromPtr(&memory), memory.len, 0, 0, @intFromPtr(&memory) + memory.len, @intFromPtr(&memory) + memory.len, @intFromPtr(&memory), @intFromPtr(&memory) + memory.len);
    configureDrm(.amdgpu);
    configureDrmMemory(&test_pages);
    var test_vram = try gpu.AmdVramAllocator.init(.{
        .cpu_start = @intFromPtr(&memory),
        .cpu_end = @intFromPtr(&memory) + memory.len - 1,
        .mc_start = 0x100000,
        .mc_end = 0x100000 + memory.len - 1,
        .bytes = memory.len,
        .framebuffer_mc_start = 0x100000,
        .framebuffer_mc_end = 0x100fff,
    });
    test_vram.sealFirmwareMap();
    configureAmdGpuVramEndpoint(.{ .context = &test_vram, .allocate = &amdgpuAbiTestVramAllocate, .release = &amdgpuAbiTestVramRelease, .reserved_bytes = &amdgpuAbiTestVramReserved, .largest_free_bytes = &amdgpuAbiTestVramLargestFree });
    defer {
        amdgpu_cs_endpoint = null;
        amdgpu_info_profile = null;
        amdgpu_memory_profile = null;
        amdgpu_firmware_profile = null;
        amdgpu_vram_endpoint = null;
        drm_pages = null;
        amdgpu_contexts = .{AmdGpuContext{}} ** max_amdgpu_contexts;
        amdgpu_bo_lists = .{AmdGpuBoList{}} ** max_amdgpu_bo_lists;
        drm_syncobjs = .{DrmSyncobj{}} ** max_drm_syncobjs;
        drm_objects = .{DrmObject{}} ** max_drm_objects;
        drm_vm_manager = .{};
        drm_vm_vmid = 0;
    }
    const base: [*]u8 = &memory;
    @memset(base[1100..1164], 0);
    if (drmVersion(@intFromPtr(base + 1100)) != 0 or read32(base + 1100) != 3 or read32(base + 1104) != 0)
        return error.AmdGpuDrmVersionLeakedBeforePhysicalGate;
    put32(base, 1);
    if (amdgpuCtx(@intFromPtr(base)) != 0 or read32(base) != 1) return error.AmdGpuCtxAllocateAbiMismatch;
    drm_objects[0] = .{ .allocated = true, .handle_open = true, .handle = 1, .size = 4096, .physical_address = @intFromPtr(base + 512), .gpu_address = @intFromPtr(base + 512), .pages = 1, .domains = 2 };
    put32(base + 32, 1);
    put32(base + 36, 0);
    put32(base + 48, 0);
    put32(base + 52, 0);
    put32(base + 56, 1);
    put32(base + 60, 8);
    put64(base + 64, @intFromPtr(base + 32));
    if (amdgpuBoList(@intFromPtr(base + 48)) != 0 or read32(base + 48) != 1) return error.AmdGpuBoListCreateAbiMismatch;
    drm_vm_vmid = 1;
    drm_vm_manager.vms[0] = .{ .allocated = true, .vmid = 1 };
    drm_vm_manager.vms[0].mappings[0] = .{ .active = true, .handle = 1, .address = 0x4000, .size = 4096, .flags = 2 };
    put64(base + 96, 0);
    put64(base + 104, 0x4000);
    put32(base + 112, 16);
    put32(base + 116, 0);
    put32(base + 120, 0);
    put32(base + 124, 0);
    put32(base + 128, 1);
    put32(base + 132, 8);
    put64(base + 136, @intFromPtr(base + 96));
    put64(base + 144, @intFromPtr(base + 128));
    put32(base + 160, 1);
    put32(base + 164, 1);
    put32(base + 168, 1);
    put32(base + 172, 0);
    put64(base + 176, @intFromPtr(base + 144));
    amdgpu_abi_test_dispatches = 0;
    var endpoint_cookie: u8 = 0;
    put64(base + 560, @intFromPtr(base + 608));
    put32(base + 568, 4);
    put32(base + 572, 3);
    put32(base + 576, 0);
    put32(base + 580, 99);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0) return error.AmdGpuHwIpLeakedBeforeGate;
    configureAmdGpuCsEndpoint(.{ .context = &endpoint_cookie, .submit = &amdgpuAbiTestSubmit });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0) return error.AmdGpuHwIpLeakedWithoutPhysicalProfile;
    const test_topology = gpu.AmdGcInfo{ .version_minor = 2, .num_shader_engines = 6, .num_wgp0_per_sa = 4, .num_wgp1_per_sa = 4, .num_rb_per_se = 2, .num_tcc_blocks = 16, .max_gprs = 1536, .max_gs_threads = 32, .gs_vgt_table_depth = 32, .gs_prim_buffer_depth = 64, .double_offchip_lds_buf = 512, .wave_front_size = 32, .num_shader_arrays_per_engine = 2, .num_sqc_per_wgp = 2, .tcp_l1_size = 32, .sqc_instruction_cache_size = 32, .sqc_data_cache_size = 16, .gl1c_per_sa = 4, .gl1c_size_per_instance = 32, .gl2c_per_gpu = 16 };
    var test_cu_info = gpu.AmdGfx11CuInfo{ .active_count = 172, .active_sa_mask = 0x07ff, .bitmap = .{.{0} ** 4} ** 4, .enabled_rb_mask = 0x7fe, .active_rb_count = 10, .tcc_disabled_mask = 4 };
    test_cu_info.bitmap[0][0] = 0xfffc;
    const test_clocks = gpu.AmdGpuClockInfo{ .counter_khz = 100000, .min_engine_khz = 2500000, .max_engine_khz = 2500000, .min_memory_khz = 1200000, .max_memory_khz = 1200000 };
    const test_vm_info = gpu.amdGpuVmInfo();
    const test_vram_info = gpu.AmdAtomVramInfo{ .format_revision = 3, .content_revision = 0, .atom_memory_type = 0x70, .uapi_vram_type = 9, .channel_count = 24, .width_bits = 384 };
    const test_cache_info = try test_topology.cacheInfo();
    configureAmdGpuInfoProfile(.{ .pci_device = 0, .pci_revision = 0, .chip_revision = 0, .external_revision = 0, .family = 145, .gfx_major = 11, .gfx_minor = 0, .gfx_revision = 2, .topology = test_topology, .cu_info = test_cu_info, .clocks = test_clocks, .pcie_generation = 4, .pcie_width = 16, .vm_info = test_vm_info, .vram_info = test_vram_info, .cache_info = test_cache_info, .mall_size = 96 * 1024 * 1024 });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0) return error.AmdGpuHwIpAcceptedInvalidPhysicalProfile;
    configureAmdGpuInfoProfile(.{ .pci_device = 0x744c, .pci_revision = 0xc8, .chip_revision = 3, .external_revision = 0x13, .family = 145, .gfx_major = 11, .gfx_minor = 0, .gfx_revision = 2, .topology = test_topology, .cu_info = test_cu_info, .clocks = test_clocks, .pcie_generation = 4, .pcie_width = 16, .vm_info = test_vm_info, .vram_info = test_vram_info, .cache_info = test_cache_info, .mall_size = 96 * 1024 * 1024 });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 1) return error.AmdGpuHwIpCountAbiMismatch;
    put32(base + 568, 40);
    put32(base + 572, 2);
    put32(base + 580, 0);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 11 or read32(base + 612) != 0 or
        read32(base + 624) != 4 or read32(base + 628) != 4 or read32(base + 632) != 1)
        return error.AmdGpuHwIpInfoAbiMismatch;
    if (read32(base + 636) != 0x0b0002) return error.AmdGpuHwIpDiscoveryVersionAbiMismatch;
    configureAmdGpuFirmwareProfile(.{
        .me = .{ .version = 0x1020304, .feature = 11 },
        .mec = .{ .version = 0x2030405, .feature = 12 },
        .pfp = .{ .version = 0x3040506, .feature = 13 },
    });
    put32(base + 568, 8);
    put32(base + 572, 0x0e);
    put32(base + 576, 0x04);
    put32(base + 580, 0);
    put32(base + 584, 0);
    put32(base + 588, 0);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0x1020304 or read32(base + 612) != 11)
        return error.AmdGpuMeFirmwareInfoAbiMismatch;
    put32(base + 576, 0x08);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0x2030405 or read32(base + 612) != 12)
        return error.AmdGpuMecFirmwareInfoAbiMismatch;
    put32(base + 576, 0x05);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0x3040506 or read32(base + 612) != 13)
        return error.AmdGpuPfpFirmwareInfoAbiMismatch;
    put32(base + 584, 1);
    if (amdgpuInfo(@intFromPtr(base + 560)) != errno(22)) return error.AmdGpuFirmwareEngineIndexAccepted;
    put32(base + 584, 0);
    configureAmdGpuMemoryProfile(.{ .vram_bytes = 12 * 1024 * 1024 * 1024, .visible_vram_bytes = memory.len, .reserved_vram_bytes = 4096 });
    @memset(base[1100..1164], 0);
    if (drmVersion(@intFromPtr(base + 1100)) != 0 or read32(base + 1100) != 3 or read32(base + 1104) != 54 or read32(base + 1108) != 0)
        return error.AmdGpuDrmVersionAbiMismatch;
    put32(base + 568, 95);
    put32(base + 572, 0x19);
    if (amdgpuInfo(@intFromPtr(base + 560)) != errno(95)) return error.AmdGpuMemoryInfoPartialAccepted;
    put32(base + 568, 96);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or
        read64(base + 608) != 12 * 1024 * 1024 * 1024 or read64(base + 616) != 12288 or
        read64(base + 624) != 4096 or read64(base + 632) != 12288 or
        read64(base + 640) != 16384 or read64(base + 648) != 12288 or
        read64(base + 656) != 4096 or read64(base + 664) != 12288 or
        read64(base + 672) != 1024 * 1024 or read64(base + 680) != 1024 * 1024 or
        read64(base + 688) != 4096 or read64(base + 696) != 255 * 4096)
        return error.AmdGpuMemoryInfoAbiMismatch;
    put64(base + 1100, 4096);
    put64(base + 1108, 4096);
    put64(base + 1116, 4);
    put64(base + 1124, 0);
    if (amdgpuGemCreate(@intFromPtr(base + 1100)) != 0 or read32(base + 1100) != 2 or
        !drm_objects[1].vram_backed or drm_objects[1].domains != 4 or drm_objects[1].gpu_address != 0x103000 or
        drm_objects[1].physical_address != @intFromPtr(base + 12288) or test_vram.reservedBytes() != 8192)
        return error.AmdGpuVramGemCreateAbiMismatch;
    if (drmCloseHandle(2) != 0 or test_vram.reservedBytes() != 4096)
        return error.AmdGpuVramGemReleaseAbiMismatch;
    @memset(base[12288..16384], 0xa5);
    put64(base + 1100, 4096);
    put64(base + 1108, 4096);
    put64(base + 1116, 4);
    put64(base + 1124, amdgpu_gem_create_no_cpu_access | amdgpu_gem_create_vram_cleared |
        amdgpu_gem_create_vm_always_valid | amdgpu_gem_create_explicit_sync | amdgpu_gem_create_discardable);
    if (amdgpuGemCreate(@intFromPtr(base + 1100)) != 0 or read32(base + 1100) != 2 or
        drm_objects[1].allocation_flags != 0x10ca or base[12288] != 0)
        return error.AmdGpuRadvGemFlagsAbiMismatch;
    put32(base + 1140, 2);
    put32(base + 1144, 0);
    if (amdgpuGemMmap(@intFromPtr(base + 1140)) != errno(1) or drmObjectForMap(drm_objects[1].map_offset, 4096) != null)
        return error.AmdGpuNoCpuAccessMappingAccepted;
    if (drmCloseHandle(2) != 0) return error.AmdGpuRadvGemFlagsReleaseMismatch;
    put64(base + 1100, 4096);
    put64(base + 1108, 4096);
    put64(base + 1116, 4);
    put64(base + 1124, amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access);
    if (amdgpuGemCreate(@intFromPtr(base + 1100)) != errno(22)) return error.AmdGpuConflictingCpuAccessFlagsAccepted;
    put64(base + 1116, 1);
    put64(base + 1124, amdgpu_gem_create_vm_always_valid);
    if (amdgpuGemCreate(@intFromPtr(base + 1100)) != errno(22)) return error.AmdGpuCpuOnlyAlwaysValidAccepted;
    put32(base + 568, 20);
    put32(base + 572, 0x16);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0x744c or read32(base + 612) != 3 or
        read32(base + 616) != 0x13 or read32(base + 620) != 0xc8 or read32(base + 624) != 145)
        return error.AmdGpuDevInfoIdentityAbiMismatch;
    put32(base + 568, 21);
    if (amdgpuInfo(@intFromPtr(base + 560)) != errno(95)) return error.AmdGpuDevInfoTopologyLeaked;
    put32(base + 568, 120);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 628) != 6 or read32(base + 632) != 2 or
        read32(base + 636) != 100000 or read64(base + 640) != 2500000 or read64(base + 648) != 1200000 or
        read32(base + 656) != 172 or read32(base + 664) != 0xfffc)
        return error.AmdGpuDevInfoTopologyClockAbiMismatch;
    put32(base + 568, 132);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 728) != 0x7fe or
        read32(base + 732) != 12 or read32(base + 736) != 8)
        return error.AmdGpuDevInfoRenderBackendAbiMismatch;
    put32(base + 568, 136);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 740) != 4)
        return error.AmdGpuDevInfoPcieAbiMismatch;
    put32(base + 568, 176);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read64(base + 744) != 0 or
        read64(base + 752) != 0x10000 or read64(base + 760) != 0x0000800000000000 or
        read32(base + 768) != 4096 or read32(base + 772) != 4096 or read32(base + 776) != 4096 or
        read32(base + 780) != 0)
        return error.AmdGpuDevInfoVmAbiMismatch;
    put32(base + 568, 184);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 784) != 9 or read32(base + 788) != 384)
        return error.AmdGpuDevInfoVramAbiMismatch;
    put32(base + 568, 192);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 792) != 0 or read32(base + 796) != 512)
        return error.AmdGpuDevInfoLdsAbiMismatch;
    put32(base + 568, 244);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read64(base + 800) != 0 or read64(base + 808) != 0 or
        read64(base + 816) != 0 or read64(base + 824) != 0 or read32(base + 832) != 0 or
        read32(base + 836) != 0 or read32(base + 840) != 0 or read32(base + 844) != 0 or
        read32(base + 848) != 32)
        return error.AmdGpuDevInfoNggWaveAbiMismatch;
    put32(base + 568, 272);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 852) != 1536 or read32(base + 856) != 16 or
        read32(base + 860) != 16 or read32(base + 864) != 32 or read32(base + 868) != 64 or
        read32(base + 872) != 32 or read32(base + 876) != 16)
        return error.AmdGpuDevInfoGraphicsConfigAbiMismatch;
    put32(base + 568, 384);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read64(base + 880) != 0 or read64(base + 944) != 0 or
        read64(base + 952) != 0 or read32(base + 960) != 0 or read64(base + 968) != 4 or
        read64(base + 976) != 2500000 or read64(base + 984) != 1200000)
        return error.AmdGpuDevInfoAoTccClockAbiMismatch;
    put32(base + 568, 408);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 992) != 32 or
        read32(base + 996) != 2 or read32(base + 1000) != 16 or read32(base + 1004) != 32 or
        read32(base + 1008) != 128 or read32(base + 1012) != 16)
        return error.AmdGpuDevInfoCacheAbiMismatch;
    put32(base + 568, 420);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read64(base + 1016) != 96 * 1024 * 1024 or
        read32(base + 1024) != 0)
        return error.AmdGpuDevInfoMallAbiMismatch;
    put32(base + 568, 448);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 1028) != 0 or
        read32(base + 1032) != 0 or read32(base + 1036) != 0 or read32(base + 1040) != 0 or
        read32(base + 1044) != 0 or read32(base + 1048) != 0)
        return error.AmdGpuDevInfoUnsupportedQueueCapabilityLeaked;
    put32(base + 2048, 1);
    put32(base + 2052, 99);
    put32(base + 2064, ~@as(u32, 0));
    put32(base + 2068, ~@as(u32, 0));
    put32(base + 2072, 1);
    put32(base + 2076, 8);
    put64(base + 2080, @intFromPtr(base + 2048));
    var parsed_inline_list = AmdGpuBoList{};
    if (amdgpuCsInlineBoList(@intFromPtr(base + 2064), 6, &parsed_inline_list) != 0 or
        parsed_inline_list.count != 1 or parsed_inline_list.handles[0] != 1 or parsed_inline_list.priorities[0] != 32)
        return error.AmdGpuInlineBoListParseMismatch;
    put32(base + 2096, 6);
    put32(base + 2100, 6);
    put64(base + 2104, @intFromPtr(base + 2064));
    put64(base + 2112, @intFromPtr(base + 128));
    put64(base + 2120, @intFromPtr(base + 2096));
    put32(base + 168, 2);
    put64(base + 176, @intFromPtr(base + 2112));
    if (amdgpuCs(@intFromPtr(base + 160)) != errno(22) or amdgpu_abi_test_dispatches != 0)
        return error.AmdGpuPersistentAndInlineBoListAccepted;
    put32(base + 164, 0);
    if (amdgpuCs(@intFromPtr(base + 160)) != 0 or read64(base + 160) != 1 or amdgpu_abi_test_dispatches != 1)
        return error.AmdGpuCsDispatchAbiMismatch;
    var empty_list = AmdGpuBoList{ .allocated = true };
    drm_objects[0].allocation_flags |= amdgpu_gem_create_vm_always_valid;
    if (!amdgpuBoListCoversGpuVa(&empty_list, 0x4000, 16)) return error.AmdGpuAlwaysValidBoNotResident;
    drm_objects[0].allocation_flags &= ~amdgpu_gem_create_vm_always_valid;
    put64(base + 192, 1);
    put64(base + 200, 0);
    put32(base + 208, 0);
    put32(base + 212, 0);
    put32(base + 216, 0);
    put32(base + 220, 1);
    if (amdgpuWaitCs(@intFromPtr(base + 192)) != 0 or read64(base + 192) != 0) return error.AmdGpuWaitCsAbiMismatch;
    put32(base + 224, 0);
    put32(base + 228, 0);
    if (drmSyncobjCreate(@intFromPtr(base + 224)) != 0 or read32(base + 224) != 1) return error.AmdGpuSyncobjCreateAbiMismatch;
    put32(base + 312, 4);
    put32(base + 316, 1);
    put64(base + 320, @intFromPtr(base + 224));
    put64(base + 328, @intFromPtr(base + 128));
    put64(base + 336, @intFromPtr(base + 312));
    put32(base + 344, 1);
    put32(base + 348, 1);
    put32(base + 352, 2);
    put32(base + 356, 0);
    put64(base + 360, @intFromPtr(base + 328));
    if (amdgpuCs(@intFromPtr(base + 344)) != errno(62) or amdgpu_abi_test_dispatches != 1 or drm_syncobjs[0].point != 0)
        return error.AmdGpuSyncobjDependencyDispatchedEarly;
    put32(base + 240, 5);
    put32(base + 244, 1);
    put64(base + 248, @intFromPtr(base + 224));
    put64(base + 256, @intFromPtr(base + 128));
    put64(base + 264, @intFromPtr(base + 240));
    put32(base + 384, 2);
    put32(base + 388, 2);
    put64(base + 392, @intFromPtr(base + 400));
    put32(base + 400, 1);
    put32(base + 404, 0);
    put64(base + 272, @intFromPtr(base + 384));
    put32(base + 280, 1);
    put32(base + 284, 1);
    put32(base + 288, 3);
    put32(base + 292, 0);
    put64(base + 296, @intFromPtr(base + 256));
    if (amdgpuCs(@intFromPtr(base + 280)) != 0 or drm_syncobjs[0].point != 1 or read64(base + 512) != 2 or amdgpu_abi_test_dispatches != 2)
        return error.AmdGpuSyncobjSignalOrderingMismatch;
}

fn amdgpuBoListCoversGpuVa(list: *const AmdGpuBoList, address: u64, size: u32) bool {
    if (address >= (@as(u64, 1) << 48) or size > (@as(u64, 1) << 48) - address) return false;
    const vm = &drm_vm_manager.vms[drm_vm_vmid - 1];
    var cursor = address;
    const end = address + size;
    while (cursor < end) {
        var covered: ?gpu.AmdGpuVaMapping = null;
        for (vm.mappings) |mapping| if (mapping.active and cursor >= mapping.address and cursor - mapping.address < 4096) {
            covered = mapping;
            break;
        };
        const mapping = covered orelse return false;
        if ((mapping.flags & 0x2) == 0) return false;
        if (!amdgpuBoIsResident(list, mapping.handle)) return false;
        cursor = @min(end, mapping.address + 4096);
    }
    return true;
}

fn amdgpuGemMetadata(address: u64) u64 {
    if (!validUserSlice(address, 288)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const object = drmObjectForHandle(read32(io)) orelse return errno(2);
    const operation = read32(io + 4);
    if (operation == 1) {
        const size = read32(io + 24);
        if (size > 256) return errno(22);
        object.metadata_flags = read64(io + 8);
        object.tiling_info = read64(io + 16);
        object.metadata_size = size;
        @memset(&object.metadata, 0);
        const words = (size + 3) / 4;
        var index: usize = 0;
        while (index < words) : (index += 1) object.metadata[index] = read32(io + 28 + index * 4);
        return 0;
    }
    if (operation != 2) return errno(22);
    put64(io + 8, object.metadata_flags);
    put64(io + 16, object.tiling_info);
    put32(io + 24, object.metadata_size);
    @memset(io[28..288], 0);
    const words = (object.metadata_size + 3) / 4;
    var index: usize = 0;
    while (index < words) : (index += 1) put32(io + 28 + index * 4, object.metadata[index]);
    return 0;
}

fn amdgpuGemWaitIdle(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    if (read32(io + 4) != 0) return errno(22);
    const object = drmObjectForHandle(read32(io)) orelse return errno(2);
    // Submission currently waits for the physical fence before returning.
    @memset(io[0..16], 0);
    put32(io + 4, @truncate(object.domains));
    return 0;
}

fn ensureAmdGpuVm() !*gpu.AmdGpuVm {
    if (drm_vm_vmid != 0) return &drm_vm_manager.vms[drm_vm_vmid - 1];
    const pages = drm_pages orelse return error.AmdGpuVmMemoryUnavailable;
    const vm = try drm_vm_manager.allocate();
    errdefer drm_vm_manager.release(vm.vmid) catch {};
    try drm_vm_manager.materialize(vm.vmid, gpu.physicalAmdGpuVmPageAllocator(pages));
    drm_vm_vmid = vm.vmid;
    return vm;
}

fn syncAmdGpuVmAfterMap() !void {
    const session = if (drm_vm_hardware) |*value| value else return;
    if (drm_vm_vmid == 0) return error.AmdGpuVmidNotAllocated;
    const root = drm_vm_manager.vms[drm_vm_vmid - 1].page_tree.root() orelse return error.AmdGpuVmPageTablesNotAllocated;
    try session.syncAfterMap(drm_vm_vmid, root);
}

fn syncAmdGpuVmAfterUnmap() !void {
    const session = if (drm_vm_hardware) |*value| value else return;
    if (drm_vm_vmid == 0) return;
    var mappings_remain = false;
    for (drm_vm_manager.vms[drm_vm_vmid - 1].mappings) |mapping| if (mapping.active) {
        mappings_remain = true;
        break;
    };
    try session.syncAfterUnmap(drm_vm_vmid, mappings_remain);
}

fn mapAmdGpuObjectPage(object: *const DrmObject, handle: u32, va: u64, bo_offset: u64, flags: u32) !void {
    const gpu_page = object.gpu_address + bo_offset;
    if (object.vram_backed)
        try drm_vm_manager.mapVramPage(drm_vm_vmid, handle, va, bo_offset, object.size, gpu_page, flags)
    else
        try drm_vm_manager.mapSystemPage(drm_vm_vmid, handle, va, bo_offset, object.size, gpu_page, flags);
}

fn unmapAmdGpuObjectPage(object: *const DrmObject, va: u64, bo_offset: u64, flags: u32) !void {
    const gpu_page = object.gpu_address + bo_offset;
    if (object.vram_backed)
        try drm_vm_manager.unmapVramPage(drm_vm_vmid, va, gpu_page, flags)
    else
        try drm_vm_manager.unmapSystemPage(drm_vm_vmid, va, gpu_page, flags);
}

fn validateAmdGpuObjectPage(object: *const DrmObject, handle: u32, va: u64, bo_offset: u64) !u32 {
    const gpu_page = object.gpu_address + bo_offset;
    return if (object.vram_backed)
        drm_vm_manager.validateVramPageMapping(drm_vm_vmid, handle, va, bo_offset, gpu_page)
    else
        drm_vm_manager.validateSystemPageMapping(drm_vm_vmid, handle, va, bo_offset, gpu_page);
}

fn amdgpuGemVa(address: u64, extended: bool) u64 {
    const input_size: u64 = if (extended) 64 else 40;
    if (!validUserSlice(address, input_size)) return errno(14);
    const io: [*]const u8 = @ptrFromInt(address);
    const handle = read32(io);
    if (read32(io + 4) != 0) return errno(22);
    const operation = read32(io + 8);
    const flags = read32(io + 12);
    const va_address = read64(io + 16);
    const bo_offset = read64(io + 24);
    const map_size = read64(io + 32);
    if (extended and (read64(io + 40) != 0 or read32(io + 48) != 0 or read32(io + 52) != 0 or read64(io + 56) != 0))
        return errno(95);
    if (map_size == 0 or (va_address & 4095) != 0 or (bo_offset & 4095) != 0 or (map_size & 4095) != 0)
        return errno(22);
    const object = drmObjectForHandle(handle) orelse return errno(2);
    if ((object.domains & 0x6) == 0 or bo_offset > object.size or map_size > object.size - bo_offset) return errno(22);

    if (operation == 1) {
        if (flags == 0 or (flags & ~@as(u32, 0x0e)) != 0) return errno(95);
        _ = ensureAmdGpuVm() catch |err| return amdGpuVmErrno(err);
        var mapped: u64 = 0;
        while (mapped < map_size) : (mapped += 4096) {
            mapAmdGpuObjectPage(object, handle, va_address + mapped, bo_offset + mapped, flags) catch |err| {
                var rollback = mapped;
                while (rollback != 0) {
                    rollback -= 4096;
                    unmapAmdGpuObjectPage(object, va_address + rollback, bo_offset + rollback, flags) catch {};
                }
                return amdGpuVmErrno(err);
            };
        }
        syncAmdGpuVmAfterMap() catch |err| {
            var rollback = mapped;
            while (rollback != 0) {
                rollback -= 4096;
                unmapAmdGpuObjectPage(object, va_address + rollback, bo_offset + rollback, flags) catch {};
            }
            if (drm_vm_hardware) |*session| if (session.bound_vmid != 0)
                session.hardware.invalidate(session.hardware.context, drm_vm_vmid) catch {};
            return amdGpuVmErrno(err);
        };
        return 0;
    }
    if (operation != 2 or flags != 0) return errno(95);
    if (drm_vm_vmid == 0) return errno(2);
    var mapped_flags: ?u32 = null;
    var checked: u64 = 0;
    while (checked < map_size) : (checked += 4096) {
        const page_flags = validateAmdGpuObjectPage(object, handle, va_address + checked, bo_offset + checked) catch |err| return amdGpuVmErrno(err);
        if (mapped_flags) |expected| {
            if (page_flags != expected) return errno(22);
        } else mapped_flags = page_flags;
    }
    const page_flags = mapped_flags orelse return errno(2);
    var unmapped: u64 = 0;
    while (unmapped < map_size) : (unmapped += 4096) {
        unmapAmdGpuObjectPage(object, va_address + unmapped, bo_offset + unmapped, page_flags) catch |err|
            return amdGpuVmErrno(err);
    }
    syncAmdGpuVmAfterUnmap() catch |err| {
        var restore: u64 = 0;
        while (restore < unmapped) : (restore += 4096) mapAmdGpuObjectPage(
            object, handle, va_address + restore, bo_offset + restore, page_flags,
        ) catch {};
        if (drm_vm_hardware) |*session| if (session.bound_vmid != 0)
            session.hardware.invalidate(session.hardware.context, drm_vm_vmid) catch {};
        return amdGpuVmErrno(err);
    };
    return 0;
}

fn amdGpuVmErrno(err: anyerror) u64 {
    return switch (err) {
        error.OutOfMemory, error.AmdGpuVmidsExhausted, error.AmdGpuVmPdb1NodesExhausted,
        error.AmdGpuVmPdb0NodesExhausted, error.AmdGpuVmPtbNodesExhausted,
        error.AmdGpuVmPageOutsideDmaMask => errno(12),
        error.AmdGpuVaMappingsExhausted => errno(28),
        error.AmdGpuVaMappingNotFound, error.AmdGpuVmBranchNotFound, error.AmdGpuVmPteNotMapped => errno(2),
        error.AmdGpuVaOverlap, error.AmdGpuVmPagePathCollision => errno(17),
        error.AmdGpuVmMemoryUnavailable, error.AmdGpuVmHardwareUnavailable => errno(19),
        error.AmdGartInvalidateTimeout, error.AmdGartRegisterWriteFailed,
        error.AmdGartRegisterReadbackFailed, error.AmdGartRegisterReadbackMismatch,
        error.AmdGartRollbackFailed => errno(5),
        else => errno(22),
    };
}

fn amdgpuGemOp(address: u64) u64 {
    if (!validUserSlice(address, 24)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const object = drmObjectForHandle(read32(io)) orelse return errno(2);
    if (read32(io + 4) != 0 or read32(io + 16) != 0 or read32(io + 20) != 0) return errno(22);
    const output_address = read64(io + 8);
    if (!validUserSlice(output_address, 32)) return errno(14);
    const output: [*]u8 = @ptrFromInt(output_address);
    put64(output, object.size);
    put64(output + 8, object.alignment);
    put64(output + 16, object.domains);
    put64(output + 24, object.allocation_flags);
    return 0;
}

fn amdgpuGemListHandles(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    if (read32(io + 12) != 0) return errno(22);
    var count: u32 = 0;
    for (drm_objects) |object| if (object.allocated and object.handle_open) { count += 1; };
    const capacity = read32(io + 8);
    const entries_address = read64(io);
    put32(io + 8, count);
    if (capacity < count) return errno(28);
    if (count == 0) return 0;
    if (!validUserSlice(entries_address, @as(u64, count) * 40)) return errno(14);
    const entries: [*]u8 = @ptrFromInt(entries_address);
    var index: usize = 0;
    for (drm_objects) |object| if (object.allocated and object.handle_open) {
        const entry = entries + index * 40;
        put32(entry, object.handle);
        put32(entry + 4, 0);
        put64(entry + 8, object.size);
        put64(entry + 16, object.domains);
        put64(entry + 24, object.allocation_flags);
        put64(entry + 32, object.alignment);
        index += 1;
    };
    return 0;
}

fn amdgpuInfo(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const return_address = read64(input);
    const return_size = read32(input + 8);
    const query = read32(input + 12);
    if (return_address == 0 or return_size == 0) return errno(22);
    if (query == 0) {
        const count = @min(return_size, 4);
        if (!validUserSlice(return_address, count)) return errno(14);
        const output: [*]u8 = @ptrFromInt(return_address);
        // Keep false until the complete Radeon Vulkan path is hardware-tested.
        @memset(output[0..count], 0);
        return 0;
    }
    const ip_type = read32(input + 16);
    const ip_instance = read32(input + 20);
    const profile = amdgpu_info_profile;
    const gfx_available = amdgpu_cs_endpoint != null and profile != null and profile.?.cu_info.active_count != 0 and
        profile.?.cu_info.enabled_rb_mask != 0 and profile.?.cu_info.active_rb_count != 0 and
        profile.?.pcie_generation != 0 and profile.?.pcie_width != 0 and
        profile.?.vm_info.virtual_address_offset != 0 and profile.?.vm_info.virtual_address_max > profile.?.vm_info.virtual_address_offset and
        profile.?.vm_info.virtual_address_alignment == 4096 and profile.?.vm_info.gart_page_size == 4096 and
        profile.?.vram_info.uapi_vram_type != 0 and profile.?.vram_info.width_bits != 0 and
        profile.?.cache_info.tcp != 0 and profile.?.cache_info.sqc_per_wgp != 0 and
        profile.?.cache_info.gl1 != 0 and profile.?.cache_info.gl2 != 0 and
        profile.?.mall_size != 0 and
        profile.?.clocks.counter_khz != 0 and profile.?.clocks.max_engine_khz != 0 and profile.?.clocks.max_memory_khz != 0 and
        profile.?.pci_device != 0 and profile.?.pci_device != 0xffff and profile.?.gfx_major == 11 and
        profile.?.topology.num_shader_engines != 0 and profile.?.topology.num_shader_arrays_per_engine != 0 and
        profile.?.topology.maxCuPerShaderArray() != 0 and profile.?.topology.max_gprs != 0 and profile.?.topology.max_gs_threads != 0;
    if (query == 3) {
        if (return_size < 4 or !validUserSlice(return_address, 4)) return errno(14);
        const output: [*]u8 = @ptrFromInt(return_address);
        put32(output, if (ip_type == 0 and gfx_available) 1 else 0);
        return 0;
    }
    if (query == 2) {
        if (ip_type != 0 or ip_instance != 0 or !gfx_available) return errno(2);
        const gfx = profile.?;
        const count = @min(return_size, 40);
        if (!validUserSlice(return_address, count)) return errno(14);
        const output: [*]u8 = @ptrFromInt(return_address);
        @memset(output[0..count], 0);
        if (count >= 4) put32(output, gfx.gfx_major);
        if (count >= 8) put32(output + 4, gfx.gfx_minor);
        if (count >= 20) put32(output + 16, 4);
        if (count >= 24) put32(output + 20, 4);
        if (count >= 28) put32(output + 24, 1);
        if (count >= 32) put32(output + 28, (@as(u32, gfx.gfx_major) << 16) | (@as(u32, gfx.gfx_minor) << 8) | gfx.gfx_revision);
        return 0;
    }
    if (query == 0x0e) {
        if (!gfx_available) return errno(19);
        if (return_size != 8 or !validUserSlice(return_address, 8)) return errno(if (return_size == 8) 14 else 95);
        if (read32(input + 28) != 0 or ip_instance != 0 or read32(input + 24) != 0) return errno(22);
        const firmware = amdgpu_firmware_profile orelse return errno(19);
        const selected = switch (ip_type) {
            0x04 => firmware.me,
            0x05 => firmware.pfp,
            0x08 => firmware.mec,
            else => return errno(95),
        };
        if (selected.version == 0) return errno(19);
        const output: [*]u8 = @ptrFromInt(return_address);
        put32(output, selected.version);
        put32(output + 4, selected.feature);
        return 0;
    }
    if (query == 0x19) {
        // drm_amdgpu_memory_info: three 32-byte drm_amdgpu_heap_info
        // records (VRAM, CPU-visible VRAM and page-backed GTT). VRAM is
        // inventory-only until GEM placement can really allocate it.
        if (return_size != 96) return errno(95);
        if (!validUserSlice(return_address, 96)) return errno(14);
        const memory = amdgpu_memory_profile orelse return errno(19);
        if (memory.vram_bytes == 0 or memory.visible_vram_bytes == 0 or
            memory.visible_vram_bytes > memory.vram_bytes or memory.reserved_vram_bytes > memory.visible_vram_bytes)
            return errno(19);
        const pages = drm_pages orelse return errno(19);
        var gtt_usage: u64 = 0;
        for (drm_objects) |object| if (object.allocated) {
            if (!object.vram_backed) gtt_usage += object.pages * 4096;
        };
        const gtt_free = pages.free_pages * 4096;
        const gtt_total = gtt_free + gtt_usage;
        const vram_reserved = if (amdgpu_vram_endpoint) |endpoint| endpoint.reserved_bytes(endpoint.context) else memory.reserved_vram_bytes;
        const vram_free = if (amdgpu_vram_endpoint != null and vram_reserved <= memory.visible_vram_bytes) memory.visible_vram_bytes - vram_reserved else 0;
        const vram_max = if (amdgpu_vram_endpoint) |endpoint| @min(endpoint.largest_free_bytes(endpoint.context), drm_object_stride) else 0;
        const output: [*]u8 = @ptrFromInt(return_address);
        @memset(output[0..96], 0);
        put64(output, memory.vram_bytes);
        put64(output + 8, vram_free);
        put64(output + 16, vram_reserved);
        put64(output + 24, vram_max);
        put64(output + 32, memory.visible_vram_bytes);
        put64(output + 40, vram_free);
        put64(output + 48, vram_reserved);
        put64(output + 56, vram_max);
        put64(output + 64, gtt_total);
        put64(output + 72, gtt_total);
        put64(output + 80, gtt_usage);
        put64(output + 88, @min(gtt_free, drm_object_stride));
        return 0;
    }
    if (query == 0x16) {
        if (!gfx_available) return errno(19);
        // Accept only field boundaries that have been audited, plus the full
        // naturally aligned UAPI structure. This avoids returning a partial
        // scalar while still supporting current userspace's sizeof request.
        if (return_size != 20 and return_size != 120 and return_size != 132 and return_size != 136 and return_size != 176 and return_size != 184 and return_size != 192 and return_size != 244 and return_size != 272 and return_size != 384 and return_size != 408 and return_size != 420 and return_size != 444 and return_size != 448) return errno(95);
        if (!validUserSlice(return_address, return_size)) return errno(14);
        const gfx = profile.?;
        const output: [*]u8 = @ptrFromInt(return_address);
        @memset(output[0..return_size], 0);
        put32(output, gfx.pci_device);
        put32(output + 4, gfx.chip_revision);
        put32(output + 8, gfx.external_revision);
        put32(output + 12, gfx.pci_revision);
        put32(output + 16, gfx.family);
        if (return_size >= 120) {
            put32(output + 20, gfx.topology.num_shader_engines);
            put32(output + 24, gfx.topology.num_shader_arrays_per_engine);
            put32(output + 28, gfx.clocks.counter_khz);
            put64(output + 32, gfx.clocks.max_engine_khz);
            put64(output + 40, gfx.clocks.max_memory_khz);
            put32(output + 48, gfx.cu_info.active_count);
            var se: usize = 0;
            while (se < 4) : (se += 1) {
                var sa: usize = 0;
                while (sa < 4) : (sa += 1)
                    put32(output + 56 + (se * 4 + sa) * 4, gfx.cu_info.bitmap[se][sa]);
            }
        }
        if (return_size >= 132) {
            put32(output + 120, gfx.cu_info.enabled_rb_mask);
            put32(output + 124, gfx.topology.num_shader_engines * gfx.topology.num_rb_per_se);
            put32(output + 128, 8);
        }
        if (return_size == 136) put32(output + 132, gfx.pcie_generation);
        if (return_size >= 176) {
            put32(output + 132, gfx.pcie_generation);
            put64(output + 136, gfx.vm_info.ids_flags);
            put64(output + 144, gfx.vm_info.virtual_address_offset);
            put64(output + 152, gfx.vm_info.virtual_address_max);
            put32(output + 160, gfx.vm_info.virtual_address_alignment);
            put32(output + 164, gfx.vm_info.pte_fragment_size);
            put32(output + 168, gfx.vm_info.gart_page_size);
            put32(output + 172, gfx.vm_info.ce_ram_size);
        }
        if (return_size >= 184) {
            put32(output + 176, gfx.vram_info.uapi_vram_type);
            put32(output + 180, gfx.vram_info.width_bits);
        }
        if (return_size == 192) {
            // GFX11 uses VCN rather than the legacy VCE block.
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
        }
        if (return_size == 244) {
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
            // NGG kernel buffers are not allocated; memset above is the
            // authoritative zero state for addresses and sizes at 192..239.
            put32(output + 240, gfx.topology.wave_front_size);
        }
        if (return_size == 272) {
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
            put32(output + 240, gfx.topology.wave_front_size);
            put32(output + 244, gfx.topology.max_gprs);
            put32(output + 248, gfx.topology.maxCuPerShaderArray());
            put32(output + 252, gfx.topology.num_tcc_blocks);
            put32(output + 256, gfx.topology.gs_vgt_table_depth);
            put32(output + 260, gfx.topology.gs_prim_buffer_depth);
            put32(output + 264, gfx.topology.max_gs_threads);
            put32(output + 268, gfx.pcie_width);
        }
        if (return_size == 384) {
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
            put32(output + 240, gfx.topology.wave_front_size);
            put32(output + 244, gfx.topology.max_gprs);
            put32(output + 248, gfx.topology.maxCuPerShaderArray());
            put32(output + 252, gfx.topology.num_tcc_blocks);
            put32(output + 256, gfx.topology.gs_vgt_table_depth);
            put32(output + 260, gfx.topology.gs_prim_buffer_depth);
            put32(output + 264, gfx.topology.max_gs_threads);
            put32(output + 268, gfx.pcie_width);
            // GFX11 does not populate an always-on CU bitmap; high VA is not
            // implemented and PA_SC tile steering is explicitly zero.
            put64(output + 360, gfx.cu_info.tcc_disabled_mask);
            put64(output + 368, gfx.clocks.min_engine_khz);
            put64(output + 376, gfx.clocks.min_memory_khz);
        }
        if (return_size == 408) {
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
            put32(output + 240, gfx.topology.wave_front_size);
            put32(output + 244, gfx.topology.max_gprs);
            put32(output + 248, gfx.topology.maxCuPerShaderArray());
            put32(output + 252, gfx.topology.num_tcc_blocks);
            put32(output + 256, gfx.topology.gs_vgt_table_depth);
            put32(output + 260, gfx.topology.gs_prim_buffer_depth);
            put32(output + 264, gfx.topology.max_gs_threads);
            put32(output + 268, gfx.pcie_width);
            put64(output + 360, gfx.cu_info.tcc_disabled_mask);
            put64(output + 368, gfx.clocks.min_engine_khz);
            put64(output + 376, gfx.clocks.min_memory_khz);
            put32(output + 384, gfx.cache_info.tcp);
            put32(output + 388, gfx.cache_info.sqc_per_wgp);
            put32(output + 392, gfx.cache_info.sqc_data);
            put32(output + 396, gfx.cache_info.sqc_instruction);
            put32(output + 400, gfx.cache_info.gl1);
            put32(output + 404, gfx.cache_info.gl2);
        }
        if (return_size >= 420) {
            put32(output + 184, 0);
            put32(output + 188, gfx.topology.double_offchip_lds_buf);
            put32(output + 240, gfx.topology.wave_front_size);
            put32(output + 244, gfx.topology.max_gprs);
            put32(output + 248, gfx.topology.maxCuPerShaderArray());
            put32(output + 252, gfx.topology.num_tcc_blocks);
            put32(output + 256, gfx.topology.gs_vgt_table_depth);
            put32(output + 260, gfx.topology.gs_prim_buffer_depth);
            put32(output + 264, gfx.topology.max_gs_threads);
            put32(output + 268, gfx.pcie_width);
            put64(output + 360, gfx.cu_info.tcc_disabled_mask);
            put64(output + 368, gfx.clocks.min_engine_khz);
            put64(output + 376, gfx.clocks.min_memory_khz);
            put32(output + 384, gfx.cache_info.tcp);
            put32(output + 388, gfx.cache_info.sqc_per_wgp);
            put32(output + 392, gfx.cache_info.sqc_data);
            put32(output + 396, gfx.cache_info.sqc_instruction);
            put32(output + 400, gfx.cache_info.gl1);
            put32(output + 404, gfx.cache_info.gl2);
            put64(output + 408, gfx.mall_size);
            put32(output + 416, 0);
        }
        // 420..443 remain zero unless CP shadowing and user queues are really
        // enabled. 444..447 are ABI tail padding and were cleared above.
        return 0;
    }
    return errno(22);
}

fn drmMapDumb(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const object = drmObjectForHandle(read32(output)) orelse return errno(2);
    put64(output + 8, object.map_offset);
    return 0;
}

fn drmDestroyDumb(address: u64) u64 {
    if (!validUserSlice(address, 4)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const handle = read32(input);
    return drmCloseHandle(handle);
}

fn drmGemClose(address: u64) u64 {
    if (!validUserSlice(address, 8)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    if (read32(input + 4) != 0) return errno(22);
    return drmCloseHandle(read32(input));
}

fn drmCloseHandle(handle: u32) u64 {
    const object = drmObjectForHandle(handle) orelse return errno(2);
    for (amdgpu_bo_lists) |list| if (list.allocated) {
        var index: usize = 0;
        while (index < list.count) : (index += 1) if (list.handles[index] == handle) return errno(16);
    };
    if (drm_vm_vmid != 0) for (drm_vm_manager.vms[drm_vm_vmid - 1].mappings) |mapping|
        if (mapping.active and mapping.handle == handle) return errno(16);
    object.handle_open = false;
    if (!object.framebuffer_reference) releaseDrmObject(object);
    return 0;
}

fn releaseDrmObject(object: *DrmObject) void {
    if (object.allocated and object.physical_address != 0 and object.pages != 0) {
        if (object.vram_backed) {
            if (amdgpu_vram_endpoint) |endpoint| endpoint.release(endpoint.context, .{ .cpu_address = object.physical_address, .mc_address = object.gpu_address, .bytes = object.pages * 4096 }) catch {};
        } else if (drm_pages) |pages| pages.release(object.physical_address, object.pages) catch {};
        drm_releases += 1;
    }
    object.* = .{};
}

fn releaseAllDrmObjects() void { for (&drm_objects) |*object| releaseDrmObject(object); }

fn resetDrmVm() void {
    if (drm_vm_vmid == 0) return;
    if (drm_vm_hardware) |*session| session.reset() catch return;
    const vm = &drm_vm_manager.vms[drm_vm_vmid - 1];
    while (true) {
        var active: ?gpu.AmdGpuVaMapping = null;
        for (vm.mappings) |mapping| if (mapping.active) {
            active = mapping;
            break;
        };
        const mapping = active orelse break;
        var object: ?*DrmObject = null;
        for (&drm_objects) |*candidate| if (candidate.allocated and candidate.handle == mapping.handle) {
            object = candidate;
            break;
        };
        const bo = object orelse break;
        unmapAmdGpuObjectPage(bo, mapping.address, mapping.bo_offset, mapping.flags) catch break;
    }
    drm_vm_manager.dematerialize(drm_vm_vmid) catch return;
    drm_vm_manager.release(drm_vm_vmid) catch return;
    drm_vm_vmid = 0;
}
fn drmObjectForHandle(handle: u32) ?*DrmObject {
    if (handle == 0 or handle > drm_objects.len) return null;
    const object = &drm_objects[handle - 1];
    return if (object.allocated and object.handle_open and object.handle == handle) object else null;
}
fn drmObjectForMap(offset: u64, length: u64) ?*DrmObject {
    for (&drm_objects) |*object| {
        if (object.allocated and (object.allocation_flags & amdgpu_gem_create_no_cpu_access) == 0 and offset >= object.map_offset and offset - object.map_offset <= object.size and length <= object.size - (offset - object.map_offset)) return object;
    }
    return null;
}

fn drmGetResources(address: u64) u64 {
    if (!validUserSlice(address, 64)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const framebuffer_pointer = read64(output + 0);
    const crtc_pointer = read64(output + 8);
    const connector_pointer = read64(output + 16);
    const encoder_pointer = read64(output + 24);
    const crtc_capacity = read32(output + 36);
    const connector_capacity = read32(output + 40);
    const encoder_capacity = read32(output + 44);
    const framebuffer_capacity = read32(output + 32);
    if (drm_framebuffer_created and !putDrmId(framebuffer_pointer, framebuffer_capacity, 4)) return errno(14);
    if (!putDrmId(crtc_pointer, crtc_capacity, 1) or !putDrmId(connector_pointer, connector_capacity, 2) or !putDrmId(encoder_pointer, encoder_capacity, 3)) return errno(14);
    put32(output + 32, if (drm_framebuffer_created) 1 else 0);
    put32(output + 36, 1); put32(output + 40, 1); put32(output + 44, 1);
    put32(output + 48, 1); put32(output + 52, framebuffer.width);
    put32(output + 56, 1); put32(output + 60, framebuffer.height);
    return 0;
}

fn putDrmId(address: u64, capacity: u32, id: u32) bool {
    if (capacity == 0) return true;
    if (address == 0 or !validUserSlice(address, 4)) return false;
    const output: [*]u8 = @ptrFromInt(address);
    put32(output, id);
    return true;
}

fn drmGetEncoder(address: u64) u64 {
    if (!validUserSlice(address, 20)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (read32(output) != 3) return errno(2);
    put32(output + 4, 5);
    put32(output + 8, 1);
    put32(output + 12, 1);
    put32(output + 16, 0);
    return 0;
}

fn drmGetConnector(address: u64) u64 {
    if (!validUserSlice(address, 80)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (read32(output + 48) != 2) return errno(2);
    const encoder_pointer = read64(output + 0);
    const mode_pointer = read64(output + 8);
    const mode_capacity = read32(output + 32);
    const encoder_capacity = read32(output + 40);
    if (!putDrmId(encoder_pointer, encoder_capacity, 3)) return errno(14);
    if (mode_capacity != 0) {
        if (mode_pointer == 0 or !validUserSlice(mode_pointer, 68)) return errno(14);
        const mode: [*]u8 = @ptrFromInt(mode_pointer);
        writeDrmMode(mode);
    }
    put32(output + 32, 1); put32(output + 36, 0); put32(output + 40, 1);
    put32(output + 44, 3); put32(output + 48, 2);
    put32(output + 52, 15); put32(output + 56, 1); put32(output + 60, 1);
    put32(output + 64, 0); put32(output + 68, 0); put32(output + 72, 0); put32(output + 76, 0);
    return 0;
}

fn drmGetCrtc(address: u64) u64 {
    if (!validUserSlice(address, 104)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (read32(output + 12) != 1) return errno(2);
    put64(output + 0, 0); put32(output + 8, 0); put32(output + 12, 1);
    put32(output + 16, drm_scanout_framebuffer); put32(output + 20, 0); put32(output + 24, 0);
    put32(output + 28, 0); put32(output + 32, 1);
    writeDrmMode(output + 36);
    return 0;
}

fn drmAddFramebuffer(address: u64) u64 {
    if (!validUserSlice(address, 28)) return errno(14);
    if (drm_framebuffer_created) return errno(16);
    const output: [*]u8 = @ptrFromInt(address);
    const width = read32(output + 4);
    const height = read32(output + 8);
    const pitch = read32(output + 12);
    if (width == 0 or height == 0 or width > framebuffer.width or height > framebuffer.height) return errno(22);
    if (pitch != width * 4 or read32(output + 16) != 32 or read32(output + 20) != 24) return errno(22);
    const handle = read32(output + 24);
    const object = drmObjectForHandle(handle) orelse return errno(2);
    if (@as(u64, pitch) * height > object.size) return errno(22);
    put32(output, 4);
    drm_framebuffer_created = true;
    drm_framebuffer_handle = handle;
    object.framebuffer_reference = true;
    return 0;
}

fn drmSetCrtc(address: u64) u64 {
    if (!validUserSlice(address, 104)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    if (read32(input + 12) != 1 or read32(input + 16) != 4 or !drm_framebuffer_created) return errno(2);
    if (read32(input + 20) != 0 or read32(input + 24) != 0 or read32(input + 28) != 0 or read32(input + 32) != 1) return errno(22);
    const connectors = read64(input);
    if (connectors == 0 or !validUserSlice(connectors, 4)) return errno(14);
    const connector: [*]const u8 = @ptrFromInt(connectors);
    if (read32(connector) != 2 or read16(input + 40) != framebuffer.width or read16(input + 50) != framebuffer.height) return errno(22);
    drm_scanout_framebuffer = 4;
    return 0;
}

fn drmRemoveFramebuffer(address: u64) u64 {
    if (!validUserSlice(address, 4)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    if (!drm_framebuffer_created or read32(input) != 4) return errno(2);
    drm_scanout_framebuffer = 0;
    const object = &drm_objects[drm_framebuffer_handle - 1];
    object.framebuffer_reference = false;
    if (!object.handle_open) releaseDrmObject(object);
    drm_framebuffer_created = false;
    drm_framebuffer_handle = 0;
    return 0;
}

fn writeDrmMode(output: [*]u8) void {
    @memset(output[0..68], 0);
    const clock: u32 = @intCast((@as(u64, framebuffer.width) * framebuffer.height * 60) / 1000);
    put32(output + 0, clock);
    put16(output + 4, @intCast(framebuffer.width)); put16(output + 6, @intCast(framebuffer.width));
    put16(output + 8, @intCast(framebuffer.width)); put16(output + 10, @intCast(framebuffer.width));
    put16(output + 14, @intCast(framebuffer.height)); put16(output + 16, @intCast(framebuffer.height));
    put16(output + 18, @intCast(framebuffer.height)); put16(output + 20, @intCast(framebuffer.height));
    put32(output + 24, 60); put32(output + 28, 0); put32(output + 32, 0x48);
    writeModeName(output + 36, framebuffer.width, framebuffer.height);
}

fn writeModeName(output: [*]u8, width: u32, height: u32) void {
    var index = writeDecimal(output, width);
    output[index] = 'x'; index += 1;
    _ = writeDecimal(output + index, height);
}

fn writeDecimal(output: [*]u8, value: u32) usize {
    var divisor: u32 = 1;
    while (value / divisor >= 10) divisor *= 10;
    var remaining = value;
    var count: usize = 0;
    while (divisor != 0) : (divisor /= 10) {
        output[count] = @intCast('0' + remaining / divisor);
        remaining %= divisor;
        count += 1;
    }
    return count;
}

fn framebufferVariable(address: u64) u64 {
    if (framebuffer.base == 0 or !validUserSlice(address, 160)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    @memset(output[0..160], 0);
    put32(output + 0, framebuffer.width);
    put32(output + 4, framebuffer.height);
    put32(output + 8, framebuffer.width);
    put32(output + 12, framebuffer.height);
    put32(output + 24, 32);
    const red_offset: u32 = if (framebuffer.pixel_format == 1) 0 else 16;
    const blue_offset: u32 = if (framebuffer.pixel_format == 1) 16 else 0;
    put32(output + 32, red_offset); put32(output + 36, 8);
    put32(output + 44, 8); put32(output + 48, 8);
    put32(output + 56, blue_offset); put32(output + 60, 8);
    put32(output + 68, 24); put32(output + 72, 8);
    return 0;
}

fn framebufferFixed(address: u64) u64 {
    if (framebuffer.base == 0 or !validUserSlice(address, 80)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    @memset(output[0..80], 0);
    @memcpy(output[0..4], "CSOS");
    put64(output + 16, framebuffer.base);
    put32(output + 24, framebuffer.size);
    put32(output + 28, 0);
    put32(output + 36, 2);
    put32(output + 48, framebuffer.stride * 4);
    return 0;
}

fn openat(directory_fd: u64, path_address: u64, flags: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    const fd = vfs.openAt(@bitCast(directory_fd), path, flags) catch |err| return vfsError(err);
    return fd;
}

fn stat(path_address: u64, output_address: u64, directory_fd: i64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    const info = vfs.infoAt(directory_fd, path) catch |err| return vfsError(err);
    return writeStat(output_address, info);
}

fn fstat(fd: u64, output_address: u64) u64 {
    if (fd <= 2) return writeStat(output_address, .{ .mode = 0o020666, .size = 0, .directory = false });
    const info = vfs.infoFd(@intCast(fd)) catch |err| return vfsError(err);
    return writeStat(output_address, info);
}

fn writeStat(address: u64, info: vfs.Info) u64 {
    if (!validUserSlice(address, 144)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..144], 0);
    put64(bytes + 8, 1);
    put64(bytes + 16, 1);
    put32(bytes + 24, info.mode);
    put64(bytes + 48, info.size);
    put64(bytes + 56, 4096);
    put64(bytes + 64, (info.size + 511) / 512);
    return 0;
}

fn lseek(fd: u64, raw_offset: u64, whence: u64) u64 {
    const offset: i64 = @bitCast(raw_offset);
    return vfs.seek(@intCast(fd), offset, whence) catch |err| vfsError(err);
}

fn getdents(fd: u64, address: u64, length: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    return vfs.getDents(@intCast(fd), output[0..@intCast(length)]) catch |err| vfsError(err);
}

fn writev(fd: u64, address: u64, count: u64) u64 {
    if (count > 64 or !validUserSlice(address, count * 16)) return errno(14);
    var total: u64 = 0;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const item: [*]const u8 = @ptrFromInt(address + index * 16);
        const base = read64(item);
        const length = read64(item + 8);
        const result = write(fd, base, length);
        if (@as(i64, @bitCast(result)) < 0) return result;
        total += result;
    }
    return total;
}

fn uname(address: u64) u64 {
    if (!validUserSlice(address, 390)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..390], 0);
    copyZ(bytes, "CSOS");
    copyZ(bytes + 65, "csos");
    copyZ(bytes + 130, "0.1");
    copyZ(bytes + 195, "CSOS");
    copyZ(bytes + 260, "x86_64");
    return 0;
}

fn getcwd(address: u64, size: u64) u64 {
    if (size < 2 or !validUserSlice(address, 2)) return errno(34);
    const bytes: [*]u8 = @ptrFromInt(address);
    bytes[0] = '/'; bytes[1] = 0;
    return address;
}

fn userString(address: u64, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) {
        if (!validUserSlice(address + length, 1)) return null;
        const source: *const u8 = @ptrFromInt(address + length);
        if (source.* == 0) return buffer[0..length];
        buffer[length] = source.*;
    }
    return null;
}

fn vfsError(err: anyerror) u64 {
    return switch (err) { error.NotFound => errno(2), error.BadFd => errno(9), error.NotDirectory => errno(20), error.TooManyFiles => errno(24), else => errno(22) };
}

fn put32(target: [*]u8, value: u32) void { var i: usize = 0; while (i < 4) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
fn put16(target: [*]u8, value: u16) void { target[0] = @truncate(value); target[1] = @truncate(value >> 8); }
fn put64(target: [*]u8, value: u64) void { var i: usize = 0; while (i < 8) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
fn read32(source: [*]const u8) u32 { var value: u32 = 0; var i: usize = 0; while (i < 4) : (i += 1) value |= @as(u32, source[i]) << @intCast(i * 8); return value; }
fn read16(source: [*]const u8) u16 { return @as(u16, source[0]) | (@as(u16, source[1]) << 8); }
fn read64(source: [*]const u8) u64 { var value: u64 = 0; var i: usize = 0; while (i < 8) : (i += 1) value |= @as(u64, source[i]) << @intCast(i * 8); return value; }
fn copyZ(target: [*]u8, text: []const u8) void { @memcpy(target[0..text.len], text); target[text.len] = 0; }

fn write(fd: u64, address: u64, length: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const text: [*]const u8 = @ptrFromInt(address);
    if (socketIndex(fd)) |index| return socketSend(index, text[0..@intCast(length)]);
    if (vfs.isDiskFile(@intCast(fd))) return vfs.write(@intCast(fd), text[0..@intCast(length)]) catch |err| vfsError(err);
    if (!vfs.isConsole(@intCast(fd))) return errno(9);
    serial.write(text[0..@intCast(length)]);
    writes += 1;
    return length;
}

const Socket = struct {
    allocated: bool = false,
    connection: ?net.TcpConnection = null,
};

fn socket(domain: u64, kind: u64, protocol: u64) u64 {
    if (domain != 2 or (kind & 0xf) != 1 or (protocol != 0 and protocol != 6)) return errno(97);
    for (&sockets, 0..) |*entry, index| {
        if (!entry.allocated) {
            entry.* = .{ .allocated = true };
            return 32 + index;
        }
    }
    return errno(24);
}

fn connect(fd: u64, address: u64, length: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (length < 16 or !validUserSlice(address, 16)) return errno(14);
    const bytes: [*]const u8 = @ptrFromInt(address);
    if (bytes[0] != 2 or bytes[1] != 0) return errno(97);
    const port = (@as(u16, bytes[2]) << 8) | bytes[3];
    const destination = [4]u8{ bytes[4], bytes[5], bytes[6], bytes[7] };
    const stack = network_stack orelse return errno(100);
    sockets[index].connection = stack.tcpConnect(destination, port, @intCast(49153 + index)) catch return errno(111);
    return 0;
}

fn sendTo(fd: u64, address: u64, length: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (!validUserSlice(address, length)) return errno(14);
    const bytes: [*]const u8 = @ptrFromInt(address);
    return socketSend(index, bytes[0..@intCast(length)]);
}

fn receiveFrom(fd: u64, address: u64, length: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (!validUserSlice(address, length)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    return socketReceive(index, bytes[0..@intCast(length)]);
}

fn shutdown(fd: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection| stack.tcpClose(connection) catch return errno(5) else return errno(107);
    return 0;
}

fn socketSend(index: usize, data: []const u8) u64 {
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection|
        return stack.tcpSend(connection, data) catch errno(5);
    return errno(107);
}

fn socketReceive(index: usize, data: []u8) u64 {
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection|
        return stack.tcpReceive(connection, data) catch errno(5);
    return errno(107);
}

fn socketIndex(fd: u64) ?usize {
    if (fd < 32 or fd >= 32 + sockets.len) return null;
    const index: usize = @intCast(fd - 32);
    return if (sockets[index].allocated) index else null;
}

fn archPrctl(code: u64, address: u64) u64 {
    if (code != 0x1002) return errno(22);
    writeMsr(0xc0000100, address);
    return 0;
}

fn brk(requested: u64) u64 {
    if (requested == 0) return program_break;
    if (requested >= user_base + user_size and requested <= break_limit) program_break = requested;
    return program_break;
}

fn mmap(requested: u64, length: u64, protection: u64, flags: u64, fd: u64, file_offset: u64) u64 {
    if (length == 0 or (file_offset & 4095) != 0 or (protection & 2) != 0 and (protection & 4) != 0) return errno(22);
    const anonymous = (flags & 0x20) != 0;
    const framebuffer_device = !anonymous and vfs.isFramebuffer(@intCast(fd));
    const drm_device = !anonymous and vfs.isDrmPrimary(@intCast(fd));
    if (framebuffer_device or drm_device) {
        const drm_object = if (drm_device) drmObjectForMap(file_offset, length) else null;
        if ((flags & 1) == 0 or (protection & 4) != 0 or (drm_device and drm_object == null) or (!drm_device and (file_offset > framebuffer.size or length > framebuffer.size - file_offset))) return errno(22);
        const aligned_length = (length + 4095) & ~@as(u64, 4095);
        const address = if (requested != 0) requested else (device_mmap_next + 4095) & ~@as(u64, 4095);
        if (address < mmap_limit or address > device_mmap_limit or aligned_length > device_mmap_limit - address) return errno(12);
        const hook = device_mmap_hook orelse return errno(19);
        const physical_address = if (drm_object) |object| object.physical_address + (file_offset - object.map_offset) else framebuffer.base + file_offset;
        if (!hook(address, physical_address, aligned_length, (protection & 2) != 0)) return errno(12);
        device_mmap_next = address + aligned_length;
        if (drm_device) drm_mmaps += 1 else framebuffer_mmaps += 1;
        return address;
    }
    if (!anonymous and (flags & 2) == 0) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    const address = if (requested != 0) requested else (mmap_next + 4095) & ~@as(u64, 4095);
    if (address < mmap_next or address > mmap_limit or aligned_length > mmap_limit - address) return errno(12);
    const hook = mmap_protect_hook orelse return errno(12);
    const target: [*]u8 = @ptrFromInt(address);
    @memset(target[0..@intCast(aligned_length)], 0);
    if (!anonymous) {
        const count = vfs.pread(@intCast(fd), target[0..@intCast(length)], @intCast(file_offset)) catch |err| return vfsError(err);
        if (count == 0) return errno(19);
        file_mmaps += 1;
    }
    if (!hook(address, aligned_length, (protection & 2) != 0, (protection & 4) != 0)) return errno(12);
    mmap_next = address + aligned_length;
    return address;
}

fn mprotect(address: u64, length: u64, protection: u64) u64 {
    if ((address & 4095) != 0 or length == 0 or ((protection & 2) != 0 and (protection & 4) != 0)) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    if (!mmapRegion(address, aligned_length)) return errno(12);
    const hook = mmap_protect_hook orelse return errno(12);
    if (!hook(address, aligned_length, (protection & 2) != 0, (protection & 4) != 0)) return errno(12);
    protected_mmaps += 1;
    return 0;
}

fn munmap(address: u64, length: u64) u64 {
    if ((address & 4095) != 0 or length == 0) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    if (!mmapRegion(address, aligned_length)) return errno(22);
    const hook = mmap_unmap_hook orelse return errno(22);
    if (!hook(address, aligned_length)) return errno(22);
    unmapped_mmaps += 1;
    return 0;
}

fn unsupported(number: u64) u64 {
    if (number < unknown_seen.len and !unknown_seen[number]) {
        unknown_seen[number] = true;
        serial.write("unsupported syscall ");
        serial.writeDecimal(number);
        serial.write("\n");
    }
    return errno(38);
}

fn validUserSlice(address: u64, length: u64) bool {
    return inRegion(address, length, user_base, user_size) or
        inRegion(address, length, stack_base, stack_size) or
        inRegion(address, length, user_base + user_size, break_limit - (user_base + user_size)) or
        inRegion(address, length, mmap_base, mmap_limit - mmap_base) or
        inRegion(address, length, mmap_limit, device_mmap_limit - mmap_limit);
}

fn mmapRegion(address: u64, length: u64) bool {
    return inRegion(address, length, mmap_base, mmap_limit - mmap_base) or
        inRegion(address, length, mmap_limit, device_mmap_limit - mmap_limit);
}

fn inRegion(address: u64, length: u64, base: u64, size: u64) bool {
    if (address < base or length > size) return false;
    return address - base <= size - length;
}

fn errno(value: i64) u64 {
    return @bitCast(-value);
}

fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr));
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))));
}
