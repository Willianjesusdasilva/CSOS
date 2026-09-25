const std = @import("std");
const serial = @import("serial");
const vfs = @import("vfs");
const net = @import("net");
const physical = @import("physical");
const gpu = @import("gpu");
const ui_ipc = @import("ui_ipc");

var user_base: u64 = 0;
var user_size: u64 = 0;
var stack_base: u64 = 0;
var stack_size: u64 = 0;
var program_break: u64 = 0;
var break_limit: u64 = 0;
var mmap_next: u64 = 0;
var noreserve_next: u64 = 0;
var mmap_base: u64 = 0;
var mmap_limit: u64 = 0;
var device_mmap_next: u64 = 0;
var device_mmap_limit: u64 = 0;
var writes: usize = 0;
var process_exit_status: u64 = 0;
var process_pause: ?Pause = null;
export var exec_pause_requested: bool = false;
var mmap_protect_hook: ?*const fn (u64, u64, bool, bool) callconv(.c) bool = null;
var mmap_unmap_hook: ?*const fn (u64, u64) callconv(.c) bool = null;
var mmap_reset_hook: ?*const fn (u64, u64) callconv(.c) bool = null;
var device_mmap_hook: ?*const fn (u64, u64, u64, bool) callconv(.c) bool = null;
var user_slice_hook: ?*const fn (u64, u64) callconv(.c) bool = null;
var execve_hook: ?*const fn (u64, u64, u64) callconv(.c) u64 = null;
var stdin_hook: ?*const fn ([*]u8, usize) callconv(.c) usize = null;
pub var console_write_hook: ?*const fn ([]const u8) void = null;
var idle_hook: ?*const fn () callconv(.c) void = null;
var initializer_step_hook: ?*const fn (u64) callconv(.c) void = null;
var robust_head: u64 = 0;
var robust_len: u64 = 0;
var clear_tid_address: u64 = 0;
var process_umask: u32 = 0o022;
var limit_stack: u64 = 128 * 1024;
var limit_address_space: u64 = 256 * 1024 * 1024;
var limit_nofile: u64 = 32;
var hard_limit_stack: u64 = 128 * 1024;
var hard_limit_address_space: u64 = 256 * 1024 * 1024;
var hard_limit_nofile: u64 = 32;
var process_name: [16]u8 = .{ 'c', 's', 'o', 's', 0 } ++ .{0} ** 11;
var process_group: u64 = 1;
var process_session: u64 = 1;
var process_nice: i32 = 0;
var signal_stack: [32]u8 = .{0} ** 32;
var random_state: u64 = 0x9e3779b97f4a7c15;
var ui_mailboxes: [8]ui_ipc.Mailbox = undefined;
var ui_mailbox_used: [8]bool = .{false} ** 8;
pub var ui_send_count: u64 = 0;
var monotonic_time_ns: u64 = 0;
const max_epoll_watch = 16;
const EpollWatch = struct { fd: u32 = 0, generation: u32 = 0, events: u32 = 0, data: u64 = 0, active: bool = false };
var epoll_watches: [32][max_epoll_watch]EpollWatch = .{.{EpollWatch{}} ** max_epoll_watch} ** 32;
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

fn saturatingCount(value: u64, increment: u64) u64 {
    return std.math.add(u64, value, increment) catch std.math.maxInt(u64);
}

fn pageCountForBytes(size: u64) !u64 {
    return (try std.math.add(u64, size, 4095)) / 4096;
}

fn bytesForPages(pages: u64) !u64 {
    return std.math.mul(u64, pages, 4096);
}

test "DRM page count rounds and rejects overflow" {
    try std.testing.expectEqual(@as(u64, 1), try pageCountForBytes(1));
    try std.testing.expectEqual(@as(u64, 2), try pageCountForBytes(4097));
    try std.testing.expectError(error.Overflow, pageCountForBytes(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 8192), try bytesForPages(2));
    try std.testing.expectError(error.Overflow, bytesForPages(std.math.maxInt(u64)));
}
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
    submit: *const fn (*anyopaque, u4, []const gpu.AmdGfx11IndirectBuffer) anyerror!u64,
    // Absent for preparatory/test endpoints. Production installs this only
    // after the physical PM4 test; it must track runtime loss of the queue.
    acceleration_ready: ?*const fn (*anyopaque) bool = null,
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
    gb_addr_config: u32,
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
fn amdgpuAbiTestSubmit(_: *anyopaque, vmid: u4, ibs: []const gpu.AmdGfx11IndirectBuffer) !u64 {
    if (vmid != 1 or ibs.len == 0 or ibs.len > 2) return error.InvalidAmdGpuAbiTestSubmission;
    for (ibs, 0..) |ib, index| if (ib.address != 0x4000 + index * 16 or ib.dwords != 4)
        return error.InvalidAmdGpuAbiTestSubmission;
    if (amdgpu_abi_test_dispatches != std.math.maxInt(u32)) amdgpu_abi_test_dispatches += 1;
    return 0x100 + amdgpu_abi_test_dispatches;
}

fn amdgpuAbiTestAccelerationReady(raw: *anyopaque) bool {
    const ready: *const u8 = @ptrCast(raw);
    return ready.* != 0;
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
const socket_fd_base: u64 = 256;
var sockets: [32]Socket = .{Socket{}} ** 32;
// Linux signal numbers are 1..64; keep slot zero unused for the ABI check.
var signal_actions: [65][32]u8 = .{.{0} ** 32} ** 65;
var unknown_seen: [512]bool = .{false} ** 512;
pub export var syscall_kernel_rsp: u64 = 0;
pub export var syscall_user_rsp: u64 = 0;
pub export var user_threads_enabled: bool = false;
pub export var user_threads_done: bool = false;

fn captureRawSyscallFrame(raw: *const [14]u64) [14]u64 {
    return .{ raw[13], raw[12], raw[11], raw[10], raw[9], raw[8], raw[7],
        raw[6], raw[5], raw[4], raw[3], raw[2], raw[1], raw[0] };
}

fn restoreRawSyscallFrame(raw: *[14]u64, frame: [14]u64) void {
    raw[13] = frame[0];
    raw[12] = frame[1];
    raw[11] = frame[2];
    raw[10] = frame[3];
    raw[9] = frame[4];
    raw[8] = frame[5];
    raw[7] = frame[6];
    raw[6] = frame[7];
    raw[5] = frame[8];
    raw[4] = frame[9];
    raw[3] = frame[10];
    raw[2] = frame[11];
    raw[1] = frame[12];
    raw[0] = frame[13];
}
const SocketFdAlias = struct {
    fd: u32 = 0,
    socket_index: u8 = 0,
    close_on_exec: bool = false,
    used: bool = false,
};
const UserThread = struct {
    state: enum { unused, runnable, blocked, exited } = .unused,
    kind: enum { thread, process_child } = .thread,
    vfork_child: bool = false,
    pid: u32 = 0,
    exit_status: u64 = 0,
    wait_child_pid: u64 = 0,
    wait_status: u64 = 0,
    // syscall_entry.S saves rcx, r11 and thirteen general registers before
    // returning with sysretq; retain the complete fifteen-word frame when
    // switching user threads.
    frame: [14]u64 = @splat(0),
    rsp: u64 = 0, result: u64 = 0, fs: u64 = 0,
    // Separate iretq state from the syscall/sysret frame above. Layout:
    // RIP, RFLAGS, RSP, then RAX..R15 in architectural register order.
    timer_frame: [18]u64 = .{0} ** 18,
    timer_valid: bool = false,
    workspace_id: u8 = 0,
    parent_slot: usize = 0,
    clear_tid: u64 = 0, wait_address: u64 = 0,
    child_tid_published: bool = false,
    child_tid_set: bool = false,
    wait_workspace: u8 = 0, wait_private: bool = false,
    pending_read_socket: ?usize = null,
    pending_read_address: u64 = 0,
    pending_read_length: usize = 0,
    pending_read_eof: bool = false,
    pending_write_socket: ?usize = null,
    pending_write_address: u64 = 0,
    pending_write_length: usize = 0,
    pending_poll_address: u64 = 0,
    pending_poll_count: u64 = 0,
    pending_poll_sockets: [32]bool = .{false} ** 32,
    pending_wait_status: ?u8 = null,
    pending_wait_address: u64 = 0,
    stdio_sockets: [3]?usize = .{ null, null, null },
    stdio_cloexec: [3]bool = .{ false, false, false },
    direct_socket_refs: [32]bool = .{false} ** 32,
    direct_socket_cloexec: [32]bool = .{false} ** 32,
    socket_fd_map: [32]?usize = .{null} ** 32,
    owned_socket_refs: [32]bool = .{false} ** 32,
    socket_fd_aliases: [16]SocketFdAlias = .{SocketFdAlias{}} ** 16,
    cwd: [256]u8 = .{0} ** 256,
    cwd_len: usize = 1,
    robust: u64 = 0, robust_size: u64 = 0,
    rseq_address: u64 = 0,
    exec_request: ?ExecRequest = null,
    fx: [512]u8 align(16) = @splat(0),
};
var user_threads: [16]UserThread = @splat(.{});
// Descriptor identity belongs to the process workspace, not to whichever
// scheduler thread happens to perform the syscall.  The per-thread arrays
// remain as a compatibility cache for existing code, while these tables are
// the authoritative inherited descriptor view.
var workspace_socket_refs: [16][32]bool = .{.{false} ** 32} ** 16;
var workspace_socket_cloexec: [16][32]bool = .{.{false} ** 32} ** 16;
// Real descriptor references owned by each workspace. Publication booleans
// cannot represent multiple stdio/dup aliases inherited across fork.
var workspace_socket_ref_counts: [16][32]u16 = .{.{0} ** 32} ** 16;
var workspace_stdio_sockets: [16][3]?usize = [_][3]?usize{.{null, null, null}} ** 16;
var workspace_stdio_cloexec: [16][3]bool = [_][3]bool{.{false, false, false}} ** 16;
var workspace_fd_aliases: [16][16]SocketFdAlias = [_][16]SocketFdAlias{.{SocketFdAlias{}} ** 16} ** 16;
var workspace_socket_fd_map: [16][32]?usize = .{.{null} ** 32} ** 16;
// Total aliases (high descriptors plus stdin/stdout/stderr) owned by each
// process workspace. The boolean table above only describes high fds; this
// ledger is the refcount source used by fork/close/exec.
var workspace_socket_aliases: [16][32]u8 = .{.{0} ** 32} ** 16;
var workspace_done: [16]bool = .{false} ** 16;
var workspace_exit_status: [16]u8 = .{0} ** 16;
var top_level_workspace: u8 = 0xff;
var current_thread: usize = 0;
var current_pid: u32 = 1;
var pending_clone: ?struct { slot: usize, stack: u64, tls: u64, process_child: bool, entry: u64, clone_child: bool } = null;
// Process children may be forked in bursts (for example receive-pack starts
// several Git helpers before the parent blocks). Keep every deferred child;
// a single slot loses siblings and can starve one of the helpers forever.
var deferred_process_children: u16 = 0;
// Threads created by pthread/clone must get one scheduling turn before the
// creating process can continue a protocol that depends on their pipe work.
// Keep this separate from process children: the latter are deferred until a
// parent blocks, while a new helper thread is part of the same workspace.
var deferred_user_threads: u16 = 0;
var active_user_thread: ?usize = null;
var released_vfork_parent: ?usize = null;
// A pthread clone is created while the caller still owns musl's thread-list
// lock.  Let the caller return through one syscall boundary before selecting
// the new thread, otherwise the child can enter pthread bookkeeping too early
// and spin on a lock that the parent has not released yet.
var defer_user_thread_switch: bool = false;
var thread_switch_requested: bool = false;
var workspace_clone_hook: ?*const fn (u8, u32) callconv(.c) u16 = null;
var workspace_activate_hook: ?*const fn (u8) callconv(.c) void = null;
var interrupt_reload_hook: ?*const fn () void = null;
var workspace_release_hook: ?*const fn (u8) callconv(.c) void = null;

fn workspaceHasBlockedThread(workspace: u8) bool {
    for (user_threads) |thread| {
        if (thread.workspace_id == workspace and thread.state == .blocked) return true;
    }
    return false;
}
pub var process_clone_hint_address: u64 = 0;
// Set only while the workspace clone hook services CLONE_VFORK. The vfork
// child shares the parent's address space until execve/_exit, so copying the
// entire anonymous arena here is both unnecessary and contrary to Linux
// semantics.
pub var process_clone_vfork: bool = false;
const max_exec_arguments = 32;
const max_exec_string = 256;
pub const ExecRequest = struct {
    path: [max_exec_string]u8 = .{0} ** max_exec_string,
    path_len: usize = 0,
    argv: [max_exec_arguments][max_exec_string]u8 = .{.{0} ** max_exec_string} ** max_exec_arguments,
    argv_lengths: [max_exec_arguments]u16 = .{0} ** max_exec_arguments,
    argc: usize = 0,
    envp: [max_exec_arguments][max_exec_string]u8 = .{.{0} ** max_exec_string} ** max_exec_arguments,
    envp_lengths: [max_exec_arguments]u16 = .{0} ** max_exec_arguments,
    envc: usize = 0,
};
pub const ExecRequestEnvelope = struct {
    thread_id: u32,
    workspace_id: u8,
    request: ExecRequest,
};
pub var user_futex_blocks: u64 = 0;
pub var user_futex_wakes: u64 = 0;

fn wakeUserThreads(address: u64, maximum: u64, workspace: ?u8, private: bool) u64 {
    var count: u64 = 0;
    for (&user_threads) |*thread| {
        if (count == maximum) break;
        if (thread.state == .blocked and thread.wait_address == address and
            thread.wait_private == private and
            (!private or (workspace != null and thread.wait_workspace == workspace.?))) {
            thread.state = .runnable;
            thread.result = 0;
            thread.wait_address = 0;
            thread_switch_requested = true;
            user_futex_wakes += 1;
            count += 1;
        }
    }
    if (deferred_user_threads != 0 and active_user_thread == current_thread) {
        active_user_thread = null;
        defer_user_thread_switch = false;
        thread_switch_requested = true;
    }
    return count;
}

fn markRobustFutexOwnerDied(address: u64, workspace: u8, pid: u32) void {
    if (!validUserSlice(address, 4)) return;
    const word: *align(1) volatile u32 = @ptrFromInt(address);
    const owner = word.*;
    if ((owner & 0x3fff_ffff) != (pid & 0x3fff_ffff)) return;
    word.* = owner | 0x4000_0000;
    for (&user_threads) |*waiter| {
        if (waiter.workspace_id != workspace or waiter.state != .blocked or
            waiter.wait_address != address) continue;
        waiter.state = .runnable;
        waiter.wait_address = 0;
        waiter.result = 0;
        thread_switch_requested = true;
        user_futex_wakes += 1;
    }
}

fn releaseRobustList(thread: *const UserThread) void {
    const head = thread.robust;
    if (head == 0 or thread.robust_size != 24 or !validUserSlice(head, 24)) return;
    const next_ptr: *align(1) const u64 = @ptrFromInt(head);
    const offset_ptr: *align(1) const i64 = @ptrFromInt(head + 8);
    const pending_ptr: *align(1) const u64 = @ptrFromInt(head + 16);
    const offset = offset_ptr.*;
    var node = next_ptr.*;
    var count: usize = 0;
    while (node != 0 and node != head and count < 128) : (count += 1) {
        if (!validUserSlice(node, 8)) break;
        const node_next: *align(1) const u64 = @ptrFromInt(node);
        const robust_futex = if (offset >= 0)
            (std.math.add(u64, node, @intCast(offset)) catch break)
        else blk: {
            const distance: u64 = @intCast(-offset);
            break :blk if (node < distance) break else node - distance;
        };
        markRobustFutexOwnerDied(robust_futex, thread.workspace_id, thread.pid);
        node = node_next.*;
    }
    const pending = pending_ptr.*;
    if (pending != 0 and validUserSlice(pending, 8)) {
        const robust_futex = if (offset >= 0)
            (std.math.add(u64, pending, @intCast(offset)) catch 0)
        else blk: {
            const distance: u64 = @intCast(-offset);
            break :blk if (pending < distance) 0 else pending - distance;
        };
        if (robust_futex != 0) markRobustFutexOwnerDied(robust_futex, thread.workspace_id, thread.pid);
    }
}

/// A userspace thread may terminate while holding a futex-backed runtime lock.
/// Linux's robust-thread machinery normally repairs those locks; the compact
/// CSOS scheduler has no asynchronous signal/reaper path, so perform the same
/// ownership handoff at the exit boundary.  Only wake waiters in the exiting
/// thread's workspace, and only when the futex word explicitly names that
/// thread as its owner.  Unrelated futexes and other workspaces are untouched.
fn releaseOwnedFutexesOnExit(thread: *const UserThread) void {
    releaseRobustList(thread);
    for (&user_threads) |*waiter| {
        if (waiter.workspace_id != thread.workspace_id or waiter.state != .blocked or
            waiter.wait_address == 0 or !validUserSlice(waiter.wait_address, 4)) continue;
        const word: *align(1) volatile u32 = @ptrFromInt(waiter.wait_address);
        if (word.* != @as(u32, @intCast(thread.pid))) continue;
        word.* = 0;
        waiter.state = .runnable;
        waiter.wait_address = 0;
        waiter.result = 0;
        thread_switch_requested = true;
        user_futex_wakes += 1;
    }
}

// Linux x86-64 clone(2) arguments are flags, child_stack, parent_tid,
// child_tid, tls. Keep this order explicit: swapping tls/ctid makes a new
// pthread inherit the child-tid address as FS and hang before its first
// userspace syscall.
fn cloneThread(flags: u64, stack: u64, parent_tid: u64, child_tid: u64, tls: u64, clone_entry: u64) u64 {
    // musl pthread_create flags, plus the Linux fork form (SIGCHLD) used by
    // Git and other runtimes to create a process child before execve.
    const is_clone_child = flags == 0x4111;
    const is_process_child = flags == 17 or is_clone_child;
    if (flags != 0x7d0f00 and !is_process_child) return errno(22);
    if (flags == 17) {
        if (stack != 0 or parent_tid != 0 or child_tid != 0 or tls != 0) return errno(22);
    } else if (is_clone_child) {
        // musl's x86-64 __clone aligns RSI and subtracts eight before the
        // syscall, leaving the callback argument at the kernel-visible
        // stack value itself.
        if (clone_entry == 0 or !validUserSlice(stack, 8)) return errno(14);
        process_clone_hint_address = read64(@as([*]const u8, @ptrFromInt(stack)));
    } else if (stack < 8 or !validUserSlice(stack, 8) or !validUserSlice(tls, 8) or
        !validUserSlice(parent_tid, 4) or !validUserSlice(child_tid, 4)) return errno(14);
    for (1..user_threads.len) |slot| {
        if (user_threads[slot].state != .unused and
            !(user_threads[slot].state == .exited and user_threads[slot].kind == .thread)) continue;
        user_threads[slot] = .{ .state = .runnable, .kind = if (is_process_child) .process_child else .thread,
            .vfork_child = is_clone_child,
            .child_tid_set = (flags & 0x01000000) != 0,
            .pid = @intCast(slot + 1), .clear_tid = child_tid,
            .parent_slot = current_thread,
            .workspace_id = user_threads[current_thread].workspace_id };
        user_threads[slot].stdio_sockets = user_threads[current_thread].stdio_sockets;
        user_threads[slot].stdio_cloexec = user_threads[current_thread].stdio_cloexec;
        // Threads share the process descriptor table.  A fork/clone may be
        // issued by a thread whose local snapshot predates a pipe-to-stdio
        // dup performed by a sibling, so merge the workspace's STDIO view
        // before copying it into the new thread/process.
        for (user_threads, 0..) |peer, peer_index| {
            if (peer_index == current_thread or peer.workspace_id != user_threads[current_thread].workspace_id) continue;
            for (peer.stdio_sockets, 0..) |entry, fd| {
                if (user_threads[slot].stdio_sockets[fd] == null and entry != null) {
                    user_threads[slot].stdio_sockets[fd] = entry;
                    user_threads[slot].stdio_cloexec[fd] = peer.stdio_cloexec[fd];
                }
            }
        }
        user_threads[slot].direct_socket_refs = user_threads[current_thread].direct_socket_refs;
        user_threads[slot].direct_socket_cloexec = user_threads[current_thread].direct_socket_cloexec;
        user_threads[slot].socket_fd_map = user_threads[current_thread].socket_fd_map;
        // Descriptor aliases are part of the process descriptor view too.
        // Threads share them directly; a forked process receives a copied
        // view below while its workspace reference ledger is cloned.
        user_threads[slot].socket_fd_aliases = user_threads[current_thread].socket_fd_aliases;
        user_threads[slot].cwd = user_threads[current_thread].cwd;
        user_threads[slot].cwd_len = user_threads[current_thread].cwd_len;
        if (is_process_child) {
            // The Linux cwd belongs to the process, while the cooperative
            // scheduler stores a copy on each thread.  A fork can be issued
            // by a sibling created by run-command; merge the workspace's
            // newest non-root cwd before cloning the process workspace.
            for (user_threads) |peer| {
                if (peer.workspace_id != user_threads[current_thread].workspace_id) continue;
                if (peer.cwd_len > user_threads[slot].cwd_len or
                    (user_threads[slot].cwd_len == 1 and peer.cwd_len > 1)) {
                    user_threads[slot].cwd = peer.cwd;
                    user_threads[slot].cwd_len = peer.cwd_len;
                }
            }
        }
        if (is_process_child) {
            // Linux threads in one process share the descriptor table.  A
            // fork may therefore be issued by a thread other than the one
            // that created a pipe/socket; merge the workspace's direct fd
            // view before creating the child's private workspace.
            for (user_threads, 0..) |peer, peer_index| {
                if (peer_index == current_thread or peer.workspace_id != user_threads[current_thread].workspace_id) continue;
                for (peer.direct_socket_refs, 0..) |present, socket_index| {
                    if (present) {
                        user_threads[slot].direct_socket_refs[socket_index] = true;
                        user_threads[slot].direct_socket_cloexec[socket_index] = peer.direct_socket_cloexec[socket_index];
                    }
                }
                // Consolidate the complete descriptor identity, not only
                // the presence bit. A sibling may have performed socket()
                // or dup2() after the caller's local snapshot was taken.
                for (peer.socket_fd_map, 0..) |mapped, fd_slot| {
                    if (mapped != null)
                        user_threads[slot].socket_fd_map[fd_slot] = mapped;
                }
                for (peer.socket_fd_aliases) |peer_alias| {
                    if (!peer_alias.used) continue;
                    var already_present = false;
                    for (user_threads[slot].socket_fd_aliases) |child_alias| {
                        if (child_alias.used and child_alias.fd == peer_alias.fd and
                            child_alias.socket_index == peer_alias.socket_index) {
                            already_present = true;
                            break;
                        }
                    }
                    if (already_present) continue;
                    for (&user_threads[slot].socket_fd_aliases) |*child_alias| {
                        if (!child_alias.used) {
                            child_alias.* = peer_alias;
                            break;
                        }
                    }
                }
            }
            // A fork duplicates only descriptors visible in the process
            // table.  Incrementing every allocated socket kept unrelated
            // pipe endpoints alive and prevented the peer from observing
            // EOF when a nested helper exited.
            for (&sockets, 0..) |*socket_entry, index| {
                if (!socket_entry.allocated) continue;
                // `direct_socket_refs` represents the high descriptor
                // namespace, while stdio has three independent aliases.
                // Count every inherited alias: dup2() commonly leaves the
                // original CLOEXEC fd alongside a non-CLOEXEC stdio fd.
                const parent_workspace = user_threads[current_thread].workspace_id;
                const inherited_refs: u16 = workspace_socket_ref_counts[parent_workspace][index];
                if (inherited_refs != 0) {
                    socket_entry.refs += inherited_refs;
                    // The child cleanup has separate paths for stdio aliases
                    // and high descriptors. Do not invent a direct ownership
                    // reference when the inherited table contains only
                    // stdin/stdout/stderr aliases.
                    user_threads[slot].owned_socket_refs[index] = user_threads[slot].direct_socket_refs[index];
                }
            }
        }
        const tid: u32 = @intCast(slot + 1);
        // parent_tid is an output only when CLONE_PARENT_SETTID is present.
        // Some vfork-style callers pass a scratch value in this argument even
        // though flags 0x4111 do not request the parent-TID write.
        if ((flags & 0x00100000) != 0 and parent_tid != 0) {
            const out: *align(1) u32 = @ptrFromInt(parent_tid); out.* = tid;
        }
        if (!user_threads_enabled) {
            user_threads[0].state = .runnable;
            user_threads[0].clear_tid = clear_tid_address;
        }
        user_threads_enabled = true;
        if (is_process_child) {
            if (workspace_clone_hook) |hook| {
                process_clone_vfork = is_clone_child;
                const child_workspace = hook(user_threads[current_thread].workspace_id, @intCast(slot));
                process_clone_vfork = false;
                if (child_workspace == 0xffff) {
                    user_threads[slot] = .{};
                    process_clone_hint_address = 0;
                    return errno(12);
                }
                user_threads[slot].workspace_id = @intCast(child_workspace);
                workspace_socket_refs[child_workspace] = workspace_socket_refs[user_threads[current_thread].workspace_id];
                workspace_socket_cloexec[child_workspace] = workspace_socket_cloexec[user_threads[current_thread].workspace_id];
                workspace_socket_ref_counts[child_workspace] = workspace_socket_ref_counts[user_threads[current_thread].workspace_id];
                workspace_stdio_sockets[child_workspace] = workspace_stdio_sockets[user_threads[current_thread].workspace_id];
                workspace_stdio_cloexec[child_workspace] = workspace_stdio_cloexec[user_threads[current_thread].workspace_id];
                workspace_fd_aliases[child_workspace] = workspace_fd_aliases[user_threads[current_thread].workspace_id];
                workspace_socket_fd_map[child_workspace] = workspace_socket_fd_map[user_threads[current_thread].workspace_id];
                workspace_socket_aliases[child_workspace] = workspace_socket_aliases[user_threads[current_thread].workspace_id];
                workspace_done[child_workspace] = false;
                workspace_exit_status[child_workspace] = 0;
            }
            process_clone_hint_address = 0;
        }
    pending_clone = .{ .slot = slot, .stack = stack, .tls = tls, .process_child = is_process_child,
            .entry = clone_entry, .clone_child = is_clone_child };
        // A fork child must not run while the parent still holds musl's
        // fork/loader lock. Let the parent return from clone and complete a
        // short syscall window first; a later boundary performs the switch.
        thread_switch_requested = !is_process_child;
        return tid;
    }
    return errno(11);
}

// Called while still on the syscall stack. Save the complete SYSRET frame;
// cooperative scheduling switches only at yield, blocking wait and exit.
export fn user_thread_resume(frame: *[14]u64, result: u64) callconv(.c) u64 {
    if (!user_threads_enabled) return result;
    const old = &user_threads[current_thread];
    old.frame = captureRawSyscallFrame(frame); old.rsp = syscall_user_rsp; old.result = result;
    old.timer_valid = false;
    old.timer_frame[0] = old.frame[0];
    old.timer_frame[1] = old.frame[1];
    old.timer_frame[2] = old.rsp;
    old.timer_frame[3] = result;
    old.timer_frame[4] = old.frame[0];
    old.timer_frame[5] = old.frame[13];
    old.timer_frame[6] = old.frame[12];
    old.timer_frame[7] = old.frame[11];
    old.timer_frame[8] = old.frame[10];
    old.timer_frame[9] = old.frame[9];
    old.timer_frame[10] = old.frame[8];
    old.timer_frame[11] = old.frame[7];
    old.timer_frame[12] = old.frame[6];
    old.timer_frame[13] = old.frame[1];
    old.timer_frame[14] = old.frame[5];
    old.timer_frame[15] = old.frame[4];
    old.timer_frame[16] = old.frame[3];
    old.timer_frame[17] = old.frame[2];
    old.fs = readMsr(0xc0000100);
    asm volatile ("fxsave64 (%[p])" : : [p] "r" (&old.fx) : .{ .memory = true });
    if (active_user_thread) |slot| {
        if (slot == current_thread and old.state != .runnable) active_user_thread = null;
    }
    if (defer_user_thread_switch and pending_clone == null and deferred_user_threads == 0) {
        defer_user_thread_switch = false;
        thread_switch_requested = true;
    }
    if (old.exec_request != null) exec_pause_requested = true;
    var created_process_child = false;
    var immediate_vfork_child: ?usize = null;
    if (pending_clone) |child| {
        user_threads[child.slot].frame = captureRawSyscallFrame(frame);
        if (child.clone_child) {
            // Resume at musl's instruction immediately after SYS_clone.  Its
            // continuation pops the callback argument, calls R9, and issues
            // exit when the callback returns. Jumping directly to R9 leaves
            // the argument as the return address (RIP=10/9).
            // captureRawSyscallFrame normalizes the interrupt frame into the
            // SYSRET register order (RIP, RFLAGS, R15...R9...).  Therefore
            // frame[7] is R9 and frame[11] is RBP; these are the registers
            // consumed by musl's clone continuation (`call *%r9` after it
            // clears EBP).
            user_threads[child.slot].frame[7] = child.entry; // R9 callback
            user_threads[child.slot].frame[11] = 0; // clear RBP as musl does
            user_threads[child.slot].rsp = child.stack;
        } else if (child.process_child) {
            // Plain fork (SIGCHLD) returns through the saved syscall frame;
            // it has no callback stack and therefore needs no adjustment.
            user_threads[child.slot].rsp = old.rsp;
        } else {
            // pthread clone uses the same musl continuation as vfork.
            user_threads[child.slot].frame[7] = child.entry;
            user_threads[child.slot].frame[11] = 0;
            user_threads[child.slot].rsp = child.stack;
        }
        user_threads[child.slot].fs = if (child.process_child) old.fs else child.tls;
        user_threads[child.slot].fx = old.fx;
        // clone returns the child TID only to the caller in the parent.  The
        // new thread/process observes the Linux child return value zero.
        user_threads[child.slot].result = 0;
        pending_clone = null;
        if (child.process_child) {
            deferred_process_children |= @as(u16, 1) << @intCast(child.slot);
            created_process_child = true;
            if (child.clone_child) {
                // CLONE_VFORK suspends the caller until the callback has
                // either exec'd or exited.  Keep the child as the active
                // task; leaving the parent in active_user_thread would make
                // the scheduler select it repeatedly and starve the vfork
                // child before it can reach execve.
                active_user_thread = child.slot;
                defer_user_thread_switch = false;
                thread_switch_requested = true;
                immediate_vfork_child = child.slot;
            } else {
                // Keep the forking thread on CPU through its post-fork
                // cleanup (close inherited pipe ends, then publish the
                // notify read). A sibling may already be blocked on a shared
                // descriptor; if the child runs first it can consume bytes
                // from the parent's still-open endpoint and truncate the
                // second transport pipe.
                active_user_thread = current_thread;
                defer_user_thread_switch = true;
                thread_switch_requested = false;
            }
        } else {
            deferred_user_threads |= @as(u16, 1) << @intCast(child.slot);
            active_user_thread = current_thread;
            defer_user_thread_switch = true;
        }
    }
    if (!created_process_child and deferred_process_children != 0 and old.state == .runnable) {
        thread_switch_requested = true;
    }
    if (user_threads_done) return result;
    if (thread_switch_requested or old.state != .runnable) {
        thread_switch_requested = false;
        var selected: ?usize = null;
        const current_workspace = user_threads[current_thread].workspace_id;
        if (immediate_vfork_child) |slot| {
            // A vfork child must run before unrelated waiters. Its parent is
            // suspended by contract until this child reaches execve/_exit.
            if (slot < user_threads.len and user_threads[slot].state == .runnable) {
                selected = slot;
                deferred_process_children &= ~(@as(u16, 1) << @intCast(slot));
            }
        } else if (old.exec_request != null and old.state == .runnable) {
            // execve must be consumed by the loader while this thread's
            // address space is still active; switching to the parent first
            // would make the pending request run with the wrong CR3.
            selected = current_thread;
        } else {
            // A child-exit wakeup carries a pending wait status and must take
            // precedence over unrelated deferred helpers.  Otherwise a busy
            // receive-pack workspace can repeatedly schedule transport
            // children while the parent remains runnable but never resumes
            // the saved wait4 frame.
            for (0..user_threads.len) |waiter_slot| {
                if (user_threads[waiter_slot].state == .runnable and
                    user_threads[waiter_slot].workspace_id == current_workspace and
                    user_threads[waiter_slot].pending_wait_status != null) {
                    selected = waiter_slot;
                    break;
                }
            }
            if (selected != null) {
                // Skip deferred-child selection below; the waiter owns the
                // next syscall-return boundary and completes its status when
                // activated.
            } else {
            if (released_vfork_parent) |parent_slot| {
                if (parent_slot < user_threads.len and user_threads[parent_slot].state == .runnable) {
                    selected = parent_slot;
                }
                released_vfork_parent = null;
            }
            if (selected != null) {
                // Successful vfork exec has an explicit wake target. Resume
                // the launcher before allowing the child to create workers.
            } else {
            // Keep a freshly-created pthread on the CPU until it reaches its
            // first blocking boundary.  The parent may already be waiting on
            // the pipe it owns, and selecting that waiter after one signal
            // mask syscall would recreate the starvation race.
            if (deferred_user_threads == 0) {
                if (active_user_thread) |thread_slot| {
                    if (user_threads[thread_slot].state == .runnable) {
                        selected = thread_slot;
                    } else {
                        active_user_thread = null;
                    }
                }
            }
            }
            if (selected != null) {
                // The new helper remains preferred until it blocks/exits.
            } else {
            // A socket/poll wakeup carries a saved userspace frame that must
            // consume the newly available bytes before another runnable
            // workspace can spin.  Prioritize these I/O waiters just like
            // wait4 waiters; otherwise a receive-pack pipe can be woken yet
            // never resume its pending read.
            for (0..user_threads.len) |io_slot| {
                const io_thread = &user_threads[io_slot];
                if (io_thread.state == .runnable and
                    io_thread.workspace_id == current_workspace and
                    (io_thread.pending_read_socket != null or
                        io_thread.pending_write_socket != null or
                        io_thread.pending_poll_address != 0)) {
                    selected = io_slot;
                    break;
                }
            }
            if (selected != null) {
                // The I/O waiter owns the next boundary.
            } else {
            // A newly-created pthread commonly owns the other end of a pipe
            // or socket needed by the caller.  Give it a first turn before
            // round-robin can repeatedly select an unrelated runnable image.
            for (0..user_threads.len) |thread_slot| {
                if ((deferred_user_threads & (@as(u16, 1) << @intCast(thread_slot))) == 0) continue;
                if (user_threads[thread_slot].state != .runnable) {
                    deferred_user_threads &= ~(@as(u16, 1) << @intCast(thread_slot));
                    continue;
                }
                if (user_threads[thread_slot].kind != .thread or
                    user_threads[thread_slot].workspace_id != current_workspace or
                    thread_slot == current_thread) continue;
                selected = thread_slot;
                deferred_user_threads &= ~(@as(u16, 1) << @intCast(thread_slot));
                active_user_thread = thread_slot;
                defer_user_thread_switch = false;
                break;
            }
            if (selected != null) {
                // The freshly-created helper owns the next boundary.
            } else {
            // Once the parent has blocked (read/wait/poll), run its newly
            // forked process child before unrelated runnable threads.  Keep
            // the deferred marker until that point so an older sibling can
            // finish its pipe work first.
            for (0..user_threads.len) |child_slot| {
                if ((deferred_process_children & (@as(u16, 1) << @intCast(child_slot))) == 0) continue;
                const parent_slot = user_threads[child_slot].parent_slot;
                // A forked process owns a distinct workspace descriptor
                // table.  The parent slot is the ownership relation; the
                // workspace ids must intentionally differ here.
                if (parent_slot >= user_threads.len)
                    continue;
                if (user_threads[child_slot].state == .runnable and
                    (user_threads[parent_slot].state != .runnable or
                        workspaceHasBlockedThread(user_threads[parent_slot].workspace_id) or
                        user_threads[parent_slot].kind == .process_child or
                        user_threads[child_slot].vfork_child)) {
                    selected = child_slot;
                    deferred_process_children &= ~(@as(u16, 1) << @intCast(child_slot));
                    break;
                }
            }
            if (selected == null) {
                for (1..user_threads.len + 1) |step| {
                    const slot = (current_thread + step) % user_threads.len;
                    if (user_threads[slot].state == .runnable) { selected = slot; break; }
                }
            }
            }
            }
            }
            }
        }
        if (selected) |slot| {
            current_thread = slot;
            current_pid = user_threads[slot].pid;
            if (workspace_activate_hook) |hook| hook(user_threads[slot].workspace_id);
            if (interrupt_reload_hook) |reload| reload();
            _ = vfs.changeDirectory(user_threads[slot].cwd[0..user_threads[slot].cwd_len]) catch {};
            // CLONE_CHILD_SETTID is observed by the new thread after the
            // parent has returned from clone. Publish it at the handoff,
            // rather than while the creator still owns musl's thread-list
            // lock, which would make the parent observe a premature TID.
            const next_thread = &user_threads[slot];
            if (next_thread.kind == .thread and next_thread.child_tid_set and next_thread.clear_tid != 0 and
                !next_thread.child_tid_published and validUserSlice(next_thread.clear_tid, 4)) {
                const child_tid_out: *align(1) u32 = @ptrFromInt(next_thread.clear_tid);
                child_tid_out.* = next_thread.pid;
                next_thread.child_tid_published = true;
            }
            completePendingSocketRead(slot);
            completePendingPoll(slot);
            completePendingWaitStatus(slot);
        } else {
            // No runnable task or external futex producer in this initial
            // single-process scheduler. Fail explicitly, never spin a waiter.
            serial.write("userspace thread deadlock: no runnable thread\n");
            process_exit_status = 125; user_threads_done = true; return result;
        }
    }
    const next = &user_threads[current_thread];
    restoreRawSyscallFrame(frame, next.frame); syscall_user_rsp = next.rsp;
    writeMsr(0xc0000100, next.fs);
    asm volatile ("fxrstor64 (%[p])" : : [p] "r" (&next.fx) : .{ .memory = true });
    return next.result;
}

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
    user_threads_enabled = false;
    user_threads_done = false;
    user_threads = @splat(.{});
    workspace_socket_refs = .{.{false} ** 32} ** 16;
    workspace_socket_cloexec = .{.{false} ** 32} ** 16;
    workspace_socket_ref_counts = .{.{0} ** 32} ** 16;
    workspace_stdio_sockets = [_][3]?usize{.{null, null, null}} ** 16;
    workspace_stdio_cloexec = [_][3]bool{.{false, false, false}} ** 16;
    workspace_fd_aliases = [_][16]SocketFdAlias{.{SocketFdAlias{}} ** 16} ** 16;
    workspace_socket_fd_map = .{.{null} ** 32} ** 16;
    workspace_socket_aliases = .{.{0} ** 32} ** 16;
    workspace_done = .{false} ** 16;
    workspace_exit_status = .{0} ** 16;
    top_level_workspace = 0xff;
    current_thread = 0;
    current_pid = 1;
    user_threads[0].pid = 1;
    user_threads[0].cwd[0] = '/';
    user_threads[0].cwd_len = 1;
    _ = vfs.changeDirectory("/") catch {};
    pending_clone = null;
    deferred_process_children = 0;
    deferred_user_threads = 0;
    active_user_thread = null;
    released_vfork_parent = null;
    defer_user_thread_switch = false;
    thread_switch_requested = false;
    workspace_clone_hook = null;
    workspace_activate_hook = null;
    workspace_release_hook = null;
    execve_hook = null;
    user_futex_blocks = 0;
    user_futex_wakes = 0;
    sockets = .{Socket{}} ** sockets.len;
    signal_actions = .{.{0} ** 32} ** 65;
    user_base = base;
    user_size = size;
    stack_base = stack;
    stack_size = stack_length;
    program_break = initial_break;
    break_limit = maximum_break;
    mmap_next = mmap_start;
    noreserve_next = 0x000000c000000000;
    mmap_base = mmap_start;
    mmap_limit = mmap_end;
    device_mmap_next = mmap_end;
    // Keep the device-mapping window bounded even if a malformed layout puts
    // its end near the top of the address space. An overflow disables the
    // optional window instead of wrapping it below mmap_end.
    device_mmap_limit = @import("std").math.add(u64, mmap_end, max_drm_objects * drm_object_stride) catch mmap_end;
    writes = 0;
    unknown_seen = .{false} ** unknown_seen.len;
    process_exit_status = 0xffffffffffffffff;
    process_pause = null;
    exec_pause_requested = false;
    process_nice = 0;
    process_umask = 0o022;
    process_name = .{ 'c', 's', 'o', 's', 0 } ++ .{0} ** 11;
    process_group = 1;
    process_session = 1;
    robust_head = 0;
    robust_len = 0;
    clear_tid_address = 0;
    signal_stack = .{0} ** 32;
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
    for (&ui_mailboxes) |*mailbox| mailbox.* = .{};
    ui_mailbox_used = .{false} ** 8;
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
pub fn configureDrmPci(identity: vfs.DrmPciIdentity) void { vfs.configureDrmPci(identity); }
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

pub fn configureMmapReset(hook: ?*const fn (u64, u64) callconv(.c) bool) void {
    mmap_reset_hook = hook;
}

/// The mmap allocator is process/address-space state.  The scheduler can
/// switch between loader workspaces without re-running configure(), so the
/// process manager must save and restore these cursors at every switch.
pub fn mmapState() [4]u64 {
    return .{ mmap_base, mmap_limit, mmap_next, noreserve_next };
}

pub fn restoreMmapState(state: [4]u64) void {
    mmap_base = state[0];
    mmap_limit = state[1];
    mmap_next = state[2];
    noreserve_next = state[3];
    device_mmap_next = mmap_limit;
    device_mmap_limit = std.math.add(u64, mmap_limit, max_drm_objects * drm_object_stride) catch mmap_limit;
}

pub fn configureUserSlice(hook: ?*const fn (u64, u64) callconv(.c) bool) void {
    user_slice_hook = hook;
}

pub fn configureProcessWorkspaces(
    workspace_id: u8,
    clone_hook: ?*const fn (u8, u32) callconv(.c) u16,
    activate_hook: ?*const fn (u8) callconv(.c) void,
    release_hook: ?*const fn (u8) callconv(.c) void,
) void {
    user_threads[current_thread].workspace_id = workspace_id;
    workspace_clone_hook = clone_hook;
    workspace_activate_hook = activate_hook;
    workspace_release_hook = release_hook;
}

/// Replace the user address-space bounds for execve without resetting the
/// cooperative scheduler.  Existing thread frames remain intact; the caller
/// is responsible for installing the new current-thread frame.
pub fn reconfigureAddressSpace(
    base: u64,
    size: u64,
    stack: u64,
    stack_length: u64,
    initial_break: u64,
    maximum_break: u64,
    mmap_start: u64,
    mmap_end: u64,
) void {
    user_base = base;
    user_size = size;
    stack_base = stack;
    stack_size = stack_length;
    program_break = initial_break;
    break_limit = maximum_break;
    mmap_next = mmap_start;
    noreserve_next = 0x000000c000000000;
    mmap_base = mmap_start;
    mmap_limit = mmap_end;
    device_mmap_next = mmap_end;
    device_mmap_limit = std.math.add(u64, mmap_end, max_drm_objects * drm_object_stride) catch mmap_end;
    process_exit_status = 0xffffffffffffffff;
    process_pause = null;
    exec_pause_requested = false;
    user_threads_done = false;
    if (current_thread < user_threads.len) user_threads[current_thread].rseq_address = 0;
}

pub fn configureConsole(read_hook: ?*const fn ([*]u8, usize) callconv(.c) usize, wait_hook: ?*const fn () callconv(.c) void) void {
    stdin_hook = read_hook;
    idle_hook = wait_hook;
}

pub fn exitStatus() ?u8 {
    if (process_exit_status == 0xffffffffffffffff) return null;
    return @truncate(process_exit_status);
}

pub fn resetExitStatus() void { process_exit_status = 0xffffffffffffffff; }
pub fn resetUserThreadsDone() void { user_threads_done = false; }

pub fn setTopLevelWorkspace(workspace: u8) void {
    top_level_workspace = workspace;
}

pub fn workspaceDone(workspace: u8) bool {
    return workspace < workspace_done.len and workspace_done[workspace];
}

pub fn workspaceExitStatus(workspace: u8) u8 {
    return if (workspace < workspace_exit_status.len) workspace_exit_status[workspace] else 125;
}

fn anyLiveUserThread() bool {
    for (user_threads) |thread| {
        if (thread.state == .runnable or thread.state == .blocked) return true;
    }
    return false;
}

/// Reset local socket/pipe descriptors at a top-level image boundary. Child
/// exec images retain inherited descriptors until they exit; the outer Git
/// command owns the final cleanup.
pub fn closeProcessSockets() void {
    for (&user_threads) |*thread| {
        thread.stdio_sockets = .{ null, null, null };
        thread.stdio_cloexec = .{ false, false, false };
        thread.direct_socket_refs = .{false} ** 32;
        thread.direct_socket_cloexec = .{false} ** 32;
    }
    for (&sockets) |*entry| {
        if (entry.connection) |*connection| if (network_stack) |stack| stack.tcpClose(connection) catch {};
        entry.* = .{};
    }
}

/// Start an exec replacement without inheriting the parent's TLS base. The
/// new musl image installs its own FS through arch_prctl before using TLS;
/// the parent's FS remains saved in its scheduler frame.
pub fn resetExecThreadTls() void {
    writeMsr(0xc0000100, 0);
    // Keep the scheduler's saved context consistent with the MSR while the
    // replacement image installs its own musl TLS.  Otherwise a timer/context
    // switch during the ELF bootstrap could restore the parent's FS base.
    if (current_thread < user_threads.len) user_threads[current_thread].fs = 0;
}

/// Complete an exec'd process child after its replacement image returns to
/// the kernel loader. The image no longer has a userspace frame from which
/// exitThread can report, but wait4 still needs the normal exited transition
/// and parent wakeup.
pub const UserResume = struct {
    frame: [14]u64,
    rsp: u64,
    result: u64,
    fs: u64,
    workspace_id: u8,
    fx: [512]u8 align(16),
};

fn closeProcessSocketRefs(thread_index: usize) void {
    if (thread_index >= user_threads.len) return;
    for (&user_threads[thread_index].socket_fd_aliases) |*alias| closeSocketAlias(thread_index, alias);
    var fd_index: usize = 0;
    while (fd_index < user_threads[thread_index].stdio_sockets.len) : (fd_index += 1) {
        if (user_threads[thread_index].stdio_sockets[fd_index]) |socket_index| {
            // stdio entries are workspace-owned and may be mirrored in
            // helper threads. Clear the entire workspace view before
            // dropping this process reference.
            clearWorkspaceStdioSocket(thread_index, socket_index, fd_index);
            if (sockets[socket_index].allocated) releaseSocketRef(socket_index);
        }
    }
    for (&user_threads[thread_index].owned_socket_refs, 0..) |*owned, socket_index| {
        if (!owned.*) continue;
        owned.* = false;
        // Direct descriptors are published to every thread in the process
        // workspace.  Removing only the owner's boolean leaves stale fd
        // maps in sibling helpers, so they can keep a pipe endpoint alive
        // after exec/exit and prevent the peer from observing EOF.
        clearWorkspaceDirectSocket(thread_index, socket_index, socket_fd_base + socket_index);
        if (sockets[socket_index].allocated) releaseSocketRef(socket_index);
    }
}

/// Release an exec replacement's inherited local descriptors by its Linux
/// pid.  The scheduler may have resumed another thread by the time the
/// loader returns, so using current_thread here would clean the wrong table.
pub fn closeProcessSocketsForPid(pid: u32) void {
    if (pid == 0) return;
    const thread_index: usize = @intCast(pid - 1);
    closeProcessSocketRefs(thread_index);
}

/// Drop the workspace's descriptor namespace after its process has been
/// reaped. `closeProcessSocketRefs` releases aliases owned by the child, but
/// the workspace publication tables are separate from the per-thread cache;
/// leaving them populated makes a recycled workspace inherit stale pipe
/// identities and can keep a Git receive-pack transport alive indefinitely.
pub fn releaseWorkspaceSockets(workspace: u8) void {
    if (workspace >= 16) return;
    for (&user_threads, 0..) |*thread, thread_index| {
        if (thread.workspace_id != workspace) continue;
        closeProcessSocketRefs(thread_index);
        thread.direct_socket_refs = .{false} ** 32;
        thread.direct_socket_cloexec = .{false} ** 32;
        thread.socket_fd_map = .{null} ** 32;
        thread.stdio_sockets = .{ null, null, null };
        thread.stdio_cloexec = .{ false, false, false };
        thread.owned_socket_refs = .{false} ** 32;
        thread.socket_fd_aliases = .{SocketFdAlias{}} ** 16;
    }
    // Any descriptor entries not represented by a live thread cache are
    // still real references inherited into this workspace. Drain the ledger
    // explicitly instead of dropping metadata and leaving the peer endpoint
    // permanently open.
    for (workspace_socket_ref_counts[workspace], 0..) |count, index| {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            if (sockets[index].allocated) releaseSocketRef(index);
        }
    }
    workspace_socket_refs[workspace] = .{false} ** 32;
    workspace_socket_cloexec[workspace] = .{false} ** 32;
    workspace_socket_ref_counts[workspace] = .{0} ** 32;
    workspace_stdio_sockets[workspace] = .{null, null, null};
    workspace_stdio_cloexec[workspace] = .{false, false, false};
    workspace_fd_aliases[workspace] = .{SocketFdAlias{}} ** 16;
    workspace_socket_fd_map[workspace] = .{null} ** 32;
    workspace_socket_aliases[workspace] = .{0} ** 32;
    // Keep workspace_done/exit_status intact until wait4 has reaped the
    // process. Descriptor teardown may run both at exit and from the reap
    // hook; clearing terminal state here makes a second teardown turn a
    // completed child back into an invisible, permanently-waited process.
}

/// Restore the non-GPR execution state saved for a parent while its process
/// child was running an exec replacement.  The assembly resume path restores
/// the SYSRET register frame, but TLS and SIMD state live outside that frame.
pub fn restoreUserResumeContext(saved: *const UserResume) void {
    writeMsr(0xc0000100, saved.fs);
    asm volatile ("fxrstor64 (%[p])" : : [p] "r" (&saved.fx) : .{ .memory = true });
}

/// CLONE_VFORK suspends the calling thread until the child has either exited
/// or successfully replaced its image with execve.  The loader handles the
/// replacement image outside the syscall frame, so explicitly hand the CPU
/// back to that caller once exec staging succeeds; otherwise an exec'd WPE
/// helper can keep polling forever while its launcher remains runnable but
/// never resumes to complete the IPC handshake.
pub fn releaseVforkParent(child_pid: u32) void {
    if (child_pid == 0 or child_pid - 1 >= user_threads.len) return;
    const child = &user_threads[child_pid - 1];
    if (!child.vfork_child or child.parent_slot >= user_threads.len) return;
    const parent = &user_threads[child.parent_slot];
    // The parent may have been marked blocked by the cooperative boundary
    // while the vfork child was loading.  Successful exec is the wake event;
    // restore the saved post-clone frame regardless of that transient state.
    parent.state = .runnable;
    // Keep the exec'd child on CPU; the parent is merely made runnable here.
    // Selecting the parent immediately can retarget the active workspace to
    // the launcher before the replacement image reaches its first IPC wait.
    active_user_thread = child_pid - 1;
    released_vfork_parent = null;
    defer_user_thread_switch = false;
    thread_switch_requested = false;
}

/// Make an exec replacement operate on the scheduler slot that issued the
/// request.  The loader runs outside the syscall frame; without this handoff
/// `configureProcessWorkspaces` could retarget slot 0 (the launcher) and the
/// replacement image would create its pthreads on the wrong process context.
pub fn activateExecThread(child_pid: u32) void {
    if (child_pid == 0 or child_pid - 1 >= user_threads.len) return;
    const slot = child_pid - 1;
    current_thread = slot;
    current_pid = user_threads[slot].pid;
    if (workspace_activate_hook) |hook| hook(user_threads[slot].workspace_id);
    if (interrupt_reload_hook) |reload| reload();
}

pub fn finishProcessChild(pid: u32, status: u8) ?UserResume {
    vfs.signalPidfd(pid);
    for (&user_threads) |*child| {
        if (child.kind != .process_child or child.pid != pid or child.state == .exited) continue;
        // The process descriptor table is owned by the workspace. Releasing
        // only the leader's cache leaves helper-thread copies alive and can
        // prevent pipe EOF from reaching the waiting parent.
        const child_workspace = child.workspace_id;
        for (&user_threads) |*peer| {
            if (peer.workspace_id != child_workspace or peer.pid == pid) continue;
            // exec replaces the entire process image. Old pthread helpers
            // must not remain blocked on the scheduler after the leader has
            // returned from its replacement image.
            peer.exec_request = null;
            peer.pending_read_socket = null;
            peer.pending_read_address = 0;
            peer.pending_read_length = 0;
            peer.pending_read_eof = false;
            peer.pending_write_socket = null;
            peer.pending_write_address = 0;
            peer.pending_write_length = 0;
            peer.pending_poll_address = 0;
            peer.pending_poll_count = 0;
            peer.pending_poll_sockets = .{false} ** 32;
            peer.state = .exited;
        }
        releaseWorkspaceSockets(child_workspace);
        // releaseWorkspaceSockets() clears reusable workspace metadata.  A
        // process that has just completed exec must remain observable to
        // wait4() until the parent reaps it, so publish the terminal state
        // again after descriptor cleanup.
        workspace_done[child_workspace] = true;
        workspace_exit_status[child_workspace] = status;
        child.exit_status = status;
        child.state = .exited;
        // The child is owned by its parent's workspace.  Do not require the
        // same scheduler slot: Git routinely forks from one worker and waits
        // from another thread sharing the process descriptor table.
        const parent_workspace = if (child.parent_slot < user_threads.len)
            user_threads[child.parent_slot].workspace_id
        else
            0xff;
        var parent_slot = child.parent_slot;
        for (user_threads, 0..) |candidate, candidate_slot| {
            if (candidate.workspace_id != parent_workspace or candidate.state != .blocked or
                candidate.wait_child_pid == 0) continue;
            if (candidate.wait_child_pid == ~@as(u64, 0) or candidate.wait_child_pid == pid) {
                parent_slot = candidate_slot;
                break;
            }
        }
        if (parent_slot >= user_threads.len) return null;
        const parent = &user_threads[parent_slot];
        // The parent may not have reached wait4 yet: the loader runs an
        // exec'd child immediately after fork, while the parent's syscall
        // frame is already saved by user_thread_resume.  Restore that frame
        // for both cases.  wait4 still receives its pending result below
        // when the parent was blocked; an unblocked parent simply continues
        // after clone and can reap the exited child normally.
        if (parent.state == .blocked and parent.wait_child_pid != 0 and
            (parent.wait_child_pid == ~@as(u64, 0) or parent.wait_child_pid == pid)) {
            parent.pending_wait_status = status;
            parent.pending_wait_address = parent.wait_status;
            parent.result = pid;
            parent.wait_child_pid = 0;
            parent.wait_status = 0;
            parent.state = .runnable;
            current_thread = parent_slot;
            current_pid = parent.pid;
            return .{ .frame = parent.frame, .rsp = parent.rsp, .result = parent.result, .fs = parent.fs, .workspace_id = parent.workspace_id, .fx = parent.fx };
        }
        current_thread = parent_slot;
        current_pid = parent.pid;
        return .{ .frame = parent.frame, .rsp = parent.rsp, .result = parent.result, .fs = parent.fs, .workspace_id = parent.workspace_id, .fx = parent.fx };
    }
    return null;
}

export fn process_exit_dispatch(status: u64) callconv(.c) void {
    process_exit_status = status;
}

/// Replace the saved userspace context when an existing scheduler slot starts
/// a fresh exec image.  The old image may have a valid timer snapshot; using
/// it after exec would return into the previous stack/code while the new
/// image is still being bootstrapped.
pub fn resetExecThreadContext(entry: u64, stack: u64) void {
    if (!user_threads_enabled or current_thread >= user_threads.len) return;
    var thread = &user_threads[current_thread];
    thread.frame = @splat(0);
    thread.frame[0] = entry;
    thread.frame[1] = 0x202;
    thread.rsp = stack;
    thread.result = 0;
    thread.timer_valid = false;
}

pub fn primeUserTls(address: u64) void {
    writeMsr(0xc0000100, address);
}



pub fn configureInterruptReload(hook: ?*const fn () void) void {
    interrupt_reload_hook = hook;
}

export fn process_pause_dispatch(instruction: u64, stack: u64) callconv(.c) void {
    process_pause = .{ .instruction = instruction, .stack = stack };
}

pub fn takePause() ?Pause {
    const result = process_pause;
    process_pause = null;
    exec_pause_requested = false;
    return result;
}

pub fn configureInitializerStep(hook: ?*const fn (u64) callconv(.c) void) void {
    initializer_step_hook = hook;
}

export fn user_syscall_dispatch(number: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.c) u64 {
    if (user_threads_enabled and current_thread < user_threads.len)
        _ = vfs.changeDirectory(user_threads[current_thread].cwd[0..user_threads[current_thread].cwd_len]) catch {};
    return switch (number) {
        0 => read(arg1, arg2, arg3),
        1 => write(arg1, arg2, arg3),
        2 => openat(@bitCast(@as(i64, -100)), arg1, arg2),
        3 => close(arg1),
        4 => stat(arg1, arg2, -100),
        5 => fstat(arg1, arg2),
        6 => stat(arg1, arg2, -100),
        7 => poll(arg1, arg2, @bitCast(arg3)),
        8 => lseek(arg1, arg2, arg3),
        9 => mmap(arg1, arg2, arg3, arg4, arg5, arg6),
        10 => mprotect(arg1, arg2, arg3),
        11 => munmap(arg1, arg2),
        12 => brk(arg1),
        13 => rtSigaction(arg1, arg2, arg3, arg4),
        14 => rtSigprocmask(arg3, arg4),
        // Linux ioctl's command is unsigned int. musl passes its signed int
        // API argument sign-extended; upper register bits are not command bits.
        16 => ioctl(arg1, @truncate(arg2), arg3),
        17 => pread64(arg1, arg2, arg3, arg4),
        18 => pwrite64(arg1, arg2, arg3, arg4),
        19 => readv(arg1, arg2, arg3),
        20 => writev(arg1, arg2, arg3),
        21 => access(arg1, @truncate(arg2)),
        // Let libc/runtimes yield through the same bounded idle hook used by
        // the console loop; this is a real no-op only when no scheduler hook
        // is installed, and avoids advertising ENOSYS for a core Linux ABI.
        24 => schedYield(),
        // GLib installs a short watchdog during initialization. Timers are
        // driven by the kernel scheduler, so an unarmed alarm is the only
        // valid result in this bootstrap path.
        25 => 0,
        // setitimer(2): the cooperative scheduler owns timer delivery. Git's
        // pack/index helpers use this only as a watchdog; accepting the
        // request prevents a spurious ENOSYS path from corrupting the helper
        // protocol while leaving delivery to the existing scheduler clock.
        38 => 0,
        28 => madvise(arg1, arg2, arg3),
        // dup(2) returns the lowest available descriptor.  Reuse the same
        // descriptor-table path as F_DUPFD rather than treating it as dup2;
        // WPE/GLib uses dup while wiring its renderer and IPC channels.
        32 => fcntl(arg1, 0, 0),
        33 => duplicate(arg1, arg2),
        39 => current_pid,
        110 => 1,
        40 => sendfile(arg1, arg2, arg3, arg4),
        41 => socket(arg1, arg2, arg3),
        42 => connect(arg1, arg2, arg3),
        44 => sendTo(arg1, arg2, arg3),
        45 => receiveFrom(arg1, arg2, arg3),
        46 => sendMessage(arg1, arg2, arg3),
        47 => receiveMessage(arg1, arg2, arg3),
        48 => shutdown(arg1, arg2),
        51 => socketName(arg1, arg2, arg3, false),
        52 => socketName(arg1, arg2, arg3, true),
        53 => socketPair(arg1, arg2, arg3, arg4),
        54 => setSocketOption(arg1, arg2, arg3, arg4, arg5),
        55 => getSocketOption(arg1, arg2, arg3, arg4, arg5),
        22 => pipe2(arg1, 0),
        56 => cloneThread(arg1, arg2, arg3, arg4, arg5, arg6),
        // fork creates a cooperative process child; execve remains the
        // explicit image-replacement boundary.
        57 => cloneThread(17, 0, 0, 0, 0, 0),
        // Git's run-command backend may select vfork on x86-64.  CSOS uses
        // the same bounded cooperative process-child path; the scheduler
        // still guarantees the parent can wait for the child before reuse.
        58 => cloneThread(17, 0, 0, 0, 0, 0),
        293 => pipe2(arg1, arg2),
        59 => execve(arg1, arg2, arg3),
        60 => exitThread(arg1),
        62 => kill(arg1, arg2),
        61 => wait4(arg1, arg2, arg3, arg4),
        63 => uname(arg1),
        72 => fcntl(arg1, arg2, arg3),
        74 => syncFile(arg1),
        75 => syncFile(arg1),
        76 => truncatePath(arg1, arg2),
        77 => ftruncate(arg1, arg2),
        79 => getcwd(arg1, arg2),
        80 => chdir(arg1),
        82 => renameLegacy(arg1, arg2),
        83 => mkdirLegacy(arg1, arg2),
        84 => rmdirLegacy(arg1),
        85 => creatLegacy(arg1, arg2),
        86 => linkLegacy(arg1, arg2),
        87 => unlinkLegacy(arg1),
        88 => symlinkLegacy(arg1, arg2),
        89 => readlinkat(@bitCast(@as(i64, -100)), arg1, arg2, arg3),
        90 => chmodLegacy(arg1, arg2),
        96 => getTimeOfDay(arg1, arg2),
        // Git updates reflog timestamps through all three Linux timestamp
        // entry points.  FAT16 has no exposed timestamp mutation yet, but the
        // path/FD contract must succeed so metadata updates do not abort a
        // repository operation.
        235 => utimes(arg1, arg2),
        261 => futimesat(arg1, arg2, arg3),
        280 => utimensat(arg1, arg2, arg3, arg4),
        95 => umask(arg1),
        97 => getRlimit(arg1, arg2),
        98 => getRusage(arg1, arg2),
        99 => sysinfo(arg1),
        100 => times(arg1),
        450 => uiChannelCreate(),
        451 => uiChannelSend(arg1, arg2, arg3),
        452 => uiChannelReceive(arg1, arg2, arg3),
        // Internal PT_INTERP hook: refresh deferred COPY objects after an
        // initializer has run. It has no effect for images without COPY data.
        460 => if (initializer_step_hook) |hook| blk: { hook(arg1); break :blk 0; } else 0,
        102, 104, 107, 108 => 0,
        // Git's spawn setup may pass uid/gid -1 to mean "unchanged". CSOS
        // has only the root identity at this stage, so accept root and the
        // Linux all-ones sentinel; reject real unprivileged transitions.
        105, 106 => if (arg1 == 0 or arg1 == std.math.maxInt(u64) or arg1 == std.math.maxInt(u32)) 0 else errno(1),
        112 => setSid(),
        113 => setRegId(arg1, arg2),
        114 => setRegId(arg1, arg2),
        109 => setPgid(arg1, arg2),
        121 => getPgid(arg1),
        124 => getSid(arg1),
        125 => capGet(arg1, arg2),
        126 => capSet(arg1, arg2),
        // Nix probes pending signals while coordinating worker processes.  No
        // asynchronous signal queue exists yet, so a timed wait observes an
        // empty queue and returns the Linux EAGAIN result after its timeout.
        128 => errno(11),
        127 => if (validUserSlice(arg1, arg2)) blk: {
            @memset(@as([*]u8, @ptrFromInt(arg1))[0..@intCast(arg2)], 0);
            break :blk 0;
        } else errno(14),
        115 => getGroups(arg1, arg2),
        116 => setGroups(arg1, arg2),
        117 => setResUid(arg1, arg2, arg3),
        118 => getResUid(arg1, arg2, arg3),
        119 => setResGid(arg1, arg2, arg3),
        120 => getResGid(arg1, arg2, arg3),
        135 => personality(arg1),
        137 => statfs(arg1, arg2),
        138 => fstatfs(arg1, arg2),
        131 => sigaltstack(arg1, arg2),
        140 => getPriority(arg1, arg2),
        141 => setPriority(arg1, arg2, @bitCast(arg3)),
        142 => setScheduler(arg1, arg2, arg3),
        143 => getSchedulerParam(arg1, arg2),
        144 => setScheduler(arg1, arg2, arg3),
        145 => getScheduler(arg1),
        148 => schedRrInterval(arg1, arg2),
        149 => memoryLock(arg1, arg2),
        150 => memoryUnlock(arg1, arg2),
        151 => memoryLockAll(arg1),
        152 => memoryUnlockAll(),
        157 => prctl(arg1, arg2, arg3),
        158 => archPrctl(arg1, arg2),
        // musl's x86-64 __set_thread_area path uses the legacy syscall
        // number while bootstrapping its private TLS domain.  CSOS does not
        // expose Linux GDT TLS descriptors; the required contract is the
        // userspace FS base used by musl's pthread implementation.
        205 => setThreadArea(arg1),
        160 => setRlimit(arg1, arg2),
        162 => syncAll(),
        // The current userspace model has one kernel thread per process.  Keep
        // gettid consistent with getpid so musl's thread-local setup does not
        // fall through to ENOSYS while loading real shared libraries.
        186 => current_thread + 1,
        // WebKit/GLib uses legacy tkll to probe thread signal state; CSOS
        // currently has no asynchronous signal delivery between user threads.
        200 => 0,
        202 => futex(arg1, arg2, arg3, arg4, arg5),
        203 => schedSetAffinity(arg1, arg2, arg3),
        204 => schedGetAffinity(arg1, arg2, arg3),
        217 => getdents(arg1, arg2, arg3),
        221 => fadvise64(arg1, arg2, arg3, arg4),
        218 => setTidAddress(arg1),
        228 => clockGetTime(arg1, arg2),
        229 => clockGetRes(arg1, arg2),
        230 => clockNanosleep(arg1, arg2, arg3, arg4),
        // exit_group from an exec'd process child must participate in the
        // userspace thread scheduler so wait4 can reap it.  Treat the lone
        // main thread as an ordinary process thread here; exitSyscall would
        // terminate the whole loader before the parent resumes.
        231 => exitThread(arg1),
        234 => tgkill(arg1, arg2, arg3),
        35 => clockNanosleep(1, 0, arg1, arg2),
        257 => openat(arg1, arg2, arg3),
        258 => mkdirat(arg1, arg2, arg3),
        263 => unlinkat(arg1, arg2, arg3),
        264 => renameat(arg1, arg2, arg3, arg4),
        265 => linkat(arg1, arg2, arg3, arg4, arg5),
        262 => stat(arg2, arg3, @bitCast(arg1)),
        267 => readlinkat(@bitCast(arg1), arg2, arg3, arg4),
        247 => waitId(arg1, arg2, arg3, arg4),
        271 => ppoll(arg1, arg2, arg3, arg4, arg5),
        302 => prlimit64(arg1, arg2, arg3, arg4),
        306 => syncFile(arg1),
        232 => epollWait(arg1, arg2, arg3, @bitCast(arg4)),
        233 => epollCtl(arg1, arg2, arg3, arg4),
        291 => epollCreate(arg1),
        290 => eventfd2(arg1, arg2),
        273 => setRobustList(arg1, arg2),
        316 => renameat2(arg1, arg2, arg3, arg4, arg5),
        274 => getRobustList(arg1, arg2, arg3, arg4),
        309 => getcpu(arg1, arg2),
        318 => getRandom(arg1, arg2, arg3),
        322 => execveAt(arg1, arg2, arg3, arg4, arg5),
        // membarrier is redundant across the syscall boundary in the
        // cooperative single-process scheduler used by this runtime.
        324 => 0,
        334 => rseq(arg1, arg2, arg3, arg4),
        332 => statx(arg1, arg2, arg3, arg4, arg5),
        434 => pidfdOpen(arg1, arg2),
        436 => closeRange(arg1, arg2, arg3),
        439 => faccessat2(arg1, arg2, arg3, arg4),
        else => unsupported(number),
    };
}

fn rtSigaction(signum: u64, new_action: u64, old_action: u64, sigset_size: u64) u64 {
    if (signum == 0 or signum >= signal_actions.len or sigset_size != 8) return errno(22);
    if (new_action != 0 and !validUserSlice(new_action, 32)) return errno(14);
    if (old_action != 0 and !validUserSlice(old_action, 32)) return errno(14);
    if (old_action != 0) {
        const bytes: [*]u8 = @ptrFromInt(old_action);
        @memcpy(bytes[0..32], &signal_actions[signum]);
    }
    if (new_action != 0) {
        const bytes: [*]const u8 = @ptrFromInt(new_action);
        @memcpy(&signal_actions[signum], bytes[0..32]);
    }
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

fn getTimeOfDay(address: u64, timezone: u64) u64 {
    _ = timezone; // Linux retains this obsolete pointer for ABI compatibility.
    if (address == 0) return 0;
    if (!validUserSlice(address, 16)) return errno(14);
    monotonic_time_ns = saturatingCount(monotonic_time_ns, 1_000);
    const bytes: [*]u8 = @ptrFromInt(address);
    put64(bytes, monotonic_time_ns / 1_000_000_000);
    put64(bytes + 8, (monotonic_time_ns % 1_000_000_000) / 1_000);
    return 0;
}

fn clockGetTime(clock: u64, address: u64) u64 {
    // CLOCK_REALTIME, MONOTONIC, MONOTONIC_RAW and BOOTTIME are all backed
    // by the firmware-independent monotonic source in this early kernel.
    if (!supportedClock(clock) or !validUserSlice(address, 16)) return errno(22);
    // The firmware timer is not wired into this early userspace ABI yet; keep
    // a monotonic software clock so libc does not observe time going backward.
    monotonic_time_ns = saturatingCount(monotonic_time_ns, 1_000_000);
    const bytes: [*]u8 = @ptrFromInt(address);
    put64(bytes, monotonic_time_ns / 1_000_000_000);
    put64(bytes + 8, monotonic_time_ns % 1_000_000_000);
    return 0;
}

fn clockNanosleep(clock: u64, flags: u64, request: u64, remaining: u64) u64 {
    if (!supportedClock(clock) or (flags & ~@as(u64, 1)) != 0 or !validUserSlice(request, 16)) return errno(22);
    const value: [*]const u8 = @ptrFromInt(request);
    const seconds = read64(value);
    const nanoseconds = read64(value + 8);
    if (nanoseconds >= 1_000_000_000) return errno(22);
    if (remaining != 0 and !validUserSlice(remaining, 16)) return errno(14);
    const requested_ns = if (seconds > std.math.maxInt(u64) / 1_000_000_000)
        std.math.maxInt(u64)
    else
        (seconds * 1_000_000_000) +| nanoseconds;
    const should_wait = if ((flags & 1) != 0)
        requested_ns > monotonic_time_ns
    else
        requested_ns != 0;
    if (should_wait) if (idle_hook) |hook| hook();
    if ((flags & 1) == 0)
        monotonic_time_ns = saturatingCount(monotonic_time_ns, requested_ns)
    else if (requested_ns > monotonic_time_ns)
        monotonic_time_ns = requested_ns;
    if (remaining != 0) @memset(@as([*]u8, @ptrFromInt(remaining))[0..16], 0);
    return 0;
}

fn clockGetRes(clock: u64, output: u64) u64 {
    if (!supportedClock(clock)) return errno(22);
    if (output == 0) return 0;
    if (!validUserSlice(output, 16)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(output);
    @memset(bytes[0..16], 0);
    bytes[8] = 1; // one nanosecond software resolution
    return 0;
}

fn supportedClock(clock: u64) bool {
    // Until RTC calibration is wired into the boot path, all accepted clock
    // IDs intentionally share the monotonic source; this preserves ordering
    // without fabricating a wall-clock offset.
    // Linux exposes coarse and alarm clock variants in addition to the basic
    // realtime/monotonic IDs.  This early kernel has one monotonic source, so
    // map the complete non-dynamic ID range to it instead of returning EINVAL
    // from libc's monotonic-time probe.
    return clock <= 11;
}

fn read(fd: u64, address: u64, length: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const length_usize = std.math.cast(usize, length) orelse return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (vfs.isEventfd(@intCast(fd))) return vfs.readEventfd(@intCast(fd), output[0..length_usize]) catch |err| vfsError(err);
    if (fd == 0 and socketIndex(fd) == null) {
        if (length == 0) return 0;
        const hook = stdin_hook orelse return 0;
        return hook(output, length_usize);
    }
    const socket_index = socketIndex(fd);
    if (socket_index) |index| {
        return socketReceive(index, output[0..length_usize]);
    }
    return vfs.read(@intCast(fd), output[0..length_usize]) catch |err| vfsError(err);
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
        const read_count = if (explicit_offset) |position| blk: {
            if (position > std.math.maxInt(u64) - transferred)
                return if (transferred == 0) errno(75) else transferred;
            const file_offset = std.math.cast(usize, position + transferred) orelse
                return if (transferred == 0) errno(75) else transferred;
            break :blk vfs.pread(@intCast(input_fd), buffer[0..wanted], file_offset) catch |err| return if (transferred == 0) vfsError(err) else transferred;
        }
        else
            vfs.read(@intCast(input_fd), buffer[0..wanted]) catch |err| return if (transferred == 0) vfsError(err) else transferred;
        if (read_count == 0) break;
        const written = writeKernel(output_fd, buffer[0..read_count]) catch |err| return if (transferred == 0) vfsError(err) else transferred;
        transferred = advanceSendfileTransfer(transferred, written) catch
            return if (transferred == 0) errno(75) else transferred;
        if (written != read_count) break;
    }
    if (offset_address != 0) {
        if (explicit_offset.? > std.math.maxInt(u64) - transferred)
            return if (transferred == 0) errno(75) else transferred;
        const pointer: *align(1) u64 = @ptrFromInt(offset_address);
        pointer.* = explicit_offset.? + transferred;
    }
    sendfile_calls = saturatingCount(sendfile_calls, 1);
    return transferred;
}

fn advanceSendfileTransfer(transferred: u64, written: usize) !u64 {
    return std.math.add(u64, transferred, written) catch error.Overflow;
}

test "sendfile transfer counter rejects overflow" {
    try std.testing.expectEqual(@as(u64, 12), try advanceSendfileTransfer(10, 2));
    try std.testing.expectError(error.Overflow, advanceSendfileTransfer(std.math.maxInt(u64), 1));
}

test "DRM mode dimensions fit the userspace ABI" {
    const saved = framebuffer;
    defer framebuffer = saved;
    framebuffer.width = std.math.maxInt(u16);
    framebuffer.height = std.math.maxInt(u16);
    try std.testing.expect(drmModeDimensionsFit());
    framebuffer.width = @as(u32, std.math.maxInt(u16)) + 1;
    try std.testing.expect(!drmModeDimensionsFit());
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
    if (console_write_hook) |hook| hook(bytes);
    if (writes != std.math.maxInt(usize)) writes += 1;
    return bytes.len;
}

fn socketHasPublishedIdentity(index: usize) bool {
    for (workspace_socket_fd_map) |workspace_map| {
        for (workspace_map) |mapped| if (mapped == index) return true;
    }
    for (workspace_socket_aliases) |workspace_aliases| {
        if (workspace_aliases[index] != 0) return true;
    }
    for (workspace_fd_aliases) |aliases| {
        for (aliases) |alias| if (alias.used and alias.socket_index == index) return true;
    }
    for (user_threads) |thread| {
        if (thread.stdio_sockets[0] == index or thread.stdio_sockets[1] == index or thread.stdio_sockets[2] == index)
            return true;
        if (thread.direct_socket_refs[index] or thread.owned_socket_refs[index]) return true;
        for (thread.socket_fd_aliases) |alias| if (alias.used and alias.socket_index == index) return true;
    }
    return false;
}

pub export fn userTimerSwitch(registers: *anyopaque, user_frame: *anyopaque) callconv(.c) bool {
    if (!user_threads_enabled or current_thread >= user_threads.len) return false;
    // A pthread creator must first return from clone while it still owns the
    // libc thread-list lock. Give that syscall return one timer quantum before
    // allowing the deferred child to run; otherwise a preemptive tick can
    // reintroduce the same bootstrap race as an immediate cooperative switch.
    if (defer_user_thread_switch and deferred_user_threads != 0) {
        defer_user_thread_switch = false;
        return false;
    }
    const regs: *[15]u64 = @ptrCast(@alignCast(registers));
    const frame: *[5]u64 = @ptrCast(@alignCast(user_frame));
    var selected: ?usize = null;
    if (deferred_user_threads != 0) {
        const current_workspace = user_threads[current_thread].workspace_id;
        for (0..user_threads.len) |slot| {
            // Deferred pthreads belong to the current process workspace.
            // Never let a timer interrupt cross into another process's
            // address space; process children use the separate deferred
            // process-child queue below.
            if ((deferred_user_threads & (@as(u16, 1) << @intCast(slot))) != 0 and
                user_threads[slot].state == .runnable and
                user_threads[slot].kind == .thread and
                user_threads[slot].workspace_id == current_workspace and
                slot != current_thread) {
                selected = slot;
                deferred_user_threads &= ~(@as(u16, 1) << @intCast(slot));
                break;
            }
        }
    }
    if (selected == null and deferred_process_children != 0) {
        for (0..user_threads.len) |slot| {
            if ((deferred_process_children & (@as(u16, 1) << @intCast(slot))) != 0 and
                user_threads[slot].state == .runnable) {
                const parent = user_threads[slot].parent_slot;
                const can_run = user_threads[slot].vfork_child or parent >= user_threads.len or
                    user_threads[parent].state != .runnable or
                    workspaceHasBlockedThread(user_threads[parent].workspace_id);
                if (!can_run) continue;
                selected = slot;
                deferred_process_children &= ~(@as(u16, 1) << @intCast(slot));
                break;
            }
        }
    }
    // Once a deferred pthread has had its first turn, allow the timer to
    // return to another runnable thread in the same workspace. This is the
    // preemption point needed when the child is spinning in libc while the
    // creator owns a lock; process-child workspaces remain cooperative.
    if (selected == null) {
        const workspace = user_threads[current_thread].workspace_id;
        for (1..user_threads.len + 1) |step| {
            const slot = (current_thread + step) % user_threads.len;
            if (user_threads[slot].state == .runnable and
                user_threads[slot].kind == .thread and
                user_threads[slot].workspace_id == workspace) {
                selected = slot;
                break;
            }
        }
    }
    const next = selected orelse return false;
    const current = &user_threads[current_thread];
    current.timer_frame[0] = frame[0];
    current.timer_frame[1] = frame[2];
    current.timer_frame[2] = frame[3];
    for (0..15) |index| current.timer_frame[3 + index] = regs[index];
    current.timer_valid = true;
    current.fs = readMsr(0xc0000100);
    asm volatile ("fxsave64 (%[p])" : : [p] "r" (&current.fx) : .{ .memory = true });
    current_thread = next;
    current_pid = user_threads[next].pid;
    if (workspace_activate_hook) |hook| hook(user_threads[next].workspace_id);
    if (interrupt_reload_hook) |reload| reload();
    const replacement = &user_threads[next];
    if (!replacement.timer_valid) {
        replacement.timer_frame[0] = replacement.frame[0];
        replacement.timer_frame[1] = replacement.frame[1];
        replacement.timer_frame[2] = replacement.rsp;
        replacement.timer_frame[3] = replacement.result;
        replacement.timer_frame[4] = replacement.frame[0];
        replacement.timer_frame[5] = replacement.frame[13];
        replacement.timer_frame[6] = replacement.frame[12];
        replacement.timer_frame[7] = replacement.frame[11];
        replacement.timer_frame[8] = replacement.frame[10];
        replacement.timer_frame[9] = replacement.frame[9];
        replacement.timer_frame[10] = replacement.frame[8];
        replacement.timer_frame[11] = replacement.frame[7];
        replacement.timer_frame[12] = replacement.frame[6];
        replacement.timer_frame[13] = replacement.frame[1];
        replacement.timer_frame[14] = replacement.frame[5];
        replacement.timer_frame[15] = replacement.frame[4];
        replacement.timer_frame[16] = replacement.frame[3];
        replacement.timer_frame[17] = replacement.frame[2];
        replacement.timer_valid = true;
    }
    frame[0] = replacement.timer_frame[0];
    frame[1] = 0x23;
    frame[2] = replacement.timer_frame[1];
    frame[3] = replacement.timer_frame[2];
    frame[4] = 0x1b;
    for (0..15) |index| regs[index] = replacement.timer_frame[3 + index];
    writeMsr(0xc0000100, replacement.fs);
    asm volatile ("fxrstor64 (%[p])" : : [p] "r" (&replacement.fx) : .{ .memory = true });
    return true;
}

fn workspaceDirectSlotFree(workspace: u8, index: usize) bool {
    if (workspace >= workspace_socket_fd_map.len or index >= sockets.len) return false;
    return workspace_socket_fd_map[workspace][index] == null;
}

fn releaseSocketRef(index: usize) void {
    // A peer observes EOF only after the final reference to this endpoint is
    // gone.  Published namespace entries are bookkeeping, not ownership: a
    // fork/exec boundary can temporarily have a real reference that is not
    // represented in one of those maps.  Closing the peer while `refs` is
    // still non-zero truncates a pipe stream and is precisely the failure
    // mode Git reports as a bad pack header.
    if (sockets[index].refs > 1) {
        sockets[index].refs -= 1;
        return;
    }
    if (sockets[index].refs == 0) return;
    if (sockets[index].pending_rights_len != 0) {
        for (sockets[index].pending_rights[0..sockets[index].pending_rights_len]) |source| {
            if (source < sockets.len and sockets[source].refs != 0) sockets[source].refs -= 1;
        }
        sockets[index].pending_rights_len = 0;
    }
    if (sockets[index].peer_index) |peer| {
        sockets[peer].peer_closed = true;
        for (&user_threads) |*thread| {
            if (thread.pending_read_socket == peer) {
                thread.pending_read_eof = true;
                thread.state = .runnable;
                thread_switch_requested = true;
            }
        }
        wakeSocketReaders(peer);
        wakeSocketWriters(peer);
        wakeSocketPollers(peer);
    }
    if (sockets[index].connection) |*connection| if (network_stack) |stack| stack.tcpClose(connection) catch {};
    // Once the final object reference is gone, no workspace may retain the
    // old numeric identity.  Clear every published map before the slot is
    // reused; otherwise a later socket() can inherit a stale fd->index entry
    // from an unrelated process and connect the wrong pipe endpoints.
    for (0..workspace_socket_fd_map.len) |workspace| {
        for (&workspace_socket_fd_map[workspace]) |*mapped| {
            if (mapped.* == index) mapped.* = null;
        }
        workspace_socket_refs[workspace][index] = false;
        workspace_socket_cloexec[workspace][index] = false;
        workspace_socket_ref_counts[workspace][index] = 0;
        workspace_socket_aliases[workspace][index] = 0;
    }
    for (&user_threads) |*thread| {
        thread.direct_socket_refs[index] = false;
        thread.direct_socket_cloexec[index] = false;
        thread.owned_socket_refs[index] = false;
        for (&thread.socket_fd_map) |*mapped| {
            if (mapped.* == index) mapped.* = null;
        }
        for (&thread.socket_fd_aliases) |*alias| {
            if (alias.used and alias.socket_index == index) alias.* = .{};
        }
    }
    for (&workspace_fd_aliases) |*aliases| {
        for (aliases) |*alias| {
            if (alias.used and alias.socket_index == index) alias.* = .{};
        }
    }
    sockets[index] = .{};
}

fn clearWorkspaceDirectSocket(owner: usize, index: usize, fd: u64) void {
    const workspace = user_threads[owner].workspace_id;
    var removed = false;
    for (&user_threads) |*peer| {
        if (peer.workspace_id != workspace) continue;
        if (fd >= socket_fd_base and fd < socket_fd_base + sockets.len) {
            const slot: usize = @intCast(fd - socket_fd_base);
            if (workspace_socket_fd_map[workspace][slot] == index) {
                workspace_socket_fd_map[workspace][slot] = null;
            }
            if (peer.socket_fd_map[slot] == index) {
                peer.socket_fd_map[slot] = null;
                removed = true;
            }
        }
        var still_mapped = false;
        for (peer.socket_fd_map) |mapped| if (mapped == index) { still_mapped = true; break; };
        if (!still_mapped) {
            peer.direct_socket_refs[index] = false;
            peer.direct_socket_cloexec[index] = false;
            peer.owned_socket_refs[index] = false;
        }
    }
    if (removed and workspace_socket_aliases[workspace][index] != 0)
        workspace_socket_aliases[workspace][index] -= 1;
    if (removed and workspace_socket_ref_counts[workspace][index] != 0)
        workspace_socket_ref_counts[workspace][index] -= 1;
    var still_workspace_mapped = false;
    for (user_threads) |peer| if (peer.workspace_id == workspace and peer.direct_socket_refs[index]) { still_workspace_mapped = true; break; };
    if (!still_workspace_mapped) {
        workspace_socket_refs[workspace][index] = false;
        workspace_socket_cloexec[workspace][index] = false;
    }
}

fn clearWorkspaceStdioSocket(owner: usize, index: usize, fd: usize) void {
    const workspace = user_threads[owner].workspace_id;
    if (workspace_socket_aliases[workspace][index] != 0)
        workspace_socket_aliases[workspace][index] -= 1;
    if (workspace_socket_ref_counts[workspace][index] != 0)
        workspace_socket_ref_counts[workspace][index] -= 1;
    if (fd < workspace_stdio_sockets[workspace].len and workspace_stdio_sockets[workspace][fd] == index) {
        workspace_stdio_sockets[workspace][fd] = null;
        workspace_stdio_cloexec[workspace][fd] = false;
    }
    for (&user_threads) |*peer| {
        if (peer.workspace_id != workspace) continue;
        if (peer.stdio_sockets[fd] == index) {
            peer.stdio_sockets[fd] = null;
            peer.stdio_cloexec[fd] = false;
        }
    }
}

fn publishDirectSocket(owner: usize, index: usize, cloexec: bool) void {
    const owner_workspace = user_threads[owner].workspace_id;
    workspace_socket_refs[owner_workspace][index] = true;
    workspace_socket_cloexec[owner_workspace][index] = cloexec;
    if (workspace_socket_ref_counts[owner_workspace][index] != std.math.maxInt(u16))
        workspace_socket_ref_counts[owner_workspace][index] += 1;
    if (workspace_socket_aliases[owner_workspace][index] != std.math.maxInt(u8))
        workspace_socket_aliases[owner_workspace][index] += 1;
    for (&user_threads) |*peer| {
        if (peer.workspace_id != owner_workspace) continue;
        peer.direct_socket_refs[index] = true;
        peer.direct_socket_cloexec[index] = cloexec;
        peer.socket_fd_map[index] = index;
    }
    workspace_socket_fd_map[owner_workspace][index] = index;
}

pub fn closeOnExecSockets() void {
    const workspace = user_threads[current_thread].workspace_id;
    for (&workspace_fd_aliases[workspace]) |*alias|
        if (alias.used and alias.close_on_exec) closeSocketAlias(current_thread, alias);
    var index: usize = 0;
    while (index < sockets.len) : (index += 1) {
        if (!sockets[index].allocated) continue;
        if (workspace_socket_refs[workspace][index] and workspace_socket_cloexec[workspace][index]) {
            // The direct descriptor is workspace-owned. Clear every thread's
            // published view before dropping the single table reference;
            // clearing only current_thread leaves an inherited endpoint alive
            // across exec and prevents pipe EOF.
            clearWorkspaceDirectSocket(current_thread, index, socket_fd_base + index);
            releaseSocketRef(index);
        }
        for (workspace_stdio_sockets[workspace], 0..) |entry, fd| {
            if (entry == index and workspace_stdio_cloexec[workspace][fd]) {
                clearWorkspaceStdioSocket(current_thread, index, fd);
                releaseSocketRef(index);
            }
        }
    }
}

fn close(fd: u64) u64 {
    if (socketIndex(fd)) |index| {
        if (fd < 3) {
            clearWorkspaceStdioSocket(current_thread, index, @intCast(fd));
            releaseSocketRef(index);
            return 0;
        }
        if (socketAliasForThread(current_thread, fd)) |alias| {
            closeSocketAlias(current_thread, alias);
            return 0;
        }
        clearWorkspaceDirectSocket(current_thread, index, fd);
        releaseSocketRef(index);
        return 0;
    }
    if (fd <= 2 and !vfs.isOpen(@intCast(fd))) return 0;
    vfs.close(@intCast(fd)) catch |err| return vfsError(err);
    return 0;
}

fn duplicate(old_fd: u64, new_fd: u64) u64 {
    if (socketIndex(old_fd)) |source| {
        if (old_fd == new_fd) return new_fd;
        if (new_fd < 3) {
            if (user_threads[current_thread].stdio_sockets[@intCast(new_fd)] != null) _ = close(new_fd);
            sockets[source].refs += 1;
            // dup2/dup3 create a descriptor whose close-on-exec flag is
            // clear; Git relies on this when wiring pipe ends to stdio
            // before exec'ing receive-pack/upload-pack.
            // The stdio descriptor has its own CLOEXEC bit; changing it must
            // not mutate the backing socket or the parent's descriptor.
            const workspace = user_threads[current_thread].workspace_id;
            workspace_stdio_sockets[workspace][@intCast(new_fd)] = source;
            workspace_stdio_cloexec[workspace][@intCast(new_fd)] = false;
            // stdio aliases belong to the workspace descriptor table, not to
            // the thread that happened to perform dup2. Publish the same
            // endpoint to every live thread in this process workspace.
            for (&user_threads) |*peer| {
                if (peer.workspace_id != workspace) continue;
                peer.stdio_cloexec[@intCast(new_fd)] = false;
                peer.stdio_sockets[@intCast(new_fd)] = source;
            }
            if (workspace_socket_aliases[workspace][source] != std.math.maxInt(u8))
                workspace_socket_aliases[workspace][source] += 1;
            if (workspace_socket_ref_counts[workspace][source] != std.math.maxInt(u16))
                workspace_socket_ref_counts[workspace][source] += 1;
            return new_fd;
        }
        if (new_fd >= 3)
            return installSocketAliasAt(current_thread, source, new_fd) orelse errno(24);
    }
    return vfs.duplicate(@intCast(old_fd), @intCast(new_fd)) catch |err| vfsError(err);
}

fn fcntl(fd: u64, command: u64, argument: u64) u64 {
    if (socketIndex(fd)) |index| {
        if (command == 0 or command == 1030) {
            const duplicate_minimum = if (command == 1030) @max(argument, socket_fd_base + sockets.len) else @max(argument, socket_fd_base);
            return allocateSocketAlias(current_thread, index, duplicate_minimum, command == 1030) orelse errno(24);
        }
        if (socketAliasForThread(current_thread, fd)) |alias| {
            if (command == 1) return @intFromBool(alias.close_on_exec);
            if (command == 2) {
                if ((argument & ~@as(u64, 1)) != 0) return errno(22);
                const cloexec = (argument & 1) != 0;
                const workspace = user_threads[current_thread].workspace_id;
                // Aliases are one workspace descriptor table, even though
                // each cooperative thread keeps a local cache.  Publishing
                // F_SETFD only to the caller leaves a sibling's fork with a
                // stale CLOEXEC bit and keeps receive-pack pipes open after
                // exec. Update every cache and the canonical workspace entry.
                for (&user_threads) |*peer| {
                    if (peer.workspace_id != workspace) continue;
                    for (&peer.socket_fd_aliases) |*peer_alias| {
                        if (peer_alias.used and peer_alias.fd == alias.fd and
                            peer_alias.socket_index == alias.socket_index)
                            peer_alias.close_on_exec = cloexec;
                    }
                }
                for (&workspace_fd_aliases[workspace]) |*workspace_alias| {
                    if (workspace_alias.used and workspace_alias.fd == alias.fd and
                        workspace_alias.socket_index == alias.socket_index)
                        workspace_alias.close_on_exec = cloexec;
                }
                return 0;
            }
            if (command == 3) return @as(u64, 2) | if (sockets[index].nonblocking) @as(u64, 0x800) else 0;
            if (command == 4) { if ((argument & ~@as(u64, 0x8802)) != 0) return errno(22); sockets[index].nonblocking = (argument & 0x800) != 0; return 0; }
            return errno(22);
        }
        if (fd < 3 and command == 1) return @intFromBool(user_threads[current_thread].stdio_cloexec[@intCast(fd)]);
        if (fd < 3 and command == 2) {
            if ((argument & ~@as(u64, 1)) != 0) return errno(22);
            const workspace = user_threads[current_thread].workspace_id;
            const cloexec = (argument & 1) != 0;
            workspace_stdio_cloexec[workspace][@intCast(fd)] = cloexec;
            for (&user_threads) |*peer| {
                if (peer.workspace_id == workspace) peer.stdio_cloexec[@intCast(fd)] = cloexec;
            }
            return 0;
        }
        return switch (command) {
        1 => @intFromBool(if (fd >= socket_fd_base) user_threads[current_thread].direct_socket_cloexec[index] else sockets[index].close_on_exec),
        2 => blk: {
            if ((argument & ~@as(u64, 1)) != 0) break :blk errno(22);
            if (fd >= socket_fd_base) {
                const cloexec = (argument & 1) != 0;
                const workspace = user_threads[current_thread].workspace_id;
                workspace_socket_cloexec[workspace][index] = cloexec;
                for (&user_threads) |*peer| {
                    if (peer.workspace_id == workspace) peer.direct_socket_cloexec[index] = cloexec;
                }
            } else {
                sockets[index].close_on_exec = (argument & 1) != 0;
            }
            break :blk 0;
        },
        // Sockets are opened read/write.  Linux exposes that access mode in
        // F_GETFL even when no mutable status flags are set; omitting it makes
        // runtimes misclassify a connected descriptor as write-only.
        3 => @as(u64, 2) | if (sockets[index].nonblocking) @as(u64, 0x800) else 0,
        4 => blk: {
            // Access mode is immutable, while O_NONBLOCK is the status bit
            // that this kernel can change for a socket.
            // Linux may include O_LARGEFILE in the status word even though
            // it is immutable/irrelevant on this 64-bit kernel.
            if ((argument & ~@as(u64, 0x8802)) != 0) break :blk errno(22);
            sockets[index].nonblocking = (argument & 0x800) != 0;
            break :blk 0;
        },
        else => errno(22),
        };
    }
    return switch (command) {
        0, 1030 => blk: {
            const copy = vfs.duplicateMinimum(@intCast(fd), @intCast(argument)) catch |err| break :blk vfsError(err);
            if (command == 1030) vfs.setDescriptorFlags(copy, 1) catch |err| break :blk vfsError(err);
            break :blk copy;
        },
        1 => vfs.descriptorFlags(@intCast(fd)) catch |err| vfsError(err),
        2 => blk: {
            vfs.setDescriptorFlags(@intCast(fd), @truncate(argument)) catch |err| break :blk vfsError(err);
            break :blk 0;
        },
        3 => if (vfs.isDiskFile(@intCast(fd))) 2 else 0,
        4 => if (vfs.isDiskFile(@intCast(fd))) 0 else 0,
        else => errno(22),
    };
}

fn ioctl(fd: u64, request: u32, address: u64) u64 {
    if (vfs.isFramebuffer(@intCast(fd))) {
        const result = switch (request) {
            0x4600 => framebufferVariable(address),
            0x4602 => framebufferFixed(address),
            else => errno(25),
        };
        if (result == 0) framebuffer_ioctls = saturatingCount(framebuffer_ioctls, 1);
        return result;
    }
    if (vfs.isDrm(@intCast(fd))) {
        const render = vfs.isDrmRender(@intCast(fd));
        const result = switch (request) {
            0xc0406400 => drmVersion(address),
            0xc010640c => drmGetCap(address),
            0x4010640d => drmSetClientCap(address),
            0x40086409 => drmGemClose(address),
            0xc02064b2 => if (render) errno(25) else drmCreateDumb(address),
            0xc01064b3 => if (render) errno(25) else drmMapDumb(address),
            0xc00464b4 => if (render) errno(25) else drmDestroyDumb(address),
            0xc01064b5 => if (render) errno(25) else drmGetPlaneResources(address),
            0xc02064b6 => if (render) errno(25) else drmGetPlane(address),
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
        if (result == 0) drm_ioctls = saturatingCount(drm_ioctls, 1);
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

fn drmSetClientCap(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    const capability = read64(input);
    const value = read64(input + 8);
    if (value > 1) return errno(22);
    return switch (capability) {
        1, 4 => 0,
        2, 3 => if (value == 0) 0 else errno(95),
        else => errno(22),
    };
}

pub fn validateDrmKmsClientCapSelfTest() !void {
    var memory: [128]u8 align(8) = .{0} ** 128;
    configure(@intFromPtr(&memory), memory.len, 0, 0,
        @intFromPtr(&memory) + memory.len, @intFromPtr(&memory) + memory.len,
        @intFromPtr(&memory), @intFromPtr(&memory) + memory.len);
    const input: [*]u8 = &memory;
    put64(input, 1); put64(input + 8, 1);
    if (drmSetClientCap(@intFromPtr(input)) != 0) return error.DrmStereoClientCapRejected;
    put64(input, 4); put64(input + 8, 1);
    if (drmSetClientCap(@intFromPtr(input)) != 0) return error.DrmAspectRatioClientCapRejected;
    put64(input, 2); put64(input + 8, 0);
    if (drmSetClientCap(@intFromPtr(input)) != 0) return error.DrmUniversalPlanesDisableRejected;
    put64(input + 8, 1);
    if (drmSetClientCap(@intFromPtr(input)) != errno(95)) return error.DrmUniversalPlanesEnabledWithoutAbi;
    put64(input, 3);
    if (drmSetClientCap(@intFromPtr(input)) != errno(95)) return error.DrmAtomicEnabledWithoutAbi;
    put64(input, 99); put64(input + 8, 0);
    if (drmSetClientCap(@intFromPtr(input)) != errno(22)) return error.DrmUnknownClientCapAccepted;
    put64(input, 1); put64(input + 8, 2);
    if (drmSetClientCap(@intFromPtr(input)) != errno(22)) return error.DrmInvalidClientCapValueAccepted;
    if (drmSetClientCap(@intFromPtr(input) + memory.len - 8) != errno(14))
        return error.DrmClientCapInvalidPointerAccepted;
    @memset(input[16..128], 0);
    put64(input + 16, @intFromPtr(input + 32));
    put32(input + 24, 1);
    if (drmGetPlaneResources(@intFromPtr(input + 16)) != 0 or
        read32(input + 24) != 1 or read32(input + 32) != 5)
        return error.DrmPlaneResourcesAbiMismatch;
    @memset(input[40..72], 0);
    put32(input + 40, 5);
    put32(input + 60, 1);
    put64(input + 64, @intFromPtr(input + 80));
    if (drmGetPlane(@intFromPtr(input + 40)) != 0 or read32(input + 44) != 1 or
        read32(input + 52) != 1 or read32(input + 60) != 1 or
        read32(input + 80) != 0x34325258)
        return error.DrmPrimaryPlaneAbiMismatch;
    put32(input + 40, 6);
    if (drmGetPlane(@intFromPtr(input + 40)) != errno(2)) return error.DrmUnknownPlaneAccepted;
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
    const pitch = std.math.mul(u64, width, 4) catch return errno(12);
    if (pitch > std.math.maxInt(u32)) return errno(12);
    const size = std.math.mul(u64, pitch, height) catch return errno(12);
    if (size > framebuffer.size) return errno(12);
    const page_count = pageCountForBytes(size) catch return errno(12);
    const pages = drm_pages orelse return errno(19);
    const allocation = pages.allocate(page_count) orelse return errno(12);
    if (allocation >= (@as(u64, 1) << 44) or page_count > ((@as(u64, 1) << 44) - allocation) / 4096) {
        pages.release(allocation, page_count) catch {};
        return errno(12);
    }
    const memory: [*]u8 = @ptrFromInt(allocation);
    const allocation_bytes = bytesForPages(page_count) catch return errno(12);
    @memset(memory[0..@intCast(allocation_bytes)], 0);
    const handle: u32 = @intCast(object_index + 1);
    put32(output + 16, handle);
    put32(output + 20, @intCast(pitch));
    put64(output + 24, size);
    drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = allocation, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride };
    drm_allocations = saturatingCount(drm_allocations, 1);
    return 0;
}

fn amdgpuGemCreate(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    const io: [*]u8 = @ptrFromInt(address);
    const size = read64(io);
    const requested_alignment = read64(io + 8);
    const alignment = @max(@as(u64, 4096), requested_alignment);
    const domains = read64(io + 16);
    const flags = read64(io + 24);
    if (size == 0 or size > drm_object_stride or (requested_alignment != 0 and (requested_alignment & (requested_alignment - 1)) != 0)) return errno(22);
    if (domains == 0 or (domains & ~@as(u64, 0x7)) != 0 or (flags & ~amdgpu_gem_create_supported) != 0) return errno(95);
    if ((flags & (amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access)) ==
        (amdgpu_gem_create_cpu_access_required | amdgpu_gem_create_no_cpu_access) or
        (flags & amdgpu_gem_create_vm_always_valid) != 0 and (domains & 0x6) == 0) return errno(22);
    var free_index: ?usize = null;
    for (drm_objects, 0..) |object, index| if (!object.allocated) { free_index = index; break; };
    const object_index = free_index orelse return errno(12);
    const page_count = pageCountForBytes(size) catch return errno(12);
    if ((domains & 0x4) != 0) if (amdgpu_vram_endpoint) |endpoint| {
        const allocation_bytes = bytesForPages(page_count) catch return errno(12);
        const allocation = endpoint.allocate(endpoint.context, allocation_bytes, alignment) catch null;
        if (allocation) |vram| {
            const memory: [*]u8 = @ptrFromInt(vram.cpu_address);
            @memset(memory[0..@intCast(vram.bytes)], 0);
            const handle: u32 = @intCast(object_index + 1);
            drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = vram.cpu_address, .gpu_address = vram.mc_address, .vram_backed = true, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride, .alignment = alignment, .domains = 0x4, .allocation_flags = flags };
            put32(io, handle);
            put32(io + 4, 0);
            drm_allocations = saturatingCount(drm_allocations, 1);
            return 0;
        }
        if ((domains & 0x3) == 0) return errno(12);
    } else if ((domains & 0x3) == 0) return errno(19);
    const pages = drm_pages orelse return errno(19);
    const allocation = pages.allocateAligned(page_count, alignment) orelse return errno(12);
    if (allocation >= (@as(u64, 1) << 44) or page_count > ((@as(u64, 1) << 44) - allocation) / 4096) {
        pages.release(allocation, page_count) catch {};
        return errno(12);
    }
    const memory: [*]u8 = @ptrFromInt(allocation);
    const allocation_bytes = bytesForPages(page_count) catch return errno(12);
    @memset(memory[0..@intCast(allocation_bytes)], 0);
    const handle: u32 = @intCast(object_index + 1);
    drm_objects[object_index] = .{ .allocated = true, .handle_open = true, .handle = handle, .size = size, .physical_address = allocation, .gpu_address = allocation, .pages = page_count, .map_offset = @as(u64, @intCast(object_index)) * drm_object_stride, .alignment = alignment, .domains = domains & 0x3, .allocation_flags = flags };
    put32(io, handle);
    put32(io + 4, 0);
    drm_allocations = saturatingCount(drm_allocations, 1);
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
    if (chunk_count == 0 or chunk_count > gpu.max_amd_gfx11_submission_ibs + 8 or read32(io + 12) != 0) return errno(95);
    const chunk_pointers_address = read64(io + 16);
    if (!validUserSlice(chunk_pointers_address, @as(u64, chunk_count) * 8)) return errno(14);
    const chunk_pointers: [*]const u8 = @ptrFromInt(chunk_pointers_address);
    var ibs: [gpu.max_amd_gfx11_submission_ibs]gpu.AmdGfx11IndirectBuffer = undefined;
    var ib_count: usize = 0;
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
            if (ib_count == ibs.len or length_dw != 8 or !validUserSlice(data_address, 32)) return errno(95);
            const ib: [*]const u8 = @ptrFromInt(data_address);
            const flags = read32(ib + 4);
            const gpu_va = read64(ib + 8);
            const ib_bytes = read32(ib + 16);
            if (read32(ib) != 0 or flags != 0 or gpu_va == 0 or (gpu_va & 3) != 0 or
                ib_bytes == 0 or (ib_bytes & 3) != 0 or ib_bytes > 0x003ffffc or
                read32(ib + 20) != 0 or read32(ib + 24) != 0 or read32(ib + 28) != 0)
                return errno(95);
            ibs[ib_count] = .{ .address = gpu_va, .dwords = ib_bytes / 4 };
            ib_count += 1;
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
    if (ib_count == 0) return errno(95);
    if (drm_vm_vmid == 0) return errno(22);
    for (ibs[0..ib_count]) |ib|
        if (!amdgpuBoListCoversGpuVa(list orelse &inline_list, ib.address, ib.dwords * 4)) return errno(22);
    const endpoint = amdgpu_cs_endpoint orelse return errno(95);
    if (context.next_handle == ~@as(u64, 0)) return errno(75);
    const hardware_sequence = endpoint.submit(endpoint.context, drm_vm_vmid, ibs[0..ib_count]) catch |err| return switch (err) {
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
    try physical.validateAlignedAllocationSelfTest();
    try validateAmdGpuGemAlignmentSelfTest();
    try vfs.validateDrmPciIdentitySelfTest();
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
    configureAmdGpuInfoProfile(.{ .pci_device = 0, .pci_revision = 0, .chip_revision = 0, .external_revision = 0, .family = 145, .gfx_major = 11, .gfx_minor = 0, .gfx_revision = 2, .topology = test_topology, .cu_info = test_cu_info, .gb_addr_config = 0x04180383, .clocks = test_clocks, .pcie_generation = 4, .pcie_width = 16, .vm_info = test_vm_info, .vram_info = test_vram_info, .cache_info = test_cache_info, .mall_size = 96 * 1024 * 1024 });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0) return error.AmdGpuHwIpAcceptedInvalidPhysicalProfile;
    configureAmdGpuInfoProfile(.{ .pci_device = 0x744c, .pci_revision = 0xc8, .chip_revision = 3, .external_revision = 0x13, .family = 145, .gfx_major = 11, .gfx_minor = 0, .gfx_revision = 2, .topology = test_topology, .cu_info = test_cu_info, .gb_addr_config = 0x04180383, .clocks = test_clocks, .pcie_generation = 4, .pcie_width = 16, .vm_info = test_vm_info, .vram_info = test_vram_info, .cache_info = test_cache_info, .mall_size = 96 * 1024 * 1024 });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 1) return error.AmdGpuHwIpCountAbiMismatch;
    put32(base + 572, 4);
    put32(base + 576, gpu.amd_gfx11_gb_addr_config_offset / 4);
    put32(base + 580, 1);
    put32(base + 584, 0xffffffff);
    put32(base + 588, 0);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0x04180383)
        return error.AmdGpuGbAddrConfigMmrAbiMismatch;
    put32(base + 576, 0);
    if (amdgpuInfo(@intFromPtr(base + 560)) != errno(22)) return error.AmdGpuArbitraryMmrReadAccepted;
    put32(base + 568, 40);
    put32(base + 572, 2);
    put32(base + 576, 0);
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
    put32(base + 568, 4);
    put32(base + 572, 0);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0)
        return error.AmdGpuAccelerationLeakedWithoutReadinessCallback;
    configureAmdGpuCsEndpoint(.{ .context = &endpoint_cookie, .submit = &amdgpuAbiTestSubmit, .acceleration_ready = &amdgpuAbiTestAccelerationReady });
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0)
        return error.AmdGpuAccelerationLeakedBeforePhysicalTest;
    endpoint_cookie = 1;
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 1)
        return error.AmdGpuAccelerationReadyNotReported;
    const saved_firmware = amdgpu_firmware_profile;
    amdgpu_firmware_profile = null;
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0)
        return error.AmdGpuAccelerationLeakedWithoutFirmware;
    amdgpu_firmware_profile = saved_firmware;
    endpoint_cookie = 0;
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0)
        return error.AmdGpuAccelerationStaleAfterQueueLoss;
    configureAmdGpuCsEndpoint(null);
    if (amdgpuInfo(@intFromPtr(base + 560)) != 0 or read32(base + 608) != 0)
        return error.AmdGpuAccelerationStaleAfterEndpointRemoval;
    configureAmdGpuCsEndpoint(.{ .context = &endpoint_cookie, .submit = &amdgpuAbiTestSubmit });
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
    put64(base + 2136, 0);
    put64(base + 2144, 0x4010);
    put32(base + 2152, 16);
    put32(base + 2156, 0);
    put32(base + 2160, 0);
    put32(base + 2164, 0);
    put32(base + 2176, 1);
    put32(base + 2180, 8);
    put64(base + 2184, @intFromPtr(base + 2136));
    put64(base + 2112, @intFromPtr(base + 128));
    put64(base + 2120, @intFromPtr(base + 2176));
    put64(base + 2128, @intFromPtr(base + 2096));
    put32(base + 168, 3);
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

pub fn validateAmdGpuGttAlignmentSelfTest(storage: []u8) !void {
    const start = @intFromPtr(storage.ptr);
    if (storage.len < 4 * 1024 * 1024 or (start & 0x1fffff) != 0 or start >= (@as(u64, 1) << 44))
        return error.InvalidGttTestStorage;
    var io: [128]u8 = .{0} ** 128;
    const base: [*]u8 = &io;
    configure(@intFromPtr(base), io.len, 0, 0, 0, 0, 0, 0);
    var pages = physical.Allocator{ .range_count = 1, .free_pages = 1023 };
    pages.ranges[0] = .{ .next = start + 4096, .end = start + 4 * 1024 * 1024 };
    configureDrmMemory(&pages);
    // All of this tiny VRAM aperture belongs to scanout, forcing the actual
    // allocator failure branch (not simply an absent VRAM endpoint).
    var vram = try gpu.AmdVramAllocator.init(.{
        .cpu_start = start, .cpu_end = start + 4095, .mc_start = 0x100000,
        .mc_end = 0x100fff, .bytes = 4096,
        .framebuffer_mc_start = 0x100000, .framebuffer_mc_end = 0x100fff,
    });
    vram.sealFirmwareMap();
    configureAmdGpuVramEndpoint(.{ .context = &vram, .allocate = &amdgpuAbiTestVramAllocate,
        .release = &amdgpuAbiTestVramRelease, .reserved_bytes = &amdgpuAbiTestVramReserved,
        .largest_free_bytes = &amdgpuAbiTestVramLargestFree });
    defer {
        releaseAllDrmObjects();
        drm_pages = null;
        amdgpu_vram_endpoint = null;
    }
    for ([_]u64{ 2, 6 }) |domain| {
        @memset(storage[4096..], 0xa5);
        put64(base, 8192);
        put64(base + 8, 0x200000);
        put64(base + 16, domain);
        put64(base + 24, amdgpu_gem_create_cpu_gtt_uswc);
        if (amdgpuGemCreate(@intFromPtr(base)) != 0) return error.AlignedGttCreateFailed;
        const handle = read32(base);
        const object = &drm_objects[handle - 1];
        if (object.vram_backed or object.physical_address != start + 0x200000 or object.gpu_address != object.physical_address or
            object.alignment != 0x200000 or object.domains != 2 or pages.free_pages != 1021)
            return error.AlignedGttBackingMismatch;
        for (storage[0x200000..0x202000]) |byte| if (byte != 0) return error.AlignedGttNotCleared;
        if (storage[0x1fffff] != 0xa5 or storage[0x202000] != 0xa5) return error.AlignedGttPaddingModified;
        put32(base + 32, handle);
        put32(base + 36, 0);
        put64(base + 40, @intFromPtr(base + 64));
        if (amdgpuGemOp(@intFromPtr(base + 32)) != 0 or read64(base + 72) != 0x200000 or read64(base + 80) != 2)
            return error.AlignedGttGemOpMismatch;
        put64(base, 8192);
        if (amdgpuGemCreate(@intFromPtr(base)) != errno(12) or pages.free_pages != 1021)
            return error.AlignedGttExhaustionMismatch;
        if (drmGemClose(@intFromPtr(base + 32)) != 0 or pages.free_pages != 1023 or pages.returned_count != 0 or
            pages.ranges[0].next != start + 4096 or vram.reservedBytes() != 4096)
            return error.AlignedGttReleaseMismatch;
    }
}

fn validateAmdGpuGemAlignmentSelfTest() !void {
    var storage: [16384]u8 align(4096) = undefined;
    var io: [128]u8 = .{0} ** 128;
    const base: [*]u8 = &io;
    configure(@intFromPtr(base), io.len, 0, 0, 0, 0, 0, 0);
    var allocator = try gpu.AmdVramAllocator.init(.{
        .cpu_start = @intFromPtr(&storage), .cpu_end = @intFromPtr(&storage) + storage.len - 1,
        .mc_start = 0x1ff000, .mc_end = 0x202fff, .bytes = storage.len,
        .framebuffer_mc_start = 0x1ff000, .framebuffer_mc_end = 0x1fffff,
    });
    allocator.sealFirmwareMap();
    configureAmdGpuVramEndpoint(.{ .context = &allocator, .allocate = &amdgpuAbiTestVramAllocate,
        .release = &amdgpuAbiTestVramRelease, .reserved_bytes = &amdgpuAbiTestVramReserved,
        .largest_free_bytes = &amdgpuAbiTestVramLargestFree });
    defer { amdgpu_vram_endpoint = null; drm_objects = .{DrmObject{}} ** max_drm_objects; }
    put64(base, 4096);
    put64(base + 8, 0x200000);
    put64(base + 16, 4);
    put64(base + 24, amdgpu_gem_create_discardable);
    if (amdgpuGemCreate(@intFromPtr(base)) != 0) return error.AmdGpuAlignedVramCreateFailed;
    const handle = read32(base);
    const object = &drm_objects[handle - 1];
    if (!object.vram_backed or object.gpu_address != 0x200000 or object.alignment != 0x200000)
        return error.AmdGpuAlignedVramAddressMismatch;
    put32(base + 32, handle);
    put32(base + 36, 0);
    put64(base + 40, @intFromPtr(base + 64));
    if (amdgpuGemOp(@intFromPtr(base + 32)) != 0 or read64(base + 72) != 0x200000)
        return error.AmdGpuAlignedGemOpMismatch;
    put64(base, 4096);
    if (amdgpuGemCreate(@intFromPtr(base)) != errno(12)) return error.AmdGpuAlignedVramExhaustionMismatch;
    put32(base + 32, handle);
    if (drmGemClose(@intFromPtr(base + 32)) != 0 or allocator.reservedBytes() != 4096)
        return error.AmdGpuAlignedVramReleaseFailed;
    put64(base, 4096);
    put64(base + 8, 6000);
    if (amdgpuGemCreate(@intFromPtr(base)) != errno(22) or allocator.reservedBytes() != 4096)
        return error.AmdGpuInvalidAlignmentAccepted;
    put64(base + 8, 64);
    if (amdgpuGemCreate(@intFromPtr(base)) != 0) return error.AmdGpuSmallAlignmentNotNormalized;
    put32(base + 32, read32(base));
    if (drm_objects[read32(base) - 1].alignment != 4096 or drmGemClose(@intFromPtr(base + 32)) != 0)
        return error.AmdGpuNormalizedAlignmentMismatch;
}

fn amdgpuBoListCoversGpuVa(list: *const AmdGpuBoList, address: u64, size: u32) bool {
    if (address >= (@as(u64, 1) << 48) or size > (@as(u64, 1) << 48) - address) return false;
    const vm = &drm_vm_manager.vms[drm_vm_vmid - 1];
    var cursor = address;
    const end = address + size;
    while (cursor < end) {
        var covered: ?gpu.AmdGpuVaMapping = null;
        for (&vm.mappings) |*mapping| if (mapping.active and cursor >= mapping.address and cursor - mapping.address < 4096) {
            covered = mapping.*;
            break;
        };
        const mapping = covered orelse return false;
        if ((mapping.flags & 0x2) == 0) return false;
        if (!amdgpuBoIsResident(list, mapping.handle)) return false;
        const next_page = std.math.add(u64, mapping.address, 4096) catch return false;
        if (next_page <= cursor) return false;
        cursor = @min(end, next_page);
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
    for (&drm_vm_manager.vms[drm_vm_vmid - 1].mappings) |*mapping| if (mapping.active) {
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
    if (va_address > std.math.maxInt(u64) - (map_size - 1) or object.gpu_address > std.math.maxInt(u64) - bo_offset)
        return errno(22);

    if (operation == 1) {
        if (flags == 0 or (flags & ~@as(u32, 0x0e)) != 0) return errno(95);
        _ = ensureAmdGpuVm() catch |err| return amdGpuVmErrno(err);
        var mapped: u64 = 0;
        while (mapped < map_size) : (mapped += @min(@as(u64, 4096), map_size - mapped)) {
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
    while (checked < map_size) : (checked += @min(@as(u64, 4096), map_size - checked)) {
        const page_flags = validateAmdGpuObjectPage(object, handle, va_address + checked, bo_offset + checked) catch |err| return amdGpuVmErrno(err);
        if (mapped_flags) |expected| {
            if (page_flags != expected) return errno(22);
        } else mapped_flags = page_flags;
    }
    const page_flags = mapped_flags orelse return errno(2);
    var unmapped: u64 = 0;
    while (unmapped < map_size) : (unmapped += @min(@as(u64, 4096), map_size - unmapped)) {
        unmapAmdGpuObjectPage(object, va_address + unmapped, bo_offset + unmapped, page_flags) catch |err|
            return amdGpuVmErrno(err);
    }
    syncAmdGpuVmAfterUnmap() catch |err| {
        var restore: u64 = 0;
        while (restore < unmapped) : (restore += @min(@as(u64, 4096), unmapped - restore)) mapAmdGpuObjectPage(
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
        profile.?.mall_size != 0 and profile.?.gb_addr_config != 0 and
        profile.?.clocks.counter_khz != 0 and profile.?.clocks.max_engine_khz != 0 and profile.?.clocks.max_memory_khz != 0 and
        profile.?.pci_device != 0 and profile.?.pci_device != 0xffff and profile.?.gfx_major == 11 and
        profile.?.topology.num_shader_engines != 0 and profile.?.topology.num_shader_arrays_per_engine != 0 and
        profile.?.topology.maxCuPerShaderArray() != 0 and profile.?.topology.max_gprs != 0 and profile.?.topology.max_gs_threads != 0;
    if (query == 0) {
        const count = @min(return_size, 4);
        if (!validUserSlice(return_address, count)) return errno(14);
        const output: [*]u8 = @ptrFromInt(return_address);
        @memset(output[0..count], 0);
        // libdrm checks this before it can initialize RADV. It means the
        // acceleration backend is operational, not that Vulkan is certified.
        if (gfx_available and drm_pages != null and amdgpu_vram_endpoint != null) {
            if (amdgpu_memory_profile) |memory| if (amdgpu_firmware_profile) |firmware| {
                const endpoint = amdgpu_cs_endpoint.?;
                if (memory.vram_bytes != 0 and memory.visible_vram_bytes != 0 and
                    memory.visible_vram_bytes <= memory.vram_bytes and memory.reserved_vram_bytes <= memory.visible_vram_bytes and
                    firmware.me.version != 0 and firmware.mec.version != 0 and firmware.pfp.version != 0) {
                    if (endpoint.acceleration_ready) |ready| output[0] = @intFromBool(ready(endpoint.context));
                }
            };
        }
        return 0;
    }
    if (query == 4) {
        if (!gfx_available) return errno(19);
        const dword_offset = read32(input + 16);
        const count = read32(input + 20);
        const instance = read32(input + 24);
        const flags = read32(input + 28);
        if (dword_offset != gpu.amd_gfx11_gb_addr_config_offset / 4 or count != 1 or
            instance != 0xffffffff or flags != 0 or return_size != 4)
            return errno(22);
        if (!validUserSlice(return_address, 4)) return errno(14);
        const output: [*]u8 = @ptrFromInt(return_address);
        put32(output, profile.?.gb_addr_config);
        return 0;
    }
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
            if (!object.vram_backed) {
                const object_bytes = bytesForPages(object.pages) catch return errno(12);
                gtt_usage = std.math.add(u64, gtt_usage, object_bytes) catch return errno(12);
            }
        };
        const gtt_free = bytesForPages(pages.free_pages) catch return errno(12);
        const gtt_total = std.math.add(u64, gtt_free, gtt_usage) catch return errno(12);
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
    if (drm_vm_vmid != 0) for (&drm_vm_manager.vms[drm_vm_vmid - 1].mappings) |*mapping|
        if (mapping.active and mapping.handle == handle) return errno(16);
    object.handle_open = false;
    if (!object.framebuffer_reference) releaseDrmObject(object);
    return 0;
}

fn releaseDrmObject(object: *DrmObject) void {
    if (object.allocated and object.physical_address != 0 and object.pages != 0) {
        if (object.vram_backed) {
            if (amdgpu_vram_endpoint) |endpoint| {
                if (bytesForPages(object.pages)) |bytes| {
                    endpoint.release(endpoint.context, .{ .cpu_address = object.physical_address, .mc_address = object.gpu_address, .bytes = bytes }) catch {};
                } else |_| {}
            }
        } else if (drm_pages) |pages| pages.release(object.physical_address, object.pages) catch {};
        drm_releases = saturatingCount(drm_releases, 1);
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
        for (&vm.mappings) |*mapping| if (mapping.active) {
            active = mapping.*;
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
    drm_vm_manager.dematerialize(drm_vm_vmid) catch |err| {
        serial.write("DRM VM cleanup failed: "); serial.write(@errorName(err)); serial.write("\n");
        return;
    };
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

fn drmGetPlaneResources(address: u64) u64 {
    if (!validUserSlice(address, 16)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    const ids = read64(output);
    const capacity = read32(output + 8);
    if (!putDrmId(ids, capacity, 5)) return errno(14);
    put32(output + 8, 1);
    put32(output + 12, 0);
    return 0;
}

fn drmGetPlane(address: u64) u64 {
    if (!validUserSlice(address, 32)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    if (read32(output) != 5) return errno(2);
    const formats = read64(output + 24);
    const capacity = read32(output + 20);
    if (capacity != 0) {
        if (formats == 0 or !validUserSlice(formats, 4)) return errno(14);
        const format_output: [*]u8 = @ptrFromInt(formats);
        put32(format_output, 0x34325258);
    }
    put32(output + 4, 1);
    put32(output + 8, drm_scanout_framebuffer);
    put32(output + 12, 1);
    put32(output + 16, 0);
    put32(output + 20, 1);
    return 0;
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
    if (!drmModeDimensionsFit()) return errno(22);
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
    if (!drmModeDimensionsFit()) return errno(22);
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
    const expected_pitch = std.math.mul(u32, width, 4) catch return errno(12);
    if (pitch != expected_pitch or read32(output + 16) != 32 or read32(output + 20) != 24) return errno(22);
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

fn drmModeDimensionsFit() bool {
    return framebuffer.width <= std.math.maxInt(u16) and framebuffer.height <= std.math.maxInt(u16);
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

fn unlinkat(directory_fd: u64, path_address: u64, flags: u64) u64 {
    if ((flags & ~@as(u64, 0x200)) != 0) return errno(22);
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    if ((flags & 0x200) != 0) {
        vfs.rmdirAt(@bitCast(directory_fd), path) catch |err| return vfsError(err);
        return 0;
    }
    vfs.unlinkAt(@bitCast(directory_fd), path) catch |err| return vfsError(err);
    return 0;
}

fn mkdirat(directory_fd: u64, path_address: u64, mode: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    vfs.mkdirAt(@bitCast(directory_fd), path, mode) catch |err| return vfsError(err);
    return 0;
}

fn mkdirLegacy(path_address: u64, mode: u64) u64 {
    return mkdirat(@bitCast(@as(i64, -100)), path_address, mode);
}

fn renameLegacy(old_path_address: u64, new_path_address: u64) u64 {
    return renameat(@bitCast(@as(i64, -100)), old_path_address, new_path_address, 0);
}

fn rmdirLegacy(path_address: u64) u64 {
    return unlinkat(@bitCast(@as(i64, -100)), path_address, 0x200);
}

fn unlinkLegacy(path_address: u64) u64 {
    return unlinkat(@bitCast(@as(i64, -100)), path_address, 0);
}

fn linkLegacy(old_path_address: u64, new_path_address: u64) u64 {
    var old_buffer: [256]u8 = undefined;
    var new_buffer: [256]u8 = undefined;
    const old_path = userString(old_path_address, &old_buffer) orelse return errno(14);
    const new_path = userString(new_path_address, &new_buffer) orelse return errno(14);
    vfs.linkAt(-100, old_path, -100, new_path) catch |err| return vfsError(err);
    return 0;
}

fn linkat(old_directory_fd: u64, old_path_address: u64, new_directory_fd: u64, new_path_address: u64, flags: u64) u64 {
    if (flags != 0) return errno(22);
    var old_buffer: [256]u8 = undefined;
    var new_buffer: [256]u8 = undefined;
    const old_path = userString(old_path_address, &old_buffer) orelse return errno(14);
    const new_path = userString(new_path_address, &new_buffer) orelse return errno(14);
    vfs.linkAt(@bitCast(old_directory_fd), old_path, @bitCast(new_directory_fd), new_path) catch |err| return vfsError(err);
    return 0;
}

fn symlinkLegacy(target_address: u64, link_address: u64) u64 {
    // FAT bootstrap storage has no symlink inode yet. Report the real
    // capability boundary so Git can use its regular-file fallback.
    _ = target_address;
    _ = link_address;
    return errno(95);
}

fn creatLegacy(path_address: u64, mode: u64) u64 {
    _ = mode;
    return openat(@bitCast(@as(i64, -100)), path_address, 0x241);
}

fn chmodLegacy(path_address: u64, mode: u64) u64 {
    _ = mode;
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    _ = vfs.infoAt(-100, path) catch |err| return vfsError(err);
    return 0;
}

fn ftruncate(fd: u64, length: u64) u64 {
    if (length > std.math.maxInt(usize)) return errno(22);
    vfs.truncate(@intCast(fd), @intCast(length)) catch |err| return vfsError(err);
    return 0;
}

fn truncatePath(path_address: u64, length: u64) u64 {
    if (length > std.math.maxInt(usize)) return errno(22);
    const fd = openat(@bitCast(@as(i64, -100)), path_address, 2);
    if (fd >= std.math.maxInt(u64) - 4096) return fd;
    const result = ftruncate(fd, length);
    vfs.close(@intCast(fd)) catch {};
    return result;
}

fn renameat(old_directory_fd: u64, old_path_address: u64, new_path_address: u64, flags: u64) u64 {
    if (flags != 0) return errno(22);
    var old_buffer: [256]u8 = undefined;
    var new_buffer: [256]u8 = undefined;
    const old_path = userString(old_path_address, &old_buffer) orelse return errno(14);
    const new_path = userString(new_path_address, &new_buffer) orelse return errno(14);
    vfs.renameAt(@bitCast(old_directory_fd), old_path, new_path) catch |err| return vfsError(err);
    return 0;
}

fn renameat2(old_directory_fd: u64, old_path_address: u64, new_directory_fd: u64, new_path_address: u64, flags: u64) u64 {
    if (new_directory_fd != old_directory_fd) return errno(18);
    return renameat(old_directory_fd, old_path_address, new_path_address, flags);
}

fn statx(directory_fd: u64, path_address: u64, flags: u64, mask: u64, output_address: u64) u64 {
    if ((flags & ~@as(u64, 0x100)) != 0 or mask == 0) return errno(22);
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    const info = vfs.infoAt(@bitCast(directory_fd), path) catch |err| return vfsError(err);
    if (!validUserSlice(output_address, 256)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(output_address);
    @memset(bytes[0..256], 0);
    // struct statx: fixed-width fields through the timestamps and device IDs.
    put32(bytes, @truncate(mask & 0x07ff)); // only requested supported fields
    put32(bytes + 4, 4096);
    put32(bytes + 16, 1); // nlink
    put32(bytes + 28, info.mode);
    put64(bytes + 32, 1); // inode
    put64(bytes + 40, info.size);
    put64(bytes + 48, (info.size + 511) / 512);
    put64(bytes + 56, 0);
    put64(bytes + 64, 0);
    put64(bytes + 80, 0);
    put64(bytes + 96, 0);
    put64(bytes + 112, 0);
    put32(bytes + 128, @truncate(info.rdev >> 32));
    put32(bytes + 132, @truncate(info.rdev));
    return 0;
}

fn access(path_address: u64, mode: u32) u64 {
    if ((mode & ~@as(u32, 7)) != 0) return errno(22);
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    _ = vfs.infoAt(-100, path) catch |err| return vfsError(err);
    // CSOS currently has one bootstrap user and no discretionary credential
    // model. Existing files therefore satisfy R_OK/W_OK/X_OK uniformly;
    // returning ENOTSUP here breaks real runtimes such as Git during config
    // discovery rather than reflecting an actual permission denial.
    return 0;
}

fn fstat(fd: u64, output_address: u64) u64 {
    if (socketIndex(fd)) |index| {
        // Pipes/socketpairs are real open-file descriptions, not console
        // descriptors. Git's unpack/index helpers fstat(0) before reading
        // the inherited transport; reporting the pipe type keeps that
        // inspection from falling through to the VFS numeric table.
        return writeStat(output_address, .{ .mode = 0o010600, .size = sockets[index].local_len, .directory = false });
    }
    if (fd <= 2) return writeStat(output_address, .{ .mode = 0o020666, .size = 0, .directory = false });
    const info = vfs.infoFd(@intCast(fd)) catch |err| return vfsError(err);
    return writeStat(output_address, info);
}

fn statfs(path_address: u64, output_address: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    _ = vfs.infoAt(-100, path) catch |err| return vfsError(err);
    return writeStatfs(output_address);
}

fn fstatfs(fd: u64, output_address: u64) u64 {
    if (socketIndex(fd) != null) return writeStatfs(output_address);
    _ = vfs.infoFd(@intCast(fd)) catch |err| return vfsError(err);
    return writeStatfs(output_address);
}

fn writeStatfs(address: u64) u64 {
    if (!validUserSlice(address, 120)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..120], 0);
    // Linux struct statfs: ext2-compatible magic, 4 KiB blocks and a
    // conservative bounded volume estimate for the current FAT backend.
    put64(bytes + 0, 0xEF53);
    put64(bytes + 8, 4096);
    put64(bytes + 16, 1024);
    put64(bytes + 24, 512);
    put64(bytes + 32, 512);
    put64(bytes + 40, 32);
    put64(bytes + 48, 0x00000000_0000ffff);
    put64(bytes + 56, 255);
    return 0;
}

fn writeStat(address: u64, info: vfs.Info) u64 {
    if (!validUserSlice(address, 144)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..144], 0);
    put64(bytes + 8, 1);
    put64(bytes + 16, 1);
    put32(bytes + 24, info.mode);
    put64(bytes + 40, info.rdev);
    put64(bytes + 48, info.size);
    put64(bytes + 56, 4096);
    put64(bytes + 64, info.size / 512 + @intFromBool(info.size % 512 != 0));
    return 0;
}

fn readlinkat(directory_fd: i64, path_address: u64, output_address: u64, length: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    if (std.mem.indexOf(u8, path, "proc/self/exe") != null or std.mem.eql(u8, path, "self/exe") or std.mem.eql(u8, path, "exe")) {
        const target = "/nix/bin/nix";
        const count = @min(length, target.len);
        if (!validUserSlice(output_address, count)) return errno(14);
        @memcpy(@as([*]u8, @ptrFromInt(output_address))[0..@intCast(count)], target[0..@intCast(count)]);
        return count;
    }
    if (!validUserSlice(output_address, length)) return errno(14);
    const output: [*]u8 = @ptrFromInt(output_address);
    return vfs.readLinkAt(directory_fd, path, output[0..@intCast(length)]) catch |err| vfsError(err);
}

fn lseek(fd: u64, raw_offset: u64, whence: u64) u64 {
    const offset: i64 = @bitCast(raw_offset);
    return vfs.seek(@intCast(fd), offset, whence) catch |err| vfsError(err);
}

fn pread64(fd: u64, address: u64, length: u64, offset: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    return vfs.pread(@intCast(fd), output[0..@intCast(length)], @intCast(offset)) catch |err| vfsError(err);
}

fn pwrite64(fd: u64, address: u64, length: u64, offset: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const input: [*]const u8 = @ptrFromInt(address);
    return vfs.pwrite(@intCast(fd), input[0..@intCast(length)], @intCast(offset)) catch |err| vfsError(err);
}

fn getdents(fd: u64, address: u64, length: u64) u64 {
    if (!validUserSlice(address, length)) return errno(14);
    const output: [*]u8 = @ptrFromInt(address);
    return vfs.getDents(@intCast(fd), output[0..@intCast(length)]) catch |err| vfsError(err);
}

fn writev(fd: u64, address: u64, count: u64) u64 {
    const bytes = std.math.mul(u64, count, 16) catch return errno(14);
    if (count > 64 or !validUserSlice(address, bytes)) return errno(14);
    var total: u64 = 0;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const item: [*]const u8 = @ptrFromInt(address + index * 16);
        const base = read64(item);
        const length = read64(item + 8);
        if (length == 0) continue;
        const result = write(fd, base, length);
        if (@as(i64, @bitCast(result)) < 0) return result;
        total += result;
        // writev is a stream operation: once an element is only partially
        // written (including a blocked socket returning zero), the caller
        // owns the remaining iovecs and must retry from this position. Do
        // not silently consume later elements or lose the tail of a Git
        // sideband/pipe frame.
        if (result != length) break;
    }
    return total;
}

fn readv(fd: u64, address: u64, count: u64) u64 {
    const bytes = std.math.mul(u64, count, 16) catch return errno(14);
    if (count > 64 or !validUserSlice(address, bytes)) return errno(14);
    var total: u64 = 0;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const item: [*]const u8 = @ptrFromInt(address + index * 16);
        const base = read64(item);
        const length = read64(item + 8);
        if (length == 0) continue;
        const result = read(fd, base, length);
        if (@as(i64, @bitCast(result)) < 0) return if (total == 0) result else total;
        total += result;
        if (result != length) break;
    }
    return total;
}

fn poll(address: u64, count: u64, timeout: i64) u64 {
    const bytes = std.math.mul(u64, count, 8) catch return errno(22);
    if (count > 64) return errno(22);
    // Linux permits poll(NULL, 0, timeout), which is useful as a sleep.
    if (count != 0 and !validUserSlice(address, bytes)) return errno(14);
    var ready: u64 = 0;
    var has_local_pair = false;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const item: [*]u8 = @ptrFromInt(address + index * 8);
        const fd = read32(item);
        const events = read16(item + 4);
        var revents: u16 = 0;
        // A negative pollfd is ignored, rather than reported as POLLNVAL.
        if (@as(i32, @bitCast(fd)) < 0) {
            revents = 0;
        } else if (fd == 0 and socketIndex(fd) == null) {
            if (stdin_hook != null and (events & 1) != 0) revents |= 1;
        } else if (socketIndex(fd)) |socket_index| {
            if (sockets[socket_index].local_pair) has_local_pair = true;
            if ((events & 1) != 0 and sockets[socket_index].connection != null) revents |= 1;
            if ((events & 1) != 0 and sockets[socket_index].local_pair and sockets[socket_index].local_len != 0) revents |= 1;
            if (sockets[socket_index].local_pair and sockets[socket_index].peer_closed) revents |= 0x10 | 1;
            if ((events & 4) != 0 and sockets[socket_index].connection != null) revents |= 4;
            if ((events & 4) != 0 and sockets[socket_index].local_pair) {
                if (sockets[socket_index].peer_index) |peer| {
                    if (sockets[peer].local_len < sockets[peer].local_buffer.len) revents |= 4;
                }
            }
        } else if (!vfs.isOpen(fd)) {
            revents = 0x20; // POLLNVAL
        } else if (vfs.isEventfd(fd)) {
            if ((events & 1) != 0) {
                var probe: [8]u8 = undefined;
                if (vfs.readEventfd(fd, &probe)) |count_read| {
                    // Restore the counter after readiness inspection.
                    _ = vfs.writeEventfd(fd, probe[0..count_read]) catch 0;
                    revents |= 1;
                } else |_| {}
            }
            if ((events & 4) != 0) revents |= 4;
        } else if (vfs.isPidfd(fd)) {
            if ((events & 1) != 0 and vfs.pidfdReady(fd)) revents |= 1;
        } else {
            if ((events & 1) != 0) revents |= 1;
            if ((events & 4) != 0) revents |= 4;
        }
        put16(item + 6, revents);
        if (revents != 0) ready += 1;
    }
    if (ready == 0 and timeout != 0) {
        if (user_threads_enabled and has_local_pair) {
            user_threads[current_thread].pending_poll_address = address;
            user_threads[current_thread].pending_poll_count = count;
            user_threads[current_thread].pending_poll_sockets = .{false} ** 32;
            var interest_index: u64 = 0;
            while (interest_index < count) : (interest_index += 1) {
                const item: [*]u8 = @ptrFromInt(address + interest_index * 8);
                const fd = read32(item);
                if (socketIndexForThread(current_thread, fd)) |socket_index|
                    user_threads[current_thread].pending_poll_sockets[socket_index] = true;
            }
            user_threads[current_thread].state = .blocked;
            thread_switch_requested = true;
            return 0;
        }
        if (user_threads_enabled) thread_switch_requested = true;
        if (idle_hook) |hook| hook();
    } else if (ready == 0 and timeout == 0 and active_user_thread == current_thread) {
        // A newly-created helper is preferred until its first real blocking
        // boundary.  A zero-timeout poll is not that boundary: clear the
        // preference so a WPE/GIO worker cannot spin forever ahead of the
        // launcher or another process that must feed its IPC channel.
        active_user_thread = null;
    }
    return ready;
}

fn ppoll(address: u64, count: u64, timespec: u64, signal_mask: u64, signal_set_size: u64) u64 {
    // x86_64 Linux exposes an eight-byte kernel sigset for ppoll.  Reject a
    // non-null mask with another size instead of silently accepting an ABI
    // layout that userspace cannot rely on.
    if (signal_mask != 0 and signal_set_size != 8) return errno(22);
    if (signal_mask != 0 and !validUserSlice(signal_mask, signal_set_size)) return errno(14);
    var timeout: i64 = 0;
    if (timespec != 0) {
        if (!validUserSlice(timespec, 16)) return errno(14);
        const value: [*]const u8 = @ptrFromInt(timespec);
        const seconds = read64(value);
        const nanoseconds = read64(value + 8);
        if (nanoseconds >= 1_000_000_000 or seconds > @as(u64, @intCast(std.math.maxInt(i64) / 1000))) return errno(22);
        timeout = if (seconds != 0 or nanoseconds != 0) 1 else 0;
    }
    return poll(address, count, timeout);
}

fn getRandom(address: u64, length: u64, flags: u64) u64 {
    // GRND_NONBLOCK, GRND_RANDOM and (since newer Linux) GRND_INSECURE.
    if ((flags & ~@as(u64, 7)) != 0) return errno(22);
    if (length == 0) return 0;
    if (!validUserSlice(address, length)) return errno(14);
    // This is a deterministic bootstrap source until a hardware entropy
    // provider is installed; it satisfies libc's ABI without claiming
    // cryptographic randomness from a machine that has not been provisioned.
    const bytes: [*]u8 = @ptrFromInt(address);
    var index: u64 = 0;
    while (index < length) : (index += 1) {
        random_state ^= random_state << 13;
        random_state ^= random_state >> 7;
        random_state ^= random_state << 17;
        bytes[index] = @truncate(random_state >> 24);
    }
    return length;
}

fn rseq(address: u64, length: u64, flags: u64, signature: u64) u64 {
    const unregister: u64 = 1;
    const registration = if (current_thread < user_threads.len)
        &user_threads[current_thread].rseq_address
    else
        return errno(3);
    if ((flags & ~unregister) != 0) return errno(22);
    if ((flags & unregister) != 0) {
        if (address != 0 or length != 0 or signature != 0 or registration.* == 0) return errno(22);
        registration.* = 0;
        return 0;
    }
    // Linux's current x86 ABI requires a 32-byte, 32-byte-aligned area.
    if (address == 0 or (address & 31) != 0 or length != 32 or !validUserSlice(address, length)) return errno(22);
    if (registration.* != 0) return errno(16);
    registration.* = address;
    return 0;
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
    const path = if (user_threads_enabled and current_thread < user_threads.len)
        user_threads[current_thread].cwd[0..user_threads[current_thread].cwd_len]
    else
        vfs.currentWorkingDirectory();
    if (size <= path.len or !validUserSlice(address, path.len + 1)) return errno(34);
    const bytes: [*]u8 = @ptrFromInt(address);
    @memcpy(bytes[0..path.len], path);
    bytes[path.len] = 0;
    // Linux getcwd returns the number of bytes copied, including the NUL.
    // Returning the user pointer makes libc/Git treat the pointer value as a
    // path length and report the current directory as invalid.
    return path.len + 1;
}

fn chdir(address: u64) u64 {
    var path: [256]u8 = undefined;
    const text = userString(address, &path) orelse return errno(14);
    vfs.changeDirectory(text) catch |err| return vfsError(err);
    const current = vfs.currentWorkingDirectory();
    const thread = &user_threads[current_thread];
    const length = @min(current.len, thread.cwd.len);
    @memcpy(thread.cwd[0..length], current[0..length]);
    thread.cwd_len = length;
    vfs.setWorkspaceDirectory(thread.workspace_id, thread.cwd[0..length]);
    return 0;
}

fn userString(address: u64, buffer: []u8) ?[]const u8 {
    var length: usize = 0;
    while (length < buffer.len) : (length += 1) {
        const offset: u64 = @intCast(length);
        if (address > std.math.maxInt(u64) - offset) return null;
        const current_address = address + offset;
        if (!validUserSlice(current_address, 1)) return null;
        const source: *const u8 = @ptrFromInt(current_address);
        if (source.* == 0) return buffer[0..length];
        buffer[length] = source.*;
    }
    return null;
}

fn vfsError(err: anyerror) u64 {
    if (err == error.WouldBlock) return errno(11);
    if (err == error.Overflow) return errno(75);
    return switch (err) { error.NotFound => errno(2), error.AlreadyExists => errno(17), error.BadFd => errno(9), error.NotDirectory => errno(20), error.TooManyFiles => errno(24), else => errno(22) };
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
    const length_usize = std.math.cast(usize, length) orelse return errno(14);
    const text: [*]const u8 = @ptrFromInt(address);
    if (vfs.isEventfd(@intCast(fd))) return vfs.writeEventfd(@intCast(fd), text[0..length_usize]) catch |err| vfsError(err);
    if (socketIndex(fd)) |index| {
        const result = socketSend(index, text[0..length_usize]);
        if (result == errno(11) and sockets[index].local_pair and !sockets[index].nonblocking and user_threads_enabled) {
            user_threads[current_thread].pending_write_socket = index;
            user_threads[current_thread].pending_write_address = address;
            user_threads[current_thread].pending_write_length = length_usize;
            user_threads[current_thread].state = .blocked;
            thread_switch_requested = true;
            return 0;
        }
        return result;
    }
    if (vfs.isDiskFile(@intCast(fd))) return vfs.write(@intCast(fd), text[0..length_usize]) catch |err| vfsError(err);
    if (!vfs.isConsole(@intCast(fd))) return errno(9);
    serial.write(text[0..length_usize]);
    if (console_write_hook) |hook| hook(text[0..length_usize]);
    if (writes != std.math.maxInt(usize)) writes += 1;
    return length;
}

const Socket = struct {
    allocated: bool = false,
    refs: u16 = 0,
    local_pair: bool = false,
    seqpacket: bool = false,
    readable: bool = true,
    writable: bool = true,
    peer_index: ?usize = null,
    // WebKit's initial page/process messages can exceed a single 4 KiB
    // transport window. Keep enough room for a complete IPC burst so the
    // SOCK_SEQPACKET compatibility path does not return a short write during
    // WebProcess initialization.
    local_buffer: [64 * 1024]u8 = .{0} ** (64 * 1024),
    local_head: usize = 0,
    local_len: usize = 0,
    packet_lengths: [64]u32 = .{0} ** 64,
    packet_head: usize = 0,
    packet_count: usize = 0,
    peer_closed: bool = false,
    read_closed: bool = false,
    write_closed: bool = false,
    close_on_exec: bool = false,
    nonblocking: bool = false,
    connection: ?net.TcpConnection = null,
    reuse_address: bool = false,
    reuse_port: bool = false,
    keep_alive: bool = false,
    linger_enabled: bool = false,
    linger_seconds: u32 = 0,
    remote_address: [4]u8 = .{0} ** 4,
    remote_port: u16 = 0,
    pending_rights: [8]usize = .{0} ** 8,
    pending_rights_len: u8 = 0,
    pending_credentials: bool = false,
    pending_credential_pid: u32 = 0,
    pending_credential_uid: u32 = 0,
    pending_credential_gid: u32 = 0,
};

fn socket(domain: u64, kind: u64, protocol: u64) u64 {
    if (domain != 2 or (kind & 0xf) != 1 or (kind & ~@as(u64, 0x80801)) != 0 or (protocol != 0 and protocol != 6)) return errno(97);
    for (&sockets, 0..) |*entry, index| {
        if (!entry.allocated and workspaceDirectSlotFree(user_threads[current_thread].workspace_id, index)) {
            entry.* = .{ .allocated = true, .refs = 1, .close_on_exec = (kind & 0x80000) != 0, .nonblocking = (kind & 0x800) != 0 };
            publishDirectSocket(current_thread, index, (kind & 0x80000) != 0);
            return socket_fd_base + index;
        }
    }
    return errno(24);
}

fn socketPair(domain: u64, kind: u64, protocol: u64, output: u64) u64 {
    // WPE/GLib ProcessLauncher uses SOCK_SEQPACKET for its local control
    // channel.  The bounded local transport preserves the same bidirectional
    // semantics while allowing the existing poll/read/write ABI to carry the
    // startup handshake.
    const socket_kind = kind & 0xf;
    if (domain != 1 or (socket_kind != 1 and socket_kind != 5) or
        (kind & ~@as(u64, 0x80805)) != 0 or protocol != 0) return errno(97);
    if (!validUserSlice(output, 8)) return errno(14);
    var first: ?usize = null;
    var second: ?usize = null;
    for (&sockets, 0..) |*entry, index| {
        if (!entry.allocated and workspaceDirectSlotFree(user_threads[current_thread].workspace_id, index)) {
            if (first == null) first = index else { second = index; break; }
        }
    }
    if (first == null or second == null) return errno(24);
    const seqpacket = socket_kind == 5;
    sockets[first.?] = .{ .allocated = true, .refs = 1, .local_pair = true, .seqpacket = seqpacket, .peer_index = second, .close_on_exec = (kind & 0x80000) != 0, .nonblocking = (kind & 0x800) != 0 };
    sockets[second.?] = .{ .allocated = true, .refs = 1, .local_pair = true, .seqpacket = seqpacket, .peer_index = first, .close_on_exec = (kind & 0x80000) != 0, .nonblocking = (kind & 0x800) != 0 };
    // AF_UNIX socketpair endpoints are full-duplex.  Unlike pipe2, both
    // descriptors must be accepted by read(2) and write(2); leaving the
    // direction bits clear makes WPE/WebKit's control and renderer channels
    // fail with EBADF before the peer can initialize.
    sockets[first.?].readable = true;
    sockets[first.?].writable = true;
    sockets[second.?].readable = true;
    sockets[second.?].writable = true;
    publishDirectSocket(current_thread, first.?, (kind & 0x80000) != 0);
    publishDirectSocket(current_thread, second.?, (kind & 0x80000) != 0);
    if (user_threads_enabled and user_threads[current_thread].kind == .process_child) {
        user_threads[current_thread].owned_socket_refs[first.?] = true;
        user_threads[current_thread].owned_socket_refs[second.?] = true;
    }
    put32(@ptrFromInt(output), @intCast(socket_fd_base + first.?));
    put32(@ptrFromInt(output + 4), @intCast(socket_fd_base + second.?));
    return 0;
}

fn eventfd2(initial: u64, flags: u64) u64 {
    // GLib/WPE uses EFD_CLOEXEC and EFD_NONBLOCK; readiness is represented by
    // the counter, while blocking waits are handled by the poll/epoll layer.
    if ((flags & ~@as(u64, 0x80800)) != 0) return errno(22);
    return vfs.openEventfd(initial) catch |err| vfsError(err);
}

fn pidfdOpen(pid: u64, flags: u64) u64 {
    if (flags != 0 or pid == 0 or pid > std.math.maxInt(u32)) return errno(22);
    const target: u32 = @intCast(pid);
    var found = false;
    for (user_threads) |thread| {
        if (thread.pid == target and thread.state != .unused and thread.state != .exited) {
            found = true;
            break;
        }
    }
    if (!found) return errno(3);
    return vfs.openPidfd(target) catch |err| vfsError(err);
}

fn connect(fd: u64, address: u64, length: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (length < 16) return errno(22);
    if (!validUserSlice(address, 16)) return errno(14);
    const bytes: [*]const u8 = @ptrFromInt(address);
    if (bytes[0] != 2 or bytes[1] != 0) return errno(97);
    const port = (@as(u16, bytes[2]) << 8) | bytes[3];
    const destination = [4]u8{ bytes[4], bytes[5], bytes[6], bytes[7] };
    const stack = network_stack orelse return errno(100);
    sockets[index].connection = stack.tcpConnect(destination, port, @intCast(49153 + index)) catch return errno(111);
    sockets[index].remote_address = destination;
    sockets[index].remote_port = port;
    return 0;
}

fn socketName(fd: u64, address: u64, length_address: u64, peer: bool) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (address == 0 or length_address == 0 or !validUserSlice(length_address, 4)) return errno(14);
    if (peer and sockets[index].connection == null) return errno(107);
    if (!validUserSlice(address, 16)) return errno(14);
    const available = @as(*align(1) u32, @ptrFromInt(length_address)).*;
    if (available < 16) return errno(22);
    const output: [*]u8 = @ptrFromInt(address);
    @memset(output[0..16], 0);
    output[0] = 2; // AF_INET
    const port = if (peer) sockets[index].remote_port else @as(u16, @intCast(49153 + index));
    output[2] = @truncate(port >> 8);
    output[3] = @truncate(port);
    if (peer) @memcpy(output[4..8], &sockets[index].remote_address);
    @as(*align(1) u32, @ptrFromInt(length_address)).* = 16;
    return 0;
}

fn setSocketOption(fd: u64, level: u64, option: u64, value: u64, length: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (level != 1 or (option != 2 and option != 9 and option != 13 and option != 15)) return errno(92); // SOL_SOCKET
    if ((option == 2 or option == 9 or option == 15) and length != 4) return errno(22);
    if (option == 13 and length != 8) return errno(22);
    if (!validUserSlice(value, length)) return errno(14);
    const bytes: [*]const u8 = @ptrFromInt(value);
    if (option == 2) sockets[index].reuse_address = read32(bytes) != 0;
    if (option == 15) sockets[index].reuse_port = read32(bytes) != 0;
    if (option == 9) sockets[index].keep_alive = read32(bytes) != 0;
    if (option == 13) {
        sockets[index].linger_enabled = read32(bytes) != 0;
        sockets[index].linger_seconds = read32(bytes + 4);
    }
    return 0;
}

fn getSocketOption(fd: u64, level: u64, option: u64, value: u64, length_address: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (level != 1 or (option != 2 and option != 3 and option != 4 and option != 7 and option != 8 and option != 9 and option != 13 and option != 15 and option != 30)) return errno(92); // SOL_SOCKET
    if (value == 0 or length_address == 0 or !validUserSlice(length_address, 4)) return errno(14);
    const available = @as(*align(1) u32, @ptrFromInt(length_address)).*;
    const result_length: u32 = if (option == 13) 8 else 4;
    if (available < result_length or !validUserSlice(value, result_length)) return errno(22);
    const output: [*]u8 = @ptrFromInt(value);
    @memset(output[0..result_length], 0);
    if (option == 2) put32(output, @intFromBool(sockets[index].reuse_address));
    if (option == 15) put32(output, @intFromBool(sockets[index].reuse_port));
    if (option == 3) put32(output, 1); // SO_TYPE = SOCK_STREAM
    if (option == 4) put32(output, 0); // SO_ERROR
    if (option == 30) put32(output, 0); // SO_ACCEPTCONN
    if (option == 7 or option == 8) put32(output, 212992); // SO_{SND,RCV}BUF defaults
    if (option == 9) put32(output, @intFromBool(sockets[index].keep_alive));
    if (option == 13) {
        put32(output, @intFromBool(sockets[index].linger_enabled));
        put32(output + 4, sockets[index].linger_seconds);
    }
    @as(*align(1) u32, @ptrFromInt(length_address)).* = result_length;
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

// Linux x86-64 msghdr offsets are name=0, namelen=8, iov=16, iovlen=24,
// control=32, controllen=40 and flags=48. WPE uses sendmsg/recvmsg for its
// local process-pool sockets, including SCM_RIGHTS and Linux SCM_CREDENTIALS.
// Keep the implementation real rather than treating ancillary data as a
// successful no-op: GLib uses SCM_CREDENTIALS during the WebKit handshake.
fn sendMessage(fd: u64, message: u64, flags: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (flags & ~@as(u64, 0x4000 | 0x40 | 0x100) != 0 or !validUserSlice(message, 56)) return errno(22);
    const header: [*]const u8 = @ptrFromInt(message);
    const vector = read64(header + 16);
    const count = read64(header + 24);
    if (count > 64 or (count != 0 and !validUserSlice(vector, count * 16))) return errno(14);
    var rights: [8]usize = .{0} ** 8;
    var credentials = false;
    const rights_count = parseControl(header, &rights, &credentials) catch return errno(22);
    if (rights_count != 0) {
        const peer = sockets[index].peer_index orelse return errno(95);
        if (!sockets[index].local_pair or sockets[peer].pending_rights_len + rights_count > sockets[peer].pending_rights.len)
            return errno(11);
        for (rights[0..rights_count]) |source| if (!sockets[source].allocated) return errno(9);
    }
    var total: u64 = 0;
    if (sockets[index].seqpacket) {
        // sendmsg() on SOCK_SEQPACKET submits one packet even when the
        // payload is split across several iovecs.  Do not enqueue each iovec
        // independently: the WebKit decoder relies on one IPC message per
        // receive operation.
        var packet: [4096]u8 = undefined;
        var packet_len: usize = 0;
        var item: u64 = 0;
        while (item < count) : (item += 1) {
            const entry: [*]const u8 = @ptrFromInt(vector + item * 16);
            const base = read64(entry);
            const length = read64(entry + 8);
            if (!validUserSlice(base, length)) return errno(14);
            const length_usize = std.math.cast(usize, length) orelse return errno(90);
            if (length_usize > packet.len - packet_len) return errno(90);
            if (length_usize != 0) {
                @memcpy(packet[packet_len..][0..length_usize], @as([*]const u8, @ptrFromInt(base))[0..length_usize]);
                packet_len += length_usize;
            }
        }
        const result = socketSend(index, packet[0..packet_len]);
        if (result == errno(11)) return errno(11);
        if (result != packet_len) return if (result < std.math.maxInt(u64)) result else errno(5);
        total = result;
    } else {
        var item: u64 = 0;
        while (item < count) : (item += 1) {
            const entry: [*]const u8 = @ptrFromInt(vector + item * 16);
            const base = read64(entry);
            const length = read64(entry + 8);
            if (!validUserSlice(base, length)) return if (total == 0) errno(14) else total;
            if (length == 0) continue;
            const result = socketSend(index, (@as([*]const u8, @ptrFromInt(base)))[0..@intCast(length)]);
            if (result == errno(11)) return if (total == 0) result else total;
            if (result > std.math.maxInt(u64) - total) return total;
            total += result;
            if (result < length) break;
        }
    }
    if (rights_count != 0) {
        const peer = sockets[index].peer_index.?;
        const start = sockets[peer].pending_rights_len;
        for (rights[0..rights_count], 0..) |source, offset| {
            sockets[peer].pending_rights[start + offset] = source;
            sockets[source].refs += 1;
        }
        sockets[peer].pending_rights_len += rights_count;
    }
    if (credentials) {
        const peer = sockets[index].peer_index orelse return errno(95);
        if (!sockets[index].local_pair) return errno(95);
        sockets[peer].pending_credentials = true;
        sockets[peer].pending_credential_pid = current_pid;
        sockets[peer].pending_credential_uid = 0;
        sockets[peer].pending_credential_gid = 0;
    }
    if (rights_count != 0 or credentials) {
        const peer = sockets[index].peer_index.?;
        wakeSocketReaders(peer);
        wakeSocketPollers(peer);
    }
    return total;
}

fn receiveMessage(fd: u64, message: u64, flags: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    // MSG_CMSG_CLOEXEC is consumed when SCM_RIGHTS descriptors are
    // materialized by deliverRights().  Accept it here as Linux recvmsg(2)
    // does; rejecting it before delivery breaks the WebKit process-pool
    // handshake even though the descriptor-transfer path is implemented.
    if (flags & ~@as(u64, 0x40000000 | 0x40 | 0x2 | 0x100) != 0 or !validUserSlice(message, 56)) return errno(22);
    const header: [*]const u8 = @ptrFromInt(message);
    const vector = read64(header + 16);
    const count = read64(header + 24);
    if (count > 64 or (count != 0 and !validUserSlice(vector, count * 16))) return errno(14);
    // A SOCK_SEQPACKET receive consumes exactly one packet.  Do not call
    // socketReceive once per iovec: that would consume and discard the tail
    // of the packet after the first iovec, corrupting WebKit's IPC envelope
    // (including SCM_RIGHTS descriptors carried with it).
    if (sockets[index].seqpacket and sockets[index].packet_count != 0) {
        const packet_len: usize = sockets[index].packet_lengths[sockets[index].packet_head];
        var copied: usize = 0;
        var item: u64 = 0;
        while (item < count and copied < packet_len) : (item += 1) {
            const entry: [*]const u8 = @ptrFromInt(vector + item * 16);
            const base = read64(entry);
            const length = read64(entry + 8);
            if (!validUserSlice(base, length)) return if (copied == 0) errno(14) else copied;
            const length_usize = std.math.cast(usize, length) orelse return if (copied == 0) errno(90) else copied;
            const amount = @min(length_usize, packet_len - copied);
            var offset: usize = 0;
            while (offset < amount) : (offset += 1) {
                const position = (sockets[index].local_head + copied + offset) % sockets[index].local_buffer.len;
                @as([*]u8, @ptrFromInt(base))[offset] = sockets[index].local_buffer[position];
            }
            copied += amount;
        }
        sockets[index].local_head = (sockets[index].local_head + packet_len) % sockets[index].local_buffer.len;
        sockets[index].local_len -= packet_len;
        sockets[index].packet_head = (sockets[index].packet_head + 1) % sockets[index].packet_lengths.len;
        sockets[index].packet_count -= 1;
        if (sockets[index].peer_index) |peer| {
            wakeSocketPollers(peer);
            wakeSocketWriters(peer);
        }
        deliverAncillary(index, @constCast(header), flags);
        return copied;
    }
    var total: u64 = 0;
    var item: u64 = 0;
    while (item < count) : (item += 1) {
        const entry: [*]const u8 = @ptrFromInt(vector + item * 16);
        const base = read64(entry);
        const length = read64(entry + 8);
        if (!validUserSlice(base, length)) return if (total == 0) errno(14) else total;
        if (length == 0) continue;
        const result = socketReceive(index, (@as([*]u8, @ptrFromInt(base)))[0..@intCast(length)]);
        if (result == errno(11)) return if (total == 0) result else total;
        if (result > std.math.maxInt(u64) - total) return total;
        total += result;
        if (result < length) break;
    }
    deliverAncillary(index, @constCast(header), flags);
    return total;
}

const RightsError = error{InvalidControl, InvalidRights};

fn parseControl(header: [*]const u8, output: *[8]usize, credentials: *bool) RightsError!u8 {
    const control = read64(header + 32);
    const control_length = read64(header + 40);
    if (control_length == 0) return 0;
    if (control == 0 or !validUserSlice(control, control_length) or control_length < 16) return error.InvalidControl;
    var offset: usize = 0;
    var rights_count: u8 = 0;
    while (offset + 16 <= control_length) {
        const cmsg: [*]const u8 = @ptrFromInt(control + offset);
        const cmsg_length = read64(cmsg);
        if (cmsg_length < 16 or cmsg_length > control_length - offset) return error.InvalidControl;
        const level = read32(cmsg + 8);
        const kind = read32(cmsg + 12);
        if (level != 1) return error.InvalidControl; // SOL_SOCKET
        if (kind == 1) { // SCM_RIGHTS
            const bytes = cmsg_length - 16;
            if ((bytes & 3) != 0 or rights_count + bytes / 4 > output.len) return error.InvalidRights;
            for (0..bytes / 4) |item| {
                const fd = read32(cmsg + 16 + item * 4);
                output[rights_count + item] = socketIndex(fd) orelse return error.InvalidRights;
            }
            rights_count += @intCast(bytes / 4);
        } else if (kind == 2) { // SCM_CREDENTIALS, Linux struct ucred
            if (cmsg_length != 28) return error.InvalidControl;
            credentials.* = true;
        } else return error.InvalidControl;
        const aligned = (cmsg_length + 7) & ~@as(u64, 7);
        if (aligned == 0 or aligned > control_length - offset) break;
        offset += @intCast(aligned);
    }
    return rights_count;
}

fn deliverAncillary(index: usize, header: [*]u8, flags: u64) void {
    const available = read64(header + 40);
    const control = read64(header + 32);
    const requested = @min(@as(usize, sockets[index].pending_rights_len), 8);
    const has_credentials = sockets[index].pending_credentials;
    var used: usize = 0;
    var written_rights: usize = 0;
    var wrote_credentials = false;
    const can_write = control != 0 and validUserSlice(control, available);
    const target: [*]u8 = if (can_write) @ptrFromInt(control) else undefined;
    if (can_write and requested != 0 and available >= 16 + 4) {
        const capacity = @as(usize, @intCast(available));
        while (written_rights < requested and used + 20 <= capacity) {
            const source = sockets[index].pending_rights[written_rights];
            const alias = allocateSocketAlias(current_thread, source, socket_fd_base + sockets.len, (flags & 0x40000000) != 0) orelse break;
            put64(target + used, 16 + 4);
            put32(target + used + 8, 1);
            put32(target + used + 12, 1);
            put32(target + used + 16, @intCast(alias));
            sockets[source].refs -|= 1;
            written_rights += 1;
            used += 24;
        }
    }
    if (can_write and has_credentials and used + 28 <= available) {
        put64(target + used, 28);
        put32(target + used + 8, 1);
        put32(target + used + 12, 2);
        put32(target + used + 16, sockets[index].pending_credential_pid);
        put32(target + used + 20, sockets[index].pending_credential_uid);
        put32(target + used + 24, sockets[index].pending_credential_gid);
        wrote_credentials = true;
        used += 32;
    }
    const old_flags = read32(header + 48);
    if (written_rights < requested or (has_credentials and !wrote_credentials)) put32(header + 48, old_flags | 8); // MSG_CTRUNC
    put64(header + 40, used);
    const remaining = requested - @min(written_rights, requested);
    if (remaining != 0) {
        for (0..remaining) |offset| sockets[index].pending_rights[offset] = sockets[index].pending_rights[written_rights + offset];
    }
    sockets[index].pending_rights_len = @intCast(remaining);
    if (wrote_credentials or !can_write) sockets[index].pending_credentials = false;
}

fn shutdown(fd: u64, how: u64) u64 {
    const index = socketIndex(fd) orelse return errno(9);
    if (how > 2) return errno(22);
    if (sockets[index].local_pair) {
        if (how == 0 or how == 2) {
            sockets[index].read_closed = true;
            sockets[index].local_len = 0;
        }
        if (how == 1 or how == 2) {
            sockets[index].write_closed = true;
            if (sockets[index].peer_index) |peer| {
                sockets[peer].peer_closed = true;
                wakeSocketReaders(peer);
                wakeSocketPollers(peer);
            }
        }
        return 0;
    }
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection| stack.tcpClose(connection) catch return errno(5) else return errno(107);
    return 0;
}

fn socketSend(index: usize, data: []const u8) u64 {
    if (sockets[index].local_pair) {
        if (!sockets[index].writable) return errno(9);
        if (sockets[index].write_closed) return errno(32);
        const peer = sockets[index].peer_index orelse return errno(32);
        if (!sockets[peer].allocated) return errno(32);
        const available = sockets[peer].local_buffer.len - sockets[peer].local_len;
        if (available == 0) return errno(11);
        if (sockets[index].seqpacket) {
            // A zero-length write is a successful no-op.  Do not enqueue an
            // empty packet: the receive path uses an empty queue as its
            // blocking condition, so such a packet could strand a reader.
            if (data.len == 0) return 0;
            if (data.len > sockets[peer].local_buffer.len or sockets[peer].packet_count >= sockets[peer].packet_lengths.len or data.len > available)
                return errno(11);
            var offset: usize = 0;
            while (offset < data.len) : (offset += 1) {
                const position = (sockets[peer].local_head + sockets[peer].local_len + offset) % sockets[peer].local_buffer.len;
                sockets[peer].local_buffer[position] = data[offset];
            }
            sockets[peer].local_len += data.len;
            const slot = (sockets[peer].packet_head + sockets[peer].packet_count) % sockets[peer].packet_lengths.len;
            sockets[peer].packet_lengths[slot] = @intCast(data.len);
            sockets[peer].packet_count += 1;
            wakeSocketPollers(peer);
            wakeSocketReaders(peer);
            return data.len;
        }
        const count = @min(data.len, available);
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const position = (sockets[peer].local_head + sockets[peer].local_len + offset) % sockets[peer].local_buffer.len;
            sockets[peer].local_buffer[position] = data[offset];
        }
        sockets[peer].local_len += count;
        wakeSocketPollers(peer);
        wakeSocketReaders(peer);
        return count;
    }
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection|
        return stack.tcpSend(connection, data) catch errno(5);
    return errno(107);
}

fn wakeSocketPollers(index: usize) void {
    if (sockets[index].local_len == 0 and !sockets[index].peer_closed) return;
    for (&user_threads) |*thread| {
        if (thread.state != .blocked or thread.pending_poll_address == 0 or !thread.pending_poll_sockets[index]) continue;
        // The pollfd array belongs to the blocked thread's address space.
        // Leave it untouched until that workspace is active again.
        thread.state = .runnable;
        thread_switch_requested = true;
    }
}

fn completePendingPoll(thread_index: usize) void {
    if (thread_index >= user_threads.len) return;
    const thread = &user_threads[thread_index];
    if (thread.pending_poll_address == 0) return;
    const address = thread.pending_poll_address;
    const count = thread.pending_poll_count;
    const bytes = std.math.mul(u64, count, 8) catch {
        thread.pending_poll_address = 0;
        thread.pending_poll_count = 0;
        thread.pending_poll_sockets = .{false} ** 32;
        thread.result = errno(22);
        return;
    };
    if (count > 64 or (count != 0 and !validUserSlice(address, bytes))) {
        thread.pending_poll_address = 0;
        thread.pending_poll_count = 0;
        thread.pending_poll_sockets = .{false} ** 32;
        thread.result = errno(14);
        return;
    }
    var ready: u64 = 0;
    var poll_index: u64 = 0;
    while (poll_index < count) : (poll_index += 1) {
        const item: [*]u8 = @ptrFromInt(address + poll_index * 8);
        const fd = read32(item);
        var revents: u16 = 0;
        const events = read16(item + 4);
        if (socketIndexForThread(thread_index, fd)) |socket_index| {
            if ((events & 1) != 0 and sockets[socket_index].local_pair and sockets[socket_index].local_len != 0) revents |= 1;
            if (sockets[socket_index].local_pair and sockets[socket_index].peer_closed) revents |= 0x10 | 1;
            if ((events & 4) != 0 and sockets[socket_index].local_pair) {
                if (sockets[socket_index].peer_index) |peer| {
                    if (sockets[peer].local_len < sockets[peer].local_buffer.len) revents |= 4;
                }
            }
        }
        put16(item + 6, revents);
        if (revents != 0) ready += 1;
    }
    thread.pending_poll_address = 0;
    thread.pending_poll_count = 0;
    thread.pending_poll_sockets = .{false} ** 32;
    thread.result = ready;
}

fn completePendingWaitStatus(thread_index: usize) void {
    if (thread_index >= user_threads.len) return;
    const thread = &user_threads[thread_index];
    const status = thread.pending_wait_status orelse return;
    const address = thread.pending_wait_address;
    if (address != 0 and validUserSlice(address, 4))
        @as(*align(1) u32, @ptrFromInt(address)).* = @as(u32, status) << 8;
    thread.pending_wait_status = null;
    thread.pending_wait_address = 0;
}

pub fn completeCurrentPendingWaitStatus() void {
    completePendingWaitStatus(current_thread);
}

/// The process loader can restore a parent's userspace frame directly after
/// an exec child exits, bypassing the normal scheduler-selection path.  Keep
/// the same socket/poll completion semantics in that path as well.
pub fn completeCurrentPendingIo() void {
    completePendingSocketRead(current_thread);
    completePendingSocketWrite(current_thread);
    completePendingPoll(current_thread);
}

fn wakeSocketReaders(index: usize) void {
    if (sockets[index].local_len == 0 and !sockets[index].peer_closed) return;
    for (&user_threads) |*thread| {
        if (thread.state != .blocked or thread.pending_read_socket != index) continue;
        // The blocked thread may belong to another address space.  Do not
        // dereference its userspace address while the producer's CR3 is
        // active; completion is performed after the scheduler activates the
        // reader workspace.
        thread.state = .runnable;
        thread_switch_requested = true;
    }
}

fn wakeSocketWriters(index: usize) void {
    if (!sockets[index].allocated or sockets[index].local_len >= sockets[index].local_buffer.len) return;
    for (&user_threads) |*thread| {
        if (thread.state != .blocked or thread.pending_write_socket != index) continue;
        thread.state = .runnable;
        thread_switch_requested = true;
    }
}

fn completePendingSocketWrite(thread_index: usize) void {
    if (thread_index >= user_threads.len) return;
    const thread = &user_threads[thread_index];
    const index = thread.pending_write_socket orelse return;
    const address = thread.pending_write_address;
    const length = thread.pending_write_length;
    if (!validUserSlice(address, length)) {
        thread.pending_write_socket = null;
        thread.pending_write_address = 0;
        thread.pending_write_length = 0;
        thread.result = errno(14);
        return;
    }
    const result = socketSend(index, @as([*]const u8, @ptrFromInt(address))[0..length]);
    if (result == errno(11)) return;
    thread.pending_write_socket = null;
    thread.pending_write_address = 0;
    thread.pending_write_length = 0;
    thread.result = result;
}

fn completePendingSocketRead(thread_index: usize) void {
    if (thread_index >= user_threads.len) return;
    const thread = &user_threads[thread_index];
    const index = thread.pending_read_socket orelse return;
    // EOF is a state of the stream, not a priority over bytes already
    // buffered.  A producer may close immediately after its final write;
    // deliver that buffered data first and only complete the blocked read
    // with zero once the queue is empty.
    if (thread.pending_read_eof and sockets[index].local_len == 0) {
        thread.pending_read_socket = null;
        thread.pending_read_address = 0;
        thread.pending_read_length = 0;
        thread.pending_read_eof = false;
        thread.result = 0;
        return;
    }
    if (sockets[index].local_len == 0) {
        if (sockets[index].peer_closed) {
            thread.pending_read_socket = null;
            thread.pending_read_address = 0;
            thread.pending_read_length = 0;
            thread.result = 0;
        }
        return;
    }
    const address = thread.pending_read_address;
    const length = @min(thread.pending_read_length, sockets[index].local_len);
    if (!validUserSlice(address, length)) {
        thread.pending_read_socket = null;
        thread.pending_read_address = 0;
        thread.pending_read_length = 0;
        thread.result = errno(14);
        return;
    }
    if (sockets[index].seqpacket) {
        const result = socketReceive(index, @as([*]u8, @ptrFromInt(address))[0..length]);
        if (result == errno(11) or result == 0) return;
        thread.pending_read_socket = null;
        thread.pending_read_address = 0;
        thread.pending_read_length = 0;
        thread.pending_read_eof = false;
        thread.result = result;
        return;
    }
    const output: [*]u8 = @ptrFromInt(address);
    var offset: usize = 0;
    while (offset < length) : (offset += 1) {
        const position = (sockets[index].local_head + offset) % sockets[index].local_buffer.len;
        output[offset] = sockets[index].local_buffer[position];
    }
    sockets[index].local_head = (sockets[index].local_head + length) % sockets[index].local_buffer.len;
    sockets[index].local_len -= length;
    if (sockets[index].peer_index) |peer| {
        wakeSocketPollers(peer);
        wakeSocketWriters(peer);
    }
    thread.pending_read_socket = null;
    thread.pending_read_address = 0;
    thread.pending_read_length = 0;
    thread.pending_read_eof = false;
    thread.result = length;
}

fn socketReceive(index: usize, data: []u8) u64 {
    if (sockets[index].local_pair) {
        if (!sockets[index].readable) return errno(9);
        if (sockets[index].read_closed) return 0;
        if (sockets[index].local_len == 0) {
            if (sockets[index].peer_closed) return 0;
            if (sockets[index].nonblocking) return errno(11);
            if (!user_threads_enabled) return errno(11);
            user_threads[current_thread].pending_read_socket = index;
            user_threads[current_thread].pending_read_address = @intFromPtr(data.ptr);
            user_threads[current_thread].pending_read_length = data.len;
            user_threads[current_thread].pending_read_eof = false;
            user_threads[current_thread].state = .blocked;
            thread_switch_requested = true;
            return 0;
        }
        if (sockets[index].seqpacket and sockets[index].packet_count != 0) {
            const packet_len: usize = sockets[index].packet_lengths[sockets[index].packet_head];
            const count = @min(data.len, packet_len);
            var offset: usize = 0;
            while (offset < count) : (offset += 1) {
                const position = (sockets[index].local_head + offset) % sockets[index].local_buffer.len;
                data[offset] = sockets[index].local_buffer[position];
            }
            sockets[index].local_head = (sockets[index].local_head + packet_len) % sockets[index].local_buffer.len;
            sockets[index].local_len -= packet_len;
            sockets[index].packet_head = (sockets[index].packet_head + 1) % sockets[index].packet_lengths.len;
            sockets[index].packet_count -= 1;
            if (sockets[index].peer_index) |peer| {
                wakeSocketPollers(peer);
                wakeSocketWriters(peer);
            }
            return count;
        }
        const count = @min(data.len, sockets[index].local_len);
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const position = (sockets[index].local_head + offset) % sockets[index].local_buffer.len;
            data[offset] = sockets[index].local_buffer[position];
        }
        sockets[index].local_head = (sockets[index].local_head + count) % sockets[index].local_buffer.len;
        sockets[index].local_len -= count;
        if (sockets[index].peer_index) |peer| {
            wakeSocketPollers(peer);
            wakeSocketWriters(peer);
        }
        return count;
    }
    const stack = network_stack orelse return errno(100);
    if (sockets[index].connection) |*connection|
        return stack.tcpReceive(connection, data) catch errno(5);
    return errno(107);
}

fn socketIndex(fd: u64) ?usize {
    return socketIndexForThread(current_thread, fd);
}

fn socketAliasForThread(thread_index: usize, fd: u64) ?*SocketFdAlias {
    if (thread_index >= user_threads.len or fd > std.math.maxInt(u32)) return null;
    const workspace = user_threads[thread_index].workspace_id;
    for (&workspace_fd_aliases[workspace]) |*alias|
        if (alias.used and alias.fd == @as(u32, @intCast(fd))) return alias;
    for (&user_threads[thread_index].socket_fd_aliases) |*alias|
        if (alias.used and alias.fd == @as(u32, @intCast(fd))) return alias;
    return null;
}

fn socketIndexForThread(thread_index: usize, fd: u64) ?usize {
    if (thread_index >= user_threads.len) return null;
    if (socketAliasForThread(thread_index, fd)) |alias| {
        const index: usize = alias.socket_index;
        return if (index < sockets.len and sockets[index].allocated) index else null;
    }
    if (fd < 3) {
        const workspace = user_threads[thread_index].workspace_id;
        if (workspace_stdio_sockets[workspace][@intCast(fd)]) |index| return index;
        if (user_threads[thread_index].stdio_sockets[@intCast(fd)]) |index| return index;
        for (user_threads) |peer| {
            if (peer.workspace_id == workspace) {
                if (peer.stdio_sockets[@intCast(fd)]) |index| return index;
            }
        }
        return null;
    }
    if (fd < socket_fd_base or fd >= socket_fd_base + sockets.len) return null;
    const slot: usize = @intCast(fd - socket_fd_base);
    const workspace = user_threads[thread_index].workspace_id;
    // High descriptors are process/workspace-owned.  Never infer identity
    // from the global socket slot: after fork/close that numeric fd may have
    // been reused by another workspace, and the old fallback would silently
    // connect unrelated pipe endpoints.  Every valid direct descriptor is
    // published into this map by socket()/socketpair()/fork().
    const index: usize = workspace_socket_fd_map[workspace][slot] orelse return null;
    if (!sockets[index].allocated) return null;
    if (workspace_socket_refs[workspace][index] or user_threads[thread_index].direct_socket_refs[index]) return index;
    for (user_threads) |peer| {
        if (peer.workspace_id == workspace and peer.direct_socket_refs[index]) return index;
    }
    return null;
}

fn allocateSocketAlias(thread_index: usize, source: usize, minimum: u64, cloexec: bool) ?u64 {
    if (thread_index >= user_threads.len or source >= sockets.len) return null;
    var fd: u64 = @max(minimum, socket_fd_base + sockets.len);
    const workspace = user_threads[thread_index].workspace_id;
    for (user_threads[thread_index].socket_fd_aliases) |alias| {
        if (alias.used) continue;
        // F_DUPFD must never reuse a live alias in the same descriptor view.
        while (fd <= std.math.maxInt(u32)) {
            var collision = false;
            for (user_threads[thread_index].socket_fd_aliases) |existing| {
                if (existing.used and existing.fd == @as(u32, @intCast(fd))) {
                    collision = true;
                    break;
                }
            }
            if (!collision) break;
            fd += 1;
        }
        if (fd > std.math.maxInt(u32)) return null;
        // A workspace is the descriptor table owner. Every live thread in
        // that workspace receives the same alias entry, while the underlying
        // socket gets only one additional reference for the shared table.
        for (user_threads) |peer| {
            if (peer.workspace_id != workspace) continue;
            var has_slot = false;
            for (peer.socket_fd_aliases) |peer_alias| if (!peer_alias.used) { has_slot = true; break; };
            if (!has_slot) return null;
        }
        for (&user_threads) |*peer| {
            if (peer.workspace_id != workspace) continue;
            for (&peer.socket_fd_aliases) |*peer_alias| {
                if (peer_alias.used) continue;
                peer_alias.* = .{ .fd = @intCast(fd), .socket_index = @intCast(source), .close_on_exec = cloexec, .used = true };
                break;
            }
        }
        for (&workspace_fd_aliases[workspace]) |*workspace_alias| {
            if (!workspace_alias.used) {
                workspace_alias.* = .{ .fd = @intCast(fd), .socket_index = @intCast(source), .close_on_exec = cloexec, .used = true };
                break;
            }
        }
        if (workspace_socket_aliases[workspace][source] != std.math.maxInt(u8))
            workspace_socket_aliases[workspace][source] += 1;
        if (workspace_socket_ref_counts[workspace][source] != std.math.maxInt(u16))
            workspace_socket_ref_counts[workspace][source] += 1;
        sockets[source].refs += 1;
        return fd;
    }
    return null;
}

fn installSocketAliasAt(thread_index: usize, source: usize, fd: u64) ?u64 {
    if (thread_index >= user_threads.len or source >= sockets.len or fd > std.math.maxInt(u32)) return null;
    if (socketAliasForThread(thread_index, fd)) |alias| closeSocketAlias(thread_index, alias);
    const workspace = user_threads[thread_index].workspace_id;
    // A workspace owns one descriptor table shared by all of its live
    // threads.  dup2() must therefore publish the target alias to every
    // thread before returning; installing it only in the caller makes a
    // sibling helper resolve the same numeric fd to an unrelated endpoint.
    // A stale copy can exist only in a sibling cache after a scheduler
    // switch.  Treat it exactly like dup2() replacing an occupied target:
    // remove the shared alias once, then install the new one everywhere.
    var replaced_sibling = false;
    for (&user_threads, 0..) |*peer, peer_index| {
        if (peer.workspace_id != workspace) continue;
        for (&peer.socket_fd_aliases) |*alias| {
            if (!alias.used or alias.fd != @as(u32, @intCast(fd))) continue;
            closeSocketAlias(peer_index, alias);
            replaced_sibling = true;
            break;
        }
        if (replaced_sibling) break;
    }
    var peer_count: usize = 0;
    for (user_threads) |peer| {
        if (peer.workspace_id == workspace) peer_count += 1;
    }
    if (peer_count == 0) return null;
    for (user_threads) |peer| {
        if (peer.workspace_id != workspace) continue;
        var has_free = false;
        for (peer.socket_fd_aliases) |alias| {
            if (!alias.used) { has_free = true; break; }
        }
        if (!has_free) return null;
    }
    for (&user_threads) |*peer| {
        if (peer.workspace_id != workspace) continue;
        for (&peer.socket_fd_aliases) |*alias| {
            if (!alias.used) {
                alias.* = .{ .fd = @intCast(fd), .socket_index = @intCast(source), .close_on_exec = false, .used = true };
                break;
            }
        }
    }
    for (&workspace_fd_aliases[workspace]) |*workspace_alias| {
        if (!workspace_alias.used) {
            workspace_alias.* = .{ .fd = @intCast(fd), .socket_index = @intCast(source), .close_on_exec = false, .used = true };
            break;
        }
    }
    if (workspace_socket_aliases[workspace][source] != std.math.maxInt(u8))
        workspace_socket_aliases[workspace][source] += 1;
    if (workspace_socket_ref_counts[workspace][source] != std.math.maxInt(u16))
        workspace_socket_ref_counts[workspace][source] += 1;
    sockets[source].refs += 1;
    return fd;
}

fn closeSocketAlias(thread_index: usize, alias: *SocketFdAlias) void {
    if (!alias.used) return;
    const index: usize = alias.socket_index;
    const workspace = user_threads[thread_index].workspace_id;
    const fd = alias.fd;
    alias.used = false;
    for (&user_threads) |*peer| {
        if (peer.workspace_id != workspace) continue;
        for (&peer.socket_fd_aliases) |*peer_alias| {
            if (peer_alias.used and peer_alias.fd == fd and peer_alias.socket_index == index)
                peer_alias.used = false;
        }
    }
    for (&workspace_fd_aliases[workspace]) |*workspace_alias| {
        if (workspace_alias.used and workspace_alias.fd == fd and workspace_alias.socket_index == index)
            workspace_alias.* = .{};
    }
    if (workspace_socket_aliases[workspace][index] != 0)
        workspace_socket_aliases[workspace][index] -= 1;
    if (index < sockets.len and sockets[index].allocated) releaseSocketRef(index);
}

fn archPrctl(code: u64, address: u64) u64 {
    if (code != 0x1002) return errno(22);
    // ARCH_SET_FS accepts a canonical userspace base only; never let a
    // userspace syscall install a kernel/non-canonical address in the MSR.
    if (address >= 0x0000800000000000) return errno(22);
    writeMsr(0xc0000100, address);
    if (current_thread < user_threads.len and user_threads[current_thread].state != .unused)
        user_threads[current_thread].fs = address;
    return 0;
}

fn setThreadArea(address: u64) u64 {
    if (address >= 0x0000800000000000) return errno(22);
    writeMsr(0xc0000100, address);
    if (current_thread < user_threads.len and user_threads[current_thread].state != .unused)
        user_threads[current_thread].fs = address;
    return 0;
}

fn brk(requested: u64) u64 {
    if (requested == 0) return program_break;
    if (requested >= user_base + user_size and requested <= break_limit) program_break = requested;
    return program_break;
}

fn mmap(requested: u64, length: u64, protection: u64, flags: u64, fd: u64, file_offset: u64) u64 {
    if (length > ~@as(u64, 0) - 4095) return errno(12);
    if (length == 0 or (file_offset & 4095) != 0 or (protection & 2) != 0 and (protection & 4) != 0) return errno(22);
    const anonymous = (flags & 0x20) != 0;
    const framebuffer_device = !anonymous and vfs.isFramebuffer(@intCast(fd));
    const drm_device = !anonymous and vfs.isDrm(@intCast(fd));
    if (framebuffer_device or drm_device) {
        if (requested != 0 and (requested & 4095) != 0) return errno(22);
        const drm_object = if (drm_device) drmObjectForMap(file_offset, length) else null;
        if ((flags & 1) == 0 or (protection & 4) != 0 or (drm_device and drm_object == null) or (!drm_device and (file_offset > framebuffer.size or length > framebuffer.size - file_offset))) return errno(22);
        const aligned_length = (length + 4095) & ~@as(u64, 4095);
        const address = if (requested != 0) requested else (device_mmap_next + 4095) & ~@as(u64, 4095);
        if (address < mmap_limit or address > device_mmap_limit or aligned_length > device_mmap_limit - address) return errno(12);
        const hook = device_mmap_hook orelse return errno(19);
        const physical_address = if (drm_object) |object|
            std.math.add(u64, object.physical_address, file_offset - object.map_offset) catch return errno(12)
        else
            std.math.add(u64, framebuffer.base, file_offset) catch return errno(12);
        if (!hook(address, physical_address, aligned_length, (protection & 2) != 0)) return errno(12);
        device_mmap_next = address + aligned_length;
        if (drm_device) drm_mmaps = saturatingCount(drm_mmaps, 1) else framebuffer_mmaps = saturatingCount(framebuffer_mmaps, 1);
        return address;
    }
    if (!anonymous and (flags & 2) == 0) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    // Without MAP_FIXED the address is a hint, not a requirement. musl's
    // allocator probes adjacent addresses, including below this arena.
    const hint = requested & ~@as(u64, 4095);
    const hint_fits = hint >= mmap_next and hint <= mmap_limit and aligned_length <= mmap_limit - hint;
    const address = if ((flags & 0x10) != 0) requested else if (requested != 0 and hint_fits) hint else (mmap_next + 4095) & ~@as(u64, 4095);
    if ((address & 4095) != 0) return errno(22);
    // MAP_NORESERVE is used by WebKit's bmalloc arena. The CSOS process
    // already reserves and zeroes the complete anonymous arena at startup;
    // consume this virtual reservation without rewalking or clearing every
    // page on each large arena request.
    if ((flags & 0x4000) != 0) {
        const virtual_limit: u64 = 0x00007f0000000000;
        // MAP_FIXED remaps/commits the exact address supplied by the caller.
        // In particular, bmalloc uses MAP_FIXED to populate portions of an
        // already-reserved arena; advancing noreserve_next here would return
        // a different pointer and silently corrupt the allocator's state.
        if ((flags & 0x10) != 0) {
            const fixed_end = std.math.add(u64, requested, aligned_length) catch return errno(12);
            if (requested < mmap_base or requested > virtual_limit or fixed_end > virtual_limit) return errno(12);
            // MAP_FIXED|MAP_ANON replaces previous contents with fresh
            // zero-filled pages. WebKit's vmZeroAndPurge relies on this.
            if (mmap_reset_hook) |reset| if (!reset(requested, aligned_length)) return errno(12);
            // A fixed commit may retain the aligned tail of a larger
            // MAP_NORESERVE reservation. Do not let the next non-fixed
            // reservation reuse that tail and overwrite allocator metadata.
            if (fixed_end > noreserve_next) noreserve_next = fixed_end;
            return requested;
        }
        // Large allocator arenas (notably JSC's aligned structure heap) are
        // virtual reservations and can exceed the eagerly-backed mmap arena.
        // Keep them in the canonical user range; pages are committed later by
        // the normal protection path.
        // A MAP_NORESERVE request is virtual-only when it does not fit the
        // eagerly-backed arena.  WebKit's bmalloc uses reservations in the
        // 128 MiB range even though the process starts with a much smaller
        // resident window; rejecting those requests makes the allocator
        // receive ENOMEM and eventually trip its alignment assertion.
        const eager_fits = address <= mmap_limit and aligned_length <= mmap_limit - address;
        const large_reservation = !eager_fits;
        const reserve_address = if (!large_reservation)
            address
        else if (requested != 0 and requested >= noreserve_next and requested <= virtual_limit and aligned_length <= virtual_limit - requested)
            requested
        else
            (noreserve_next + 4095) & ~@as(u64, 4095);
        if (reserve_address > virtual_limit or aligned_length > virtual_limit - reserve_address) return errno(12);
        if (large_reservation) noreserve_next = reserve_address + aligned_length else mmap_next = reserve_address + aligned_length;
        return reserve_address;
    }
    if (address < mmap_next or address > mmap_limit or aligned_length > mmap_limit - address) return errno(12);
    const hook = mmap_protect_hook orelse return errno(12);
    // Private mappings remain writable until copy-on-write is available. This
    // keeps real userspace allocators functional while preserving NX when
    // executable permission was not requested.
    if (!hook(address, aligned_length, true, (protection & 4) != 0)) return errno(12);
    const target: [*]u8 = @ptrFromInt(address);
    @memset(target[0..@intCast(aligned_length)], 0);
    if (!anonymous) {
        const count = vfs.pread(@intCast(fd), target[0..@intCast(length)], @intCast(file_offset)) catch |err| {
            if (mmap_unmap_hook) |unmap| _ = unmap(address, aligned_length);
            return vfsError(err);
        };
        if (count == 0) {
            if (mmap_unmap_hook) |unmap| _ = unmap(address, aligned_length);
            return errno(19);
        }
        file_mmaps = saturatingCount(file_mmaps, 1);
    }
    mmap_next = address + aligned_length;
    return address;
}

fn mprotect(address: u64, length: u64, protection: u64) u64 {
    if ((address & 4095) != 0 or length == 0 or ((protection & 2) != 0 and (protection & 4) != 0)) return errno(22);
    if (length > ~@as(u64, 0) - 4095) return errno(12);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    const hook = mmap_protect_hook orelse return errno(12);
    if (!hook(address, aligned_length, (protection & 2) != 0, (protection & 4) != 0)) return errno(12);
    protected_mmaps = saturatingCount(protected_mmaps, 1);
    return 0;
}

fn munmap(address: u64, length: u64) u64 {
    if ((address & 4095) != 0 or length == 0) return errno(22);
    if (length > ~@as(u64, 0) - 4095) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    // OSAllocator's aligned MAP_NORESERVE path maps a larger raw span, keeps
    // the aligned subspan, then releases both edge spans. Those reservations
    // are virtual-only in CSOS, so releasing an edge must succeed even when
    // it lies beyond the eagerly-backed mmap arena.
    const virtual_limit: u64 = 0x00007f0000000000;
    if (address >= mmap_base and address < virtual_limit and
        (address >= mmap_limit or aligned_length > mmap_limit - address) and
        aligned_length <= virtual_limit - address) return 0;
    if (!mmapRegion(address, aligned_length)) return errno(22);
    const hook = mmap_unmap_hook orelse return errno(22);
    if (!hook(address, aligned_length)) return errno(22);
    unmapped_mmaps = saturatingCount(unmapped_mmaps, 1);
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

fn schedYield() u64 {
    if (user_threads_enabled) { thread_switch_requested = true; return 0; }
    if (idle_hook) |hook| hook();
    return 0;
}

fn exitSyscall(status: u64) u64 {
    process_exit_status = status;
    if (user_threads_enabled) user_threads_done = true;
    return 0;
}

fn exitThread(status: u64) u64 {
    if (!user_threads_enabled) return exitSyscall(status);
    const thread = &user_threads[current_thread];
    thread.exit_status = status;
    if (thread.clear_tid != 0 and validUserSlice(thread.clear_tid, 4)) {
        @as(*align(1) u32, @ptrFromInt(thread.clear_tid)).* = 0;
        _ = wakeUserThreads(thread.clear_tid, ~@as(u64, 0), thread.workspace_id, true);
    }
    releaseOwnedFutexesOnExit(thread);
    thread.state = .exited;
    var workspace_has_live_thread = false;
    if (thread.kind == .process_child) {
        // A process exit is an exit_group: helper pthreads belong to the
        // same process/workspace and must not keep inherited pipe endpoints
        // alive after the leader has terminated.  Waiting for each helper to
        // exit independently can deadlock receive-pack forever because those
        // helpers are commonly blocked in read/poll on the same descriptor
        // table.  Invalidate their waits before releasing workspace FDs.
        for (&user_threads) |*peer| {
            if (peer.workspace_id != thread.workspace_id or peer.pid == thread.pid) continue;
            peer.exec_request = null;
            peer.pending_read_socket = null;
            peer.pending_read_address = 0;
            peer.pending_read_length = 0;
            peer.pending_read_eof = false;
            peer.pending_write_socket = null;
            peer.pending_write_address = 0;
            peer.pending_write_length = 0;
            peer.pending_poll_address = 0;
            peer.pending_poll_count = 0;
            peer.pending_poll_sockets = .{false} ** 32;
            peer.state = .exited;
        }
    } else {
        for (user_threads) |other| {
            if (other.workspace_id != thread.workspace_id) continue;
            if (other.state == .runnable or other.state == .blocked) {
                workspace_has_live_thread = true;
                break;
            }
        }
    }
    if (!workspace_has_live_thread) {
        // A process owns one descriptor table for its whole workspace. Do
        // not reap it when only the leader thread exits: detached helpers may
        // still be using the transport and must keep their endpoints alive.
        // The final thread performs the single workspace-wide close and is
        // the only point at which wait4 may observe process termination.
        if (thread.kind == .process_child) {
            const parent_workspace = if (thread.parent_slot < user_threads.len)
                user_threads[thread.parent_slot].workspace_id
            else
                0xff;
            releaseWorkspaceSockets(thread.workspace_id);
            for (&user_threads) |*parent| {
                // wait4 belongs to the process/workspace, not to the
                // particular helper thread that happened to issue fork().
                // A receive-pack worker may fork while another worker waits.
                if (parent.workspace_id != parent_workspace or
                    parent.state != .blocked or parent.wait_child_pid == 0) continue;
                if (parent.wait_child_pid != ~@as(u64, 0) and parent.wait_child_pid != thread.pid) continue;
                parent.pending_wait_status = @truncate(status & 0xff);
                parent.pending_wait_address = parent.wait_status;
                parent.result = thread.pid;
                parent.wait_child_pid = 0;
                parent.wait_status = 0;
                parent.state = .runnable;
            }
        }
        workspace_done[thread.workspace_id] = true;
        workspace_exit_status[thread.workspace_id] = @truncate(status & 0xff);
        // Only the top-level image owns the global run loop. A process child
        // must finish its own nested loader without terminating its parent or
        // sibling workspaces (receive-pack relies on this distinction).
        // A helper pthread can belong to the top-level workspace while its
        // process leader is blocked in wait4.  Its return must not terminate
        // the loader globally; only the bootstrap leader owns that boundary.
        if ((thread.workspace_id == top_level_workspace and thread.pid == 1) or !anyLiveUserThread()) return exitSyscall(status);
        thread_switch_requested = true;
        return 0;
    }
    for (user_threads) |other| {
        if (other.state == .runnable or other.state == .blocked) return 0;
    }
    return exitSyscall(status);
}

fn kill(pid: u64, signal: u64) u64 {
    if (pid != 1 and pid != 0) return errno(3);
    if (signal == 0) return 0;
    if (signal != 9 and signal != 15) return errno(22);
    process_exit_status = 128 + signal;
    return 0;
}

fn tgkill(pid: u64, tid: u64, signal: u64) u64 {
    if ((pid != 0 and pid != 1) or (tid != 1 and tid != 0)) return errno(3);
    return kill(1, signal);
}

fn pipe2(output: u64, flags: u64) u64 {
    if ((flags & ~@as(u64, 0x80800)) != 0) return errno(22);
    const result = socketPair(1, 1 | (flags & 0x80800), 0, output);
    if (@as(i64, @bitCast(result)) < 0) return result;
    const first = @as(usize, @intCast(@as(*align(1) u32, @ptrFromInt(output)).* - socket_fd_base));
    const second = @as(usize, @intCast(@as(*align(1) u32, @ptrFromInt(output + 4)).* - socket_fd_base));
    sockets[first].readable = true; sockets[first].writable = false;
    sockets[second].readable = false; sockets[second].writable = true;
    return 0;
}

/// Replace the current image through the process loader.  The hook is kept
/// explicit because entering the loader from a syscall must atomically tear
/// down the current address space and install a fresh argv/auxv image.
/// Until that transition is wired, report the real Linux ENOSYS result after
/// validating the pathname pointer instead of treating execve as unknown.
fn execve(path: u64, argv: u64, envp: u64) u64 {
    var request = ExecRequest{};
    request.path_len = copyExecString(path, &request.path) catch |err| return errno(execCopyErrno(err));
    if (argv == 0 or !validUserSlice(argv, 8)) return errno(14);
    request.argc = copyExecVector(argv, &request.argv, &request.argv_lengths) catch |err| return errno(execCopyErrno(err));
    if (envp != 0) {
        if (!validUserSlice(envp, 8)) return errno(14);
        request.envc = copyExecVector(envp, &request.envp, &request.envp_lengths) catch |err| return errno(execCopyErrno(err));
    }
    user_threads[current_thread].exec_request = request;
    thread_switch_requested = true;
    // The bootstrap image may exec before cooperative user threads exist.
    // In that path user_thread_resume is bypassed by the assembly entry, so
    // arm the loader pause here instead of returning to the old image.
    exec_pause_requested = true;
    if (execve_hook) |hook| return hook(path, argv, envp);
    return errno(38);
}

fn execveAt(directory_fd: u64, path: u64, argv: u64, envp: u64, flags: u64) u64 {
    // Git's fexecve path is execveat(fd, "", ..., AT_EMPTY_PATH). The helper
    // image is the pinned Git runtime, so the descriptor identity does not
    // change which ELF must be loaded; retain the caller's argv and envp.
    if (flags == 0x1000) {
        _ = directory_fd;
        if (path != 0 and !validUserSlice(path, 1)) return errno(14);
        if (path != 0 and @as(*const u8, @ptrFromInt(path)).* != 0) return execve(path, argv, envp);
        var request = ExecRequest{};
        request.path_len = 8;
        @memcpy(request.path[0..8], "/bin/git");
        if (argv == 0 or !validUserSlice(argv, 8)) return errno(14);
        request.argc = copyExecVector(argv, &request.argv, &request.argv_lengths) catch |err| return errno(execCopyErrno(err));
        if (envp != 0) {
            if (!validUserSlice(envp, 8)) return errno(14);
            request.envc = copyExecVector(envp, &request.envp, &request.envp_lengths) catch |err| return errno(execCopyErrno(err));
        }
        user_threads[current_thread].exec_request = request;
        thread_switch_requested = true;
        exec_pause_requested = true;
        if (execve_hook) |hook| return hook(0, argv, envp);
        return errno(38);
    }
    if (flags != 0 or path == 0) return errno(22);
    return execve(path, argv, envp);
}

const ExecCopyError = error{ Fault, TooMany, TooLong };

fn execCopyErrno(err: ExecCopyError) i64 {
    return switch (err) {
        error.Fault => 14, // EFAULT
        error.TooMany, error.TooLong => 7, // E2BIG
    };
}

fn copyExecString(address: u64, output: *[max_exec_string]u8) ExecCopyError!usize {
    if (address == 0) return error.Fault;
    var length: usize = 0;
    while (length < max_exec_string) : (length += 1) {
        const current = std.math.add(u64, address, length) catch return error.Fault;
        if (!validUserSlice(current, 1)) return error.Fault;
        const byte = @as(*const u8, @ptrFromInt(current)).*;
        if (byte == 0) return length;
        output[length] = byte;
    }
    return error.TooLong;
}

fn copyExecVector(address: u64, output: *[max_exec_arguments][max_exec_string]u8, lengths: *[max_exec_arguments]u16) ExecCopyError!usize {
    var count: usize = 0;
    while (count < max_exec_arguments) : (count += 1) {
        const pointer_address = std.math.add(u64, address, count * 8) catch return error.Fault;
        if (!validUserSlice(pointer_address, 8)) return error.Fault;
        const pointer = read64(@as([*]const u8, @ptrFromInt(pointer_address)));
        if (pointer == 0) return count;
        const length = try copyExecString(pointer, &output[count]);
        lengths[count] = @intCast(length);
    }
    return error.TooMany;
}

pub fn takeExecRequest() ?ExecRequestEnvelope {
    // A syscall can yield immediately and select the parent, so do not infer
    // ownership from current_thread. Scan the fixed scheduler table and
    // return the originating pid with the copied request.
    for (&user_threads, 0..) |*thread, thread_index| {
        if (thread.exec_request) |request| {
            thread.exec_request = null;
            current_thread = thread_index;
            current_pid = thread.pid;
            _ = vfs.changeDirectory(thread.cwd[0..thread.cwd_len]) catch {};
            return .{ .thread_id = thread.pid, .workspace_id = thread.workspace_id, .request = request };
        }
    }
    return null;
}

pub fn currentWorkingDirectory() []const u8 {
    if (current_thread < user_threads.len and user_threads_enabled)
        return user_threads[current_thread].cwd[0..user_threads[current_thread].cwd_len];
    return vfs.currentWorkingDirectory();
}

pub const UserResumeContext = struct { rip: u64, rsp: u64, workspace_id: u8 };

/// Return the userspace continuation selected by the scheduler after a
/// syscall boundary.  The process loader uses this when a fork/exec child
/// yields back to its parent; otherwise its outer entry loop would restart
/// the child's initial ELF entry instead of the saved syscall frame.
pub fn currentUserResume() ?UserResumeContext {
    if (!user_threads_enabled or current_thread >= user_threads.len) return null;
    const thread = &user_threads[current_thread];
    // A process-child slot can retain the syscall return value while its
    // exec image is being handed to the loader.  It is not an instruction
    // pointer; never feed that small value back into enter_user.
    if (thread.frame[0] < 0x10000 or thread.rsp == 0) return null;
    return .{ .rip = thread.frame[0], .rsp = thread.rsp, .workspace_id = thread.workspace_id };
}

pub fn configureExecve(hook: ?*const fn (u64, u64, u64) callconv(.c) u64) void {
    execve_hook = hook;
}

fn wait4(pid: u64, status: u64, options: u64, usage: u64) u64 {
    // Validate the selector and flags even though this single-process kernel
    // has no child to reap yet.  Returning ECHILD for a malformed request
    // hides caller bugs and differs from Linux's EINVAL contract.
    if ((options & ~@as(u64, 0x0b)) != 0) return errno(22);
    if (status != 0 and !validUserSlice(status, 4)) return errno(14);
    if (usage != 0 and !validUserSlice(usage, 144)) return errno(14);
    var matching_child = false;
    for (&user_threads) |*child| {
        if (child.kind != .process_child or child.parent_slot >= user_threads.len or
            user_threads[child.parent_slot].workspace_id != user_threads[current_thread].workspace_id or
            child.state != .exited or !workspaceDone(child.workspace_id)) continue;
        if (pid > 0 and pid != ~@as(u64, 0) and child.pid != pid) continue;
        if (status != 0) @as(*align(1) u32, @ptrFromInt(status)).* = @truncate((child.exit_status & 0xff) << 8);
        const child_pid = child.pid;
        if (workspace_release_hook) |hook| hook(child.workspace_id);
        // Releasing a child may destroy its address space while the parent is
        // still executing this syscall. Reassert the caller's workspace and
        // CR3 before returning, so the saved wait4 frame cannot resume on a
        // stale child context.
        if (workspace_activate_hook) |activate| activate(user_threads[current_thread].workspace_id);
        child.* = .{};
        return child_pid;
    }
    for (user_threads) |child| {
        if (child.kind != .process_child or child.parent_slot >= user_threads.len or
            user_threads[child.parent_slot].workspace_id != user_threads[current_thread].workspace_id or
            child.state == .unused or workspaceDone(child.workspace_id)) continue;
        if (pid > 0 and pid != ~@as(u64, 0) and child.pid != pid) continue;
        matching_child = true;
        break;
    }
    if (matching_child and (options & 1) == 0 and user_threads_enabled) {
        user_threads[current_thread].wait_address = 0;
        user_threads[current_thread].pending_read_socket = null;
        user_threads[current_thread].pending_read_address = 0;
        user_threads[current_thread].pending_read_length = 0;
        user_threads[current_thread].pending_read_eof = false;
        user_threads[current_thread].pending_poll_address = 0;
        user_threads[current_thread].pending_poll_count = 0;
        user_threads[current_thread].pending_poll_sockets = .{false} ** 32;
        user_threads[current_thread].state = .blocked;
        user_threads[current_thread].wait_child_pid = if (pid == 0) ~@as(u64, 0) else pid;
        user_threads[current_thread].wait_status = status;
        thread_switch_requested = true;
        return 0;
    }
    if (matching_child and (options & 1) != 0) return 0;
    return errno(10); // ECHILD: CSOS has no child process yet.
}

fn waitId(id_type: u64, id: u64, info: u64, options: u64) u64 {
    _ = id;
    // P_* selectors are 0..4.  Keep the Linux waitid flag layout so callers
    // can compose WEXITED/WSTOPPED/WCONTINUED with WNOHANG/WNOWAIT.
    const waitid_flags = @as(u64, 0x1 | 0x2 | 0x4 | 0x8 | 0x01000000);
    if (id_type > 4 or (options & ~waitid_flags) != 0 or
        (options & 0x0e) == 0) return errno(22);
    if (info != 0 and !validUserSlice(info, 128)) return errno(14);
    return errno(10);
}

fn madvise(address: u64, length: u64, advice: u64) u64 {
    const supported = advice == 0 or advice == 1 or advice == 2 or advice == 3 or
        advice == 4 or advice == 8 or advice == 9 or advice == 10 or advice == 11 or
        advice == 12 or advice == 13 or advice == 14 or advice == 15 or advice == 25;
    if (!supported or length == 0) return errno(22);
    const noreserve_start: u64 = 0x000000c000000000;
    const noreserve_end: u64 = 0x00007f0000000000;
    const lazy_range = address >= noreserve_start and address < noreserve_end and
        length <= noreserve_end - address;
    if (!lazy_range and !validUserSlice(address, length)) return errno(22);
    // Hints are accepted, but reclaim remains controlled by the process
    // lifecycle and never trusts userspace to discard live mappings.
    return 0;
}

fn memoryLock(address: u64, length: u64) u64 {
    if (length == 0 or !validUserSlice(address, length)) return errno(14);
    // CSOS does not reclaim locked user pages in the current loader model;
    // accepting the validated range preserves the Linux ABI without making
    // an unverified physical-pinning claim.
    return 0;
}

fn memoryUnlock(address: u64, length: u64) u64 {
    if (length == 0 or !validUserSlice(address, length)) return errno(14);
    return 0;
}

fn memoryLockAll(flags: u64) u64 {
    if ((flags & ~@as(u64, 3)) != 0) return errno(22);
    return 0;
}

fn memoryUnlockAll() u64 {
    return 0;
}

fn fadvise64(fd: u64, offset: u64, length: u64, advice: u64) u64 {
    if (!vfs.isOpen(@intCast(fd))) return errno(9);
    if (advice > 5 or offset > std.math.maxInt(u64) - length) return errno(22);
    return 0;
}

fn closeRange(first: u64, last: u64, flags: u64) u64 {
    if ((flags & ~@as(u64, 2)) != 0 or first > last or first >= 1024) return errno(22);
    const limit = @min(last, 1023);
    var fd = first;
    while (fd <= limit) : (fd += 1) {
        if (socketIndex(fd)) |_| {
            if ((flags & 2) == 0) {
                _ = close(fd);
            } else if (socketAliasForThread(current_thread, fd)) |alias| {
                // CLOSE_RANGE_CLOEXEC applies to this descriptor entry, not
                // the backing socket object.  Mutating the object would make
                // the flag leak into the parent and sibling descriptors.
                alias.close_on_exec = true;
                const workspace = user_threads[current_thread].workspace_id;
                for (&workspace_fd_aliases[workspace]) |*workspace_alias| {
                    if (workspace_alias.used and workspace_alias.fd == alias.fd and workspace_alias.socket_index == alias.socket_index)
                        workspace_alias.close_on_exec = true;
                }
            } else if (fd >= socket_fd_base) {
                const index: usize = @intCast(fd - socket_fd_base);
                const workspace = user_threads[current_thread].workspace_id;
                workspace_socket_cloexec[workspace][index] = true;
                for (&user_threads) |*peer| {
                    if (peer.workspace_id == workspace) peer.direct_socket_cloexec[index] = true;
                }
            } else if (socketIndex(fd)) |index| {
                sockets[index].close_on_exec = true;
            }
        } else if (vfs.isOpen(@intCast(fd))) {
            if ((flags & 2) != 0) _ = vfs.setDescriptorFlags(@intCast(fd), 1) catch {} else _ = vfs.close(@intCast(fd)) catch {};
        }
    }
    return 0;
}

fn faccessat2(directory_fd: u64, path: u64, mode: u64, flags: u64) u64 {
    _ = directory_fd;
    if (flags != 0 and flags != 0x200) return errno(22);
    return access(path, @truncate(mode));
}

fn syncFile(fd: u64) u64 {
    if (!vfs.isOpen(@intCast(fd))) return errno(9);
    return 0;
}

fn syncAll() u64 {
    return 0;
}

fn epollCreate(flags: u64) u64 {
    if ((flags & ~@as(u64, 0x80000)) != 0) return errno(22);
    const fd = vfs.openEpoll() catch |err| return vfsError(err);
    epoll_watches[fd] = .{EpollWatch{}} ** max_epoll_watch;
    if ((flags & 0x80000) != 0) _ = vfs.setDescriptorFlags(fd, 1) catch return errno(9);
    return fd;
}

fn epollCtl(epfd: u64, operation: u64, target: u64, event: u64) u64 {
    if (!vfs.isEpoll(@intCast(epfd)) or (!vfs.isOpen(@intCast(target)) and socketIndex(target) == null) or target == epfd) return errno(9);
    if (event == 0 and operation != 2) return errno(14);
    if (operation != 2 and !validUserSlice(event, 16)) return errno(14);
    const watches = &epoll_watches[@intCast(epfd)];
    if (operation == 1 or operation == 2 or operation == 3) {
        var slot: ?usize = null;
        for (watches, 0..) |watch, index| if (watch.active and watch.fd == target) { slot = index; break; };
        if (operation == 2) {
            if (slot) |index| watches[index].active = false else return errno(2);
            return 0;
        }
        if (operation == 3) {
            const index = slot orelse return errno(2);
            const input: [*]const u8 = @ptrFromInt(event);
            watches[index].events = read32(input);
            watches[index].data = read64(input + 8);
            watches[index].generation = vfs.descriptorGeneration(@intCast(target)) catch 0;
            watches[index].active = true;
            return 0;
        }
        if (slot != null) return errno(17);
        const input: [*]const u8 = @ptrFromInt(event);
        for (watches) |*watch| if (!watch.active) {
            watch.* = .{ .fd = @intCast(target), .generation = vfs.descriptorGeneration(@intCast(target)) catch 0, .events = read32(input), .data = read64(input + 8), .active = true };
            return 0;
        };
        return errno(28);
    }
    if (operation == 3) return errno(22);
    return errno(22);
}

fn epollWait(epfd: u64, output: u64, capacity: u64, timeout: i64) u64 {
    const bytes_len = std.math.mul(u64, capacity, 16) catch return errno(22);
    if (!vfs.isEpoll(@intCast(epfd)) or capacity == 0 or capacity > max_epoll_watch or !validUserSlice(output, bytes_len)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(output);
    var ready: u64 = 0;
    for (&epoll_watches[@intCast(epfd)]) |*watch| {
        if (!watch.active or ready == capacity) continue;
        if (socketIndex(watch.fd)) |socket_index| {
            if (sockets[socket_index].connection == null and (!sockets[socket_index].local_pair or sockets[socket_index].local_len == 0)) continue;
        } else if (vfs.isPidfd(watch.fd)) {
            if (!vfs.pidfdReady(watch.fd)) continue;
        } else {
            if (!vfs.isOpen(watch.fd)) continue;
            const generation = vfs.descriptorGeneration(watch.fd) catch continue;
            if (generation != watch.generation) {
                watch.active = false;
                continue;
            }
        }
        const item = bytes + ready * 16;
        put32(item, watch.events);
        put32(item + 4, 0);
        put64(item + 8, watch.data);
        ready += 1;
        if ((watch.events & (1 << 30)) != 0) watch.active = false;
    }
    if (ready == 0 and timeout > 0) if (idle_hook) |hook| hook();
    return ready;
}

fn validateTimestampVector(times_address: u64, bytes: u64) bool {
    return times_address == 0 or validUserSlice(times_address, bytes);
}

fn utimes(path_address: u64, times_address: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    if (!validateTimestampVector(times_address, 32)) return errno(14);
    _ = vfs.infoAt(-100, path) catch |err| return vfsError(err);
    return 0;
}

fn futimesat(directory_fd: u64, path_address: u64, times_address: u64) u64 {
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    if (!validateTimestampVector(times_address, 32)) return errno(14);
    _ = vfs.infoAt(@bitCast(directory_fd), path) catch |err| return vfsError(err);
    return 0;
}

fn utimensat(directory_fd: u64, path_address: u64, times_address: u64, flags: u64) u64 {
    if ((flags & ~@as(u64, 0x100)) != 0) return errno(22);
    var path_buffer: [256]u8 = undefined;
    const path = userString(path_address, &path_buffer) orelse return errno(14);
    if (!validateTimestampVector(times_address, 32)) return errno(14);
    _ = vfs.infoAt(@bitCast(directory_fd), path) catch |err| return vfsError(err);
    return 0;
}

fn futex(address: u64, operation: u64, expected: u64, timeout: u64, address2: u64) u64 {
    _ = timeout;
    if ((address & 3) != 0 or !validUserSlice(address, 4)) return errno(14);
    const command = operation & 0x7f;
    const word: *align(1) volatile u32 = @ptrFromInt(address);
    switch (command) {
        0 => { // FUTEX_WAIT: never sleep indefinitely in the single-thread core.
            if (word.* != @as(u32, @truncate(expected))) {
                // Linux reports EAGAIN when the value changed before the
                // wait was queued.  In the cooperative CSOS scheduler that
                // fast path must still yield, otherwise a launcher can spin
                // on a private futex forever and starve the worker that made
                // the value change (notably WPE process startup).
                if (user_threads_enabled) {
                    active_user_thread = null;
                    thread_switch_requested = true;
                }
                return errno(11);
            }
            if (user_threads_enabled) {
                user_threads[current_thread].state = .blocked;
                user_futex_blocks += 1;
                user_threads[current_thread].wait_address = address;
                user_threads[current_thread].wait_workspace = user_threads[current_thread].workspace_id;
                user_threads[current_thread].wait_private = (operation & 0x80) != 0;
                thread_switch_requested = true;
                return 0;
            }
            if (idle_hook) |hook| hook();
            return errno(11);
        },
        1 => return wakeUserThreads(address, expected,
            if ((operation & 0x80) != 0) user_threads[current_thread].workspace_id else null,
            (operation & 0x80) != 0),
        3 => { // FUTEX_REQUEUE: wake a bounded set and move the rest.
            if (address2 == 0 or (address2 & 3) != 0 or !validUserSlice(address2, 4)) return errno(14);
            const private = (operation & 0x80) != 0;
            const workspace = user_threads[current_thread].workspace_id;
            var woken: u64 = 0;
            var moved: u64 = 0;
            for (&user_threads) |*thread| {
                if (thread.state != .blocked or thread.wait_address != address or
                    thread.wait_private != private or
                    (private and thread.wait_workspace != workspace)) continue;
                if (woken < expected) {
                    thread.state = .runnable;
                    thread.wait_address = 0;
                    thread.result = 0;
                    woken += 1;
                } else {
                    thread.wait_address = address2;
                    moved += 1;
                }
            }
            return woken + moved;
        },
        else => return errno(38),
    }
}

fn schedGetAffinity(pid: u64, size: u64, mask: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (size < 8 or !validUserSlice(mask, size)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(mask);
    @memset(bytes[0..@intCast(size)], 0);
    // The userspace scheduler currently exposes one runnable CPU to each
    // process; secondary kernel workers do not imply extra userspace CPUs.
    bytes[0] = 1;
    return 8;
}

fn schedSetAffinity(pid: u64, size: u64, mask: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (size < 8 or !validUserSlice(mask, size)) return errno(22);
    const bytes: [*]const u8 = @ptrFromInt(mask);
    if ((bytes[0] & 1) == 0) return errno(22);
    var index: u64 = 1;
    while (index < size) : (index += 1) if (bytes[index] != 0) return errno(22);
    return 0;
}

fn getcpu(cpu: u64, node: u64) u64 {
    if (cpu != 0 and !validUserSlice(cpu, 4)) return errno(14);
    if (node != 0 and !validUserSlice(node, 4)) return errno(14);
    if (cpu != 0) @as(*align(1) u32, @ptrFromInt(cpu)).* = 0;
    if (node != 0) @as(*align(1) u32, @ptrFromInt(node)).* = 0;
    return 0;
}

fn getPriority(which: u64, who: u64) u64 {
    if (which > 2) return errno(22);
    if (who != 0 and who != 1) return errno(3);
    return @intCast(process_nice + 20); // Linux exposes nice + 20.
}

fn setPriority(which: u64, who: u64, priority: i64) u64 {
    if (which > 2) return errno(22);
    if (who != 0 and who != 1) return errno(3);
    if (priority < -20 or priority > 19) return errno(22);
    process_nice = @intCast(priority);
    return 0;
}

fn setScheduler(pid: u64, policy: u64, param: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (policy != 0 or (param != 0 and !validUserSlice(param, 4))) return errno(22);
    return 0;
}

fn getScheduler(pid: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    return 0; // SCHED_OTHER
}

fn getSchedulerParam(pid: u64, output: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (!validUserSlice(output, 4)) return errno(14);
    @as(*align(1) i32, @ptrFromInt(output)).* = 0;
    return 0;
}

fn schedRrInterval(pid: u64, output: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (!validUserSlice(output, 16)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(output);
    @memset(bytes[0..16], 0);
    put64(bytes, 0);
    put64(bytes + 8, 10_000_000); // 10 ms cooperative scheduler quantum
    return 0;
}

fn setTidAddress(address: u64) u64 {
    if (address != 0 and !validUserSlice(address, 4)) return errno(14);
    clear_tid_address = address;
    user_threads[current_thread].clear_tid = address;
    return current_thread + 1;
}

fn umask(value: u64) u64 {
    const previous = process_umask;
    process_umask = @truncate(value & 0o777);
    return previous;
}

fn getRlimit(resource: u64, output: u64) u64 {
    if (resource > 16 or !validUserSlice(output, 16)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(output);
    const limit: u64 = switch (resource) {
        3 => limit_stack, // RLIMIT_STACK
        7 => limit_nofile, // RLIMIT_NOFILE
        9 => limit_address_space, // RLIMIT_AS
        else => std.math.maxInt(u64),
    };
    const hard: u64 = switch (resource) {
        3 => hard_limit_stack,
        7 => hard_limit_nofile,
        9 => hard_limit_address_space,
        else => limit,
    };
    put64(bytes, limit);
    put64(bytes + 8, hard);
    return 0;
}

fn getRusage(who: u64, output: u64) u64 {
    const children = std.math.maxInt(u64);
    if (who != 0 and who != 1 and who != children or !validUserSlice(output, 144)) return errno(22);
    const bytes: [*]u8 = @ptrFromInt(output);
    @memset(bytes[0..144], 0);
    const seconds = if (who == children) 0 else monotonic_time_ns / 1_000_000_000;
    const micros = if (who == children) 0 else (monotonic_time_ns % 1_000_000_000) / 1_000;
    put64(bytes, seconds);
    put64(bytes + 8, micros);
    if (who != children) put64(bytes + 40, 192 * 1024); // ru_maxrss in KiB
    return 0;
}

fn sysinfo(output: u64) u64 {
    if (!validUserSlice(output, 112)) return errno(14);
    const bytes: [*]u8 = @ptrFromInt(output);
    @memset(bytes[0..112], 0);
    put64(bytes, monotonic_time_ns / 1_000_000_000); // uptime
    put64(bytes + 8, 0); // load averages, fixed-point 0.0
    put64(bytes + 16, 0);
    put64(bytes + 24, 0);
    put64(bytes + 32, 256 * 1024 * 1024 / 4096); // totalram units
    put64(bytes + 40, 192 * 1024 * 1024 / 4096); // freeram units
    put64(bytes + 48, 0); // sharedram
    put64(bytes + 56, 64 * 1024 * 1024 / 4096); // bufferram units
    put64(bytes + 64, 0); // totalswap
    put64(bytes + 72, 0); // freeswap
    put16(bytes + 80, 1); // procs
    put64(bytes + 88, 128 * 1024 * 1024 / 4096); // totalhigh units
    put64(bytes + 96, 96 * 1024 * 1024 / 4096); // freehigh units
    put32(bytes + 104, 4096); // mem_unit
    return 0;
}

fn times(output: u64) u64 {
    if (output != 0 and !validUserSlice(output, 32)) return errno(14);
    const ticks = monotonic_time_ns / 10_000_000; // USER_HZ=100
    if (output != 0) {
        const bytes: [*]u8 = @ptrFromInt(output);
        @memset(bytes[0..32], 0);
        put64(bytes, ticks);
    }
    return ticks;
}

fn setRlimit(resource: u64, address: u64) u64 {
    if (resource > 16 or !validUserSlice(address, 16)) return errno(22);
    const bytes: [*]const u8 = @ptrFromInt(address);
    const soft = read64(bytes);
    const hard = read64(bytes + 8);
    if (soft > hard or (resource == 7 and hard > 32) or (resource == 3 and hard > 16 * 1024 * 1024) or (resource == 9 and hard > 256 * 1024 * 1024)) return errno(1);
    switch (resource) {
        3 => { limit_stack = soft; hard_limit_stack = hard; },
        7 => { limit_nofile = soft; hard_limit_nofile = hard; },
        9 => { limit_address_space = soft; hard_limit_address_space = hard; },
        else => {},
    }
    return 0;
}

fn prlimit64(pid: u64, resource: u64, new_limit: u64, old_limit: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    if (old_limit != 0) {
        const result = getRlimit(resource, old_limit);
        if (result != 0) return result;
    }
    if (new_limit != 0) return setRlimit(resource, new_limit);
    return 0;
}

fn getGroups(count: u64, output: u64) u64 {
    if (count == 0) return 1;
    const bytes = std.math.mul(u64, count, 4) catch return errno(22);
    if (!validUserSlice(output, bytes)) return errno(14);
    @as(*align(1) u32, @ptrFromInt(output)).* = 0;
    return 1;
}

fn setGroups(count: u64, groups: u64) u64 {
    const bytes = std.math.mul(u64, count, 4) catch return errno(22);
    if (count > 1 or (count != 0 and !validUserSlice(groups, bytes))) return errno(22);
    return 0;
}

fn setResUid(real: u64, effective: u64, saved: u64) u64 {
    if ((real != 0 and real != std.math.maxInt(u32)) or (effective != 0 and effective != std.math.maxInt(u32)) or (saved != 0 and saved != std.math.maxInt(u32))) return errno(1);
    return 0;
}

fn getResUid(real: u64, effective: u64, saved: u64) u64 {
    if (!validUserSlice(real, 4) or !validUserSlice(effective, 4) or !validUserSlice(saved, 4)) return errno(14);
    @as(*align(1) u32, @ptrFromInt(real)).* = 0;
    @as(*align(1) u32, @ptrFromInt(effective)).* = 0;
    @as(*align(1) u32, @ptrFromInt(saved)).* = 0;
    return 0;
}

fn setResGid(real: u64, effective: u64, saved: u64) u64 {
    return setResUid(real, effective, saved);
}

fn personality(value: u64) u64 {
    if (value == 0xffffffffffffffff or value == 0) return 0;
    return errno(22);
}

fn sigaltstack(new_stack: u64, old_stack: u64) u64 {
    if (old_stack != 0) {
        if (!validUserSlice(old_stack, 32)) return errno(14);
        @memcpy(@as([*]u8, @ptrFromInt(old_stack))[0..32], &signal_stack);
    }
    if (new_stack != 0) {
        if (!validUserSlice(new_stack, 32)) return errno(14);
        @memcpy(&signal_stack, @as([*]const u8, @ptrFromInt(new_stack))[0..32]);
    }
    return 0;
}

fn prctl(option: u64, arg2: u64, _: u64) u64 {
    if (option == 15) { // PR_SET_NAME
        if (!validUserSlice(arg2, 16)) return errno(14);
        const source: [*]const u8 = @ptrFromInt(arg2);
        @memcpy(&process_name, source[0..16]);
        process_name[15] = 0;
        return 0;
    }
    if (option == 16) { // PR_GET_NAME
        if (!validUserSlice(arg2, 16)) return errno(14);
        const target: [*]u8 = @ptrFromInt(arg2);
        @memcpy(target[0..16], &process_name);
        return 0;
    }
    return errno(22);
}

fn setPgid(pid: u64, group: u64) u64 {
    if ((pid != 0 and pid != 1) or (group != 0 and group != 1)) return errno(3);
    process_group = if (group == 0) 1 else group;
    return 0;
}

fn getPgid(pid: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    return process_group;
}

fn setSid() u64 {
    process_group = 1;
    process_session = 1;
    return process_session;
}

fn getSid(pid: u64) u64 {
    if (pid != 0 and pid != 1) return errno(3);
    return process_session;
}

fn setRegId(real: u64, effective: u64) u64 {
    if ((real != 0 and real != std.math.maxInt(u32)) or (effective != 0 and effective != std.math.maxInt(u32))) return errno(1);
    return 0;
}

fn capGet(header: u64, data: u64) u64 {
    if (!validUserSlice(header, 8) or !validUserSlice(data, 12)) return errno(14);
    const output: [*]u8 = @ptrFromInt(data);
    @memset(output[0..12], 0);
    return 0;
}

fn capSet(header: u64, data: u64) u64 {
    if (!validUserSlice(header, 8) or !validUserSlice(data, 12)) return errno(14);
    return 0;
}

fn getResGid(real: u64, effective: u64, saved: u64) u64 {
    return getResUid(real, effective, saved);
}

fn setRobustList(head: u64, length: u64) u64 {
    if (length != 24 or (head != 0 and !validUserSlice(head, length))) return errno(22);
    robust_head = head;
    robust_len = length;
    user_threads[current_thread].robust = head;
    user_threads[current_thread].robust_size = length;
    return 0;
}

fn getRobustList(pid: u64, head_address: u64, length_address: u64, _: u64) u64 {
    const slot = if (pid == 0) current_thread else pid - 1;
    if (slot >= user_threads.len or (slot != current_thread and user_threads[slot].state != .runnable and user_threads[slot].state != .blocked)) return errno(3);
    if (!validUserSlice(head_address, 8) or !validUserSlice(length_address, 8)) return errno(14);
    @as(*align(1) u64, @ptrFromInt(head_address)).* = user_threads[slot].robust;
    @as(*align(1) u64, @ptrFromInt(length_address)).* = user_threads[slot].robust_size;
    return 0;
}

fn validUserSlice(address: u64, length: u64) bool {
    if (length > std.math.maxInt(usize)) return false;
    if (inRegion(address, length, user_base, user_size) or
        inRegion(address, length, stack_base, stack_size) or
        inRegion(address, length, user_base + user_size, break_limit - (user_base + user_size)) or
        inRegion(address, length, mmap_base, mmap_limit - mmap_base) or
        inRegion(address, length, mmap_limit, device_mmap_limit - mmap_limit)) return true;
    if (user_slice_hook) |hook| return hook(address, length);
    return false;
}

fn mmapRegion(address: u64, length: u64) bool {
    return inRegion(address, length, mmap_base, mmap_limit - mmap_base) or
        inRegion(address, length, mmap_limit, device_mmap_limit - mmap_limit);
}

fn inRegion(address: u64, length: u64, base: u64, size: u64) bool {
    if (address < base or length > size) return false;
    return address - base <= size - length;
}

test "syscall region checks include exact edges without wrapping" {
    try std.testing.expect(inRegion(0x1000, 0x1000, 0x1000, 0x2000));
    try std.testing.expect(inRegion(0x2000, 0x1000, 0x1000, 0x2000));
    try std.testing.expect(!inRegion(0x2001, 0x1000, 0x1000, 0x2000));
    try std.testing.expect(!inRegion(std.math.maxInt(u64) - 3, 8, 0, std.math.maxInt(u64)));
}

test "statfs ABI writes Linux-compatible volume fields" {
    var output: [120]u8 = undefined;
    const saved_base = user_base;
    const saved_size = user_size;
    defer {
        user_base = saved_base;
        user_size = saved_size;
    }
    user_base = @intFromPtr(&output);
    user_size = output.len;
    try @import("std").testing.expectEqual(@as(u64, 0), writeStatfs(@intFromPtr(&output)));
    try @import("std").testing.expectEqual(@as(u64, 0xEF53), read64(output[0..].ptr));
    try @import("std").testing.expectEqual(@as(u64, 4096), read64(output[8..].ptr));
    try @import("std").testing.expectEqual(@as(u64, 1024), read64(output[16..].ptr));
}

test "file mutation syscall flags reject unsupported operations" {
    try @import("std").testing.expectEqual(@as(u64, errno(22)), unlinkat(0, 0, 1));
    try @import("std").testing.expectEqual(@as(u64, errno(22)), renameat(0, 0, 0, 1));
}

fn uiChannelCreate() u64 {
    for (ui_mailbox_used, 0..) |used, index| {
        if (!used) {
            ui_mailbox_used[index] = true;
            ui_mailboxes[index] = .{};
            return index + 1;
        }
    }
    return errno(12);
}

fn uiChannelSend(channel: u64, address: u64, length: u64) u64 {
    if (channel == 0 or channel > ui_mailboxes.len or length < 2 or length > ui_ipc.max_message or !validUserSlice(address, length)) return errno(22);
    const bytes: []const u8 = @as([*]const u8, @ptrFromInt(address))[0..@intCast(length)];
    if (ui_mailbox_used[channel - 1] and ui_mailboxes[channel - 1].push(bytes)) {
        ui_send_count += 1;
        return length;
    }
    return errno(11);
}

fn uiChannelReceive(channel: u64, address: u64, capacity_bytes: u64) u64 {
    if (channel == 0 or channel > ui_mailboxes.len or capacity_bytes < 2 or capacity_bytes > ui_ipc.max_message or !validUserSlice(address, capacity_bytes)) return errno(22);
    const output: []u8 = @as([*]u8, @ptrFromInt(address))[0..@intCast(capacity_bytes)];
    const length = ui_mailboxes[channel - 1].pop(output) orelse return errno(11);
    return @intCast(length);
}

pub fn receiveUiBootFrame(output: []u8) ?usize {
    if (!ui_mailbox_used[0]) return null;
    return ui_mailboxes[0].pop(output);
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
