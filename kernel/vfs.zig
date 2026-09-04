const busybox = @embedFile("busybox_elf");
const fat16 = @import("fat16");
const hello = "Hello from initramfs\n";

const max_fds = 32;

const Kind = enum { unused, console, file, directory, device };
const Node = enum {
    root, bin, dev, dri, sys, sys_dev, sys_char, drm_char_primary, drm_char_render,
    drm_device, drm_device_drm, drm_subsystem, drm_pci_uevent, drm_vendor,
    drm_device_id, drm_subsystem_vendor, drm_subsystem_device,
    drm_primary_uevent, drm_render_uevent, busybox, hello, framebuffer, drm, render, disk,
};

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
    rdev: u64 = 0,
};

pub const DrmPciIdentity = struct {
    domain: u16 = 0,
    bus: u8,
    slot: u5,
    function: u3,
    vendor: u16,
    device: u16,
    subsystem_vendor: u16,
    subsystem_device: u16,
};

var descriptors: [max_fds]Descriptor = .{Descriptor{}} ** max_fds;
var disk: ?*fat16.Volume = null;
var drm_pci_configured = false;
var drm_pci_uevent: [40]u8 = undefined;
var drm_pci_uevent_len: usize = 0;
var drm_vendor_data: [7]u8 = undefined;
var drm_device_data: [7]u8 = undefined;
var drm_subsystem_vendor_data: [7]u8 = undefined;
var drm_subsystem_device_data: [7]u8 = undefined;

pub fn configureDrmPci(identity: DrmPciIdentity) void {
    drm_pci_uevent_len = 0;
    append(&drm_pci_uevent, &drm_pci_uevent_len, "PCI_SLOT_NAME=");
    appendHex(&drm_pci_uevent, &drm_pci_uevent_len, identity.domain, 4);
    append(&drm_pci_uevent, &drm_pci_uevent_len, ":");
    appendHex(&drm_pci_uevent, &drm_pci_uevent_len, identity.bus, 2);
    append(&drm_pci_uevent, &drm_pci_uevent_len, ":");
    appendHex(&drm_pci_uevent, &drm_pci_uevent_len, identity.slot, 2);
    append(&drm_pci_uevent, &drm_pci_uevent_len, ".");
    appendHex(&drm_pci_uevent, &drm_pci_uevent_len, identity.function, 1);
    append(&drm_pci_uevent, &drm_pci_uevent_len, "\n");
    formatPciId(&drm_vendor_data, identity.vendor);
    formatPciId(&drm_device_data, identity.device);
    formatPciId(&drm_subsystem_vendor_data, identity.subsystem_vendor);
    formatPciId(&drm_subsystem_device_data, identity.subsystem_device);
    drm_pci_configured = true;
}

pub fn validateDrmPciIdentitySelfTest() !void {
    reset();
    configureDrmPci(.{
        .bus = 4, .slot = 2, .function = 1,
        .vendor = 0x1002, .device = 0x744c,
        .subsystem_vendor = 0x1da2, .subsystem_device = 0xe471,
    });
    const primary = try infoAt(-100, "/dev/dri/card0");
    const render = try infoAt(-100, "/dev/dri/renderD128");
    if (primary.rdev != 0xe200 or render.rdev != 0xe280) return error.DrmDeviceNumberMismatch;
    const vendor_fd = try openAt(-100, "/sys/dev/char/226:128/device/vendor", 0);
    var vendor: [7]u8 = undefined;
    if (try read(vendor_fd, &vendor) != vendor.len or !equal(&vendor, "0x1002\n")) return error.DrmPciVendorMismatch;
    try close(vendor_fd);
    const uevent_fd = try openAt(-100, "/sys/dev/char/226:0/device/uevent", 0);
    var uevent: [40]u8 = undefined;
    const uevent_len = try read(uevent_fd, &uevent);
    if (!equal(uevent[0..uevent_len], "PCI_SLOT_NAME=0000:04:02.1\n")) return error.DrmPciSlotMismatch;
    try close(uevent_fd);
    var target: [32]u8 = undefined;
    const target_len = try readLinkAt(-100, "/sys/dev/char/226:128/device/subsystem", &target);
    if (!equal(target[0..target_len], "../../../../bus/pci")) return error.DrmPciSubsystemMismatch;
}

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

pub fn readLinkAt(directory_fd: i64, path: []const u8, output: []u8) !usize {
    const node = try resolve(directory_fd, path);
    if (node != .drm_subsystem) return error.Invalid;
    const target = "../../../../bus/pci";
    const count = @min(output.len, target.len);
    @memcpy(output[0..count], target[0..count]);
    return count;
}

pub fn getDents(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .directory) return error.BadFd;
    const entries = switch (descriptors[fd].node) {
        .root => &[_][]const u8{ "bin", "dev", "sys", "hello.txt" },
        .bin => &[_][]const u8{ "busybox", "sh", "ls", "cat", "echo" },
        .dev => &[_][]const u8{ "dri", "fb0" },
        .dri => &[_][]const u8{ "card0", "renderD128" },
        .sys => &[_][]const u8{"dev"},
        .sys_dev => &[_][]const u8{"char"},
        .sys_char => &[_][]const u8{ "226:0", "226:128" },
        .drm_char_primary, .drm_char_render => &[_][]const u8{ "device", "uevent" },
        .drm_device => &[_][]const u8{ "drm", "subsystem", "uevent", "vendor", "device", "subsystem_vendor", "subsystem_device" },
        .drm_device_drm => &[_][]const u8{ "card0", "renderD128" },
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
        output[written + 18] = entryType(descriptors[fd].node, name);
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
    if (equal(path, "/sys")) return .sys;
    if (equal(path, "/sys/dev")) return .sys_dev;
    if (equal(path, "/sys/dev/char")) return .sys_char;
    if (equal(path, "/sys/dev/char/226:0")) return requireDrmPci(.drm_char_primary);
    if (equal(path, "/sys/dev/char/226:128")) return requireDrmPci(.drm_char_render);
    if (equal(path, "/sys/dev/char/226:0/uevent")) return requireDrmPci(.drm_primary_uevent);
    if (equal(path, "/sys/dev/char/226:128/uevent")) return requireDrmPci(.drm_render_uevent);
    if (equal(path, "/sys/dev/char/226:0/device") or equal(path, "/sys/dev/char/226:128/device")) return requireDrmPci(.drm_device);
    if (equal(path, "/sys/dev/char/226:0/device/drm") or equal(path, "/sys/dev/char/226:128/device/drm")) return requireDrmPci(.drm_device_drm);
    if (endsWithDrmDevice(path, "/subsystem")) return requireDrmPci(.drm_subsystem);
    if (endsWithDrmDevice(path, "/uevent")) return requireDrmPci(.drm_pci_uevent);
    if (endsWithDrmDevice(path, "/vendor")) return requireDrmPci(.drm_vendor);
    if (endsWithDrmDevice(path, "/device")) return requireDrmPci(.drm_device_id);
    if (endsWithDrmDevice(path, "/subsystem_vendor")) return requireDrmPci(.drm_subsystem_vendor);
    if (endsWithDrmDevice(path, "/subsystem_device")) return requireDrmPci(.drm_subsystem_device);
    if (equal(path, "/hello.txt") or equal(path, "hello.txt")) return .hello;
    if (equal(path, "/bin/busybox") or equal(path, "/bin/sh") or equal(path, "/bin/ls") or
        equal(path, "/bin/cat") or equal(path, "/bin/echo") or
        ((directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and descriptors[@intCast(directory_fd)].node == .bin) and
        (equal(path, "busybox") or equal(path, "sh") or equal(path, "ls") or equal(path, "cat") or equal(path, "echo")))) return .busybox;
    return error.NotFound;
}

fn nodeInfo(node: Node) Info {
    return switch (node) {
        .root, .bin, .dev, .dri, .sys, .sys_dev, .sys_char, .drm_char_primary, .drm_char_render, .drm_device, .drm_device_drm => .{ .mode = 0o040755, .size = 0, .directory = true },
        .busybox => .{ .mode = 0o100755, .size = busybox.len, .directory = false },
        .hello => .{ .mode = 0o100644, .size = hello.len, .directory = false },
        .framebuffer => .{ .mode = 0o020600, .size = 0, .directory = false },
        .drm => .{ .mode = 0o020660, .size = 0, .directory = false, .rdev = 0xe200 },
        .render => .{ .mode = 0o020660, .size = 0, .directory = false, .rdev = 0xe280 },
        .drm_subsystem => .{ .mode = 0o120777, .size = "../../../../bus/pci".len, .directory = false },
        .drm_pci_uevent => .{ .mode = 0o100444, .size = drm_pci_uevent_len, .directory = false },
        .drm_vendor, .drm_device_id, .drm_subsystem_vendor, .drm_subsystem_device => .{ .mode = 0o100444, .size = 7, .directory = false },
        .drm_primary_uevent => .{ .mode = 0o100444, .size = "DEVNAME=dri/card0\n".len, .directory = false },
        .drm_render_uevent => .{ .mode = 0o100444, .size = "DEVNAME=dri/renderD128\n".len, .directory = false },
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
    return switch (node) {
        .busybox => busybox, .hello => hello,
        .drm_pci_uevent => drm_pci_uevent[0..drm_pci_uevent_len],
        .drm_vendor => &drm_vendor_data, .drm_device_id => &drm_device_data,
        .drm_subsystem_vendor => &drm_subsystem_vendor_data,
        .drm_subsystem_device => &drm_subsystem_device_data,
        .drm_primary_uevent => "DEVNAME=dri/card0\n",
        .drm_render_uevent => "DEVNAME=dri/renderD128\n",
        else => "",
    };
}

fn requireDrmPci(node: Node) error{NotFound}!Node { return if (drm_pci_configured) node else error.NotFound; }

fn endsWithDrmDevice(path: []const u8, suffix: []const u8) bool {
    const primary = "/sys/dev/char/226:0/device";
    const render = "/sys/dev/char/226:128/device";
    return (path.len == primary.len + suffix.len and equal(path[0..primary.len], primary) and equal(path[primary.len..], suffix)) or
        (path.len == render.len + suffix.len and equal(path[0..render.len], render) and equal(path[render.len..], suffix));
}

fn entryType(parent: Node, name: []const u8) u8 {
    if (parent == .drm_device and equal(name, "subsystem")) return 10;
    return switch (parent) {
        .root => if (equal(name, "hello.txt")) 8 else 4,
        .bin, .dri, .drm_device_drm => 8,
        .dev => if (equal(name, "dri")) 4 else 8,
        .sys, .sys_dev, .sys_char => 4,
        .drm_char_primary, .drm_char_render => if (equal(name, "device")) 4 else 8,
        .drm_device => if (equal(name, "drm")) 4 else 8,
        else => 8,
    };
}

fn formatPciId(output: *[7]u8, value: u16) void {
    output[0] = '0'; output[1] = 'x';
    var length: usize = 2;
    appendHex(output, &length, value, 4);
    output[6] = '\n';
}

fn append(output: []u8, length: *usize, value: []const u8) void {
    @memcpy(output[length.* .. length.* + value.len], value);
    length.* += value.len;
}

fn appendHex(output: []u8, length: *usize, value: u64, digits: usize) void {
    var index: usize = 0;
    while (index < digits) : (index += 1) {
        const shift: u6 = @intCast((digits - index - 1) * 4);
        const nibble: u8 = @truncate((value >> shift) & 0xf);
        output[length.*] = if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
        length.* += 1;
    }
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
