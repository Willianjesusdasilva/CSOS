const pci = @import("pci");
const fat16 = @import("fat16");
const physical = @import("physical");

const firmware_name: [11]u8 = "GPUFW   BIN".*;
const maximum_firmware_bytes = 56 * 1024 * 1024;
var interrupt_count: u64 = 0;

pub const Driver = enum {
    unsupported,
    qemu_vga,
    amdgpu,
    nouveau,
};

pub const ChipIdentity = struct {
    pci_device: u16,
    pci_revision: u8,
    chipset: ?u16 = null,
    chip_revision: ?u8 = null,
    boot0: ?u32 = null,
};

pub const Adapter = struct {
    device: pci.Device,
    driver: Driver,
    bars: [6]?pci.Bar,
    bar_count: u8,
    mmio_bytes: u64,
    register_bar: ?pci.Bar,

    pub fn discover(device: pci.Device) !Adapter {
        if (device.class != 0x03) return error.NotDisplayController;
        const driver = driverFor(device.vendor, device.device);
        var bars: [6]?pci.Bar = .{null} ** 6;
        var count: u8 = 0;
        var bytes: u64 = 0;
        var register_bar: ?pci.Bar = null;
        for (0..bars.len) |index| {
            bars[index] = pci.barInfo(device, @intCast(index), true);
            if (bars[index]) |bar| {
                count += 1;
                bytes +|= bar.size;
                if (!bar.prefetchable and bar.size != 0 and (register_bar == null or bar.size < register_bar.?.size)) register_bar = bar;
            }
        }
        if (driver == .nouveau) {
            const bar0 = bars[0] orelse return error.NouveauPriBarMissing;
            if (bar0.prefetchable or bar0.size == 0) return error.InvalidNouveauPriBar;
            register_bar = bar0;
        }
        pci.enableMemoryAndBusMaster(device);
        return .{
            .device = device,
            .driver = driver,
            .bars = bars,
            .bar_count = count,
            .mmio_bytes = bytes,
            .register_bar = register_bar,
        };
    }

    pub fn isAmd(self: *const Adapter) bool {
        return self.driver == .amdgpu;
    }

    pub fn readRegister(self: *const Adapter, offset: u32) !u32 {
        const bar = self.register_bar orelse return error.RegisterBarMissing;
        if ((offset & 3) != 0 or offset > bar.size or bar.size - offset < 4) return error.InvalidRegisterOffset;
        const register: *align(1) volatile const u32 = @ptrFromInt(bar.address + offset);
        return register.*;
    }

    pub fn writeRegister(self: *const Adapter, offset: u32, value: u32) !void {
        const bar = self.register_bar orelse return error.RegisterBarMissing;
        if ((offset & 3) != 0 or offset > bar.size or bar.size - offset < 4) return error.InvalidRegisterOffset;
        const register: *align(1) volatile u32 = @ptrFromInt(bar.address + offset);
        register.* = value;
    }

    pub fn identifyChip(self: *const Adapter) !ChipIdentity {
        var identity = ChipIdentity{
            .pci_device = self.device.device,
            .pci_revision = self.device.revision,
        };
        if (self.driver != .nouveau) return identity;
        const boot0 = try self.readRegister(0);
        const decoded = try decodeNouveauBoot0(boot0);
        identity.chipset = decoded.chipset;
        identity.chip_revision = decoded.revision;
        identity.boot0 = boot0;
        return identity;
    }
};

pub const NouveauChip = struct { chipset: u16, revision: u8 };

// NVKM derives modern NVIDIA chipset and revision fields from PMC_BOOT_0.
// Legacy encodings intentionally remain unsupported until their init path exists.
pub fn decodeNouveauBoot0(boot0: u32) !NouveauChip {
    if (boot0 == 0xffffffff) return error.DeviceUnavailable;
    if ((boot0 & 0x1f000000) == 0) return error.LegacyNouveauChipsetUnsupported;
    return .{
        .chipset = @intCast((boot0 & 0x1ff00000) >> 20),
        .revision = @truncate(boot0),
    };
}

comptime {
    const tu102 = decodeNouveauBoot0(0x162000a1) catch @compileError("Nouveau BOOT0 decoder rejected a modern encoding");
    if (tu102.chipset != 0x162 or tu102.revision != 0xa1) @compileError("Nouveau BOOT0 decoder produced the wrong identity");
}

pub const Firmware = struct {
    address: u64,
    size: usize,
    pages: u64,

    pub fn bytes(self: Firmware) []const u8 {
        const pointer: [*]const u8 = @ptrFromInt(self.address);
        return pointer[0..self.size];
    }

    pub fn entryCount(self: Firmware) !usize {
        var iterator = CpioIterator{ .archive = self.bytes() };
        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }

    pub fn find(self: Firmware, wanted: []const u8) !?[]const u8 {
        var iterator = CpioIterator{ .archive = self.bytes() };
        while (try iterator.next()) |entry| if (equal(entry.name, wanted)) return entry.data;
        return null;
    }

    pub fn selected(self: Firmware, selection: Selection) SelectedIterator {
        return .{ .iterator = .{ .archive = self.bytes() }, .prefix = selection.prefix };
    }

    pub fn inventory(self: Firmware, selection: Selection, driver: Driver) !FirmwareInventory {
        var result = FirmwareInventory{};
        var names: [128][]const u8 = undefined;
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            if (result.entries == names.len) return error.TooManySelectedFirmwareEntries;
            for (names[0..result.entries]) |name| if (equal(name, entry.name)) return error.DuplicateSelectedFirmwareEntry;
            names[result.entries] = entry.name;
            result.entries += 1;
            const block = classifyFirmware(driver, entry.name);
            result.blocks[@intFromEnum(block)].entries += 1;
            const payload_bytes = if (driver == .amdgpu) (try parseAmdgpuFirmware(entry.data)).payload.len else entry.data.len;
            result.blocks[@intFromEnum(block)].bytes += payload_bytes;
            result.payload_bytes += payload_bytes;
        }
        if (result.entries != selection.entries) return error.FirmwareSelectionIncomplete;
        return result;
    }

    pub fn countPrefix(self: Firmware, prefix: []const u8) !usize {
        var iterator = CpioIterator{ .archive = self.bytes() };
        var count: usize = 0;
        while (try iterator.next()) |entry| {
            if (startsWith(entry.name, prefix)) count += 1;
        }
        return count;
    }

    pub fn select(self: Firmware, device: pci.Device, driver: Driver) !?Selection {
        const manifest = try self.find("csos-gpu.conf") orelse return null;
        const backend = switch (driver) { .amdgpu => "amdgpu/", .nouveau => "nouveau/", else => return null };
        var iterator = ManifestIterator{ .manifest = manifest };
        var best: ?Mapping = null;
        var best_specificity: u8 = 0;
        while (try iterator.next()) |mapping| {
            if (!startsWith(mapping.prefix, backend)) continue;
            if (mapping.vendor == device.vendor and mapping.device == device.device and
                (mapping.revision == null or mapping.revision.? == device.revision) and
                (mapping.subsystem_vendor == null or (mapping.subsystem_vendor.? == device.subsystem_vendor and mapping.subsystem_device.? == device.subsystem_device)))
            {
                const specificity: u8 = @intFromBool(mapping.revision != null) + 2 * @as(u8, @intFromBool(mapping.subsystem_vendor != null));
                if (best == null or specificity > best_specificity) {
                    best = mapping;
                    best_specificity = specificity;
                }
            }
        }
        const mapping = best orelse return null;
        const count = try self.countPrefix(mapping.prefix);
        if (count == 0) return error.FirmwareSelectionEmpty;
        return .{ .prefix = mapping.prefix, .entries = count };
    }

    pub fn mappingCount(self: Firmware) !usize {
        const manifest = try self.find("csos-gpu.conf") orelse return 0;
        var iterator = ManifestIterator{ .manifest = manifest };
        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }

    pub fn validateSelection(self: Firmware, selection: Selection, driver: Driver) !usize {
        if (driver != .amdgpu) return selection.entries;
        var iterator = CpioIterator{ .archive = self.bytes() };
        var validated: usize = 0;
        while (try iterator.next()) |entry| {
            if (!startsWith(entry.name, selection.prefix) or entry.data.len == 0) continue;
            _ = try parseAmdgpuFirmware(entry.data);
            validated += 1;
        }
        if (validated != selection.entries) return error.FirmwareSelectionIncomplete;
        return validated;
    }
};

pub const Selection = struct { prefix: []const u8, entries: usize };
pub const FirmwareBlock = enum { security, management, memory, graphics, dma, display, media, discovery, other };
pub const FirmwareBlockSummary = struct { entries: usize = 0, bytes: usize = 0 };
pub const FirmwareInventory = struct {
    entries: usize = 0,
    payload_bytes: usize = 0,
    blocks: [9]FirmwareBlockSummary = .{FirmwareBlockSummary{}} ** 9,

    pub fn block(self: *const FirmwareInventory, kind: FirmwareBlock) FirmwareBlockSummary { return self.blocks[@intFromEnum(kind)]; }
};
pub const SelectedEntry = struct { name: []const u8, data: []const u8 };
pub const SelectedIterator = struct {
    iterator: CpioIterator,
    prefix: []const u8,

    pub fn next(self: *SelectedIterator) !?SelectedEntry {
        while (try self.iterator.next()) |entry| {
            if (!startsWith(entry.name, self.prefix)) continue;
            return .{ .name = entry.name[self.prefix.len..], .data = entry.data };
        }
        return null;
    }
};
const Mapping = struct { vendor: u16, device: u16, revision: ?u8, subsystem_vendor: ?u16, subsystem_device: ?u16, prefix: []const u8 };

const ManifestIterator = struct {
    manifest: []const u8,
    offset: usize = 0,

    fn next(self: *ManifestIterator) !?Mapping {
        while (self.offset < self.manifest.len) {
            var end = self.offset;
            while (end < self.manifest.len and self.manifest[end] != '\n') : (end += 1) {}
            var line = self.manifest[self.offset..end];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.offset = if (end < self.manifest.len) end + 1 else end;
            if (line.len == 0 or line[0] == '#') continue;
            const separator = findByte(line, '=') orelse return error.InvalidFirmwareManifest;
            const identity = line[0..separator];
            const prefix = line[separator + 1 ..];
            if ((!startsWith(prefix, "amdgpu/") and !startsWith(prefix, "nouveau/")) or prefix[prefix.len - 1] != '/') return error.InvalidFirmwareManifest;
            const subsystem_separator = findByte(identity, '@');
            const pci_identity = if (subsystem_separator) |index| identity[0..index] else identity;
            const subsystem: ?[]const u8 = if (subsystem_separator) |index| identity[index + 1 ..] else null;
            if (pci_identity.len != 9 and pci_identity.len != 12) return error.InvalidFirmwareManifest;
            if (pci_identity[4] != ':' or (pci_identity.len == 12 and pci_identity[9] != ':')) return error.InvalidFirmwareManifest;
            if (subsystem) |value| if (value.len != 9 or value[4] != ':') return error.InvalidFirmwareManifest;
            return .{
                .vendor = try readHexValue(pci_identity[0..4]),
                .device = try readHexValue(pci_identity[5..9]),
                .revision = if (pci_identity.len == 12) @intCast(try readHexValue(pci_identity[10..12])) else null,
                .subsystem_vendor = if (subsystem) |value| try readHexValue(value[0..4]) else null,
                .subsystem_device = if (subsystem) |value| try readHexValue(value[5..9]) else null,
                .prefix = prefix,
            };
        }
        return null;
    }
};

comptime {
    var mappings = ManifestIterator{ .manifest = "1002:744c:cc@1da2:e471=amdgpu/navi31/\n10de:2684=nouveau/ad102/\n" };
    const amd = mappings.next() catch @compileError("GPU subsystem firmware mapping was rejected");
    if (amd == null or amd.?.revision != 0xcc or amd.?.subsystem_vendor != 0x1da2 or amd.?.subsystem_device != 0xe471)
        @compileError("GPU subsystem firmware mapping decoded incorrectly");
    const nvidia = mappings.next() catch @compileError("GPU firmware mapping compatibility was rejected");
    if (nvidia == null or nvidia.?.revision != null or nvidia.?.subsystem_vendor != null)
        @compileError("legacy GPU firmware mapping decoded incorrectly");
}

const CpioEntry = struct { name: []const u8, data: []const u8 };

const CpioIterator = struct {
    archive: []const u8,
    offset: usize = 0,
    finished: bool = false,

    fn next(self: *CpioIterator) !?CpioEntry {
        if (self.finished) return null;
        if (self.offset > self.archive.len or self.archive.len - self.offset < 110) return error.InvalidFirmwareArchive;
        const header = self.archive[self.offset .. self.offset + 110];
        if (!equal(header[0..6], "070701") and !equal(header[0..6], "070702")) return error.InvalidFirmwareArchive;
        const file_size = try readHex(header[54..62]);
        const name_size = try readHex(header[94..102]);
        if (name_size == 0) return error.InvalidFirmwareArchive;
        const name_start = self.offset + 110;
        if (name_size > self.archive.len - name_start) return error.InvalidFirmwareArchive;
        const name_end = name_start + name_size;
        if (self.archive[name_end - 1] != 0) return error.InvalidFirmwareArchive;
        const data_start = align4(name_end);
        if (data_start > self.archive.len or file_size > self.archive.len - data_start) return error.InvalidFirmwareArchive;
        const data_end = data_start + file_size;
        self.offset = align4(data_end);
        const name = self.archive[name_start .. name_end - 1];
        if (equal(name, "TRAILER!!!")) {
            self.finished = true;
            return null;
        }
        return .{ .name = name, .data = self.archive[data_start..data_end] };
    }
};

fn readHex(bytes: []const u8) !usize {
    var value: usize = 0;
    for (bytes) |character| {
        const digit: u8 = if (character >= '0' and character <= '9') character - '0'
            else if (character >= 'a' and character <= 'f') character - 'a' + 10
            else if (character >= 'A' and character <= 'F') character - 'A' + 10
            else return error.InvalidFirmwareArchive;
        value = value * 16 + digit;
    }
    return value;
}
fn readHexValue(bytes: []const u8) !u16 { return @intCast(try readHex(bytes)); }
fn findByte(bytes: []const u8, wanted: u8) ?usize { for (bytes, 0..) |byte, index| if (byte == wanted) return index; return null; }

fn align4(value: usize) usize { return (value + 3) & ~@as(usize, 3); }
fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and equal(value[0..prefix.len], prefix);
}
fn contains(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index <= value.len - needle.len) : (index += 1) if (equal(value[index .. index + needle.len], needle)) return true;
    return false;
}

pub fn classifyFirmware(driver: Driver, name: []const u8) FirmwareBlock {
    if (driver == .amdgpu) {
        if (contains(name, "_sos.") or contains(name, "_asd.") or contains(name, "_ta.") or contains(name, "_toc.")) return .security;
        if (contains(name, "_smc.") or contains(name, "_psp.")) return .management;
        if (contains(name, "_mc.")) return .memory;
        if (contains(name, "_sdma")) return .dma;
        if (contains(name, "_dmcub.") or contains(name, "_dmcu.")) return .display;
        if (contains(name, "_vcn.") or contains(name, "_uvd.") or contains(name, "_vce.")) return .media;
        if (contains(name, "_gpu_info.") or contains(name, "_discovery.")) return .discovery;
        if (contains(name, "_pfp.") or contains(name, "_me.") or contains(name, "_mec") or contains(name, "_rlc") or contains(name, "_mes") or contains(name, "_imu.") or contains(name, "_gc_")) return .graphics;
    } else if (driver == .nouveau) {
        if (contains(name, "acr") or contains(name, "sec2") or contains(name, "gsp")) return .security;
        if (contains(name, "pmu")) return .management;
        if (contains(name, "gr/")) return .graphics;
        if (contains(name, "ce/")) return .dma;
        if (contains(name, "disp")) return .display;
        if (contains(name, "nvdec") or contains(name, "nvenc")) return .media;
    }
    return .other;
}

comptime {
    @setEvalBranchQuota(5000);
    if (classifyFirmware(.amdgpu, "navi31_sos.bin") != .security or
        classifyFirmware(.amdgpu, "navi31_sdma.bin") != .dma or
        classifyFirmware(.amdgpu, "navi31_pfp.bin") != .graphics or
        classifyFirmware(.nouveau, "nvidia/ad102/gr/sw_nonctx.bin") != .graphics or
        classifyFirmware(.nouveau, "nvidia/ad102/nvdec/scrubber.bin") != .media)
        @compileError("GPU firmware block classification failed");
}

pub const AmdgpuFirmware = struct {
    header_version_major: u16,
    header_version_minor: u16,
    ip_version_major: u16,
    ip_version_minor: u16,
    ucode_version: u32,
    crc32: u32,
    payload: []const u8,
};

pub fn parseAmdgpuFirmware(bytes: []const u8) !AmdgpuFirmware {
    const common_header_bytes = 32;
    if (bytes.len < common_header_bytes) return error.AmdgpuFirmwareHeaderTruncated;
    const total_size = readLittle32(bytes, 0);
    const header_size = readLittle32(bytes, 4);
    const ucode_size = readLittle32(bytes, 20);
    const ucode_offset = readLittle32(bytes, 24);
    if (total_size != bytes.len) return error.AmdgpuFirmwareSizeMismatch;
    if (header_size < common_header_bytes or header_size > bytes.len) return error.InvalidAmdgpuFirmwareHeaderSize;
    if (ucode_offset < header_size or ucode_offset > bytes.len or ucode_size > bytes.len - ucode_offset)
        return error.InvalidAmdgpuFirmwarePayload;
    return .{
        .header_version_major = readLittle16(bytes, 8),
        .header_version_minor = readLittle16(bytes, 10),
        .ip_version_major = readLittle16(bytes, 12),
        .ip_version_minor = readLittle16(bytes, 14),
        .ucode_version = @intCast(readLittle32(bytes, 16)),
        .crc32 = @intCast(readLittle32(bytes, 28)),
        .payload = bytes[ucode_offset .. ucode_offset + ucode_size],
    };
}

pub fn validateAmdgpuFirmware(bytes: []const u8) !void { _ = try parseAmdgpuFirmware(bytes); }

fn readLittle16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readLittle32(bytes: []const u8, offset: usize) usize {
    return @as(usize, bytes[offset]) |
        (@as(usize, bytes[offset + 1]) << 8) |
        (@as(usize, bytes[offset + 2]) << 16) |
        (@as(usize, bytes[offset + 3]) << 24);
}

comptime {
    var sample = [_]u8{0} ** 36;
    sample[0] = 36;
    sample[4] = 32;
    sample[8] = 1;
    sample[12] = 11;
    sample[16] = 7;
    sample[20] = 4;
    sample[24] = 32;
    const parsed = parseAmdgpuFirmware(&sample) catch @compileError("AMDGPU common firmware header was rejected");
    if (parsed.header_version_major != 1 or parsed.ip_version_major != 11 or parsed.ucode_version != 7 or parsed.payload.len != 4)
        @compileError("AMDGPU common firmware header decoded incorrectly");
}

pub fn loadFirmware(volume: *fat16.Volume, pages: *physical.Allocator) !?Firmware {
    const size = volume.fileSize(&firmware_name) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    if (size == 0 or size > maximum_firmware_bytes) return error.InvalidFirmwareSize;
    const page_count: u64 = @intCast((size + 4095) / 4096);
    const address = pages.allocate(page_count) orelse return error.OutOfMemory;
    const target: [*]u8 = @ptrFromInt(address);
    @memset(target[0 .. page_count * 4096], 0);
    const loaded = volume.readRootFile(&firmware_name, target[0..size]) catch |err| {
        pages.release(address, page_count) catch {};
        return err;
    };
    if (loaded != size) {
        pages.release(address, page_count) catch {};
        return error.TruncatedFirmware;
    }
    return .{ .address = address, .size = size, .pages = page_count };
}

pub fn driverFor(vendor: u16, device: u16) Driver {
    _ = device;
    return switch (vendor) {
        0x1002 => .amdgpu,
        0x10de => .nouveau,
        0x1234, 0x1b36 => .qemu_vga,
        else => .unsupported,
    };
}

pub fn handleInterrupt() callconv(.c) void { _ = @atomicRmw(u64, &interrupt_count, .Add, 1, .monotonic); }
pub fn interrupts() u64 { return @atomicLoad(u64, &interrupt_count, .acquire); }
