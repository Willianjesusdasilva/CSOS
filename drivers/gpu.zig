const std = @import("std");
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
    rom_bar: ?pci.RomBar,

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
            .rom_bar = pci.romInfo(device, true),
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
        var amd_ip_discovery = false;
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            if (result.entries == names.len) return error.TooManySelectedFirmwareEntries;
            for (names[0..result.entries]) |name| if (equal(name, entry.name)) return error.DuplicateSelectedFirmwareEntry;
            names[result.entries] = entry.name;
            result.entries += 1;
            const block = classifyFirmware(driver, entry.name);
            if (driver == .amdgpu and isAmdIpDiscovery(entry.name)) amd_ip_discovery = true;
            result.blocks[@intFromEnum(block)].entries += 1;
            const payload_bytes = if (driver == .amdgpu and isAmdIpDiscovery(entry.name)) blk: {
                _ = try parseAmdIpDiscovery(entry.data);
                break :blk entry.data.len;
            } else if (driver == .amdgpu) (try parseAmdgpuFirmware(entry.data)).payload.len else entry.data.len;
            result.blocks[@intFromEnum(block)].bytes += payload_bytes;
            result.payload_bytes += payload_bytes;
        }
        if (result.entries != selection.entries) return error.FirmwareSelectionIncomplete;
        var present: u16 = 0;
        for (result.blocks, 0..) |summary, index| {
            if (summary.entries != 0) present |= @as(u16, 1) << @intCast(index);
        }
        if ((present & selection.required_blocks) != selection.required_blocks) return error.RequiredFirmwareBlockMissing;
        const discovery_bit = @as(u16, 1) << @intFromEnum(FirmwareBlock.discovery);
        if (driver == .amdgpu and (selection.required_blocks & discovery_bit) != 0 and !amd_ip_discovery) return error.AmdIpDiscoveryMissing;
        return result;
    }

    pub fn amdDiscovery(self: Firmware, selection: Selection) !?AmdIpDiscovery {
        var result: ?AmdIpDiscovery = null;
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            if (!isAmdIpDiscovery(entry.name)) continue;
            if (result != null) return error.DuplicateAmdIpDiscovery;
            result = try parseAmdIpDiscovery(entry.data);
        }
        return result;
    }

    pub fn stageAmdSecurity(self: Firmware, selection: Selection, pages: *physical.Allocator) !AmdFirmwareStaging {
        var result = AmdFirmwareStaging{};
        errdefer result.release(pages);
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            if (classifyFirmware(.amdgpu, entry.name) != .security) continue;
            if (result.count == result.areas.len) return error.TooManyAmdSecurityFirmwareEntries;
            const parsed = try parseAmdgpuFirmware(entry.data);
            const psp = if (isAmdPspPackage(entry.name)) try parseAmdPspFirmware(entry.data) else null;
            const page_count: u64 = @intCast((entry.data.len + 4095) / 4096);
            const address = pages.allocate(page_count) orelse return error.OutOfMemory;
            const target: [*]u8 = @ptrFromInt(address);
            @memset(target[0 .. page_count * 4096], 0);
            @memcpy(target[0..entry.data.len], entry.data);
            const payload_offset = @intFromPtr(parsed.payload.ptr) - @intFromPtr(entry.data.ptr);
            result.areas[result.count] = .{
                .address = address,
                .pages = page_count,
                .image_bytes = entry.data.len,
                .payload_offset = payload_offset,
                .payload_bytes = parsed.payload.len,
                .header_version_major = parsed.header_version_major,
                .header_version_minor = parsed.header_version_minor,
                .ucode_version = parsed.ucode_version,
            };
            result.count += 1;
            result.image_bytes += entry.data.len;
            result.payload_bytes += parsed.payload.len;
            if (psp) |package| {
                for (package.components[0..package.count]) |component| {
                    if (result.psp_component_count == result.psp_components.len) return error.TooManyAmdPspFirmwareComponents;
                    result.psp_components[result.psp_component_count] = .{
                        .kind = component.kind,
                        .version = component.version,
                        .address = address + component.offset,
                        .bytes = component.bytes,
                    };
                    result.psp_component_count += 1;
                }
            }
        }
        const security_bit = @as(u16, 1) << @intFromEnum(FirmwareBlock.security);
        if ((selection.required_blocks & security_bit) != 0 and result.count == 0) return error.AmdSecurityFirmwareMissing;
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
        if (mapping.psp_host_boot) {
            const required = (@as(u16, 1) << @intFromEnum(FirmwareBlock.security)) |
                (@as(u16, 1) << @intFromEnum(FirmwareBlock.discovery));
            if (driver != .amdgpu or mapping.revision == null or mapping.subsystem_vendor == null or
                (mapping.required_blocks & required) != required)
                return error.UnsafeAmdPspHostBootMapping;
        }
        return .{ .prefix = mapping.prefix, .entries = count, .required_blocks = mapping.required_blocks, .psp_host_boot = mapping.psp_host_boot };
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
            if (isAmdIpDiscovery(entry.name))
                _ = try parseAmdIpDiscovery(entry.data)
            else
                _ = try parseAmdgpuFirmware(entry.data);
            validated += 1;
        }
        if (validated != selection.entries) return error.FirmwareSelectionIncomplete;
        return validated;
    }
};

pub const Selection = struct { prefix: []const u8, entries: usize, required_blocks: u16, psp_host_boot: bool };
pub const FirmwareBlock = enum { security, management, memory, graphics, dma, display, media, discovery, other };
pub const FirmwareBlockSummary = struct { entries: usize = 0, bytes: usize = 0 };
pub const FirmwareInventory = struct {
    entries: usize = 0,
    payload_bytes: usize = 0,
    blocks: [9]FirmwareBlockSummary = .{FirmwareBlockSummary{}} ** 9,

    pub fn block(self: *const FirmwareInventory, kind: FirmwareBlock) FirmwareBlockSummary { return self.blocks[@intFromEnum(kind)]; }
};
pub const AmdFirmwareArea = struct {
    address: u64 = 0,
    pages: u64 = 0,
    image_bytes: usize = 0,
    payload_offset: usize = 0,
    payload_bytes: usize = 0,
    header_version_major: u16 = 0,
    header_version_minor: u16 = 0,
    ucode_version: u32 = 0,
};
pub const AmdFirmwareStaging = struct {
    count: usize = 0,
    image_bytes: usize = 0,
    payload_bytes: usize = 0,
    psp_component_count: usize = 0,
    areas: [128]AmdFirmwareArea = .{AmdFirmwareArea{}} ** 128,
    psp_components: [128]AmdStagedPspComponent = .{AmdStagedPspComponent{}} ** 128,

    pub fn release(self: *AmdFirmwareStaging, pages: *physical.Allocator) void {
        while (self.count != 0) {
            self.count -= 1;
            const area = self.areas[self.count];
            pages.release(area.address, area.pages) catch {};
            self.areas[self.count] = .{};
        }
        self.image_bytes = 0;
        self.payload_bytes = 0;
        self.psp_component_count = 0;
    }
};
pub const AmdStagedPspComponent = struct { kind: u32 = 0, version: u32 = 0, address: u64 = 0, bytes: u32 = 0 };
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
const Mapping = struct { vendor: u16, device: u16, revision: ?u8, subsystem_vendor: ?u16, subsystem_device: ?u16, prefix: []const u8, required_blocks: u16, psp_host_boot: bool };

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
            const target = line[separator + 1 ..];
            const requirement_separator = findByte(target, '|');
            const prefix = if (requirement_separator) |index| target[0..index] else target;
            const requirements: ?[]const u8 = if (requirement_separator) |index| target[index + 1 ..] else null;
            if (prefix.len == 0 or (!startsWith(prefix, "amdgpu/") and !startsWith(prefix, "nouveau/")) or prefix[prefix.len - 1] != '/') return error.InvalidFirmwareManifest;
            if (requirements) |value| if (value.len == 0) return error.InvalidFirmwareManifest;
            const subsystem_separator = findByte(identity, '@');
            const pci_identity = if (subsystem_separator) |index| identity[0..index] else identity;
            const subsystem: ?[]const u8 = if (subsystem_separator) |index| identity[index + 1 ..] else null;
            if (pci_identity.len != 9 and pci_identity.len != 12) return error.InvalidFirmwareManifest;
            if (pci_identity[4] != ':' or (pci_identity.len == 12 and pci_identity[9] != ':')) return error.InvalidFirmwareManifest;
            if (subsystem) |value| if (value.len != 9 or value[4] != ':') return error.InvalidFirmwareManifest;
            const parsed_requirements = if (requirements) |value| try parseFirmwareRequirements(value) else FirmwareRequirements{};
            return .{
                .vendor = try readHexValue(pci_identity[0..4]),
                .device = try readHexValue(pci_identity[5..9]),
                .revision = if (pci_identity.len == 12) @intCast(try readHexValue(pci_identity[10..12])) else null,
                .subsystem_vendor = if (subsystem) |value| try readHexValue(value[0..4]) else null,
                .subsystem_device = if (subsystem) |value| try readHexValue(value[5..9]) else null,
                .prefix = prefix,
                .required_blocks = parsed_requirements.blocks,
                .psp_host_boot = parsed_requirements.psp_host_boot,
            };
        }
        return null;
    }
};

comptime {
    var mappings = ManifestIterator{ .manifest = "1002:744c:cc@1da2:e471=amdgpu/navi31/|security,graphics,dma,discovery,psp-host-boot\n10de:2684=nouveau/ad102/\n" };
    const amd = mappings.next() catch @compileError("GPU subsystem firmware mapping was rejected");
    if (amd == null or amd.?.revision != 0xcc or amd.?.subsystem_vendor != 0x1da2 or amd.?.subsystem_device != 0xe471 or amd.?.required_blocks != 0x99 or !amd.?.psp_host_boot)
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

const FirmwareRequirements = struct { blocks: u16 = 0, psp_host_boot: bool = false };

fn parseFirmwareRequirements(value: []const u8) !FirmwareRequirements {
    var result = FirmwareRequirements{};
    var offset: usize = 0;
    while (offset < value.len) {
        var end = offset;
        while (end < value.len and value[end] != ',') : (end += 1) {}
        const name = value[offset..end];
        if (equal(name, "psp-host-boot")) {
            if (result.psp_host_boot) return error.DuplicateFirmwareRequirement;
            result.psp_host_boot = true;
            if (end < value.len and end + 1 == value.len) return error.InvalidFirmwareRequirement;
            offset = if (end < value.len) end + 1 else end;
            continue;
        }
        const block: FirmwareBlock = if (equal(name, "security")) .security
            else if (equal(name, "management")) .management
            else if (equal(name, "memory")) .memory
            else if (equal(name, "graphics")) .graphics
            else if (equal(name, "dma")) .dma
            else if (equal(name, "display")) .display
            else if (equal(name, "media")) .media
            else if (equal(name, "discovery")) .discovery
            else if (equal(name, "other")) .other
            else return error.InvalidFirmwareRequirement;
        const bit = @as(u16, 1) << @intFromEnum(block);
        if ((result.blocks & bit) != 0) return error.DuplicateFirmwareRequirement;
        result.blocks |= bit;
        if (end < value.len and end + 1 == value.len) return error.InvalidFirmwareRequirement;
        offset = if (end < value.len) end + 1 else end;
    }
    return result;
}

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

fn isAmdIpDiscovery(name: []const u8) bool {
    return equal(name, "ip_discovery.bin") or contains(name, "_ip_discovery.bin");
}

fn isAmdPspPackage(name: []const u8) bool {
    // A *_sos.bin file is the combined PSP package. Separate *_toc.bin
    // files use a common firmware header but are not PSP component tables.
    return contains(name, "_sos.");
}

comptime {
    @setEvalBranchQuota(5000);
    if (classifyFirmware(.amdgpu, "navi31_sos.bin") != .security or
        classifyFirmware(.amdgpu, "navi31_sdma.bin") != .dma or
        classifyFirmware(.amdgpu, "navi31_pfp.bin") != .graphics or
        classifyFirmware(.nouveau, "nvidia/ad102/gr/sw_nonctx.bin") != .graphics or
        classifyFirmware(.nouveau, "nvidia/ad102/nvdec/scrubber.bin") != .media)
        @compileError("GPU firmware block classification failed");
    if (!isAmdPspPackage("navi31_sos.bin") or isAmdPspPackage("psp_13_0_5_toc.bin"))
        @compileError("AMDGPU PSP package identification failed");
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

pub const AmdPspComponent = struct {
    kind: u32 = 0,
    version: u32 = 0,
    offset: u32 = 0,
    bytes: u32 = 0,
};
pub const AmdPspFirmware = struct {
    count: usize = 0,
    components: [32]AmdPspComponent = .{AmdPspComponent{}} ** 32,
};

fn appendPspComponent(result: *AmdPspFirmware, bytes: []const u8, kind: u32, component_version: u32, offset: usize, size: usize) !void {
    if (kind == 0 or kind > 14) return error.UnsupportedAmdPspFirmwareType;
    if (size == 0 or offset > bytes.len or size > bytes.len - offset) return error.InvalidAmdPspFirmwareComponent;
    for (result.components[0..result.count]) |component| if (component.kind == kind) return error.DuplicateAmdPspFirmwareComponent;
    if (result.count == result.components.len) return error.TooManyAmdPspFirmwareComponents;
    result.components[result.count] = .{ .kind = kind, .version = component_version, .offset = @intCast(offset), .bytes = @intCast(size) };
    result.count += 1;
}

fn appendLegacyPspComponent(result: *AmdPspFirmware, bytes: []const u8, descriptor: usize, kind: u32, payload_base: usize) !void {
    try appendPspComponent(result, bytes, kind, @intCast(readLittle32(bytes, descriptor)), payload_base + readLittle32(bytes, descriptor + 4), readLittle32(bytes, descriptor + 8));
}

pub fn parseAmdPspFirmware(bytes: []const u8) !AmdPspFirmware {
    const common = try parseAmdgpuFirmware(bytes);
    const common_offset = readLittle32(bytes, 24);
    var result = AmdPspFirmware{};
    if (common.header_version_major == 1) {
        const required_header: usize = switch (common.header_version_minor) {
            0 => 44,
            1, 2 => 68,
            3 => 116,
            else => return error.UnsupportedAmdPspFirmwareHeader,
        };
        if (readLittle32(bytes, 4) < required_header) return error.TruncatedAmdPspFirmwareHeader;
        const sos_offset = readLittle32(bytes, 36);
        try appendPspComponent(&result, bytes, 2, common.ucode_version, common_offset, sos_offset);
        try appendLegacyPspComponent(&result, bytes, 32, 1, common_offset);
        if (common.header_version_minor == 1 or common.header_version_minor == 3) {
            try appendLegacyPspComponent(&result, bytes, 44, 4, common_offset);
            try appendLegacyPspComponent(&result, bytes, 56, 3, common_offset);
        } else if (common.header_version_minor == 2) {
            // v1.2 calls the middle descriptor RES upstream; it is not a
            // loadable PSP type, so retain only the explicitly typed KDB.
            try appendLegacyPspComponent(&result, bytes, 56, 3, common_offset);
        }
        if (common.header_version_minor == 3) {
            try appendLegacyPspComponent(&result, bytes, 68, 5, common_offset);
            try appendLegacyPspComponent(&result, bytes, 80, 6, common_offset);
            // Internal kinds 13/14 retain v1.3 SYS/SOS auxiliary images; the
            // upstream selection rule is applied later using the exact MP0 IP.
            try appendLegacyPspComponent(&result, bytes, 92, 13, common_offset);
            try appendLegacyPspComponent(&result, bytes, 104, 14, common_offset);
        }
    } else if (common.header_version_major == 2) {
        if (common.header_version_minor > 1) return error.UnsupportedAmdPspFirmwareHeader;
        const descriptor_start: usize = if (common.header_version_minor == 0) 36 else 40;
        const count = readLittle32(bytes, 32);
        const header_size = readLittle32(bytes, 4);
        if (count == 0 or count > result.components.len or descriptor_start > header_size or count * 16 > header_size - descriptor_start)
            return error.InvalidAmdPspFirmwareComponentTable;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const descriptor = descriptor_start + index * 16;
            try appendPspComponent(&result, bytes, @intCast(readLittle32(bytes, descriptor)), @intCast(readLittle32(bytes, descriptor + 4)), common_offset + readLittle32(bytes, descriptor + 8), readLittle32(bytes, descriptor + 12));
        }
    } else return error.UnsupportedAmdPspFirmwareHeader;
    return result;
}

pub const AmdIpDiscovery = struct {
    binary_version_major: u16,
    binary_version_minor: u16,
    table_version: u16,
    dies: u16,
    ips: u32,
    base_addresses: u32,
    harvested: u32,
    critical_count: usize = 0,
    critical: [16]AmdIp = .{AmdIp{}} ** 16,

    pub fn find(self: *const AmdIpDiscovery, hw_id: u16, instance: u8) ?*const AmdIp {
        for (self.critical[0..self.critical_count]) |*ip| if (ip.hw_id == hw_id and ip.instance == instance) return ip;
        return null;
    }
};

pub const AmdIp = struct {
    hw_id: u16 = 0,
    instance: u8 = 0,
    major: u8 = 0,
    minor: u8 = 0,
    revision: u8 = 0,
    sub_revision: u8 = 0,
    variant: u8 = 0,
    harvest: u8 = 0,
    base_count: u8 = 0,
    bases: [8]u64 = .{0} ** 8,
};

pub const amd_hw_id = struct { pub const smu: u16 = 1; pub const gfx: u16 = 11; pub const mmhub: u16 = 34; pub const sdma0: u16 = 42; pub const sdma1: u16 = 43; pub const sdma2: u16 = 44; pub const sdma3: u16 = 45; pub const nbif: u16 = 108; pub const psp: u16 = 255; };

pub const AmdBackendPlan = struct { psp: AmdPspPlan, gmc: GmcFamily, gfx: GfxFamily, sdma: SdmaFamily };
pub const AmdMemoryPlan = struct {
    family: GmcFamily,
    register_bar: pci.Bar,
    doorbell_bar: pci.Bar,
    vram_bar: ?pci.Bar,
};
pub const AmdGartPlan = struct {
    family: GmcFamily,
    gfxhub_base: ?u64,
    mmhub_base: u64,
    table_cpu_address: u64,
    table_mc_address: ?u64 = null,
    window_start: ?u64 = null,
    window_end: ?u64 = null,
    entries: u16,
    window_bytes: u64,
    active: bool = false,
};
pub const AmdGmc11GartRegisters = struct {
    fb_location_base: u32,
    fb_offset: u32,
    agp_base: u32,
    agp_bottom: u32,
    agp_top: u32,
    system_aperture_low: u32,
    system_aperture_high: u32,
    system_default_low: u32,
    system_default_high: u32,
    fault_default_low: u32,
    fault_default_high: u32,
    fault_control2: u32,
    context_control: u32,
    context1_control: u32,
    page_table_base_low: u32,
    page_table_base_high: u32,
    page_table_start_low: u32,
    page_table_start_high: u32,
    page_table_end_low: u32,
    page_table_end_high: u32,
    context1_page_table_start_low: u32,
    context1_page_table_start_high: u32,
    context1_page_table_end_low: u32,
    context1_page_table_end_high: u32,
    l1_tlb_control: u32,
    l2_control: u32,
    l2_control2: u32,
    l2_control3: u32,
    l2_control4: u32,
    l2_control5: u32,
    identity_low_low: u32,
    identity_low_high: u32,
    identity_high_low: u32,
    identity_high_high: u32,
    identity_offset_low: u32,
    identity_offset_high: u32,
    invalidate_request: u32,
    invalidate_ack: u32,
    invalidate_range_low: u32,
    invalidate_range_high: u32,
    context_control_stride: u32,
    context_address_stride: u32,
    invalidate_engine_stride: u32,
    invalidate_range_stride: u32,
};
pub const AmdGmc11MemorySnapshot = struct {
    vram_mc_base: u64,
    vram_mc_offset: u64,
    vram_bytes: u64,
};
pub const AmdGmc11NbioRegisters = struct { memsize: u32 };
pub const AmdGmc11GartWindow = struct { start: u64, end: u64 };
pub const AmdGmc11GartApertureValues = struct {
    page_table_base_low: u32,
    page_table_base_high: u32,
    page_table_start_low: u32,
    page_table_start_high: u32,
    page_table_end_low: u32,
    page_table_end_high: u32,
};
pub const AmdGmc11SystemApertureValues = struct {
    agp_base: u32,
    agp_bottom: u32,
    agp_top: u32,
    aperture_low: u32,
    aperture_high: u32,
    default_low: u32,
    default_high: u32,
    fault_default_low: u32,
    fault_default_high: u32,
};
pub const AmdGmc11GartRegisterSet = struct {
    offsets: [144]u32 = .{0} ** 144,
    count: usize = 0,

    fn add(self: *AmdGmc11GartRegisterSet, offset: u32) !void {
        for (self.offsets[0..self.count]) |existing| if (existing == offset) return error.DuplicateAmdGartRegister;
        if (self.count == self.offsets.len) return error.TooManyAmdGartRegisters;
        self.offsets[self.count] = offset;
        self.count += 1;
    }
};
pub const AmdRegisterIo = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u32) anyerror!u32,
    write: *const fn (*anyopaque, u32, u32) anyerror!void,
};
pub const AmdGmc11AuthorizationEvidence = struct {
    selected_firmware_entries: usize,
    validated_firmware_entries: usize,
    security_firmware_entries: usize,
    compatible_ip_discovery: bool,
    psp_ready: bool,
    gart_table_bound: bool,
    gart_window_bound: bool,
    rollback_registers: usize,
};
pub const AmdGmc11MmioTransport = struct {
    adapter: *const Adapter,
    uncached: bool = false,
    authorized: bool = false,
    armed: bool = false,

    pub fn authorize(self: *AmdGmc11MmioTransport, evidence: AmdGmc11AuthorizationEvidence) !void {
        if (self.armed or self.authorized or !self.uncached or !self.adapter.isAmd() or self.adapter.device.vendor != 0x1002 or
            evidence.selected_firmware_entries == 0 or evidence.validated_firmware_entries != evidence.selected_firmware_entries or
            evidence.security_firmware_entries == 0 or !evidence.compatible_ip_discovery or !evidence.psp_ready or !evidence.gart_table_bound or
            !evidence.gart_window_bound or evidence.rollback_registers != 141)
            return error.AmdGmc11MmioAuthorizationRejected;
        self.authorized = true;
    }

    pub fn arm(self: *AmdGmc11MmioTransport) !void {
        if (self.armed or !self.uncached or !self.authorized or !self.adapter.isAmd() or self.adapter.device.vendor != 0x1002)
            return error.AmdGmc11MmioTransportNotReady;
        const bar = self.adapter.register_bar orelse return error.RegisterBarMissing;
        if (bar.address == 0 or bar.prefetchable or bar.size < 4 or bar.size > 16 * 1024 * 1024)
            return error.InvalidAmdGmc11RegisterBar;
        self.armed = true;
    }

    pub fn disarm(self: *AmdGmc11MmioTransport) void {
        self.armed = false;
    }

    pub fn io(self: *AmdGmc11MmioTransport) AmdRegisterIo {
        return .{ .context = self, .read = &read, .write = &write };
    }

    fn read(context: *anyopaque, offset: u32) !u32 {
        const self: *AmdGmc11MmioTransport = @ptrCast(@alignCast(context));
        if (!self.armed) return error.AmdGmc11MmioTransportDisarmed;
        return self.adapter.readRegister(offset);
    }

    fn write(context: *anyopaque, offset: u32, value: u32) !void {
        const self: *AmdGmc11MmioTransport = @ptrCast(@alignCast(context));
        if (!self.armed) return error.AmdGmc11MmioTransportDisarmed;
        try self.adapter.writeRegister(offset, value);
    }
};
pub const AmdGmc11GartSnapshot = struct {
    offsets: [144]u32 = .{0} ** 144,
    values: [144]u32 = .{0} ** 144,
    count: usize = 0,
};
pub const AmdRegisterWrite = struct { offset: u32, value: u32, verify_mask: u32 = 0xffffffff };
pub const AmdRegisterWriteSet = struct {
    writes: [144]AmdRegisterWrite = .{AmdRegisterWrite{ .offset = 0, .value = 0 }} ** 144,
    count: usize = 0,

    pub fn add(self: *AmdRegisterWriteSet, write: AmdRegisterWrite) !void {
        for (self.writes[0..self.count]) |existing| if (existing.offset == write.offset) return error.DuplicateAmdRegisterWrite;
        if (self.count == self.writes.len or write.verify_mask == 0) return error.InvalidAmdRegisterWrite;
        self.writes[self.count] = write;
        self.count += 1;
    }
};
pub const AmdGmc11RegisterTransaction = struct { snapshot: AmdGmc11GartSnapshot, writes_applied: usize };
pub const AmdGmc11InvalidateResult = struct { engine: u5, vmid: u4, polls: u32 };
pub const AmdGmc11ActivationWorkspace = struct {
    register_set: AmdGmc11GartRegisterSet = .{},
    writes: AmdRegisterWriteSet = .{},
    transaction: AmdGmc11RegisterTransaction = .{ .snapshot = .{}, .writes_applied = 0 },
    prepared: bool = false,
    active: bool = false,
    snapshot_digest: u64 = 0,
    write_digest: u64 = 0,
    invalidate_polls: u32 = 0,
};
pub const AmdGpuVaMapping = struct {
    active: bool = false,
    handle: u32 = 0,
    address: u64 = 0,
    size: u64 = 0,
    bo_offset: u64 = 0,
    flags: u32 = 0,
};
pub const AmdGpuVmPagePath = struct {
    pdb2: u9,
    pdb1: u9,
    pdb0: u9,
    ptb: u9,
    page_offset: u12,
};

pub fn amdGpuVmPagePath(address: u64) !AmdGpuVmPagePath {
    if (address >= 0x0000800000000000) return error.InvalidAmdGpuVa;
    return .{
        .pdb2 = @truncate(address >> 39),
        .pdb1 = @truncate(address >> 30),
        .pdb0 = @truncate(address >> 21),
        .ptb = @truncate(address >> 12),
        .page_offset = @truncate(address),
    };
}

pub fn amdGpuVmTableBytes(entries: u16) !u32 {
    if (entries == 0 or entries > 512) return error.InvalidAmdGpuVmTableEntries;
    return @intCast((@as(u32, entries) * 8 + 4095) & ~@as(u32, 4095));
}
pub const AmdGpuVm = struct {
    allocated: bool = false,
    vmid: u4 = 0,
    mappings: [32]AmdGpuVaMapping = .{AmdGpuVaMapping{}} ** 32,
};
pub const AmdGpuVmManager = struct {
    vms: [15]AmdGpuVm = .{AmdGpuVm{}} ** 15,

    pub fn allocate(self: *AmdGpuVmManager) !*AmdGpuVm {
        for (&self.vms, 1..) |*vm, vmid| if (!vm.allocated) {
            vm.* = .{ .allocated = true, .vmid = @intCast(vmid) };
            return vm;
        };
        return error.AmdGpuVmidsExhausted;
    }

    pub fn release(self: *AmdGpuVmManager, vmid: u4) !void {
        const vm = try self.get(vmid);
        vm.* = .{};
    }

    pub fn map(self: *AmdGpuVmManager, vmid: u4, handle: u32, address: u64, size: u64, bo_offset: u64, bo_size: u64, flags: u32) !void {
        const vm = try self.get(vmid);
        const allowed_flags: u32 = (1 << 1) | (1 << 2) | (1 << 3);
        if (handle == 0 or size == 0 or (address & 4095) != 0 or (size & 4095) != 0 or (bo_offset & 4095) != 0 or
            flags == 0 or (flags & ~allowed_flags) != 0 or bo_offset > bo_size or size > bo_size - bo_offset)
            return error.InvalidAmdGpuVaMapping;
        const end = std.math.add(u64, address, size - 1) catch return error.InvalidAmdGpuVaMapping;
        if (end >= 0x0000800000000000) return error.InvalidAmdGpuVaMapping;
        for (vm.mappings) |mapping| if (mapping.active) {
            const mapping_end = mapping.address + mapping.size - 1;
            if (!(end < mapping.address or address > mapping_end)) return error.AmdGpuVaOverlap;
        };
        for (&vm.mappings) |*mapping| if (!mapping.active) {
            mapping.* = .{ .active = true, .handle = handle, .address = address, .size = size, .bo_offset = bo_offset, .flags = flags };
            return;
        };
        return error.AmdGpuVaMappingsExhausted;
    }

    pub fn unmap(self: *AmdGpuVmManager, vmid: u4, address: u64, size: u64) !void {
        const vm = try self.get(vmid);
        for (&vm.mappings) |*mapping| if (mapping.active and mapping.address == address and mapping.size == size) {
            mapping.* = .{};
            return;
        };
        return error.AmdGpuVaMappingNotFound;
    }

    fn get(self: *AmdGpuVmManager, vmid: u4) !*AmdGpuVm {
        if (vmid == 0 or vmid > 15) return error.InvalidAmdGpuVmid;
        const vm = &self.vms[vmid - 1];
        return if (vm.allocated) vm else error.AmdGpuVmidNotAllocated;
    }
};

fn amdGartDigest(seed: u64, value: u32) u64 {
    var digest = seed;
    inline for (0..4) |shift| {
        digest ^= @as(u8, @truncate(value >> @intCast(shift * 8)));
        digest *%= 0x100000001b3;
    }
    return digest;
}

fn amdGartSnapshotDigest(snapshot: *const AmdGmc11GartSnapshot) u64 {
    var digest: u64 = 0xcbf29ce484222325;
    for (snapshot.offsets[0..snapshot.count], snapshot.values[0..snapshot.count]) |offset, value| {
        digest = amdGartDigest(digest, offset);
        digest = amdGartDigest(digest, value);
    }
    return digest;
}

fn amdGartWriteDigest(writes: *const AmdRegisterWriteSet) u64 {
    var digest: u64 = 0xcbf29ce484222325;
    for (writes.writes[0..writes.count]) |write| {
        digest = amdGartDigest(digest, write.offset);
        digest = amdGartDigest(digest, write.value);
        digest = amdGartDigest(digest, write.verify_mask);
    }
    return digest;
}
pub const AmdGmc11VisibleVram = struct {
    cpu_start: u64,
    cpu_end: u64,
    mc_start: u64,
    mc_end: u64,
    bytes: u64,
    framebuffer_mc_start: u64,
    framebuffer_mc_end: u64,
};
pub const AmdVramRange = struct { start: u64, end: u64 };
pub const AmdVramAllocation = struct { cpu_address: u64, mc_address: u64, bytes: u64 };
pub const AmdGmc11SystemPages = struct {
    scratch: AmdVramAllocation,
    scratch_physical: u64,
    dummy_physical: u64,
};
pub const AmdVramAllocator = struct {
    visible: AmdGmc11VisibleVram,
    reservations: [16]AmdVramRange = .{AmdVramRange{ .start = 0, .end = 0 }} ** 16,
    reservation_count: usize = 0,
    firmware_map_sealed: bool = false,

    pub fn init(visible: AmdGmc11VisibleVram) !AmdVramAllocator {
        var result = AmdVramAllocator{ .visible = visible };
        try result.reserve(visible.framebuffer_mc_start, visible.framebuffer_mc_end - visible.framebuffer_mc_start + 1);
        return result;
    }

    pub fn reserve(self: *AmdVramAllocator, start: u64, bytes: u64) !void {
        if (self.firmware_map_sealed) return error.AmdVramMapAlreadySealed;
        if (bytes == 0 or start < self.visible.mc_start) return error.InvalidAmdVramReservation;
        const end = std.math.add(u64, start, bytes - 1) catch return error.InvalidAmdVramReservation;
        if (end > self.visible.mc_end) return error.InvalidAmdVramReservation;
        var combined = AmdVramRange{ .start = start, .end = end };
        var index: usize = 0;
        while (index < self.reservation_count) {
            const used = self.reservations[index];
            if (!rangesTouch(combined, used)) {
                index += 1;
                continue;
            }
            combined.start = @min(combined.start, used.start);
            combined.end = @max(combined.end, used.end);
            self.reservation_count -= 1;
            self.reservations[index] = self.reservations[self.reservation_count];
        }
        if (self.reservation_count == self.reservations.len) return error.TooManyAmdVramReservations;
        self.reservations[self.reservation_count] = combined;
        self.reservation_count += 1;
    }

    pub fn sealFirmwareMap(self: *AmdVramAllocator) void {
        self.firmware_map_sealed = true;
    }

    pub fn allocatePinned(self: *AmdVramAllocator, bytes: u64, alignment: u64) !AmdVramAllocation {
        if (!self.firmware_map_sealed) return error.AmdVramFirmwareMapIncomplete;
        if (bytes == 0 or alignment < 4096 or !std.math.isPowerOfTwo(alignment)) return error.InvalidAmdVramAllocation;
        var upper_end = self.visible.mc_end;
        var attempt: usize = 0;
        while (attempt <= self.reservation_count) : (attempt += 1) {
            if (upper_end < self.visible.mc_start or bytes - 1 > upper_end - self.visible.mc_start)
                return error.AmdVisibleVramExhausted;
            const candidate = (upper_end - bytes + 1) & ~(alignment - 1);
            const candidate_end = std.math.add(u64, candidate, bytes - 1) catch return error.InvalidAmdVramAllocation;
            if (candidate < self.visible.mc_start or candidate_end > self.visible.mc_end) return error.AmdVisibleVramExhausted;
            var collision_start: ?u64 = null;
            for (self.reservations[0..self.reservation_count]) |used| if (rangesOverlap(.{ .start = candidate, .end = candidate_end }, used)) {
                collision_start = if (collision_start) |current| @min(current, used.start) else used.start;
            };
            if (collision_start) |start| {
                if (start == 0) return error.AmdVisibleVramExhausted;
                upper_end = start - 1;
                continue;
            }
            if (self.reservation_count == self.reservations.len) return error.TooManyAmdVramReservations;
            self.reservations[self.reservation_count] = .{ .start = candidate, .end = candidate_end };
            self.reservation_count += 1;
            return .{
                .cpu_address = self.visible.cpu_start + (candidate - self.visible.mc_start),
                .mc_address = candidate,
                .bytes = bytes,
            };
        }
        return error.AmdVisibleVramExhausted;
    }

    pub fn releasePinned(self: *AmdVramAllocator, allocation: AmdVramAllocation) !void {
        if (!self.firmware_map_sealed or allocation.bytes == 0 or allocation.mc_address < self.visible.mc_start or
            allocation.cpu_address != self.visible.cpu_start + (allocation.mc_address - self.visible.mc_start))
            return error.InvalidAmdVramAllocation;
        const end = std.math.add(u64, allocation.mc_address, allocation.bytes - 1) catch return error.InvalidAmdVramAllocation;
        for (self.reservations[0..self.reservation_count], 0..) |reservation, index| {
            if (reservation.start != allocation.mc_address or reservation.end != end) continue;
            self.reservation_count -= 1;
            self.reservations[index] = self.reservations[self.reservation_count];
            return;
        }
        return error.AmdVramAllocationNotFound;
    }
};

fn rangesOverlap(left: AmdVramRange, right: AmdVramRange) bool {
    return left.start <= right.end and right.start <= left.end;
}

fn rangesTouch(left: AmdVramRange, right: AmdVramRange) bool {
    return rangesOverlap(left, right) or (left.end != ~@as(u64, 0) and left.end + 1 == right.start) or
        (right.end != ~@as(u64, 0) and right.end + 1 == left.start);
}

pub fn reserveAmdGmc11BootVram(
    allocator: *AmdVramAllocator,
    memory: AmdGmc11MemorySnapshot,
    firmware_tail_bytes: u64,
    reserve_memory_training: bool,
) !void {
    if (allocator.firmware_map_sealed or allocator.visible.mc_start != memory.vram_mc_base)
        return error.InvalidAmdGmc11BootVramMap;
    try allocator.reserve(allocator.visible.mc_start, allocator.visible.framebuffer_mc_end - allocator.visible.mc_start + 1);
    if (firmware_tail_bytes == 0) return;
    if (memory.vram_bytes < firmware_tail_bytes) return error.InvalidAmdGmc11VramRange;
    const firmware_start = memory.vram_mc_base + memory.vram_bytes - firmware_tail_bytes;
    const vram_end = memory.vram_mc_base + memory.vram_bytes - 1;
    const visible_firmware_start = @max(firmware_start, allocator.visible.mc_start);
    const visible_firmware_end = @min(vram_end, allocator.visible.mc_end);
    if (visible_firmware_start <= visible_firmware_end)
        try allocator.reserve(visible_firmware_start, visible_firmware_end - visible_firmware_start + 1);
    if (!reserve_memory_training) return;
    const one_mib: u64 = 1024 * 1024;
    if (memory.vram_bytes < firmware_tail_bytes + one_mib) return error.InvalidAmdGmc11VramRange;
    const training_offset = (memory.vram_bytes - firmware_tail_bytes - one_mib + one_mib - 1) & ~(one_mib - 1);
    const training_start = memory.vram_mc_base + training_offset;
    const training_end = training_start + 4096 - 1;
    if (training_start <= allocator.visible.mc_end and training_end >= allocator.visible.mc_start)
        try allocator.reserve(@max(training_start, allocator.visible.mc_start), @min(training_end, allocator.visible.mc_end) - @max(training_start, allocator.visible.mc_start) + 1);
}
pub const AmdPspGttStaging = struct {
    page_table_address: u64 = 0,
    page_table_pages: u64 = 0,
    buffer_address: u64 = 0,
    buffer_pages: u64 = 0,
    ring_page: u16 = 0,
    command_page: u16 = 1,
    fence_page: u16 = 2,
    active: bool = false,

    pub fn release(self: *AmdPspGttStaging, pages: *physical.Allocator) void {
        if (self.page_table_pages != 0) pages.release(self.page_table_address, self.page_table_pages) catch {};
        if (self.buffer_pages != 0) pages.release(self.buffer_address, self.buffer_pages) catch {};
        self.* = .{};
    }
};

pub fn planAmdGart(discovery: *const AmdIpDiscovery, memory: AmdMemoryPlan, staging: AmdPspGttStaging) !AmdGartPlan {
    if (staging.page_table_address == 0 or staging.page_table_pages != 1 or staging.buffer_pages != 3 or staging.active)
        return error.InvalidAmdGartStaging;
    const mmhub = discovery.find(amd_hw_id.mmhub, 0) orelse return error.AmdMmhubMissing;
    if (mmhub.base_count == 0) return error.AmdMmhubBaseMissing;
    const needs_gfxhub = memory.family == .v9_0 or memory.family == .v10_0 or memory.family == .v12_0;
    const gfxhub: ?*const AmdIp = if (needs_gfxhub) discovery.find(amd_hw_id.gfx, 0) orelse return error.AmdGfxhubMissing else null;
    if (gfxhub) |ip| if (ip.base_count == 0) return error.AmdGfxhubBaseMissing;
    return .{
        .family = memory.family,
        .gfxhub_base = if (gfxhub) |ip| ip.bases[0] else null,
        .mmhub_base = mmhub.bases[0],
        .table_cpu_address = staging.page_table_address,
        .entries = 512,
        .window_bytes = 512 * 4096,
    };
}

pub fn bindAmdGmc11GartAddressSpace(plan: AmdGartPlan, table_mc_address: u64, window_start: u64) !AmdGartPlan {
    if (plan.family != .v11_0) return error.UnsupportedAmdGartAddressSpace;
    if (plan.table_mc_address != null or plan.window_start != null or plan.window_end != null or plan.active)
        return error.AmdGartAlreadyBound;
    if (table_mc_address == 0 or (table_mc_address & 4095) != 0) return error.InvalidAmdGartTableMcAddress;
    if ((window_start & 4095) != 0 or plan.window_bytes == 0 or (plan.window_bytes & 4095) != 0)
        return error.InvalidAmdGartWindow;
    const window_end = std.math.add(u64, window_start, plan.window_bytes - 1) catch return error.AmdGartWindowOverflow;
    const max_gpu_address: u64 = 0x0000ffffffffffff;
    if (table_mc_address > max_gpu_address or window_end > max_gpu_address) return error.AmdGartAddressOutsideGmc11Range;
    var bound = plan;
    bound.table_mc_address = table_mc_address;
    bound.window_start = window_start;
    bound.window_end = window_end;
    return bound;
}

pub fn copyAmdGmc11GartTable(plan: AmdGartPlan, allocation: AmdVramAllocation) !void {
    if (plan.family != .v11_0 or plan.active or plan.table_cpu_address == 0 or plan.table_mc_address != null or
        allocation.bytes != 4096 or (allocation.cpu_address & 4095) != 0 or (allocation.mc_address & 4095) != 0)
        return error.InvalidAmdGartTableCopy;
    const source: [*]const u8 = @ptrFromInt(plan.table_cpu_address);
    const destination: [*]align(1) volatile u8 = @ptrFromInt(allocation.cpu_address);
    for (0..allocation.bytes) |index| destination[index] = source[index];
}

pub fn prepareAmdGmc11GartAperture(plan: AmdGartPlan) !AmdGmc11GartApertureValues {
    if (plan.family != .v11_0 or plan.active or plan.table_mc_address == null or plan.window_start == null or plan.window_end == null)
        return error.AmdGartAddressSpaceNotBound;
    const page_table_base = plan.table_mc_address.? | 1;
    return .{
        .page_table_base_low = @truncate(page_table_base),
        .page_table_base_high = @truncate(page_table_base >> 32),
        .page_table_start_low = @truncate(plan.window_start.? >> 12),
        .page_table_start_high = @truncate(plan.window_start.? >> 44),
        .page_table_end_low = @truncate(plan.window_end.? >> 12),
        .page_table_end_high = @truncate(plan.window_end.? >> 44),
    };
}

pub fn amdGmc11VramMcToPhysical(memory: AmdGmc11MemorySnapshot, mc_address: u64) !u64 {
    if (mc_address < memory.vram_mc_base or mc_address - memory.vram_mc_base >= memory.vram_bytes)
        return error.AmdVramAddressOutsideRange;
    return std.math.add(u64, memory.vram_mc_offset, mc_address - memory.vram_mc_base) catch
        error.AmdVramPhysicalAddressOverflow;
}

pub fn prepareAmdGmc11SystemPages(
    allocator: *AmdVramAllocator,
    memory: AmdGmc11MemorySnapshot,
    pages: *physical.Allocator,
) !AmdGmc11SystemPages {
    if (!allocator.firmware_map_sealed) return error.AmdVramFirmwareMapIncomplete;
    const dummy = pages.allocate(1) orelse return error.OutOfMemory;
    errdefer pages.release(dummy, 1) catch {};
    @memset(@as([*]u8, @ptrFromInt(dummy))[0..4096], 0);
    const scratch = try allocator.allocatePinned(4096, 4096);
    errdefer allocator.releasePinned(scratch) catch {};
    const scratch_physical = try amdGmc11VramMcToPhysical(memory, scratch.mc_address);
    if ((scratch_physical & 4095) != 0 or scratch_physical > 0x0000fffffffff000 or dummy > 0x0000fffffffff000)
        return error.AmdGmc11SystemPageOutsideRange;
    return .{ .scratch = scratch, .scratch_physical = scratch_physical, .dummy_physical = dummy };
}

pub fn clearAmdGmc11Scratch(system_pages: AmdGmc11SystemPages) void {
    const destination: [*]align(1) volatile u8 = @ptrFromInt(system_pages.scratch.cpu_address);
    for (0..system_pages.scratch.bytes) |index| destination[index] = 0;
}

pub fn prepareAmdGmc11SystemAperture(
    memory: AmdGmc11MemorySnapshot,
    system_pages: AmdGmc11SystemPages,
) !AmdGmc11SystemApertureValues {
    if (memory.vram_bytes == 0 or system_pages.scratch.bytes != 4096 or
        system_pages.scratch_physical != try amdGmc11VramMcToPhysical(memory, system_pages.scratch.mc_address) or
        (system_pages.scratch_physical & 4095) != 0 or (system_pages.dummy_physical & 4095) != 0)
        return error.InvalidAmdGmc11SystemPages;
    const vram_end = std.math.add(u64, memory.vram_mc_base, memory.vram_bytes - 1) catch
        return error.InvalidAmdGmc11VramRange;
    return .{
        .agp_base = 0,
        .agp_bottom = 0x00ffffff,
        .agp_top = 0,
        .aperture_low = @truncate(memory.vram_mc_base >> 18),
        .aperture_high = @truncate(vram_end >> 18),
        .default_low = @truncate(system_pages.scratch_physical >> 12),
        .default_high = @truncate(system_pages.scratch_physical >> 44),
        .fault_default_low = @truncate(system_pages.dummy_physical >> 12),
        .fault_default_high = @truncate(system_pages.dummy_physical >> 44),
    };
}

pub fn amdGmc11GartMutableRegisters(registers: AmdGmc11GartRegisters) !AmdGmc11GartRegisterSet {
    var result = AmdGmc11GartRegisterSet{};
    const fixed = [_]u32{
        registers.page_table_base_low, registers.page_table_base_high,
        registers.page_table_start_low, registers.page_table_start_high,
        registers.page_table_end_low, registers.page_table_end_high,
        registers.agp_base, registers.agp_bottom, registers.agp_top,
        registers.system_aperture_low, registers.system_aperture_high,
        registers.system_default_low, registers.system_default_high,
        registers.fault_default_low, registers.fault_default_high, registers.fault_control2,
        registers.l1_tlb_control, registers.l2_control, registers.l2_control2,
        registers.l2_control3, registers.l2_control4, registers.l2_control5,
        registers.context_control,
        registers.identity_low_low, registers.identity_low_high,
        registers.identity_high_low, registers.identity_high_high,
        registers.identity_offset_low, registers.identity_offset_high,
        registers.invalidate_request,
    };
    for (fixed) |offset| try result.add(offset);
    for (0..15) |index| {
        const control_delta: u32 = @intCast(index * registers.context_control_stride);
        const address_delta: u32 = @intCast(index * registers.context_address_stride);
        try result.add(registers.context1_control + control_delta);
        try result.add(registers.context1_page_table_start_low + address_delta);
        try result.add(registers.context1_page_table_start_high + address_delta);
        try result.add(registers.context1_page_table_end_low + address_delta);
        try result.add(registers.context1_page_table_end_high + address_delta);
    }
    for (0..18) |index| {
        const delta: u32 = @intCast(index * registers.invalidate_range_stride);
        try result.add(registers.invalidate_range_low + delta);
        try result.add(registers.invalidate_range_high + delta);
    }
    return result;
}

fn captureAmdGmc11GartSnapshotInPlace(registers: *const AmdGmc11GartRegisterSet, io: AmdRegisterIo, snapshot: *AmdGmc11GartSnapshot) !void {
    if (registers.count == 0 or registers.count > registers.offsets.len) return error.InvalidAmdGartRegisterSet;
    snapshot.* = AmdGmc11GartSnapshot{ .count = registers.count };
    for (registers.offsets[0..registers.count], 0..) |offset, index| {
        snapshot.offsets[index] = offset;
        snapshot.values[index] = try io.read(io.context, offset);
    }
}

pub fn captureAmdGmc11GartSnapshot(registers: AmdGmc11GartRegisterSet, io: AmdRegisterIo) !AmdGmc11GartSnapshot {
    var snapshot = AmdGmc11GartSnapshot{};
    try captureAmdGmc11GartSnapshotInPlace(&registers, io, &snapshot);
    return snapshot;
}

pub fn restoreAmdGmc11GartSnapshot(snapshot: AmdGmc11GartSnapshot, io: AmdRegisterIo) !void {
    if (snapshot.count == 0 or snapshot.count > snapshot.offsets.len) return error.InvalidAmdGartSnapshot;
    var failed = false;
    var index = snapshot.count;
    while (index != 0) {
        index -= 1;
        io.write(io.context, snapshot.offsets[index], snapshot.values[index]) catch { failed = true; };
    }
    for (snapshot.offsets[0..snapshot.count], snapshot.values[0..snapshot.count]) |offset, expected| {
        const observed = io.read(io.context, offset) catch { failed = true; continue; };
        if (observed != expected) failed = true;
    }
    if (failed) return error.AmdGartRollbackFailed;
}

pub fn applyAmdGmc11RegisterTransaction(
    registers: AmdGmc11GartRegisterSet,
    writes: AmdRegisterWriteSet,
    io: AmdRegisterIo,
) !AmdGmc11RegisterTransaction {
    if (writes.count == 0 or writes.count > writes.writes.len) return error.InvalidAmdRegisterWriteSet;
    for (writes.writes[0..writes.count]) |write| {
        var known = false;
        for (registers.offsets[0..registers.count]) |offset| if (offset == write.offset) { known = true; break; };
        if (!known) return error.AmdRegisterWriteOutsideSnapshot;
    }
    const snapshot = try captureAmdGmc11GartSnapshot(registers, io);
    var applied: usize = 0;
    for (writes.writes[0..writes.count]) |write| {
        io.write(io.context, write.offset, write.value) catch {
            restoreAmdGmc11GartSnapshot(snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterWriteFailed;
        };
        applied += 1;
        const observed = io.read(io.context, write.offset) catch {
            restoreAmdGmc11GartSnapshot(snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterReadbackFailed;
        };
        if ((observed & write.verify_mask) != (write.value & write.verify_mask)) {
            restoreAmdGmc11GartSnapshot(snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterReadbackMismatch;
        }
    }
    return .{ .snapshot = snapshot, .writes_applied = applied };
}

fn applyAmdGmc11RegisterTransactionInPlace(
    registers: *const AmdGmc11GartRegisterSet,
    writes: *const AmdRegisterWriteSet,
    io: AmdRegisterIo,
    transaction: *AmdGmc11RegisterTransaction,
) !void {
    if (writes.count == 0 or writes.count > writes.writes.len) return error.InvalidAmdRegisterWriteSet;
    for (writes.writes[0..writes.count]) |write| {
        var known = false;
        for (registers.offsets[0..registers.count]) |offset| if (offset == write.offset) { known = true; break; };
        if (!known) return error.AmdRegisterWriteOutsideSnapshot;
    }
    transaction.snapshot = try captureAmdGmc11GartSnapshot(registers.*, io);
    transaction.writes_applied = 0;
    for (writes.writes[0..writes.count]) |write| {
        io.write(io.context, write.offset, write.value) catch {
            restoreAmdGmc11GartSnapshot(transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterWriteFailed;
        };
        transaction.writes_applied += 1;
        const observed = io.read(io.context, write.offset) catch {
            restoreAmdGmc11GartSnapshot(transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterReadbackFailed;
        };
        if ((observed & write.verify_mask) != (write.value & write.verify_mask)) {
            restoreAmdGmc11GartSnapshot(transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
            return error.AmdGartRegisterReadbackMismatch;
        }
    }
}

fn amdSnapshotValue(snapshot: *const AmdGmc11GartSnapshot, offset: u32) !u32 {
    for (snapshot.offsets[0..snapshot.count], snapshot.values[0..snapshot.count]) |candidate, value|
        if (candidate == offset) return value;
    return error.AmdRegisterMissingFromSnapshot;
}

fn amdRmw(snapshot: *const AmdGmc11GartSnapshot, offset: u32, clear_mask: u32, set_bits: u32) !u32 {
    if ((set_bits & clear_mask) != set_bits) return error.InvalidAmdRegisterMask;
    return (try amdSnapshotValue(snapshot, offset) & ~clear_mask) | set_bits;
}

fn buildAmdGmc11GartBootstrapWritesInPlace(
    registers: AmdGmc11GartRegisters,
    aperture: AmdGmc11GartApertureValues,
    system: AmdGmc11SystemApertureValues,
    snapshot: *const AmdGmc11GartSnapshot,
    writes: *AmdRegisterWriteSet,
) !void {
    if (snapshot.count != 141) return error.InvalidAmdGartSnapshot;
    writes.* = AmdRegisterWriteSet{};
    try writes.add(.{ .offset = registers.page_table_base_low, .value = aperture.page_table_base_low });
    try writes.add(.{ .offset = registers.page_table_base_high, .value = aperture.page_table_base_high });
    try writes.add(.{ .offset = registers.page_table_start_low, .value = aperture.page_table_start_low });
    try writes.add(.{ .offset = registers.page_table_start_high, .value = aperture.page_table_start_high });
    try writes.add(.{ .offset = registers.page_table_end_low, .value = aperture.page_table_end_low });
    try writes.add(.{ .offset = registers.page_table_end_high, .value = aperture.page_table_end_high });
    try writes.add(.{ .offset = registers.agp_base, .value = system.agp_base });
    try writes.add(.{ .offset = registers.agp_bottom, .value = system.agp_bottom });
    try writes.add(.{ .offset = registers.agp_top, .value = system.agp_top });
    try writes.add(.{ .offset = registers.system_aperture_low, .value = system.aperture_low });
    try writes.add(.{ .offset = registers.system_aperture_high, .value = system.aperture_high });
    try writes.add(.{ .offset = registers.system_default_low, .value = system.default_low });
    try writes.add(.{ .offset = registers.system_default_high, .value = system.default_high });
    try writes.add(.{ .offset = registers.fault_default_low, .value = system.fault_default_low });
    try writes.add(.{ .offset = registers.fault_default_high, .value = system.fault_default_high });
    try writes.add(.{ .offset = registers.fault_control2, .value = try amdRmw(snapshot, registers.fault_control2, 0x00040000, 0x00040000) });
    try writes.add(.{ .offset = registers.l1_tlb_control, .value = try amdRmw(snapshot, registers.l1_tlb_control, 0x00003ff9, 0x00000059) });
    try writes.add(.{ .offset = registers.l2_control, .value = try amdRmw(snapshot, registers.l2_control, 0x03fc0913, 0x00080801) });
    try writes.add(.{ .offset = registers.l2_control2, .value = try amdRmw(snapshot, registers.l2_control2, 0x00000003, 0x00000003), .verify_mask = 0xfffffffc });
    try writes.add(.{ .offset = registers.l2_control3, .value = (0x80100007 & ~@as(u32, 0x000f803f)) | 9 | (6 << 15) });
    try writes.add(.{ .offset = registers.l2_control4, .value = 0x000000c1 & ~@as(u32, 0x000000c0) });
    try writes.add(.{ .offset = registers.l2_control5, .value = 0x00003fe0 & ~@as(u32, 0x0000001f) });
    try writes.add(.{ .offset = registers.context_control, .value = try amdRmw(snapshot, registers.context_control, 0x00000087, 0x00000001) });
    try writes.add(.{ .offset = registers.identity_low_low, .value = 0xffffffff });
    try writes.add(.{ .offset = registers.identity_low_high, .value = 0x0000000f });
    try writes.add(.{ .offset = registers.identity_high_low, .value = 0 });
    try writes.add(.{ .offset = registers.identity_high_high, .value = 0 });
    try writes.add(.{ .offset = registers.identity_offset_low, .value = 0 });
    try writes.add(.{ .offset = registers.identity_offset_high, .value = 0 });
    // Process VMIDs remain disabled until their page-directory manager exists.
    for (0..15) |index| try writes.add(.{
        .offset = registers.context1_control + @as(u32, @intCast(index * registers.context_control_stride)),
        .value = 0,
    });
    for (0..18) |index| {
        const delta: u32 = @intCast(index * registers.invalidate_range_stride);
        try writes.add(.{ .offset = registers.invalidate_range_low + delta, .value = 0xffffffff });
        try writes.add(.{ .offset = registers.invalidate_range_high + delta, .value = 0x0000001f });
    }
    if (writes.count != 80) return error.InvalidAmdGartBootstrapWriteCount;
}

pub fn buildAmdGmc11GartBootstrapWrites(
    registers: AmdGmc11GartRegisters,
    aperture: AmdGmc11GartApertureValues,
    system: AmdGmc11SystemApertureValues,
    snapshot: *const AmdGmc11GartSnapshot,
) !AmdRegisterWriteSet {
    var writes = AmdRegisterWriteSet{};
    try buildAmdGmc11GartBootstrapWritesInPlace(registers, aperture, system, snapshot, &writes);
    return writes;
}

const AmdGartRegisterTestBank = struct {
    offsets: [144]u32 = .{0} ** 144,
    values: [144]u32 = .{0} ** 144,
    count: usize = 0,
    fail_read: ?u32 = null,
    fail_write: ?u32 = null,
    fail_write_once: ?u32 = null,
    invalidate_request: ?u32 = null,
    invalidate_ack: ?u32 = null,
    acknowledge_after_reads: ?u32 = null,
    acknowledge_reads: u32 = 0,

    fn position(self: *const AmdGartRegisterTestBank, offset: u32) ?usize {
        for (self.offsets[0..self.count], 0..) |candidate, index| if (candidate == offset) return index;
        return null;
    }
    fn read(context: *anyopaque, offset: u32) !u32 {
        const self: *AmdGartRegisterTestBank = @ptrCast(@alignCast(context));
        if (self.fail_read != null and self.fail_read.? == offset) return error.InjectedAmdRegisterReadFailure;
        if (self.invalidate_ack != null and self.invalidate_ack.? == offset and self.acknowledge_after_reads != null) {
            self.acknowledge_reads += 1;
            if (self.acknowledge_reads >= self.acknowledge_after_reads.?)
                self.values[self.position(offset) orelse return error.UnknownAmdRegister] |= 1;
        }
        return self.values[self.position(offset) orelse return error.UnknownAmdRegister];
    }
    fn write(context: *anyopaque, offset: u32, value: u32) !void {
        const self: *AmdGartRegisterTestBank = @ptrCast(@alignCast(context));
        if (self.fail_write != null and self.fail_write.? == offset) return error.InjectedAmdRegisterWriteFailure;
        if (self.fail_write_once != null and self.fail_write_once.? == offset) {
            self.fail_write_once = null;
            return error.InjectedAmdRegisterWriteFailure;
        }
        self.values[self.position(offset) orelse return error.UnknownAmdRegister] = value;
        if (self.invalidate_request != null and self.invalidate_request.? == offset) self.acknowledge_reads = 0;
    }
    fn io(self: *AmdGartRegisterTestBank) AmdRegisterIo {
        return .{ .context = self, .read = &read, .write = &write };
    }
};

pub fn invalidateAmdGmc11Gart(
    registers: AmdGmc11GartRegisters,
    engine: u5,
    vmid: u4,
    timeout_polls: u32,
    io: AmdRegisterIo,
) !AmdGmc11InvalidateResult {
    if (engine >= 18 or timeout_polls == 0) return error.InvalidAmdGartInvalidateRequest;
    const request_offset = registers.invalidate_request + @as(u32, engine) * registers.invalidate_engine_stride;
    const ack_offset = registers.invalidate_ack + @as(u32, engine) * registers.invalidate_engine_stride;
    const vmid_mask = @as(u32, 1) << vmid;
    // Invalidate L2 PTE/PDE0/PDE1/PDE2 and L1 for the selected VMID.
    try io.write(io.context, request_offset, 0x00f80000 | vmid_mask);
    var polls: u32 = 0;
    while (polls < timeout_polls) {
        polls += 1;
        if ((try io.read(io.context, ack_offset) & vmid_mask) != 0)
            return .{ .engine = engine, .vmid = vmid, .polls = polls };
    }
    return error.AmdGartInvalidateTimeout;
}

pub fn activateAmdGmc11Gart(
    register_set: *const AmdGmc11GartRegisterSet,
    registers: AmdGmc11GartRegisters,
    writes: *const AmdRegisterWriteSet,
    timeout_polls: u32,
    io: AmdRegisterIo,
    transaction: *AmdGmc11RegisterTransaction,
) !AmdGmc11InvalidateResult {
    try applyAmdGmc11RegisterTransactionInPlace(register_set, writes, io, transaction);
    return invalidateAmdGmc11Gart(registers, 0, 0, timeout_polls, io) catch |err| {
        restoreAmdGmc11GartSnapshot(transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
        transaction.writes_applied = 0;
        return err;
    };
}

pub fn prepareAmdGmc11Activation(
    workspace: *AmdGmc11ActivationWorkspace,
    registers: AmdGmc11GartRegisters,
    aperture: AmdGmc11GartApertureValues,
    system: AmdGmc11SystemApertureValues,
    io: AmdRegisterIo,
) !void {
    if (workspace.prepared or workspace.active) return error.AmdGartActivationWorkspaceBusy;
    workspace.register_set = try amdGmc11GartMutableRegisters(registers);
    try captureAmdGmc11GartSnapshotInPlace(&workspace.register_set, io, &workspace.transaction.snapshot);
    try buildAmdGmc11GartBootstrapWritesInPlace(registers, aperture, system, &workspace.transaction.snapshot, &workspace.writes);
    workspace.transaction.writes_applied = 0;
    workspace.snapshot_digest = amdGartSnapshotDigest(&workspace.transaction.snapshot);
    workspace.write_digest = amdGartWriteDigest(&workspace.writes);
    workspace.invalidate_polls = 0;
    workspace.prepared = true;
}

pub fn commitAmdGmc11Activation(
    workspace: *AmdGmc11ActivationWorkspace,
    registers: AmdGmc11GartRegisters,
    timeout_polls: u32,
    io: AmdRegisterIo,
) !AmdGmc11InvalidateResult {
    if (!workspace.prepared or workspace.active) return error.AmdGartActivationWorkspaceNotReady;
    const result = activateAmdGmc11Gart(
        &workspace.register_set,
        registers,
        &workspace.writes,
        timeout_polls,
        io,
        &workspace.transaction,
    ) catch |err| {
        workspace.prepared = false;
        return err;
    };
    workspace.prepared = false;
    workspace.active = true;
    workspace.invalidate_polls = result.polls;
    return result;
}

pub fn rollbackAmdGmc11Activation(workspace: *AmdGmc11ActivationWorkspace, io: AmdRegisterIo) !void {
    if (!workspace.active) return error.AmdGartActivationWorkspaceNotActive;
    try restoreAmdGmc11GartSnapshot(workspace.transaction.snapshot, io);
    workspace.transaction.writes_applied = 0;
    workspace.active = false;
}

// Boot-time validation runs before scheduler stacks exist, so keep its large
// synthetic register state out of the firmware-provided entry stack.
var amd_bootstrap_test_bank = AmdGartRegisterTestBank{};
var amd_bootstrap_test_workspace = AmdGmc11ActivationWorkspace{};

pub fn validateAmdGmc11GartRollback(registers: AmdGmc11GartRegisterSet) !void {
    if (registers.count != 141) return error.InvalidAmdGartRegisterSet;
    var bank = AmdGartRegisterTestBank{ .count = registers.count };
    for (registers.offsets[0..registers.count], 0..) |offset, index| {
        bank.offsets[index] = offset;
        bank.values[index] = 0xa5000000 | @as(u32, @intCast(index));
    }
    const snapshot = try captureAmdGmc11GartSnapshot(registers, bank.io());
    var writes = AmdRegisterWriteSet{};
    try writes.add(.{ .offset = registers.offsets[0], .value = 0x11111111 });
    try writes.add(.{ .offset = registers.offsets[1], .value = 0x22222222 });
    try writes.add(.{ .offset = registers.offsets[2], .value = 0x33333333 });
    const transaction = try applyAmdGmc11RegisterTransaction(registers, writes, bank.io());
    if (transaction.writes_applied != 3 or bank.values[0] != 0x11111111 or bank.values[1] != 0x22222222 or bank.values[2] != 0x33333333)
        return error.AmdGartRegisterTransactionMismatch;
    try restoreAmdGmc11GartSnapshot(transaction.snapshot, bank.io());
    bank.fail_write_once = registers.offsets[1];
    if (applyAmdGmc11RegisterTransaction(registers, writes, bank.io())) |_| return error.AmdGartWriteFailureNotDetected else |err|
        if (err != error.AmdGartRegisterWriteFailed) return err;
    for (snapshot.values[0..snapshot.count], bank.values[0..bank.count]) |expected, observed|
        if (observed != expected) return error.AmdGartAutomaticRollbackMismatch;

    for (registers.offsets[0..registers.count], 0..) |offset, index|
        try bank.io().write(bank.io().context, offset, 0x5a000000 | @as(u32, @intCast(index)));
    try restoreAmdGmc11GartSnapshot(snapshot, bank.io());
    for (snapshot.values[0..snapshot.count], bank.values[0..bank.count]) |expected, observed|
        if (observed != expected) return error.AmdGartRollbackMismatch;

    for (bank.values[0..bank.count]) |*value| value.* = 0xcccccccc;
    const failed_index = registers.count / 2;
    bank.fail_write = registers.offsets[failed_index];
    if (restoreAmdGmc11GartSnapshot(snapshot, bank.io())) |_| return error.AmdGartRollbackFailureNotDetected else |err|
        if (err != error.AmdGartRollbackFailed) return err;
    for (bank.values[0..bank.count], snapshot.values[0..snapshot.count], 0..) |observed, expected, index| {
        if (index == failed_index) {
            if (observed == expected) return error.AmdGartInjectedFailureMissing;
        } else if (observed != expected) return error.AmdGartRollbackDidNotContinue;
    }
    bank.fail_write = null;
    try restoreAmdGmc11GartSnapshot(snapshot, bank.io());
    bank.fail_read = registers.offsets[0];
    if (captureAmdGmc11GartSnapshot(registers, bank.io())) |_| return error.AmdGartSnapshotFailureNotDetected else |err|
        if (err != error.InjectedAmdRegisterReadFailure) return err;
}

pub fn validateAmdGmc11GartRollbackSelfTest() !void {
    var registers = AmdGmc11GartRegisterSet{ .count = 141 };
    for (registers.offsets[0..registers.count], 0..) |*offset, index| offset.* = 0x1000 + @as(u32, @intCast(index)) * 4;
    try validateAmdGmc11GartRollback(registers);
}

pub fn validateAmdGmc11BootstrapWrites(
    registers: AmdGmc11GartRegisters,
    aperture: AmdGmc11GartApertureValues,
    system: AmdGmc11SystemApertureValues,
) !void {
    const register_set = try amdGmc11GartMutableRegisters(registers);
    amd_bootstrap_test_bank = AmdGartRegisterTestBank{ .count = register_set.count + 1 };
    const bank = &amd_bootstrap_test_bank;
    for (register_set.offsets[0..register_set.count], 0..) |offset, index| {
        bank.offsets[index] = offset;
        bank.values[index] = 0x5a000000 | @as(u32, @intCast(index));
    }
    bank.offsets[register_set.count] = registers.invalidate_ack;
    bank.values[register_set.count] = 0;
    bank.invalidate_request = registers.invalidate_request;
    bank.invalidate_ack = registers.invalidate_ack;
    bank.values[bank.position(registers.invalidate_ack).?] = 0;
    amd_bootstrap_test_workspace = AmdGmc11ActivationWorkspace{};
    const workspace = &amd_bootstrap_test_workspace;
    try prepareAmdGmc11Activation(workspace, registers, aperture, system, bank.io());
    bank.acknowledge_after_reads = 3;
    const invalidation = try commitAmdGmc11Activation(workspace, registers, 8, bank.io());
    const transaction = &workspace.transaction;
    if (workspace.snapshot_digest == 0 or workspace.write_digest == 0 or workspace.invalidate_polls != 3)
        return error.AmdGartActivationTelemetryMissing;
    if (transaction.writes_applied != 80 or bank.values[bank.position(registers.page_table_base_low).?] != aperture.page_table_base_low or
        bank.values[bank.position(registers.system_default_low).?] != system.default_low or
        (bank.values[bank.position(registers.context_control).?] & 0x87) != 1 or
        (bank.values[bank.position(registers.l1_tlb_control).?] & 0x3ff9) != 0x59 or
        (bank.values[bank.position(registers.l2_control).?] & 0x03fc0913) != 0x00080801)
        return error.AmdGartBootstrapWriteMismatch;
    for (0..15) |index| if (bank.values[bank.position(registers.context1_control + @as(u32, @intCast(index * registers.context_control_stride))).?] != 0)
        return error.AmdGartProcessVmidEnabledEarly;
    for (0..18) |index| {
        const delta: u32 = @intCast(index * registers.invalidate_range_stride);
        if (bank.values[bank.position(registers.invalidate_range_low + delta).?] != 0xffffffff or
            bank.values[bank.position(registers.invalidate_range_high + delta).?] != 0x1f)
            return error.AmdGartInvalidateRangeMismatch;
    }
    if (invalidation.polls != 3 or bank.values[bank.position(registers.invalidate_request).?] != 0x00f80001)
        return error.AmdGartInvalidateHandshakeMismatch;
    try rollbackAmdGmc11Activation(workspace, bank.io());
    for (transaction.snapshot.values[0..transaction.snapshot.count], bank.values[0..transaction.snapshot.count]) |expected, observed|
        if (expected != observed) return error.AmdGartBootstrapRestoreMismatch;

    bank.acknowledge_after_reads = null;
    bank.values[bank.position(registers.invalidate_ack).?] = 0;
    try prepareAmdGmc11Activation(workspace, registers, aperture, system, bank.io());
    if (commitAmdGmc11Activation(workspace, registers, 2, bank.io())) |_| return error.AmdGartInvalidateTimeoutNotDetected else |err|
        if (err != error.AmdGartInvalidateTimeout) return err;
    for (transaction.snapshot.values[0..transaction.snapshot.count], bank.values[0..transaction.snapshot.count]) |expected, observed|
        if (expected != observed) return error.AmdGartInvalidateTimeoutRollbackMismatch;
    if (transaction.writes_applied != 0 or workspace.prepared or workspace.active) return error.AmdGartInvalidateTimeoutTransactionStillActive;
}

pub fn validateAmdGmc11BootstrapWritesSelfTest() !void {
    const plan = AmdGartPlan{
        .family = .v11_0,
        .gfxhub_base = null,
        .mmhub_base = 0x300,
        .table_cpu_address = 0x800000,
        .entries = 512,
        .window_bytes = 2 * 1024 * 1024,
    };
    const registers = try resolveAmdGmc11GartRegisters(plan, 0x4000);
    try validateAmdGmc11BootstrapWrites(registers, .{
        .page_table_base_low = 0x01000001,
        .page_table_base_high = 0,
        .page_table_start_low = 0x2000,
        .page_table_start_high = 0,
        .page_table_end_low = 0x21ff,
        .page_table_end_high = 0,
    }, .{
        .agp_base = 0,
        .agp_bottom = 0x00ffffff,
        .agp_top = 0,
        .aperture_low = 0x1000,
        .aperture_high = 0x1fff,
        .default_low = 0x4000,
        .default_high = 0,
        .fault_default_low = 0x5000,
        .fault_default_high = 0,
    });
}

pub fn validateAmdGmc11MmioTransportSelfTest() !void {
    var registers = [_]u32{ 0x11223344, 0x55667788, 0, 0 };
    const device = pci.Device{
        .bus = 0, .slot = 1, .function = 0, .vendor = 0x1002, .device = 0x744c,
        .revision = 1, .subsystem_vendor = 0x1002, .subsystem_device = 1,
        .class = 3, .subclass = 0, .programming_interface = 0, .header_type = 0,
        .msi = true, .msix = true,
    };
    const bar = pci.Bar{ .address = @intFromPtr(&registers), .size = @sizeOf(@TypeOf(registers)), .is_64_bit = true, .prefetchable = false };
    const adapter = Adapter{
        .device = device, .driver = .amdgpu, .bars = .{ bar, null, null, null, null, null },
        .bar_count = 1, .mmio_bytes = bar.size, .register_bar = bar, .rom_bar = null,
    };
    var transport = AmdGmc11MmioTransport{ .adapter = &adapter, .uncached = true };
    if (transport.io().read(transport.io().context, 0)) |_| return error.AmdGmc11DisarmedReadAllowed else |err|
        if (err != error.AmdGmc11MmioTransportDisarmed) return err;
    if (transport.arm()) return error.AmdGmc11UnauthorizedArmAllowed else |err|
        if (err != error.AmdGmc11MmioTransportNotReady) return err;
    const valid_evidence = AmdGmc11AuthorizationEvidence{
        .selected_firmware_entries = 12,
        .validated_firmware_entries = 12,
        .security_firmware_entries = 3,
        .compatible_ip_discovery = true,
        .psp_ready = true,
        .gart_table_bound = true,
        .gart_window_bound = true,
        .rollback_registers = 141,
    };
    var invalid_evidence = valid_evidence;
    invalid_evidence.validated_firmware_entries = 11;
    if (transport.authorize(invalid_evidence)) return error.AmdGmc11IncompleteFirmwareAuthorized else |err|
        if (err != error.AmdGmc11MmioAuthorizationRejected) return err;
    invalid_evidence = valid_evidence;
    invalid_evidence.psp_ready = false;
    if (transport.authorize(invalid_evidence)) return error.AmdGmc11UnreadyPspAuthorized else |err|
        if (err != error.AmdGmc11MmioAuthorizationRejected) return err;
    try transport.authorize(valid_evidence);
    try transport.arm();
    if (try transport.io().read(transport.io().context, 4) != 0x55667788) return error.AmdGmc11MmioReadMismatch;
    try transport.io().write(transport.io().context, 8, 0xa5a55a5a);
    if (registers[2] != 0xa5a55a5a) return error.AmdGmc11MmioWriteMismatch;
    transport.disarm();
    if (transport.io().write(transport.io().context, 8, 0)) return error.AmdGmc11DisarmedWriteAllowed else |err|
        if (err != error.AmdGmc11MmioTransportDisarmed) return err;
}

pub fn validateAmdGpuVmManagerSelfTest() !void {
    var manager = AmdGpuVmManager{};
    const first = try manager.allocate();
    const second = try manager.allocate();
    if (first.vmid != 1 or second.vmid != 2) return error.AmdGpuVmidAllocationMismatch;
    try manager.map(1, 7, 0x100000000, 0x4000, 0, 0x8000, (1 << 1) | (1 << 2));
    try manager.map(1, 8, 0x100004000, 0x2000, 0x2000, 0x8000, 1 << 1);
    try manager.map(2, 9, 0x100000000, 0x1000, 0, 0x1000, 1 << 3);
    if (manager.map(1, 10, 0x100003000, 0x2000, 0, 0x2000, 1 << 1)) return error.AmdGpuVaOverlapAccepted else |err|
        if (err != error.AmdGpuVaOverlap) return err;
    if (manager.map(1, 10, 0x200000000, 0x2000, 0x1000, 0x2000, 1 << 1)) return error.AmdGpuVaBoOverflowAccepted else |err|
        if (err != error.InvalidAmdGpuVaMapping) return err;
    try manager.unmap(1, 0x100004000, 0x2000);
    if (manager.unmap(1, 0x100004000, 0x2000)) return error.AmdGpuVaMissingUnmapAccepted else |err|
        if (err != error.AmdGpuVaMappingNotFound) return err;
    try manager.release(1);
    const recycled = try manager.allocate();
    if (recycled.vmid != 1) return error.AmdGpuVmidNotRecycled;
    for (recycled.mappings) |mapping| if (mapping.active) return error.AmdGpuVmReleaseLeakedMapping;
    const path = try amdGpuVmPagePath(0x00007f123456789a);
    if (path.pdb2 != 0xfe or path.pdb1 != 0x48 or path.pdb0 != 0x1a2 or path.ptb != 0x167 or path.page_offset != 0x89a)
        return error.AmdGpuVmPagePathMismatch;
    if (try amdGpuVmTableBytes(512) != 4096 or try amdGpuVmTableBytes(1) != 4096)
        return error.AmdGpuVmTableSizeMismatch;
    if (amdGpuVmPagePath(0x0000800000000000)) |_| return error.AmdGpuVmNonCanonicalVaAccepted else |err|
        if (err != error.InvalidAmdGpuVa) return err;
}

pub fn resolveAmdGmc11GartRegisters(plan: AmdGartPlan, register_bar_bytes: u64) !AmdGmc11GartRegisters {
    if (plan.family != .v11_0 or plan.mmhub_base == 0) return error.UnsupportedAmdGartRegisterMap;
    return .{
        .fb_location_base = try resolveAmdRegister(plan.mmhub_base, 0x08ec, register_bar_bytes),
        .fb_offset = try resolveAmdRegister(plan.mmhub_base, 0x08d7, register_bar_bytes),
        .agp_base = try resolveAmdRegister(plan.mmhub_base, 0x08f0, register_bar_bytes),
        .agp_bottom = try resolveAmdRegister(plan.mmhub_base, 0x08ef, register_bar_bytes),
        .agp_top = try resolveAmdRegister(plan.mmhub_base, 0x08ee, register_bar_bytes),
        .system_aperture_low = try resolveAmdRegister(plan.mmhub_base, 0x08f1, register_bar_bytes),
        .system_aperture_high = try resolveAmdRegister(plan.mmhub_base, 0x08f2, register_bar_bytes),
        .system_default_low = try resolveAmdRegister(plan.mmhub_base, 0x08d8, register_bar_bytes),
        .system_default_high = try resolveAmdRegister(plan.mmhub_base, 0x08d9, register_bar_bytes),
        .fault_default_low = try resolveAmdRegister(plan.mmhub_base, 0x070f, register_bar_bytes),
        .fault_default_high = try resolveAmdRegister(plan.mmhub_base, 0x0710, register_bar_bytes),
        .fault_control2 = try resolveAmdRegister(plan.mmhub_base, 0x0709, register_bar_bytes),
        .context_control = try resolveAmdRegister(plan.mmhub_base, 0x0740, register_bar_bytes),
        .context1_control = try resolveAmdRegister(plan.mmhub_base, 0x0741, register_bar_bytes),
        .page_table_base_low = try resolveAmdRegister(plan.mmhub_base, 0x07ab, register_bar_bytes),
        .page_table_base_high = try resolveAmdRegister(plan.mmhub_base, 0x07ac, register_bar_bytes),
        .page_table_start_low = try resolveAmdRegister(plan.mmhub_base, 0x07cb, register_bar_bytes),
        .page_table_start_high = try resolveAmdRegister(plan.mmhub_base, 0x07cc, register_bar_bytes),
        .page_table_end_low = try resolveAmdRegister(plan.mmhub_base, 0x07eb, register_bar_bytes),
        .page_table_end_high = try resolveAmdRegister(plan.mmhub_base, 0x07ec, register_bar_bytes),
        .context1_page_table_start_low = try resolveAmdRegister(plan.mmhub_base, 0x07cd, register_bar_bytes),
        .context1_page_table_start_high = try resolveAmdRegister(plan.mmhub_base, 0x07ce, register_bar_bytes),
        .context1_page_table_end_low = try resolveAmdRegister(plan.mmhub_base, 0x07ed, register_bar_bytes),
        .context1_page_table_end_high = try resolveAmdRegister(plan.mmhub_base, 0x07ee, register_bar_bytes),
        .l1_tlb_control = try resolveAmdRegister(plan.mmhub_base, 0x08f3, register_bar_bytes),
        .l2_control = try resolveAmdRegister(plan.mmhub_base, 0x0700, register_bar_bytes),
        .l2_control2 = try resolveAmdRegister(plan.mmhub_base, 0x0701, register_bar_bytes),
        .l2_control3 = try resolveAmdRegister(plan.mmhub_base, 0x0702, register_bar_bytes),
        .l2_control4 = try resolveAmdRegister(plan.mmhub_base, 0x0718, register_bar_bytes),
        .l2_control5 = try resolveAmdRegister(plan.mmhub_base, 0x071e, register_bar_bytes),
        .identity_low_low = try resolveAmdRegister(plan.mmhub_base, 0x0712, register_bar_bytes),
        .identity_low_high = try resolveAmdRegister(plan.mmhub_base, 0x0713, register_bar_bytes),
        .identity_high_low = try resolveAmdRegister(plan.mmhub_base, 0x0714, register_bar_bytes),
        .identity_high_high = try resolveAmdRegister(plan.mmhub_base, 0x0715, register_bar_bytes),
        .identity_offset_low = try resolveAmdRegister(plan.mmhub_base, 0x0716, register_bar_bytes),
        .identity_offset_high = try resolveAmdRegister(plan.mmhub_base, 0x0717, register_bar_bytes),
        .invalidate_request = try resolveAmdRegister(plan.mmhub_base, 0x0774, register_bar_bytes),
        .invalidate_ack = try resolveAmdRegister(plan.mmhub_base, 0x0786, register_bar_bytes),
        .invalidate_range_low = try resolveAmdRegister(plan.mmhub_base, 0x0787, register_bar_bytes),
        .invalidate_range_high = try resolveAmdRegister(plan.mmhub_base, 0x0788, register_bar_bytes),
        .context_control_stride = 4,
        .context_address_stride = 8,
        .invalidate_engine_stride = 4,
        .invalidate_range_stride = 8,
    };
}

pub fn resolveAmdGmc11NbioRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdGmc11NbioRegisters {
    if (ip.hw_id != amd_hw_id.nbif or ip.instance != 0 or ip.base_count <= 2 or ip.bases[2] == 0)
        return error.AmdGmc11NbioBaseMissing;
    switch (version(ip)) {
        0x060301, 0x070700, 0x070701, 0x070900, 0x070901,
        0x070b00, 0x070b01, 0x070b02, 0x070b03, 0x070b04, 0x070b05,
        => {},
        else => return error.UnsupportedAmdGmc11NbioVersion,
    }
    return .{ .memsize = try resolveAmdRegister(ip.bases[2], 0x00c3, register_bar_bytes) };
}

pub fn decodeAmdGmc11MemorySnapshot(fb_location_base: u32, fb_offset: u32, memsize_mb: u32) !AmdGmc11MemorySnapshot {
    if (fb_location_base == 0xffffffff or fb_offset == 0xffffffff or memsize_mb == 0xffffffff)
        return error.AmdGmc11MemoryMmioUnavailable;
    if (memsize_mb == 0) return error.AmdGmc11VramSizeMissing;
    return .{
        .vram_mc_base = @as(u64, fb_location_base & 0x00ffffff) << 24,
        .vram_mc_offset = @as(u64, fb_offset) << 24,
        .vram_bytes = @as(u64, memsize_mb) * 1024 * 1024,
    };
}

pub fn planAmdGmc11HighGartWindow(memory: AmdGmc11MemorySnapshot, window_bytes: u64) !AmdGmc11GartWindow {
    if (window_bytes == 0 or (window_bytes & 4095) != 0) return error.InvalidAmdGartWindow;
    const max_mc_address: u64 = 0x00007fffffffffff;
    if (memory.vram_bytes == 0 or memory.vram_mc_base > max_mc_address) return error.InvalidAmdGmc11VramRange;
    const vram_end = std.math.add(u64, memory.vram_mc_base, memory.vram_bytes - 1) catch return error.InvalidAmdGmc11VramRange;
    if (vram_end > max_mc_address or window_bytes > max_mc_address + 1) return error.InvalidAmdGmc11VramRange;
    const unaligned_start = max_mc_address - window_bytes + 1;
    const start = unaligned_start & ~@as(u64, (4 * 1024 * 1024 * 1024) - 1);
    const end = std.math.add(u64, start, window_bytes - 1) catch return error.AmdGartWindowOverflow;
    if (!(end < memory.vram_mc_base or start > vram_end)) return error.AmdGartOverlapsVram;
    return .{ .start = start, .end = end };
}

pub fn mapAmdGmc11VisibleVram(memory: AmdGmc11MemorySnapshot, bar: pci.Bar, framebuffer_cpu: u64, framebuffer_bytes: u64) !AmdGmc11VisibleVram {
    const visible_bytes = @min(bar.size, memory.vram_bytes);
    if (bar.address == 0 or visible_bytes < 4096 or framebuffer_bytes == 0) return error.InvalidAmdVisibleVram;
    const cpu_end = std.math.add(u64, bar.address, visible_bytes - 1) catch return error.InvalidAmdVisibleVram;
    const mc_end = std.math.add(u64, memory.vram_mc_base, visible_bytes - 1) catch return error.InvalidAmdVisibleVram;
    const framebuffer_cpu_end = std.math.add(u64, framebuffer_cpu, framebuffer_bytes - 1) catch return error.InvalidAmdFramebufferRange;
    if (framebuffer_cpu < bar.address or framebuffer_cpu_end > cpu_end) return error.AmdFramebufferOutsideVisibleVram;
    const framebuffer_offset = framebuffer_cpu - bar.address;
    const framebuffer_mc_start = memory.vram_mc_base + framebuffer_offset;
    return .{
        .cpu_start = bar.address,
        .cpu_end = cpu_end,
        .mc_start = memory.vram_mc_base,
        .mc_end = mc_end,
        .bytes = visible_bytes,
        .framebuffer_mc_start = framebuffer_mc_start,
        .framebuffer_mc_end = framebuffer_mc_start + framebuffer_bytes - 1,
    };
}

fn resolveAmdRegister(base: u64, register_dword: u64, bar_bytes: u64) !u32 {
    const dword = std.math.add(u64, base, register_dword) catch return error.AmdRegisterOffsetOverflow;
    const offset = std.math.mul(u64, dword, 4) catch return error.AmdRegisterOffsetOverflow;
    if (offset > ~@as(u32, 0)) return error.AmdRegisterOffsetOverflow;
    if (bar_bytes < 4 or offset > bar_bytes - 4) return error.AmdRegistersOutsideBar;
    return @intCast(offset);
}

const amd_pte_valid: u64 = 1 << 0;
const amd_pte_system: u64 = 1 << 1;
const amd_pte_snooped: u64 = 1 << 2;
const amd_pte_readable: u64 = 1 << 5;
const amd_pte_writeable: u64 = 1 << 6;
const amd_gtt_pte_flags = amd_pte_valid | amd_pte_system | amd_pte_snooped | amd_pte_readable | amd_pte_writeable;

pub fn prepareAmdPspGtt(pages: *physical.Allocator) !AmdPspGttStaging {
    var result = AmdPspGttStaging{};
    errdefer result.release(pages);
    result.page_table_pages = 1;
    result.page_table_address = pages.allocate(result.page_table_pages) orelse return error.OutOfMemory;
    result.buffer_pages = 3;
    result.buffer_address = pages.allocate(result.buffer_pages) orelse return error.OutOfMemory;
    if ((result.page_table_address & 4095) != 0 or (result.buffer_address & 4095) != 0) return error.InvalidAmdGttAlignment;
    const table: [*]u64 = @ptrFromInt(result.page_table_address);
    @memset(table[0..512], 0);
    const buffers: [*]u8 = @ptrFromInt(result.buffer_address);
    @memset(buffers[0 .. result.buffer_pages * 4096], 0);
    table[result.ring_page] = amdGttPte(result.buffer_address);
    table[result.command_page] = amdGttPte(result.buffer_address + 4096);
    table[result.fence_page] = amdGttPte(result.buffer_address + 8192);
    return result;
}

pub fn validateAmdPspGtt(pages: *physical.Allocator) !void {
    var staging = try prepareAmdPspGtt(pages);
    defer staging.release(pages);
    const table: [*]const u64 = @ptrFromInt(staging.page_table_address);
    if (table[staging.ring_page] != amdGttPte(staging.buffer_address) or
        table[staging.command_page] != amdGttPte(staging.buffer_address + 4096) or
        table[staging.fence_page] != amdGttPte(staging.buffer_address + 8192) or staging.active)
        return error.AmdPspGttValidationFailed;
    const buffers: [*]const u8 = @ptrFromInt(staging.buffer_address);
    for (buffers[0 .. staging.buffer_pages * 4096]) |byte| if (byte != 0) return error.AmdPspGttBufferNotZero;
}

fn amdGttPte(address: u64) u64 {
    return (address & 0x0000fffffffff000) | amd_gtt_pte_flags;
}

pub fn planAmdMemory(bars: [6]?pci.Bar, register_bar: ?pci.Bar, family: GmcFamily) !AmdMemoryPlan {
    const registers = register_bar orelse return error.AmdRegisterBarMissing;
    const doorbells = bars[2] orelse return error.AmdDoorbellBarMissing;
    if (registers.size < 4096 or registers.prefetchable or doorbells.size < 4096 or doorbells.size > 16 * 1024 * 1024 or
        (registers.address & 4095) != 0 or (doorbells.address & 4095) != 0 or
        registers.address == doorbells.address or aperturesOverlap(registers, doorbells))
        return error.InvalidAmdMmioApertures;
    const vram: ?pci.Bar = if (bars[0]) |bar| if (bar.prefetchable and bar.size != 0) bar else null else null;
    if (vram) |bar| if (aperturesOverlap(bar, registers) or aperturesOverlap(bar, doorbells)) return error.InvalidAmdVramAperture;
    return .{ .family = family, .register_bar = registers, .doorbell_bar = doorbells, .vram_bar = vram };
}

fn aperturesOverlap(left: pci.Bar, right: pci.Bar) bool {
    if (left.size == 0 or right.size == 0) return false;
    const left_end = std.math.add(u64, left.address, left.size) catch return true;
    const right_end = std.math.add(u64, right.address, right.size) catch return true;
    return left.address < right_end and right.address < left_end;
}

comptime {
    const registers = pci.Bar{ .address = 0xf0000000, .size = 0x80000, .is_64_bit = false, .prefetchable = false };
    const doorbells = pci.Bar{ .address = 0xf1000000, .size = 0x200000, .is_64_bit = true, .prefetchable = true };
    const vram = pci.Bar{ .address = 0x100000000, .size = 0x40000000, .is_64_bit = true, .prefetchable = true };
    var bars: [6]?pci.Bar = .{null} ** 6;
    bars[0] = vram;
    bars[2] = doorbells;
    const plan = planAmdMemory(bars, registers, .v11_0) catch @compileError("valid AMD memory apertures were rejected");
    if (plan.family != .v11_0 or plan.doorbell_bar.address != doorbells.address or plan.vram_bar == null or plan.vram_bar.?.address != vram.address)
        @compileError("AMD memory apertures were classified incorrectly");
    bars[2] = registers;
    if (planAmdMemory(bars, registers, .v11_0)) |_|
        @compileError("overlapping AMD MMIO apertures were accepted")
    else |err| if (err != error.InvalidAmdMmioApertures)
        @compileError("overlapping AMD MMIO apertures returned the wrong error");
    if (amdGttPte(0x12345000) != 0x12345067) @compileError("AMD GTT system PTE encoded incorrectly");
    var gart_discovery = AmdIpDiscovery{ .binary_version_major = 1, .binary_version_minor = 0, .table_version = 3, .dies = 1, .ips = 2, .base_addresses = 2, .harvested = 0 };
    gart_discovery.critical_count = 2;
    gart_discovery.critical[0] = .{ .hw_id = amd_hw_id.gfx, .base_count = 1, .bases = .{0x200} ++ .{0} ** 7 };
    gart_discovery.critical[1] = .{ .hw_id = amd_hw_id.mmhub, .base_count = 1, .bases = .{0x300} ++ .{0} ** 7 };
    const gart = planAmdGart(&gart_discovery, .{ .family = .v10_0, .register_bar = registers, .doorbell_bar = doorbells, .vram_bar = vram }, .{ .page_table_address = 0x800000, .page_table_pages = 1, .buffer_address = 0x900000, .buffer_pages = 3 }) catch
        @compileError("valid AMD GART plan was rejected");
    if (gart.gfxhub_base != 0x200 or gart.mmhub_base != 0x300 or gart.entries != 512 or gart.window_bytes != 2 * 1024 * 1024 or gart.active)
        @compileError("AMD GART plan was classified incorrectly");
    const mmhub_only = planAmdGart(&gart_discovery, .{ .family = .v11_0, .register_bar = registers, .doorbell_bar = doorbells, .vram_bar = vram }, .{
        .page_table_address = 0x800000,
        .page_table_pages = 1,
        .buffer_address = 0x900000,
        .buffer_pages = 3,
    }) catch @compileError("valid GMC 11 GART plan was rejected");
    if (mmhub_only.gfxhub_base != null) @compileError("GMC 11 incorrectly requires GFXHUB GART");
    const gmc11_registers = resolveAmdGmc11GartRegisters(mmhub_only, 0x4000) catch
        @compileError("valid GMC 11 GART registers were rejected");
    @setEvalBranchQuota(30000);
    if (gmc11_registers.context_control != 0x2900 or gmc11_registers.page_table_base_low != 0x2aac or
        gmc11_registers.invalidate_request != 0x29d0 or gmc11_registers.invalidate_ack != 0x2a18 or
        gmc11_registers.l1_tlb_control != 0x2fcc or gmc11_registers.fb_location_base != 0x2fb0 or
        gmc11_registers.fb_offset != 0x2f5c or gmc11_registers.agp_base != 0x2fc0 or
        gmc11_registers.fault_default_low != 0x283c or gmc11_registers.context1_control != 0x2904 or
        gmc11_registers.invalidate_range_low != 0x2a1c or gmc11_registers.invalidate_range_high != 0x2a20 or
        gmc11_registers.context_control_stride != 4 or gmc11_registers.context_address_stride != 8 or
        gmc11_registers.invalidate_range_stride != 8)
        @compileError("GMC 11 GART registers resolved incorrectly");
    const mutable_registers = amdGmc11GartMutableRegisters(gmc11_registers) catch
        @compileError("GMC 11 mutable register set was rejected");
    if (mutable_registers.count != 141 or mutable_registers.offsets[0] != gmc11_registers.page_table_base_low or
        mutable_registers.offsets[mutable_registers.count - 1] != gmc11_registers.invalidate_range_high + 17 * 8)
        @compileError("GMC 11 mutable register set was enumerated incorrectly");
    if (resolveAmdGmc11GartRegisters(mmhub_only, 0x2fcc)) |_|
        @compileError("out-of-BAR GMC 11 GART registers were accepted")
    else |err| if (err != error.AmdRegistersOutsideBar)
        @compileError("out-of-BAR GMC 11 GART registers returned the wrong error");
    const bound_gart = bindAmdGmc11GartAddressSpace(mmhub_only, 0x1000000, 0x2000000) catch
        @compileError("valid GMC 11 GART address space was rejected");
    if (bound_gart.table_cpu_address != 0x800000 or bound_gart.table_mc_address.? != 0x1000000 or
        bound_gart.window_start.? != 0x2000000 or bound_gart.window_end.? != 0x21fffff or bound_gart.active)
        @compileError("GMC 11 GART address space was bound incorrectly");
    const aperture = prepareAmdGmc11GartAperture(bound_gart) catch
        @compileError("bound GMC 11 GART aperture was rejected");
    if (aperture.page_table_base_low != 0x1000001 or aperture.page_table_base_high != 0 or
        aperture.page_table_start_low != 0x2000 or aperture.page_table_start_high != 0 or
        aperture.page_table_end_low != 0x21ff or aperture.page_table_end_high != 0)
        @compileError("GMC 11 GART aperture values were encoded incorrectly");
    if (bindAmdGmc11GartAddressSpace(mmhub_only, 0x800001, 0x2000000)) |_|
        @compileError("unaligned GMC 11 GART table MC address was accepted")
    else |err| if (err != error.InvalidAmdGartTableMcAddress)
        @compileError("unaligned GMC 11 GART table MC address returned the wrong error");
    const nbio_ip = AmdIp{ .hw_id = amd_hw_id.nbif, .major = 7, .minor = 11, .base_count = 3, .bases = .{ 0, 0, 0x500 } ++ .{0} ** 5 };
    const nbio_registers = resolveAmdGmc11NbioRegisters(&nbio_ip, 0x4000) catch
        @compileError("valid GMC 11 NBIO registers were rejected");
    if (nbio_registers.memsize != 0x170c) @compileError("GMC 11 NBIO memsize register resolved incorrectly");
    const memory_snapshot = decodeAmdGmc11MemorySnapshot(0xab123456, 0x42, 12288) catch
        @compileError("valid GMC 11 memory snapshot was rejected");
    if (memory_snapshot.vram_mc_base != 0x123456000000 or memory_snapshot.vram_mc_offset != 0x42000000 or
        memory_snapshot.vram_bytes != 12 * 1024 * 1024 * 1024)
        @compileError("GMC 11 memory snapshot decoded incorrectly");
    const system_aperture = prepareAmdGmc11SystemAperture(memory_snapshot, .{
        .scratch = .{ .cpu_address = 0x800001000, .mc_address = memory_snapshot.vram_mc_base + 4096, .bytes = 4096 },
        .scratch_physical = memory_snapshot.vram_mc_offset + 4096,
        .dummy_physical = 0x800000,
    }) catch @compileError("valid GMC 11 system aperture was rejected");
    if (system_aperture.agp_base != 0 or system_aperture.agp_bottom != 0x00ffffff or system_aperture.agp_top != 0 or
        system_aperture.aperture_low != @as(u32, @truncate(memory_snapshot.vram_mc_base >> 18)) or
        system_aperture.default_low != 0x42001 or system_aperture.default_high != 0 or
        system_aperture.fault_default_low != 0x800 or system_aperture.fault_default_high != 0)
        @compileError("GMC 11 system aperture values were encoded incorrectly");
    const high_window = planAmdGmc11HighGartWindow(memory_snapshot, 2 * 1024 * 1024) catch
        @compileError("valid GMC 11 high GART window was rejected");
    if (high_window.start != 0x7fff00000000 or high_window.end != 0x7fff001fffff)
        @compileError("GMC 11 high GART window was placed incorrectly");
    const visible_vram = mapAmdGmc11VisibleVram(memory_snapshot, .{ .address = 0x800000000, .size = 256 * 1024 * 1024, .is_64_bit = true, .prefetchable = true }, 0x801000000, 8 * 1024 * 1024) catch
        @compileError("valid GMC 11 visible VRAM mapping was rejected");
    if (visible_vram.bytes != 256 * 1024 * 1024 or visible_vram.mc_start != memory_snapshot.vram_mc_base or
        visible_vram.framebuffer_mc_start != memory_snapshot.vram_mc_base + 16 * 1024 * 1024 or
        visible_vram.framebuffer_mc_end != memory_snapshot.vram_mc_base + 24 * 1024 * 1024 - 1)
        @compileError("GMC 11 visible VRAM mapping was translated incorrectly");
    var vram_allocator = AmdVramAllocator.init(visible_vram) catch @compileError("valid GMC 11 VRAM allocator was rejected");
    if (vram_allocator.allocatePinned(4096, 4096)) |_|
        @compileError("unsealed GMC 11 VRAM allocator accepted an allocation")
    else |err| if (err != error.AmdVramFirmwareMapIncomplete)
        @compileError("unsealed GMC 11 VRAM allocator returned the wrong error");
    reserveAmdGmc11BootVram(&vram_allocator, memory_snapshot, 64 * 1024, false) catch
        @compileError("valid GMC 11 boot VRAM reservations were rejected");
    var found_boot_prefix = false;
    for (vram_allocator.reservations[0..vram_allocator.reservation_count]) |reservation| if (
        reservation.start == memory_snapshot.vram_mc_base and reservation.end == visible_vram.framebuffer_mc_end) {
        found_boot_prefix = true;
    };
    if (vram_allocator.reservation_count != 1 or !found_boot_prefix)
        @compileError("GMC 11 boot VRAM reservations were imported incorrectly");
    vram_allocator.reserve(memory_snapshot.vram_mc_base + 8 * 1024 * 1024, 12 * 1024 * 1024) catch
        @compileError("overlapping GMC 11 firmware reservations were not normalized");
    found_boot_prefix = false;
    for (vram_allocator.reservations[0..vram_allocator.reservation_count]) |reservation| if (
        reservation.start == memory_snapshot.vram_mc_base and reservation.end == visible_vram.framebuffer_mc_end) {
        found_boot_prefix = true;
    };
    if (vram_allocator.reservation_count != 1 or !found_boot_prefix)
        @compileError("GMC 11 firmware reservations were normalized incorrectly");
    const full_memory = AmdGmc11MemorySnapshot{
        .vram_mc_base = 0x100000000,
        .vram_mc_offset = 0,
        .vram_bytes = 256 * 1024 * 1024,
    };
    const full_visible = AmdGmc11VisibleVram{
        .cpu_start = 0x200000000,
        .cpu_end = 0x20fffffff,
        .mc_start = full_memory.vram_mc_base,
        .mc_end = full_memory.vram_mc_base + full_memory.vram_bytes - 1,
        .bytes = full_memory.vram_bytes,
        .framebuffer_mc_start = full_memory.vram_mc_base + 16 * 1024 * 1024,
        .framebuffer_mc_end = full_memory.vram_mc_base + 24 * 1024 * 1024 - 1,
    };
    var full_allocator = AmdVramAllocator.init(full_visible) catch @compileError("full VRAM allocator was rejected");
    reserveAmdGmc11BootVram(&full_allocator, full_memory, 3 * 1024 * 1024, true) catch
        @compileError("firmware and training VRAM reservations were rejected");
    var found_firmware_tail = false;
    var found_training = false;
    for (full_allocator.reservations[0..full_allocator.reservation_count]) |reservation| {
        if (reservation.start == full_memory.vram_mc_base + 253 * 1024 * 1024 and reservation.end == full_visible.mc_end)
            found_firmware_tail = true;
        if (reservation.start == full_memory.vram_mc_base + 252 * 1024 * 1024 and reservation.end == full_memory.vram_mc_base + 252 * 1024 * 1024 + 4095)
            found_training = true;
    }
    if (full_allocator.reservation_count != 3 or !found_firmware_tail or !found_training)
        @compileError("firmware and training VRAM reservations were placed incorrectly");
    vram_allocator.reserve(memory_snapshot.vram_mc_base + 248 * 1024 * 1024, 8 * 1024 * 1024) catch
        @compileError("valid GMC 11 firmware VRAM reservation was rejected");
    vram_allocator.sealFirmwareMap();
    const table_allocation = vram_allocator.allocatePinned(4096, 4096) catch
        @compileError("valid GMC 11 pinned VRAM allocation was rejected");
    if (table_allocation.mc_address != memory_snapshot.vram_mc_base + 248 * 1024 * 1024 - 4096 or
        table_allocation.cpu_address != visible_vram.cpu_start + 248 * 1024 * 1024 - 4096 or table_allocation.bytes != 4096)
        @compileError("GMC 11 pinned VRAM allocation was placed incorrectly");
    const table_physical = amdGmc11VramMcToPhysical(memory_snapshot, table_allocation.mc_address) catch
        @compileError("GMC 11 VRAM MC address was not translated");
    if (table_physical != memory_snapshot.vram_mc_offset + 248 * 1024 * 1024 - 4096)
        @compileError("GMC 11 VRAM MC address translated incorrectly");
    const reservations_before_release = vram_allocator.reservation_count;
    vram_allocator.releasePinned(table_allocation) catch @compileError("GMC 11 pinned VRAM allocation was not released");
    if (vram_allocator.reservation_count + 1 != reservations_before_release)
        @compileError("GMC 11 pinned VRAM allocation release corrupted reservations");
    if (decodeAmdGmc11MemorySnapshot(0xffffffff, 0, 1)) |_|
        @compileError("unavailable GMC 11 memory MMIO was accepted")
    else |err| if (err != error.AmdGmc11MemoryMmioUnavailable)
        @compileError("unavailable GMC 11 memory MMIO returned the wrong error");
}

pub const AmdPspPlan = struct {
    family: PspFamily,
    ip_version: u32,
    autoload_supported: bool,
    boot_time_tmr: bool,
    host_boot_components: bool,
};
pub const AmdPspTopology = enum { unknown, no_cpu_xgmi, cpu_xgmi };
pub const AmdPspBootImages = struct {
    sys: AmdStagedPspComponent,
    sos: AmdStagedPspComponent,
    toc: ?AmdStagedPspComponent,
    kdb: ?AmdStagedPspComponent,
    spl: ?AmdStagedPspComponent,
    rl: ?AmdStagedPspComponent,
    auxiliary: bool,
};
pub const AmdPspBootCommand = enum { load_kdb, load_spl, load_sysdrv, load_sos };
pub const AmdPspCompletion = enum { command_ready, sos_changed };
pub const AmdPspMailboxProfile = struct {
    command_message: u8 = 35,
    address_message: u8 = 36,
    sos_message: u8 = 81,
    ready_mask: u32 = 0x80000000,
    error_mask: u32 = 0,
    supported_commands: u8,

    pub fn supports(self: AmdPspMailboxProfile, command: AmdPspBootCommand) bool {
        return self.supported_commands & (@as(u8, 1) << @intFromEnum(command)) != 0;
    }
};
pub const AmdPspMailboxState = enum { bootloader_busy, bootloader_ready, sos_alive, failed };
pub const AmdPspMailboxSnapshot = struct {
    command: u32,
    sos: u32,
    state: AmdPspMailboxState,
};
pub const AmdPspMailboxSubmission = struct {
    address_message: u8,
    address_value: u32,
    command_message: u8,
    command_value: u32,
    completion_message: u8,
    completion: AmdPspCompletion,
    completion_mask: u32,
};
pub const AmdPspMailboxRegisters = struct {
    command_offset: u32,
    address_offset: u32,
    sos_offset: u32,
};
pub const AmdPspHandoffStep = struct { command: AmdPspBootCommand = .load_sysdrv, source_address: u64 = 0, bytes: u32 = 0 };
pub const AmdPspHandoffState = enum { empty, ready, staged, submitted, finished, failed };
pub const AmdPspPreparedCommand = struct {
    command: AmdPspBootCommand,
    transfer_address: u64,
    transfer_address_1m: u64,
    bytes: u32,
    index: usize,
};
pub const AmdPspTransportStatus = enum { pending, complete, failed };
pub const AmdPspPreflight = enum { blocked_uncached, blocked_unauthorized, mailbox_busy, ready, already_running };
pub const AmdPspTransport = struct {
    context: *anyopaque,
    sosAlive: *const fn (*anyopaque) bool,
    submit: *const fn (*anyopaque, AmdPspPreparedCommand) bool,
    status: *const fn (*anyopaque, AmdPspBootCommand) AmdPspTransportStatus,
};
pub const AmdPspClock = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) u64,
};
pub const AmdPspMailboxObserver = struct {
    context: *anyopaque,
    snapshot: *const fn (*anyopaque) anyerror!AmdPspMailboxSnapshot,
};
pub const AmdPspMmioTransport = struct {
    adapter: *const Adapter,
    profile: AmdPspMailboxProfile,
    registers: AmdPspMailboxRegisters,
    uncached: bool = false,
    authorized: bool = false,
    armed: bool = false,
    active: ?AmdPspBootCommand = null,
    sos_before: u32 = 0,

    pub fn arm(self: *AmdPspMmioTransport, initial: AmdPspMailboxSnapshot) !void {
        if (!self.uncached or !self.authorized or self.armed or self.active != null or initial.state != .bootloader_ready)
            return error.AmdPspTransportNotReady;
        self.armed = true;
        self.sos_before = initial.sos;
    }

    pub fn disarm(self: *AmdPspMmioTransport) void {
        self.armed = false;
        self.active = null;
    }

    pub fn transport(self: *AmdPspMmioTransport) AmdPspTransport {
        return .{ .context = self, .sosAlive = &sosAlive, .submit = &submit, .status = &status };
    }

    pub fn observer(self: *AmdPspMmioTransport) AmdPspMailboxObserver {
        return .{ .context = self, .snapshot = &observeSnapshot };
    }

    fn snapshot(self: *AmdPspMmioTransport) !AmdPspMailboxSnapshot {
        const command = try self.adapter.readRegister(self.registers.command_offset);
        const sos = try self.adapter.readRegister(self.registers.sos_offset);
        return classifyAmdPspMailbox(self.profile, command, sos);
    }

    fn observeSnapshot(context: *anyopaque) !AmdPspMailboxSnapshot {
        const self: *AmdPspMmioTransport = @ptrCast(@alignCast(context));
        return self.snapshot();
    }

    fn sosAlive(context: *anyopaque) bool {
        const self: *AmdPspMmioTransport = @ptrCast(@alignCast(context));
        const observed = self.snapshot() catch return false;
        return observed.state == .sos_alive;
    }

    fn submit(context: *anyopaque, prepared: AmdPspPreparedCommand) bool {
        const self: *AmdPspMmioTransport = @ptrCast(@alignCast(context));
        if (!self.armed or self.active != null) return false;
        const observed = self.snapshot() catch return false;
        if (observed.state != .bootloader_ready) return false;
        const submission = encodeAmdPspMailboxSubmission(self.profile, prepared) catch return false;
        self.adapter.writeRegister(self.registers.address_offset, submission.address_value) catch return false;
        asm volatile ("" ::: .{ .memory = true });
        self.adapter.writeRegister(self.registers.command_offset, submission.command_value) catch return false;
        self.active = prepared.command;
        self.sos_before = observed.sos;
        return true;
    }

    fn status(context: *anyopaque, command: AmdPspBootCommand) AmdPspTransportStatus {
        const self: *AmdPspMmioTransport = @ptrCast(@alignCast(context));
        if (!self.armed or self.active == null or self.active.? != command) return .failed;
        const observed = self.snapshot() catch {
            self.disarm();
            return .failed;
        };
        if (observed.state == .failed) {
            self.disarm();
            return .failed;
        }
        const complete = if (command == .load_sos)
            observed.state == .sos_alive and observed.sos != self.sos_before
        else
            observed.state == .bootloader_ready or observed.state == .sos_alive;
        if (!complete) return .pending;
        self.active = null;
        return .complete;
    }
};
pub const AmdPspHandoff = struct {
    reservation_address: u64 = 0,
    reservation_pages: u64 = 0,
    transfer_address: u64 = 0,
    transfer_pages: u64 = 0,
    count: usize = 0,
    current: usize = 0,
    deadline: u64 = 0,
    state: AmdPspHandoffState = .empty,
    steps: [4]AmdPspHandoffStep = .{AmdPspHandoffStep{}} ** 4,

    pub fn stageNext(self: *AmdPspHandoff) !AmdPspPreparedCommand {
        if (self.state != .ready or self.current >= self.count) return error.InvalidAmdPspHandoffState;
        const step = self.steps[self.current];
        const capacity = self.transfer_pages * 4096;
        if (step.source_address == 0 or step.bytes == 0 or step.bytes > capacity or (self.transfer_address & (1024 * 1024 - 1)) != 0)
            return error.InvalidAmdPspTransfer;
        const source: [*]const u8 = @ptrFromInt(step.source_address);
        const target: [*]u8 = @ptrFromInt(self.transfer_address);
        @memset(target[0..capacity], 0);
        @memcpy(target[0..step.bytes], source[0..step.bytes]);
        asm volatile ("" ::: .{ .memory = true });
        self.state = .staged;
        return .{
            .command = step.command,
            .transfer_address = self.transfer_address,
            .transfer_address_1m = self.transfer_address >> 20,
            .bytes = step.bytes,
            .index = self.current,
        };
    }

    pub fn markSubmitted(self: *AmdPspHandoff, now: u64, timeout: u64) !void {
        if (self.state != .staged or timeout == 0 or now > ~@as(u64, 0) - timeout) return error.InvalidAmdPspHandoffState;
        self.deadline = now + timeout;
        self.state = .submitted;
    }

    pub fn observe(self: *AmdPspHandoff, completed: bool, now: u64) !AmdPspHandoffState {
        if (self.state != .submitted) return error.InvalidAmdPspHandoffState;
        if (completed) {
            self.current += 1;
            self.deadline = 0;
            self.state = if (self.current == self.count) .finished else .ready;
            return self.state;
        }
        if (now >= self.deadline) {
            self.state = .failed;
            return error.AmdPspHandoffTimeout;
        }
        return self.state;
    }

    pub fn fail(self: *AmdPspHandoff) void {
        if (self.state != .empty and self.state != .finished) self.state = .failed;
    }

    pub fn release(self: *AmdPspHandoff, pages: *physical.Allocator) void {
        if (self.reservation_pages != 0) pages.release(self.reservation_address, self.reservation_pages) catch {};
        self.* = .{};
    }
};

pub fn preflightAmdPspHandoff(handoff: *const AmdPspHandoff, transport: *const AmdPspMmioTransport, initial: AmdPspMailboxSnapshot) !AmdPspPreflight {
    if (handoff.state != .ready or handoff.count < 2 or handoff.count > handoff.steps.len or handoff.current != 0 or handoff.deadline != 0 or
        handoff.transfer_pages == 0 or (handoff.transfer_address & (1024 * 1024 - 1)) != 0 or
        handoff.reservation_address == 0 or handoff.reservation_pages == 0 or
        handoff.steps[handoff.count - 2].command != .load_sysdrv or handoff.steps[handoff.count - 1].command != .load_sos or
        handoff.transfer_address >> 20 > ~@as(u32, 0))
        return error.InvalidAmdPspHandoffPreflight;
    const capacity = std.math.mul(u64, handoff.transfer_pages, 4096) catch return error.InvalidAmdPspHandoffPreflight;
    const reservation_bytes = std.math.mul(u64, handoff.reservation_pages, 4096) catch return error.InvalidAmdPspHandoffPreflight;
    const transfer_end = std.math.add(u64, handoff.transfer_address, capacity) catch return error.InvalidAmdPspHandoffPreflight;
    const reservation_end = std.math.add(u64, handoff.reservation_address, reservation_bytes) catch return error.InvalidAmdPspHandoffPreflight;
    if (handoff.transfer_address < handoff.reservation_address or transfer_end > reservation_end)
        return error.InvalidAmdPspHandoffPreflight;
    for (handoff.steps[0..handoff.count]) |step| {
        if (!transport.profile.supports(step.command) or step.source_address == 0 or step.bytes == 0 or step.bytes > capacity)
            return error.InvalidAmdPspHandoffPreflight;
    }
    if (transport.armed or transport.active != null) return error.InvalidAmdPspTransportPreflight;
    if (!transport.uncached) return .blocked_uncached;
    if (!transport.authorized) return .blocked_unauthorized;
    return switch (initial.state) {
        .bootloader_ready => .ready,
        .sos_alive => .already_running,
        .bootloader_busy => .mailbox_busy,
        .failed => error.AmdPspMailboxFailed,
    };
}

pub fn waitAmdPspMailbox(observer: AmdPspMailboxObserver, clock: AmdPspClock, timeout: u64, spin_limit: usize) !AmdPspMailboxSnapshot {
    if (timeout == 0 or spin_limit == 0) return error.InvalidAmdPspExecutionLimit;
    const started = clock.now(clock.context);
    const deadline = std.math.add(u64, started, timeout) catch return error.InvalidAmdPspExecutionLimit;
    var spins: usize = 0;
    while (spins < spin_limit) : (spins += 1) {
        const observed = try observer.snapshot(observer.context);
        switch (observed.state) {
            .bootloader_ready, .sos_alive => return observed,
            .failed => return error.AmdPspMailboxFailed,
            .bootloader_busy => {},
        }
        if (clock.now(clock.context) >= deadline) return error.AmdPspMailboxTimeout;
        asm volatile ("pause");
    }
    return error.AmdPspMailboxSpinLimit;
}

pub fn advanceAmdPspHandoff(handoff: *AmdPspHandoff, transport: AmdPspTransport, now: u64, timeout: u64) !AmdPspHandoffState {
    switch (handoff.state) {
        .empty, .finished, .failed => return handoff.state,
        .ready => {
            if (handoff.current == 0 and transport.sosAlive(transport.context)) {
                handoff.current = handoff.count;
                handoff.state = .finished;
                return handoff.state;
            }
            const prepared = try handoff.stageNext();
            if (!transport.submit(transport.context, prepared)) {
                handoff.fail();
                return error.AmdPspTransportSubmitFailed;
            }
            handoff.markSubmitted(now, timeout) catch |err| {
                handoff.fail();
                return err;
            };
            return handoff.state;
        },
        .submitted => switch (transport.status(transport.context, handoff.steps[handoff.current].command)) {
            .pending => return handoff.observe(false, now),
            .complete => return handoff.observe(true, now),
            .failed => {
                handoff.fail();
                return error.AmdPspTransportFailed;
            },
        },
        .staged => {
            handoff.fail();
            return error.AmdPspTransportNotSubmitted;
        },
    }
}

pub fn runAmdPspHandoff(handoff: *AmdPspHandoff, transport: AmdPspTransport, clock: AmdPspClock, timeout: u64, spin_limit: usize) !AmdPspHandoffState {
    if (timeout == 0 or spin_limit == 0) return error.InvalidAmdPspExecutionLimit;
    var spins: usize = 0;
    while (handoff.state != .finished) : (spins += 1) {
        if (spins == spin_limit) {
            handoff.fail();
            return error.AmdPspHandoffSpinLimit;
        }
        _ = advanceAmdPspHandoff(handoff, transport, clock.now(clock.context), timeout) catch |err| {
            handoff.fail();
            return err;
        };
        if (handoff.state == .failed) return error.AmdPspHandoffFailed;
        asm volatile ("pause");
    }
    return handoff.state;
}
pub const PspFamily = enum { v3_1, v10_0, v11_0, v11_0_8, v12_0, v13_0, v13_0_4, v14_0, v15_0, v15_0_8 };
pub const GmcFamily = enum { v9_0, v10_0, v11_0, v12_0 };
pub const GfxFamily = enum { v9_0, v9_4_3, v10_0, v11_0, v12_0, v12_1 };
pub const SdmaFamily = enum { v4_0, v4_4_2, v5_0, v5_2, v6_0, v7_0, v7_1 };

const psp_sys_sos_commands: u8 = (@as(u8, 1) << @intFromEnum(AmdPspBootCommand.load_sysdrv)) |
    (@as(u8, 1) << @intFromEnum(AmdPspBootCommand.load_sos));
const psp_all_boot_commands: u8 = (@as(u8, 1) << @typeInfo(AmdPspBootCommand).@"enum".fields.len) - 1;

pub fn amdPspMailboxProfile(plan: AmdPspPlan) !AmdPspMailboxProfile {
    if (!plan.host_boot_components) return error.AmdPspHostBootUnsupported;
    // All currently supported host-boot families use the logical MP0
    // C2PMSG 35/36/81 protocol. Actual MMIO offsets still come from the
    // selected MP register map and must not be inferred from these indices.
    return .{
        .error_mask = switch (plan.family) {
            .v11_0 => 0x0000ffff,
            .v13_0 => 0x000000ff,
            else => 0,
        },
        .supported_commands = switch (plan.family) {
            .v3_1, .v12_0 => psp_sys_sos_commands,
            .v11_0, .v13_0, .v13_0_4, .v14_0 => psp_all_boot_commands,
            else => return error.AmdPspHostBootUnsupported,
        },
    };
}

pub fn encodeAmdPspMailboxSubmission(profile: AmdPspMailboxProfile, prepared: AmdPspPreparedCommand) !AmdPspMailboxSubmission {
    if (!profile.supports(prepared.command) or prepared.transfer_address_1m > ~@as(u32, 0))
        return error.UnsupportedAmdPspBootCommand;
    const command_value: u32 = switch (prepared.command) {
        .load_sysdrv => 0x00010000,
        .load_sos => 0x00020000,
        .load_kdb => 0x00080000,
        .load_spl => 0x10000000,
    };
    const sos = prepared.command == .load_sos;
    return .{
        .address_message = profile.address_message,
        .address_value = @intCast(prepared.transfer_address_1m),
        .command_message = profile.command_message,
        .command_value = command_value,
        .completion_message = if (sos) profile.sos_message else profile.command_message,
        .completion = if (sos) .sos_changed else .command_ready,
        .completion_mask = if (sos) 0 else profile.ready_mask,
    };
}

pub fn resolveAmdPspMailboxRegisters(ip: *const AmdIp, profile: AmdPspMailboxProfile, register_bar_bytes: u64) !AmdPspMailboxRegisters {
    if (ip.hw_id != amd_hw_id.psp or ip.instance != 0 or ip.base_count == 0)
        return error.AmdPspRegisterBaseMissing;
    const base = ip.bases[0];
    const command_dword = std.math.add(u64, base, 0x40 + profile.command_message) catch return error.AmdPspRegisterOffsetOverflow;
    const address_dword = std.math.add(u64, base, 0x40 + profile.address_message) catch return error.AmdPspRegisterOffsetOverflow;
    const sos_dword = std.math.add(u64, base, 0x40 + profile.sos_message) catch return error.AmdPspRegisterOffsetOverflow;
    const command_offset = std.math.mul(u64, command_dword, 4) catch return error.AmdPspRegisterOffsetOverflow;
    const address_offset = std.math.mul(u64, address_dword, 4) catch return error.AmdPspRegisterOffsetOverflow;
    const sos_offset = std.math.mul(u64, sos_dword, 4) catch return error.AmdPspRegisterOffsetOverflow;
    if (command_offset > ~@as(u32, 0) or address_offset > ~@as(u32, 0) or sos_offset > ~@as(u32, 0))
        return error.AmdPspRegisterOffsetOverflow;
    if (register_bar_bytes < 4 or command_offset > register_bar_bytes - 4 or
        address_offset > register_bar_bytes - 4 or sos_offset > register_bar_bytes - 4)
        return error.AmdPspRegistersOutsideBar;
    return .{ .command_offset = @intCast(command_offset), .address_offset = @intCast(address_offset), .sos_offset = @intCast(sos_offset) };
}

pub fn classifyAmdPspMailbox(profile: AmdPspMailboxProfile, command: u32, sos: u32) !AmdPspMailboxSnapshot {
    if (command == 0xffffffff or sos == 0xffffffff) return error.AmdPspMmioUnavailable;
    const state: AmdPspMailboxState = if (sos != 0)
        .sos_alive
    else if (command & profile.ready_mask == profile.ready_mask)
        if (command & profile.error_mask != 0) .failed else .bootloader_ready
    else
        .bootloader_busy;
    return .{ .command = command, .sos = sos, .state = state };
}

fn findStagedPspComponent(staging: *const AmdFirmwareStaging, kind: u32) !?AmdStagedPspComponent {
    var result: ?AmdStagedPspComponent = null;
    for (staging.psp_components[0..staging.psp_component_count]) |component| {
        if (component.kind != kind) continue;
        if (result != null) return error.DuplicateStagedAmdPspComponent;
        result = component;
    }
    return result;
}

pub fn selectAmdPspBootImages(staging: *const AmdFirmwareStaging, plan: AmdPspPlan, topology: AmdPspTopology) !AmdPspBootImages {
    const use_auxiliary = if (plan.ip_version == 0x0d0002) switch (topology) {
        .unknown => return error.AmdPspTopologyRequired,
        .no_cpu_xgmi => true,
        .cpu_xgmi => false,
    } else false;
    const sys_kind: u32 = if (use_auxiliary) 13 else 2;
    const sos_kind: u32 = if (use_auxiliary) 14 else 1;
    const sys = try findStagedPspComponent(staging, sys_kind) orelse return error.AmdPspSystemDriverMissing;
    const sos = try findStagedPspComponent(staging, sos_kind) orelse return error.AmdPspSosMissing;
    if (sys.address == 0 or sys.bytes == 0 or sos.address == 0 or sos.bytes == 0) return error.InvalidAmdPspBootImage;
    return .{
        .sys = sys,
        .sos = sos,
        .toc = try findStagedPspComponent(staging, 4),
        .kdb = try findStagedPspComponent(staging, 3),
        .spl = try findStagedPspComponent(staging, 5),
        .rl = try findStagedPspComponent(staging, 6),
        .auxiliary = use_auxiliary,
    };
}

fn appendPspHandoffStep(handoff: *AmdPspHandoff, command: AmdPspBootCommand, image: ?AmdStagedPspComponent) !void {
    const component = image orelse return;
    if (component.address == 0 or component.bytes == 0) return error.InvalidAmdPspBootImage;
    if (handoff.count == handoff.steps.len) return error.TooManyAmdPspHandoffSteps;
    handoff.steps[handoff.count] = .{ .command = command, .source_address = component.address, .bytes = component.bytes };
    handoff.count += 1;
}

pub fn prepareAmdPspHandoff(images: AmdPspBootImages, profile: AmdPspMailboxProfile, pages: *physical.Allocator) !AmdPspHandoff {
    var result = AmdPspHandoff{};
    errdefer result.release(pages);
    if (!profile.supports(.load_sysdrv) or !profile.supports(.load_sos)) return error.AmdPspHostBootUnsupported;
    if (profile.supports(.load_kdb)) try appendPspHandoffStep(&result, .load_kdb, images.kdb);
    if (profile.supports(.load_spl)) try appendPspHandoffStep(&result, .load_spl, images.spl);
    try appendPspHandoffStep(&result, .load_sysdrv, images.sys);
    try appendPspHandoffStep(&result, .load_sos, images.sos);
    if (result.count < 2 or result.steps[result.count - 2].command != .load_sysdrv or result.steps[result.count - 1].command != .load_sos)
        return error.InvalidAmdPspHandoffOrder;
    var maximum_bytes: u64 = 0;
    for (result.steps[0..result.count]) |step| maximum_bytes = @max(maximum_bytes, step.bytes);
    const transfer_pages = (maximum_bytes + 4095) / 4096;
    const alignment_pages: u64 = 256;
    const reservation_pages = transfer_pages + alignment_pages - 1;
    const reservation = pages.allocate(reservation_pages) orelse return error.OutOfMemory;
    const transfer = (reservation + 1024 * 1024 - 1) & ~@as(u64, 1024 * 1024 - 1);
    result.reservation_address = reservation;
    result.reservation_pages = reservation_pages;
    if (transfer < reservation or transfer + transfer_pages * 4096 > reservation + reservation_pages * 4096)
        return error.InvalidAmdPspTransferReservation;
    result.transfer_address = transfer;
    result.transfer_pages = transfer_pages;
    result.state = .ready;
    const target: [*]u8 = @ptrFromInt(transfer);
    @memset(target[0 .. transfer_pages * 4096], 0);
    return result;
}

pub fn validateAmdPspHandoff(pages: *physical.Allocator) !void {
    const MockTransport = struct {
        alive: bool = false,
        accepts: bool = true,
        submissions: usize = 0,
        completion: AmdPspTransportStatus = .pending,
        complete_on_submit: bool = false,
        last: ?AmdPspPreparedCommand = null,

        fn sosAlive(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.alive;
        }
        fn submit(context: *anyopaque, command: AmdPspPreparedCommand) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.submissions += 1;
            self.last = command;
            self.completion = if (self.complete_on_submit) .complete else .pending;
            return self.accepts;
        }
        fn status(context: *anyopaque, command: AmdPspBootCommand) AmdPspTransportStatus {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.last == null or self.last.?.command != command) return .failed;
            return self.completion;
        }
    };
    const MockClock = struct {
        tick: u64 = 0,
        fn now(context: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.tick += 1;
            return self.tick;
        }
    };
    const MockMailbox = struct {
        reads: usize = 0,
        busy_reads: usize = 0,
        terminal: AmdPspMailboxState = .bootloader_ready,
        fn snapshot(context: *anyopaque) !AmdPspMailboxSnapshot {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reads += 1;
            return .{ .command = 0, .sos = 0, .state = if (self.reads <= self.busy_reads) .bootloader_busy else self.terminal };
        }
    };
    const source_address = pages.allocate(1) orelse return error.OutOfMemory;
    defer pages.release(source_address, 1) catch {};
    const source: [*]u8 = @ptrFromInt(source_address);
    for (source[0..256], 0..) |*byte, index| byte.* = @truncate(index ^ 0x5a);
    const images = AmdPspBootImages{
        .sys = .{ .kind = 2, .address = source_address, .bytes = 128 },
        .sos = .{ .kind = 1, .address = source_address + 128, .bytes = 128 },
        .toc = null,
        .kdb = null,
        .spl = null,
        .rl = null,
        .auxiliary = false,
    };
    var handoff = try prepareAmdPspHandoff(images, .{ .supported_commands = psp_all_boot_commands }, pages);
    defer handoff.release(pages);
    var mock = MockTransport{};
    const transport = AmdPspTransport{ .context = &mock, .sosAlive = &MockTransport.sosAlive, .submit = &MockTransport.submit, .status = &MockTransport.status };
    if (try advanceAmdPspHandoff(&handoff, transport, 100, 50) != .submitted) return error.AmdPspHandoffValidationFailed;
    const sys = mock.last orelse return error.AmdPspHandoffValidationFailed;
    if (sys.command != .load_sysdrv or sys.index != 0 or sys.transfer_address_1m != sys.transfer_address >> 20)
        return error.AmdPspHandoffValidationFailed;
    const transfer: [*]const u8 = @ptrFromInt(sys.transfer_address);
    if (!equal(transfer[0..sys.bytes], source[0..sys.bytes])) return error.AmdPspHandoffCopyFailed;
    mock.completion = .complete;
    if (try advanceAmdPspHandoff(&handoff, transport, 120, 50) != .ready) return error.AmdPspHandoffValidationFailed;
    if (try advanceAmdPspHandoff(&handoff, transport, 200, 50) != .submitted) return error.AmdPspHandoffValidationFailed;
    const sos = mock.last orelse return error.AmdPspHandoffValidationFailed;
    if (sos.command != .load_sos or !equal(transfer[0..sos.bytes], source[128 .. 128 + sos.bytes]))
        return error.AmdPspHandoffCopyFailed;
    mock.completion = .complete;
    if (try advanceAmdPspHandoff(&handoff, transport, 220, 50) != .finished or handoff.current != 2 or mock.submissions != 2)
        return error.AmdPspHandoffValidationFailed;
    handoff.current = 0;
    handoff.state = .ready;
    mock.alive = true;
    if (try advanceAmdPspHandoff(&handoff, transport, 300, 50) != .finished or mock.submissions != 2)
        return error.AmdPspHandoffAliveBypassFailed;
    handoff.current = 0;
    handoff.state = .ready;
    mock.alive = false;
    mock.accepts = false;
    if (advanceAmdPspHandoff(&handoff, transport, 400, 50)) |_| return error.AmdPspTransportFailureAccepted else |err| {
        if (err != error.AmdPspTransportSubmitFailed or handoff.state != .failed) return error.AmdPspTransportFailureStateInvalid;
    }
    handoff.current = 0;
    handoff.state = .ready;
    mock.accepts = true;
    mock.complete_on_submit = true;
    var clock = MockClock{};
    if (try runAmdPspHandoff(&handoff, transport, .{ .context = &clock, .now = &MockClock.now }, 10, 20) != .finished)
        return error.AmdPspHandoffRunnerValidationFailed;
    handoff.current = 0;
    handoff.state = .ready;
    mock.complete_on_submit = false;
    clock.tick = 0;
    if (runAmdPspHandoff(&handoff, transport, .{ .context = &clock, .now = &MockClock.now }, 2, 20)) |_| {
        return error.AmdPspHandoffTimeoutAccepted;
    } else |err| if (err != error.AmdPspHandoffTimeout or handoff.state != .failed) {
        return error.AmdPspHandoffRunnerTimeoutInvalid;
    }
    var mailbox = MockMailbox{ .busy_reads = 2 };
    clock.tick = 0;
    const waited = try waitAmdPspMailbox(.{ .context = &mailbox, .snapshot = &MockMailbox.snapshot }, .{
        .context = &clock,
        .now = &MockClock.now,
    }, 10, 20);
    if (waited.state != .bootloader_ready or mailbox.reads != 3) return error.AmdPspMailboxWaitValidationFailed;
    mailbox = .{ .busy_reads = 20 };
    clock.tick = 0;
    if (waitAmdPspMailbox(.{ .context = &mailbox, .snapshot = &MockMailbox.snapshot }, .{
        .context = &clock,
        .now = &MockClock.now,
    }, 2, 20)) |_| {
        return error.AmdPspMailboxTimeoutAccepted;
    } else |err| if (err != error.AmdPspMailboxTimeout) {
        return error.AmdPspMailboxWaitTimeoutInvalid;
    }
    mailbox = .{ .terminal = .failed };
    clock.tick = 0;
    if (waitAmdPspMailbox(.{ .context = &mailbox, .snapshot = &MockMailbox.snapshot }, .{
        .context = &clock,
        .now = &MockClock.now,
    }, 2, 20)) |_| {
        return error.AmdPspMailboxFailureAccepted;
    } else |err| if (err != error.AmdPspMailboxFailed) {
        return error.AmdPspMailboxWaitFailureInvalid;
    }
}

pub fn planAmdBackend(discovery: *const AmdIpDiscovery) !AmdBackendPlan {
    const psp = discovery.find(amd_hw_id.psp, 0) orelse return error.AmdPspMissing;
    const gfx = discovery.find(amd_hw_id.gfx, 0) orelse return error.AmdGfxMissing;
    const mmhub = discovery.find(amd_hw_id.mmhub, 0) orelse return error.AmdMmhubMissing;
    const sdma = discovery.find(amd_hw_id.sdma0, 0) orelse return error.AmdSdmaMissing;
    if (psp.harvest != 0 or gfx.harvest != 0 or mmhub.harvest != 0 or sdma.harvest != 0) return error.RequiredAmdIpHarvested;
    if (psp.base_count == 0) return error.AmdPspRegisterBaseMissing;
    if (mmhub.base_count == 0) return error.AmdMmhubBaseMissing;
    return .{
        .psp = try selectPsp(psp),
        .gmc = try selectGmc(gfx),
        .gfx = try selectGfx(gfx),
        .sdma = try selectSdma(sdma),
    };
}

fn version(ip: *const AmdIp) u32 { return (@as(u32, ip.major) << 16) | (@as(u32, ip.minor) << 8) | ip.revision; }
fn selectPsp(ip: *const AmdIp) !AmdPspPlan {
    const ip_version = version(ip);
    const family: PspFamily = switch (ip_version) {
        0x090000 => .v3_1,
        0x0a0000, 0x0a0001 => .v10_0,
        0x0b0000, 0x0b0002, 0x0b0004, 0x0b0005, 0x0b0007, 0x0b0009, 0x0b000b, 0x0b000c, 0x0b000d, 0x0b0500, 0x0b0502 => .v11_0,
        0x0b0008 => .v11_0_8,
        0x0b0003, 0x0c0001 => .v12_0,
        0x0d0000, 0x0d0001, 0x0d0002, 0x0d0003, 0x0d0005, 0x0d0006, 0x0d0007, 0x0d0008, 0x0d000a, 0x0d000b, 0x0d000c, 0x0d000e, 0x0d000f, 0x0e0000, 0x0e0001, 0x0e0004 => .v13_0,
        0x0d0004 => .v13_0_4,
        0x0e0002, 0x0e0003, 0x0e0005 => .v14_0,
        0x0f0000, 0x0f0005, 0x0f0009 => .v15_0,
        0x0f0008 => .v15_0_8,
        else => return error.UnsupportedAmdPspVersion,
    };
    // Keep these policy bits aligned with amdgpu_psp.c::psp_early_init and
    // each family's psp_funcs table. Autoload support is independent from
    // having bootloader_load_* callbacks for SYS/SOS host boot.
    const autoload_supported = switch (ip_version) {
        0x090000,
        0x0a0000, 0x0a0001,
        0x0b0002, 0x0b0004, 0x0b0008,
        0x0b0003, 0x0c0001,
        0x0d0002, 0x0d0006, 0x0d000c, 0x0d000e, 0x0d000f,
        => false,
        else => true,
    };
    const boot_time_tmr = switch (ip_version) {
        0x0e0002, 0x0e0003, 0x0f0008 => true,
        else => false,
    };
    const host_boot_components = switch (family) {
        .v10_0, .v11_0_8, .v15_0, .v15_0_8 => false,
        else => true,
    };
    return .{
        .family = family,
        .ip_version = ip_version,
        .autoload_supported = autoload_supported,
        .boot_time_tmr = boot_time_tmr,
        .host_boot_components = host_boot_components,
    };
}
fn selectGmc(ip: *const AmdIp) !GmcFamily {
    return switch (version(ip)) {
        0x090000, 0x090001, 0x090100, 0x090201, 0x090202, 0x090300, 0x090400, 0x090401, 0x090402, 0x090403, 0x090404, 0x090500 => .v9_0,
        0x0a0101, 0x0a0102, 0x0a0103, 0x0a0104, 0x0a010a, 0x0a0300, 0x0a0301, 0x0a0302, 0x0a0303, 0x0a0304, 0x0a0305, 0x0a0306, 0x0a0307 => .v10_0,
        0x0b0000, 0x0b0001, 0x0b0002, 0x0b0003, 0x0b0004, 0x0b0500, 0x0b0501, 0x0b0502, 0x0b0503, 0x0b0504, 0x0b0506, 0x0b0700, 0x0b0701 => .v11_0,
        0x0c0000, 0x0c0001, 0x0c0100 => .v12_0,
        else => error.UnsupportedAmdGmcVersion,
    };
}
fn selectGfx(ip: *const AmdIp) !GfxFamily {
    const value = version(ip);
    return switch (value) {
        0x090000, 0x090001, 0x090100, 0x090201, 0x090202, 0x090300, 0x090400, 0x090401, 0x090402 => .v9_0,
        0x090403, 0x090404, 0x090500 => .v9_4_3,
        0x0a0101, 0x0a0102, 0x0a0103, 0x0a0104, 0x0a010a, 0x0a0300, 0x0a0301, 0x0a0302, 0x0a0303, 0x0a0304, 0x0a0305, 0x0a0306, 0x0a0307 => .v10_0,
        0x0b0000, 0x0b0001, 0x0b0002, 0x0b0003, 0x0b0004, 0x0b0500, 0x0b0501, 0x0b0502, 0x0b0503, 0x0b0504, 0x0b0506, 0x0b0700, 0x0b0701 => .v11_0,
        0x0c0000, 0x0c0001 => .v12_0,
        0x0c0100 => .v12_1,
        else => error.UnsupportedAmdGfxVersion,
    };
}
fn selectSdma(ip: *const AmdIp) !SdmaFamily {
    return switch (version(ip)) {
        0x040000, 0x040001, 0x040100, 0x040101, 0x040102, 0x040200, 0x040202, 0x040400 => .v4_0,
        0x040402, 0x040404, 0x040405 => .v4_4_2,
        0x050000, 0x050001, 0x050002, 0x050005 => .v5_0,
        0x050200, 0x050201, 0x050202, 0x050203, 0x050204, 0x050205, 0x050206, 0x050207 => .v5_2,
        0x060000, 0x060001, 0x060002, 0x060003, 0x060100, 0x060101, 0x060102, 0x060103, 0x060104, 0x060400 => .v6_0,
        0x070000, 0x070001 => .v7_0,
        0x070100 => .v7_1,
        else => error.UnsupportedAmdSdmaVersion,
    };
}

comptime {
    var discovery = AmdIpDiscovery{ .binary_version_major = 1, .binary_version_minor = 0, .table_version = 3, .dies = 1, .ips = 4, .base_addresses = 4, .harvested = 0 };
    discovery.critical_count = 4;
    discovery.critical[0] = .{ .hw_id = amd_hw_id.psp, .major = 13, .base_count = 1, .bases = .{0x100} ++ .{0} ** 7 };
    discovery.critical[1] = .{ .hw_id = amd_hw_id.gfx, .major = 11, .base_count = 1 };
    discovery.critical[2] = .{ .hw_id = amd_hw_id.mmhub, .major = 3, .base_count = 1, .bases = .{1} ++ .{0} ** 7 };
    discovery.critical[3] = .{ .hw_id = amd_hw_id.sdma0, .major = 6, .base_count = 1 };
    const plan = planAmdBackend(&discovery) catch @compileError("valid AMD backend combination was rejected");
    if (plan.psp.family != .v13_0 or plan.psp.ip_version != 0x0d0000 or !plan.psp.autoload_supported or plan.psp.boot_time_tmr or !plan.psp.host_boot_components or
        plan.gmc != .v11_0 or plan.gfx != .v11_0 or plan.sdma != .v6_0)
        @compileError("AMD backend combination selected incorrectly");
    const host_boot = selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 13, .revision = 2 }) catch
        @compileError("valid host-boot PSP version was rejected");
    if (host_boot.family != .v13_0 or host_boot.autoload_supported or host_boot.boot_time_tmr or !host_boot.host_boot_components)
        @compileError("AMD PSP host-boot policy selected incorrectly");
    const boot_tmr = selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 14, .revision = 2 }) catch
        @compileError("valid boot-time TMR PSP version was rejected");
    if (!boot_tmr.autoload_supported or !boot_tmr.boot_time_tmr)
        @compileError("AMD PSP boot-time TMR policy selected incorrectly");
    const psp15_tmr = selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 15, .revision = 8 }) catch
        @compileError("valid PSP 15 boot-time TMR version was rejected");
    if (psp15_tmr.family != .v15_0_8 or !psp15_tmr.autoload_supported or !psp15_tmr.boot_time_tmr or psp15_tmr.host_boot_components)
        @compileError("AMD PSP 15 boot-time TMR policy selected incorrectly");
    const platform_booted = selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 10 }) catch
        @compileError("valid platform-booted PSP version was rejected");
    if (platform_booted.family != .v10_0 or platform_booted.host_boot_components)
        @compileError("platform-booted AMD PSP policy selected incorrectly");
    const mailbox = amdPspMailboxProfile(plan.psp) catch @compileError("valid AMD PSP mailbox profile was rejected");
    const mailbox_registers = resolveAmdPspMailboxRegisters(&discovery.critical[0], mailbox, 0x1000) catch
        @compileError("valid AMD PSP mailbox registers were rejected");
    if (mailbox_registers.command_offset != 0x58c or mailbox_registers.address_offset != 0x590 or mailbox_registers.sos_offset != 0x644)
        @compileError("AMD PSP mailbox register offsets resolved incorrectly");
    if (resolveAmdPspMailboxRegisters(&discovery.critical[0], mailbox, 0x600)) |_|
        @compileError("out-of-BAR AMD PSP mailbox registers were accepted")
    else |err| if (err != error.AmdPspRegistersOutsideBar)
        @compileError("out-of-BAR AMD PSP mailbox returned the wrong error");
    var missing_psp_base = discovery.critical[0];
    missing_psp_base.base_count = 0;
    if (resolveAmdPspMailboxRegisters(&missing_psp_base, mailbox, 0x1000)) |_|
        @compileError("missing AMD PSP register base was accepted")
    else |err| if (err != error.AmdPspRegisterBaseMissing)
        @compileError("missing AMD PSP register base returned the wrong error");
    const ready_snapshot = classifyAmdPspMailbox(mailbox, 0x80000000, 0) catch
        @compileError("ready AMD PSP mailbox was rejected");
    const alive_snapshot = classifyAmdPspMailbox(mailbox, 0, 1) catch
        @compileError("alive AMD PSP mailbox was rejected");
    const failed_snapshot = classifyAmdPspMailbox(mailbox, 0x80000001, 0) catch
        @compileError("failed AMD PSP mailbox was rejected");
    if (ready_snapshot.state != .bootloader_ready or alive_snapshot.state != .sos_alive or failed_snapshot.state != .failed)
        @compileError("AMD PSP mailbox state classified incorrectly");
    if (classifyAmdPspMailbox(mailbox, 0xffffffff, 0)) |_|
        @compileError("unavailable AMD PSP MMIO was accepted")
    else |err| if (err != error.AmdPspMmioUnavailable)
        @compileError("unavailable AMD PSP MMIO returned the wrong error");
    const sys_submission = encodeAmdPspMailboxSubmission(mailbox, .{
        .command = .load_sysdrv,
        .transfer_address = 0x400000,
        .transfer_address_1m = 4,
        .bytes = 0x1000,
        .index = 0,
    }) catch @compileError("valid AMD PSP mailbox submission was rejected");
    if (sys_submission.address_message != 36 or sys_submission.address_value != 4 or
        sys_submission.command_message != 35 or sys_submission.command_value != 0x10000 or
        sys_submission.completion != .command_ready or sys_submission.completion_mask != 0x80000000)
        @compileError("AMD PSP SYS mailbox submission encoded incorrectly");
    const sos_submission = encodeAmdPspMailboxSubmission(mailbox, .{
        .command = .load_sos,
        .transfer_address = 0x400000,
        .transfer_address_1m = 4,
        .bytes = 0x1000,
        .index = 1,
    }) catch @compileError("valid AMD PSP SOS mailbox submission was rejected");
    if (sos_submission.command_value != 0x20000 or sos_submission.completion_message != 81 or
        sos_submission.completion != .sos_changed or sos_submission.completion_mask != 0)
        @compileError("AMD PSP SOS mailbox submission encoded incorrectly");
    const limited_mailbox = amdPspMailboxProfile(selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 12, .revision = 1 }) catch
        @compileError("valid PSP 12 profile was rejected")) catch @compileError("valid PSP 12 mailbox was rejected");
    if (limited_mailbox.supports(.load_kdb) or !limited_mailbox.supports(.load_sysdrv))
        @compileError("AMD PSP mailbox capabilities encoded incorrectly");

    var staging = AmdFirmwareStaging{};
    staging.psp_component_count = 4;
    staging.psp_components[0] = .{ .kind = 2, .address = 0x1000, .bytes = 0x100 };
    staging.psp_components[1] = .{ .kind = 1, .address = 0x2000, .bytes = 0x200 };
    staging.psp_components[2] = .{ .kind = 13, .address = 0x3000, .bytes = 0x300 };
    staging.psp_components[3] = .{ .kind = 14, .address = 0x4000, .bytes = 0x400 };
    const normal_images = selectAmdPspBootImages(&staging, plan.psp, .unknown) catch
        @compileError("normal AMD PSP boot images were rejected");
    if (normal_images.auxiliary or normal_images.sys.address != 0x1000 or normal_images.sos.address != 0x2000)
        @compileError("normal AMD PSP boot images selected incorrectly");
    const auxiliary_plan = selectPsp(&AmdIp{ .hw_id = amd_hw_id.psp, .major = 13, .revision = 2 }) catch
        @compileError("valid auxiliary PSP version was rejected");
    const auxiliary_images = selectAmdPspBootImages(&staging, auxiliary_plan, .no_cpu_xgmi) catch
        @compileError("auxiliary AMD PSP boot images were rejected");
    if (!auxiliary_images.auxiliary or auxiliary_images.sys.address != 0x3000 or auxiliary_images.sos.address != 0x4000)
        @compileError("auxiliary AMD PSP boot images selected incorrectly");
    var handoff = AmdPspHandoff{};
    appendPspHandoffStep(&handoff, .load_kdb, AmdStagedPspComponent{ .kind = 3, .address = 0x5000, .bytes = 0x80 }) catch
        @compileError("valid AMD PSP KDB handoff was rejected");
    appendPspHandoffStep(&handoff, .load_spl, null) catch @compileError("optional AMD PSP SPL was rejected");
    appendPspHandoffStep(&handoff, .load_sysdrv, normal_images.sys) catch @compileError("valid AMD PSP SYS handoff was rejected");
    appendPspHandoffStep(&handoff, .load_sos, normal_images.sos) catch @compileError("valid AMD PSP SOS handoff was rejected");
    if (handoff.count != 3 or handoff.steps[0].command != .load_kdb or handoff.steps[1].command != .load_sysdrv or handoff.steps[2].command != .load_sos)
        @compileError("AMD PSP handoff order is incorrect");
    handoff.transfer_address = 0x100000;
    handoff.transfer_pages = 1;
    handoff.reservation_address = 0x100000;
    handoff.reservation_pages = 1;
    handoff.state = .ready;
    var preflight_transport = AmdPspMmioTransport{
        .adapter = undefined,
        .profile = mailbox,
        .registers = undefined,
        .uncached = true,
        .authorized = true,
    };
    if ((preflightAmdPspHandoff(&handoff, &preflight_transport, ready_snapshot) catch
        @compileError("valid AMD PSP preflight was rejected")) != .ready)
        @compileError("ready AMD PSP preflight was classified incorrectly");
    preflight_transport.authorized = false;
    if ((preflightAmdPspHandoff(&handoff, &preflight_transport, ready_snapshot) catch
        @compileError("unauthorized AMD PSP preflight was rejected")) != .blocked_unauthorized)
        @compileError("unauthorized AMD PSP preflight was classified incorrectly");
    preflight_transport.authorized = true;
    if ((preflightAmdPspHandoff(&handoff, &preflight_transport, alive_snapshot) catch
        @compileError("live AMD PSP preflight was rejected")) != .already_running)
        @compileError("live AMD PSP preflight was classified incorrectly");
    handoff.state = .staged;
    handoff.markSubmitted(100, 50) catch @compileError("staged AMD PSP handoff could not be submitted");
    const pending = handoff.observe(false, 149) catch @compileError("pending AMD PSP handoff was rejected");
    if (pending != .submitted or handoff.deadline != 150) @compileError("AMD PSP handoff deadline is incorrect");
    const advanced = handoff.observe(true, 149) catch @compileError("completed AMD PSP handoff was rejected");
    if (advanced != .ready or handoff.current != 1) @compileError("AMD PSP handoff did not advance correctly");
    var timed_out = AmdPspHandoff{ .state = .staged };
    timed_out.markSubmitted(5, 5) catch @compileError("AMD PSP timeout sample could not be submitted");
    if (timed_out.observe(false, 10)) |_| @compileError("expired AMD PSP handoff was accepted") else |err| {
        if (err != error.AmdPspHandoffTimeout or timed_out.state != .failed) @compileError("AMD PSP timeout state is incorrect");
    }
}

pub fn parseAmdIpDiscovery(bytes: []const u8) !AmdIpDiscovery {
    const binary_signature: u32 = 0x28211407;
    const table_signature: u32 = 0x53445049;
    if (bytes.len < 12 or readLittle32(bytes, 0) != binary_signature) return error.InvalidAmdIpDiscoverySignature;
    const binary_major = readLittle16(bytes, 4);
    const binary_minor = readLittle16(bytes, 6);
    const binary_checksum = readLittle16(bytes, 8);
    const binary_size: usize = readLittle16(bytes, 10);
    if (binary_size < 12 or binary_size > bytes.len) return error.InvalidAmdIpDiscoverySize;
    var table_count: usize = 6;
    var table_list: usize = 12;
    if (binary_major == 2) {
        if (binary_size < 16) return error.InvalidAmdIpDiscoveryHeader;
        table_count = readLittle16(bytes, 12);
        table_list = 16;
    } else if (binary_major > 1) return error.UnsupportedAmdIpDiscoveryVersion;
    if (table_count == 0 or table_count > 16 or table_list + @as(usize, table_count) * 8 > binary_size) return error.InvalidAmdIpDiscoveryTableList;
    if (byteSum(bytes[10..binary_size]) != binary_checksum) return error.InvalidAmdIpDiscoveryChecksum;
    const table_offset: usize = readLittle16(bytes, table_list);
    const table_checksum = readLittle16(bytes, table_list + 2);
    if (table_offset > binary_size or binary_size - table_offset < 80) return error.InvalidAmdIpDiscoveryTableOffset;
    if (readLittle32(bytes, table_offset) != table_signature) return error.InvalidAmdIpDiscoveryTableSignature;
    const table_version = readLittle16(bytes, table_offset + 4);
    const table_size: usize = readLittle16(bytes, table_offset + 6);
    if (table_version == 0 or table_version > 4 or table_size < 80 or table_size > binary_size - table_offset) return error.InvalidAmdIpDiscoveryTableSize;
    if (byteSum(bytes[table_offset .. table_offset + table_size]) != table_checksum) return error.InvalidAmdIpDiscoveryTableChecksum;
    const dies = readLittle16(bytes, table_offset + 12);
    if (dies == 0 or dies > 16) return error.InvalidAmdIpDiscoveryDieCount;
    const address_bytes: usize = if (table_version == 4 and (bytes[table_offset + 78] & 1) != 0) 8 else 4;
    var result = AmdIpDiscovery{ .binary_version_major = binary_major, .binary_version_minor = binary_minor, .table_version = table_version, .dies = dies, .ips = 0, .base_addresses = 0, .harvested = 0 };
    var die_index: u16 = 0;
    while (die_index < dies) : (die_index += 1) {
        const die_info = table_offset + 14 + @as(usize, die_index) * 4;
        const die_offset: usize = readLittle16(bytes, die_info + 2);
        if (die_offset < table_offset or die_offset > table_offset + table_size or table_offset + table_size - die_offset < 4) return error.InvalidAmdIpDiscoveryDieOffset;
        const ip_count = readLittle16(bytes, die_offset + 2);
        var ip_offset: usize = die_offset + 4;
        var ip_index: u16 = 0;
        while (ip_index < ip_count) : (ip_index += 1) {
            if (ip_offset > table_offset + table_size or table_offset + table_size - ip_offset < 8) return error.TruncatedAmdIpDiscoveryEntry;
            const bases = bytes[ip_offset + 3];
            const entry_size = 8 + @as(usize, bases) * address_bytes;
            if (entry_size > table_offset + table_size - ip_offset) return error.TruncatedAmdIpDiscoveryBaseAddresses;
            result.ips += 1;
            result.base_addresses += bases;
            if (table_version <= 2 and (bytes[ip_offset + 7] & 0xf) != 0) result.harvested += 1;
            const hw_id = readLittle16(bytes, ip_offset);
            if (isCriticalAmdIp(hw_id)) {
                if (result.critical_count == result.critical.len) return error.TooManyCriticalAmdIps;
                if (bases > 8) return error.TooManyCriticalAmdIpBaseAddresses;
                const instance = bytes[ip_offset + 2];
                for (result.critical[0..result.critical_count]) |ip| if (ip.hw_id == hw_id and ip.instance == instance) return error.DuplicateCriticalAmdIp;
                var ip = AmdIp{
                    .hw_id = hw_id,
                    .instance = instance,
                    .major = bytes[ip_offset + 4],
                    .minor = bytes[ip_offset + 5],
                    .revision = bytes[ip_offset + 6],
                    .sub_revision = if (table_version >= 3) bytes[ip_offset + 7] & 0xf else 0,
                    .variant = if (table_version >= 3) bytes[ip_offset + 7] >> 4 else 0,
                    .harvest = if (table_version <= 2) bytes[ip_offset + 7] & 0xf else 0,
                    .base_count = bases,
                };
                var base_index: u8 = 0;
                while (base_index < bases) : (base_index += 1) {
                    const base_offset = ip_offset + 8 + @as(usize, base_index) * address_bytes;
                    ip.bases[base_index] = if (address_bytes == 8) readLittle64(bytes, base_offset) else readLittle32(bytes, base_offset);
                }
                result.critical[result.critical_count] = ip;
                result.critical_count += 1;
            }
            ip_offset += entry_size;
        }
    }
    return result;
}

fn isCriticalAmdIp(hw_id: u16) bool {
    return hw_id == amd_hw_id.smu or hw_id == amd_hw_id.gfx or hw_id == amd_hw_id.mmhub or
        (hw_id >= amd_hw_id.sdma0 and hw_id <= amd_hw_id.sdma3) or hw_id == amd_hw_id.nbif or hw_id == amd_hw_id.psp;
}

fn byteSum(bytes: []const u8) u16 {
    var sum: u16 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

fn writeLittle16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}
fn writeLittle32(bytes: []u8, offset: usize, value: u32) void {
    writeLittle16(bytes, offset, @truncate(value));
    writeLittle16(bytes, offset + 2, @truncate(value >> 16));
}

fn readLittle64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readLittle32(bytes, offset)) | (@as(u64, readLittle32(bytes, offset + 4)) << 32);
}

comptime {
    var sample = [_]u8{0} ** 156;
    writeLittle32(&sample, 0, 0x28211407);
    writeLittle16(&sample, 4, 1);
    writeLittle16(&sample, 10, sample.len);
    writeLittle16(&sample, 12, 60);
    writeLittle16(&sample, 16, 96);
    writeLittle32(&sample, 60, 0x53445049);
    writeLittle16(&sample, 64, 3);
    writeLittle16(&sample, 66, 96);
    writeLittle16(&sample, 72, 1);
    writeLittle16(&sample, 76, 140);
    writeLittle16(&sample, 142, 1);
    writeLittle16(&sample, 144, amd_hw_id.sdma0);
    sample[147] = 1;
    sample[148] = 11;
    writeLittle32(&sample, 152, 0x1234);
    writeLittle16(&sample, 14, byteSum(sample[60..156]));
    writeLittle16(&sample, 8, byteSum(sample[10..156]));
    const discovery = parseAmdIpDiscovery(&sample) catch @compileError("AMDGPU IP discovery sample was rejected");
    const sdma = discovery.find(amd_hw_id.sdma0, 0);
    if (discovery.table_version != 3 or discovery.dies != 1 or discovery.ips != 1 or discovery.base_addresses != 1 or sdma == null or sdma.?.major != 11 or sdma.?.bases[0] != 0x1234)
        @compileError("AMDGPU IP discovery sample decoded incorrectly");
}

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

pub const AmdAtomVramUsage = struct {
    format_revision: u8,
    content_revision: u8,
    firmware_start_kib: u32,
    firmware_kib: u32,
    driver_start_kib: ?u32,
    driver_kib: u32,
};

pub const AmdAtomFirmwareInfo = struct {
    format_revision: u8,
    content_revision: u8,
    capability: u32,
    reserved_kib: u32,
};

const AmdAtomTables = struct { image: []const u8, master: []const u8 };

// ATOM offsets are relative to the beginning of the PCI ROM image. Keep this
// parser independent of PCI/MMIO so an untrusted VBIOS can be checked before
// any reservation is added to the VRAM allocator.
pub fn parseAmdAtomVramUsage(bytes: []const u8) !AmdAtomVramUsage {
    const tables = try amdAtomTables(bytes);
    const usage_offset = @as(usize, readLittle16(tables.master, 26));
    if (usage_offset == 0) return error.AtomVramUsageMissing;
    const usage = try atomTable(tables.image, usage_offset, 12);
    const format = usage[2];
    const content = usage[3];
    if (format == 2 and content == 1) return .{
        .format_revision = format,
        .content_revision = content,
        .firmware_start_kib = @intCast(readLittle32(usage, 4)),
        .firmware_kib = readLittle16(usage, 8),
        .driver_start_kib = null,
        .driver_kib = readLittle16(usage, 10),
    };
    if (format >= 2 and content >= 2) {
        if (usage.len < 20) return error.TruncatedAtomTable;
        return .{
            .format_revision = format,
            .content_revision = content,
            .firmware_start_kib = @intCast(readLittle32(usage, 4)),
            .firmware_kib = readLittle16(usage, 8),
            .driver_start_kib = @intCast(readLittle32(usage, 12)),
            .driver_kib = @intCast(readLittle32(usage, 16)),
        };
    }
    return error.UnsupportedAtomVramUsage;
}

pub fn parseAmdAtomFirmwareInfo(bytes: []const u8) !AmdAtomFirmwareInfo {
    const tables = try amdAtomTables(bytes);
    const firmware_offset = @as(usize, readLittle16(tables.master, 12));
    if (firmware_offset == 0) return error.AtomFirmwareInfoMissing;
    const firmware = try atomTable(tables.image, firmware_offset, 20);
    const format = firmware[2];
    const content = firmware[3];
    if (format != 3 or (content != 4 and content != 5)) return error.UnsupportedAtomFirmwareInfo;
    if (firmware.len < 88) return error.TruncatedAtomTable;
    return .{
        .format_revision = format,
        .content_revision = content,
        .capability = @intCast(readLittle32(firmware, 16)),
        .reserved_kib = @intCast(readLittle32(firmware, 84)),
    };
}

fn amdAtomTables(bytes: []const u8) !AmdAtomTables {
    if (bytes.len < 0x4a or bytes[0] != 0x55 or bytes[1] != 0xaa) return error.InvalidPciRom;
    const image_bytes = @as(usize, bytes[2]) * 512;
    if (image_bytes == 0 or image_bytes > bytes.len) return error.TruncatedPciRom;
    const image = bytes[0..image_bytes];

    const rom_header = @as(usize, readLittle16(image, 0x48));
    const rom = try atomTable(image, rom_header, 34);
    if (!equal(rom[4..8], "ATOM")) return error.NotAtomBios;

    const master_offset = @as(usize, readLittle16(rom, 32));
    const master = try atomTable(image, master_offset, 28);
    return .{ .image = image, .master = master };
}

fn atomTable(image: []const u8, offset: usize, minimum_bytes: usize) ![]const u8 {
    if (offset > image.len or image.len - offset < 4) return error.TruncatedAtomTable;
    const table_bytes = @as(usize, readLittle16(image, offset));
    if (table_bytes < minimum_bytes or table_bytes > image.len - offset) return error.TruncatedAtomTable;
    return image[offset .. offset + table_bytes];
}

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
    var atom = [_]u8{0} ** 512;
    atom[0] = 0x55;
    atom[1] = 0xaa;
    atom[2] = 1;
    writeLittle16(&atom, 0x48, 0x80);
    writeLittle16(&atom, 0x80, 38);
    atom[0x82] = 2;
    atom[0x83] = 2;
    @memcpy(atom[0x84..0x88], "ATOM");
    writeLittle16(&atom, 0xa0, 0xc0);
    writeLittle16(&atom, 0xc0, 74);
    atom[0xc2] = 2;
    atom[0xc3] = 1;
    writeLittle16(&atom, 0xda, 0x120);
    writeLittle16(&atom, 0xcc, 0x160);
    writeLittle16(&atom, 0x120, 12);
    atom[0x122] = 2;
    atom[0x123] = 1;
    writeLittle32(&atom, 0x124, 0x12340);
    writeLittle16(&atom, 0x128, 64);
    writeLittle16(&atom, 0x12a, 20);
    writeLittle16(&atom, 0x160, 88);
    atom[0x162] = 3;
    atom[0x163] = 4;
    writeLittle32(&atom, 0x170, 0x401);
    writeLittle32(&atom, 0x1b4, 3072);
    const usage = parseAmdAtomVramUsage(&atom) catch @compileError("ATOM VRAM usage sample was rejected");
    if (usage.format_revision != 2 or usage.content_revision != 1 or usage.firmware_start_kib != 0x12340 or
        usage.firmware_kib != 64 or usage.driver_start_kib != null or usage.driver_kib != 20)
        @compileError("ATOM VRAM usage sample decoded incorrectly");
    const firmware = parseAmdAtomFirmwareInfo(&atom) catch @compileError("ATOM firmware info sample was rejected");
    if (firmware.format_revision != 3 or firmware.content_revision != 4 or firmware.capability != 0x401 or firmware.reserved_kib != 3072)
        @compileError("ATOM firmware info sample decoded incorrectly");
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

    var psp_sample = [_]u8{0} ** 104;
    writeLittle32(&psp_sample, 0, psp_sample.len);
    writeLittle32(&psp_sample, 4, 68);
    writeLittle16(&psp_sample, 8, 2);
    writeLittle16(&psp_sample, 10, 0);
    writeLittle32(&psp_sample, 20, 36);
    writeLittle32(&psp_sample, 24, 68);
    writeLittle32(&psp_sample, 32, 2);
    writeLittle32(&psp_sample, 36, 1);
    writeLittle32(&psp_sample, 40, 0x10203);
    writeLittle32(&psp_sample, 44, 0);
    writeLittle32(&psp_sample, 48, 16);
    writeLittle32(&psp_sample, 52, 2);
    writeLittle32(&psp_sample, 56, 0x40506);
    writeLittle32(&psp_sample, 60, 16);
    writeLittle32(&psp_sample, 64, 20);
    const psp = parseAmdPspFirmware(&psp_sample) catch @compileError("AMDGPU PSP v2 package was rejected");
    if (psp.count != 2 or psp.components[0].kind != 1 or psp.components[0].version != 0x10203 or
        psp.components[0].offset != 68 or psp.components[1].kind != 2 or psp.components[1].bytes != 20)
        @compileError("AMDGPU PSP component table decoded incorrectly");
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
