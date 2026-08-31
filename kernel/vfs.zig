const busybox = @embedFile("busybox_elf");
const fat16 = @import("fat16");
const hello = "Hello from initramfs\n";

const max_fds = 32;

const Kind = enum { unused, console, file, directory, device };
const Node = enum { root, bin, dev, dri, busybox, hello, framebuffer, drm, render, disk };

const Descriptor = struct {
    kind: Kind = .unused,
    node: Node = .root,
    offset: usize = 0,
    size: usize = 0,
    fat_name: [11]u8 = .{' '} ** 11,
};

pub const Info = struct {
    mode: u32,
    size: u64,
    directory: bool,
};

var descriptors: [max_fds]Descriptor = .{Descriptor{}} ** max_fds;
var disk: ?*fat16.Volume = null;

pub fn mount(volume: *fat16.Volume) void { disk = volume; }

pub fn reset() void {
    descriptors = .{Descriptor{}} ** max_fds;
    descriptors[1].kind = .console;
    descriptors[2].kind = .console;
}

pub fn openAt(directory_fd: i64, path: []const u8, flags: u64) !usize {
    var fd: usize = 3;
    while (fd < descriptors.len and descriptors[fd].kind != .unused) : (fd += 1) {}
    if (fd == descriptors.len) return error.TooManyFiles;
    if (toFatName(path)) |fat_name| if (disk) |volume| {
        var size = volume.fileSize(&fat_name) catch |err| switch (err) {
            error.NotFound => if ((flags & 0x40) != 0) @as(usize, 0) else return error.NotFound,
            else => return err,
        };
        if ((flags & 0x200) != 0 or (size == 0 and (flags & 0x40) != 0)) {
            try volume.writeRootFile(&fat_name, "");
            size = 0;
        }
        descriptors[fd] = .{ .kind = .file, .node = .disk, .size = size, .fat_name = fat_name };
        return fd;
    };
    const node = try resolve(directory_fd, path);
    const info = nodeInfo(node);
    descriptors[fd] = .{ .kind = if (info.directory) .directory else if (node == .framebuffer or node == .drm or node == .render) .device else .file, .node = node, .size = @intCast(info.size) };
    return fd;
}

pub fn close(fd: usize) !void {
    if (fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    descriptors[fd] = .{};
}

pub fn duplicate(old_fd: usize, new_fd: usize) !usize {
    if (old_fd >= descriptors.len or new_fd >= descriptors.len or descriptors[old_fd].kind == .unused) return error.BadFd;
    if (old_fd != new_fd) descriptors[new_fd] = descriptors[old_fd];
    return new_fd;
}

pub fn isOpen(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind != .unused;
}

pub fn isDiskFile(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .file and descriptors[fd].node == .disk;
}

pub fn isConsole(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .console;
}

pub fn isFramebuffer(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .device and descriptors[fd].node == .framebuffer;
}

pub fn isDrm(fd: usize) bool {
    return isDrmPrimary(fd) or isDrmRender(fd);
}

pub fn isDrmPrimary(fd: usize) bool { return fd < descriptors.len and descriptors[fd].kind == .device and descriptors[fd].node == .drm; }
pub fn isDrmRender(fd: usize) bool { return fd < descriptors.len and descriptors[fd].kind == .device and descriptors[fd].node == .render; }

pub fn duplicateMinimum(old_fd: usize, minimum: usize) !usize {
    if (old_fd >= descriptors.len or descriptors[old_fd].kind == .unused or minimum >= descriptors.len) return error.BadFd;
    var target = minimum;
    while (target < descriptors.len and descriptors[target].kind != .unused) : (target += 1) {}
    if (target == descriptors.len) return error.TooManyFiles;
    descriptors[target] = descriptors[old_fd];
    return target;
}

pub fn read(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    if (descriptors[fd].node == .disk) {
        const volume = disk orelse return error.NotFound;
        const count = try volume.readRootFileAt(&descriptors[fd].fat_name, output, descriptors[fd].offset);
        descriptors[fd].offset += count;
        return count;
    }
    const data = nodeData(descriptors[fd].node);
    const start = @min(descriptors[fd].offset, data.len);
    const count = @min(output.len, data.len - start);
    @memcpy(output[0..count], data[start .. start + count]);
    descriptors[fd].offset = start + count;
    return count;
}

pub fn pread(fd: usize, output: []u8, offset: usize) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    if (descriptors[fd].node == .disk) {
        const volume = disk orelse return error.NotFound;
        return volume.readRootFileAt(&descriptors[fd].fat_name, output, offset);
    }
    const data = nodeData(descriptors[fd].node);
    const start = @min(offset, data.len);
    const count = @min(output.len, data.len - start);
    @memcpy(output[0..count], data[start .. start + count]);
    return count;
}

pub fn write(fd: usize, input: []const u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file or descriptors[fd].node != .disk) return error.BadFd;
    const volume = disk orelse return error.NotFound;
    var contents: [8192]u8 = undefined;
    const descriptor = &descriptors[fd];
    if (descriptor.offset > contents.len or input.len > contents.len - descriptor.offset or descriptor.size > contents.len) return error.FileTooLarge;
    if (descriptor.size != 0) _ = try volume.readRootFile(&descriptor.fat_name, contents[0..descriptor.size]);
    if (descriptor.offset > descriptor.size) @memset(contents[descriptor.size..descriptor.offset], 0);
    @memcpy(contents[descriptor.offset .. descriptor.offset + input.len], input);
    descriptor.offset += input.len;
    descriptor.size = @max(descriptor.size, descriptor.offset);
    try volume.writeRootFile(&descriptor.fat_name, contents[0..descriptor.size]);
    return input.len;
}

pub fn seek(fd: usize, offset: i64, whence: u64) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    const size: i64 = @intCast(descriptors[fd].size);
    const base: i64 = switch (whence) { 0 => 0, 1 => @intCast(descriptors[fd].offset), 2 => size, else => return error.Invalid };
    if (offset < -base or base + offset < 0) return error.Invalid;
    descriptors[fd].offset = @intCast(base + offset);
    return descriptors[fd].offset;
}

pub fn infoAt(directory_fd: i64, path: []const u8) !Info {
    if (toFatName(path)) |fat_name| if (disk) |volume| {
        return .{ .mode = 0o100644, .size = try volume.fileSize(&fat_name), .directory = false };
    };
    return nodeInfo(try resolve(directory_fd, path));
}

pub fn infoFd(fd: usize) !Info {
    if (fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    if (descriptors[fd].node == .disk) return .{ .mode = 0o100644, .size = descriptors[fd].size, .directory = false };
    return nodeInfo(descriptors[fd].node);
}

pub fn getDents(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .directory) return error.BadFd;
    const entries = switch (descriptors[fd].node) {
        .root => &[_][]const u8{ "bin", "dev", "hello.txt" },
        .bin => &[_][]const u8{ "busybox", "sh", "ls", "cat", "echo" },
        .dev => &[_][]const u8{ "dri", "fb0" },
        .dri => &[_][]const u8{ "card0", "renderD128" },
        else => return error.NotDirectory,
    };
    var written: usize = 0;
    while (descriptors[fd].offset < entries.len) {
        const name = entries[descriptors[fd].offset];
        const record_length = (19 + name.len + 1 + 7) & ~@as(usize, 7);
        if (record_length > output.len - written) break;
        @memset(output[written .. written + record_length], 0);
        write64(output[written..], descriptors[fd].offset + 1);
        write64(output[written + 8 ..], descriptors[fd].offset + 1);
        write16(output[written + 16 ..], @intCast(record_length));
        output[written + 18] = if (equal(name, "bin") or equal(name, "dev") or equal(name, "dri")) 4 else 8;
        @memcpy(output[written + 19 .. written + 19 + name.len], name);
        written += record_length;
        descriptors[fd].offset += 1;
    }
    return written;
}

fn resolve(directory_fd: i64, path: []const u8) !Node {
    if (equal(path, "/") or equal(path, ".")) return .root;
    if (equal(path, "/bin") or equal(path, "bin")) return .bin;
    if (equal(path, "/dev") or equal(path, "dev")) return .dev;
    if (equal(path, "/dev/dri")) return .dri;
    if (equal(path, "/dev/dri/card0")) return .drm;
    if (equal(path, "/dev/dri/renderD128")) return .render;
    if (equal(path, "/dev/fb0")) return .framebuffer;
    if (equal(path, "/hello.txt") or equal(path, "hello.txt")) return .hello;
    if (equal(path, "/bin/busybox") or equal(path, "/bin/sh") or equal(path, "/bin/ls") or
        equal(path, "/bin/cat") or equal(path, "/bin/echo") or
        ((directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and descriptors[@intCast(directory_fd)].node == .bin) and
        (equal(path, "busybox") or equal(path, "sh") or equal(path, "ls") or equal(path, "cat") or equal(path, "echo")))) return .busybox;
    return error.NotFound;
}

fn nodeInfo(node: Node) Info {
    return switch (node) {
        .root, .bin, .dev, .dri => .{ .mode = 0o040755, .size = 0, .directory = true },
        .busybox => .{ .mode = 0o100755, .size = busybox.len, .directory = false },
        .hello => .{ .mode = 0o100644, .size = hello.len, .directory = false },
        .framebuffer => .{ .mode = 0o020600, .size = 0, .directory = false },
        .drm, .render => .{ .mode = 0o020660, .size = 0, .directory = false },
        .disk => .{ .mode = 0o100644, .size = 0, .directory = false },
    };
}

fn toFatName(path: []const u8) ?[11]u8 {
    var start: usize = 0;
    if (path.len != 0 and path[0] == '/') start = 1;
    if (start == path.len) return null;
    var result: [11]u8 = .{' '} ** 11;
    var name_index: usize = 0;
    var extension_index: usize = 8;
    var extension = false;
    for (path[start..]) |character| {
        if (character == '/') return null;
        if (character == '.') { if (extension) return null; extension = true; continue; }
        if ((!extension and name_index == 8) or (extension and extension_index == 11)) return null;
        const upper = if (character >= 'a' and character <= 'z') character - 32 else character;
        if (upper <= ' ' or upper == 0x7f) return null;
        if (extension) { result[extension_index] = upper; extension_index += 1; }
        else { result[name_index] = upper; name_index += 1; }
    }
    if (name_index == 0) return null;
    return result;
}

fn nodeData(node: Node) []const u8 {
    return switch (node) { .busybox => busybox, .hello => hello, else => "" };
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn write16(output: []u8, value: u16) void {
    output[0] = @truncate(value);
    output[1] = @truncate(value >> 8);
}

fn write64(output: []u8, value: u64) void {
    var index: usize = 0;
    while (index < 8) : (index += 1) output[index] = @truncate(value >> @intCast(index * 8));
}
