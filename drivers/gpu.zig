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
        return .{ .prefix = mapping.prefix, .entries = count, .required_blocks = mapping.required_blocks };
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

pub const Selection = struct { prefix: []const u8, entries: usize, required_blocks: u16 };
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
    areas: [128]AmdFirmwareArea = .{AmdFirmwareArea{}} ** 128,

    pub fn release(self: *AmdFirmwareStaging, pages: *physical.Allocator) void {
        while (self.count != 0) {
            self.count -= 1;
            const area = self.areas[self.count];
            pages.release(area.address, area.pages) catch {};
            self.areas[self.count] = .{};
        }
        self.image_bytes = 0;
        self.payload_bytes = 0;
    }
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
const Mapping = struct { vendor: u16, device: u16, revision: ?u8, subsystem_vendor: ?u16, subsystem_device: ?u16, prefix: []const u8, required_blocks: u16 };

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
            return .{
                .vendor = try readHexValue(pci_identity[0..4]),
                .device = try readHexValue(pci_identity[5..9]),
                .revision = if (pci_identity.len == 12) @intCast(try readHexValue(pci_identity[10..12])) else null,
                .subsystem_vendor = if (subsystem) |value| try readHexValue(value[0..4]) else null,
                .subsystem_device = if (subsystem) |value| try readHexValue(value[5..9]) else null,
                .prefix = prefix,
                .required_blocks = if (requirements) |value| try parseRequiredBlocks(value) else 0,
            };
        }
        return null;
    }
};

comptime {
    var mappings = ManifestIterator{ .manifest = "1002:744c:cc@1da2:e471=amdgpu/navi31/|security,graphics,dma\n10de:2684=nouveau/ad102/\n" };
    const amd = mappings.next() catch @compileError("GPU subsystem firmware mapping was rejected");
    if (amd == null or amd.?.revision != 0xcc or amd.?.subsystem_vendor != 0x1da2 or amd.?.subsystem_device != 0xe471 or amd.?.required_blocks != 0x19)
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

fn parseRequiredBlocks(value: []const u8) !u16 {
    var mask: u16 = 0;
    var offset: usize = 0;
    while (offset < value.len) {
        var end = offset;
        while (end < value.len and value[end] != ',') : (end += 1) {}
        const name = value[offset..end];
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
        if ((mask & bit) != 0) return error.DuplicateFirmwareRequirement;
        mask |= bit;
        if (end < value.len and end + 1 == value.len) return error.InvalidFirmwareRequirement;
        offset = if (end < value.len) end + 1 else end;
    }
    return mask;
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

pub const AmdBackendPlan = struct { psp: PspFamily, gmc: GmcFamily, gfx: GfxFamily, sdma: SdmaFamily };
pub const PspFamily = enum { v3_1, v10_0, v11_0, v11_0_8, v12_0, v13_0, v13_0_4, v14_0, v15_0, v15_0_8 };
pub const GmcFamily = enum { v9_0, v10_0, v11_0, v12_0 };
pub const GfxFamily = enum { v9_0, v9_4_3, v10_0, v11_0, v12_0, v12_1 };
pub const SdmaFamily = enum { v4_0, v4_4_2, v5_0, v5_2, v6_0, v7_0, v7_1 };

pub fn planAmdBackend(discovery: *const AmdIpDiscovery) !AmdBackendPlan {
    const psp = discovery.find(amd_hw_id.psp, 0) orelse return error.AmdPspMissing;
    const gfx = discovery.find(amd_hw_id.gfx, 0) orelse return error.AmdGfxMissing;
    const mmhub = discovery.find(amd_hw_id.mmhub, 0) orelse return error.AmdMmhubMissing;
    const sdma = discovery.find(amd_hw_id.sdma0, 0) orelse return error.AmdSdmaMissing;
    if (psp.harvest != 0 or gfx.harvest != 0 or mmhub.harvest != 0 or sdma.harvest != 0) return error.RequiredAmdIpHarvested;
    if (mmhub.base_count == 0) return error.AmdMmhubBaseMissing;
    return .{
        .psp = try selectPsp(psp),
        .gmc = try selectGmc(gfx),
        .gfx = try selectGfx(gfx),
        .sdma = try selectSdma(sdma),
    };
}

fn version(ip: *const AmdIp) u32 { return (@as(u32, ip.major) << 16) | (@as(u32, ip.minor) << 8) | ip.revision; }
fn selectPsp(ip: *const AmdIp) !PspFamily {
    return switch (version(ip)) {
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
        else => error.UnsupportedAmdPspVersion,
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
    discovery.critical[0] = .{ .hw_id = amd_hw_id.psp, .major = 13, .base_count = 1 };
    discovery.critical[1] = .{ .hw_id = amd_hw_id.gfx, .major = 11, .base_count = 1 };
    discovery.critical[2] = .{ .hw_id = amd_hw_id.mmhub, .major = 3, .base_count = 1, .bases = .{1} ++ .{0} ** 7 };
    discovery.critical[3] = .{ .hw_id = amd_hw_id.sdma0, .major = 6, .base_count = 1 };
    const plan = planAmdBackend(&discovery) catch @compileError("valid AMD backend combination was rejected");
    if (plan.psp != .v13_0 or plan.gmc != .v11_0 or plan.gfx != .v11_0 or plan.sdma != .v6_0)
        @compileError("AMD backend combination selected incorrectly");
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
