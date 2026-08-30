const serial = @import("serial");
const vfs = @import("vfs");
const net = @import("net");

var user_base: u64 = 0;
var user_size: u64 = 0;
var stack_base: u64 = 0;
var stack_size: u64 = 0;
var program_break: u64 = 0;
var break_limit: u64 = 0;
var mmap_next: u64 = 0;
var mmap_base: u64 = 0;
var mmap_limit: u64 = 0;
var writes: usize = 0;
var process_exit_status: u64 = 0;
var process_pause: ?Pause = null;
var mmap_protect_hook: ?*const fn (u64, u64, bool, bool) callconv(.c) bool = null;
var mmap_unmap_hook: ?*const fn (u64, u64) callconv(.c) bool = null;
var stdin_hook: ?*const fn ([*]u8, usize) callconv(.c) usize = null;
var idle_hook: ?*const fn () callconv(.c) void = null;
pub var file_mmaps: u64 = 0;
pub var protected_mmaps: u64 = 0;
pub var unmapped_mmaps: u64 = 0;
pub var sendfile_calls: u64 = 0;
var network_stack: ?*net.Stack = null;
var sockets: [4]Socket = .{Socket{}} ** 4;
var unknown_seen: [512]bool = .{false} ** 512;
pub export var syscall_kernel_rsp: u64 = 0;
pub export var syscall_user_rsp: u64 = 0;

pub const Pause = struct { instruction: u64, stack: u64 };

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
    writes = 0;
    unknown_seen = .{false} ** unknown_seen.len;
    process_exit_status = 0xffffffffffffffff;
    process_pause = null;
    sockets = .{Socket{}} ** sockets.len;
    vfs.reset();
}

pub fn completedWrites() usize {
    return writes;
}

pub fn configureNetwork(stack: *net.Stack) void {
    network_stack = stack;
}

pub fn configureMmap(protect_hook: ?*const fn (u64, u64, bool, bool) callconv(.c) bool, unmap_hook: ?*const fn (u64, u64) callconv(.c) bool) void {
    mmap_protect_hook = protect_hook;
    mmap_unmap_hook = unmap_hook;
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
        16 => errno(25),
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
fn put64(target: [*]u8, value: u64) void { var i: usize = 0; while (i < 8) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
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
    if (!inRegion(address, aligned_length, mmap_base, mmap_limit - mmap_base)) return errno(12);
    const hook = mmap_protect_hook orelse return errno(12);
    if (!hook(address, aligned_length, (protection & 2) != 0, (protection & 4) != 0)) return errno(12);
    protected_mmaps += 1;
    return 0;
}

fn munmap(address: u64, length: u64) u64 {
    if ((address & 4095) != 0 or length == 0) return errno(22);
    const aligned_length = (length + 4095) & ~@as(u64, 4095);
    if (!inRegion(address, aligned_length, mmap_base, mmap_limit - mmap_base)) return errno(22);
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
        inRegion(address, length, mmap_base, mmap_limit - mmap_base);
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
