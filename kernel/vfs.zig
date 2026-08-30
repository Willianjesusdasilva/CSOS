const busybox = @embedFile("busybox_elf");
const hello = "Hello from initramfs\n";

const max_fds = 32;

const Kind = enum { unused, file, directory };
const Node = enum { root, bin, busybox, hello };

const Descriptor = struct {
    kind: Kind = .unused,
    node: Node = .root,
    offset: usize = 0,
};

pub const Info = struct {
    mode: u32,
    size: u64,
    directory: bool,
};

var descriptors: [max_fds]Descriptor = .{Descriptor{}} ** max_fds;

pub fn reset() void {
    descriptors = .{Descriptor{}} ** max_fds;
}

pub fn openAt(directory_fd: i64, path: []const u8) !usize {
    const node = try resolve(directory_fd, path);
    var fd: usize = 3;
    while (fd < descriptors.len and descriptors[fd].kind != .unused) : (fd += 1) {}
    if (fd == descriptors.len) return error.TooManyFiles;
    const info = nodeInfo(node);
    descriptors[fd] = .{ .kind = if (info.directory) .directory else .file, .node = node };
    return fd;
}

pub fn close(fd: usize) !void {
    if (fd < 3 or fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    descriptors[fd] = .{};
}

pub fn read(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    const data = nodeData(descriptors[fd].node);
    const start = @min(descriptors[fd].offset, data.len);
    const count = @min(output.len, data.len - start);
    @memcpy(output[0..count], data[start .. start + count]);
    descriptors[fd].offset = start + count;
    return count;
}

pub fn seek(fd: usize, offset: i64, whence: u64) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    const size: i64 = @intCast(nodeData(descriptors[fd].node).len);
    const base: i64 = switch (whence) { 0 => 0, 1 => @intCast(descriptors[fd].offset), 2 => size, else => return error.Invalid };
    if (offset < -base or base + offset < 0) return error.Invalid;
    descriptors[fd].offset = @intCast(base + offset);
    return descriptors[fd].offset;
}

pub fn infoAt(directory_fd: i64, path: []const u8) !Info {
    return nodeInfo(try resolve(directory_fd, path));
}

pub fn infoFd(fd: usize) !Info {
    if (fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    return nodeInfo(descriptors[fd].node);
}

pub fn getDents(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .directory) return error.BadFd;
    const entries = switch (descriptors[fd].node) {
        .root => &[_][]const u8{ "bin", "hello.txt" },
        .bin => &[_][]const u8{ "busybox", "sh", "ls", "cat", "echo" },
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
        output[written + 18] = if (name.len == 3 and name[0] == 'b') 4 else 8;
        @memcpy(output[written + 19 .. written + 19 + name.len], name);
        written += record_length;
        descriptors[fd].offset += 1;
    }
    return written;
}

fn resolve(directory_fd: i64, path: []const u8) !Node {
    if (equal(path, "/") or equal(path, ".")) return .root;
    if (equal(path, "/bin") or equal(path, "bin")) return .bin;
    if (equal(path, "/hello.txt") or equal(path, "hello.txt")) return .hello;
    if (equal(path, "/bin/busybox") or equal(path, "/bin/sh") or equal(path, "/bin/ls") or
        equal(path, "/bin/cat") or equal(path, "/bin/echo") or
        ((directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and descriptors[@intCast(directory_fd)].node == .bin) and
        (equal(path, "busybox") or equal(path, "sh") or equal(path, "ls") or equal(path, "cat") or equal(path, "echo")))) return .busybox;
    return error.NotFound;
}

fn nodeInfo(node: Node) Info {
    return switch (node) {
        .root, .bin => .{ .mode = 0o040755, .size = 0, .directory = true },
        .busybox => .{ .mode = 0o100755, .size = busybox.len, .directory = false },
        .hello => .{ .mode = 0o100644, .size = hello.len, .directory = false },
    };
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
