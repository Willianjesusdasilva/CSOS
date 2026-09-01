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
const DrmObject = struct {
    allocated: bool = false,
    handle_open: bool = false,
    framebuffer_reference: bool = false,
    handle: u32 = 0,
    size: u64 = 0,
    physical_address: u64 = 0,
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
    put32(output + 0, if (drm_driver == .amdgpu) 3 else 1); put32(output + 4, 0); put32(output + 8, 0);
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
    // Until GART/VRAM placement exists, only CPU and page-backed GTT candidates
    // are accepted. Claiming VRAM here would make RADV infer false residency.
    if (domains == 0 or (domains & ~@as(u64, 0x3)) != 0 or (flags & ~@as(u64, 0x5)) != 0) return errno(95);
    var free_index: ?usize = null;
    for (drm_objects, 0..) |object, index| if (!object.allocated) { free_index = index; break; };
    const object_index = free_index orelse return errno(12);
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
    drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = allocation, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride, .alignment = if (alignment == 0) 4096 else alignment, .domains = domains, .allocation_flags = flags };
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
    const list = amdgpuBoListForHandle(read32(io + 4)) orelse return errno(2);
    const chunk_count = read32(io + 8);
    if (chunk_count == 0 or chunk_count > 3 or read32(io + 12) != 0) return errno(95);
    const chunk_pointers_address = read64(io + 16);
    if (!validUserSlice(chunk_pointers_address, @as(u64, chunk_count) * 8)) return errno(14);
    const chunk_pointers: [*]const u8 = @ptrFromInt(chunk_pointers_address);
    var gpu_va: u64 = 0;
    var ib_bytes: u32 = 0;
    var saw_ib = false;
    var saw_sync_in = false;
    var saw_sync_out = false;
    var output_syncobjs: [max_drm_syncobjs]*DrmSyncobj = undefined;
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
        if (chunk_id != 4 and chunk_id != 5) return errno(95);
        if (length_dw == 0 or length_dw > max_drm_syncobjs or !validUserSlice(data_address, @as(u64, length_dw) * 4))
            return errno(22);
        if ((chunk_id == 4 and saw_sync_in) or (chunk_id == 5 and saw_sync_out)) return errno(17);
        if (chunk_id == 4) saw_sync_in = true else saw_sync_out = true;
        const handles: [*]const u8 = @ptrFromInt(data_address);
        var sync_index: usize = 0;
        while (sync_index < length_dw) : (sync_index += 1) {
            const object = drmSyncobjForHandle(read32(handles + sync_index * 4)) orelse return errno(22);
            if (chunk_id == 4) {
                if (object.point == 0) return errno(62);
            } else {
                var prior: usize = 0;
                while (prior < output_count) : (prior += 1) if (output_syncobjs[prior] == object) return errno(17);
                output_syncobjs[output_count] = object;
                output_count += 1;
            }
        }
    }
    if (!saw_ib) return errno(95);
    if (drm_vm_vmid == 0 or !amdgpuBoListCoversGpuVa(list, gpu_va, ib_bytes)) return errno(22);
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
    var output_index: usize = 0;
    while (output_index < output_count) : (output_index += 1) output_syncobjs[output_index].point = 1;
    const output: [*]u8 = @ptrFromInt(address);
    put64(output, handle);
    return 0;
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
        var resident = false;
        var index: usize = 0;
        while (index < list.count) : (index += 1) if (list.handles[index] == mapping.handle) { resident = true; break; };
        if (!resident) return false;
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
    if ((object.domains & 0x2) == 0 or bo_offset > object.size or map_size > object.size - bo_offset) return errno(22);

    if (operation == 1) {
        if (flags == 0 or (flags & ~@as(u32, 0x0e)) != 0) return errno(95);
        _ = ensureAmdGpuVm() catch |err| return amdGpuVmErrno(err);
        var mapped: u64 = 0;
        while (mapped < map_size) : (mapped += 4096) {
            drm_vm_manager.mapSystemPage(drm_vm_vmid, handle, va_address + mapped, bo_offset + mapped, object.size, object.physical_address + bo_offset + mapped, flags) catch |err| {
                var rollback = mapped;
                while (rollback != 0) {
                    rollback -= 4096;
                    drm_vm_manager.unmapSystemPage(drm_vm_vmid, va_address + rollback, object.physical_address + bo_offset + rollback, flags) catch {};
                }
                return amdGpuVmErrno(err);
            };
        }
        syncAmdGpuVmAfterMap() catch |err| {
            var rollback = mapped;
            while (rollback != 0) {
                rollback -= 4096;
                drm_vm_manager.unmapSystemPage(drm_vm_vmid, va_address + rollback, object.physical_address + bo_offset + rollback, flags) catch {};
            }
            if (drm_vm_hardware) |*session| if (session.bound_vmid != 0)
                session.hardware.invalidate(session.hardware.context, drm_vm_vmid) catch {};
            return amdGpuVmErrno(err);
        };
        return 0;
    }
    if (operation != 2 or flags != 0) return errno(95);
    if (drm_vm_vmid == 0) return errno(2);
    var mapping_flags: [32]u32 = .{0} ** 32;
    const page_count = map_size / 4096;
    if (page_count > mapping_flags.len) return errno(28);
    var checked: u64 = 0;
    while (checked < map_size) : (checked += 4096) {
        mapping_flags[@intCast(checked / 4096)] = drm_vm_manager.validateSystemPageMapping(drm_vm_vmid, handle, va_address + checked, bo_offset + checked,
            object.physical_address + bo_offset + checked) catch |err| return amdGpuVmErrno(err);
    }
    var unmapped: u64 = 0;
    while (unmapped < map_size) : (unmapped += 4096) {
        const page_flags = mapping_flags[@intCast(unmapped / 4096)];
        drm_vm_manager.unmapSystemPage(drm_vm_vmid, va_address + unmapped, object.physical_address + bo_offset + unmapped, page_flags) catch |err|
            return amdGpuVmErrno(err);
    }
    syncAmdGpuVmAfterUnmap() catch |err| {
        var restore: u64 = 0;
        while (restore < unmapped) : (restore += 4096) drm_vm_manager.mapSystemPage(
            drm_vm_vmid, handle, va_address + restore, bo_offset + restore, object.size,
            object.physical_address + bo_offset + restore, mapping_flags[@intCast(restore / 4096)],
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
    if (query != 0) return errno(22);
    const count = @min(return_size, 4);
    if (!validUserSlice(return_address, count)) return errno(14);
    const output: [*]u8 = @ptrFromInt(return_address);
    // AMDGPU_INFO_ACCEL_WORKING remains false until firmware, GART and a
    // command ring have all been initialized and verified on the device.
    @memset(output[0..count], 0);
    return 0;
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
        if (drm_pages) |pages| pages.release(object.physical_address, object.pages) catch {};
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
        drm_vm_manager.unmapSystemPage(drm_vm_vmid, mapping.address, bo.physical_address + mapping.bo_offset, mapping.flags) catch break;
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
        if (object.allocated and offset >= object.map_offset and offset - object.map_offset <= object.size and length <= object.size - (offset - object.map_offset)) return object;
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
