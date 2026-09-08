const std = @import("std");
const busybox = @embedFile("busybox_elf");
const fat16 = @import("fat16");
const hello = "Hello from initramfs\n";

const max_fds = 32;

const Kind = enum { unused, console, file, directory, device, epoll };
const Node = enum {
    root,
    bin,
    dev,
    dri,
    sys,
    sys_dev,
    sys_char,
    drm_char_primary,
    drm_char_render,
    drm_device,
    drm_device_drm,
    drm_subsystem,
    drm_pci_uevent,
    drm_vendor,
    drm_device_id,
    drm_subsystem_vendor,
    drm_subsystem_device,
    drm_primary_uevent,
    drm_render_uevent,
    busybox,
    hello,
    framebuffer,
    drm,
    render,
    disk,
    fat_directory,
};

const Descriptor = struct {
    generation: u32 = 0,
    close_on_exec: bool = false,
    append: bool = false,
    writable: bool = false,
    kind: Kind = .unused,
    node: Node = .root,
    offset: usize = 0,
    size: usize = 0,
    fat_name: [11]u8 = .{' '} ** 11,
    fat_cluster: u16 = 0,
    fat_parent_cluster: u16 = 0,
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
var next_generation: u32 = 1;
var generations_exhausted = false;
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
        .bus = 4,
        .slot = 2,
        .function = 1,
        .vendor = 0x1002,
        .device = 0x744c,
        .subsystem_vendor = 0x1da2,
        .subsystem_device = 0xe471,
    });
    const primary = try infoAt(-100, "/dev/dri/card0");
    const render = try infoAt(-100, "/dev/dri/renderD128");
    if (primary.rdev != 0xe200 or render.rdev != 0xe280) return error.DrmDeviceNumberMismatch;
    for (0..3) |fd| if (!isOpen(fd) or !isConsole(fd)) return error.StandardDescriptorMissing;
    const render_fd = try openAt(-100, "/dev/dri/renderD128", 2 | 0x80000);
    if (try descriptorFlags(render_fd) != 1) return error.DrmOpenCloexecMissing;
    _ = try duplicate(render_fd, render_fd);
    if (try descriptorFlags(render_fd) != 1) return error.DrmSelfDuplicateChangedFlags;
    const duplicate_fd = try duplicateMinimum(render_fd, 0);
    if (try descriptorFlags(duplicate_fd) != 0) return error.DrmDuplicateInheritedCloexec;
    try setDescriptorFlags(duplicate_fd, 1);
    _ = try duplicate(render_fd, duplicate_fd);
    if (try descriptorFlags(duplicate_fd) != 0 or try descriptorFlags(render_fd) != 1)
        return error.DrmDuplicateFlagsNotIndependent;
    if (duplicate_fd < 3 or duplicate_fd == render_fd or !isDrmRender(duplicate_fd))
        return error.DrmDuplicateIdentityMismatch;
    if ((try infoFd(duplicate_fd)).rdev != render.rdev) return error.DrmDuplicateDeviceNumberMismatch;
    try close(duplicate_fd);
    if (!isDrmRender(render_fd) or (try infoFd(render_fd)).rdev != render.rdev)
        return error.DrmDuplicateCloseInvalidatedOriginal;
    const reused_fd = try duplicateMinimum(render_fd, 0);
    if (reused_fd != duplicate_fd) return error.DrmDuplicateSlotNotReused;
    try close(reused_fd);
    try close(render_fd);
    if (descriptorFlags(render_fd)) |_| return error.ClosedDescriptorFlagsAccepted else |err| if (err != error.BadFd) return err;
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

pub fn validateRuntimeLibraryAliasesSelfTest() !void {
    try expectFatAlias("libvulkan_radeon.so", "RADV    SO ");
    try expectFatAlias("/usr/lib/libvulkan_radeon.so", "RADV    SO ");
    try expectFatAlias("libdrm_amdgpu.so.1", "DRMAMD  SO1");
    try expectFatAlias("/usr/lib/libdrm_amdgpu.so.1", "DRMAMD  SO1");
    try expectFatAlias("libdrm.so.2", "LIBDRM  SO2");
    try expectFatAlias("libz.so.1", "LIBZ    SO1");
    try expectFatAlias("libc.so", "LIBC    SO ");
    if (toFatName("/usr/lib/not-supported.so") != null) return error.UnexpectedLibraryAlias;
}

pub fn validateRuntimeLibrariesSelfTest() !void {
    const paths = [_][]const u8{
        "/usr/lib/libvulkan_radeon.so",
        "/usr/lib/libdrm_amdgpu.so.1",
        "/usr/lib/libdrm.so.2",
        "/usr/lib/libz.so.1",
        "/usr/lib/libc.so",
    };
    for (paths) |path| {
        const info = try infoAt(-100, path);
        if (info.directory or info.size < 64) return error.InvalidRuntimeLibrary;
        const fd = try openAt(-100, path, 0);
        var magic: [4]u8 = undefined;
        const count = read(fd, &magic) catch |err| {
            close(fd) catch {};
            return err;
        };
        try close(fd);
        if (count != magic.len or magic[0] != 0x7f or magic[1] != 'E' or magic[2] != 'L' or magic[3] != 'F')
            return error.InvalidRuntimeLibrary;
    }
}

pub fn mount(volume: *fat16.Volume) void {
    disk = volume;
}

pub fn reset() void {
    descriptors = .{Descriptor{}} ** max_fds;
    next_generation = 1;
    generations_exhausted = false;
    descriptors[0].kind = .console;
    descriptors[1].kind = .console;
    descriptors[2].kind = .console;
}

fn newGeneration() !u32 {
    if (generations_exhausted) return error.GenerationExhausted;
    const generation = next_generation;
    if (next_generation == std.math.maxInt(u32)) {
        generations_exhausted = true;
    } else {
        next_generation += 1;
    }
    return generation;
}

test "VFS generation exhaustion fails closed until reset" {
    const saved_next = next_generation;
    const saved_exhausted = generations_exhausted;
    defer {
        next_generation = saved_next;
        generations_exhausted = saved_exhausted;
    }
    next_generation = std.math.maxInt(u32);
    generations_exhausted = false;
    try std.testing.expectEqual(std.math.maxInt(u32), try newGeneration());
    try std.testing.expectError(error.GenerationExhausted, newGeneration());
}

test "VFS duplicate preserves destination when generation is exhausted" {
    const saved_descriptors = descriptors;
    const saved_next = next_generation;
    const saved_exhausted = generations_exhausted;
    defer {
        descriptors = saved_descriptors;
        next_generation = saved_next;
        generations_exhausted = saved_exhausted;
    }
    descriptors = .{Descriptor{}} ** max_fds;
    descriptors[3] = .{ .generation = 11, .kind = .console };
    descriptors[4] = .{ .generation = 22, .kind = .console };
    generations_exhausted = true;
    try std.testing.expectError(error.GenerationExhausted, duplicate(3, 4));
    try std.testing.expectEqual(@as(u32, 22), descriptors[4].generation);
}

pub fn descriptorGeneration(fd: usize) !u32 {
    if (!isOpen(fd)) return error.BadFd;
    return descriptors[fd].generation;
}

pub fn openAt(directory_fd: i64, path: []const u8, flags: u64) !usize {
    var fd: usize = 3;
    while (fd < descriptors.len and descriptors[fd].kind != .unused) : (fd += 1) {}
    if (fd == descriptors.len) return error.TooManyFiles;
    if (disk) |volume| if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
        descriptors[@intCast(directory_fd)].node == .fat_directory and std.mem.indexOfScalar(u8, path, '/') == null)
    {
        if (std.mem.eql(u8, path, "..")) {
            const parent = descriptors[@intCast(directory_fd)].fat_parent_cluster;
            if (parent == 0) {
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .root };
            } else {
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = parent };
            }
            descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
            return fd;
        }
        if (std.mem.eql(u8, path, ".")) {
            descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = descriptors[@intCast(directory_fd)].fat_cluster };
            descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
            return fd;
        }
        const parent_cluster = descriptors[@intCast(directory_fd)].fat_cluster;
        const name = toFatName(path) orelse return error.Invalid;
        if (volume.findDirectoryEntry(parent_cluster, &name)) |entry| {
            if (entry.directory) {
                if ((flags & 0x3) != 0 or (flags & 0x200) != 0) return error.IsDirectory;
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = entry.first_cluster, .fat_parent_cluster = parent_cluster };
            } else {
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .file, .node = .disk, .size = entry.size, .fat_name = entry.name, .fat_parent_cluster = parent_cluster };
            }
            descriptors[fd].writable = (flags & 0x3) != 0;
            descriptors[fd].append = (flags & 0x400) != 0;
            descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
            return fd;
        } else |err| if (err != error.NotFound) return err;
        if ((flags & 0x40) != 0) {
            try volume.createDirectoryFile(parent_cluster, &name);
            const entry = try volume.findDirectoryEntry(parent_cluster, &name);
            descriptors[fd] = .{ .generation = try newGeneration(), .kind = .file, .node = .disk, .size = entry.size, .fat_name = entry.name, .fat_parent_cluster = parent_cluster };
            descriptors[fd].writable = (flags & 0x3) != 0;
            return fd;
        }
        return error.NotFound;
    };
    if (disk) |volume| if ((flags & 0x40) != 0) if (resolveFatPath(volume, path)) |_| {} else |_| if (nestedParentPath(path)) |parent_path| {
        const child_name = toFatName(lastPathComponent(path)) orelse return error.Invalid;
        var parent_cluster: u16 = undefined;
        if (toFatName(parent_path)) |root_name| {
            const parent = try volume.findRootEntry(&root_name);
            if (!parent.directory) return error.NotDirectory;
            parent_cluster = parent.first_cluster;
        } else if (resolveFatPath(volume, parent_path)) |parent| {
            if (!parent.entry.directory) return error.NotDirectory;
            parent_cluster = parent.entry.first_cluster;
        } else |_| return error.NotFound;
        try volume.createDirectoryFile(parent_cluster, &child_name);
        const created = try volume.findDirectoryEntry(parent_cluster, &child_name);
        descriptors[fd] = .{ .generation = try newGeneration(), .kind = .file, .node = .disk, .size = created.size, .fat_name = created.name, .fat_parent_cluster = parent_cluster };
        descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
        descriptors[fd].writable = (flags & 0x3) != 0;
        descriptors[fd].append = (flags & 0x400) != 0;
        return fd;
    };
    if (disk) |volume| if (resolveFatPath(volume, path)) |resolved| {
        if (resolved.entry.directory) {
            if ((flags & 0x3) != 0 or (flags & 0x200) != 0) return error.IsDirectory;
            descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = resolved.entry.first_cluster };
        } else {
            descriptors[fd] = .{ .generation = try newGeneration(), .kind = .file, .node = .disk, .size = resolved.entry.size, .fat_name = resolved.entry.name, .fat_parent_cluster = resolved.parent_cluster };
        }
        descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
        descriptors[fd].writable = (flags & 0x3) != 0;
        descriptors[fd].append = (flags & 0x400) != 0;
        return fd;
    } else |_| {};
    if (disk) |volume| if (splitNestedPath(path)) |parts| {
        if (toFatName(parts.parent)) |parent_name| if (volume.findRootEntry(&parent_name) catch null) |parent| if (parent.directory)
            if (toFatName(parts.child)) |child_name| if (volume.findDirectoryEntry(parent.first_cluster, &child_name)) |child| {
                if (child.directory) {
                    if ((flags & 0x3) != 0 or (flags & 0x200) != 0) return error.IsDirectory;
                    descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = child.first_cluster };
                    descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
                    return fd;
                }
                if ((flags & 0x40) != 0 or (flags & 0x200) != 0 or (flags & 0x3) != 0) return error.ReadOnly;
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .file, .node = .disk, .size = child.size, .fat_name = child.name, .fat_parent_cluster = parent.first_cluster };
                descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
                descriptors[fd].writable = (flags & 0x3) != 0;
                descriptors[fd].append = (flags & 0x400) != 0;
                return fd;
            } else |_| {};
    };
    if (toFatName(path)) |fat_name| if (disk) |volume| {
        if (volume.findRootEntry(&fat_name)) |entry| {
            if (entry.directory) {
                if ((flags & 0x3) != 0 or (flags & 0x200) != 0) return error.IsDirectory;
                descriptors[fd] = .{ .generation = try newGeneration(), .kind = .directory, .node = .fat_directory, .fat_cluster = entry.first_cluster };
                descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
                return fd;
            }
        } else |err| {
            switch (err) {
                error.NotFound => {},
                else => return err,
            }
        }
        var existed = true;
        var size = volume.fileSize(&fat_name) catch |err| switch (err) {
            error.NotFound => blk: {
                existed = false;
                break :blk if ((flags & 0x40) != 0) @as(usize, 0) else return error.NotFound;
            },
            else => return err,
        };
        if (existed and (flags & 0xc0) == 0xc0) return error.AlreadyExists;
        const writable = (flags & 0x3) != 0;
        const generation = try newGeneration();
        if ((flags & 0x200) != 0 and writable or (size == 0 and (flags & 0x40) != 0)) {
            try volume.writeRootFile(&fat_name, "");
            size = 0;
        }
        descriptors[fd] = .{ .generation = generation, .kind = .file, .node = .disk, .size = size, .fat_name = fat_name };
        descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
        descriptors[fd].append = (flags & 0x400) != 0;
        descriptors[fd].writable = (flags & 0x3) != 0;
        return fd;
    };
    const node = try resolve(directory_fd, path);
    const info = nodeInfo(node);
    descriptors[fd] = .{ .generation = try newGeneration(), .kind = if (info.directory) .directory else if (node == .framebuffer or node == .drm or node == .render) .device else .file, .node = node, .size = @intCast(info.size) };
    descriptors[fd].close_on_exec = (flags & 0x80000) != 0;
    descriptors[fd].append = false;
    descriptors[fd].writable = (flags & 0x3) != 0;
    return fd;
}

pub fn openEpoll() !usize {
    var fd: usize = 3;
    while (fd < descriptors.len and descriptors[fd].kind != .unused) : (fd += 1) {}
    if (fd == descriptors.len) return error.TooManyFiles;
    descriptors[fd] = .{ .generation = try newGeneration(), .kind = .epoll, .node = .root };
    return fd;
}

pub fn isEpoll(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .epoll;
}

pub fn close(fd: usize) !void {
    if (fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    descriptors[fd] = .{};
}

pub fn duplicate(old_fd: usize, new_fd: usize) !usize {
    if (old_fd >= descriptors.len or new_fd >= descriptors.len or descriptors[old_fd].kind == .unused) return error.BadFd;
    if (old_fd != new_fd) {
        const generation = try newGeneration();
        descriptors[new_fd] = descriptors[old_fd];
        descriptors[new_fd].generation = generation;
        descriptors[new_fd].close_on_exec = false;
    }
    return new_fd;
}

pub fn isOpen(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind != .unused;
}

pub fn descriptorFlags(fd: usize) !u32 {
    if (!isOpen(fd)) return error.BadFd;
    return @intFromBool(descriptors[fd].close_on_exec);
}

pub fn setDescriptorFlags(fd: usize, flags: u32) !void {
    if (!isOpen(fd)) return error.BadFd;
    descriptors[fd].close_on_exec = (flags & 1) != 0;
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

pub fn isDrmPrimary(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .device and descriptors[fd].node == .drm;
}
pub fn isDrmRender(fd: usize) bool {
    return fd < descriptors.len and descriptors[fd].kind == .device and descriptors[fd].node == .render;
}

pub fn duplicateMinimum(old_fd: usize, minimum: usize) !usize {
    if (old_fd >= descriptors.len or descriptors[old_fd].kind == .unused or minimum >= descriptors.len) return error.BadFd;
    var target = minimum;
    while (target < descriptors.len and descriptors[target].kind != .unused) : (target += 1) {}
    if (target == descriptors.len) return error.TooManyFiles;
    descriptors[target] = descriptors[old_fd];
    descriptors[target].close_on_exec = false;
    return target;
}

pub fn read(fd: usize, output: []u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    if (descriptors[fd].node == .disk) {
        const volume = disk orelse return error.NotFound;
        const count = if (descriptors[fd].fat_parent_cluster != 0)
            try volume.readDirectoryFileAt(descriptors[fd].fat_parent_cluster, &descriptors[fd].fat_name, output, descriptors[fd].offset)
        else
            try volume.readRootFileAt(&descriptors[fd].fat_name, output, descriptors[fd].offset);
        try advanceOffset(&descriptors[fd].offset, count);
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
        return if (descriptors[fd].fat_parent_cluster != 0)
            volume.readDirectoryFileAt(descriptors[fd].fat_parent_cluster, &descriptors[fd].fat_name, output, offset)
        else
            volume.readRootFileAt(&descriptors[fd].fat_name, output, offset);
    }
    const data = nodeData(descriptors[fd].node);
    const start = @min(offset, data.len);
    const count = @min(output.len, data.len - start);
    @memcpy(output[0..count], data[start .. start + count]);
    return count;
}

pub fn write(fd: usize, input: []const u8) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file or descriptors[fd].node != .disk) return error.BadFd;
    if (!descriptors[fd].writable) return error.AccessDenied;
    const volume = disk orelse return error.NotFound;
    var contents: [8192]u8 = undefined;
    const descriptor = &descriptors[fd];
    if (descriptor.append) descriptor.offset = descriptor.size;
    if (descriptor.offset > contents.len or input.len > contents.len - descriptor.offset or descriptor.size > contents.len) return error.FileTooLarge;
    if (descriptor.size != 0) _ = try volume.readRootFile(&descriptor.fat_name, contents[0..descriptor.size]);
    if (descriptor.offset > descriptor.size) @memset(contents[descriptor.size..descriptor.offset], 0);
    @memcpy(contents[descriptor.offset .. descriptor.offset + input.len], input);
    const new_offset = descriptor.offset + input.len;
    const new_size = @max(descriptor.size, new_offset);
    if (descriptor.fat_parent_cluster != 0)
        try volume.writeDirectoryFile(descriptor.fat_parent_cluster, &descriptor.fat_name, contents[0..new_size])
    else
        try volume.writeRootFile(&descriptor.fat_name, contents[0..new_size]);
    descriptor.offset = new_offset;
    descriptor.size = new_size;
    return input.len;
}

pub fn unlinkAt(directory_fd: i64, path: []const u8) !void {
    if (disk) |volume| if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
        descriptors[@intCast(directory_fd)].node == .fat_directory and std.mem.indexOfScalar(u8, path, '/') == null)
    {
        const name = toFatName(path) orelse return error.Invalid;
        return volume.deleteDirectoryFile(descriptors[@intCast(directory_fd)].fat_cluster, &name);
    };
    if (disk) |volume| if (resolveFatPath(volume, path)) |resolved| {
        if (resolved.entry.directory) return error.IsDirectory;
        if (resolved.parent_cluster == 0) return error.Invalid;
        return volume.deleteDirectoryFile(resolved.parent_cluster, &resolved.entry.name);
    } else |_| {};
    if (toFatName(path)) |fat_name| if (disk) |volume| {
        try volume.deleteRootFile(&fat_name);
        return;
    };
    _ = try resolve(directory_fd, path);
    return error.ReadOnly;
}

pub fn mkdirAt(directory_fd: i64, path: []const u8, mode: u64) !void {
    _ = mode;
    if (disk) |volume| {
        if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
            descriptors[@intCast(directory_fd)].node == .fat_directory and std.mem.indexOfScalar(u8, path, '/') == null)
        {
            const child = toFatName(path) orelse return error.Invalid;
            if (volume.findDirectoryEntry(descriptors[@intCast(directory_fd)].fat_cluster, &child)) |_| return error.AlreadyExists else |_| {}
            _ = try volume.createDirectory(descriptors[@intCast(directory_fd)].fat_cluster, &child);
            return;
        }
        if (resolveFatPath(volume, path)) |_| return error.AlreadyExists else |_| {}
        const child = toFatName(lastPathComponent(path)) orelse return error.Invalid;
        const parent_path = nestedParentPath(path) orelse {
            _ = try volume.createDirectory(0, &child);
            return;
        };
        var parent_cluster: u16 = undefined;
        if (toFatName(parent_path)) |root_name| {
            const parent = try volume.findRootEntry(&root_name);
            if (!parent.directory) return error.NotDirectory;
            parent_cluster = parent.first_cluster;
        } else {
            const parent = try resolveFatPath(volume, parent_path);
            if (!parent.entry.directory) return error.NotDirectory;
            parent_cluster = parent.entry.first_cluster;
        }
        _ = try volume.createDirectory(parent_cluster, &child);
        return;
    }
    return error.ReadOnly;
}

pub fn rmdirAt(directory_fd: i64, path: []const u8) !void {
    if (disk) |volume| {
        if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
            descriptors[@intCast(directory_fd)].node == .fat_directory and std.mem.indexOfScalar(u8, path, '/') == null)
        {
            const child = toFatName(path) orelse return error.Invalid;
            return volume.deleteDirectory(descriptors[@intCast(directory_fd)].fat_cluster, &child);
        }
        const resolved = try resolveFatPath(volume, path);
        if (!resolved.entry.directory) return error.NotDirectory;
        return volume.deleteDirectory(resolved.parent_cluster, &resolved.entry.name);
    }
    return error.ReadOnly;
}

pub fn renameAt(directory_fd: i64, old_path: []const u8, new_path: []const u8) !void {
    if (disk) |volume| if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
        descriptors[@intCast(directory_fd)].node == .fat_directory and
        std.mem.indexOfScalar(u8, old_path, '/') == null and std.mem.indexOfScalar(u8, new_path, '/') == null)
    {
        const old_name = toFatName(old_path) orelse return error.Invalid;
        const new_name = toFatName(new_path) orelse return error.Invalid;
        return volume.renameDirectoryFile(descriptors[@intCast(directory_fd)].fat_cluster, &old_name, &new_name);
    };
    if (disk) |volume| if (resolveFatPath(volume, old_path)) |old_resolved| {
        if (old_resolved.parent_cluster == 0 or old_resolved.entry.directory) return error.ReadOnly;
        if (resolveFatPath(volume, new_path)) |_| {
            return error.AlreadyExists;
        } else |_| {}
        if (toFatName(lastPathComponent(new_path))) |new_name|
            return volume.renameDirectoryFile(old_resolved.parent_cluster, &old_resolved.entry.name, &new_name);
    } else |_| {};
    if (toFatName(old_path)) |old_name| if (toFatName(new_path)) |new_name| if (disk) |volume| {
        try volume.renameRootFile(&old_name, &new_name);
        return;
    };
    _ = try resolve(directory_fd, old_path);
    return error.ReadOnly;
}

fn lastPathComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end != 0 and path[end - 1] == '/') : (end -= 1) {}
    var start = end;
    while (start != 0 and path[start - 1] != '/') : (start -= 1) {}
    return path[start..end];
}

fn nestedParentPath(path: []const u8) ?[]const u8 {
    const child = lastPathComponent(path);
    if (child.len == 0 or path.len <= child.len) return null;
    const separator = path.len - child.len - 1;
    if (path[separator] != '/') return null;
    return path[0..separator];
}

pub fn seek(fd: usize, offset: i64, whence: u64) !usize {
    if (fd >= descriptors.len or descriptors[fd].kind != .file) return error.BadFd;
    const size = std.math.cast(i64, descriptors[fd].size) orelse return error.Invalid;
    const current = std.math.cast(i64, descriptors[fd].offset) orelse return error.Invalid;
    const base: i64 = switch (whence) {
        0 => 0,
        1 => current,
        2 => size,
        else => return error.Invalid,
    };
    const result = @addWithOverflow(base, offset);
    if (result[1] != 0 or result[0] < 0) return error.Invalid;
    descriptors[fd].offset = @intCast(result[0]);
    return descriptors[fd].offset;
}

fn advanceOffset(offset: *usize, count: usize) !void {
    offset.* = std.math.add(usize, offset.*, count) catch return error.FileTooLarge;
}

test "file offsets reject arithmetic overflow" {
    var offset: usize = std.math.maxInt(usize) - 1;
    try advanceOffset(&offset, 1);
    try std.testing.expectError(error.FileTooLarge, advanceOffset(&offset, 1));
}

pub fn infoAt(directory_fd: i64, path: []const u8) !Info {
    if (disk) |volume| if (directory_fd >= 3 and @as(usize, @intCast(directory_fd)) < descriptors.len and
        descriptors[@intCast(directory_fd)].node == .fat_directory and std.mem.indexOfScalar(u8, path, '/') == null)
    {
        const name = toFatName(path) orelse return error.Invalid;
        const entry = try volume.findDirectoryEntry(descriptors[@intCast(directory_fd)].fat_cluster, &name);
        return if (entry.directory) .{ .mode = 0o040755, .size = 0, .directory = true } else .{ .mode = 0o100644, .size = entry.size, .directory = false };
    };
    if (disk) |volume| if (resolveFatPath(volume, path)) |resolved| {
        return if (resolved.entry.directory) .{ .mode = 0o040755, .size = 0, .directory = true } else .{ .mode = 0o100644, .size = resolved.entry.size, .directory = false };
    } else |_| {};
    if (toFatName(path)) |fat_name| if (disk) |volume| {
        if (volume.findRootEntry(&fat_name)) |entry| {
            if (entry.directory) return .{ .mode = 0o040755, .size = 0, .directory = true };
        } else |err| switch (err) {
            error.NotFound => {},
            else => return err,
        }
        return .{ .mode = 0o100644, .size = try volume.fileSize(&fat_name), .directory = false };
    };
    return nodeInfo(try resolve(directory_fd, path));
}

const NestedPath = struct { parent: []const u8, child: []const u8 };

const ResolvedFatPath = struct { entry: fat16.Volume.DirectoryEntry, parent_cluster: u16 };

fn resolveFatPath(volume: *fat16.Volume, path: []const u8) !ResolvedFatPath {
    var iterator = std.mem.splitScalar(u8, path, '/');
    var components: [32][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |component| {
        if (component.len == 0) continue;
        if (count == components.len) return error.NameTooLong;
        components[count] = component;
        count += 1;
    }
    if (count < 2) return error.NotFound;
    const first_name = toFatName(components[0]) orelse return error.NotFound;
    var entry = try volume.findRootEntry(&first_name);
    var parent_cluster: u16 = 0;
    var index: usize = 1;
    while (index < count) : (index += 1) {
        if (!entry.directory) return error.NotFound;
        parent_cluster = entry.first_cluster;
        const name = toFatName(components[index]) orelse return error.NotFound;
        entry = try volume.findDirectoryEntry(parent_cluster, &name);
    }
    return .{ .entry = entry, .parent_cluster = parent_cluster };
}

fn splitNestedPath(path: []const u8) ?NestedPath {
    var start: usize = if (path.len != 0 and path[0] == '/') 1 else 0;
    const separator = std.mem.indexOfScalarPos(u8, path, start, '/') orelse return null;
    if (separator == start or separator + 1 >= path.len) return null;
    start = separator + 1;
    if (std.mem.indexOfScalarPos(u8, path, start, '/') != null) return null;
    return .{ .parent = path[0..separator], .child = path[start..] };
}

pub fn infoFd(fd: usize) !Info {
    if (fd >= descriptors.len or descriptors[fd].kind == .unused) return error.BadFd;
    if (descriptors[fd].node == .disk) return .{ .mode = 0o100644, .size = descriptors[fd].size, .directory = false };
    if (descriptors[fd].node == .fat_directory) return .{ .mode = 0o040755, .size = 0, .directory = true };
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
    if (descriptors[fd].node == .fat_directory) {
        const volume = disk orelse return error.NotFound;
        var entries: [64]fat16.Volume.DirectoryEntry = undefined;
        const count = try volume.listDirectory(descriptors[fd].fat_cluster, &entries);
        var written: usize = 0;
        while (descriptors[fd].offset < count) {
            const entry = entries[descriptors[fd].offset];
            var display_name: [12]u8 = undefined;
            const name_length = formatFatName(&entry.name, &display_name);
            const name = display_name[0..name_length];
            const record_length = (19 + name.len + 1 + 7) & ~@as(usize, 7);
            if (written > output.len or record_length > output.len - written) break;
            @memset(output[written .. written + record_length], 0);
            write64(output[written..], descriptors[fd].offset + 1);
            write64(output[written + 8 ..], descriptors[fd].offset + 1);
            write16(output[written + 16 ..], @intCast(record_length));
            output[written + 18] = if (entry.directory) 4 else 8;
            @memcpy(output[written + 19 .. written + 19 + name.len], name);
            written += record_length;
            descriptors[fd].offset += 1;
        }
        return written;
    }
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
        if (written > output.len or record_length > output.len - written) break;
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

fn formatFatName(fat_name: *const [11]u8, output: *[12]u8) usize {
    var length: usize = 0;
    var index: usize = 0;
    while (index < 8 and fat_name[index] != ' ') : (index += 1) {
        output[length] = fat_name[index];
        length += 1;
    }
    var extension_length: usize = 0;
    var extension_index: usize = 8;
    while (extension_index < 11 and fat_name[extension_index] != ' ') : (extension_index += 1) extension_length += 1;
    if (extension_length != 0) {
        output[length] = '.';
        length += 1;
        index = 8;
        while (index < 11 and fat_name[index] != ' ') : (index += 1) {
            output[length] = fat_name[index];
            length += 1;
        }
    }
    return length;
}

test "VFS formats FAT 8.3 names for directory records" {
    var output: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), formatFatName("README  TXT", &output));
    try std.testing.expectEqualSlices(u8, "README.TXT", output[0..10]);
    try std.testing.expectEqual(@as(usize, 3), formatFatName("BIN        ", &output));
    try std.testing.expectEqualSlices(u8, "BIN", output[0..3]);
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
        .root, .bin, .dev, .dri, .sys, .sys_dev, .sys_char, .drm_char_primary, .drm_char_render, .drm_device, .drm_device_drm, .fat_directory => .{ .mode = 0o040755, .size = 0, .directory = true },
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
    if (runtimeLibraryFatAlias(path)) |alias| return alias;
    var start: usize = 0;
    if (path.len != 0 and path[0] == '/') start = 1;
    if (start == path.len) return null;
    var result: [11]u8 = .{' '} ** 11;
    var name_index: usize = 0;
    var extension_index: usize = 8;
    var extension = false;
    for (path[start..]) |character| {
        if (character == '/' or character == '\\') return null;
        if (character == '.') {
            if (extension) return null;
            extension = true;
            continue;
        }
        if ((!extension and name_index == 8) or (extension and extension_index == 11)) return null;
        const upper = if (character >= 'a' and character <= 'z') character - 32 else character;
        if (upper <= ' ' or upper >= 0x7f) return null;
        if (extension) {
            result[extension_index] = upper;
            extension_index += 1;
        } else {
            result[name_index] = upper;
            name_index += 1;
        }
    }
    if (name_index == 0 or (extension and extension_index == 8)) return null;
    return result;
}

test "FAT path conversion rejects extended characters" {
    try std.testing.expect(toFatName("café.txt") == null);
    try std.testing.expect(toFatName("valid.txt") != null);
    try std.testing.expect(toFatName("valid.") == null);
    try std.testing.expect(toFatName("dir\\file.txt") == null);
}

fn runtimeLibraryFatAlias(path: []const u8) ?[11]u8 {
    const prefix = "/usr/lib/";
    const name = if (path.len > prefix.len and equal(path[0..prefix.len], prefix)) path[prefix.len..] else path;
    if (equal(name, "libvulkan_radeon.so")) return "RADV    SO ".*;
    if (equal(name, "libdrm_amdgpu.so.1")) return "DRMAMD  SO1".*;
    if (equal(name, "libdrm.so.2")) return "LIBDRM  SO2".*;
    if (equal(name, "libz.so.1")) return "LIBZ    SO1".*;
    if (equal(name, "libc.so")) return "LIBC    SO ".*;
    return null;
}

fn expectFatAlias(path: []const u8, expected: *const [11]u8) !void {
    const actual = toFatName(path) orelse return error.MissingLibraryAlias;
    if (!equal(&actual, expected)) return error.LibraryAliasMismatch;
}

fn nodeData(node: Node) []const u8 {
    return switch (node) {
        .busybox => busybox,
        .hello => hello,
        .drm_pci_uevent => drm_pci_uevent[0..drm_pci_uevent_len],
        .drm_vendor => &drm_vendor_data,
        .drm_device_id => &drm_device_data,
        .drm_subsystem_vendor => &drm_subsystem_vendor_data,
        .drm_subsystem_device => &drm_subsystem_device_data,
        .drm_primary_uevent => "DEVNAME=dri/card0\n",
        .drm_render_uevent => "DEVNAME=dri/renderD128\n",
        else => "",
    };
}

fn requireDrmPci(node: Node) error{NotFound}!Node {
    return if (drm_pci_configured) node else error.NotFound;
}

fn endsWithDrmDevice(path: []const u8, suffix: []const u8) bool {
    const primary = "/sys/dev/char/226:0/device";
    const render = "/sys/dev/char/226:128/device";
    return pathHasSuffix(path, primary, suffix) or pathHasSuffix(path, render, suffix);
}

fn pathHasSuffix(path: []const u8, prefix: []const u8, suffix: []const u8) bool {
    if (path.len < prefix.len or path.len - prefix.len != suffix.len) return false;
    return equal(path[0..prefix.len], prefix) and equal(path[prefix.len..], suffix);
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
    output[0] = '0';
    output[1] = 'x';
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
