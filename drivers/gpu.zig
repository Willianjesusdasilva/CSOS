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
        const register: *align(1) const volatile u32 = @ptrFromInt(bar.address + offset);
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

    pub fn amdGfxFirmwareManifest(self: Firmware, selection: Selection, family: GfxFamily) !AmdGfxFirmwareManifest {
        var result = AmdGfxFirmwareManifest{ .family = family };
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            const role = classifyAmdGfxFirmware(entry.name) orelse continue;
            try result.add(role, entry.data);
        }
        try result.validate();
        return result;
    }

    pub fn amdMesFirmwareSet(self: Firmware, selection: Selection) !AmdMesFirmwareSet {
        var scheduler_v2: ?AmdMesFirmware = null;
        var scheduler_fallback: ?AmdMesFirmware = null;
        var kiq: ?AmdMesFirmware = null;
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            if (endsWith(entry.name, "_mes_2.bin")) {
                if (scheduler_v2 != null) return error.DuplicateAmdMesSchedulerFirmware;
                scheduler_v2 = try parseAmdMesFirmware(entry.data);
            } else if (endsWith(entry.name, "_mes.bin")) {
                if (scheduler_fallback != null) return error.DuplicateAmdMesSchedulerFirmware;
                scheduler_fallback = try parseAmdMesFirmware(entry.data);
            } else if (endsWith(entry.name, "_mes1.bin")) {
                if (kiq != null) return error.DuplicateAmdMesKiqFirmware;
                kiq = try parseAmdMesFirmware(entry.data);
            }
        }
        const scheduler = scheduler_v2 orelse scheduler_fallback orelse return error.AmdMesSchedulerFirmwareMissing;
        const selected_kiq = kiq orelse return error.AmdMesKiqFirmwareMissing;
        if (scheduler.ip_version_major != 11 or selected_kiq.ip_version_major != 11)
            return error.AmdMesFirmwareIpMismatch;
        return .{ .scheduler = scheduler, .kiq = selected_kiq, .scheduler_v2 = scheduler_v2 != null };
    }

    pub fn amdGfx11CpFirmwareSet(self: Firmware, selection: Selection) !AmdGfx11CpFirmwareSet {
        var result = AmdGfx11CpFirmwareSet{};
        var iterator = self.selected(selection);
        while (try iterator.next()) |entry| {
            const role = classifyAmdGfxFirmware(entry.name) orelse continue;
            switch (role) {
                .pfp => {
                    if (result.pfp != null) return error.DuplicateAmdCpFirmware;
                    result.pfp = try parseAmdCpFirmware(entry.data, .pfp);
                },
                .me => {
                    if (result.me != null) return error.DuplicateAmdCpFirmware;
                    result.me = try parseAmdCpFirmware(entry.data, .me);
                },
                .mec => {
                    if (result.mec != null) return error.DuplicateAmdCpFirmware;
                    result.mec = try parseAmdCpFirmware(entry.data, .mec);
                },
                .rlc => {
                    if (result.rlc != null) return error.DuplicateAmdRlcFirmware;
                    result.rlc = try parseAmdRlcFirmware(entry.data);
                },
                else => {},
            }
        }
        try result.validate();
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
        const backend = switch (driver) {
            .amdgpu => "amdgpu/",
            .nouveau => "nouveau/",
            else => return null,
        };
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

    pub fn block(self: *const FirmwareInventory, kind: FirmwareBlock) FirmwareBlockSummary {
        return self.blocks[@intFromEnum(kind)];
    }
};
pub const AmdGfxFirmwareRole = enum { pfp, me, mec, rlc, mes_scheduler, mes_kiq };
pub const AmdMesFirmware = struct {
    ip_version_major: u16,
    ip_version_minor: u16,
    ucode_version: u32,
    data_version: u32,
    ucode: []const u8,
    data: []const u8,
    ucode_start: u64,
    data_start: u64,
};
pub const AmdMesFirmwareSet = struct { scheduler: AmdMesFirmware, kiq: AmdMesFirmware, scheduler_v2: bool };
pub const AmdCpFirmwareKind = enum { pfp, me, mec };
pub const AmdCpFirmwareFormat = enum { legacy, rs64 };
pub const AmdCpFirmware = struct {
    kind: AmdCpFirmwareKind,
    format: AmdCpFirmwareFormat,
    ucode_version: u32,
    feature_version: u32,
    instruction: []const u8,
    data: []const u8 = &.{},
    jump_table: []const u8 = &.{},
    start_address: u64 = 0,
};
pub const AmdRlcFirmwarePayload = struct { kind: AmdPspGfxFirmwareType = .rlc_g, data: []const u8 = &.{} };
pub const AmdRlcFirmware = struct {
    ucode_version: u32,
    feature_version: u32,
    header_minor: u16,
    count: usize = 0,
    payloads: [11]AmdRlcFirmwarePayload = .{AmdRlcFirmwarePayload{}} ** 11,
};
pub const AmdGfx11CpFirmwareSet = struct {
    pfp: ?AmdCpFirmware = null,
    me: ?AmdCpFirmware = null,
    mec: ?AmdCpFirmware = null,
    rlc: ?AmdRlcFirmware = null,

    pub fn validate(self: *const AmdGfx11CpFirmwareSet) !void {
        const pfp = self.pfp orelse return error.RequiredAmdCpFirmwareMissing;
        const me = self.me orelse return error.RequiredAmdCpFirmwareMissing;
        const mec = self.mec orelse return error.RequiredAmdCpFirmwareMissing;
        _ = self.rlc orelse return error.RequiredAmdRlcFirmwareMissing;
        if (pfp.format != me.format or pfp.format != mec.format) return error.MixedAmdCpFirmwareFormats;
        if (pfp.format == .rs64 and (pfp.data.len == 0 or me.data.len == 0 or mec.data.len == 0))
            return error.AmdCpRs64StackMissing;
        if (pfp.format == .legacy and mec.jump_table.len == 0) return error.AmdCpMecJumpTableMissing;
    }
};
pub const AmdPspGfxFirmwareType = enum(u32) {
    cp_me = 1,
    cp_pfp = 2,
    cp_mec = 4,
    cp_mec_me1 = 5,
    rlc_g = 8,
    rlc_v = 7,
    rlc_restore_gpm = 20,
    rlc_restore_srm = 21,
    rlc_restore_cntl = 22,
    rlc_p = 25,
    rlc_iram = 26,
    global_tap_delays = 27,
    se0_tap_delays = 28,
    se1_tap_delays = 29,
    rlc_dram_boot = 48,
    se2_tap_delays = 65,
    se3_tap_delays = 66,
    rs64_pfp = 87,
    rs64_me = 88,
    rs64_mec = 89,
    rs64_pfp_p0_stack = 90,
    rs64_pfp_p1_stack = 91,
    rs64_me_p0_stack = 92,
    rs64_me_p1_stack = 93,
    rs64_mec_p0_stack = 94,
    rs64_mec_p1_stack = 95,
    rs64_mec_p2_stack = 96,
    rs64_mec_p3_stack = 97,
    rlc_iram_core1 = 98,
    rlc_dram_boot_core1 = 99,
};
pub const AmdPspIpFirmwareArea = struct { kind: AmdPspGfxFirmwareType = .cp_me, address: u64 = 0, pages: u64 = 0, bytes: u32 = 0 };
pub const AmdPspIpFirmwarePayload = struct { kind: AmdPspGfxFirmwareType = .cp_me, data: []const u8 = &.{} };
pub const AmdGfx11CpFirmwarePlan = struct {
    count: usize = 0,
    payloads: [22]AmdPspIpFirmwarePayload = .{AmdPspIpFirmwarePayload{}} ** 22,
};
pub const AmdGfx11CpFirmwareStaging = struct {
    count: usize = 0,
    areas: [22]AmdPspIpFirmwareArea = .{AmdPspIpFirmwareArea{}} ** 22,

    pub fn release(self: *AmdGfx11CpFirmwareStaging, pages: *physical.Allocator) void {
        var index = self.count;
        while (index != 0) {
            index -= 1;
            const area = self.areas[index];
            if (area.pages != 0) pages.release(area.address, area.pages) catch {};
        }
        self.* = .{};
    }
};
pub const AmdPspIpFirmwareGpuArea = struct { kind: AmdPspGfxFirmwareType = .cp_me, address: u64 = 0, bytes: u32 = 0 };
pub const AmdGfx11CpFirmwareGpuLayout = struct {
    count: usize = 0,
    first_gart_page: u16 = 0,
    gart_pages: u16 = 0,
    areas: [22]AmdPspIpFirmwareGpuArea = .{AmdPspIpFirmwareGpuArea{}} ** 22,
};
pub const AmdMesPayloadArea = struct { address: u64 = 0, pages: u64 = 0, bytes: usize = 0 };
pub const AmdMesStagedImage = struct { ucode: AmdMesPayloadArea = .{}, data: AmdMesPayloadArea = .{} };
pub const AmdMesFirmwareStaging = struct {
    scheduler: AmdMesStagedImage = .{},
    kiq: AmdMesStagedImage = .{},

    pub fn release(self: *AmdMesFirmwareStaging, pages: *physical.Allocator) void {
        inline for (.{ "kiq", "scheduler" }) |image_field| {
            inline for (.{ "data", "ucode" }) |area_field| {
                const area = @field(@field(self, image_field), area_field);
                if (area.pages != 0) pages.release(area.address, area.pages) catch {};
            }
        }
        self.* = .{};
    }
};

fn stageAmdMesPayload(payload: []const u8, pages: *physical.Allocator) !AmdMesPayloadArea {
    const page_count: u64 = @intCast((payload.len + 4095) / 4096);
    const address = pages.allocate(page_count) orelse return error.OutOfMemory;
    if (address >= (@as(u64, 1) << 44) or page_count > (((@as(u64, 1) << 44) - address) / 4096)) {
        pages.release(address, page_count) catch {};
        return error.AmdMesFirmwareOutsideDmaMask;
    }
    const target: [*]u8 = @ptrFromInt(address);
    @memset(target[0 .. page_count * 4096], 0);
    @memcpy(target[0..payload.len], payload);
    return .{ .address = address, .pages = page_count, .bytes = payload.len };
}

pub fn stageAmdMesFirmwareSet(set: AmdMesFirmwareSet, pages: *physical.Allocator) !AmdMesFirmwareStaging {
    var result = AmdMesFirmwareStaging{};
    errdefer result.release(pages);
    result.scheduler.ucode = try stageAmdMesPayload(set.scheduler.ucode, pages);
    result.scheduler.data = try stageAmdMesPayload(set.scheduler.data, pages);
    result.kiq.ucode = try stageAmdMesPayload(set.kiq.ucode, pages);
    result.kiq.data = try stageAmdMesPayload(set.kiq.data, pages);
    return result;
}
pub const AmdGfxFirmwareSummary = struct {
    entries: usize = 0,
    image_bytes: usize = 0,
    payload_bytes: usize = 0,
    newest_ucode_version: u32 = 0,
};
pub const AmdGfxFirmwareManifest = struct {
    family: GfxFamily,
    entries: usize = 0,
    roles: [6]AmdGfxFirmwareSummary = .{AmdGfxFirmwareSummary{}} ** 6,

    pub fn role(self: *const AmdGfxFirmwareManifest, kind: AmdGfxFirmwareRole) AmdGfxFirmwareSummary {
        return self.roles[@intFromEnum(kind)];
    }

    pub fn add(self: *AmdGfxFirmwareManifest, kind: AmdGfxFirmwareRole, image: []const u8) !void {
        const parsed = try parseAmdgpuFirmware(image);
        if (parsed.ucode_version == 0) return error.InvalidAmdGfxFirmwareVersion;
        if (kind == .mes_scheduler or kind == .mes_kiq) try validateAmdMesFirmware(image);
        var summary = &self.roles[@intFromEnum(kind)];
        summary.entries += 1;
        summary.image_bytes += image.len;
        summary.payload_bytes += parsed.payload.len;
        summary.newest_ucode_version = @max(summary.newest_ucode_version, parsed.ucode_version);
        self.entries += 1;
    }

    pub fn validate(self: *const AmdGfxFirmwareManifest) !void {
        if (self.family != .v11_0) return error.UnsupportedAmdGfxFirmwareManifest;
        inline for (.{ AmdGfxFirmwareRole.pfp, .me, .mec, .rlc, .mes_scheduler, .mes_kiq }) |kind|
            if (self.role(kind).entries == 0) return error.RequiredAmdGfxFirmwareMissing;
    }
};

pub const AmdGfx11RingContract = struct {
    ring_dwords: u32 = 1024,
    ring_bytes: u32 = 4096,
    mqd_bytes: u32 = 4096,
    eop_bytes: u32 = 2048,
    pointer_bytes: u32 = 16,
    uses_64bit_pointers: bool = true,
    requires_doorbell: bool = true,
};
pub const AmdGfx11QueueResources = struct {
    ring: u64 = 0,
    mqd: u64 = 0,
    eop: u64 = 0,
    pointers: u64 = 0,
};
pub const AmdGfx11RingResources = struct {
    scheduler: AmdGfx11QueueResources = .{},
    kiq: AmdGfx11QueueResources = .{},
    allocator: ?AmdGpuVmPageAllocator = null,

    pub fn release(self: *AmdGfx11RingResources) !void {
        const allocator = self.allocator orelse return error.AmdGfxRingResourcesNotAllocated;
        var failed = false;
        inline for (.{ "kiq", "scheduler" }) |queue_field| {
            inline for (.{ "pointers", "eop", "mqd", "ring" }) |field| {
                const address = @field(@field(self, queue_field), field);
                if (address != 0) allocator.release(allocator.context, address) catch {
                    failed = true;
                };
            }
        }
        self.* = .{};
        if (failed) return error.AmdGfxRingResourceReleaseFailed;
    }
};

pub fn allocateAmdGfx11RingResources(allocator: AmdGpuVmPageAllocator) !AmdGfx11RingResources {
    var result = AmdGfx11RingResources{ .allocator = allocator };
    errdefer {
        if (result.allocator != null) result.release() catch {};
    }
    inline for (.{ "scheduler", "kiq" }) |queue_field| {
        inline for (.{ "ring", "mqd", "eop", "pointers" }) |field| {
            const address = try allocateCheckedAmdGpuVmPage(allocator);
            @field(@field(result, queue_field), field) = address;
            try allocator.zero(allocator.context, address);
        }
    }
    return result;
}
pub const AmdGfx11QueueKind = enum { scheduler, kiq };
pub const AmdGfx11Doorbell = struct { assignment: u16, register_index: u16, byte_offset: u32 };

pub fn planAmdGfx11MesDoorbell(kind: AmdGfx11QueueKind, aperture_bytes: u64) !AmdGfx11Doorbell {
    const assignment: u16 = switch (kind) {
        .scheduler => 0x00b,
        .kiq => 0x00c,
    };
    const register_index = assignment << 1;
    const byte_offset = @as(u32, register_index) * 4;
    if (aperture_bytes < @as(u64, byte_offset) + 8) return error.AmdGfxDoorbellOutsideAperture;
    return .{ .assignment = assignment, .register_index = register_index, .byte_offset = byte_offset };
}

pub const AmdGfx11QueueAddresses = struct {
    ring: u64,
    mqd: u64,
    eop: u64,
    rptr: u64,
    wptr: u64,
};
pub const AmdGfx11ComputeMqd = struct {
    dwords: [512]u32 = .{0} ** 512,
    doorbell: AmdGfx11Doorbell,
};

fn setField(value: u32, mask: u32, shift: u5, field: u32) u32 {
    return (value & ~mask) | ((field << shift) & mask);
}

pub fn encodeAmdGfx11MesMqd(kind: AmdGfx11QueueKind, addresses: AmdGfx11QueueAddresses, aperture_bytes: u64) !AmdGfx11ComputeMqd {
    const gpu_limit: u64 = @as(u64, 1) << 48;
    if (addresses.ring == 0 or (addresses.ring & 255) != 0 or addresses.mqd == 0 or (addresses.mqd & 4095) != 0 or
        addresses.eop == 0 or (addresses.eop & 255) != 0 or addresses.rptr == 0 or (addresses.rptr & 7) != 0 or
        addresses.wptr == 0 or (addresses.wptr & 7) != 0)
        return error.InvalidAmdGfxQueueAddress;
    inline for (.{ addresses.ring, addresses.mqd, addresses.eop, addresses.rptr, addresses.wptr }) |address|
        if (address >= gpu_limit) return error.AmdGfxQueueAddressOutsideRange;
    if (addresses.rptr == addresses.wptr) return error.InvalidAmdGfxQueuePointers;

    const doorbell = try planAmdGfx11MesDoorbell(kind, aperture_bytes);
    var result = AmdGfx11ComputeMqd{ .doorbell = doorbell };
    const mqd = &result.dwords;
    mqd[0] = 0xc0310800;
    mqd[11] = 1;
    mqd[23] = 0xffffffff;
    mqd[24] = 0xffffffff;
    mqd[26] = 0xffffffff;
    mqd[27] = 0xffffffff;
    mqd[32] = 7;
    mqd[128] = @truncate(addresses.mqd & 0xfffffffc);
    mqd[129] = @truncate(addresses.mqd >> 32);
    mqd[130] = 0; // Queue activation is a later, separately gated transaction.
    mqd[132] = setField(0x0be05501, 0x0003ff00, 8, 0x55);
    const ring_base = addresses.ring >> 8;
    mqd[136] = @truncate(ring_base);
    mqd[137] = @truncate(ring_base >> 32);
    mqd[139] = @truncate(addresses.rptr & 0xfffffffc);
    mqd[140] = @truncate((addresses.rptr >> 32) & 0xffff);
    mqd[141] = @truncate(addresses.wptr & 0xfffffffc);
    mqd[142] = @truncate((addresses.wptr >> 32) & 0xffff);
    mqd[143] = setField(0, 0x0ffffffc, 2, doorbell.register_index) | 0x40000000;
    var pq_control: u32 = 0x00308509;
    pq_control = setField(pq_control, 0x0000003f, 0, 9);
    pq_control = setField(pq_control, 0x00003f00, 8, 9);
    mqd[145] = pq_control | 0x08000000 | 0x10000000 | 0x40000000 | 0x80000000;
    mqd[149] = setField(0x00300000, 0x00300000, 20, 3);
    mqd[162] = 0x00000100;
    const eop_base = addresses.eop >> 8;
    mqd[165] = @truncate(eop_base);
    mqd[166] = @truncate(eop_base >> 32);
    mqd[167] = setField(0x00000006, 0x0000003f, 0, 8);
    return result;
}
pub const AmdGfx11MesBootstrap = struct {
    scheduler: AmdGfx11QueueAddresses,
    kiq: AmdGfx11QueueAddresses,
    scheduler_doorbell: AmdGfx11Doorbell,
    kiq_doorbell: AmdGfx11Doorbell,
    first_gart_page: u16 = 3,
    gart_pages: u16 = 8,
};

pub fn prepareAmdGfx11MesBootstrap(
    staging: AmdPspGttStaging,
    resources: AmdGfx11RingResources,
    window_start: u64,
    doorbell_aperture_bytes: u64,
) !AmdGfx11MesBootstrap {
    if (staging.active or staging.page_table_address == 0 or staging.page_table_pages != 1 or staging.buffer_pages != 3 or
        resources.allocator == null or (window_start & 4095) != 0)
        return error.InvalidAmdGfxMesBootstrap;
    const queues = .{ resources.scheduler, resources.kiq };
    inline for (queues) |queue| if (queue.ring == 0 or queue.mqd == 0 or queue.eop == 0 or queue.pointers == 0)
        return error.InvalidAmdGfxMesBootstrap;

    const scheduler = AmdGfx11QueueAddresses{
        .ring = window_start + 3 * 4096,
        .mqd = window_start + 4 * 4096,
        .eop = window_start + 5 * 4096,
        .rptr = window_start + 6 * 4096,
        .wptr = window_start + 6 * 4096 + 8,
    };
    const kiq = AmdGfx11QueueAddresses{
        .ring = window_start + 7 * 4096,
        .mqd = window_start + 8 * 4096,
        .eop = window_start + 9 * 4096,
        .rptr = window_start + 10 * 4096,
        .wptr = window_start + 10 * 4096 + 8,
    };
    const scheduler_mqd = try encodeAmdGfx11MesMqd(.scheduler, scheduler, doorbell_aperture_bytes);
    const kiq_mqd = try encodeAmdGfx11MesMqd(.kiq, kiq, doorbell_aperture_bytes);
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    for (3..11) |index| if (table[index] != 0) return error.AmdGfxGartPageAlreadyMapped;
    const physical_pages = .{
        resources.scheduler.ring, resources.scheduler.mqd, resources.scheduler.eop, resources.scheduler.pointers,
        resources.kiq.ring,       resources.kiq.mqd,       resources.kiq.eop,       resources.kiq.pointers,
    };
    inline for (physical_pages, 3..) |address, index| table[index] = amdGttPte(address);
    const scheduler_target: *[512]u32 = @ptrFromInt(resources.scheduler.mqd);
    const kiq_target: *[512]u32 = @ptrFromInt(resources.kiq.mqd);
    scheduler_target.* = scheduler_mqd.dwords;
    kiq_target.* = kiq_mqd.dwords;
    return .{
        .scheduler = scheduler,
        .kiq = kiq,
        .scheduler_doorbell = scheduler_mqd.doorbell,
        .kiq_doorbell = kiq_mqd.doorbell,
    };
}
pub const AmdMesFirmwareGpuLayout = struct {
    scheduler_ucode: u64,
    scheduler_data: u64,
    kiq_ucode: u64,
    kiq_data: u64,
    first_gart_page: u16 = 11,
    gart_pages: u16,
};

pub fn mapAmdMesFirmwareIntoGart(staging: AmdPspGttStaging, firmware: AmdMesFirmwareStaging, window_start: u64) !AmdMesFirmwareGpuLayout {
    if (staging.active or staging.page_table_address == 0 or staging.page_table_pages != 1 or (window_start & 4095) != 0)
        return error.InvalidAmdMesFirmwareGart;
    const areas = .{ firmware.scheduler.ucode, firmware.scheduler.data, firmware.kiq.ucode, firmware.kiq.data };
    var total_pages: u64 = 0;
    inline for (areas) |area| {
        if (area.address == 0 or area.pages == 0 or area.bytes == 0 or (area.address & 4095) != 0 or area.bytes > area.pages * 4096)
            return error.InvalidAmdMesFirmwareStaging;
        total_pages += area.pages;
    }
    if (total_pages > 512 - 11) return error.AmdMesFirmwareExceedsGartWindow;
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    for (11..11 + total_pages) |index| if (table[index] != 0) return error.AmdMesFirmwareGartPageAlreadyMapped;
    var next: u64 = 11;
    var gpu_addresses: [4]u64 = undefined;
    inline for (areas, 0..) |area, area_index| {
        gpu_addresses[area_index] = window_start + next * 4096;
        var page: u64 = 0;
        while (page < area.pages) : (page += 1) table[next + page] = amdGttPte(area.address + page * 4096);
        next += area.pages;
    }
    return .{
        .scheduler_ucode = gpu_addresses[0],
        .scheduler_data = gpu_addresses[1],
        .kiq_ucode = gpu_addresses[2],
        .kiq_data = gpu_addresses[3],
        .gart_pages = @intCast(total_pages),
    };
}

pub const AmdMesControlResources = struct {
    page: u64 = 0,
    allocator: ?AmdGpuVmPageAllocator = null,

    pub fn release(self: *AmdMesControlResources) !void {
        const allocator = self.allocator orelse return error.AmdMesControlResourcesNotAllocated;
        if (self.page == 0) return error.AmdMesControlResourcesNotAllocated;
        try allocator.release(allocator.context, self.page);
        self.* = .{};
    }
};

pub fn allocateAmdMesControlResources(allocator: AmdGpuVmPageAllocator) !AmdMesControlResources {
    const page = try allocateCheckedAmdGpuVmPage(allocator);
    errdefer allocator.release(allocator.context, page) catch {};
    try allocator.zero(allocator.context, page);
    return .{ .page = page, .allocator = allocator };
}

pub const AmdGfx11RlcResources = struct {
    page: u64 = 0,
    allocator: ?AmdGpuVmPageAllocator = null,

    pub fn release(self: *AmdGfx11RlcResources) !void {
        const allocator = self.allocator orelse return error.AmdRlcResourcesNotAllocated;
        if (self.page == 0) return error.AmdRlcResourcesNotAllocated;
        try allocator.release(allocator.context, self.page);
        self.* = .{};
    }
};

const AmdGfx11ClearStateExtent = struct { register: u16, count: u16 };
const amd_gfx11_clear_state_extents = [_]AmdGfx11ClearStateExtent{
    .{ .register = 0xa000, .count = 215 }, .{ .register = 0xa0d8, .count = 272 },
    .{ .register = 0xa1f5, .count = 4 },   .{ .register = 0xa1ff, .count = 158 },
    .{ .register = 0xa2a0, .count = 2 },   .{ .register = 0xa2a3, .count = 1 },
    .{ .register = 0xa2a6, .count = 282 },
};
const AmdGfx11ClearStateValue = struct { index: u16, value: u32 };
const amd_gfx11_clear_state_values = [_]AmdGfx11ClearStateValue{
    .{ .index = 13, .value = 0x40004000 },  .{ .index = 31, .value = 0x00150055 },
    .{ .index = 129, .value = 0x80000000 }, .{ .index = 130, .value = 0x40004000 },
    .{ .index = 131, .value = 0x0000ffff }, .{ .index = 133, .value = 0x40004000 },
    .{ .index = 135, .value = 0x40004000 }, .{ .index = 137, .value = 0x40004000 },
    .{ .index = 139, .value = 0x40004000 }, .{ .index = 140, .value = 0xaa99aaaa },
    .{ .index = 142, .value = 0xffffffff }, .{ .index = 143, .value = 0xffffffff },
    .{ .index = 144, .value = 0x80000000 }, .{ .index = 145, .value = 0x40004000 },
    .{ .index = 148, .value = 0x80000000 }, .{ .index = 149, .value = 0x40004000 },
    .{ .index = 150, .value = 0x80000000 }, .{ .index = 151, .value = 0x40004000 },
    .{ .index = 152, .value = 0x80000000 }, .{ .index = 153, .value = 0x40004000 },
    .{ .index = 154, .value = 0x80000000 }, .{ .index = 155, .value = 0x40004000 },
    .{ .index = 156, .value = 0x80000000 }, .{ .index = 157, .value = 0x40004000 },
    .{ .index = 158, .value = 0x80000000 }, .{ .index = 159, .value = 0x40004000 },
    .{ .index = 160, .value = 0x80000000 }, .{ .index = 161, .value = 0x40004000 },
    .{ .index = 162, .value = 0x80000000 }, .{ .index = 163, .value = 0x40004000 },
    .{ .index = 164, .value = 0x80000000 }, .{ .index = 165, .value = 0x40004000 },
    .{ .index = 166, .value = 0x80000000 }, .{ .index = 167, .value = 0x40004000 },
    .{ .index = 168, .value = 0x80000000 }, .{ .index = 169, .value = 0x40004000 },
    .{ .index = 170, .value = 0x80000000 }, .{ .index = 171, .value = 0x40004000 },
    .{ .index = 172, .value = 0x80000000 }, .{ .index = 173, .value = 0x40004000 },
    .{ .index = 174, .value = 0x80000000 }, .{ .index = 175, .value = 0x40004000 },
    .{ .index = 176, .value = 0x80000000 }, .{ .index = 177, .value = 0x40004000 },
    .{ .index = 178, .value = 0x80000000 }, .{ .index = 179, .value = 0x40004000 },
    .{ .index = 181, .value = 0x3f800000 }, .{ .index = 183, .value = 0x3f800000 },
    .{ .index = 185, .value = 0x3f800000 }, .{ .index = 187, .value = 0x3f800000 },
    .{ .index = 189, .value = 0x3f800000 }, .{ .index = 191, .value = 0x3f800000 },
    .{ .index = 193, .value = 0x3f800000 }, .{ .index = 195, .value = 0x3f800000 },
    .{ .index = 197, .value = 0x3f800000 }, .{ .index = 199, .value = 0x3f800000 },
    .{ .index = 201, .value = 0x3f800000 }, .{ .index = 203, .value = 0x3f800000 },
    .{ .index = 205, .value = 0x3f800000 }, .{ .index = 207, .value = 0x3f800000 },
    .{ .index = 209, .value = 0x3f800000 }, .{ .index = 211, .value = 0x3f800000 },
    .{ .index = 259, .value = 0x00550055 }, .{ .index = 267, .value = 0x01000000 },
    .{ .index = 268, .value = 0x01000000 }, .{ .index = 437, .value = 0x00000002 },
    .{ .index = 496, .value = 0x00090000 }, .{ .index = 497, .value = 0x00000004 },
    .{ .index = 733, .value = 0x00001000 }, .{ .index = 735, .value = 0x00000005 },
    .{ .index = 736, .value = 0x3f800000 }, .{ .index = 737, .value = 0x3f800000 },
    .{ .index = 738, .value = 0x3f800000 }, .{ .index = 739, .value = 0x3f800000 },
    .{ .index = 756, .value = 0xffffffff }, .{ .index = 757, .value = 0xffffffff },
    .{ .index = 759, .value = 0x00000003 }, .{ .index = 761, .value = 0x00100000 },
};

fn amdPacket3(opcode: u8, count: u14) u32 {
    return 0xc0000000 | (@as(u32, count) << 16) | (@as(u32, opcode) << 8);
}

pub fn buildAmdGfx11ClearStateBlock(target: *[1024]u32, tile_steering_override: u32) !u16 {
    @memset(target, 0);
    var defaults = [_]u32{0} ** 934;
    for (amd_gfx11_clear_state_values) |entry| defaults[entry.index] = entry.value;
    var cursor: usize = 0;
    target[cursor] = amdPacket3(0x4a, 0);
    cursor += 1;
    target[cursor] = 2 << 28;
    cursor += 1;
    target[cursor] = amdPacket3(0x28, 1);
    cursor += 1;
    target[cursor] = 0x80000000;
    cursor += 1;
    target[cursor] = 0x80000000;
    cursor += 1;
    var source: usize = 0;
    for (amd_gfx11_clear_state_extents) |extent| {
        target[cursor] = amdPacket3(0x69, @intCast(extent.count));
        cursor += 1;
        target[cursor] = extent.register - 0xa000;
        cursor += 1;
        @memcpy(target[cursor .. cursor + extent.count], defaults[source .. source + extent.count]);
        cursor += extent.count;
        source += extent.count;
    }
    if (source != defaults.len) return error.InvalidAmdGfx11ClearStateData;
    target[cursor] = amdPacket3(0x69, 1);
    cursor += 1;
    target[cursor] = 0x00d7;
    cursor += 1;
    target[cursor] = tile_steering_override;
    cursor += 1;
    target[cursor] = amdPacket3(0x4a, 0);
    cursor += 1;
    target[cursor] = 3 << 28;
    cursor += 1;
    target[cursor] = amdPacket3(0x12, 0);
    cursor += 1;
    target[cursor] = 0;
    cursor += 1;
    if (cursor != 960) return error.InvalidAmdGfx11ClearStateSize;
    return @intCast(cursor);
}

pub fn allocateAmdGfx11RlcResources(allocator: AmdGpuVmPageAllocator) !AmdGfx11RlcResources {
    const page = try allocateCheckedAmdGpuVmPage(allocator);
    errdefer allocator.release(allocator.context, page) catch {};
    try allocator.zero(allocator.context, page);
    const target: *[1024]u32 = @ptrFromInt(page);
    _ = try buildAmdGfx11ClearStateBlock(target, 0);
    return .{ .page = page, .allocator = allocator };
}

pub const AmdGfx11RlcLayout = struct { address: u64, dwords: u16 = 960, first_gart_page: u16 };

pub fn mapAmdGfx11RlcIntoGart(staging: AmdPspGttStaging, firmware: AmdGfx11CpFirmwareGpuLayout, resources: AmdGfx11RlcResources, window_start: u64) !AmdGfx11RlcLayout {
    if (staging.active or staging.page_table_address == 0 or staging.page_table_pages != 1 or resources.allocator == null or
        resources.page == 0 or (resources.page & 4095) != 0 or firmware.count == 0 or (window_start & 4095) != 0)
        return error.InvalidAmdRlcResources;
    const first_page: u64 = @as(u64, firmware.first_gart_page) + firmware.gart_pages;
    if (first_page >= 512) return error.AmdRlcExceedsGartWindow;
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    if (table[first_page] != 0) return error.AmdRlcGartPageAlreadyMapped;
    table[first_page] = amdGttPte(resources.page);
    return .{ .address = window_start + first_page * 4096, .first_gart_page = @intCast(first_page) };
}

pub const AmdGfx11GfxRingResources = struct {
    ring: u64 = 0,
    pointers: u64 = 0,
    allocator: ?AmdGpuVmPageAllocator = null,

    pub fn release(self: *AmdGfx11GfxRingResources) !void {
        const allocator = self.allocator orelse return error.AmdGfxRingResourcesNotAllocated;
        var failed = false;
        if (self.pointers != 0) allocator.release(allocator.context, self.pointers) catch {
            failed = true;
        };
        if (self.ring != 0) allocator.release(allocator.context, self.ring) catch {
            failed = true;
        };
        self.* = .{};
        if (failed) return error.AmdGfxRingResourceReleaseFailed;
    }
};

pub fn allocateAmdGfx11GfxRingResources(allocator: AmdGpuVmPageAllocator) !AmdGfx11GfxRingResources {
    var result = AmdGfx11GfxRingResources{ .allocator = allocator };
    errdefer result.release() catch {};
    result.ring = try allocateCheckedAmdGpuVmPage(allocator);
    try allocator.zero(allocator.context, result.ring);
    result.pointers = try allocateCheckedAmdGpuVmPage(allocator);
    try allocator.zero(allocator.context, result.pointers);
    return result;
}

pub const AmdGfx11GfxRingLayout = struct {
    ring: u64,
    rptr: u64,
    wptr: u64,
    first_gart_page: u16,
    gart_pages: u8 = 2,
    ring_dwords: u16 = 1024,
    doorbell_index: u16 = 0x116,
    doorbell_byte_offset: u32 = 0x458,
};

pub fn mapAmdGfx11GfxRingIntoGart(
    staging: AmdPspGttStaging,
    rlc: AmdGfx11RlcLayout,
    resources: AmdGfx11GfxRingResources,
    window_start: u64,
    doorbell_aperture_bytes: u64,
) !AmdGfx11GfxRingLayout {
    if (staging.active or staging.page_table_address == 0 or staging.page_table_pages != 1 or resources.allocator == null or
        resources.ring == 0 or resources.pointers == 0 or (resources.ring & 4095) != 0 or (resources.pointers & 4095) != 0 or
        (window_start & 4095) != 0 or rlc.dwords != 960 or doorbell_aperture_bytes < 0x460)
        return error.InvalidAmdGfx11GfxRingResources;
    const first_page: u64 = @as(u64, rlc.first_gart_page) + 1;
    if (first_page >= 511) return error.AmdGfxRingExceedsGartWindow;
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    if (table[first_page] != 0 or table[first_page + 1] != 0) return error.AmdGfxRingGartPageAlreadyMapped;
    table[first_page] = amdGttPte(resources.ring);
    table[first_page + 1] = amdGttPte(resources.pointers);
    const pointer_gpu = window_start + (first_page + 1) * 4096;
    return .{
        .ring = window_start + first_page * 4096,
        .rptr = pointer_gpu,
        .wptr = pointer_gpu + 8,
        .first_gart_page = @intCast(first_page),
    };
}

pub const AmdMesControlLayout = struct {
    page: u64,
    scheduler_context: u64,
    query_status_fence: u64,
    api_completion_fence: u64,
    scheduler_fence: u64,
    cleaner_shader_fence: u64,
    first_gart_page: u16,
};

pub fn mapAmdMesControlIntoGart(
    staging: AmdPspGttStaging,
    firmware: AmdMesFirmwareGpuLayout,
    resources: AmdMesControlResources,
    window_start: u64,
) !AmdMesControlLayout {
    if (staging.active or staging.page_table_address == 0 or resources.allocator == null or resources.page == 0 or
        (resources.page & 4095) != 0 or (window_start & 4095) != 0)
        return error.InvalidAmdMesControlResources;
    const first_page: u64 = 11 + firmware.gart_pages;
    if (first_page >= 512) return error.AmdMesControlExceedsGartWindow;
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    if (table[first_page] != 0) return error.AmdMesControlGartPageAlreadyMapped;
    table[first_page] = amdGttPte(resources.page);
    const gpu_page = window_start + first_page * 4096;
    return .{
        .page = gpu_page,
        .scheduler_context = gpu_page,
        .query_status_fence = gpu_page + 8,
        .api_completion_fence = gpu_page + 16,
        .scheduler_fence = gpu_page + 24,
        .cleaner_shader_fence = gpu_page + 32,
        .first_gart_page = @intCast(first_page),
    };
}

pub fn mapAmdGfx11CpFirmwareIntoGart(
    staging: AmdPspGttStaging,
    firmware: AmdGfx11CpFirmwareStaging,
    after_page: u16,
    window_start: u64,
) !AmdGfx11CpFirmwareGpuLayout {
    if (staging.active or staging.page_table_address == 0 or staging.page_table_pages != 1 or
        firmware.count == 0 or firmware.count > firmware.areas.len or (window_start & 4095) != 0)
        return error.InvalidAmdCpFirmwareGart;
    const first_page: u64 = @as(u64, after_page) + 1;
    var total_pages: u64 = 0;
    for (firmware.areas[0..firmware.count]) |area| {
        if (area.address == 0 or area.pages == 0 or area.bytes == 0 or (area.address & 4095) != 0 or
            area.bytes > area.pages * 4096)
            return error.InvalidAmdCpFirmwareStaging;
        total_pages = std.math.add(u64, total_pages, area.pages) catch return error.AmdCpFirmwareExceedsGartWindow;
    }
    if (first_page >= 512 or total_pages > 512 - first_page) return error.AmdCpFirmwareExceedsGartWindow;
    const table: [*]u64 = @ptrFromInt(staging.page_table_address);
    for (first_page..first_page + total_pages) |index| if (table[index] != 0) return error.AmdCpFirmwareGartPageAlreadyMapped;
    var result = AmdGfx11CpFirmwareGpuLayout{
        .count = firmware.count,
        .first_gart_page = @intCast(first_page),
        .gart_pages = @intCast(total_pages),
    };
    var next = first_page;
    for (firmware.areas[0..firmware.count], 0..) |area, area_index| {
        result.areas[area_index] = .{ .kind = area.kind, .address = window_start + next * 4096, .bytes = area.bytes };
        var page: u64 = 0;
        while (page < area.pages) : (page += 1) table[next + page] = amdGttPte(area.address + page * 4096);
        next += area.pages;
    }
    return result;
}

pub const AmdMesHwResourceInput = struct {
    vmid_mask_mmhub: u32,
    vmid_mask_gfxhub: u32,
    compute_hqd_mask: [8]u32,
    gfx_hqd_mask: [2]u32,
    sdma_hqd_mask: [2]u32,
    aggregated_doorbells: [5]u32,
    gc_base: [8]u32,
    mmhub_base: [8]u32,
    osssys_base: [8]u32,
    gds_size: u32 = 0,
};

pub const AmdMesHwResourceFrame = struct { dwords: [64]u32 = .{0} ** 64 };

fn putAmdMesU64(frame: *[64]u32, index: usize, value: u64) void {
    frame[index] = @truncate(value);
    frame[index + 1] = @truncate(value >> 32);
}

pub fn encodeAmdMesSetHwResources(input: AmdMesHwResourceInput, control: AmdMesControlLayout) !AmdMesHwResourceFrame {
    if (control.scheduler_context == 0 or control.query_status_fence == 0 or control.api_completion_fence == 0 or
        (control.scheduler_context & 7) != 0 or (control.query_status_fence & 7) != 0 or
        (control.api_completion_fence & 7) != 0 or input.vmid_mask_mmhub == 0 or input.vmid_mask_gfxhub == 0 or
        (input.vmid_mask_mmhub & 1) != 0 or (input.vmid_mask_gfxhub & 1) != 0)
        return error.InvalidAmdMesHwResources;
    var any_hqd = false;
    for (input.compute_hqd_mask) |mask| any_hqd = any_hqd or mask != 0;
    for (input.gfx_hqd_mask) |mask| any_hqd = any_hqd or mask != 0;
    for (input.sdma_hqd_mask) |mask| any_hqd = any_hqd or mask != 0;
    var any_gc_base = false;
    var any_mmhub_base = false;
    var any_osssys_base = false;
    for (input.gc_base) |base| any_gc_base = any_gc_base or base != 0;
    for (input.mmhub_base) |base| any_mmhub_base = any_mmhub_base or base != 0;
    for (input.osssys_base) |base| any_osssys_base = any_osssys_base or base != 0;
    if (!any_hqd or !any_gc_base or !any_mmhub_base or !any_osssys_base)
        return error.InvalidAmdMesHwResources;

    var result = AmdMesHwResourceFrame{};
    const frame = &result.dwords;
    frame[0] = 0x00040001; // scheduler type, SET_HW_RSRC opcode, 64 dwords.
    frame[1] = input.vmid_mask_mmhub;
    frame[2] = input.vmid_mask_gfxhub;
    frame[3] = input.gds_size;
    frame[4] = 0; // paging VMID remains the reserved system VMID.
    @memcpy(frame[5..13], &input.compute_hqd_mask);
    @memcpy(frame[13..15], &input.gfx_hqd_mask);
    @memcpy(frame[15..17], &input.sdma_hqd_mask);
    @memcpy(frame[17..22], &input.aggregated_doorbells);
    putAmdMesU64(frame, 22, control.scheduler_context);
    putAmdMesU64(frame, 24, control.query_status_fence);
    @memcpy(frame[26..34], &input.gc_base);
    @memcpy(frame[34..42], &input.mmhub_base);
    @memcpy(frame[42..50], &input.osssys_base);
    putAmdMesU64(frame, 50, control.api_completion_fence);
    putAmdMesU64(frame, 52, 1);
    frame[54] = 0x5; // disable_reset | disable_mes_log, matching the upstream base policy.
    return result;
}

pub const AmdGfx11MesHwResourcePlan = struct {
    input: AmdMesHwResourceInput,
    frame: AmdMesHwResourceFrame,
    aggregated_doorbell_first: u32 = 0x800,
    aggregated_doorbell_bytes: u32 = 0x28,
};

pub fn planAmdGfx11MesHwResources(
    discovery: *const AmdIpDiscovery,
    control: AmdMesControlLayout,
    doorbell_aperture_bytes: u64,
) !AmdGfx11MesHwResourcePlan {
    const gfx = discovery.find(amd_hw_id.gfx, 0) orelse return error.AmdGfxMissing;
    const mmhub = discovery.find(amd_hw_id.mmhub, 0) orelse return error.AmdMmhubMissing;
    const osssys = discovery.find(amd_hw_id.osssys, 0) orelse return error.AmdOsssysMissing;
    const sdma0 = discovery.find(amd_hw_id.sdma0, 0) orelse return error.AmdSdmaMissing;
    if (gfx.major != 11 or mmhub.major != 3 or gfx.base_count == 0 or mmhub.base_count == 0 or
        osssys.base_count == 0 or sdma0.major != 6)
        return error.UnsupportedAmdMesHwTopology;
    switch (version(gfx)) {
        0x0b0000, 0x0b0001, 0x0b0002, 0x0b0504, 0x0b0506, 0x0b0700, 0x0b0701 => {},
        else => return error.UnsupportedAmdMesHwTopology,
    }
    const aggregated = [5]u32{ 0x800, 0x802, 0x804, 0x806, 0x808 };
    const final_byte = @as(u64, aggregated[4]) * 4 + 8;
    if (doorbell_aperture_bytes < final_byte) return error.AmdMesDoorbellApertureTooSmall;
    const sdma1_present = discovery.find(amd_hw_id.sdma1, 0) != null;
    var input = AmdMesHwResourceInput{
        .vmid_mask_mmhub = 0xff00,
        .vmid_mask_gfxhub = 0xff00,
        .compute_hqd_mask = .{ 0x0c, 0x0c, 0x0c, 0x0c, 0, 0, 0, 0 },
        .gfx_hqd_mask = .{ 0x02, 0x02 },
        .sdma_hqd_mask = .{ 0xfc, if (sdma1_present) 0xfc else 0 },
        .aggregated_doorbells = aggregated,
        .gc_base = .{0} ** 8,
        .mmhub_base = .{0} ** 8,
        .osssys_base = .{0} ** 8,
    };
    for (gfx.bases, 0..) |base, index| {
        if (base > ~@as(u32, 0)) return error.AmdMesIpBaseOutsideRange;
        input.gc_base[index] = @intCast(base);
    }
    for (mmhub.bases, 0..) |base, index| {
        if (base > ~@as(u32, 0)) return error.AmdMesIpBaseOutsideRange;
        input.mmhub_base[index] = @intCast(base);
    }
    for (osssys.bases, 0..) |base, index| {
        if (base > ~@as(u32, 0)) return error.AmdMesIpBaseOutsideRange;
        input.osssys_base[index] = @intCast(base);
    }
    return .{ .input = input, .frame = try encodeAmdMesSetHwResources(input, control) };
}

pub const AmdMesSchedulerInitPlan = struct {
    frames: [128]u32,
    scheduler_doorbell_offset: u32,
    final_wptr: u64 = 128,
};

pub fn planAmdMesSchedulerInit(
    resources: AmdGfx11MesHwResourcePlan,
    control: AmdMesControlLayout,
    scheduler_doorbell: AmdGfx11Doorbell,
) !AmdMesSchedulerInitPlan {
    if (resources.frame.dwords[0] != 0x00040001 or resources.frame.dwords[50] != @as(u32, @truncate(control.api_completion_fence)) or
        scheduler_doorbell.register_index != 0x16 or (scheduler_doorbell.byte_offset & 7) != 0 or
        control.scheduler_fence == 0 or (control.scheduler_fence & 7) != 0)
        return error.InvalidAmdMesSchedulerInit;
    var frames = [_]u32{0} ** 128;
    @memcpy(frames[0..64], &resources.frame.dwords);
    // QUERY_SCHEDULER_STATUS is the second fixed 64-dword API frame and acts
    // as the scheduler-ring fence after SET_HW_RSRC.
    frames[64] = 0x000400b1;
    frames[65] = 0;
    frames[66] = @truncate(control.scheduler_fence);
    frames[67] = @truncate(control.scheduler_fence >> 32);
    frames[68] = 1;
    frames[69] = 0;
    return .{ .frames = frames, .scheduler_doorbell_offset = scheduler_doorbell.byte_offset };
}

pub fn initializeAmdMesScheduler(
    plan: AmdMesSchedulerInitPlan,
    scheduler_ring: *[1024]u32,
    scheduler_pointers: *[2]u64,
    control_page: *[512]u64,
    poll_limit: u32,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or plan.final_wptr != plan.frames.len or plan.frames[0] != 0x00040001 or
        plan.frames[64] != 0x000400b1 or plan.frames[68] != 1)
        return error.InvalidAmdMesSchedulerInitPlan;
    if (@atomicLoad(u64, &scheduler_pointers[0], .seq_cst) != 0 or
        @atomicLoad(u64, &scheduler_pointers[1], .seq_cst) != 0)
        return error.AmdMesSchedulerRingNotIdle;
    @atomicStore(u64, &control_page[2], 0, .seq_cst);
    @atomicStore(u64, &control_page[3], 0, .seq_cst);
    @memcpy(scheduler_ring[0..plan.frames.len], &plan.frames);
    @atomicStore(u64, &scheduler_pointers[1], plan.final_wptr, .seq_cst);
    doorbells.write64(doorbells.context, plan.scheduler_doorbell_offset, plan.final_wptr) catch
        return error.AmdMesSchedulerDoorbellWriteFailed;
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const api_complete = @atomicLoad(u64, &control_page[2], .seq_cst) == 1;
        const query_complete = @atomicLoad(u64, &control_page[3], .seq_cst) == 1;
        const consumed = @atomicLoad(u64, &scheduler_pointers[0], .seq_cst) == plan.final_wptr;
        if (api_complete and query_complete and consumed) return polls;
        asm volatile ("pause");
    }
    return error.AmdMesSchedulerInitTimeout;
}

pub const AmdMesSchedulerResource1Plan = struct {
    frames: [128]u32,
    scheduler_doorbell_offset: u32,
    initial_wptr: u64 = 128,
    final_wptr: u64 = 256,
    firmware_revision: u16,
};

pub fn planAmdMesSchedulerResource1(
    scheduler_version: u32,
    control: AmdMesControlLayout,
    scheduler_doorbell: AmdGfx11Doorbell,
) !?AmdMesSchedulerResource1Plan {
    const revision: u16 = @truncate(scheduler_version & 0x0fff);
    if (revision < 0x52) return null;
    if (control.api_completion_fence == 0 or control.scheduler_fence == 0 or control.cleaner_shader_fence == 0 or
        (control.api_completion_fence & 7) != 0 or (control.scheduler_fence & 7) != 0 or
        (control.cleaner_shader_fence & 7) != 0 or scheduler_doorbell.register_index != 0x16)
        return error.InvalidAmdMesSchedulerResource1;
    var frames = [_]u32{0} ** 128;
    frames[0] = 0x00040131; // scheduler type, SET_HW_RSRC_1 opcode 19, 64 dwords.
    frames[1] = @truncate(control.api_completion_fence);
    frames[2] = @truncate(control.api_completion_fence >> 32);
    frames[3] = 1;
    frames[7] = 1; // enable_mes_info_ctx; address/size remain zero outside SR-IOV.
    frames[13] = @truncate(control.cleaner_shader_fence);
    frames[14] = @truncate(control.cleaner_shader_fence >> 32);
    frames[64] = 0x000400b1;
    frames[66] = @truncate(control.scheduler_fence);
    frames[67] = @truncate(control.scheduler_fence >> 32);
    frames[68] = 2;
    return .{
        .frames = frames,
        .scheduler_doorbell_offset = scheduler_doorbell.byte_offset,
        .firmware_revision = revision,
    };
}

pub fn initializeAmdMesSchedulerResource1(
    plan: AmdMesSchedulerResource1Plan,
    scheduler_ring: *[1024]u32,
    scheduler_pointers: *[2]u64,
    control_page: *[512]u64,
    poll_limit: u32,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or plan.firmware_revision < 0x52 or plan.frames[0] != 0x00040131 or
        plan.frames[64] != 0x000400b1 or plan.frames[68] != 2 or
        plan.initial_wptr + plan.frames.len != plan.final_wptr)
        return error.InvalidAmdMesSchedulerResource1Plan;
    if (@atomicLoad(u64, &scheduler_pointers[0], .seq_cst) != plan.initial_wptr or
        @atomicLoad(u64, &scheduler_pointers[1], .seq_cst) != plan.initial_wptr)
        return error.AmdMesSchedulerRingNotIdle;
    @atomicStore(u64, &control_page[2], 0, .seq_cst);
    @atomicStore(u64, &control_page[3], 0, .seq_cst);
    @atomicStore(u64, &control_page[4], 0, .seq_cst);
    const start: usize = @intCast(plan.initial_wptr);
    @memcpy(scheduler_ring[start .. start + plan.frames.len], &plan.frames);
    @atomicStore(u64, &scheduler_pointers[1], plan.final_wptr, .seq_cst);
    doorbells.write64(doorbells.context, plan.scheduler_doorbell_offset, plan.final_wptr) catch
        return error.AmdMesSchedulerDoorbellWriteFailed;
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const api_complete = @atomicLoad(u64, &control_page[2], .seq_cst) == 1;
        const query_complete = @atomicLoad(u64, &control_page[3], .seq_cst) == 2;
        const consumed = @atomicLoad(u64, &scheduler_pointers[0], .seq_cst) == plan.final_wptr;
        if (api_complete and query_complete and consumed) return polls;
        asm volatile ("pause");
    }
    return error.AmdMesSchedulerResource1Timeout;
}
pub const AmdGfx11MesRegisters = struct {
    grbm_gfx_cntl: u32,
    mes_control: u32,
    ic_base_cntl: u32,
    program_counter_low: u32,
    program_counter_high: u32,
    instruction_base_low: u32,
    instruction_base_high: u32,
    instruction_bound_low: u32,
    data_base_low: u32,
    data_base_high: u32,
    data_bound_low: u32,
    gp3_low: u32,
    hqd_vmid: u32,
    hqd_doorbell_control: u32,
    mqd_base_low: u32,
    mqd_base_high: u32,
    mqd_control: u32,
    hqd_pq_base_low: u32,
    hqd_pq_base_high: u32,
    hqd_rptr_report_low: u32,
    hqd_rptr_report_high: u32,
    hqd_pq_control: u32,
    hqd_wptr_poll_low: u32,
    hqd_wptr_poll_high: u32,
    hqd_persistent_state: u32,
    hqd_active: u32,
    scratch0: u32,
};

pub fn resolveAmdGfx11MesRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdGfx11MesRegisters {
    if (ip.hw_id != amd_hw_id.gfx or ip.instance != 0 or ip.major != 11 or ip.base_count <= 1 or ip.bases[1] == 0)
        return error.AmdGfx11MesRegisterBaseMissing;
    const base = ip.bases[1];
    return .{
        .grbm_gfx_cntl = try resolveAmdRegister(base, 0x0900, register_bar_bytes),
        .mes_control = try resolveAmdRegister(base, 0x2807, register_bar_bytes),
        .ic_base_cntl = try resolveAmdRegister(base, 0x5852, register_bar_bytes),
        .program_counter_low = try resolveAmdRegister(base, 0x2800, register_bar_bytes),
        .program_counter_high = try resolveAmdRegister(base, 0x289d, register_bar_bytes),
        .instruction_base_low = try resolveAmdRegister(base, 0x5850, register_bar_bytes),
        .instruction_base_high = try resolveAmdRegister(base, 0x5851, register_bar_bytes),
        .instruction_bound_low = try resolveAmdRegister(base, 0x585b, register_bar_bytes),
        .data_base_low = try resolveAmdRegister(base, 0x5854, register_bar_bytes),
        .data_base_high = try resolveAmdRegister(base, 0x5855, register_bar_bytes),
        .data_bound_low = try resolveAmdRegister(base, 0x585d, register_bar_bytes),
        .gp3_low = try resolveAmdRegister(base, 0x2849, register_bar_bytes),
        .hqd_vmid = try resolveAmdRegister(base, 0x1fac, register_bar_bytes),
        .hqd_doorbell_control = try resolveAmdRegister(base, 0x1fb8, register_bar_bytes),
        .mqd_base_low = try resolveAmdRegister(base, 0x1fa9, register_bar_bytes),
        .mqd_base_high = try resolveAmdRegister(base, 0x1faa, register_bar_bytes),
        .mqd_control = try resolveAmdRegister(base, 0x1fcb, register_bar_bytes),
        .hqd_pq_base_low = try resolveAmdRegister(base, 0x1fb1, register_bar_bytes),
        .hqd_pq_base_high = try resolveAmdRegister(base, 0x1fb2, register_bar_bytes),
        .hqd_rptr_report_low = try resolveAmdRegister(base, 0x1fb4, register_bar_bytes),
        .hqd_rptr_report_high = try resolveAmdRegister(base, 0x1fb5, register_bar_bytes),
        .hqd_pq_control = try resolveAmdRegister(base, 0x1fba, register_bar_bytes),
        .hqd_wptr_poll_low = try resolveAmdRegister(base, 0x1fb6, register_bar_bytes),
        .hqd_wptr_poll_high = try resolveAmdRegister(base, 0x1fb7, register_bar_bytes),
        .hqd_persistent_state = try resolveAmdRegister(base, 0x1fad, register_bar_bytes),
        .hqd_active = try resolveAmdRegister(base, 0x1fab, register_bar_bytes),
        .scratch0 = try resolveAmdRegister(base, 0x2040, register_bar_bytes),
    };
}

pub const AmdGfx11RlcRegisters = struct {
    csib_address_low: u32,
    csib_address_high: u32,
    csib_length: u32,
    srm_control: u32,
};

pub fn resolveAmdGfx11RlcRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdGfx11RlcRegisters {
    if (ip.hw_id != amd_hw_id.gfx or ip.instance != 0 or ip.major != 11 or ip.base_count <= 1 or ip.bases[1] == 0)
        return error.AmdGfx11RlcRegisterBaseMissing;
    const base = ip.bases[1];
    return .{
        .csib_address_low = try resolveAmdRegister(base, 0x0987, register_bar_bytes),
        .csib_address_high = try resolveAmdRegister(base, 0x0988, register_bar_bytes),
        .csib_length = try resolveAmdRegister(base, 0x0989, register_bar_bytes),
        .srm_control = try resolveAmdRegister(base, 0x4c80, register_bar_bytes),
    };
}

pub const AmdGfx11RlcResumePlan = struct {
    registers: AmdGfx11RlcRegisters,
    address: u64,
    dwords: u16,
};
pub const AmdGfx11RlcResumeTransaction = struct { previous: [4]u32, applied: u3 = 0 };

pub fn planAmdGfx11RlcResume(registers: AmdGfx11RlcRegisters, layout: AmdGfx11RlcLayout) !AmdGfx11RlcResumePlan {
    if (layout.address == 0 or (layout.address & 3) != 0 or layout.address >= (@as(u64, 1) << 48) or layout.dwords != 960)
        return error.InvalidAmdGfx11RlcResumePlan;
    return .{ .registers = registers, .address = layout.address, .dwords = layout.dwords };
}

fn rollbackAmdGfx11RlcResume(plan: AmdGfx11RlcResumePlan, transaction: *const AmdGfx11RlcResumeTransaction, io: AmdRegisterIo) !void {
    const offsets = [_]u32{ plan.registers.csib_address_high, plan.registers.csib_address_low, plan.registers.csib_length, plan.registers.srm_control };
    var failed = false;
    var index: usize = transaction.applied;
    while (index != 0) {
        index -= 1;
        io.write(io.context, offsets[index], transaction.previous[index]) catch {
            failed = true;
        };
    }
    if (failed) return error.AmdRlcResumeRollbackFailed;
}

pub fn executeAmdGfx11RlcResume(plan: AmdGfx11RlcResumePlan, io: AmdRegisterIo) !AmdGfx11RlcResumeTransaction {
    const offsets = [_]u32{ plan.registers.csib_address_high, plan.registers.csib_address_low, plan.registers.csib_length, plan.registers.srm_control };
    const current_srm = io.read(io.context, plan.registers.srm_control) catch return error.AmdRlcRegisterReadFailed;
    const values = [_]u32{ @truncate(plan.address >> 32), @truncate(plan.address & 0xfffffffc), plan.dwords, current_srm | 3 };
    const masks = [_]u32{ 0x0000ffff, 0xfffffffc, 0xffffffff, 0x00000003 };
    var transaction = AmdGfx11RlcResumeTransaction{ .previous = undefined };
    for (offsets, values, masks, 0..) |offset, value, mask, index| {
        transaction.previous[index] = io.read(io.context, offset) catch {
            rollbackAmdGfx11RlcResume(plan, &transaction, io) catch return error.AmdRlcResumeRollbackFailed;
            return error.AmdRlcRegisterReadFailed;
        };
        transaction.applied += 1;
        io.write(io.context, offset, value) catch {
            rollbackAmdGfx11RlcResume(plan, &transaction, io) catch return error.AmdRlcResumeRollbackFailed;
            return error.AmdRlcRegisterWriteFailed;
        };
        const observed = io.read(io.context, offset) catch {
            rollbackAmdGfx11RlcResume(plan, &transaction, io) catch return error.AmdRlcResumeRollbackFailed;
            return error.AmdRlcRegisterReadFailed;
        };
        if ((observed & mask) != (value & mask)) {
            rollbackAmdGfx11RlcResume(plan, &transaction, io) catch return error.AmdRlcResumeRollbackFailed;
            return error.AmdRlcRegisterReadbackMismatch;
        }
    }
    return transaction;
}

pub const AmdGfx11CpGfxRegisters = struct {
    grbm_gfx_control: u32,
    me_control: u32,
    status: u32,
    wptr_delay: u32,
    rb_vmid: u32,
    rb_control: u32,
    rb_wptr: u32,
    rb_wptr_high: u32,
    rb_rptr_address: u32,
    rb_rptr_address_high: u32,
    wptr_poll_address: u32,
    wptr_poll_address_high: u32,
    rb_base: u32,
    rb_base_high: u32,
    rb_active: u32,
    doorbell_control: u32,
    gfx_doorbell_lower: u32,
    gfx_doorbell_upper: u32,
    mec_doorbell_lower: u32,
    mec_doorbell_upper: u32,
    max_context: u32,
    device_id: u32,
    scratch0: u32,
};

pub const AmdGfx11CuRegisters = struct {
    selector: u32,
    sa_disable: u32,
    user_sa_disable: u32,
    shader_array_config: u32,
    user_shader_array_config: u32,
    rb_disable: u32,
    user_rb_disable: u32,
};
pub const AmdGfx11CuInfo = struct {
    active_count: u32,
    active_sa_mask: u16,
    bitmap: [4][4]u32,
    enabled_rb_mask: u32,
    active_rb_count: u8,
};

pub fn resolveAmdGfx11CuRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdGfx11CuRegisters {
    if (ip.hw_id != amd_hw_id.gfx or ip.instance != 0 or ip.major != 11 or ip.base_count <= 1 or ip.bases[0] == 0 or ip.bases[1] == 0)
        return error.AmdGfx11CuRegisterBaseMissing;
    return .{
        .selector = try resolveAmdRegister(ip.bases[1], 0x2200, register_bar_bytes),
        .sa_disable = try resolveAmdRegister(ip.bases[0], 0x0fe9, register_bar_bytes),
        .user_sa_disable = try resolveAmdRegister(ip.bases[1], 0x5b92, register_bar_bytes),
        .shader_array_config = try resolveAmdRegister(ip.bases[0], 0x100f, register_bar_bytes),
        .user_shader_array_config = try resolveAmdRegister(ip.bases[1], 0x5b90, register_bar_bytes),
        .rb_disable = try resolveAmdRegister(ip.bases[0], 0x13dd, register_bar_bytes),
        .user_rb_disable = try resolveAmdRegister(ip.bases[1], 0x5b94, register_bar_bytes),
    };
}

pub fn decodeAmdGfx11CuInfo(topology: AmdGcInfo, factory_sa_disable: u16, user_sa_disable: u16, factory_wgp_disable: [16]u16, user_wgp_disable: [16]u16, factory_rb_disable: u32, user_rb_disable: u32) !AmdGfx11CuInfo {
    const sa_count = topology.num_shader_engines * topology.num_shader_arrays_per_engine;
    const wgp_count = topology.maxCuPerShaderArray() / 2;
    const rb_count = topology.num_shader_engines * topology.num_rb_per_se;
    if (sa_count == 0 or sa_count > 16 or wgp_count == 0 or wgp_count > 16 or rb_count == 0 or rb_count > 28 or
        topology.num_rb_per_se % topology.num_shader_arrays_per_engine != 0)
        return error.InvalidAmdGfx11CuTopology;
    const sa_limit: u16 = if (sa_count == 16) 0xffff else (@as(u16, 1) << @intCast(sa_count)) - 1;
    const wgp_limit: u16 = if (wgp_count == 16) 0xffff else (@as(u16, 1) << @intCast(wgp_count)) - 1;
    const active_sa = sa_limit & ~(factory_sa_disable | user_sa_disable);
    var result = AmdGfx11CuInfo{ .active_count = 0, .active_sa_mask = active_sa, .bitmap = .{.{0} ** 4} ** 4, .enabled_rb_mask = 0, .active_rb_count = 0 };
    var se: u32 = 0;
    while (se < topology.num_shader_engines) : (se += 1) {
        var sa: u32 = 0;
        while (sa < topology.num_shader_arrays_per_engine) : (sa += 1) {
            const linear = se * topology.num_shader_arrays_per_engine + sa;
            if ((active_sa & (@as(u16, 1) << @intCast(linear))) == 0) continue;
            const active_wgp = wgp_limit & ~(factory_wgp_disable[linear] | user_wgp_disable[linear]);
            var cu_bitmap: u32 = 0;
            var wgp: u32 = 0;
            while (wgp < wgp_count) : (wgp += 1) {
                if ((active_wgp & (@as(u16, 1) << @intCast(wgp))) != 0)
                    cu_bitmap |= @as(u32, 3) << @intCast(wgp * 2);
            }
            result.bitmap[se % 4][sa + (se / 4) * 2] = cu_bitmap;
            result.active_count += @popCount(cu_bitmap);
        }
    }
    if (result.active_count == 0 or result.active_count > topology.num_shader_engines * topology.num_shader_arrays_per_engine * topology.maxCuPerShaderArray())
        return error.InvalidAmdGfx11ActiveCuCount;
    const rb_per_sa = topology.num_rb_per_se / topology.num_shader_arrays_per_engine;
    const rb_per_sa_mask = (@as(u32, 1) << @intCast(rb_per_sa)) - 1;
    var active_rb_by_sa: u32 = 0;
    var sa: u32 = 0;
    while (sa < sa_count) : (sa += 1) {
        if ((active_sa & (@as(u16, 1) << @intCast(sa))) != 0)
            active_rb_by_sa |= rb_per_sa_mask << @intCast(sa * rb_per_sa);
    }
    const rb_limit = (@as(u32, 1) << @intCast(rb_count)) - 1;
    result.enabled_rb_mask = rb_limit & active_rb_by_sa & ~(factory_rb_disable | user_rb_disable);
    result.active_rb_count = @intCast(@popCount(result.enabled_rb_mask));
    if (result.active_rb_count == 0) return error.InvalidAmdGfx11ActiveRbCount;
    return result;
}

pub fn probeAmdGfx11CuInfo(adapter: *const Adapter, registers: AmdGfx11CuRegisters, topology: AmdGcInfo) !AmdGfx11CuInfo {
    const factory_sa: u16 = @truncate((try adapter.readRegister(registers.sa_disable) >> 8) & 0xffff);
    const user_sa: u16 = @truncate((try adapter.readRegister(registers.user_sa_disable) >> 8) & 0xffff);
    const factory_rb = (try adapter.readRegister(registers.rb_disable) >> 4) & 0x0fffffff;
    const user_rb = (try adapter.readRegister(registers.user_rb_disable) >> 4) & 0x0fffffff;
    var factory_wgp: [16]u16 = .{0} ** 16;
    var user_wgp: [16]u16 = .{0} ** 16;
    errdefer adapter.writeRegister(registers.selector, 0xe0000000) catch {};
    var se: u32 = 0;
    while (se < topology.num_shader_engines) : (se += 1) {
        var sa: u32 = 0;
        while (sa < topology.num_shader_arrays_per_engine) : (sa += 1) {
            const linear = se * topology.num_shader_arrays_per_engine + sa;
            try adapter.writeRegister(registers.selector, 0x40000000 | (se << 16) | (sa << 8));
            factory_wgp[linear] = @truncate((try adapter.readRegister(registers.shader_array_config) >> 16) & 0xffff);
            user_wgp[linear] = @truncate((try adapter.readRegister(registers.user_shader_array_config) >> 16) & 0xffff);
        }
    }
    try adapter.writeRegister(registers.selector, 0xe0000000);
    return decodeAmdGfx11CuInfo(topology, factory_sa, user_sa, factory_wgp, user_wgp, factory_rb, user_rb);
}

comptime {
    const gfx_ip = AmdIp{
        .hw_id = amd_hw_id.gfx,
        .major = 11,
        .base_count = 2,
        .bases = .{ 0x100, 0x500 } ++ .{0} ** 6,
    };
    const registers = resolveAmdGfx11CuRegisters(&gfx_ip, 0x20000) catch
        @compileError("GFX11 CU register resolution failed");
    if (registers.selector != 0x9c00 or registers.sa_disable != 0x43a4 or
        registers.user_sa_disable != 0x18248 or registers.shader_array_config != 0x443c or
        registers.user_shader_array_config != 0x18240 or registers.rb_disable != 0x5374 or
        registers.user_rb_disable != 0x18250)
        @compileError("GFX11 CU register offsets mismatch");

    const topology = AmdGcInfo{
        .version_minor = 2,
        .num_shader_engines = 6,
        .num_shader_arrays_per_engine = 2,
        .num_wgp0_per_sa = 4,
        .num_wgp1_per_sa = 4,
        .num_rb_per_se = 2,
        .num_tcc_blocks = 16,
        .gs_vgt_table_depth = 32,
        .gs_prim_buffer_depth = 64,
        .double_offchip_lds_buf = 512,
        .wave_front_size = 32,
    };
    var factory_wgp = [_]u16{0} ** 16;
    var user_wgp = [_]u16{0} ** 16;
    factory_wgp[0] = 1;
    user_wgp[1] = 2;
    const cu = decodeAmdGfx11CuInfo(topology, @as(u16, 1) << 11, 0, factory_wgp, user_wgp, 1, 0) catch
        @compileError("GFX11 CU harvesting decode failed");
    if (cu.active_count != 172 or cu.active_sa_mask != 0x07ff or
        cu.bitmap[0][0] != 0xfffc or cu.bitmap[0][1] != 0xfff3 or
        cu.bitmap[1][3] != 0 or cu.enabled_rb_mask != 0x7fe or cu.active_rb_count != 10)
        @compileError("GFX11 active CU bitmap mismatch");
}

pub fn resolveAmdGfx11CpGfxRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdGfx11CpGfxRegisters {
    if (ip.hw_id != amd_hw_id.gfx or ip.instance != 0 or ip.major != 11 or ip.base_count <= 1 or ip.bases[1] == 0)
        return error.AmdGfx11CpRegisterBaseMissing;
    const base = ip.bases[1];
    return .{
        .grbm_gfx_control = try resolveAmdRegister(base, 0x0900, register_bar_bytes),
        .me_control = try resolveAmdRegister(base, 0x0803, register_bar_bytes),
        .status = try resolveAmdRegister(base, 0x0f40, register_bar_bytes),
        .wptr_delay = try resolveAmdRegister(base, 0x0f61, register_bar_bytes),
        .rb_vmid = try resolveAmdRegister(base, 0x1df1, register_bar_bytes),
        .rb_control = try resolveAmdRegister(base, 0x1de1, register_bar_bytes),
        .rb_wptr = try resolveAmdRegister(base, 0x1df4, register_bar_bytes),
        .rb_wptr_high = try resolveAmdRegister(base, 0x1df5, register_bar_bytes),
        .rb_rptr_address = try resolveAmdRegister(base, 0x1de3, register_bar_bytes),
        .rb_rptr_address_high = try resolveAmdRegister(base, 0x1de4, register_bar_bytes),
        .wptr_poll_address = try resolveAmdRegister(base, 0x1e8b, register_bar_bytes),
        .wptr_poll_address_high = try resolveAmdRegister(base, 0x1e8c, register_bar_bytes),
        .rb_base = try resolveAmdRegister(base, 0x1de0, register_bar_bytes),
        .rb_base_high = try resolveAmdRegister(base, 0x1e51, register_bar_bytes),
        .rb_active = try resolveAmdRegister(base, 0x1f40, register_bar_bytes),
        .doorbell_control = try resolveAmdRegister(base, 0x1e8d, register_bar_bytes),
        .gfx_doorbell_lower = try resolveAmdRegister(base, 0x1dfa, register_bar_bytes),
        .gfx_doorbell_upper = try resolveAmdRegister(base, 0x1dfb, register_bar_bytes),
        .mec_doorbell_lower = try resolveAmdRegister(base, 0x1dfc, register_bar_bytes),
        .mec_doorbell_upper = try resolveAmdRegister(base, 0x1dfd, register_bar_bytes),
        .max_context = try resolveAmdRegister(base, 0x1e4e, register_bar_bytes),
        .device_id = try resolveAmdRegister(base, 0x1deb, register_bar_bytes),
        .scratch0 = try resolveAmdRegister(base, 0x2040, register_bar_bytes),
    };
}

pub fn prepareAmdGfx11GfxRingClearState(command: AmdGfx11GfxRingResources, rlc: AmdGfx11RlcResources) !void {
    if (command.allocator == null or rlc.allocator == null or command.ring == 0 or command.pointers == 0 or rlc.page == 0)
        return error.InvalidAmdGfx11GfxRingResources;
    const source: *const [1024]u32 = @ptrFromInt(rlc.page);
    const ring: *[1024]u32 = @ptrFromInt(command.ring);
    const pointers: *[512]u64 = @ptrFromInt(command.pointers);
    @memcpy(ring[0..960], source[0..960]);
    @memset(ring[960..], 0);
    @memset(pointers, 0);
    asm volatile ("mfence" ::: .{ .memory = true });
}

pub const AmdGfx11CpGfxPlan = struct {
    registers: AmdGfx11CpGfxRegisters,
    layout: AmdGfx11GfxRingLayout,
    doorbell: AmdGfx11Doorbell,
};

pub fn planAmdGfx11CpGfxResume(registers: AmdGfx11CpGfxRegisters, layout: AmdGfx11GfxRingLayout) !AmdGfx11CpGfxPlan {
    if (layout.ring == 0 or layout.rptr == 0 or layout.wptr == 0 or layout.ring_dwords != 1024 or
        (layout.ring & 255) != 0 or (layout.rptr & 7) != 0 or layout.wptr != layout.rptr + 8 or
        layout.doorbell_index != 0x116 or layout.doorbell_byte_offset != 0x458)
        return error.InvalidAmdGfx11CpGfxPlan;
    return .{
        .registers = registers,
        .layout = layout,
        .doorbell = .{ .assignment = 0x08b, .register_index = 0x116, .byte_offset = 0x458 },
    };
}

pub const AmdGfx11CpGfxTransaction = struct {
    offsets: [20]u32 = .{0} ** 20,
    values: [20]u32 = .{0} ** 20,
    count: u5 = 0,
};

fn rollbackAmdGfx11CpGfx(plan: AmdGfx11CpGfxPlan, transaction: *const AmdGfx11CpGfxTransaction, io: AmdRegisterIo) !void {
    var failed = false;
    const current = io.read(io.context, plan.registers.me_control) catch 0;
    io.write(io.context, plan.registers.me_control, current | 0x14000000) catch {
        failed = true;
    };
    var index: usize = transaction.count;
    while (index != 0) {
        index -= 1;
        if (transaction.offsets[index] == plan.registers.me_control) continue;
        io.write(io.context, transaction.offsets[index], transaction.values[index]) catch {
            failed = true;
        };
    }
    io.write(io.context, plan.registers.grbm_gfx_control, 0) catch {
        failed = true;
    };
    if (failed) return error.AmdCpGfxRollbackFailed;
}

pub fn activateAmdGfx11CpGfx(
    plan: AmdGfx11CpGfxPlan,
    pointers: *[512]u64,
    poll_limit: u32,
    io: AmdRegisterIo,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or @atomicLoad(u64, &pointers[0], .seq_cst) != 0 or @atomicLoad(u64, &pointers[1], .seq_cst) != 0)
        return error.InvalidAmdCpGfxActivation;
    const initial_me = io.read(io.context, plan.registers.me_control) catch return error.AmdCpGfxRegisterReadFailed;
    if ((initial_me & 0x14000000) != 0x14000000 or try io.read(io.context, plan.registers.grbm_gfx_control) != 0)
        return error.AmdCpGfxNotHalted;
    const rb_base = plan.layout.ring >> 8;
    const writes = [_]AmdRegisterWrite{
        .{ .offset = plan.registers.gfx_doorbell_lower, .value = 0x458 },
        .{ .offset = plan.registers.gfx_doorbell_upper, .value = 0x7f8 },
        .{ .offset = plan.registers.mec_doorbell_lower, .value = 0 },
        .{ .offset = plan.registers.mec_doorbell_upper, .value = 0x450 },
        .{ .offset = plan.registers.wptr_delay, .value = 0 },
        .{ .offset = plan.registers.rb_vmid, .value = 0 },
        .{ .offset = plan.registers.rb_control, .value = 0x00000709 },
        .{ .offset = plan.registers.rb_wptr, .value = 0 },
        .{ .offset = plan.registers.rb_wptr_high, .value = 0 },
        .{ .offset = plan.registers.rb_rptr_address, .value = @truncate(plan.layout.rptr) },
        .{ .offset = plan.registers.rb_rptr_address_high, .value = @truncate((plan.layout.rptr >> 32) & 0xffff) },
        .{ .offset = plan.registers.wptr_poll_address, .value = @truncate(plan.layout.wptr) },
        .{ .offset = plan.registers.wptr_poll_address_high, .value = @truncate(plan.layout.wptr >> 32) },
        .{ .offset = plan.registers.rb_base, .value = @truncate(rb_base) },
        .{ .offset = plan.registers.rb_base_high, .value = @truncate(rb_base >> 32) },
        .{ .offset = plan.registers.rb_active, .value = 1 },
        .{ .offset = plan.registers.doorbell_control, .value = 0x40000458 },
        .{ .offset = plan.registers.max_context, .value = 7 },
        .{ .offset = plan.registers.device_id, .value = 1 },
        .{ .offset = plan.registers.me_control, .value = initial_me & ~@as(u32, 0x14000000) },
    };
    var transaction = AmdGfx11CpGfxTransaction{};
    for (writes) |write| {
        transaction.offsets[transaction.count] = write.offset;
        transaction.values[transaction.count] = io.read(io.context, write.offset) catch {
            rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
            return error.AmdCpGfxRegisterReadFailed;
        };
        transaction.count += 1;
        io.write(io.context, write.offset, write.value) catch {
            rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
            return error.AmdCpGfxRegisterWriteFailed;
        };
        const observed = io.read(io.context, write.offset) catch {
            rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
            return error.AmdCpGfxRegisterReadFailed;
        };
        if (observed != write.value) {
            rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
            return error.AmdCpGfxRegisterReadbackMismatch;
        }
    }
    var idle_polls: u32 = 0;
    while (idle_polls < poll_limit) : (idle_polls += 1) {
        const status = io.read(io.context, plan.registers.status) catch {
            rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
            return error.AmdCpGfxRegisterReadFailed;
        };
        if (status == 0) break;
        asm volatile ("pause");
    }
    if (idle_polls == poll_limit) {
        rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
        return error.AmdCpGfxIdleTimeout;
    }
    @atomicStore(u64, &pointers[1], 960, .seq_cst);
    asm volatile ("mfence" ::: .{ .memory = true });
    doorbells.write64(doorbells.context, plan.doorbell.byte_offset, 960) catch {
        rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
        return error.AmdCpGfxDoorbellWriteFailed;
    };
    var polls: u32 = 0;
    while (polls < poll_limit) : (polls += 1) {
        if (@atomicLoad(u64, &pointers[0], .seq_cst) == 960) return polls + 1;
        asm volatile ("pause");
    }
    rollbackAmdGfx11CpGfx(plan, &transaction, io) catch return error.AmdCpGfxRollbackFailed;
    return error.AmdCpGfxClearStateTimeout;
}

pub const AmdGfx11CpGfxRingTestPlan = struct {
    packet: [3]u32,
    scratch_offset: u32,
    doorbell_offset: u32 = 0x458,
    initial_wptr: u64 = 960,
    final_wptr: u64 = 963,
};

pub fn planAmdGfx11CpGfxRingTest(plan: AmdGfx11CpGfxPlan) !AmdGfx11CpGfxRingTestPlan {
    const scratch_dword = plan.registers.scratch0 / 4;
    if ((plan.registers.scratch0 & 3) != 0 or scratch_dword < 0xc000 or scratch_dword - 0xc000 > 0xffff or
        plan.doorbell.byte_offset != 0x458)
        return error.InvalidAmdCpGfxRingTestPlan;
    return .{
        .packet = .{ amdPacket3(0x79, 1), scratch_dword - 0xc000, 0xdeadbeef },
        .scratch_offset = plan.registers.scratch0,
    };
}

fn stopAmdGfx11CpGfx(plan: AmdGfx11CpGfxPlan, io: AmdRegisterIo) !void {
    var failed = false;
    const control = io.read(io.context, plan.registers.me_control) catch return error.AmdCpGfxStopFailed;
    io.write(io.context, plan.registers.me_control, control | 0x14000000) catch {
        failed = true;
    };
    io.write(io.context, plan.registers.rb_active, 0) catch {
        failed = true;
    };
    if (failed) return error.AmdCpGfxStopFailed;
}

pub fn testAmdGfx11CpGfxRing(
    plan: AmdGfx11CpGfxPlan,
    test_plan: AmdGfx11CpGfxRingTestPlan,
    ring: *[1024]u32,
    pointers: *[512]u64,
    poll_limit: u32,
    io: AmdRegisterIo,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or test_plan.initial_wptr != 960 or test_plan.final_wptr != 963 or
        @atomicLoad(u64, &pointers[0], .seq_cst) != test_plan.initial_wptr or
        @atomicLoad(u64, &pointers[1], .seq_cst) != test_plan.initial_wptr)
        return error.AmdCpGfxRingNotIdle;
    io.write(io.context, test_plan.scratch_offset, 0xcafedead) catch return error.AmdCpGfxRingTestRegisterWriteFailed;
    if (io.read(io.context, test_plan.scratch_offset) catch 0 != 0xcafedead)
        return error.AmdCpGfxRingTestRegisterReadbackMismatch;
    @memcpy(ring[960..963], &test_plan.packet);
    @atomicStore(u64, &pointers[1], test_plan.final_wptr, .seq_cst);
    asm volatile ("mfence" ::: .{ .memory = true });
    doorbells.write64(doorbells.context, test_plan.doorbell_offset, test_plan.final_wptr) catch {
        stopAmdGfx11CpGfx(plan, io) catch return error.AmdCpGfxStopFailed;
        return error.AmdCpGfxRingTestDoorbellFailed;
    };
    var polls: u32 = 0;
    while (polls < poll_limit) : (polls += 1) {
        const scratch = io.read(io.context, test_plan.scratch_offset) catch {
            stopAmdGfx11CpGfx(plan, io) catch return error.AmdCpGfxStopFailed;
            return error.AmdCpGfxRingTestRegisterReadFailed;
        };
        if (scratch == 0xdeadbeef and @atomicLoad(u64, &pointers[0], .seq_cst) == test_plan.final_wptr)
            return polls + 1;
        asm volatile ("pause");
    }
    stopAmdGfx11CpGfx(plan, io) catch return error.AmdCpGfxStopFailed;
    return error.AmdCpGfxRingTestTimeout;
}

pub const AmdGfx11SubmissionFrame = struct {
    dwords: [12]u32,
    vmid: u4,
    ib_dwords: u20,
    sequence: u64,
};

pub fn encodeAmdGfx11SubmissionFrame(vmid: u8, ib_address: u64, ib_dwords: u32, fence_address: u64, sequence: u64) !AmdGfx11SubmissionFrame {
    const gpu_limit: u64 = @as(u64, 1) << 48;
    if (vmid == 0 or vmid > 7) return error.AmdGfxSubmissionVmidReserved;
    if (ib_address == 0 or (ib_address & 3) != 0 or ib_address >= gpu_limit or
        ib_dwords == 0 or ib_dwords > 0x000fffff)
        return error.InvalidAmdGfxIndirectBuffer;
    if (fence_address == 0 or (fence_address & 7) != 0 or fence_address >= gpu_limit or sequence == 0)
        return error.InvalidAmdGfxSubmissionFence;
    return .{
        .vmid = @intCast(vmid),
        .ib_dwords = @intCast(ib_dwords),
        .sequence = sequence,
        .dwords = .{
            amdPacket3(0x3f, 2),
            @truncate(ib_address),
            @truncate(ib_address >> 32),
            ib_dwords | (@as(u32, vmid) << 24),
            amdPacket3(0x49, 6),
            0x06603514,
            0x40000000,
            @truncate(fence_address),
            @truncate(fence_address >> 32),
            @truncate(sequence),
            @truncate(sequence >> 32),
            0,
        },
    };
}

pub const AmdGfx11SubmissionQueue = struct {
    next_sequence: u64 = 1,
    committed_wptr: u64 = 963,
    stopped: bool = false,
};

pub const AmdGfx11SubmissionResult = struct { sequence: u64, final_wptr: u64, polls: u32 };

pub fn submitAmdGfx11IndirectBuffer(
    plan: AmdGfx11CpGfxPlan,
    queue: *AmdGfx11SubmissionQueue,
    ring: *[1024]u32,
    pointers: *[512]u64,
    fence: *u64,
    fence_address: u64,
    vmid: u8,
    ib_address: u64,
    ib_dwords: u32,
    poll_limit: u32,
    io: AmdRegisterIo,
    doorbells: AmdDoorbellIo,
) !AmdGfx11SubmissionResult {
    if (queue.stopped) return error.AmdGfxSubmissionQueueStopped;
    if (poll_limit == 0 or queue.next_sequence == 0 or queue.committed_wptr > std.math.maxInt(u64) - 12)
        return error.InvalidAmdGfxSubmissionQueue;
    const rptr = @atomicLoad(u64, &pointers[0], .seq_cst);
    const wptr = @atomicLoad(u64, &pointers[1], .seq_cst);
    if (rptr != queue.committed_wptr or wptr != queue.committed_wptr) return error.AmdGfxSubmissionRingNotIdle;
    const sequence = queue.next_sequence;
    const frame = try encodeAmdGfx11SubmissionFrame(vmid, ib_address, ib_dwords, fence_address, sequence);
    @atomicStore(u64, fence, 0, .seq_cst);
    for (frame.dwords, 0..) |dword, index| ring[@intCast((wptr + index) & 1023)] = dword;
    const final_wptr = wptr + frame.dwords.len;
    asm volatile ("mfence" ::: .{ .memory = true });
    @atomicStore(u64, &pointers[1], final_wptr, .seq_cst);
    asm volatile ("mfence" ::: .{ .memory = true });
    doorbells.write64(doorbells.context, plan.doorbell.byte_offset, final_wptr) catch {
        queue.stopped = true;
        stopAmdGfx11CpGfx(plan, io) catch return error.AmdCpGfxStopFailed;
        return error.AmdGfxSubmissionDoorbellFailed;
    };
    var polls: u32 = 0;
    while (polls < poll_limit) : (polls += 1) {
        if (@atomicLoad(u64, fence, .seq_cst) == sequence and
            @atomicLoad(u64, &pointers[0], .seq_cst) == final_wptr) {
            queue.committed_wptr = final_wptr;
            queue.next_sequence +%= 1;
            if (queue.next_sequence == 0) queue.next_sequence = 1;
            return .{ .sequence = sequence, .final_wptr = final_wptr, .polls = polls + 1 };
        }
        asm volatile ("pause");
    }
    queue.stopped = true;
    stopAmdGfx11CpGfx(plan, io) catch return error.AmdCpGfxStopFailed;
    return error.AmdGfxSubmissionTimeout;
}

pub fn amdGfx11MesIsHalted(control: u32) bool {
    const reset = control & 0x00030000;
    const active = control & 0x0c000000;
    return reset == 0x00030000 and active == 0 and (control & 0x40000000) != 0;
}

pub const AmdGfx11MesLoadPlan = struct {
    writes: [11]AmdRegisterWrite,
    count: u8 = 11,
    pipe: u1,
};

pub fn planAmdGfx11MesLoad(
    kind: AmdGfx11QueueKind,
    firmware: AmdMesFirmware,
    ucode_gpu_address: u64,
    data_gpu_address: u64,
    registers: AmdGfx11MesRegisters,
    halted: bool,
) !AmdGfx11MesLoadPlan {
    if (!halted) return error.AmdMesMustBeHaltedBeforeLoad;
    if ((firmware.ucode_start & 3) != 0 or firmware.ucode.len > 0x200000 or firmware.data.len > 0x80000 or
        ucode_gpu_address == 0 or data_gpu_address == 0 or (ucode_gpu_address & 4095) != 0 or (data_gpu_address & 4095) != 0)
        return error.InvalidAmdMesLoadPlan;
    const pipe: u1 = if (kind == .scheduler) 0 else 1;
    const selector: u32 = (@as(u32, pipe) & 3) | (3 << 2); // ME=3, queue=0, VMID=0.
    const pc = firmware.ucode_start >> 2;
    return .{
        .pipe = pipe,
        .writes = .{
            .{ .offset = registers.grbm_gfx_cntl, .value = selector },
            .{ .offset = registers.ic_base_cntl, .value = 0 },
            .{ .offset = registers.program_counter_low, .value = @truncate(pc) },
            .{ .offset = registers.program_counter_high, .value = @truncate(pc >> 32) },
            .{ .offset = registers.instruction_base_low, .value = @truncate(ucode_gpu_address) },
            .{ .offset = registers.instruction_base_high, .value = @truncate(ucode_gpu_address >> 32) },
            .{ .offset = registers.instruction_bound_low, .value = 0x1fffff },
            .{ .offset = registers.data_base_low, .value = @truncate(data_gpu_address) },
            .{ .offset = registers.data_base_high, .value = @truncate(data_gpu_address >> 32) },
            .{ .offset = registers.data_bound_low, .value = 0x7ffff },
            .{ .offset = registers.grbm_gfx_cntl, .value = 0 },
        },
    };
}
pub const AmdGfx11MesLoadTransaction = struct {
    offsets: [9]u32 = .{0} ** 9,
    values: [9]u32 = .{0} ** 9,
    applied: u8 = 0,
    pipe: u1,
};

fn rollbackAmdGfx11MesLoad(plan: AmdGfx11MesLoadPlan, transaction: *const AmdGfx11MesLoadTransaction, io: AmdRegisterIo) !void {
    var failed = false;
    var index: usize = transaction.applied;
    while (index != 0) {
        index -= 1;
        io.write(io.context, transaction.offsets[index], transaction.values[index]) catch {
            failed = true;
        };
    }
    io.write(io.context, plan.writes[0].offset, 0) catch {
        failed = true;
    };
    if (failed) return error.AmdMesLoadRollbackFailed;
}

pub fn restoreAmdGfx11MesLoad(plan: AmdGfx11MesLoadPlan, transaction: AmdGfx11MesLoadTransaction, io: AmdRegisterIo) !void {
    if (transaction.applied != 9 or transaction.pipe != plan.pipe or try io.read(io.context, plan.writes[0].offset) != 0)
        return error.InvalidAmdMesLoadRestore;
    io.write(io.context, plan.writes[0].offset, plan.writes[0].value) catch return error.AmdMesRegisterWriteFailed;
    if (try io.read(io.context, plan.writes[0].offset) != plan.writes[0].value) {
        io.write(io.context, plan.writes[0].offset, 0) catch return error.AmdMesLoadRollbackFailed;
        return error.AmdMesRegisterReadbackMismatch;
    }
    try rollbackAmdGfx11MesLoad(plan, &transaction, io);
}

pub fn executeAmdGfx11MesLoad(plan: AmdGfx11MesLoadPlan, io: AmdRegisterIo) !AmdGfx11MesLoadTransaction {
    if (plan.count != 11 or plan.writes[0].offset != plan.writes[10].offset or plan.writes[10].value != 0)
        return error.InvalidAmdMesLoadTransaction;
    if (try io.read(io.context, plan.writes[0].offset) != 0) return error.AmdMesGrbmSelectorBusy;
    io.write(io.context, plan.writes[0].offset, plan.writes[0].value) catch return error.AmdMesRegisterWriteFailed;
    if (try io.read(io.context, plan.writes[0].offset) != plan.writes[0].value) {
        io.write(io.context, plan.writes[0].offset, 0) catch return error.AmdMesLoadRollbackFailed;
        return error.AmdMesRegisterReadbackMismatch;
    }
    var transaction = AmdGfx11MesLoadTransaction{ .pipe = plan.pipe };
    for (plan.writes[1..10], 0..) |write, index| {
        transaction.offsets[index] = write.offset;
        transaction.values[index] = io.read(io.context, write.offset) catch {
            rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
            return error.AmdMesRegisterReadFailed;
        };
        transaction.applied += 1;
        io.write(io.context, write.offset, write.value) catch {
            rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
            return error.AmdMesRegisterWriteFailed;
        };
        const observed = io.read(io.context, write.offset) catch {
            rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
            return error.AmdMesRegisterReadFailed;
        };
        if (observed != write.value) {
            rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
            return error.AmdMesRegisterReadbackMismatch;
        }
    }
    io.write(io.context, plan.writes[10].offset, 0) catch {
        rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
        return error.AmdMesRegisterWriteFailed;
    };
    const selector = io.read(io.context, plan.writes[10].offset) catch {
        rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
        return error.AmdMesRegisterReadFailed;
    };
    if (selector != 0) {
        rollbackAmdGfx11MesLoad(plan, &transaction, io) catch return error.AmdMesLoadRollbackFailed;
        return error.AmdMesRegisterReadbackMismatch;
    }
    return transaction;
}
pub const AmdGfx11MesActivation = struct { scheduler_version: u32, kiq_version: u32, polls: u32 };

fn readAmdGfx11MesVersions(registers: AmdGfx11MesRegisters, io: AmdRegisterIo) ![2]u32 {
    var versions = [2]u32{ 0, 0 };
    inline for (0..2) |pipe| {
        try io.write(io.context, registers.grbm_gfx_cntl, @as(u32, pipe) | (3 << 2));
        versions[pipe] = try io.read(io.context, registers.gp3_low);
    }
    try io.write(io.context, registers.grbm_gfx_cntl, 0);
    return versions;
}

fn restoreAmdGfx11MesHalted(registers: AmdGfx11MesRegisters, halted_control: u32, io: AmdRegisterIo) !void {
    var failed = false;
    io.write(io.context, registers.mes_control, halted_control) catch {
        failed = true;
    };
    io.write(io.context, registers.grbm_gfx_cntl, 0) catch {
        failed = true;
    };
    if (failed) return error.AmdMesActivationRollbackFailed;
    const observed = io.read(io.context, registers.mes_control) catch return error.AmdMesActivationRollbackFailed;
    if (!amdGfx11MesIsHalted(observed)) return error.AmdMesActivationRollbackFailed;
}

pub fn haltAmdGfx11Mes(registers: AmdGfx11MesRegisters, io: AmdRegisterIo) !void {
    try io.write(io.context, registers.mes_control, 0x40030000);
    try io.write(io.context, registers.grbm_gfx_cntl, 0);
    if (!amdGfx11MesIsHalted(try io.read(io.context, registers.mes_control))) return error.AmdMesHaltReadbackMismatch;
}

pub fn activateAmdGfx11Mes(
    registers: AmdGfx11MesRegisters,
    scheduler_start: u64,
    kiq_start: u64,
    poll_limit: u32,
    io: AmdRegisterIo,
) !AmdGfx11MesActivation {
    if (poll_limit == 0 or (scheduler_start & 3) != 0 or (kiq_start & 3) != 0) return error.InvalidAmdMesActivation;
    const halted_control = try io.read(io.context, registers.mes_control);
    if (!amdGfx11MesIsHalted(halted_control) or try io.read(io.context, registers.grbm_gfx_cntl) != 0)
        return error.AmdMesActivationPreconditionFailed;
    const starts = .{ scheduler_start, kiq_start };
    inline for (starts, 0..) |start, pipe| {
        const selector: u32 = @as(u32, @intCast(pipe)) | (3 << 2);
        io.write(io.context, registers.grbm_gfx_cntl, selector) catch {
            restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
            return error.AmdMesRegisterWriteFailed;
        };
        const pc = start >> 2;
        io.write(io.context, registers.program_counter_low, @truncate(pc)) catch {
            restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
            return error.AmdMesRegisterWriteFailed;
        };
        io.write(io.context, registers.program_counter_high, @truncate(pc >> 32)) catch {
            restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
            return error.AmdMesRegisterWriteFailed;
        };
    }
    io.write(io.context, registers.grbm_gfx_cntl, 0) catch {
        restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
        return error.AmdMesRegisterWriteFailed;
    };
    io.write(io.context, registers.mes_control, 0x0c000000) catch {
        restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
        return error.AmdMesRegisterWriteFailed;
    };
    const active = io.read(io.context, registers.mes_control) catch {
        restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
        return error.AmdMesRegisterReadFailed;
    };
    if ((active & 0x4c030000) != 0x0c000000) {
        restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
        return error.AmdMesActivationReadbackMismatch;
    }
    var polls: u32 = 0;
    while (polls < poll_limit) : (polls += 1) {
        const versions = readAmdGfx11MesVersions(registers, io) catch {
            restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
            return error.AmdMesVersionReadFailed;
        };
        if (versions[0] != 0 and versions[1] != 0)
            return .{ .scheduler_version = versions[0], .kiq_version = versions[1], .polls = polls + 1 };
        asm volatile ("pause");
    }
    restoreAmdGfx11MesHalted(registers, halted_control, io) catch return error.AmdMesActivationRollbackFailed;
    return error.AmdMesActivationTimeout;
}
pub const AmdGfx11KiqPlan = struct { writes: [17]AmdRegisterWrite, count: u8 = 17 };

pub fn planAmdGfx11KiqHqd(registers: AmdGfx11MesRegisters, mqd: *const [512]u32) !AmdGfx11KiqPlan {
    if (mqd[0] != 0xc0310800 or mqd[128] == 0 or mqd[136] == 0 or mqd[143] == 0 or
        (mqd[143] & 0x40000000) == 0 or mqd[130] != 0)
        return error.InvalidAmdGfx11KiqMqd;
    return .{
        .writes = .{
            .{ .offset = registers.grbm_gfx_cntl, .value = 0x0d }, // ME3/pipe1/queue0
            .{ .offset = registers.hqd_active, .value = 0 },
            .{ .offset = registers.hqd_doorbell_control, .value = 0 },
            .{ .offset = registers.hqd_vmid, .value = mqd[131] },
            .{ .offset = registers.mqd_base_low, .value = mqd[128] },
            .{ .offset = registers.mqd_base_high, .value = mqd[129] },
            .{ .offset = registers.mqd_control, .value = mqd[162] },
            .{ .offset = registers.hqd_pq_base_low, .value = mqd[136] },
            .{ .offset = registers.hqd_pq_base_high, .value = mqd[137] },
            .{ .offset = registers.hqd_rptr_report_low, .value = mqd[139] },
            .{ .offset = registers.hqd_rptr_report_high, .value = mqd[140] },
            .{ .offset = registers.hqd_pq_control, .value = mqd[145] },
            .{ .offset = registers.hqd_wptr_poll_low, .value = mqd[141] },
            .{ .offset = registers.hqd_wptr_poll_high, .value = mqd[142] },
            .{ .offset = registers.hqd_persistent_state, .value = mqd[132] },
            .{ .offset = registers.hqd_doorbell_control, .value = mqd[143] },
            .{ .offset = registers.hqd_active, .value = 1 },
        },
    };
}

pub const AmdGfx11KiqTransaction = struct {
    offsets: [14]u32 = .{0} ** 14,
    values: [14]u32 = .{0} ** 14,
    count: u8 = 0,
};

pub fn restoreAmdGfx11Kiq(plan: AmdGfx11KiqPlan, transaction: *const AmdGfx11KiqTransaction, io: AmdRegisterIo) !void {
    var failed = false;
    var index: usize = transaction.count;
    while (index != 0) {
        index -= 1;
        io.write(io.context, transaction.offsets[index], transaction.values[index]) catch {
            failed = true;
        };
    }
    io.write(io.context, plan.writes[0].offset, 0) catch {
        failed = true;
    };
    if (failed) return error.AmdKiqRollbackFailed;
}

pub fn activateAmdGfx11Kiq(plan: AmdGfx11KiqPlan, io: AmdRegisterIo) !AmdGfx11KiqTransaction {
    if (plan.count != 17 or plan.writes[0].value != 0x0d or plan.writes[16].offset != plan.writes[1].offset or plan.writes[16].value != 1)
        return error.InvalidAmdKiqTransaction;
    if (try io.read(io.context, plan.writes[0].offset) != 0) return error.AmdMesGrbmSelectorBusy;
    io.write(io.context, plan.writes[0].offset, plan.writes[0].value) catch return error.AmdKiqRegisterWriteFailed;
    if (try io.read(io.context, plan.writes[0].offset) != plan.writes[0].value) {
        io.write(io.context, plan.writes[0].offset, 0) catch return error.AmdKiqRollbackFailed;
        return error.AmdKiqRegisterReadbackMismatch;
    }
    var transaction = AmdGfx11KiqTransaction{};
    for (plan.writes[1..], 0..) |write, write_index| {
        var found: ?usize = null;
        for (transaction.offsets[0..transaction.count], 0..) |offset, index| if (offset == write.offset) {
            found = index;
            break;
        };
        if (found == null) {
            if (transaction.count == transaction.offsets.len) return error.AmdKiqSnapshotFull;
            transaction.offsets[transaction.count] = write.offset;
            transaction.values[transaction.count] = io.read(io.context, write.offset) catch {
                restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
                return error.AmdKiqRegisterReadFailed;
            };
            transaction.count += 1;
        }
        io.write(io.context, write.offset, write.value) catch {
            restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
            return error.AmdKiqRegisterWriteFailed;
        };
        const observed = io.read(io.context, write.offset) catch {
            restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
            return error.AmdKiqRegisterReadFailed;
        };
        if (observed != write.value) {
            restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
            return error.AmdKiqRegisterReadbackMismatch;
        }
        _ = write_index;
    }
    io.write(io.context, plan.writes[0].offset, 0) catch {
        restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
        return error.AmdKiqRegisterWriteFailed;
    };
    if (try io.read(io.context, plan.writes[0].offset) != 0) {
        restoreAmdGfx11Kiq(plan, &transaction, io) catch return error.AmdKiqRollbackFailed;
        return error.AmdKiqRegisterReadbackMismatch;
    }
    return transaction;
}

pub const AmdDoorbellIo = struct {
    context: *anyopaque,
    write64: *const fn (*anyopaque, u32, u64) anyerror!void,
};

pub const AmdGfx11DoorbellTransport = struct {
    aperture: pci.Bar,
    expected_offset: u32,
    uncached: bool = false,
    authorized: bool = false,
    armed: bool = false,

    pub fn authorize(self: *AmdGfx11DoorbellTransport, doorbell: AmdGfx11Doorbell) !void {
        if (self.authorized or self.armed or !self.uncached or self.aperture.address == 0 or
            (self.aperture.address & 4095) != 0 or self.aperture.size < 8 or
            doorbell.byte_offset != self.expected_offset or (doorbell.byte_offset & 7) != 0 or
            @as(u64, doorbell.byte_offset) > self.aperture.size - 8)
            return error.AmdDoorbellAuthorizationRejected;
        self.authorized = true;
    }

    pub fn arm(self: *AmdGfx11DoorbellTransport) !void {
        if (!self.authorized or !self.uncached or self.armed) return error.AmdDoorbellTransportNotReady;
        self.armed = true;
    }

    pub fn disarm(self: *AmdGfx11DoorbellTransport) void {
        self.armed = false;
    }

    pub fn io(self: *AmdGfx11DoorbellTransport) AmdDoorbellIo {
        return .{ .context = self, .write64 = &write64 };
    }

    fn write64(context: *anyopaque, offset: u32, value: u64) !void {
        const self: *AmdGfx11DoorbellTransport = @ptrCast(@alignCast(context));
        if (!self.armed or offset != self.expected_offset or @as(u64, offset) > self.aperture.size - 8)
            return error.AmdDoorbellTransportDisarmed;
        const target: *volatile u64 = @ptrFromInt(self.aperture.address + offset);
        target.* = value;
    }
};

pub const AmdGfx11KiqTestPlan = struct {
    packet: [5]u32,
    scratch_offset: u32,
    doorbell_offset: u32,
    initial_value: u32 = 0xcafedead,
    completion_value: u32 = 0xdeadbeef,
};

pub fn planAmdGfx11KiqTest(registers: AmdGfx11MesRegisters, doorbell: AmdGfx11Doorbell) !AmdGfx11KiqTestPlan {
    if ((registers.scratch0 & 3) != 0 or (doorbell.byte_offset & 7) != 0)
        return error.InvalidAmdKiqTestAddress;
    // Linux gfx_v11_0_ring_emit_wreg() for KIQ: PACKET3 WRITE_DATA,
    // no address increment, register address low/high, then the value.
    return .{
        .packet = .{ 0xc0033700, 1 << 16, registers.scratch0 >> 2, 0, 0xdeadbeef },
        .scratch_offset = registers.scratch0,
        .doorbell_offset = doorbell.byte_offset,
    };
}

pub fn testAmdGfx11Kiq(
    plan: AmdGfx11KiqTestPlan,
    ring: *[1024]u32,
    pointers: *[2]u64,
    poll_limit: u32,
    registers: AmdRegisterIo,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or plan.packet[0] != 0xc0033700 or plan.packet[1] != 1 << 16 or
        plan.packet[2] != plan.scratch_offset >> 2 or plan.packet[3] != 0 or
        plan.packet[4] != plan.completion_value)
        return error.InvalidAmdKiqTestPlan;
    try registers.write(registers.context, plan.scratch_offset, plan.initial_value);
    if (try registers.read(registers.context, plan.scratch_offset) != plan.initial_value)
        return error.AmdKiqScratchReadbackMismatch;
    @memset(ring, 0);
    @memcpy(ring[0..plan.packet.len], &plan.packet);
    pointers[0] = 0;
    @atomicStore(u64, &pointers[1], plan.packet.len, .seq_cst);
    doorbells.write64(doorbells.context, plan.doorbell_offset, plan.packet.len) catch
        return error.AmdKiqDoorbellWriteFailed;
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const complete = try registers.read(registers.context, plan.scratch_offset) == plan.completion_value;
        const consumed = @atomicLoad(u64, &pointers[0], .seq_cst) == plan.packet.len;
        if (complete and consumed) return polls;
        asm volatile ("pause");
    }
    return error.AmdKiqTestTimeout;
}

pub const AmdGfx11MesSchedulerMapPlan = struct {
    packet: [12]u32,
    scratch_offset: u32,
    kiq_doorbell_offset: u32,
    initial_wptr: u64 = 5,
    final_wptr: u64 = 17,
};

pub fn planAmdGfx11MesSchedulerMap(
    registers: AmdGfx11MesRegisters,
    scheduler: AmdGfx11QueueAddresses,
    scheduler_doorbell: AmdGfx11Doorbell,
    kiq_doorbell: AmdGfx11Doorbell,
    scheduler_mqd: *const [512]u32,
) !AmdGfx11MesSchedulerMapPlan {
    if ((registers.scratch0 & 3) != 0 or scheduler_mqd[130] != 0 or scheduler_mqd[128] == 0 or
        scheduler.mqd == 0 or (scheduler.mqd & 4095) != 0 or scheduler.wptr == 0 or (scheduler.wptr & 7) != 0 or
        scheduler_doorbell.register_index != 0x16 or kiq_doorbell.register_index != 0x18)
        return error.InvalidAmdMesSchedulerMap;
    // MAP_QUEUES for AMDGPU_RING_TYPE_MES: queue0, pipe0, ME2, engine 5,
    // followed by the same KIQ scratch test used upstream as the completion fence.
    return .{
        .packet = .{
            0xc005a200,
            0x34080000,
            @as(u32, scheduler_doorbell.register_index) << 2,
            @truncate(scheduler.mqd),
            @truncate(scheduler.mqd >> 32),
            @truncate(scheduler.wptr),
            @truncate(scheduler.wptr >> 32),
            0xc0033700,
            1 << 16,
            registers.scratch0 >> 2,
            0,
            0xdeadbeef,
        },
        .scratch_offset = registers.scratch0,
        .kiq_doorbell_offset = kiq_doorbell.byte_offset,
    };
}

pub fn mapAmdGfx11MesScheduler(
    plan: AmdGfx11MesSchedulerMapPlan,
    kiq_ring: *[1024]u32,
    kiq_pointers: *[2]u64,
    poll_limit: u32,
    registers: AmdRegisterIo,
    doorbells: AmdDoorbellIo,
) !u32 {
    if (poll_limit == 0 or plan.initial_wptr + plan.packet.len != plan.final_wptr or
        plan.final_wptr >= kiq_ring.len or plan.packet[0] != 0xc005a200 or
        plan.packet[7] != 0xc0033700 or plan.packet[9] != plan.scratch_offset >> 2)
        return error.InvalidAmdMesSchedulerMapPlan;
    if (@atomicLoad(u64, &kiq_pointers[1], .seq_cst) != plan.initial_wptr or
        @atomicLoad(u64, &kiq_pointers[0], .seq_cst) != plan.initial_wptr)
        return error.AmdKiqRingNotIdle;
    try registers.write(registers.context, plan.scratch_offset, 0xcafedead);
    if (try registers.read(registers.context, plan.scratch_offset) != 0xcafedead)
        return error.AmdKiqScratchReadbackMismatch;
    const start: usize = @intCast(plan.initial_wptr);
    @memcpy(kiq_ring[start .. start + plan.packet.len], &plan.packet);
    @atomicStore(u64, &kiq_pointers[1], plan.final_wptr, .seq_cst);
    doorbells.write64(doorbells.context, plan.kiq_doorbell_offset, plan.final_wptr) catch
        return error.AmdKiqDoorbellWriteFailed;
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const complete = try registers.read(registers.context, plan.scratch_offset) == 0xdeadbeef;
        const consumed = @atomicLoad(u64, &kiq_pointers[0], .seq_cst) == plan.final_wptr;
        if (complete and consumed) return polls;
        asm volatile ("pause");
    }
    return error.AmdMesSchedulerMapTimeout;
}

pub const AmdGfx11PreflightEvidence = struct {
    firmware: bool = false,
    psp: bool = false,
    gart: bool = false,
    gpuvm: bool = false,
    ring: bool = false,
    mqd: bool = false,
    eop: bool = false,
    pointers: bool = false,
    doorbell: bool = false,
};
pub const AmdGfx11Preflight = enum { blocked, resources_ready };

pub fn preflightAmdGfx11Ring(evidence: AmdGfx11PreflightEvidence) AmdGfx11Preflight {
    return if (evidence.firmware and evidence.psp and evidence.gart and evidence.gpuvm and evidence.ring and
        evidence.mqd and evidence.eop and evidence.pointers and evidence.doorbell) .resources_ready else .blocked;
}
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
        const digit: u8 = if (character >= '0' and character <= '9') character - '0' else if (character >= 'a' and character <= 'f') character - 'a' + 10 else if (character >= 'A' and character <= 'F') character - 'A' + 10 else return error.InvalidFirmwareArchive;
        value = value * 16 + digit;
    }
    return value;
}
fn readHexValue(bytes: []const u8) !u16 {
    return @intCast(try readHex(bytes));
}
fn findByte(bytes: []const u8, wanted: u8) ?usize {
    for (bytes, 0..) |byte, index| if (byte == wanted) return index;
    return null;
}

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
        const block: FirmwareBlock = if (equal(name, "security")) .security else if (equal(name, "management")) .management else if (equal(name, "memory")) .memory else if (equal(name, "graphics")) .graphics else if (equal(name, "dma")) .dma else if (equal(name, "display")) .display else if (equal(name, "media")) .media else if (equal(name, "discovery")) .discovery else if (equal(name, "other")) .other else return error.InvalidFirmwareRequirement;
        const bit = @as(u16, 1) << @intFromEnum(block);
        if ((result.blocks & bit) != 0) return error.DuplicateFirmwareRequirement;
        result.blocks |= bit;
        if (end < value.len and end + 1 == value.len) return error.InvalidFirmwareRequirement;
        offset = if (end < value.len) end + 1 else end;
    }
    return result;
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}
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
fn endsWith(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and equal(value[value.len - suffix.len ..], suffix);
}

pub fn classifyAmdGfxFirmware(name: []const u8) ?AmdGfxFirmwareRole {
    if (endsWith(name, "_pfp.bin")) return .pfp;
    if (endsWith(name, "_me.bin")) return .me;
    if (endsWith(name, "_mec.bin")) return .mec;
    if (endsWith(name, "_rlc.bin") or endsWith(name, "_rlc_1.bin") or endsWith(name, "_rlc_kicker.bin")) return .rlc;
    if (endsWith(name, "_mes1.bin")) return .mes_kiq;
    if (endsWith(name, "_mes.bin") or endsWith(name, "_mes_2.bin")) return .mes_scheduler;
    return null;
}

fn amdFirmwareSlice(image: []const u8, offset: usize, bytes: usize) ![]const u8 {
    if (bytes == 0 or offset > image.len or bytes > image.len - offset) return error.InvalidAmdGfxFirmwarePayload;
    return image[offset .. offset + bytes];
}

pub fn parseAmdCpFirmware(image: []const u8, kind: AmdCpFirmwareKind) !AmdCpFirmware {
    const common = try parseAmdgpuFirmware(image);
    if (common.ip_version_major != 11 or common.ucode_version == 0) return error.InvalidAmdCpFirmwareIdentity;
    if (common.header_version_major == 2) {
        // gfx_firmware_header_v2_0 is the RS64 container used by GFX11.
        if (common.header_version_minor != 0 or image.len < 60 or readLittle32(image, 4) < 60)
            return error.UnsupportedAmdCpFirmwareHeader;
        const instruction_offset = readLittle32(image, 40);
        const instruction_bytes = readLittle32(image, 36);
        if (instruction_offset != readLittle32(image, 24) or instruction_bytes != common.payload.len)
            return error.InconsistentAmdCpRs64Payload;
        const instruction = try amdFirmwareSlice(image, instruction_offset, instruction_bytes);
        const data = try amdFirmwareSlice(image, readLittle32(image, 48), readLittle32(image, 44));
        return .{
            .kind = kind,
            .format = .rs64,
            .ucode_version = common.ucode_version,
            .feature_version = @intCast(readLittle32(image, 32)),
            .instruction = instruction,
            .data = data,
            .start_address = readLittle64(image, 52),
        };
    }
    if (common.header_version_major != 1 or common.header_version_minor != 0 or image.len < 44 or readLittle32(image, 4) < 44)
        return error.UnsupportedAmdCpFirmwareHeader;
    const jump_offset_dwords: usize = readLittle32(image, 36);
    const jump_dwords: usize = readLittle32(image, 40);
    if (kind != .mec and (jump_offset_dwords != 0 or jump_dwords != 0)) return error.UnexpectedAmdCpJumpTable;
    if (kind == .mec) {
        const jump_offset = std.math.mul(usize, jump_offset_dwords, 4) catch return error.InvalidAmdGfxFirmwarePayload;
        const jump_bytes = std.math.mul(usize, jump_dwords, 4) catch return error.InvalidAmdGfxFirmwarePayload;
        if (jump_bytes == 0 or jump_offset > common.payload.len or jump_bytes > common.payload.len - jump_offset)
            return error.InvalidAmdGfxFirmwarePayload;
        if (jump_offset + jump_bytes != common.payload.len) return error.InvalidAmdCpMecJumpTable;
        return .{
            .kind = kind,
            .format = .legacy,
            .ucode_version = common.ucode_version,
            .feature_version = @intCast(readLittle32(image, 32)),
            .instruction = common.payload[0..jump_offset],
            .jump_table = common.payload[jump_offset .. jump_offset + jump_bytes],
        };
    }
    return .{
        .kind = kind,
        .format = .legacy,
        .ucode_version = common.ucode_version,
        .feature_version = @intCast(readLittle32(image, 32)),
        .instruction = common.payload,
    };
}

pub fn parseAmdRlcFirmware(image: []const u8) !AmdRlcFirmware {
    const common = try parseAmdgpuFirmware(image);
    if (common.ip_version_major != 11 or common.ucode_version == 0) return error.InvalidAmdRlcFirmwareIdentity;
    if (common.header_version_major != 2 or image.len < 104 or readLittle32(image, 4) < 104)
        return error.UnsupportedAmdRlcFirmwareHeader;
    if (common.header_version_minor > 5) return error.UnsupportedAmdRlcFirmwareHeader;
    var result = AmdRlcFirmware{
        .ucode_version = common.ucode_version,
        .feature_version = @intCast(readLittle32(image, 32)),
        .header_minor = common.header_version_minor,
    };
    try appendAmdRlcPayload(&result, .rlc_g, common.payload);
    const minor = common.header_version_minor;
    if (minor >= 1) {
        if (image.len < 156 or readLittle32(image, 4) < 156) return error.InvalidAmdRlcFirmwareHeader;
        try appendOptionalAmdRlcPayload(&result, image, .rlc_restore_cntl, 120, 116);
        try appendOptionalAmdRlcPayload(&result, image, .rlc_restore_gpm, 136, 132);
        try appendOptionalAmdRlcPayload(&result, image, .rlc_restore_srm, 152, 148);
    }
    if (minor >= 2) {
        if (image.len < 172 or readLittle32(image, 4) < 172) return error.InvalidAmdRlcFirmwareHeader;
        try appendOptionalAmdRlcPayload(&result, image, .rlc_iram, 160, 156);
        try appendOptionalAmdRlcPayload(&result, image, .rlc_dram_boot, 168, 164);
    }
    if (minor == 3) {
        if (image.len < 204 or readLittle32(image, 4) < 204) return error.InvalidAmdRlcFirmwareHeader;
        try appendOptionalAmdRlcPayload(&result, image, .rlc_p, 184, 180);
        try appendOptionalAmdRlcPayload(&result, image, .rlc_v, 200, 196);
    } else if (minor == 4) {
        if (image.len < 244 or readLittle32(image, 4) < 244) return error.InvalidAmdRlcFirmwareHeader;
        try appendOptionalAmdRlcPayload(&result, image, .global_tap_delays, 208, 204);
        try appendOptionalAmdRlcPayload(&result, image, .se0_tap_delays, 216, 212);
        try appendOptionalAmdRlcPayload(&result, image, .se1_tap_delays, 224, 220);
        try appendOptionalAmdRlcPayload(&result, image, .se2_tap_delays, 232, 228);
        try appendOptionalAmdRlcPayload(&result, image, .se3_tap_delays, 240, 236);
    } else if (minor == 5) {
        if (image.len < 188 or readLittle32(image, 4) < 188) return error.InvalidAmdRlcFirmwareHeader;
        try appendOptionalAmdRlcPayload(&result, image, .rlc_iram_core1, 176, 172);
        try appendOptionalAmdRlcPayload(&result, image, .rlc_dram_boot_core1, 184, 180);
    }
    return result;
}

fn appendAmdRlcPayload(result: *AmdRlcFirmware, kind: AmdPspGfxFirmwareType, payload: []const u8) !void {
    if (payload.len == 0 or result.count == result.payloads.len) return error.InvalidAmdRlcFirmwarePayload;
    result.payloads[result.count] = .{ .kind = kind, .data = payload };
    result.count += 1;
}

fn appendOptionalAmdRlcPayload(result: *AmdRlcFirmware, image: []const u8, kind: AmdPspGfxFirmwareType, offset_field: usize, size_field: usize) !void {
    const bytes = readLittle32(image, size_field);
    if (bytes == 0) return;
    try appendAmdRlcPayload(result, kind, try amdFirmwareSlice(image, readLittle32(image, offset_field), bytes));
}

fn appendAmdPspIpFirmware(staging: *AmdGfx11CpFirmwareStaging, kind: AmdPspGfxFirmwareType, payload: []const u8, pages: *physical.Allocator) !void {
    if (staging.count == staging.areas.len or payload.len == 0 or payload.len > std.math.maxInt(u32))
        return error.InvalidAmdPspIpFirmwarePlan;
    const page_count: u64 = @intCast((payload.len + 4095) / 4096);
    const address = pages.allocate(page_count) orelse return error.OutOfMemory;
    if (address >= (@as(u64, 1) << 44) or page_count > (((@as(u64, 1) << 44) - address) / 4096)) {
        pages.release(address, page_count) catch {};
        return error.AmdPspIpFirmwareOutsideDmaMask;
    }
    const target: [*]u8 = @ptrFromInt(address);
    @memset(target[0 .. page_count * 4096], 0);
    @memcpy(target[0..payload.len], payload);
    staging.areas[staging.count] = .{ .kind = kind, .address = address, .pages = page_count, .bytes = @intCast(payload.len) };
    staging.count += 1;
}

fn appendAmdPspIpFirmwarePlan(plan: *AmdGfx11CpFirmwarePlan, kind: AmdPspGfxFirmwareType, payload: []const u8) !void {
    if (plan.count == plan.payloads.len or payload.len == 0 or payload.len > std.math.maxInt(u32))
        return error.InvalidAmdPspIpFirmwarePlan;
    plan.payloads[plan.count] = .{ .kind = kind, .data = payload };
    plan.count += 1;
}

pub fn planAmdGfx11CpFirmwareSet(set: AmdGfx11CpFirmwareSet) !AmdGfx11CpFirmwarePlan {
    try set.validate();
    const pfp = set.pfp.?;
    const me = set.me.?;
    const mec = set.mec.?;
    var result = AmdGfx11CpFirmwarePlan{};
    if (pfp.format == .rs64) {
        try appendAmdPspIpFirmwarePlan(&result, .rs64_pfp, pfp.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_pfp_p0_stack, pfp.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_pfp_p1_stack, pfp.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_me, me.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_me_p0_stack, me.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_me_p1_stack, me.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_mec, mec.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_mec_p0_stack, mec.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_mec_p1_stack, mec.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_mec_p2_stack, mec.data);
        try appendAmdPspIpFirmwarePlan(&result, .rs64_mec_p3_stack, mec.data);
    } else {
        try appendAmdPspIpFirmwarePlan(&result, .cp_pfp, pfp.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .cp_me, me.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .cp_mec, mec.instruction);
        try appendAmdPspIpFirmwarePlan(&result, .cp_mec_me1, mec.jump_table);
    }
    const rlc = set.rlc.?;
    for (rlc.payloads[0..rlc.count]) |payload|
        try appendAmdPspIpFirmwarePlan(&result, payload.kind, payload.data);
    return result;
}

pub fn stageAmdGfx11CpFirmwareSet(set: AmdGfx11CpFirmwareSet, pages: *physical.Allocator) !AmdGfx11CpFirmwareStaging {
    const plan = try planAmdGfx11CpFirmwareSet(set);
    var result = AmdGfx11CpFirmwareStaging{};
    errdefer result.release(pages);
    for (plan.payloads[0..plan.count]) |payload|
        try appendAmdPspIpFirmware(&result, payload.kind, payload.data, pages);
    return result;
}

pub fn parseAmdMesFirmware(image: []const u8) !AmdMesFirmware {
    // common_firmware_header (32 bytes) followed by mes_firmware_header_v1_0.
    if (image.len < 72 or readLittle16(image, 8) != 1) return error.UnsupportedAmdMesFirmwareHeader;
    const common = try parseAmdgpuFirmware(image);
    const ucode_bytes: usize = readLittle32(image, 36);
    const ucode_offset: usize = readLittle32(image, 40);
    const data_bytes: usize = readLittle32(image, 48);
    const data_offset: usize = readLittle32(image, 52);
    const mes_ucode_version = readLittle32(image, 32);
    const mes_data_version = readLittle32(image, 44);
    if (ucode_bytes == 0 or data_bytes == 0 or ucode_offset > image.len or ucode_bytes > image.len - ucode_offset or
        data_offset > image.len or data_bytes > image.len - data_offset or mes_ucode_version == 0 or mes_data_version == 0)
        return error.InvalidAmdMesFirmwarePayload;
    return .{
        .ip_version_major = common.ip_version_major,
        .ip_version_minor = common.ip_version_minor,
        .ucode_version = @intCast(mes_ucode_version),
        .data_version = @intCast(mes_data_version),
        .ucode = image[ucode_offset .. ucode_offset + ucode_bytes],
        .data = image[data_offset .. data_offset + data_bytes],
        .ucode_start = readLittle64(image, 56),
        .data_start = readLittle64(image, 64),
    };
}

fn validateAmdMesFirmware(image: []const u8) !void {
    _ = try parseAmdMesFirmware(image);
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
    if (classifyAmdGfxFirmware("gc_11_0_0_mes_2.bin") != .mes_scheduler or
        classifyAmdGfxFirmware("gc_11_0_0_mes1.bin") != .mes_kiq or
        classifyAmdGfxFirmware("gc_11_0_0_mec.bin") != .mec)
        @compileError("AMDGPU GFX firmware role classification failed");
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
    gc_info: ?AmdGcInfo = null,
    critical_count: usize = 0,
    critical: [16]AmdIp = .{AmdIp{}} ** 16,

    pub fn find(self: *const AmdIpDiscovery, hw_id: u16, instance: u8) ?*const AmdIp {
        for (self.critical[0..self.critical_count]) |*ip| if (ip.hw_id == hw_id and ip.instance == instance) return ip;
        return null;
    }
};

pub const AmdGcInfo = struct {
    version_minor: u16,
    num_shader_engines: u32,
    num_wgp0_per_sa: u32,
    num_wgp1_per_sa: u32,
    num_rb_per_se: u32,
    num_tcc_blocks: u32,
    gs_vgt_table_depth: u32,
    gs_prim_buffer_depth: u32,
    double_offchip_lds_buf: u32,
    wave_front_size: u32,
    num_shader_arrays_per_engine: u32,
    num_tcp_per_sa: u32 = 0,
    num_sqc_per_wgp: u32 = 0,
    tcp_l1_size: u32 = 0,
    sqc_instruction_cache_size: u32 = 0,
    sqc_data_cache_size: u32 = 0,
    gl1c_per_sa: u32 = 0,
    gl1c_size_per_instance: u32 = 0,
    gl2c_per_gpu: u32 = 0,

    pub fn maxCuPerShaderArray(self: AmdGcInfo) u32 {
        return 2 * (self.num_wgp0_per_sa + self.num_wgp1_per_sa);
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

pub const amd_hw_id = struct {
    pub const smu: u16 = 1;
    pub const gfx: u16 = 11;
    pub const mmhub: u16 = 34;
    pub const osssys: u16 = 40;
    pub const sdma0: u16 = 42;
    pub const sdma1: u16 = 43;
    pub const sdma2: u16 = 44;
    pub const sdma3: u16 = 45;
    pub const nbif: u16 = 108;
    pub const psp: u16 = 255;
};

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
    context1_page_table_base_low: u32,
    context1_page_table_base_high: u32,
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
pub const AmdGmc11NbioRegisters = struct { memsize: u32, revision_strap: u32 };
pub const AmdGfx11AsicIdentity = struct { device_id: u16, chip_rev: u8, external_rev: u8, family: u32 };
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
pub const AmdGmc11VmContextWorkspace = struct {
    register_set: AmdGmc11GartRegisterSet = .{},
    transaction: AmdGmc11RegisterTransaction = .{ .snapshot = .{}, .writes_applied = 0 },
    vmid: u4 = 0,
    engine: u5 = 0,
    root_page: u64 = 0,
    invalidate_polls: u32 = 0,
    bound: bool = false,
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
pub const AmdGpuVmHardware = struct {
    context: *anyopaque,
    bind: *const fn (*anyopaque, u4, u64) anyerror!void,
    invalidate: *const fn (*anyopaque, u4) anyerror!void,
    unbind: *const fn (*anyopaque, u4) anyerror!void,
};
pub const AmdGpuVmHardwareSession = struct {
    hardware: AmdGpuVmHardware,
    bound_vmid: u4 = 0,

    pub fn syncAfterMap(self: *AmdGpuVmHardwareSession, vmid: u4, root_page: u64) !void {
        if (vmid == 0 or root_page == 0) return error.InvalidAmdGpuVmHardwareSync;
        if (self.bound_vmid == 0) {
            try self.hardware.bind(self.hardware.context, vmid, root_page);
            self.bound_vmid = vmid;
        } else {
            if (self.bound_vmid != vmid) return error.AmdGpuVmHardwareVmidMismatch;
            try self.hardware.invalidate(self.hardware.context, vmid);
        }
    }

    pub fn syncAfterUnmap(self: *AmdGpuVmHardwareSession, vmid: u4, mappings_remain: bool) !void {
        if (self.bound_vmid == 0) return;
        if (self.bound_vmid != vmid) return error.AmdGpuVmHardwareVmidMismatch;
        if (mappings_remain) {
            try self.hardware.invalidate(self.hardware.context, vmid);
        } else {
            try self.hardware.unbind(self.hardware.context, vmid);
            self.bound_vmid = 0;
        }
    }

    pub fn reset(self: *AmdGpuVmHardwareSession) !void {
        if (self.bound_vmid == 0) return;
        try self.hardware.unbind(self.hardware.context, self.bound_vmid);
        self.bound_vmid = 0;
    }
};
const AmdGpuVmPdb1Node = struct { active: bool = false, pdb2: u9 = 0, child_count: u16 = 0, page: u64 = 0 };
const AmdGpuVmPdb0Node = struct { active: bool = false, pdb2: u9 = 0, pdb1: u9 = 0, child_count: u16 = 0, page: u64 = 0 };
const AmdGpuVmPtbNode = struct { active: bool = false, pdb2: u9 = 0, pdb1: u9 = 0, pdb0: u9 = 0, page_count: u16 = 0, page: u64 = 0 };
pub const AmdGpuVmBranchCounts = struct { pdb1: u16, pdb0: u16, ptb: u16, mapped_pages: u32 };
pub const AmdGpuVmBranchPlanner = struct {
    pdb1_nodes: [32]AmdGpuVmPdb1Node = .{AmdGpuVmPdb1Node{}} ** 32,
    pdb0_nodes: [64]AmdGpuVmPdb0Node = .{AmdGpuVmPdb0Node{}} ** 64,
    ptb_nodes: [128]AmdGpuVmPtbNode = .{AmdGpuVmPtbNode{}} ** 128,

    pub fn acquire(self: *AmdGpuVmBranchPlanner, path: AmdGpuVmPagePath) !void {
        if (self.findPtb(path)) |index| {
            if (self.ptb_nodes[index].page_count == ~@as(u16, 0)) return error.AmdGpuVmBranchReferenceOverflow;
            self.ptb_nodes[index].page_count += 1;
            return;
        }
        const pdb0_index = self.findPdb0(path);
        const pdb1_index = self.findPdb1(path);
        if (pdb0_index != null and pdb1_index == null) return error.CorruptAmdGpuVmBranchPlan;
        const free_ptb = self.freePtb() orelse return error.AmdGpuVmPtbNodesExhausted;
        const new_pdb0 = if (pdb0_index == null) self.freePdb0() orelse return error.AmdGpuVmPdb0NodesExhausted else null;
        const new_pdb1 = if (pdb1_index == null) self.freePdb1() orelse return error.AmdGpuVmPdb1NodesExhausted else null;
        const p1 = pdb1_index orelse new_pdb1.?;
        const p0 = pdb0_index orelse new_pdb0.?;
        if (new_pdb1 != null) self.pdb1_nodes[p1] = .{ .active = true, .pdb2 = path.pdb2 };
        if (new_pdb0 != null) {
            self.pdb0_nodes[p0] = .{ .active = true, .pdb2 = path.pdb2, .pdb1 = path.pdb1 };
            self.pdb1_nodes[p1].child_count += 1;
        }
        self.ptb_nodes[free_ptb] = .{ .active = true, .pdb2 = path.pdb2, .pdb1 = path.pdb1, .pdb0 = path.pdb0, .page_count = 1 };
        self.pdb0_nodes[p0].child_count += 1;
    }

    pub fn release(self: *AmdGpuVmBranchPlanner, path: AmdGpuVmPagePath) !void {
        const ptb_index = self.findPtb(path) orelse return error.AmdGpuVmBranchNotFound;
        const ptb = &self.ptb_nodes[ptb_index];
        if (ptb.page_count == 0) return error.CorruptAmdGpuVmBranchPlan;
        ptb.page_count -= 1;
        if (ptb.page_count != 0) return;
        ptb.* = .{};
        const pdb0_index = self.findPdb0(path) orelse return error.CorruptAmdGpuVmBranchPlan;
        const pdb0 = &self.pdb0_nodes[pdb0_index];
        if (pdb0.child_count == 0) return error.CorruptAmdGpuVmBranchPlan;
        pdb0.child_count -= 1;
        if (pdb0.child_count != 0) return;
        pdb0.* = .{};
        const pdb1_index = self.findPdb1(path) orelse return error.CorruptAmdGpuVmBranchPlan;
        const pdb1 = &self.pdb1_nodes[pdb1_index];
        if (pdb1.child_count == 0) return error.CorruptAmdGpuVmBranchPlan;
        pdb1.child_count -= 1;
        if (pdb1.child_count == 0) pdb1.* = .{};
    }

    pub fn counts(self: *const AmdGpuVmBranchPlanner) AmdGpuVmBranchCounts {
        var result = AmdGpuVmBranchCounts{ .pdb1 = 0, .pdb0 = 0, .ptb = 0, .mapped_pages = 0 };
        for (self.pdb1_nodes) |node| if (node.active) {
            result.pdb1 += 1;
        };
        for (self.pdb0_nodes) |node| if (node.active) {
            result.pdb0 += 1;
        };
        for (self.ptb_nodes) |node| if (node.active) {
            result.ptb += 1;
            result.mapped_pages += node.page_count;
        };
        return result;
    }

    fn findPdb1(self: *const AmdGpuVmBranchPlanner, path: AmdGpuVmPagePath) ?usize {
        for (self.pdb1_nodes, 0..) |node, index| if (node.active and node.pdb2 == path.pdb2) return index;
        return null;
    }
    fn findPdb0(self: *const AmdGpuVmBranchPlanner, path: AmdGpuVmPagePath) ?usize {
        for (self.pdb0_nodes, 0..) |node, index| if (node.active and node.pdb2 == path.pdb2 and node.pdb1 == path.pdb1) return index;
        return null;
    }
    fn findPtb(self: *const AmdGpuVmBranchPlanner, path: AmdGpuVmPagePath) ?usize {
        for (self.ptb_nodes, 0..) |node, index| if (node.active and node.pdb2 == path.pdb2 and node.pdb1 == path.pdb1 and node.pdb0 == path.pdb0) return index;
        return null;
    }
    fn freePdb1(self: *const AmdGpuVmBranchPlanner) ?usize {
        for (self.pdb1_nodes, 0..) |node, index| if (!node.active) return index;
        return null;
    }
    fn freePdb0(self: *const AmdGpuVmBranchPlanner) ?usize {
        for (self.pdb0_nodes, 0..) |node, index| if (!node.active) return index;
        return null;
    }
    fn freePtb(self: *const AmdGpuVmBranchPlanner) ?usize {
        for (self.ptb_nodes, 0..) |node, index| if (!node.active) return index;
        return null;
    }
};
pub const AmdGpuVmPageAllocator = struct {
    context: *anyopaque,
    allocate: *const fn (*anyopaque) anyerror!u64,
    release: *const fn (*anyopaque, u64) anyerror!void,
    zero: *const fn (*anyopaque, u64) anyerror!void,
};
pub const AmdGpuVmPageTree = struct {
    root_page: u64 = 0,
    allocator: ?AmdGpuVmPageAllocator = null,
    branches: AmdGpuVmBranchPlanner = .{},

    pub fn root(self: *const AmdGpuVmPageTree) ?u64 {
        return if (self.root_page != 0) self.root_page else null;
    }
};
pub const AmdGpuVmPageTables = struct {
    pages: [4]u64 = .{0} ** 4,
    count: u3 = 0,
    path_bound: bool = false,
    pdb2_index: u9 = 0,
    pdb1_index: u9 = 0,
    pdb0_index: u9 = 0,

    pub fn root(self: *const AmdGpuVmPageTables) ?u64 {
        return if (self.count == 4) self.pages[0] else null;
    }
};

fn allocateCheckedAmdGpuVmPage(allocator: AmdGpuVmPageAllocator) !u64 {
    const page = try allocator.allocate(allocator.context);
    if (page == 0 or (page & 4095) != 0 or (page & ~amd_gpu_page_address_mask) != 0) {
        if (page != 0) allocator.release(allocator.context, page) catch {};
        return error.InvalidAmdGpuVmPage;
    }
    return page;
}

pub fn materializeAmdGpuVmPageTree(tree: *AmdGpuVmPageTree, allocator: AmdGpuVmPageAllocator) !void {
    if (tree.root_page != 0) return error.AmdGpuVmPageTablesAlreadyAllocated;
    const root_page = try allocateCheckedAmdGpuVmPage(allocator);
    errdefer allocator.release(allocator.context, root_page) catch {};
    try allocator.zero(allocator.context, root_page);
    tree.* = .{ .root_page = root_page, .allocator = allocator };
}

pub fn dematerializeAmdGpuVmPageTree(tree: *AmdGpuVmPageTree) !void {
    if (tree.root_page == 0 or tree.allocator == null) return error.AmdGpuVmPageTablesNotAllocated;
    const counts = tree.branches.counts();
    if (counts.mapped_pages != 0 or counts.pdb1 != 0 or counts.pdb0 != 0 or counts.ptb != 0)
        return error.AmdGpuVmMappingsStillActive;
    const allocator = tree.allocator.?;
    try allocator.release(allocator.context, tree.root_page);
    tree.* = .{};
}

pub fn allocateAmdGpuVmPageTables(allocator: AmdGpuVmPageAllocator) !AmdGpuVmPageTables {
    var tables = AmdGpuVmPageTables{};
    errdefer releaseAmdGpuVmPageTables(&tables, allocator) catch {};
    while (tables.count < tables.pages.len) {
        const page = try allocator.allocate(allocator.context);
        if (page == 0 or (page & 4095) != 0) return error.InvalidAmdGpuVmPage;
        for (tables.pages[0..tables.count]) |existing| if (existing == page) return error.DuplicateAmdGpuVmPage;
        try allocator.zero(allocator.context, page);
        tables.pages[tables.count] = page;
        tables.count += 1;
    }
    return tables;
}

pub fn releaseAmdGpuVmPageTables(tables: *AmdGpuVmPageTables, allocator: AmdGpuVmPageAllocator) !void {
    var failed = false;
    while (tables.count != 0) {
        tables.count -= 1;
        const page = tables.pages[tables.count];
        allocator.release(allocator.context, page) catch {
            failed = true;
        };
        tables.pages[tables.count] = 0;
    }
    tables.path_bound = false;
    tables.pdb2_index = 0;
    tables.pdb1_index = 0;
    tables.pdb0_index = 0;
    if (failed) return error.AmdGpuVmPageReleaseFailed;
}

pub fn physicalAmdGpuVmPageAllocator(pages: *physical.Allocator) AmdGpuVmPageAllocator {
    return .{ .context = pages, .allocate = &allocatePhysicalAmdGpuVmPage, .release = &releasePhysicalAmdGpuVmPage, .zero = &zeroPhysicalAmdGpuVmPage };
}

fn allocatePhysicalAmdGpuVmPage(context: *anyopaque) !u64 {
    const pages: *physical.Allocator = @ptrCast(@alignCast(context));
    const address = pages.allocate(1) orelse return error.OutOfMemory;
    if (address >= (@as(u64, 1) << 44)) {
        pages.release(address, 1) catch {};
        return error.AmdGpuVmPageOutsideDmaMask;
    }
    return address;
}

fn releasePhysicalAmdGpuVmPage(context: *anyopaque, address: u64) !void {
    const pages: *physical.Allocator = @ptrCast(@alignCast(context));
    try pages.release(address, 1);
}

fn zeroPhysicalAmdGpuVmPage(_: *anyopaque, address: u64) !void {
    @memset(@as([*]u8, @ptrFromInt(address))[0..4096], 0);
}

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

const amd_gpu_pte_valid: u64 = 1 << 0;
const amd_gpu_pte_system: u64 = 1 << 1;
const amd_gpu_pte_snooped: u64 = 1 << 2;
const amd_gpu_pte_executable: u64 = 1 << 4;
const amd_gpu_pte_readable: u64 = 1 << 5;
const amd_gpu_pte_writeable: u64 = 1 << 6;
const amd_gpu_pte_translate_further: u64 = 1 << 56;
const amd_gpu_pde_bfs_9: u64 = @as(u64, 9) << 59;
const amd_gpu_page_address_mask: u64 = 0x0000fffffffff000;

fn amdGpuVmSystemPde(address: u64, flags: u64) !u64 {
    if (address == 0 or (address & 4095) != 0 or (address & ~amd_gpu_page_address_mask) != 0)
        return error.InvalidAmdGpuVmPage;
    return (address & amd_gpu_page_address_mask) | amd_gpu_pte_valid | amd_gpu_pte_system | amd_gpu_pte_snooped | flags;
}

pub fn amdGpuVmSystemPte(address: u64, mapping_flags: u32) !u64 {
    const allowed_flags: u32 = (1 << 1) | (1 << 2) | (1 << 3);
    if (address == 0 or (address & 4095) != 0 or (address & ~amd_gpu_page_address_mask) != 0 or
        mapping_flags == 0 or (mapping_flags & ~allowed_flags) != 0)
        return error.InvalidAmdGpuVmPte;
    var value = (address & amd_gpu_page_address_mask) | amd_gpu_pte_valid | amd_gpu_pte_system | amd_gpu_pte_snooped;
    if ((mapping_flags & (1 << 1)) != 0) value |= amd_gpu_pte_readable;
    if ((mapping_flags & (1 << 2)) != 0) value |= amd_gpu_pte_writeable;
    if ((mapping_flags & (1 << 3)) != 0) value |= amd_gpu_pte_executable;
    return value;
}

fn allocateAmdGpuVmTreeChild(tree: *const AmdGpuVmPageTree, prior: []const u64) !u64 {
    const allocator = tree.allocator orelse return error.AmdGpuVmPageTablesNotAllocated;
    const page = try allocateCheckedAmdGpuVmPage(allocator);
    if (page == tree.root_page) return error.DuplicateAmdGpuVmPage;
    for (prior) |existing| if (page == existing) return error.DuplicateAmdGpuVmPage;
    for (tree.branches.pdb1_nodes) |node| if (node.active and node.page == page) return error.DuplicateAmdGpuVmPage;
    for (tree.branches.pdb0_nodes) |node| if (node.active and node.page == page) return error.DuplicateAmdGpuVmPage;
    for (tree.branches.ptb_nodes) |node| if (node.active and node.page == page) return error.DuplicateAmdGpuVmPage;
    allocator.zero(allocator.context, page) catch |err| {
        allocator.release(allocator.context, page) catch {};
        return err;
    };
    return page;
}

pub fn linkAmdGpuVmPageTree(tree: *AmdGpuVmPageTree, path: AmdGpuVmPagePath, physical_page: u64, mapping_flags: u32) !void {
    if (tree.root_page == 0 or tree.allocator == null) return error.AmdGpuVmPageTablesNotAllocated;
    const pte_value = try amdGpuVmSystemPte(physical_page, mapping_flags);
    const old_pdb1 = tree.branches.findPdb1(path);
    const old_pdb0 = tree.branches.findPdb0(path);
    const old_ptb = tree.branches.findPtb(path);
    if (old_pdb0 != null and old_pdb1 == null or old_ptb != null and old_pdb0 == null)
        return error.CorruptAmdGpuVmBranchPlan;

    var allocated = [_]u64{0} ** 3;
    var allocated_count: usize = 0;
    var keep_allocated = false;
    defer if (!keep_allocated) {
        const allocator = tree.allocator.?;
        while (allocated_count != 0) {
            allocated_count -= 1;
            allocator.release(allocator.context, allocated[allocated_count]) catch {};
        }
    };
    const pdb1_page = if (old_pdb1) |index| tree.branches.pdb1_nodes[index].page else blk: {
        allocated[allocated_count] = try allocateAmdGpuVmTreeChild(tree, allocated[0..allocated_count]);
        allocated_count += 1;
        break :blk allocated[allocated_count - 1];
    };
    const pdb0_page = if (old_pdb0) |index| tree.branches.pdb0_nodes[index].page else blk: {
        allocated[allocated_count] = try allocateAmdGpuVmTreeChild(tree, allocated[0..allocated_count]);
        allocated_count += 1;
        break :blk allocated[allocated_count - 1];
    };
    const ptb_page = if (old_ptb) |index| tree.branches.ptb_nodes[index].page else blk: {
        allocated[allocated_count] = try allocateAmdGpuVmTreeChild(tree, allocated[0..allocated_count]);
        allocated_count += 1;
        break :blk allocated[allocated_count - 1];
    };
    const root: [*]u64 = @ptrFromInt(tree.root_page);
    const pdb1: [*]u64 = @ptrFromInt(pdb1_page);
    const pdb0: [*]u64 = @ptrFromInt(pdb0_page);
    const ptb: [*]u64 = @ptrFromInt(ptb_page);
    const links = [_]struct { slot: *u64, value: u64 }{
        .{ .slot = &root[path.pdb2], .value = try amdGpuVmSystemPde(pdb1_page, amd_gpu_pde_bfs_9) },
        .{ .slot = &pdb1[path.pdb1], .value = try amdGpuVmSystemPde(pdb0_page, amd_gpu_pte_translate_further) },
        .{ .slot = &pdb0[path.pdb0], .value = try amdGpuVmSystemPde(ptb_page, 0) },
        .{ .slot = &ptb[path.ptb], .value = pte_value },
    };
    for (links[0..3]) |link| if (link.slot.* != 0 and link.slot.* != link.value) return error.AmdGpuVmPagePathCollision;
    if (links[3].slot.* != 0) return error.AmdGpuVmPagePathCollision;
    try tree.branches.acquire(path);
    const pdb1_index = tree.branches.findPdb1(path).?;
    const pdb0_index = tree.branches.findPdb0(path).?;
    const ptb_index = tree.branches.findPtb(path).?;
    if (old_pdb1 == null) tree.branches.pdb1_nodes[pdb1_index].page = pdb1_page;
    if (old_pdb0 == null) tree.branches.pdb0_nodes[pdb0_index].page = pdb0_page;
    if (old_ptb == null) tree.branches.ptb_nodes[ptb_index].page = ptb_page;
    for (links) |link| link.slot.* = link.value;
    keep_allocated = true;
}

pub fn unlinkAmdGpuVmPageTree(tree: *AmdGpuVmPageTree, path: AmdGpuVmPagePath, expected_pte: u64) !void {
    if (tree.root_page == 0 or tree.allocator == null) return error.AmdGpuVmPageTablesNotAllocated;
    const pdb1_index = tree.branches.findPdb1(path) orelse return error.AmdGpuVmBranchNotFound;
    const pdb0_index = tree.branches.findPdb0(path) orelse return error.AmdGpuVmBranchNotFound;
    const ptb_index = tree.branches.findPtb(path) orelse return error.AmdGpuVmBranchNotFound;
    const pdb1_node = tree.branches.pdb1_nodes[pdb1_index];
    const pdb0_node = tree.branches.pdb0_nodes[pdb0_index];
    const ptb_node = tree.branches.ptb_nodes[ptb_index];
    const root: [*]u64 = @ptrFromInt(tree.root_page);
    const pdb1: [*]u64 = @ptrFromInt(pdb1_node.page);
    const pdb0: [*]u64 = @ptrFromInt(pdb0_node.page);
    const ptb: [*]u64 = @ptrFromInt(ptb_node.page);
    if (ptb[path.ptb] == 0) return error.AmdGpuVmPteNotMapped;
    if (ptb[path.ptb] != expected_pte) return error.AmdGpuVmPteMismatch;
    const prune_ptb = ptb_node.page_count == 1;
    const prune_pdb0 = prune_ptb and pdb0_node.child_count == 1;
    const prune_pdb1 = prune_pdb0 and pdb1_node.child_count == 1;
    ptb[path.ptb] = 0;
    if (prune_ptb) pdb0[path.pdb0] = 0;
    if (prune_pdb0) pdb1[path.pdb1] = 0;
    if (prune_pdb1) root[path.pdb2] = 0;
    try tree.branches.release(path);
    const allocator = tree.allocator.?;
    var release_failed = false;
    if (prune_ptb) allocator.release(allocator.context, ptb_node.page) catch {
        release_failed = true;
    };
    if (prune_pdb0) allocator.release(allocator.context, pdb0_node.page) catch {
        release_failed = true;
    };
    if (prune_pdb1) allocator.release(allocator.context, pdb1_node.page) catch {
        release_failed = true;
    };
    if (release_failed) return error.AmdGpuVmPageReleaseFailed;
}

pub fn linkAmdGpuVmPagePath(tables: *AmdGpuVmPageTables, path: AmdGpuVmPagePath, physical_page: u64, mapping_flags: u32) !void {
    if (tables.count != 4) return error.AmdGpuVmPageTablesNotAllocated;
    if (tables.path_bound and (tables.pdb2_index != path.pdb2 or tables.pdb1_index != path.pdb1 or tables.pdb0_index != path.pdb0))
        return error.AmdGpuVmPagePathOutsideMaterializedBranch;
    const pdb2: [*]u64 = @ptrFromInt(tables.pages[0]);
    const pdb1: [*]u64 = @ptrFromInt(tables.pages[1]);
    const pdb0: [*]u64 = @ptrFromInt(tables.pages[2]);
    const ptb: [*]u64 = @ptrFromInt(tables.pages[3]);
    const links = [_]struct { slot: *u64, value: u64 }{
        .{ .slot = &pdb2[path.pdb2], .value = try amdGpuVmSystemPde(tables.pages[1], amd_gpu_pde_bfs_9) },
        .{ .slot = &pdb1[path.pdb1], .value = try amdGpuVmSystemPde(tables.pages[2], amd_gpu_pte_translate_further) },
        .{ .slot = &pdb0[path.pdb0], .value = try amdGpuVmSystemPde(tables.pages[3], 0) },
        .{ .slot = &ptb[path.ptb], .value = try amdGpuVmSystemPte(physical_page, mapping_flags) },
    };
    for (links) |link| if (link.slot.* != 0 and link.slot.* != link.value) return error.AmdGpuVmPagePathCollision;
    for (links) |link| link.slot.* = link.value;
    tables.path_bound = true;
    tables.pdb2_index = path.pdb2;
    tables.pdb1_index = path.pdb1;
    tables.pdb0_index = path.pdb0;
}

pub fn unlinkAmdGpuVmPage(tables: *const AmdGpuVmPageTables, path: AmdGpuVmPagePath, expected_pte: u64) !void {
    if (tables.count != 4) return error.AmdGpuVmPageTablesNotAllocated;
    const ptb: [*]u64 = @ptrFromInt(tables.pages[3]);
    if (ptb[path.ptb] == 0) return error.AmdGpuVmPteNotMapped;
    if (ptb[path.ptb] != expected_pte) return error.AmdGpuVmPteMismatch;
    ptb[path.ptb] = 0;
}
pub const AmdGpuVm = struct {
    allocated: bool = false,
    vmid: u4 = 0,
    mappings: [32]AmdGpuVaMapping = .{AmdGpuVaMapping{}} ** 32,
    page_tree: AmdGpuVmPageTree = .{},
};
pub const AmdGpuVmManager = struct {
    // VMIDs 8-15 are owned by MES; direct kernel-managed GPUVM uses 1-7.
    vms: [7]AmdGpuVm = .{AmdGpuVm{}} ** 7,

    pub fn allocate(self: *AmdGpuVmManager) !*AmdGpuVm {
        for (&self.vms, 1..) |*vm, vmid| if (!vm.allocated) {
            vm.* = .{ .allocated = true, .vmid = @intCast(vmid) };
            return vm;
        };
        return error.AmdGpuVmidsExhausted;
    }

    pub fn release(self: *AmdGpuVmManager, vmid: u4) !void {
        const vm = try self.get(vmid);
        if (vm.page_tree.root_page != 0) return error.AmdGpuVmPageTablesStillAllocated;
        vm.* = .{};
    }

    pub fn materialize(self: *AmdGpuVmManager, vmid: u4, allocator: AmdGpuVmPageAllocator) !void {
        const vm = try self.get(vmid);
        try materializeAmdGpuVmPageTree(&vm.page_tree, allocator);
    }

    pub fn dematerialize(self: *AmdGpuVmManager, vmid: u4) !void {
        const vm = try self.get(vmid);
        for (vm.mappings) |mapping| if (mapping.active) return error.AmdGpuVmMappingsStillActive;
        try dematerializeAmdGpuVmPageTree(&vm.page_tree);
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

    pub fn mapSystemPage(self: *AmdGpuVmManager, vmid: u4, handle: u32, address: u64, bo_offset: u64, bo_size: u64, physical_page: u64, flags: u32) !void {
        const vm = try self.get(vmid);
        if (vm.page_tree.root_page == 0) return error.AmdGpuVmPageTablesNotAllocated;
        try self.map(vmid, handle, address, 4096, bo_offset, bo_size, flags);
        const path = amdGpuVmPagePath(address) catch |err| {
            self.unmap(vmid, address, 4096) catch {};
            return err;
        };
        linkAmdGpuVmPageTree(&vm.page_tree, path, physical_page, flags) catch |err| {
            self.unmap(vmid, address, 4096) catch {};
            return err;
        };
    }

    pub fn unmapSystemPage(self: *AmdGpuVmManager, vmid: u4, address: u64, physical_page: u64, flags: u32) !void {
        const vm = try self.get(vmid);
        var found = false;
        for (vm.mappings) |mapping| if (mapping.active and mapping.address == address and mapping.size == 4096) {
            if (mapping.flags != flags) return error.AmdGpuVmMappingFlagsMismatch;
            found = true;
            break;
        };
        if (!found) return error.AmdGpuVaMappingNotFound;
        const path = try amdGpuVmPagePath(address);
        try unlinkAmdGpuVmPageTree(&vm.page_tree, path, try amdGpuVmSystemPte(physical_page, flags));
        try self.unmap(vmid, address, 4096);
    }

    pub fn validateSystemPageMapping(self: *AmdGpuVmManager, vmid: u4, handle: u32, address: u64, bo_offset: u64, physical_page: u64) !u32 {
        const vm = try self.get(vmid);
        var flags: ?u32 = null;
        for (vm.mappings) |mapping| if (mapping.active and mapping.handle == handle and mapping.address == address and
            mapping.size == 4096 and mapping.bo_offset == bo_offset)
        {
            flags = mapping.flags;
            break;
        };
        const mapping_flags = flags orelse return error.AmdGpuVaMappingNotFound;
        const path = try amdGpuVmPagePath(address);
        const ptb_index = vm.page_tree.branches.findPtb(path) orelse return error.AmdGpuVmBranchNotFound;
        const ptb: [*]const u64 = @ptrFromInt(vm.page_tree.branches.ptb_nodes[ptb_index].page);
        if (ptb[path.ptb] != try amdGpuVmSystemPte(physical_page, mapping_flags)) return error.AmdGpuVmPteMismatch;
        return mapping_flags;
    }

    fn get(self: *AmdGpuVmManager, vmid: u4) !*AmdGpuVm {
        if (vmid == 0 or vmid > self.vms.len) return error.InvalidAmdGpuVmid;
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
        registers.page_table_base_low,  registers.page_table_base_high,
        registers.page_table_start_low, registers.page_table_start_high,
        registers.page_table_end_low,   registers.page_table_end_high,
        registers.agp_base,             registers.agp_bottom,
        registers.agp_top,              registers.system_aperture_low,
        registers.system_aperture_high, registers.system_default_low,
        registers.system_default_high,  registers.fault_default_low,
        registers.fault_default_high,   registers.fault_control2,
        registers.l1_tlb_control,       registers.l2_control,
        registers.l2_control2,          registers.l2_control3,
        registers.l2_control4,          registers.l2_control5,
        registers.context_control,      registers.identity_low_low,
        registers.identity_low_high,    registers.identity_high_low,
        registers.identity_high_high,   registers.identity_offset_low,
        registers.identity_offset_high, registers.invalidate_request,
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
        io.write(io.context, snapshot.offsets[index], snapshot.values[index]) catch {
            failed = true;
        };
    }
    for (snapshot.offsets[0..snapshot.count], snapshot.values[0..snapshot.count]) |offset, expected| {
        const observed = io.read(io.context, offset) catch {
            failed = true;
            continue;
        };
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
        for (registers.offsets[0..registers.count]) |offset| if (offset == write.offset) {
            known = true;
            break;
        };
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
        for (registers.offsets[0..registers.count]) |offset| if (offset == write.offset) {
            known = true;
            break;
        };
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
    acknowledge_mask: u32 = 1,
    indexed_selector: ?u32 = null,
    indexed_gp3: ?u32 = null,
    indexed_versions: [2]u32 = .{ 0, 0 },
    indexed_ready_after: ?u32 = null,
    indexed_reads: u32 = 0,

    fn position(self: *const AmdGartRegisterTestBank, offset: u32) ?usize {
        for (self.offsets[0..self.count], 0..) |candidate, index| if (candidate == offset) return index;
        return null;
    }
    fn read(context: *anyopaque, offset: u32) !u32 {
        const self: *AmdGartRegisterTestBank = @ptrCast(@alignCast(context));
        if (self.fail_read != null and self.fail_read.? == offset) return error.InjectedAmdRegisterReadFailure;
        if (self.indexed_gp3 != null and offset == self.indexed_gp3.?) {
            self.indexed_reads += 1;
            if (self.indexed_ready_after != null and self.indexed_reads < self.indexed_ready_after.?) return 0;
            const selector_offset = self.indexed_selector orelse return error.UnknownAmdRegister;
            const selector = self.values[self.position(selector_offset) orelse return error.UnknownAmdRegister];
            const pipe: usize = selector & 3;
            if (pipe >= self.indexed_versions.len) return error.UnknownAmdRegister;
            return self.indexed_versions[pipe];
        }
        if (self.invalidate_ack != null and self.invalidate_ack.? == offset and self.acknowledge_after_reads != null) {
            self.acknowledge_reads += 1;
            if (self.acknowledge_reads >= self.acknowledge_after_reads.?)
                self.values[self.position(offset) orelse return error.UnknownAmdRegister] |= self.acknowledge_mask;
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

pub fn amdGmc11VmContextRegisters(registers: AmdGmc11GartRegisters, vmid: u4) !AmdGmc11GartRegisterSet {
    if (vmid == 0 or vmid > 15) return error.InvalidAmdGpuVmid;
    const index = @as(u32, vmid) - 1;
    const control_delta = index * registers.context_control_stride;
    const address_delta = index * registers.context_address_stride;
    var result = AmdGmc11GartRegisterSet{};
    try result.add(registers.context1_control + control_delta);
    try result.add(registers.context1_page_table_base_low + address_delta);
    try result.add(registers.context1_page_table_base_high + address_delta);
    try result.add(registers.context1_page_table_start_low + address_delta);
    try result.add(registers.context1_page_table_start_high + address_delta);
    try result.add(registers.context1_page_table_end_low + address_delta);
    try result.add(registers.context1_page_table_end_high + address_delta);
    return result;
}

pub fn buildAmdGmc11VmContextBindWrites(
    registers: AmdGmc11GartRegisters,
    vmid: u4,
    root_page: u64,
    snapshot: *const AmdGmc11GartSnapshot,
) !AmdRegisterWriteSet {
    if (root_page == 0 or (root_page & 4095) != 0 or (root_page & ~amd_gpu_page_address_mask) != 0)
        return error.InvalidAmdGpuVmPage;
    const context_registers = try amdGmc11VmContextRegisters(registers, vmid);
    if (snapshot.count != context_registers.count) return error.InvalidAmdGartSnapshot;
    const address_delta = (@as(u32, vmid) - 1) * registers.context_address_stride;
    const control_offset = registers.context1_control + (@as(u32, vmid) - 1) * registers.context_control_stride;
    if (try amdSnapshotValue(snapshot, control_offset) != 0) return error.AmdGpuVmContextNotDisabled;
    const pd_address = try amdGpuVmSystemPde(root_page, amd_gpu_pde_bfs_9);
    var writes = AmdRegisterWriteSet{};
    try writes.add(.{ .offset = registers.context1_page_table_base_low + address_delta, .value = @truncate(pd_address) });
    try writes.add(.{ .offset = registers.context1_page_table_base_high + address_delta, .value = @truncate(pd_address >> 32) });
    try writes.add(.{ .offset = registers.context1_page_table_start_low + address_delta, .value = 0 });
    try writes.add(.{ .offset = registers.context1_page_table_start_high + address_delta, .value = 0 });
    try writes.add(.{ .offset = registers.context1_page_table_end_low + address_delta, .value = 0xffffffff });
    try writes.add(.{ .offset = registers.context1_page_table_end_high + address_delta, .value = 0x0000000f });
    // Four page-table levels mean depth=3. Block size 9 gives 512 entries.
    // Default fault responses are enabled; retry stays disabled to avoid storms.
    try writes.add(.{ .offset = control_offset, .value = try amdRmw(snapshot, control_offset, 0x005555ff, 0x00555407) });
    return writes;
}

pub fn bindAmdGmc11VmContext(
    workspace: *AmdGmc11VmContextWorkspace,
    registers: AmdGmc11GartRegisters,
    vmid: u4,
    root_page: u64,
    engine: u5,
    timeout_polls: u32,
    io: AmdRegisterIo,
) !AmdGmc11InvalidateResult {
    if (workspace.bound) return error.AmdGpuVmContextAlreadyBound;
    workspace.* = .{};
    workspace.register_set = try amdGmc11VmContextRegisters(registers, vmid);
    workspace.transaction.snapshot = try captureAmdGmc11GartSnapshot(workspace.register_set, io);
    const writes = try buildAmdGmc11VmContextBindWrites(registers, vmid, root_page, &workspace.transaction.snapshot);
    try applyAmdGmc11RegisterTransactionInPlace(&workspace.register_set, &writes, io, &workspace.transaction);
    const invalidation = invalidateAmdGmc11Gart(registers, engine, vmid, timeout_polls, io) catch |err| {
        restoreAmdGmc11GartSnapshot(workspace.transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
        workspace.* = .{};
        return err;
    };
    workspace.vmid = vmid;
    workspace.engine = engine;
    workspace.root_page = root_page;
    workspace.invalidate_polls = invalidation.polls;
    workspace.bound = true;
    return invalidation;
}

pub fn unbindAmdGmc11VmContext(
    workspace: *AmdGmc11VmContextWorkspace,
    registers: AmdGmc11GartRegisters,
    timeout_polls: u32,
    io: AmdRegisterIo,
) !AmdGmc11InvalidateResult {
    if (!workspace.bound or workspace.vmid == 0) return error.AmdGpuVmContextNotBound;
    const expected_set = try amdGmc11VmContextRegisters(registers, workspace.vmid);
    if (expected_set.count != workspace.register_set.count) return error.AmdGpuVmContextRegisterMismatch;
    for (expected_set.offsets[0..expected_set.count], workspace.register_set.offsets[0..workspace.register_set.count]) |expected, stored|
        if (expected != stored) return error.AmdGpuVmContextRegisterMismatch;
    var writes = AmdRegisterWriteSet{};
    // Disable the context before restoring its address registers.
    try writes.add(.{ .offset = workspace.register_set.offsets[0], .value = workspace.transaction.snapshot.values[0] });
    for (1..workspace.register_set.count) |index| try writes.add(.{
        .offset = workspace.register_set.offsets[index],
        .value = workspace.transaction.snapshot.values[index],
    });
    var unbind_transaction = AmdGmc11RegisterTransaction{ .snapshot = .{}, .writes_applied = 0 };
    try applyAmdGmc11RegisterTransactionInPlace(&workspace.register_set, &writes, io, &unbind_transaction);
    const invalidation = invalidateAmdGmc11Gart(registers, workspace.engine, workspace.vmid, timeout_polls, io) catch |err| {
        restoreAmdGmc11GartSnapshot(unbind_transaction.snapshot, io) catch return error.AmdGartRollbackFailed;
        return err;
    };
    workspace.* = .{};
    return invalidation;
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
    if (applyAmdGmc11RegisterTransaction(registers, writes, bank.io())) |_| return error.AmdGartWriteFailureNotDetected else |err| if (err != error.AmdGartRegisterWriteFailed) return err;
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
    if (restoreAmdGmc11GartSnapshot(snapshot, bank.io())) |_| return error.AmdGartRollbackFailureNotDetected else |err| if (err != error.AmdGartRollbackFailed) return err;
    for (bank.values[0..bank.count], snapshot.values[0..snapshot.count], 0..) |observed, expected, index| {
        if (index == failed_index) {
            if (observed == expected) return error.AmdGartInjectedFailureMissing;
        } else if (observed != expected) return error.AmdGartRollbackDidNotContinue;
    }
    bank.fail_write = null;
    try restoreAmdGmc11GartSnapshot(snapshot, bank.io());
    bank.fail_read = registers.offsets[0];
    if (captureAmdGmc11GartSnapshot(registers, bank.io())) |_| return error.AmdGartSnapshotFailureNotDetected else |err| if (err != error.InjectedAmdRegisterReadFailure) return err;
}

pub fn validateAmdGmc11GartRollbackSelfTest() !void {
    var registers = AmdGmc11GartRegisterSet{ .count = 141 };
    for (registers.offsets[0..registers.count], 0..) |*offset, index| offset.* = 0x1000 + @as(u32, @intCast(index)) * 4;
    try validateAmdGmc11GartRollback(registers);
}

pub fn validateAmdGfx11RlcResumeSelfTest() !void {
    var block = [_]u32{0xdeadbeef} ** 1024;
    const dwords = try buildAmdGfx11ClearStateBlock(&block, 0);
    if (dwords != 960 or block[0] != 0xc0004a00 or block[1] != 0x20000000 or
        block[2] != 0xc0012800 or block[5] != 0xc0d76900 or block[6] != 0 or
        block[20] != 0x40004000 or block[955] != 0 or block[956] != 0xc0004a00 or
        block[957] != 0x30000000 or block[958] != 0xc0001200 or block[959] != 0 or block[960] != 0)
        return error.AmdGfx11ClearStateBlockSelfTestFailed;

    const registers = AmdGfx11RlcRegisters{
        .csib_address_low = 0x100,
        .csib_address_high = 0x104,
        .csib_length = 0x108,
        .srm_control = 0x10c,
    };
    const plan = try planAmdGfx11RlcResume(registers, .{ .address = 0x12345678000, .first_gart_page = 31 });
    var bank = AmdGartRegisterTestBank{ .count = 4 };
    bank.offsets[0..4].* = .{ 0x100, 0x104, 0x108, 0x10c };
    bank.values[0..4].* = .{ 0x11, 0x22, 0x33, 0x40 };
    const transaction = try executeAmdGfx11RlcResume(plan, bank.io());
    if (transaction.applied != 4 or bank.values[0] != 0x45678000 or bank.values[1] != 0x123 or
        bank.values[2] != 960 or bank.values[3] != 0x43)
        return error.AmdGfx11RlcResumeSelfTestFailed;

    bank.values[0..4].* = .{ 0x11, 0x22, 0x33, 0x40 };
    bank.fail_write_once = registers.csib_length;
    if (executeAmdGfx11RlcResume(plan, bank.io())) |_| return error.AmdRlcResumeWriteFailureNotDetected else |err| if (err != error.AmdRlcRegisterWriteFailed) return err;
    if (bank.values[0] != 0x11 or bank.values[1] != 0x22 or bank.values[2] != 0x33 or bank.values[3] != 0x40)
        return error.AmdRlcResumeAutomaticRollbackMismatch;
}

pub fn validateAmdGfx11CpGfxResumeSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0xa000 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11CpGfxRegisters(&gfx_ip, 0x40000);
    const layout = AmdGfx11GfxRingLayout{
        .ring = 0x20015000,
        .rptr = 0x20016000,
        .wptr = 0x20016008,
        .first_gart_page = 21,
    };
    const plan = try planAmdGfx11CpGfxResume(registers, layout);
    if (plan.doorbell.assignment != 0x08b or plan.doorbell.register_index != 0x116 or plan.doorbell.byte_offset != 0x458)
        return error.AmdCpGfxDoorbellIdentityMismatch;
    const offsets = [_]u32{
        registers.grbm_gfx_control, registers.me_control, registers.status, registers.wptr_delay,
        registers.rb_vmid, registers.rb_control, registers.rb_wptr, registers.rb_wptr_high,
        registers.rb_rptr_address, registers.rb_rptr_address_high, registers.wptr_poll_address,
        registers.wptr_poll_address_high, registers.rb_base, registers.rb_base_high,
        registers.rb_active, registers.doorbell_control, registers.gfx_doorbell_lower,
        registers.gfx_doorbell_upper, registers.mec_doorbell_lower, registers.mec_doorbell_upper,
        registers.max_context, registers.device_id, registers.scratch0,
    };
    var bank = AmdGartRegisterTestBank{ .count = offsets.len };
    @memcpy(bank.offsets[0..offsets.len], &offsets);
    for (bank.values[0..offsets.len], 0..) |*value, index| value.* = 0xa5000000 | @as(u32, @intCast(index));
    bank.values[bank.position(registers.grbm_gfx_control).?] = 0;
    bank.values[bank.position(registers.me_control).?] = 0x14000000;
    bank.values[bank.position(registers.status).?] = 0;
    var original: [offsets.len]u32 = undefined;
    @memcpy(&original, bank.values[0..offsets.len]);
    var pointers = [_]u64{0} ** 512;
    var doorbell = AmdCpGfxDoorbellTestBank{ .pointers = &pointers };
    const polls = try activateAmdGfx11CpGfx(plan, &pointers, 4, bank.io(), doorbell.io());
    if (polls != 1 or doorbell.writes != 1 or pointers[0] != 960 or pointers[1] != 960 or
        bank.values[bank.position(registers.rb_control).?] != 0x709 or
        bank.values[bank.position(registers.rb_base).?] != 0x200150 or
        bank.values[bank.position(registers.doorbell_control).?] != 0x40000458 or
        (bank.values[bank.position(registers.me_control).?] & 0x14000000) != 0)
        return error.AmdCpGfxActivationMismatch;
    const ring_test = try planAmdGfx11CpGfxRingTest(plan);
    if (ring_test.packet[0] != 0xc0017900 or ring_test.packet[1] != 0x40 or ring_test.packet[2] != 0xdeadbeef)
        return error.AmdCpGfxRingTestPacketMismatch;
    var ring = [_]u32{0} ** 1024;
    doorbell.registers = &bank;
    doorbell.scratch_offset = registers.scratch0;
    doorbell.expected_wptr = 963;
    doorbell.writes = 0;
    const test_polls = try testAmdGfx11CpGfxRing(plan, ring_test, &ring, &pointers, 2, bank.io(), doorbell.io());
    if (test_polls != 1 or doorbell.writes != 1 or pointers[0] != 963 or pointers[1] != 963 or
        bank.values[bank.position(registers.scratch0).?] != 0xdeadbeef or
        !std.mem.eql(u32, ring[960..963], &ring_test.packet))
        return error.AmdCpGfxRingTestMismatch;
    pointers[0] = 960;
    pointers[1] = 960;
    doorbell.complete = false;
    doorbell.writes = 0;
    if (testAmdGfx11CpGfxRing(plan, ring_test, &ring, &pointers, 2, bank.io(), doorbell.io())) |_| return error.AmdCpGfxRingTestTimeoutNotDetected else |err| if (err != error.AmdCpGfxRingTestTimeout) return err;
    if ((bank.values[bank.position(registers.me_control).?] & 0x14000000) != 0x14000000 or
        bank.values[bank.position(registers.rb_active).?] != 0)
        return error.AmdCpGfxRingTestTimeoutDidNotStop;

    const submission = try encodeAmdGfx11SubmissionFrame(3, 0x12345678000, 0x321, 0x22334455000, 0x1122334455667788);
    const expected_submission = [12]u32{
        0xc0023f00, 0x45678000, 0x123, 0x03000321,
        0xc0064900, 0x06603514, 0x40000000, 0x34455000,
        0x223, 0x55667788, 0x11223344, 0,
    };
    if (!std.mem.eql(u32, &submission.dwords, &expected_submission) or submission.vmid != 3 or
        submission.ib_dwords != 0x321 or submission.sequence != 0x1122334455667788)
        return error.AmdGfxSubmissionFrameMismatch;
    if (encodeAmdGfx11SubmissionFrame(0, 0x1000, 1, 0x2000, 1)) |_| return error.AmdGfxSystemVmidSubmissionAccepted else |err| if (err != error.AmdGfxSubmissionVmidReserved) return err;
    if (encodeAmdGfx11SubmissionFrame(8, 0x1000, 1, 0x2000, 1)) |_| return error.AmdGfxMesVmidSubmissionAccepted else |err| if (err != error.AmdGfxSubmissionVmidReserved) return err;
    if (encodeAmdGfx11SubmissionFrame(1, 0x1001, 1, 0x2000, 1)) |_| return error.AmdGfxMisalignedIbAccepted else |err| if (err != error.InvalidAmdGfxIndirectBuffer) return err;
    if (encodeAmdGfx11SubmissionFrame(1, 0x1000, 1, 0x2004, 1)) |_| return error.AmdGfxMisalignedFenceAccepted else |err| if (err != error.InvalidAmdGfxSubmissionFence) return err;

    var queue = AmdGfx11SubmissionQueue{};
    var fence: u64 = 0xa5a5;
    pointers[0] = 963;
    pointers[1] = 963;
    bank.values[bank.position(registers.me_control).?] &= ~@as(u32, 0x14000000);
    bank.values[bank.position(registers.rb_active).?] = 1;
    doorbell.complete = true;
    doorbell.expected_wptr = 975;
    doorbell.fence = &fence;
    doorbell.fence_value = 1;
    doorbell.writes = 0;
    const submitted = try submitAmdGfx11IndirectBuffer(plan, &queue, &ring, &pointers, &fence, 0x22334455000, 3, 0x12345678000, 0x321, 2, bank.io(), doorbell.io());
    var expected_transaction = expected_submission;
    expected_transaction[9] = 1;
    expected_transaction[10] = 0;
    if (submitted.sequence != 1 or submitted.final_wptr != 975 or submitted.polls != 1 or
        queue.next_sequence != 2 or queue.committed_wptr != 975 or queue.stopped or fence != 1 or
        !std.mem.eql(u32, ring[963..975], &expected_transaction))
        return error.AmdGfxSubmissionTransactionMismatch;

    queue = .{ .next_sequence = 9, .committed_wptr = 1018 };
    pointers[0] = 1018;
    pointers[1] = 1018;
    fence = 0;
    doorbell.expected_wptr = 1030;
    doorbell.fence_value = 9;
    const wrapped = try submitAmdGfx11IndirectBuffer(plan, &queue, &ring, &pointers, &fence, 0x22334455000, 3, 0x12345678000, 0x321, 2, bank.io(), doorbell.io());
    expected_transaction[9] = 9;
    if (wrapped.final_wptr != 1030 or !std.mem.eql(u32, ring[1018..1024], expected_transaction[0..6]) or
        !std.mem.eql(u32, ring[0..6], expected_transaction[6..12]))
        return error.AmdGfxSubmissionWrapMismatch;

    queue = .{ .next_sequence = 10, .committed_wptr = 1030 };
    pointers[0] = 1030;
    pointers[1] = 1030;
    doorbell.complete = false;
    doorbell.expected_wptr = 1042;
    if (submitAmdGfx11IndirectBuffer(plan, &queue, &ring, &pointers, &fence, 0x22334455000, 3, 0x12345678000, 0x321, 2, bank.io(), doorbell.io())) |_| return error.AmdGfxSubmissionTimeoutNotDetected else |err| if (err != error.AmdGfxSubmissionTimeout) return err;
    if (!queue.stopped or (bank.values[bank.position(registers.me_control).?] & 0x14000000) != 0x14000000 or
        bank.values[bank.position(registers.rb_active).?] != 0)
        return error.AmdGfxSubmissionTimeoutDidNotStop;
    if (submitAmdGfx11IndirectBuffer(plan, &queue, &ring, &pointers, &fence, 0x22334455000, 3, 0x12345678000, 0x321, 2, bank.io(), doorbell.io())) |_| return error.AmdGfxStoppedQueueAccepted else |err| if (err != error.AmdGfxSubmissionQueueStopped) return err;

    @memcpy(bank.values[0..offsets.len], &original);
    pointers = .{0} ** 512;
    doorbell.complete = false;
    doorbell.registers = null;
    doorbell.expected_wptr = 960;
    doorbell.writes = 0;
    if (activateAmdGfx11CpGfx(plan, &pointers, 2, bank.io(), doorbell.io())) |_| return error.AmdCpGfxTimeoutNotDetected else |err| if (err != error.AmdCpGfxClearStateTimeout) return err;
    if ((bank.values[bank.position(registers.me_control).?] & 0x14000000) != 0x14000000 or
        bank.values[bank.position(registers.rb_active).?] != original[bank.position(registers.rb_active).?])
        return error.AmdCpGfxTimeoutRollbackMismatch;

    @memcpy(bank.values[0..offsets.len], &original);
    pointers = .{0} ** 512;
    doorbell.complete = true;
    bank.fail_write_once = registers.rb_base;
    if (activateAmdGfx11CpGfx(plan, &pointers, 2, bank.io(), doorbell.io())) |_| return error.AmdCpGfxWriteFailureNotDetected else |err| if (err != error.AmdCpGfxRegisterWriteFailed) return err;
    if ((bank.values[bank.position(registers.me_control).?] & 0x14000000) != 0x14000000)
        return error.AmdCpGfxWriteFailureDidNotHalt;
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
    if (commitAmdGmc11Activation(workspace, registers, 2, bank.io())) |_| return error.AmdGartInvalidateTimeoutNotDetected else |err| if (err != error.AmdGartInvalidateTimeout) return err;
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

pub fn validateAmdGfx11MesLoadTransactionSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    var ucode = [_]u8{0} ** 4;
    var data = [_]u8{0} ** 4;
    const plan = try planAmdGfx11MesLoad(.scheduler, loadFirmwareForSelfTest(&ucode, &data), 0x2010000, 0x2020000, registers, true);
    var bank = AmdGartRegisterTestBank{ .count = 10 };
    bank.offsets[0] = plan.writes[0].offset;
    bank.values[0] = 0;
    for (plan.writes[1..10], 1..) |write, index| {
        bank.offsets[index] = write.offset;
        bank.values[index] = 0xa5000000 | @as(u32, @intCast(index));
    }
    var original: [10]u32 = undefined;
    @memcpy(&original, bank.values[0..10]);
    const transaction = try executeAmdGfx11MesLoad(plan, bank.io());
    if (transaction.applied != 9 or bank.values[0] != 0 or bank.values[bank.position(registers.instruction_bound_low).?] != 0x1fffff or
        bank.values[bank.position(registers.data_bound_low).?] != 0x7ffff)
        return error.AmdMesLoadTransactionMismatch;
    try restoreAmdGfx11MesLoad(plan, transaction, bank.io());
    for (original, bank.values[0..10]) |expected, observed| if (expected != observed)
        return error.AmdMesLoadExplicitRestoreMismatch;
    bank.fail_write_once = registers.data_base_high;
    if (executeAmdGfx11MesLoad(plan, bank.io())) |_| return error.AmdMesLoadWriteFailureNotDetected else |err| if (err != error.AmdMesRegisterWriteFailed) return err;
    for (original, bank.values[0..10]) |expected, observed| if (expected != observed)
        return error.AmdMesLoadRollbackMismatch;
}

pub fn validateAmdGfx11MesActivationSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    var bank = AmdGartRegisterTestBank{
        .count = 5,
        .indexed_selector = registers.grbm_gfx_cntl,
        .indexed_gp3 = registers.gp3_low,
        .indexed_versions = .{ 0x51, 0x52 },
        .indexed_ready_after = 3,
    };
    bank.offsets[0] = registers.grbm_gfx_cntl;
    bank.offsets[1] = registers.mes_control;
    bank.offsets[2] = registers.program_counter_low;
    bank.offsets[3] = registers.program_counter_high;
    bank.offsets[4] = registers.gp3_low;
    bank.values[1] = 0x40030000;
    const active = try activateAmdGfx11Mes(registers, 0x3000, 0x4000, 4, bank.io());
    if (active.scheduler_version != 0x51 or active.kiq_version != 0x52 or active.polls != 2 or
        bank.values[0] != 0 or bank.values[1] != 0x0c000000)
        return error.AmdMesActivationHandshakeMismatch;

    bank.values[0] = 0;
    bank.values[1] = 0x40030000;
    bank.indexed_versions = .{ 0, 0 };
    bank.indexed_ready_after = null;
    bank.indexed_reads = 0;
    if (activateAmdGfx11Mes(registers, 0x3000, 0x4000, 2, bank.io())) |_| return error.AmdMesActivationTimeoutNotDetected else |err| if (err != error.AmdMesActivationTimeout) return err;
    if (bank.values[0] != 0 or bank.values[1] != 0x40030000)
        return error.AmdMesActivationTimeoutRollbackMismatch;
}

pub fn validateAmdGfx11KiqActivationSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    const mqd = try encodeAmdGfx11MesMqd(.kiq, .{
        .ring = 0x100000,
        .mqd = 0x110000,
        .eop = 0x120000,
        .rptr = 0x130000,
        .wptr = 0x130008,
    }, 0x200000);
    const plan = try planAmdGfx11KiqHqd(registers, &mqd.dwords);
    if (plan.writes[0].value != 0x0d or plan.writes[1].offset != registers.hqd_active or plan.writes[1].value != 0 or
        plan.writes[15].offset != registers.hqd_doorbell_control or plan.writes[16].offset != registers.hqd_active or plan.writes[16].value != 1)
        return error.AmdKiqWriteOrderMismatch;
    var bank = AmdGartRegisterTestBank{ .count = 15 };
    bank.offsets[0] = registers.grbm_gfx_cntl;
    bank.values[0] = 0;
    var count: usize = 1;
    for (plan.writes[1..]) |write| if (bank.position(write.offset) == null) {
        bank.offsets[count] = write.offset;
        bank.values[count] = 0xa0000000 | @as(u32, @intCast(count));
        count += 1;
    };
    if (count != 15) return error.AmdKiqSnapshotCountMismatch;
    var original: [15]u32 = undefined;
    @memcpy(&original, bank.values[0..15]);
    const transaction = try activateAmdGfx11Kiq(plan, bank.io());
    if (transaction.count != 14 or bank.values[0] != 0 or bank.values[bank.position(registers.hqd_active).?] != 1 or
        bank.values[bank.position(registers.hqd_doorbell_control).?] != mqd.dwords[143])
        return error.AmdKiqActivationMismatch;
    try restoreAmdGfx11Kiq(plan, &transaction, bank.io());
    for (original, bank.values[0..15]) |expected, observed| if (expected != observed) return error.AmdKiqExplicitRestoreMismatch;

    bank.fail_write_once = registers.hqd_pq_control;
    if (activateAmdGfx11Kiq(plan, bank.io())) |_| return error.AmdKiqFailureNotDetected else |err| if (err != error.AmdKiqRegisterWriteFailed) return err;
    for (original, bank.values[0..15]) |expected, observed| if (expected != observed) return error.AmdKiqFailureRollbackMismatch;
}

const AmdKiqDoorbellTestBank = struct {
    registers: *AmdGartRegisterTestBank,
    scratch_offset: u32,
    expected_offset: u32,
    expected_wptr: u64,
    writes: u32 = 0,
    fail: bool = false,
    complete: bool = true,
    pointers: ?*[2]u64 = null,
    consumed_wptr: u64 = 0,

    fn write64(context: *anyopaque, offset: u32, value: u64) !void {
        const self: *AmdKiqDoorbellTestBank = @ptrCast(@alignCast(context));
        if (self.fail) return error.InjectedAmdDoorbellFailure;
        if (offset != self.expected_offset or value != self.expected_wptr) return error.UnexpectedAmdDoorbellWrite;
        self.writes += 1;
        if (self.complete)
            self.registers.values[self.registers.position(self.scratch_offset) orelse return error.UnknownAmdRegister] = 0xdeadbeef;
        if (self.complete and self.pointers != null) self.pointers.?[0] = self.consumed_wptr;
    }

    fn io(self: *AmdKiqDoorbellTestBank) AmdDoorbellIo {
        return .{ .context = self, .write64 = &write64 };
    }
};

const AmdMesSchedulerDoorbellTestBank = struct {
    expected_offset: u32,
    expected_wptr: u64,
    pointers: *[2]u64,
    control: *[512]u64,
    writes: u32 = 0,
    complete: bool = true,
    fail: bool = false,
    query_fence_value: u64 = 1,

    fn write64(context: *anyopaque, offset: u32, value: u64) !void {
        const self: *AmdMesSchedulerDoorbellTestBank = @ptrCast(@alignCast(context));
        if (self.fail) return error.InjectedAmdDoorbellFailure;
        if (offset != self.expected_offset or value != self.expected_wptr) return error.UnexpectedAmdDoorbellWrite;
        self.writes += 1;
        if (self.complete) {
            self.control[2] = 1;
            self.control[3] = self.query_fence_value;
            self.pointers[0] = self.expected_wptr;
        }
    }

    fn io(self: *AmdMesSchedulerDoorbellTestBank) AmdDoorbellIo {
        return .{ .context = self, .write64 = &write64 };
    }
};

const AmdCpGfxDoorbellTestBank = struct {
    expected_offset: u32 = 0x458,
    expected_wptr: u64 = 960,
    pointers: *[512]u64,
    registers: ?*AmdGartRegisterTestBank = null,
    scratch_offset: u32 = 0,
    fence: ?*u64 = null,
    fence_value: u64 = 0,
    complete: bool = true,
    fail: bool = false,
    writes: u32 = 0,

    fn write64(context: *anyopaque, offset: u32, value: u64) !void {
        const self: *AmdCpGfxDoorbellTestBank = @ptrCast(@alignCast(context));
        if (self.fail) return error.InjectedAmdDoorbellFailure;
        if (offset != self.expected_offset or value != self.expected_wptr) return error.UnexpectedAmdDoorbellWrite;
        self.writes += 1;
        if (self.complete) {
            @atomicStore(u64, &self.pointers[0], value, .seq_cst);
            if (self.registers) |registers|
                registers.values[registers.position(self.scratch_offset) orelse return error.UnknownAmdRegister] = 0xdeadbeef;
            if (self.fence) |fence| @atomicStore(u64, fence, self.fence_value, .seq_cst);
        }
    }

    fn io(self: *AmdCpGfxDoorbellTestBank) AmdDoorbellIo {
        return .{ .context = self, .write64 = &write64 };
    }
};

pub fn validateAmdGfx11KiqRingTestSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    const doorbell = try planAmdGfx11MesDoorbell(.kiq, 0x200000);
    const plan = try planAmdGfx11KiqTest(registers, doorbell);
    const expected_packet = [5]u32{ 0xc0033700, 0x00010000, registers.scratch0 >> 2, 0, 0xdeadbeef };
    if (!std.mem.eql(u32, &plan.packet, &expected_packet))
        return error.AmdKiqTestPacketMismatch;
    var ring = [_]u32{0xa5a5a5a5} ** 1024;
    var pointers = [2]u64{ 9, 9 };
    var bank = AmdGartRegisterTestBank{ .count = 1 };
    bank.offsets[0] = registers.scratch0;
    var doorbell_bank = AmdKiqDoorbellTestBank{
        .registers = &bank,
        .scratch_offset = registers.scratch0,
        .expected_offset = doorbell.byte_offset,
        .expected_wptr = 5,
        .pointers = &pointers,
        .consumed_wptr = 5,
    };
    const polls = try testAmdGfx11Kiq(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io());
    if (polls != 1 or doorbell_bank.writes != 1 or pointers[0] != 5 or pointers[1] != 5 or
        !std.mem.eql(u32, ring[0..5], &plan.packet))
        return error.AmdKiqRingTestMismatch;

    bank.values[0] = 0;
    doorbell_bank.fail = true;
    if (testAmdGfx11Kiq(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io())) |_| return error.AmdKiqDoorbellFailureNotDetected else |err| if (err != error.AmdKiqDoorbellWriteFailed) return err;

    doorbell_bank.fail = false;
    doorbell_bank.complete = false;
    if (testAmdGfx11Kiq(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io())) |_| return error.AmdKiqTimeoutNotDetected else |err| if (err != error.AmdKiqTestTimeout) return err;
}

pub fn validateAmdGfx11MesSchedulerMapSelfTest() !void {
    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    const scheduler = AmdGfx11QueueAddresses{
        .ring = 0x100000,
        .mqd = 0x110000,
        .eop = 0x120000,
        .rptr = 0x130000,
        .wptr = 0x130008,
    };
    const scheduler_mqd = try encodeAmdGfx11MesMqd(.scheduler, scheduler, 0x200000);
    const scheduler_doorbell = try planAmdGfx11MesDoorbell(.scheduler, 0x200000);
    const kiq_doorbell = try planAmdGfx11MesDoorbell(.kiq, 0x200000);
    const plan = try planAmdGfx11MesSchedulerMap(registers, scheduler, scheduler_doorbell, kiq_doorbell, &scheduler_mqd.dwords);
    const expected = [12]u32{
        0xc005a200, 0x34080000, 0x58,                    0x110000, 0,          0x130008, 0,
        0xc0033700, 0x00010000, registers.scratch0 >> 2, 0,        0xdeadbeef,
    };
    if (!std.mem.eql(u32, &plan.packet, &expected)) return error.AmdMesSchedulerMapPacketMismatch;
    var ring = [_]u32{0} ** 1024;
    var pointers = [2]u64{ 5, 5 };
    var bank = AmdGartRegisterTestBank{ .count = 1 };
    bank.offsets[0] = registers.scratch0;
    var doorbell_bank = AmdKiqDoorbellTestBank{
        .registers = &bank,
        .scratch_offset = registers.scratch0,
        .expected_offset = kiq_doorbell.byte_offset,
        .expected_wptr = 17,
        .pointers = &pointers,
        .consumed_wptr = 17,
    };
    const polls = try mapAmdGfx11MesScheduler(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io());
    if (polls != 1 or pointers[0] != 17 or pointers[1] != 17 or
        !std.mem.eql(u32, ring[5..17], &plan.packet))
        return error.AmdMesSchedulerMapMismatch;

    pointers = .{ 5, 5 };
    doorbell_bank.complete = false;
    if (mapAmdGfx11MesScheduler(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io())) |_| return error.AmdMesSchedulerMapTimeoutNotDetected else |err| if (err != error.AmdMesSchedulerMapTimeout) return err;
    pointers = .{ 4, 5 };
    if (mapAmdGfx11MesScheduler(plan, &ring, &pointers, 2, bank.io(), doorbell_bank.io())) |_| return error.AmdMesSchedulerBusyRingAccepted else |err| if (err != error.AmdKiqRingNotIdle) return err;
}

pub fn validateAmdMesSetHwResourcesSelfTest() !void {
    const input = AmdMesHwResourceInput{
        .vmid_mask_mmhub = 0xff00,
        .vmid_mask_gfxhub = 0xfffe,
        .compute_hqd_mask = .{ 0xfc, 0xfc } ++ .{0} ** 6,
        .gfx_hqd_mask = .{ 0xfc, 0 },
        .sdma_hqd_mask = .{ 0xfc, 0xfc },
        .aggregated_doorbells = .{ 0x100, 0x101, 0x102, 0x103, 0x104 },
        .gc_base = .{ 0x100, 0x200, 0x300, 0x400, 0x500, 0, 0, 0 },
        .mmhub_base = .{ 0x600, 0x700, 0x800, 0x900, 0xa00, 0, 0, 0 },
        .osssys_base = .{ 0xb00, 0xc00, 0xd00, 0xe00, 0xf00, 0, 0, 0 },
    };
    const control = AmdMesControlLayout{
        .page = 0x200f000,
        .scheduler_context = 0x200f000,
        .query_status_fence = 0x200f008,
        .api_completion_fence = 0x200f010,
        .scheduler_fence = 0x200f018,
        .cleaner_shader_fence = 0x200f020,
        .first_gart_page = 15,
    };
    const frame = try encodeAmdMesSetHwResources(input, control);
    if (frame.dwords[0] != 0x00040001 or frame.dwords[1] != 0xff00 or frame.dwords[2] != 0xfffe or
        frame.dwords[5] != 0xfc or frame.dwords[13] != 0xfc or frame.dwords[15] != 0xfc or
        frame.dwords[17] != 0x100 or frame.dwords[21] != 0x104 or
        frame.dwords[22] != 0x200f000 or frame.dwords[24] != 0x200f008 or
        frame.dwords[26] != 0x100 or frame.dwords[34] != 0x600 or frame.dwords[42] != 0xb00 or
        frame.dwords[50] != 0x200f010 or frame.dwords[52] != 1 or frame.dwords[54] != 5 or frame.dwords[63] != 0)
        return error.AmdMesHwResourceFrameMismatch;
    var invalid = input;
    invalid.vmid_mask_gfxhub |= 1;
    if (encodeAmdMesSetHwResources(invalid, control)) |_| return error.AmdMesSystemVmidExposed else |err| if (err != error.InvalidAmdMesHwResources) return err;
    invalid = input;
    invalid.compute_hqd_mask = .{0} ** 8;
    invalid.gfx_hqd_mask = .{0} ** 2;
    invalid.sdma_hqd_mask = .{0} ** 2;
    if (encodeAmdMesSetHwResources(invalid, control)) |_| return error.AmdMesEmptyHqdResourcesAccepted else |err| if (err != error.InvalidAmdMesHwResources) return err;
}

pub fn validateAmdGfx11MesHwTopologySelfTest() !void {
    var discovery = AmdIpDiscovery{
        .binary_version_major = 1,
        .binary_version_minor = 0,
        .table_version = 3,
        .dies = 1,
        .ips = 5,
        .base_addresses = 15,
        .harvested = 0,
        .critical_count = 5,
    };
    discovery.critical[0] = .{ .hw_id = amd_hw_id.gfx, .major = 11, .base_count = 5, .bases = .{ 0, 0x100, 0x200, 0x300, 0x400, 0, 0, 0 } };
    discovery.critical[1] = .{ .hw_id = amd_hw_id.mmhub, .major = 3, .base_count = 5, .bases = .{ 0x500, 0x600, 0x700, 0x800, 0x900, 0, 0, 0 } };
    discovery.critical[2] = .{ .hw_id = amd_hw_id.osssys, .major = 6, .base_count = 5, .bases = .{ 0xa00, 0xb00, 0xc00, 0xd00, 0xe00, 0, 0, 0 } };
    discovery.critical[3] = .{ .hw_id = amd_hw_id.sdma0, .major = 6, .base_count = 1, .bases = .{0xf00} ++ .{0} ** 7 };
    discovery.critical[4] = .{ .hw_id = amd_hw_id.sdma1, .major = 6, .base_count = 1, .bases = .{0x1000} ++ .{0} ** 7 };
    const control = AmdMesControlLayout{
        .page = 0x200f000,
        .scheduler_context = 0x200f000,
        .query_status_fence = 0x200f008,
        .api_completion_fence = 0x200f010,
        .scheduler_fence = 0x200f018,
        .cleaner_shader_fence = 0x200f020,
        .first_gart_page = 15,
    };
    const plan = try planAmdGfx11MesHwResources(&discovery, control, 0x200000);
    const expected_compute = [8]u32{ 0x0c, 0x0c, 0x0c, 0x0c, 0, 0, 0, 0 };
    const expected_gfx = [2]u32{ 2, 2 };
    const expected_sdma = [2]u32{ 0xfc, 0xfc };
    const expected_doorbells = [5]u32{ 0x800, 0x802, 0x804, 0x806, 0x808 };
    if (plan.input.vmid_mask_mmhub != 0xff00 or plan.input.vmid_mask_gfxhub != 0xff00 or
        !std.mem.eql(u32, &plan.input.compute_hqd_mask, &expected_compute) or
        !std.mem.eql(u32, &plan.input.gfx_hqd_mask, &expected_gfx) or
        !std.mem.eql(u32, &plan.input.sdma_hqd_mask, &expected_sdma) or
        !std.mem.eql(u32, &plan.input.aggregated_doorbells, &expected_doorbells) or
        plan.frame.dwords[1] != 0xff00 or plan.frame.dwords[5] != 0x0c or plan.frame.dwords[13] != 2 or
        plan.frame.dwords[17] != 0x800 or plan.frame.dwords[21] != 0x808)
        return error.AmdMesHwTopologyMismatch;
    if (planAmdGfx11MesHwResources(&discovery, control, 0x2027)) |_| return error.AmdMesShortDoorbellApertureAccepted else |err| if (err != error.AmdMesDoorbellApertureTooSmall) return err;
    discovery.critical[0].minor = 9;
    if (planAmdGfx11MesHwResources(&discovery, control, 0x200000)) |_| return error.UnsupportedAmdMesTopologyAccepted else |err| if (err != error.UnsupportedAmdMesHwTopology) return err;
}

pub fn validateAmdMesSchedulerInitSelfTest() !void {
    var discovery = AmdIpDiscovery{
        .binary_version_major = 1,
        .binary_version_minor = 0,
        .table_version = 3,
        .dies = 1,
        .ips = 4,
        .base_addresses = 12,
        .harvested = 0,
        .critical_count = 4,
    };
    discovery.critical[0] = .{ .hw_id = amd_hw_id.gfx, .major = 11, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    discovery.critical[1] = .{ .hw_id = amd_hw_id.mmhub, .major = 3, .base_count = 1, .bases = .{0x500} ++ .{0} ** 7 };
    discovery.critical[2] = .{ .hw_id = amd_hw_id.osssys, .major = 6, .base_count = 1, .bases = .{0xa00} ++ .{0} ** 7 };
    discovery.critical[3] = .{ .hw_id = amd_hw_id.sdma0, .major = 6, .base_count = 1, .bases = .{0xf00} ++ .{0} ** 7 };
    const control_layout = AmdMesControlLayout{
        .page = 0x200f000,
        .scheduler_context = 0x200f000,
        .query_status_fence = 0x200f008,
        .api_completion_fence = 0x200f010,
        .scheduler_fence = 0x200f018,
        .cleaner_shader_fence = 0x200f020,
        .first_gart_page = 15,
    };
    const resources = try planAmdGfx11MesHwResources(&discovery, control_layout, 0x200000);
    const scheduler_doorbell = try planAmdGfx11MesDoorbell(.scheduler, 0x200000);
    const plan = try planAmdMesSchedulerInit(resources, control_layout, scheduler_doorbell);
    if (plan.frames[0] != 0x00040001 or plan.frames[50] != 0x200f010 or plan.frames[52] != 1 or
        plan.frames[64] != 0x000400b1 or plan.frames[66] != 0x200f018 or plan.frames[68] != 1 or
        plan.frames[127] != 0 or plan.scheduler_doorbell_offset != 0x58)
        return error.AmdMesSchedulerInitFramesMismatch;
    var ring = [_]u32{0xa5a5a5a5} ** 1024;
    var pointers = [2]u64{ 0, 0 };
    var control = [_]u64{0xa5a5a5a5a5a5a5a5} ** 512;
    var doorbell = AmdMesSchedulerDoorbellTestBank{
        .expected_offset = 0x58,
        .expected_wptr = 128,
        .pointers = &pointers,
        .control = &control,
    };
    const polls = try initializeAmdMesScheduler(plan, &ring, &pointers, &control, 2, doorbell.io());
    if (polls != 1 or doorbell.writes != 1 or pointers[0] != 128 or pointers[1] != 128 or
        control[2] != 1 or control[3] != 1 or !std.mem.eql(u32, ring[0..128], &plan.frames))
        return error.AmdMesSchedulerInitMismatch;

    pointers = .{ 0, 0 };
    doorbell.complete = false;
    if (initializeAmdMesScheduler(plan, &ring, &pointers, &control, 2, doorbell.io())) |_| return error.AmdMesSchedulerInitTimeoutNotDetected else |err| if (err != error.AmdMesSchedulerInitTimeout) return err;
    pointers = .{ 0, 0 };
    doorbell.fail = true;
    if (initializeAmdMesScheduler(plan, &ring, &pointers, &control, 2, doorbell.io())) |_| return error.AmdMesSchedulerDoorbellFailureNotDetected else |err| if (err != error.AmdMesSchedulerDoorbellWriteFailed) return err;
    pointers = .{ 1, 0 };
    if (initializeAmdMesScheduler(plan, &ring, &pointers, &control, 2, doorbell.io())) |_| return error.AmdMesSchedulerBusyRingAccepted else |err| if (err != error.AmdMesSchedulerRingNotIdle) return err;
}

pub fn validateAmdMesSchedulerResource1SelfTest() !void {
    const control_layout = AmdMesControlLayout{
        .page = 0x200f000,
        .scheduler_context = 0x200f000,
        .query_status_fence = 0x200f008,
        .api_completion_fence = 0x200f010,
        .scheduler_fence = 0x200f018,
        .cleaner_shader_fence = 0x200f020,
        .first_gart_page = 15,
    };
    const scheduler_doorbell = try planAmdGfx11MesDoorbell(.scheduler, 0x200000);
    if (try planAmdMesSchedulerResource1(0x51, control_layout, scheduler_doorbell) != null)
        return error.AmdMesOldFirmwareRequiresResource1;
    const plan = (try planAmdMesSchedulerResource1(0x1000052, control_layout, scheduler_doorbell)) orelse
        return error.AmdMesResource1PlanMissing;
    if (plan.firmware_revision != 0x52 or plan.frames[0] != 0x00040131 or
        plan.frames[1] != 0x200f010 or plan.frames[3] != 1 or plan.frames[7] != 1 or
        plan.frames[13] != 0x200f020 or plan.frames[64] != 0x000400b1 or
        plan.frames[66] != 0x200f018 or plan.frames[68] != 2 or plan.frames[127] != 0)
        return error.AmdMesSchedulerResource1FramesMismatch;
    var ring = [_]u32{0} ** 1024;
    var pointers = [2]u64{ 128, 128 };
    var control = [_]u64{0} ** 512;
    var doorbell = AmdMesSchedulerDoorbellTestBank{
        .expected_offset = 0x58,
        .expected_wptr = 256,
        .pointers = &pointers,
        .control = &control,
        .query_fence_value = 2,
    };
    const polls = try initializeAmdMesSchedulerResource1(plan, &ring, &pointers, &control, 2, doorbell.io());
    if (polls != 1 or pointers[0] != 256 or pointers[1] != 256 or control[2] != 1 or control[3] != 2 or
        !std.mem.eql(u32, ring[128..256], &plan.frames))
        return error.AmdMesSchedulerResource1Mismatch;
    pointers = .{ 128, 128 };
    doorbell.complete = false;
    if (initializeAmdMesSchedulerResource1(plan, &ring, &pointers, &control, 2, doorbell.io())) |_| return error.AmdMesSchedulerResource1TimeoutNotDetected else |err| if (err != error.AmdMesSchedulerResource1Timeout) return err;
}

pub fn validateAmdGmc11VmContextSelfTest() !void {
    const plan = AmdGartPlan{
        .family = .v11_0,
        .gfxhub_base = null,
        .mmhub_base = 0x300,
        .table_cpu_address = 0x800000,
        .entries = 512,
        .window_bytes = 2 * 1024 * 1024,
    };
    const registers = try resolveAmdGmc11GartRegisters(plan, 0x4000);
    const vmid: u4 = 3;
    const engine: u5 = 2;
    const root_page: u64 = 0x0000123456789000;
    const register_set = try amdGmc11VmContextRegisters(registers, vmid);
    var bank = AmdGartRegisterTestBank{ .count = register_set.count + 2, .acknowledge_mask = @as(u32, 1) << vmid };
    for (register_set.offsets[0..register_set.count], 0..) |offset, index| {
        bank.offsets[index] = offset;
        bank.values[index] = if (index == 0) 0 else 0xa0000000 | @as(u32, @intCast(index));
    }
    const request_offset = registers.invalidate_request + @as(u32, engine) * registers.invalidate_engine_stride;
    const ack_offset = registers.invalidate_ack + @as(u32, engine) * registers.invalidate_engine_stride;
    bank.offsets[register_set.count] = request_offset;
    bank.offsets[register_set.count + 1] = ack_offset;
    bank.invalidate_request = request_offset;
    bank.invalidate_ack = ack_offset;
    var original: [7]u32 = undefined;
    @memcpy(&original, bank.values[0..7]);

    var workspace = AmdGmc11VmContextWorkspace{};
    bank.acknowledge_after_reads = 2;
    const bound = try bindAmdGmc11VmContext(&workspace, registers, vmid, root_page, engine, 8, bank.io());
    const address_delta = (@as(u32, vmid) - 1) * registers.context_address_stride;
    const control_delta = (@as(u32, vmid) - 1) * registers.context_control_stride;
    const pd_address = try amdGpuVmSystemPde(root_page, amd_gpu_pde_bfs_9);
    if (!workspace.bound or workspace.transaction.writes_applied != 7 or bound.polls != 2 or
        bank.values[bank.position(registers.context1_page_table_base_low + address_delta).?] != @as(u32, @truncate(pd_address)) or
        bank.values[bank.position(registers.context1_page_table_base_high + address_delta).?] != @as(u32, @truncate(pd_address >> 32)) or
        bank.values[bank.position(registers.context1_page_table_end_low + address_delta).?] != 0xffffffff or
        bank.values[bank.position(registers.context1_page_table_end_high + address_delta).?] != 0x0f or
        bank.values[bank.position(registers.context1_control + control_delta).?] != ((original[0] & ~@as(u32, 0x005555ff)) | 0x00555407) or
        bank.values[bank.position(request_offset).?] != 0x00f80008)
        return error.AmdGpuVmContextBindMismatch;

    var bound_values: [7]u32 = undefined;
    @memcpy(&bound_values, bank.values[0..7]);
    bank.acknowledge_after_reads = null;
    bank.values[bank.position(ack_offset).?] = 0;
    if (unbindAmdGmc11VmContext(&workspace, registers, 2, bank.io())) |_| return error.AmdGpuVmContextUnbindTimeoutNotDetected else |err| if (err != error.AmdGartInvalidateTimeout) return err;
    if (!workspace.bound) return error.AmdGpuVmContextLostAfterUnbindTimeout;
    for (bound_values, bank.values[0..7]) |expected, observed| if (expected != observed)
        return error.AmdGpuVmContextUnbindRollbackMismatch;

    bank.acknowledge_after_reads = 1;
    bank.values[bank.position(ack_offset).?] = 0;
    _ = try unbindAmdGmc11VmContext(&workspace, registers, 4, bank.io());
    if (workspace.bound) return error.AmdGpuVmContextStillBound;
    for (original, bank.values[0..7]) |expected, observed| if (expected != observed)
        return error.AmdGpuVmContextRestoreMismatch;

    bank.acknowledge_after_reads = null;
    bank.values[bank.position(ack_offset).?] = 0;
    if (bindAmdGmc11VmContext(&workspace, registers, vmid, root_page, engine, 2, bank.io())) |_| return error.AmdGpuVmContextBindTimeoutNotDetected else |err| if (err != error.AmdGartInvalidateTimeout) return err;
    if (workspace.bound) return error.AmdGpuVmContextBoundAfterTimeout;
    for (original, bank.values[0..7]) |expected, observed| if (expected != observed)
        return error.AmdGpuVmContextBindRollbackMismatch;
}

pub fn validateAmdGmc11MmioTransportSelfTest() !void {
    var registers = [_]u32{ 0x11223344, 0x55667788, 0, 0 };
    const device = pci.Device{
        .bus = 0,
        .slot = 1,
        .function = 0,
        .vendor = 0x1002,
        .device = 0x744c,
        .revision = 1,
        .subsystem_vendor = 0x1002,
        .subsystem_device = 1,
        .class = 3,
        .subclass = 0,
        .programming_interface = 0,
        .header_type = 0,
        .msi = true,
        .msix = true,
    };
    const bar = pci.Bar{ .address = @intFromPtr(&registers), .size = @sizeOf(@TypeOf(registers)), .is_64_bit = true, .prefetchable = false };
    const adapter = Adapter{
        .device = device,
        .driver = .amdgpu,
        .bars = .{ bar, null, null, null, null, null },
        .bar_count = 1,
        .mmio_bytes = bar.size,
        .register_bar = bar,
        .rom_bar = null,
    };
    var transport = AmdGmc11MmioTransport{ .adapter = &adapter, .uncached = true };
    if (transport.io().read(transport.io().context, 0)) |_| return error.AmdGmc11DisarmedReadAllowed else |err| if (err != error.AmdGmc11MmioTransportDisarmed) return err;
    if (transport.arm()) return error.AmdGmc11UnauthorizedArmAllowed else |err| if (err != error.AmdGmc11MmioTransportNotReady) return err;
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
    if (transport.authorize(invalid_evidence)) return error.AmdGmc11IncompleteFirmwareAuthorized else |err| if (err != error.AmdGmc11MmioAuthorizationRejected) return err;
    invalid_evidence = valid_evidence;
    invalid_evidence.psp_ready = false;
    if (transport.authorize(invalid_evidence)) return error.AmdGmc11UnreadyPspAuthorized else |err| if (err != error.AmdGmc11MmioAuthorizationRejected) return err;
    try transport.authorize(valid_evidence);
    try transport.arm();
    if (try transport.io().read(transport.io().context, 4) != 0x55667788) return error.AmdGmc11MmioReadMismatch;
    try transport.io().write(transport.io().context, 8, 0xa5a55a5a);
    if (registers[2] != 0xa5a55a5a) return error.AmdGmc11MmioWriteMismatch;
    transport.disarm();
    if (transport.io().write(transport.io().context, 8, 0)) return error.AmdGmc11DisarmedWriteAllowed else |err| if (err != error.AmdGmc11MmioTransportDisarmed) return err;
}

pub fn validateAmdGpuVmManagerSelfTest() !void {
    var manager = AmdGpuVmManager{};
    const first = try manager.allocate();
    const second = try manager.allocate();
    if (first.vmid != 1 or second.vmid != 2) return error.AmdGpuVmidAllocationMismatch;
    try manager.map(1, 7, 0x100000000, 0x4000, 0, 0x8000, (1 << 1) | (1 << 2));
    try manager.map(1, 8, 0x100004000, 0x2000, 0x2000, 0x8000, 1 << 1);
    try manager.map(2, 9, 0x100000000, 0x1000, 0, 0x1000, 1 << 3);
    if (manager.map(1, 10, 0x100003000, 0x2000, 0, 0x2000, 1 << 1)) return error.AmdGpuVaOverlapAccepted else |err| if (err != error.AmdGpuVaOverlap) return err;
    if (manager.map(1, 10, 0x200000000, 0x2000, 0x1000, 0x2000, 1 << 1)) return error.AmdGpuVaBoOverflowAccepted else |err| if (err != error.InvalidAmdGpuVaMapping) return err;
    try manager.unmap(1, 0x100004000, 0x2000);
    if (manager.unmap(1, 0x100004000, 0x2000)) return error.AmdGpuVaMissingUnmapAccepted else |err| if (err != error.AmdGpuVaMappingNotFound) return err;
    try manager.release(1);
    const recycled = try manager.allocate();
    if (recycled.vmid != 1) return error.AmdGpuVmidNotRecycled;
    for (recycled.mappings) |mapping| if (mapping.active) return error.AmdGpuVmReleaseLeakedMapping;
    const path = try amdGpuVmPagePath(0x00007f123456789a);
    if (path.pdb2 != 0xfe or path.pdb1 != 0x48 or path.pdb0 != 0x1a2 or path.ptb != 0x167 or path.page_offset != 0x89a)
        return error.AmdGpuVmPagePathMismatch;
    if (try amdGpuVmTableBytes(512) != 4096 or try amdGpuVmTableBytes(1) != 4096)
        return error.AmdGpuVmTableSizeMismatch;
    if (amdGpuVmPagePath(0x0000800000000000)) |_| return error.AmdGpuVmNonCanonicalVaAccepted else |err| if (err != error.InvalidAmdGpuVa) return err;
    for (0..5) |_| _ = try manager.allocate();
    if (manager.allocate()) |_| return error.AmdGpuVmMesVmidAllocated else |err| if (err != error.AmdGpuVmidsExhausted) return err;
    if (manager.map(8, 1, 0x300000000, 0x1000, 0, 0x1000, 1 << 1))
        return error.AmdGpuVmMesVmidAccepted
    else |err| if (err != error.InvalidAmdGpuVmid) return err;
}

const AmdGpuVmHardwareTest = struct {
    binds: u8 = 0,
    invalidates: u8 = 0,
    unbinds: u8 = 0,
    fail: enum { none, bind, invalidate, unbind } = .none,

    fn hardware(self: *AmdGpuVmHardwareTest) AmdGpuVmHardware {
        return .{ .context = self, .bind = &bind, .invalidate = &invalidate, .unbind = &unbind };
    }
    fn bind(raw: *anyopaque, vmid: u4, root: u64) !void {
        const self: *AmdGpuVmHardwareTest = @ptrCast(@alignCast(raw));
        if (vmid == 0 or root == 0) return error.InvalidAmdGpuVmHardwareTest;
        if (self.fail == .bind) return error.InjectedAmdGpuVmHardwareFailure;
        self.binds += 1;
    }
    fn invalidate(raw: *anyopaque, vmid: u4) !void {
        const self: *AmdGpuVmHardwareTest = @ptrCast(@alignCast(raw));
        if (vmid == 0) return error.InvalidAmdGpuVmHardwareTest;
        if (self.fail == .invalidate) return error.InjectedAmdGpuVmHardwareFailure;
        self.invalidates += 1;
    }
    fn unbind(raw: *anyopaque, vmid: u4) !void {
        const self: *AmdGpuVmHardwareTest = @ptrCast(@alignCast(raw));
        if (vmid == 0) return error.InvalidAmdGpuVmHardwareTest;
        if (self.fail == .unbind) return error.InjectedAmdGpuVmHardwareFailure;
        self.unbinds += 1;
    }
};

pub fn validateAmdGpuVmHardwareSessionSelfTest() !void {
    var backend = AmdGpuVmHardwareTest{};
    var session = AmdGpuVmHardwareSession{ .hardware = backend.hardware() };
    try session.syncAfterMap(1, 0x1000);
    try session.syncAfterMap(1, 0x1000);
    try session.syncAfterUnmap(1, true);
    if (session.bound_vmid != 1 or backend.binds != 1 or backend.invalidates != 2 or backend.unbinds != 0)
        return error.AmdGpuVmHardwareSyncCountMismatch;
    if (session.syncAfterMap(2, 0x2000)) return error.AmdGpuVmHardwareWrongVmidAccepted else |err| if (err != error.AmdGpuVmHardwareVmidMismatch) return err;

    backend.fail = .invalidate;
    if (session.syncAfterMap(1, 0x1000)) return error.AmdGpuVmHardwareInvalidateFailureMissed else |err| if (err != error.InjectedAmdGpuVmHardwareFailure) return err;
    if (session.bound_vmid != 1) return error.AmdGpuVmHardwareBindingLostAfterInvalidateFailure;
    backend.fail = .unbind;
    if (session.syncAfterUnmap(1, false)) return error.AmdGpuVmHardwareUnbindFailureMissed else |err| if (err != error.InjectedAmdGpuVmHardwareFailure) return err;
    if (session.bound_vmid != 1) return error.AmdGpuVmHardwareBindingLostAfterUnbindFailure;
    backend.fail = .none;
    try session.syncAfterUnmap(1, false);
    if (session.bound_vmid != 0 or backend.unbinds != 1) return error.AmdGpuVmHardwareUnbindMismatch;

    backend.fail = .bind;
    if (session.syncAfterMap(2, 0x2000)) return error.AmdGpuVmHardwareBindFailureMissed else |err| if (err != error.InjectedAmdGpuVmHardwareFailure) return err;
    if (session.bound_vmid != 0) return error.AmdGpuVmHardwareBoundAfterBindFailure;
}

pub fn validateAmdGpuVmBranchPlannerSelfTest() !void {
    var planner = AmdGpuVmBranchPlanner{};
    const first = AmdGpuVmPagePath{ .pdb2 = 1, .pdb1 = 2, .pdb0 = 3, .ptb = 4, .page_offset = 0 };
    const same_ptb = AmdGpuVmPagePath{ .pdb2 = 1, .pdb1 = 2, .pdb0 = 3, .ptb = 5, .page_offset = 0 };
    const next_ptb = AmdGpuVmPagePath{ .pdb2 = 1, .pdb1 = 2, .pdb0 = 4, .ptb = 0, .page_offset = 0 };
    const next_pdb0 = AmdGpuVmPagePath{ .pdb2 = 1, .pdb1 = 3, .pdb0 = 0, .ptb = 0, .page_offset = 0 };
    const next_pdb1 = AmdGpuVmPagePath{ .pdb2 = 2, .pdb1 = 0, .pdb0 = 0, .ptb = 0, .page_offset = 0 };

    try planner.acquire(first);
    try planner.acquire(same_ptb);
    var counts = planner.counts();
    if (counts.pdb1 != 1 or counts.pdb0 != 1 or counts.ptb != 1 or counts.mapped_pages != 2)
        return error.AmdGpuVmSharedBranchCountMismatch;
    try planner.acquire(next_ptb);
    try planner.acquire(next_pdb0);
    try planner.acquire(next_pdb1);
    counts = planner.counts();
    if (counts.pdb1 != 2 or counts.pdb0 != 3 or counts.ptb != 4 or counts.mapped_pages != 5)
        return error.AmdGpuVmExpandedBranchCountMismatch;

    try planner.release(first);
    counts = planner.counts();
    if (counts.ptb != 4 or counts.mapped_pages != 4) return error.AmdGpuVmSharedBranchPrunedEarly;
    try planner.release(same_ptb);
    try planner.release(next_ptb);
    try planner.release(next_pdb0);
    try planner.release(next_pdb1);
    counts = planner.counts();
    if (counts.pdb1 != 0 or counts.pdb0 != 0 or counts.ptb != 0 or counts.mapped_pages != 0)
        return error.AmdGpuVmBranchPruneMismatch;
    if (planner.release(first)) return error.AmdGpuVmMissingBranchReleaseAccepted else |err| if (err != error.AmdGpuVmBranchNotFound) return err;
}

pub fn validateAmdGfx11RingResourceSelfTest() !void {
    var pool = AmdGpuVmPageTestPool{};
    var resources = try allocateAmdGfx11RingResources(pool.pageAllocator());
    if (resources.scheduler.ring == 0 or resources.scheduler.mqd == 0 or resources.scheduler.eop == 0 or resources.scheduler.pointers == 0 or
        resources.kiq.ring == 0 or resources.kiq.mqd == 0 or resources.kiq.eop == 0 or resources.kiq.pointers == 0)
        return error.AmdGfxRingResourceMissing;
    for (pool.allocated, 0..) |allocated, index| if (allocated)
        for (pool.storage[index]) |byte| if (byte != 0) return error.AmdGfxRingResourceNotZeroed;
    try resources.release();
    for (pool.allocated) |allocated| if (allocated) return error.AmdGfxRingResourceReleaseLeak;

    var failing = AmdGpuVmPageTestPool{ .fail_after = 5 };
    if (allocateAmdGfx11RingResources(failing.pageAllocator())) |_| return error.AmdGfxRingResourceFailureNotDetected else |err| if (err != error.InjectedAmdGpuVmAllocationFailure) return err;
    for (failing.allocated) |allocated| if (allocated) return error.AmdGfxRingResourceRollbackLeak;

    var command_pool = AmdGpuVmPageTestPool{};
    var command = try allocateAmdGfx11GfxRingResources(command_pool.pageAllocator());
    var command_table: [512]u64 align(4096) = .{0} ** 512;
    const command_staging = AmdPspGttStaging{ .page_table_address = @intFromPtr(&command_table), .page_table_pages = 1 };
    const command_layout = try mapAmdGfx11GfxRingIntoGart(
        command_staging,
        .{ .address = 0x20014000, .first_gart_page = 20 },
        command,
        0x20000000,
        0x1000,
    );
    if (command_layout.first_gart_page != 21 or command_layout.ring != 0x20015000 or command_layout.rptr != 0x20016000 or
        command_layout.wptr != 0x20016008 or command_layout.ring_dwords != 1024 or command_layout.doorbell_index != 0x116 or
        command_layout.doorbell_byte_offset != 0x458 or command_table[21] != amdGttPte(command.ring) or
        command_table[22] != amdGttPte(command.pointers))
        return error.AmdGfxCommandRingLayoutMismatch;
    if (mapAmdGfx11GfxRingIntoGart(command_staging, .{ .address = 0x20014000, .first_gart_page = 20 }, command, 0x20000000, 0x1000)) |_| return error.AmdGfxCommandRingCollisionAccepted else |err| if (err != error.AmdGfxRingGartPageAlreadyMapped) return err;
    try command.release();
    for (command_pool.allocated) |allocated| if (allocated) return error.AmdGfxCommandRingReleaseLeak;

    const scheduler = try encodeAmdGfx11MesMqd(.scheduler, .{
        .ring = 0x100000,
        .mqd = 0x110000,
        .eop = 0x120000,
        .rptr = 0x130000,
        .wptr = 0x130008,
    }, 0x200000);
    if (scheduler.doorbell.assignment != 0x0b or scheduler.doorbell.register_index != 0x16 or scheduler.doorbell.byte_offset != 0x58 or
        scheduler.dwords[128] != 0x110000 or scheduler.dwords[136] != 0x1000 or scheduler.dwords[139] != 0x130000 or
        scheduler.dwords[141] != 0x130008 or scheduler.dwords[143] != 0x40000058 or scheduler.dwords[145] != 0xd8308909 or
        scheduler.dwords[165] != 0x1200 or scheduler.dwords[167] != 8 or scheduler.dwords[130] != 0)
        return error.AmdGfxMqdEncodingMismatch;
    const kiq = try planAmdGfx11MesDoorbell(.kiq, 0x200000);
    if (kiq.assignment != 0x0c or kiq.register_index != 0x18 or kiq.byte_offset != 0x60)
        return error.AmdGfxKiqDoorbellMismatch;
    if (planAmdGfx11MesDoorbell(.scheduler, 0x5f)) |_| return error.AmdGfxShortDoorbellApertureAccepted else |err| if (err != error.AmdGfxDoorbellOutsideAperture) return err;

    var bootstrap_pool = AmdGpuVmPageTestPool{};
    var bootstrap_resources = try allocateAmdGfx11RingResources(bootstrap_pool.pageAllocator());
    var gart_table = [_]u64{0} ** 512;
    const bootstrap = try prepareAmdGfx11MesBootstrap(.{
        .page_table_address = @intFromPtr(&gart_table),
        .page_table_pages = 1,
        .buffer_address = 0x800000,
        .buffer_pages = 3,
    }, bootstrap_resources, 0x2000000, 0x200000);
    if (bootstrap.scheduler.ring != 0x2003000 or bootstrap.scheduler.mqd != 0x2004000 or
        bootstrap.kiq.ring != 0x2007000 or bootstrap.kiq.mqd != 0x2008000 or
        gart_table[3] != amdGttPte(bootstrap_resources.scheduler.ring) or
        gart_table[10] != amdGttPte(bootstrap_resources.kiq.pointers))
        return error.AmdGfxMesBootstrapLayoutMismatch;
    const staged_scheduler: *const [512]u32 = @ptrFromInt(bootstrap_resources.scheduler.mqd);
    const staged_kiq: *const [512]u32 = @ptrFromInt(bootstrap_resources.kiq.mqd);
    if (staged_scheduler[143] != 0x40000058 or staged_kiq[143] != 0x40000060 or
        staged_scheduler[130] != 0 or staged_kiq[130] != 0)
        return error.AmdGfxMesBootstrapMqdMismatch;
    const firmware_layout = try mapAmdMesFirmwareIntoGart(.{
        .page_table_address = @intFromPtr(&gart_table),
        .page_table_pages = 1,
        .buffer_address = 0x800000,
        .buffer_pages = 3,
    }, .{
        .scheduler = .{ .ucode = .{ .address = @intFromPtr(&bootstrap_pool.storage[0]), .pages = 1, .bytes = 16 }, .data = .{ .address = @intFromPtr(&bootstrap_pool.storage[1]), .pages = 1, .bytes = 16 } },
        .kiq = .{ .ucode = .{ .address = @intFromPtr(&bootstrap_pool.storage[2]), .pages = 1, .bytes = 16 }, .data = .{ .address = @intFromPtr(&bootstrap_pool.storage[3]), .pages = 1, .bytes = 16 } },
    }, 0x2000000);
    if (firmware_layout.scheduler_ucode != 0x200b000 or firmware_layout.kiq_data != 0x200e000 or firmware_layout.gart_pages != 4 or
        gart_table[11] != amdGttPte(@intFromPtr(&bootstrap_pool.storage[0])) or gart_table[14] != amdGttPte(@intFromPtr(&bootstrap_pool.storage[3])))
        return error.AmdMesFirmwareGartLayoutMismatch;
    var control_resources = try allocateAmdMesControlResources(bootstrap_pool.pageAllocator());
    const control_layout = try mapAmdMesControlIntoGart(.{
        .page_table_address = @intFromPtr(&gart_table),
        .page_table_pages = 1,
        .buffer_address = 0x800000,
        .buffer_pages = 3,
    }, firmware_layout, control_resources, 0x2000000);
    if (control_layout.first_gart_page != 15 or control_layout.page != 0x200f000 or
        control_layout.scheduler_context != 0x200f000 or control_layout.query_status_fence != 0x200f008 or
        control_layout.api_completion_fence != 0x200f010 or control_layout.scheduler_fence != 0x200f018 or
        control_layout.cleaner_shader_fence != 0x200f020 or
        gart_table[15] != amdGttPte(control_resources.page))
        return error.AmdMesControlGartLayoutMismatch;
    const control_bytes: *const [4096]u8 = @ptrFromInt(control_resources.page);
    for (control_bytes) |byte| if (byte != 0) return error.AmdMesControlPageNotZero;
    try control_resources.release();
    try bootstrap_resources.release();
    for (bootstrap_pool.allocated) |allocated| if (allocated) return error.AmdGfxMesBootstrapReleaseLeak;

    const gfx_ip = AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .instance = 0, .base_count = 2, .bases = .{ 0, 0x100 } ++ .{0} ** 6 };
    const registers = try resolveAmdGfx11MesRegisters(&gfx_ip, 0x20000);
    if (!amdGfx11MesIsHalted(0x40030000) or amdGfx11MesIsHalted(0x44030000) or amdGfx11MesIsHalted(0x40010000))
        return error.AmdGfxMesHaltClassificationMismatch;
    var ucode = [_]u8{0} ** 4;
    var data = [_]u8{0} ** 4;
    const load = try planAmdGfx11MesLoad(.kiq, .{
        .ip_version_major = 11,
        .ip_version_minor = 0,
        .ucode_version = 1,
        .data_version = 1,
        .ucode = &ucode,
        .data = &data,
        .ucode_start = 0x3000,
        .data_start = 0x8000,
    }, 0x2010000, 0x2020000, registers, true);
    if (load.pipe != 1 or load.writes[0].value != 0x0d or load.writes[1].value != 0 or
        load.writes[2].value != 0x0c00 or load.writes[4].value != 0x2010000 or
        load.writes[6].value != 0x1fffff or load.writes[9].value != 0x7ffff or load.writes[10].value != 0)
        return error.AmdGfxMesLoadPlanMismatch;
    if (planAmdGfx11MesLoad(.scheduler, loadFirmwareForSelfTest(&ucode, &data), 0x2010000, 0x2020000, registers, false)) |_|
        return error.AmdGfxMesUnhaltedLoadAccepted
    else |err| if (err != error.AmdMesMustBeHaltedBeforeLoad) return err;
}

fn loadFirmwareForSelfTest(ucode: []const u8, data: []const u8) AmdMesFirmware {
    return .{ .ip_version_major = 11, .ip_version_minor = 0, .ucode_version = 1, .data_version = 1, .ucode = ucode, .data = data, .ucode_start = 0x3000, .data_start = 0x8000 };
}

const AmdGpuVmPageTestPool = struct {
    storage: [12][4096]u8 align(4096) = .{.{0xaa} ** 4096} ** 12,
    data_page: [4096]u8 align(4096) = .{0x5a} ** 4096,
    allocated: [12]bool = .{false} ** 12,
    fail_after: ?u4 = null,
    allocations: u4 = 0,

    fn pageAllocator(self: *AmdGpuVmPageTestPool) AmdGpuVmPageAllocator {
        return .{ .context = self, .allocate = &allocate, .release = &release, .zero = &zero };
    }
    fn allocate(context: *anyopaque) !u64 {
        const self: *AmdGpuVmPageTestPool = @ptrCast(@alignCast(context));
        if (self.fail_after != null and self.allocations == self.fail_after.?) return error.InjectedAmdGpuVmAllocationFailure;
        for (&self.allocated, 0..) |*allocated, index| if (!allocated.*) {
            allocated.* = true;
            self.allocations += 1;
            return @intFromPtr(&self.storage[index]);
        };
        return error.OutOfMemory;
    }
    fn release(context: *anyopaque, address: u64) !void {
        const self: *AmdGpuVmPageTestPool = @ptrCast(@alignCast(context));
        for (&self.storage, 0..) |*page, index| if (@intFromPtr(page) == address) {
            if (!self.allocated[index]) return error.DoubleAmdGpuVmPageRelease;
            self.allocated[index] = false;
            return;
        };
        return error.UnknownAmdGpuVmPage;
    }
    fn zero(context: *anyopaque, address: u64) !void {
        const self: *AmdGpuVmPageTestPool = @ptrCast(@alignCast(context));
        for (&self.storage) |*page| if (@intFromPtr(page) == address) {
            @memset(page, 0);
            return;
        };
        return error.UnknownAmdGpuVmPage;
    }
};

pub fn validateAmdGpuVmPageTablesSelfTest() !void {
    var pool = AmdGpuVmPageTestPool{};
    var tables = try allocateAmdGpuVmPageTables(pool.pageAllocator());
    if (tables.count != 4 or tables.root() != @intFromPtr(&pool.storage[0])) return error.AmdGpuVmPageTableAllocationMismatch;
    for (tables.pages) |address| for (@as([*]const u8, @ptrFromInt(address))[0..4096]) |byte|
        if (byte != 0) return error.AmdGpuVmPageTableNotZero;
    const path = try amdGpuVmPagePath(0x00007f1234567000);
    const data_page = @intFromPtr(&pool.storage[4]);
    try linkAmdGpuVmPagePath(&tables, path, data_page, (1 << 1) | (1 << 2));
    const pdb2: [*]const u64 = @ptrFromInt(tables.pages[0]);
    const pdb1: [*]const u64 = @ptrFromInt(tables.pages[1]);
    const pdb0: [*]const u64 = @ptrFromInt(tables.pages[2]);
    const ptb: [*]const u64 = @ptrFromInt(tables.pages[3]);
    if (pdb2[path.pdb2] != try amdGpuVmSystemPde(tables.pages[1], amd_gpu_pde_bfs_9) or
        pdb1[path.pdb1] != try amdGpuVmSystemPde(tables.pages[2], amd_gpu_pte_translate_further) or
        pdb0[path.pdb0] != try amdGpuVmSystemPde(tables.pages[3], 0) or
        ptb[path.ptb] != try amdGpuVmSystemPte(data_page, (1 << 1) | (1 << 2)))
        return error.AmdGpuVmPageLinkMismatch;
    if (linkAmdGpuVmPagePath(&tables, path, tables.pages[0], 1 << 1)) return error.AmdGpuVmPageCollisionNotDetected else |err| if (err != error.AmdGpuVmPagePathCollision) return err;
    const outside_path = try amdGpuVmPagePath(0x0000010000000000);
    if (linkAmdGpuVmPagePath(&tables, outside_path, data_page, 1 << 1)) return error.AmdGpuVmOutsideBranchAccepted else |err| if (err != error.AmdGpuVmPagePathOutsideMaterializedBranch) return err;
    try releaseAmdGpuVmPageTables(&tables, pool.pageAllocator());
    for (pool.allocated) |allocated| if (allocated) return error.AmdGpuVmPageTableReleaseLeak;

    pool = AmdGpuVmPageTestPool{ .fail_after = 2 };
    if (allocateAmdGpuVmPageTables(pool.pageAllocator())) |_| return error.AmdGpuVmPageFailureNotDetected else |err| if (err != error.InjectedAmdGpuVmAllocationFailure) return err;
    for (pool.allocated) |allocated| if (allocated) return error.AmdGpuVmPageRollbackLeak;

    pool = AmdGpuVmPageTestPool{};
    var manager = AmdGpuVmManager{};
    const vm = try manager.allocate();
    try manager.materialize(vm.vmid, pool.pageAllocator());
    if (manager.release(vm.vmid)) return error.AmdGpuVmReleasedWithPageTables else |err| if (err != error.AmdGpuVmPageTablesStillAllocated) return err;
    const vm_data_page = @intFromPtr(&pool.data_page);
    try manager.mapSystemPage(vm.vmid, 1, 0x200000000, 0, 0x1000, vm_data_page, 1 << 1);
    try manager.mapSystemPage(vm.vmid, 2, 0x10000000000, 0, 0x1000, vm_data_page, 1 << 1);
    try manager.mapSystemPage(vm.vmid, 3, 0x200001000, 0, 0x1000, vm_data_page, 1 << 1);
    var branch_counts = vm.page_tree.branches.counts();
    if (branch_counts.pdb1 != 2 or branch_counts.pdb0 != 2 or branch_counts.ptb != 2 or branch_counts.mapped_pages != 3)
        return error.AmdGpuVmDynamicBranchMaterializationMismatch;
    var active_mappings: usize = 0;
    for (vm.mappings) |mapping| if (mapping.active) {
        active_mappings += 1;
    };
    if (active_mappings != 3) return error.AmdGpuVmDynamicMappingCountMismatch;
    if (manager.dematerialize(vm.vmid)) return error.AmdGpuVmDematerializedWithMappings else |err| if (err != error.AmdGpuVmMappingsStillActive) return err;
    if (try manager.validateSystemPageMapping(vm.vmid, 1, 0x200000000, 0, vm_data_page) != 1 << 1)
        return error.AmdGpuVmMappingValidationFlagsMismatch;
    if (manager.validateSystemPageMapping(vm.vmid, 99, 0x200000000, 0, vm_data_page)) |_| return error.AmdGpuVmWrongHandleValidated else |err| if (err != error.AmdGpuVaMappingNotFound) return err;
    if (manager.validateSystemPageMapping(vm.vmid, 1, 0x200000000, 0, vm_data_page + 4096)) |_| return error.AmdGpuVmWrongPhysicalPageValidated else |err| if (err != error.AmdGpuVmPteMismatch) return err;
    try manager.unmapSystemPage(vm.vmid, 0x200000000, vm_data_page, 1 << 1);
    const vm_path = try amdGpuVmPagePath(0x200000000);
    const vm_ptb_index = vm.page_tree.branches.findPtb(vm_path) orelse return error.AmdGpuVmSharedPtbPrunedEarly;
    const vm_ptb: [*]const u64 = @ptrFromInt(vm.page_tree.branches.ptb_nodes[vm_ptb_index].page);
    if (vm_ptb[vm_path.ptb] != 0) return error.AmdGpuVmPteUnmapFailed;
    try manager.unmapSystemPage(vm.vmid, 0x200001000, vm_data_page, 1 << 1);
    try manager.unmapSystemPage(vm.vmid, 0x10000000000, vm_data_page, 1 << 1);
    branch_counts = vm.page_tree.branches.counts();
    if (branch_counts.pdb1 != 0 or branch_counts.pdb0 != 0 or branch_counts.ptb != 0 or branch_counts.mapped_pages != 0)
        return error.AmdGpuVmDynamicBranchPruneMismatch;
    try manager.dematerialize(vm.vmid);
    try manager.release(vm.vmid);
    for (pool.allocated) |allocated| if (allocated) return error.AmdGpuVmLifecyclePageLeak;

    pool = AmdGpuVmPageTestPool{ .fail_after = 2 };
    manager = AmdGpuVmManager{};
    const failing_vm = try manager.allocate();
    try manager.materialize(failing_vm.vmid, pool.pageAllocator());
    if (manager.mapSystemPage(failing_vm.vmid, 1, 0x400000000, 0, 0x1000, @intFromPtr(&pool.data_page), 1 << 1))
        return error.AmdGpuVmDynamicAllocationFailureNotDetected
    else |err| if (err != error.InjectedAmdGpuVmAllocationFailure) return err;
    branch_counts = failing_vm.page_tree.branches.counts();
    if (branch_counts.pdb1 != 0 or branch_counts.pdb0 != 0 or branch_counts.ptb != 0 or branch_counts.mapped_pages != 0)
        return error.AmdGpuVmDynamicAllocationRollbackMismatch;
    active_mappings = 0;
    for (failing_vm.mappings) |mapping| if (mapping.active) {
        active_mappings += 1;
    };
    if (active_mappings != 0) return error.AmdGpuVmDynamicLogicalRollbackMismatch;
    var allocated_pages: usize = 0;
    for (pool.allocated) |allocated| if (allocated) {
        allocated_pages += 1;
    };
    if (allocated_pages != 1) return error.AmdGpuVmDynamicPhysicalRollbackLeak;
    try manager.dematerialize(failing_vm.vmid);
    try manager.release(failing_vm.vmid);
    for (pool.allocated) |allocated| if (allocated) return error.AmdGpuVmDynamicRootReleaseLeak;
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
        .context1_page_table_base_low = try resolveAmdRegister(plan.mmhub_base, 0x07ad, register_bar_bytes),
        .context1_page_table_base_high = try resolveAmdRegister(plan.mmhub_base, 0x07ae, register_bar_bytes),
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
        0x060301,
        0x070700,
        0x070701,
        0x070900,
        0x070901,
        0x070b00,
        0x070b01,
        0x070b02,
        0x070b03,
        0x070b04,
        0x070b05,
        => {},
        else => return error.UnsupportedAmdGmc11NbioVersion,
    }
    return .{
        .memsize = try resolveAmdRegister(ip.bases[2], 0x00c3, register_bar_bytes),
        .revision_strap = try resolveAmdRegister(ip.bases[2], 0x0015, register_bar_bytes),
    };
}

pub fn decodeAmdGfx11AsicIdentity(gfx: *const AmdIp, revision_strap: u32) !AmdGfx11AsicIdentity {
    if (gfx.hw_id != amd_hw_id.gfx or gfx.instance != 0 or gfx.major != 11 or gfx.minor != 0)
        return error.UnsupportedAmdGfx11AsicIdentity;
    const chip_rev: u8 = @truncate((revision_strap >> 24) & 0x0f);
    const external_rev: u8 = switch (gfx.revision) {
        0, 1 => chip_rev + 0x01,
        2 => chip_rev + 0x10,
        3 => chip_rev + 0x20,
        4 => chip_rev + 0x80,
        else => return error.UnsupportedAmdGfx11AsicIdentity,
    };
    const family: u32 = switch (gfx.revision) {
        0, 2, 3 => 145,
        1, 4 => 148,
        else => unreachable,
    };
    return .{ .device_id = @truncate(revision_strap), .chip_rev = chip_rev, .external_rev = external_rev, .family = family };
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

pub fn validateAmdPspRingProtocolSelfTest() !void {
    var table = [_]u64{0} ** 512;
    const staging = AmdPspGttStaging{
        .page_table_address = @intFromPtr(&table),
        .page_table_pages = 1,
        .buffer_address = 0x800000,
        .buffer_pages = 3,
    };
    table[0] = amdGttPte(0x800000);
    table[1] = amdGttPte(0x801000);
    table[2] = amdGttPte(0x802000);
    const layout = try planAmdPspRingLayout(staging, 0x2000000);
    var ip = AmdIp{ .hw_id = amd_hw_id.psp, .major = 13, .minor = 0, .revision = 2, .base_count = 1 };
    ip.bases[0] = 0x100;
    const registers = try resolveAmdPsp13RingRegisters(&ip, 0x2000);
    const bootstrap = try planAmdPsp13RingBootstrap(registers, layout, 0x80000000);
    if (layout.command_mc_address != 0x2001000 or layout.fence_mc_address != 0x2002000 or
        bootstrap.writes[0].offset != registers.ring_address_low or bootstrap.writes[2].value != 4096 or
        bootstrap.writes[3].value != 0x00020000)
        return error.AmdPspRingBootstrapSelfTestFailed;

    var firmware = AmdGfx11CpFirmwareStaging{ .count = 2 };
    firmware.areas[0] = .{ .kind = .rs64_pfp, .address = 0x900000, .pages = 1, .bytes = 64 };
    firmware.areas[1] = .{ .kind = .rs64_me, .address = 0xa00000, .pages = 2, .bytes = 5000 };
    const gpu_firmware = try mapAmdGfx11CpFirmwareIntoGart(staging, firmware, 15, 0x2000000);
    if (gpu_firmware.first_gart_page != 16 or gpu_firmware.gart_pages != 3 or
        gpu_firmware.areas[0].address != 0x2010000 or gpu_firmware.areas[1].address != 0x2011000 or
        table[16] != amdGttPte(0x900000) or table[18] != amdGttPte(0xa01000))
        return error.AmdCpFirmwareGartSelfTestFailed;

    const command = try encodeAmdPspLoadIpFirmware(gpu_firmware.areas[0], layout, 1008, 7);
    if (command.command[0] != 0 or command.command[1] != 0 or command.command[2] != 6 or
        command.command[7] != 0x02010000 or command.command[9] != 64 or command.command[10] != 87 or
        command.frame[0] != 0x02001000 or command.frame[3] != 0x02002000 or command.frame[5] != 7 or
        command.ring_dword != 1008 or command.next_write_pointer != 0)
        return error.AmdPspLoadIpFirmwareEncodingSelfTestFailed;
    if (encodeAmdPspLoadIpFirmware(gpu_firmware.areas[0], layout, 1, 7)) |_|
        return error.UnalignedAmdPspWritePointerAccepted
    else |err| if (err != error.InvalidAmdPspLoadIpFirmware) return err;
    if (planAmdPsp13RingBootstrap(registers, layout, 0)) |_|
        return error.UnreadyAmdPspRingAccepted
    else |err| if (err != error.AmdPspRingNotReady) return err;

    const MockPspRing = struct {
        registers: AmdPspRingRegisters,
        control: u32 = 0x80000000,
        write_pointer: u32 = 0,
        ring_low: u32 = 0,
        ring_high: u32 = 0,
        ring_size: u32 = 0,
        response_reads: u32 = 0,
        complete_commands: bool = true,
        fail_write_once: ?u32 = null,
        ring: *[1024]u32,
        command: *[1024]u32,
        fence: *u32,

        fn read(context: *anyopaque, offset: u32) !u32 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (offset == self.registers.control) {
                if ((self.control == 0x00020000 or self.control == 0x00030000) and self.response_reads != 0) {
                    self.response_reads -= 1;
                    if (self.response_reads == 0) self.control = 0x80000000;
                }
                return self.control;
            }
            if (offset == self.registers.write_pointer) return self.write_pointer;
            if (offset == self.registers.ring_address_low) return self.ring_low;
            if (offset == self.registers.ring_address_high) return self.ring_high;
            if (offset == self.registers.ring_size) return self.ring_size;
            return error.UnknownAmdPspRingRegister;
        }

        fn write(context: *anyopaque, offset: u32, value: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail_write_once != null and self.fail_write_once.? == offset) {
                self.fail_write_once = null;
                return error.InjectedAmdPspRingWriteFailure;
            }
            if (offset == self.registers.control) {
                self.control = value;
                self.response_reads = 2;
                return;
            }
            if (offset == self.registers.ring_address_low) {
                self.ring_low = value;
                return;
            }
            if (offset == self.registers.ring_address_high) {
                self.ring_high = value;
                return;
            }
            if (offset == self.registers.ring_size) {
                self.ring_size = value;
                return;
            }
            if (offset == self.registers.write_pointer) {
                const old = self.write_pointer;
                self.write_pointer = value;
                if (self.complete_commands) {
                    self.command[216] = 0;
                    self.fence.* = self.ring[old + 5];
                }
                return;
            }
            return error.UnknownAmdPspRingRegister;
        }

        fn io(self: *@This()) AmdRegisterIo {
            return .{ .context = self, .read = &read, .write = &write };
        }
    };
    var buffers: [3][4096]u8 align(4096) = .{.{0} ** 4096} ** 3;
    const live_staging = AmdPspGttStaging{ .buffer_address = @intFromPtr(&buffers), .buffer_pages = 3 };
    const ring_memory: *[1024]u32 = @ptrCast(@alignCast(&buffers[0]));
    const command_memory: *[1024]u32 = @ptrCast(@alignCast(&buffers[1]));
    const fence_memory: *u32 = @ptrCast(@alignCast(&buffers[2]));
    var mock = MockPspRing{ .registers = registers, .ring = ring_memory, .command = command_memory, .fence = fence_memory };
    const activation = try activateAmdPsp13Ring(bootstrap, mock.io(), 4);
    if (activation.write_pointer != 0 or activation.polls != 2 or mock.ring_size != 4096)
        return error.AmdPspRingActivationSelfTestFailed;
    const loaded = try loadAmdPspIpFirmwareSequence(gpu_firmware, layout, live_staging, registers, activation.write_pointer, mock.io(), 4);
    if (loaded.loaded != 2 or loaded.final_fence != 2 or loaded.final_write_pointer != 32 or
        mock.write_pointer != 32 or fence_memory.* != 2)
        return error.AmdPspFirmwareLoadSequenceSelfTestFailed;
    mock.complete_commands = false;
    if (loadAmdPspIpFirmwareSequence(gpu_firmware, layout, live_staging, registers, mock.write_pointer, mock.io(), 2)) |_|
        return error.AmdPspFirmwareLoadTimeoutAccepted
    else |err| if (err != error.AmdPspLoadIpFirmwareTimeout or mock.control != 0x80000000)
        return error.AmdPspFirmwareLoadRollbackSelfTestFailed;
    var failing_mock = MockPspRing{ .registers = registers, .ring = ring_memory, .command = command_memory, .fence = fence_memory };
    failing_mock.fail_write_once = registers.ring_size;
    if (activateAmdPsp13Ring(bootstrap, failing_mock.io(), 4)) |_|
        return error.AmdPspRingBootstrapFailureAccepted
    else |err| if (err != error.InjectedAmdPspRingWriteFailure or failing_mock.ring_low != 0 or
        failing_mock.ring_high != 0 or failing_mock.ring_size != 0 or failing_mock.write_pointer != 0)
        return error.AmdPspRingBootstrapRollbackSelfTestFailed;
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
    if (nbio_registers.memsize != 0x170c or nbio_registers.revision_strap != 0x1454)
        @compileError("GMC 11 NBIO registers resolved incorrectly");
    const navi31_identity = decodeAmdGfx11AsicIdentity(&AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .minor = 0, .revision = 0 }, 0x0300744c) catch
        @compileError("GFX11 ASIC identity decoding failed");
    if (navi31_identity.device_id != 0x744c or navi31_identity.chip_rev != 3 or navi31_identity.external_rev != 4 or navi31_identity.family != 145)
        @compileError("GFX11 ASIC identity decoded incorrectly");
    const gc_11_0_1_identity = decodeAmdGfx11AsicIdentity(&AmdIp{ .hw_id = amd_hw_id.gfx, .major = 11, .minor = 0, .revision = 4 }, 0x02007480) catch
        @compileError("GC 11.0.1 ASIC identity decoding failed");
    if (gc_11_0_1_identity.external_rev != 0x82 or gc_11_0_1_identity.family != 148)
        @compileError("GC 11.0.1 ASIC identity decoded incorrectly");
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
    for (vram_allocator.reservations[0..vram_allocator.reservation_count]) |reservation| if (reservation.start == memory_snapshot.vram_mc_base and reservation.end == visible_vram.framebuffer_mc_end) {
        found_boot_prefix = true;
    };
    if (vram_allocator.reservation_count != 1 or !found_boot_prefix)
        @compileError("GMC 11 boot VRAM reservations were imported incorrectly");
    vram_allocator.reserve(memory_snapshot.vram_mc_base + 8 * 1024 * 1024, 12 * 1024 * 1024) catch
        @compileError("overlapping GMC 11 firmware reservations were not normalized");
    found_boot_prefix = false;
    for (vram_allocator.reservations[0..vram_allocator.reservation_count]) |reservation| if (reservation.start == memory_snapshot.vram_mc_base and reservation.end == visible_vram.framebuffer_mc_end) {
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
pub const AmdPspRingRegisters = struct {
    control: u32,
    write_pointer: u32,
    ring_address_low: u32,
    ring_address_high: u32,
    ring_size: u32,
};
pub const AmdPspRingLayout = struct {
    ring_mc_address: u64,
    command_mc_address: u64,
    fence_mc_address: u64,
    ring_bytes: u32 = 4096,
    command_bytes: u32 = 4096,
};
pub const AmdPspRingBootstrap = struct {
    registers: AmdPspRingRegisters,
    initial_control: u32,
    writes: [4]AmdRegisterWrite,
};
pub const AmdPspLoadIpFirmwareCommand = struct {
    command: [256]u32 = .{0} ** 256,
    frame: [16]u32 = .{0} ** 16,
    ring_dword: u32,
    next_write_pointer: u32,
    fence_value: u32,
};
pub const AmdPspRingActivation = struct { write_pointer: u32, polls: u32 };
pub const AmdPspFirmwareLoadResult = struct { loaded: usize, final_write_pointer: u32, final_fence: u32, polls: u32, response_warnings: u32 };
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

pub fn resolveAmdPsp13RingRegisters(ip: *const AmdIp, register_bar_bytes: u64) !AmdPspRingRegisters {
    if (ip.hw_id != amd_hw_id.psp or ip.instance != 0 or ip.base_count == 0 or version(ip) != 0x0d0002)
        return error.UnsupportedAmdPspRingRegisters;
    const base = ip.bases[0];
    const messages = .{ @as(u64, 64), 67, 69, 70, 71 };
    var offsets: [5]u32 = undefined;
    inline for (messages, 0..) |message, index| {
        const dword = std.math.add(u64, base, 0x40 + message) catch return error.AmdPspRegisterOffsetOverflow;
        const offset = std.math.mul(u64, dword, 4) catch return error.AmdPspRegisterOffsetOverflow;
        if (offset > ~@as(u32, 0) or register_bar_bytes < 4 or offset > register_bar_bytes - 4)
            return error.AmdPspRegistersOutsideBar;
        offsets[index] = @intCast(offset);
    }
    return .{
        .control = offsets[0],
        .write_pointer = offsets[1],
        .ring_address_low = offsets[2],
        .ring_address_high = offsets[3],
        .ring_size = offsets[4],
    };
}

pub fn planAmdPspRingLayout(staging: AmdPspGttStaging, window_start: u64) !AmdPspRingLayout {
    if (staging.page_table_address == 0 or staging.page_table_pages != 1 or staging.buffer_address == 0 or
        staging.buffer_pages != 3 or staging.ring_page != 0 or staging.command_page != 1 or staging.fence_page != 2 or
        (window_start & 4095) != 0)
        return error.InvalidAmdPspRingLayout;
    const table: [*]const u64 = @ptrFromInt(staging.page_table_address);
    if (table[0] != amdGttPte(staging.buffer_address) or table[1] != amdGttPte(staging.buffer_address + 4096) or
        table[2] != amdGttPte(staging.buffer_address + 8192))
        return error.InvalidAmdPspRingGartMapping;
    return .{
        .ring_mc_address = window_start,
        .command_mc_address = window_start + 4096,
        .fence_mc_address = window_start + 8192,
    };
}

pub fn planAmdPsp13RingBootstrap(registers: AmdPspRingRegisters, layout: AmdPspRingLayout, initial_control: u32) !AmdPspRingBootstrap {
    if ((initial_control & 0x8000ffff) != 0x80000000 or layout.ring_mc_address == 0 or
        (layout.ring_mc_address & 4095) != 0 or layout.ring_bytes != 4096)
        return error.AmdPspRingNotReady;
    return .{
        .registers = registers,
        .initial_control = initial_control,
        .writes = .{
            .{ .offset = registers.ring_address_low, .value = @truncate(layout.ring_mc_address) },
            .{ .offset = registers.ring_address_high, .value = @truncate(layout.ring_mc_address >> 32) },
            .{ .offset = registers.ring_size, .value = layout.ring_bytes },
            .{ .offset = registers.control, .value = 0x00020000, .verify_mask = 0 },
        },
    };
}

pub fn encodeAmdPspLoadIpFirmware(
    area: AmdPspIpFirmwareGpuArea,
    layout: AmdPspRingLayout,
    write_pointer: u32,
    fence_value: u32,
) !AmdPspLoadIpFirmwareCommand {
    const ring_dwords = layout.ring_bytes / 4;
    if (area.address == 0 or (area.address & 4095) != 0 or area.bytes == 0 or
        (layout.command_mc_address & 4095) != 0 or (layout.fence_mc_address & 4095) != 0 or
        layout.command_bytes != 4096 or ring_dwords != 1024 or write_pointer >= ring_dwords or
        (write_pointer & 15) != 0 or fence_value == 0)
        return error.InvalidAmdPspLoadIpFirmware;
    var result = AmdPspLoadIpFirmwareCommand{
        .ring_dword = write_pointer,
        .next_write_pointer = (write_pointer + 16) % ring_dwords,
        .fence_value = fence_value,
    };
    // Linux leaves the generic size/version fields zero for GPCOM and fills
    // only cmd_id plus the LOAD_IP_FW union at byte 28.
    result.command[2] = 0x00000006;
    result.command[7] = @truncate(area.address);
    result.command[8] = @truncate(area.address >> 32);
    result.command[9] = area.bytes;
    result.command[10] = @intFromEnum(area.kind);
    result.frame[0] = @truncate(layout.command_mc_address);
    result.frame[1] = @truncate(layout.command_mc_address >> 32);
    result.frame[3] = @truncate(layout.fence_mc_address);
    result.frame[4] = @truncate(layout.fence_mc_address >> 32);
    result.frame[5] = fence_value;
    return result;
}

pub fn destroyAmdPsp13Ring(registers: AmdPspRingRegisters, io: AmdRegisterIo, poll_limit: u32) !u32 {
    if (poll_limit == 0) return error.InvalidAmdPspRingPollLimit;
    try io.write(io.context, registers.control, 0x00030000);
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const control = try io.read(io.context, registers.control);
        if ((control & 0x8000ffff) == 0x80000000) return polls;
        asm volatile ("pause");
    }
    return error.AmdPspRingDestroyTimeout;
}

pub fn activateAmdPsp13Ring(bootstrap: AmdPspRingBootstrap, io: AmdRegisterIo, poll_limit: u32) !AmdPspRingActivation {
    if (poll_limit == 0) return error.InvalidAmdPspRingPollLimit;
    const snapshot = [5]u32{
        try io.read(io.context, bootstrap.registers.control),
        try io.read(io.context, bootstrap.registers.write_pointer),
        try io.read(io.context, bootstrap.registers.ring_address_low),
        try io.read(io.context, bootstrap.registers.ring_address_high),
        try io.read(io.context, bootstrap.registers.ring_size),
    };
    if (snapshot[0] != bootstrap.initial_control)
        return error.AmdPspRingBootstrapStateChanged;
    var applied: usize = 0;
    errdefer {
        if (applied == bootstrap.writes.len) _ = destroyAmdPsp13Ring(bootstrap.registers, io, poll_limit) catch {};
        io.write(io.context, bootstrap.registers.write_pointer, snapshot[1]) catch {};
        io.write(io.context, bootstrap.registers.ring_size, snapshot[4]) catch {};
        io.write(io.context, bootstrap.registers.ring_address_high, snapshot[3]) catch {};
        io.write(io.context, bootstrap.registers.ring_address_low, snapshot[2]) catch {};
    }
    for (bootstrap.writes) |write| {
        try io.write(io.context, write.offset, write.value);
        applied += 1;
        if (write.verify_mask != 0) {
            const observed = try io.read(io.context, write.offset);
            if ((observed & write.verify_mask) != (write.value & write.verify_mask)) return error.AmdPspRingBootstrapReadbackFailed;
        }
    }
    var polls: u32 = 0;
    while (polls < poll_limit) {
        polls += 1;
        const control = try io.read(io.context, bootstrap.registers.control);
        if ((control & 0x8000ffff) == 0x80000000) {
            const write_pointer = try io.read(io.context, bootstrap.registers.write_pointer);
            if (write_pointer >= 1024 or (write_pointer & 15) != 0) return error.InvalidAmdPspRingWritePointer;
            return .{ .write_pointer = write_pointer, .polls = polls };
        }
        asm volatile ("pause");
    }
    return error.AmdPspRingBootstrapTimeout;
}

pub fn loadAmdPspIpFirmwareSequence(
    firmware: AmdGfx11CpFirmwareGpuLayout,
    layout: AmdPspRingLayout,
    staging: AmdPspGttStaging,
    registers: AmdPspRingRegisters,
    initial_write_pointer: u32,
    io: AmdRegisterIo,
    poll_limit: u32,
) !AmdPspFirmwareLoadResult {
    if (firmware.count == 0 or firmware.count > firmware.areas.len or poll_limit == 0 or
        staging.buffer_address == 0 or staging.buffer_pages != 3)
        return error.InvalidAmdPspFirmwareLoadSequence;
    var result = AmdPspFirmwareLoadResult{ .loaded = 0, .final_write_pointer = initial_write_pointer, .final_fence = 0, .polls = 0, .response_warnings = 0 };
    errdefer _ = destroyAmdPsp13Ring(registers, io, poll_limit) catch {};
    const ring: [*]u32 = @ptrFromInt(staging.buffer_address);
    const command_page: *[1024]u32 = @ptrFromInt(staging.buffer_address + 4096);
    const response_status: *const volatile u32 = @ptrFromInt(staging.buffer_address + 4096 + 864);
    const fence: *volatile u32 = @ptrFromInt(staging.buffer_address + 8192);
    for (firmware.areas[0..firmware.count]) |area| {
        if (result.final_fence == std.math.maxInt(u32)) return error.AmdPspFenceOverflow;
        const fence_value = result.final_fence + 1;
        const encoded = try encodeAmdPspLoadIpFirmware(area, layout, result.final_write_pointer, fence_value);
        @memset(command_page, 0);
        @memcpy(command_page[0..encoded.command.len], &encoded.command);
        const frame = ring[encoded.ring_dword .. encoded.ring_dword + encoded.frame.len];
        @memset(frame, 0);
        @memcpy(frame, &encoded.frame);
        fence.* = 0;
        asm volatile ("" ::: .{ .memory = true });
        try io.write(io.context, registers.write_pointer, encoded.next_write_pointer);
        var command_polls: u32 = 0;
        while (command_polls < poll_limit and fence.* != fence_value) {
            command_polls += 1;
            asm volatile ("pause");
        }
        result.polls +|= command_polls;
        if (fence.* != fence_value) return error.AmdPspLoadIpFirmwareTimeout;
        if (response_status.* != 0) result.response_warnings += 1;
        result.loaded += 1;
        result.final_write_pointer = encoded.next_write_pointer;
        result.final_fence = fence_value;
    }
    return result;
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

fn version(ip: *const AmdIp) u32 {
    return (@as(u32, ip.major) << 16) | (@as(u32, ip.minor) << 8) | ip.revision;
}
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
        0x0a0000,
        0x0a0001,
        0x0b0002,
        0x0b0004,
        0x0b0008,
        0x0b0003,
        0x0c0001,
        0x0d0002,
        0x0d0006,
        0x0d000c,
        0x0d000e,
        0x0d000f,
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
    if (table_count > 1) result.gc_info = try parseAmdGcInfoTable(bytes[0..binary_size], table_list + 8);
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

fn parseAmdGcInfoTable(bytes: []const u8, descriptor: usize) !?AmdGcInfo {
    const offset: usize = readLittle16(bytes, descriptor);
    if (offset == 0) return null;
    const checksum = readLittle16(bytes, descriptor + 2);
    const descriptor_size: usize = readLittle16(bytes, descriptor + 4);
    if (offset > bytes.len or bytes.len - offset < 12) return error.InvalidAmdGcInfoOffset;
    if (readLittle32(bytes, offset) != 0x4347) return error.InvalidAmdGcInfoSignature;
    const major = readLittle16(bytes, offset + 4);
    const minor = readLittle16(bytes, offset + 6);
    const size: usize = readLittle32(bytes, offset + 8);
    const minimum_size: usize = if (major == 1 and minor == 0) 88 else if (major == 1 and minor == 1) 100 else if (major == 1 and minor == 2) 132 else if (major == 1 and minor == 3) 164 else return error.UnsupportedAmdGcInfoVersion;
    if (size < minimum_size or descriptor_size != size or size > bytes.len - offset) return error.InvalidAmdGcInfoSize;
    if (byteSum(bytes[offset .. offset + size]) != checksum) return error.InvalidAmdGcInfoChecksum;
    const result = AmdGcInfo{
        .version_minor = minor,
        .num_shader_engines = @intCast(readLittle32(bytes, offset + 12)),
        .num_wgp0_per_sa = @intCast(readLittle32(bytes, offset + 16)),
        .num_wgp1_per_sa = @intCast(readLittle32(bytes, offset + 20)),
        .num_rb_per_se = @intCast(readLittle32(bytes, offset + 24)),
        .num_tcc_blocks = @intCast(readLittle32(bytes, offset + 28)),
        .gs_vgt_table_depth = @intCast(readLittle32(bytes, offset + 40)),
        .gs_prim_buffer_depth = @intCast(readLittle32(bytes, offset + 44)),
        .double_offchip_lds_buf = @intCast(readLittle32(bytes, offset + 52)),
        .wave_front_size = @intCast(readLittle32(bytes, offset + 56)),
        .num_shader_arrays_per_engine = @intCast(readLittle32(bytes, offset + 76)),
        .num_tcp_per_sa = if (minor >= 1) @intCast(readLittle32(bytes, offset + 88)) else 0,
        .tcp_l1_size = if (minor >= 2) @intCast(readLittle32(bytes, offset + 104)) else 0,
        .num_sqc_per_wgp = if (minor >= 2) @intCast(readLittle32(bytes, offset + 108)) else 0,
        .sqc_instruction_cache_size = if (minor >= 2) @intCast(readLittle32(bytes, offset + 112)) else 0,
        .sqc_data_cache_size = if (minor >= 2) @intCast(readLittle32(bytes, offset + 116)) else 0,
        .gl1c_per_sa = if (minor >= 2) @intCast(readLittle32(bytes, offset + 120)) else 0,
        .gl1c_size_per_instance = if (minor >= 2) @intCast(readLittle32(bytes, offset + 124)) else 0,
        .gl2c_per_gpu = if (minor >= 2) @intCast(readLittle32(bytes, offset + 128)) else 0,
    };
    if (result.num_shader_engines == 0 or result.num_shader_engines > 8 or
        result.num_shader_arrays_per_engine == 0 or result.num_shader_arrays_per_engine > 4 or
        result.num_wgp0_per_sa > 32 or result.num_wgp1_per_sa > 32 or result.num_rb_per_se > 16 or
        result.num_tcc_blocks > 64 or (result.wave_front_size != 32 and result.wave_front_size != 64) or
        result.maxCuPerShaderArray() == 0 or result.maxCuPerShaderArray() > 128)
        return error.InvalidAmdGcInfoTopology;
    return result;
}

fn isCriticalAmdIp(hw_id: u16) bool {
    return hw_id == amd_hw_id.smu or hw_id == amd_hw_id.gfx or hw_id == amd_hw_id.mmhub or hw_id == amd_hw_id.osssys or
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
    @setEvalBranchQuota(5000);
    var sample = [_]u8{0} ** 288;
    writeLittle32(&sample, 0, 0x28211407);
    writeLittle16(&sample, 4, 1);
    writeLittle16(&sample, 10, sample.len);
    writeLittle16(&sample, 12, 60);
    writeLittle16(&sample, 16, 96);
    writeLittle16(&sample, 20, 156);
    writeLittle16(&sample, 24, 132);
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
    writeLittle32(&sample, 156, 0x4347);
    writeLittle16(&sample, 160, 1);
    writeLittle16(&sample, 162, 2);
    writeLittle32(&sample, 164, 132);
    writeLittle32(&sample, 168, 6);
    writeLittle32(&sample, 172, 4);
    writeLittle32(&sample, 176, 4);
    writeLittle32(&sample, 180, 2);
    writeLittle32(&sample, 184, 16);
    writeLittle32(&sample, 196, 32);
    writeLittle32(&sample, 200, 64);
    writeLittle32(&sample, 208, 512);
    writeLittle32(&sample, 212, 32);
    writeLittle32(&sample, 232, 2);
    writeLittle32(&sample, 244, 4);
    writeLittle32(&sample, 260, 32);
    writeLittle32(&sample, 264, 2);
    writeLittle32(&sample, 268, 32);
    writeLittle32(&sample, 272, 16);
    writeLittle32(&sample, 276, 4);
    writeLittle32(&sample, 280, 32);
    writeLittle32(&sample, 284, 16);
    writeLittle16(&sample, 22, byteSum(sample[156..288]));
    writeLittle16(&sample, 14, byteSum(sample[60..156]));
    writeLittle16(&sample, 8, byteSum(sample[10..288]));
    const discovery = parseAmdIpDiscovery(&sample) catch @compileError("AMDGPU IP discovery sample was rejected");
    const sdma = discovery.find(amd_hw_id.sdma0, 0);
    if (discovery.table_version != 3 or discovery.dies != 1 or discovery.ips != 1 or discovery.base_addresses != 1 or sdma == null or sdma.?.major != 11 or sdma.?.bases[0] != 0x1234 or
        discovery.gc_info == null or discovery.gc_info.?.num_shader_engines != 6 or discovery.gc_info.?.maxCuPerShaderArray() != 16 or
        discovery.gc_info.?.num_shader_arrays_per_engine != 2 or discovery.gc_info.?.num_tcc_blocks != 16 or discovery.gc_info.?.wave_front_size != 32 or
        discovery.gc_info.?.num_sqc_per_wgp != 2 or discovery.gc_info.?.sqc_instruction_cache_size != 32)
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

pub fn validateAmdgpuFirmware(bytes: []const u8) !void {
    _ = try parseAmdgpuFirmware(bytes);
}

pub fn validateAmdGfx11FirmwarePreflightSelfTest() !void {
    var cp_image = [_]u8{0} ** 68;
    writeLittle32(&cp_image, 0, cp_image.len);
    writeLittle32(&cp_image, 4, 60);
    writeLittle16(&cp_image, 8, 2);
    writeLittle16(&cp_image, 12, 11);
    writeLittle32(&cp_image, 16, 0x1234);
    writeLittle32(&cp_image, 20, 4);
    writeLittle32(&cp_image, 24, 60);
    writeLittle32(&cp_image, 32, 7);
    writeLittle32(&cp_image, 36, 4);
    writeLittle32(&cp_image, 40, 60);
    writeLittle32(&cp_image, 44, 4);
    writeLittle32(&cp_image, 48, 64);
    writeLittle32(&cp_image, 52, 0x1000);
    cp_image[60] = 0xaa;
    cp_image[64] = 0xbb;
    const pfp = try parseAmdCpFirmware(&cp_image, .pfp);
    const me = try parseAmdCpFirmware(&cp_image, .me);
    const mec = try parseAmdCpFirmware(&cp_image, .mec);
    if (pfp.format != .rs64 or pfp.feature_version != 7 or pfp.instruction.len != 4 or pfp.data.len != 4 or
        pfp.instruction[0] != 0xaa or pfp.data[0] != 0xbb or pfp.start_address != 0x1000)
        return error.AmdCpFirmwareParserSelfTestFailed;

    var rlc_image = [_]u8{0} ** 108;
    writeLittle32(&rlc_image, 0, rlc_image.len);
    writeLittle32(&rlc_image, 4, 104);
    writeLittle16(&rlc_image, 8, 2);
    writeLittle16(&rlc_image, 12, 11);
    writeLittle32(&rlc_image, 16, 0x5678);
    writeLittle32(&rlc_image, 20, 4);
    writeLittle32(&rlc_image, 24, 104);
    writeLittle32(&rlc_image, 32, 9);
    rlc_image[104] = 0xcc;
    const rlc = try parseAmdRlcFirmware(&rlc_image);
    var cp_set = AmdGfx11CpFirmwareSet{ .pfp = pfp, .me = me, .mec = mec, .rlc = rlc };
    try cp_set.validate();
    if (rlc.feature_version != 9 or rlc.header_minor != 0 or rlc.count != 1 or
        rlc.payloads[0].kind != .rlc_g or rlc.payloads[0].data.len != 4 or rlc.payloads[0].data[0] != 0xcc)
        return error.AmdRlcFirmwareParserSelfTestFailed;
    var rlc_v24 = [_]u8{0} ** 268;
    writeLittle32(&rlc_v24, 0, rlc_v24.len);
    writeLittle32(&rlc_v24, 4, 244);
    writeLittle16(&rlc_v24, 8, 2);
    writeLittle16(&rlc_v24, 10, 4);
    writeLittle16(&rlc_v24, 12, 11);
    writeLittle32(&rlc_v24, 16, 1);
    writeLittle32(&rlc_v24, 20, 4);
    writeLittle32(&rlc_v24, 24, 244);
    inline for (0..5) |index| {
        writeLittle32(&rlc_v24, 204 + index * 8, 4);
        writeLittle32(&rlc_v24, 208 + index * 8, 248 + index * 4);
    }
    const parsed_v24 = try parseAmdRlcFirmware(&rlc_v24);
    if (parsed_v24.count != 6 or parsed_v24.payloads[1].kind != .global_tap_delays or
        parsed_v24.payloads[5].kind != .se3_tap_delays)
        return error.AmdRlcExtendedPayloadSelfTestFailed;
    const rs64_plan = try planAmdGfx11CpFirmwareSet(cp_set);
    if (rs64_plan.count != 12 or rs64_plan.payloads[0].kind != .rs64_pfp or
        rs64_plan.payloads[10].kind != .rs64_mec_p3_stack or rs64_plan.payloads[11].kind != .rlc_g)
        return error.AmdCpRs64FirmwarePlanSelfTestFailed;
    var extended_set = cp_set;
    extended_set.rlc = parsed_v24;
    const extended_plan = try planAmdGfx11CpFirmwareSet(extended_set);
    if (extended_plan.count != 17 or extended_plan.payloads[12].kind != .global_tap_delays or
        extended_plan.payloads[16].kind != .se3_tap_delays)
        return error.AmdRlcFirmwarePlanSelfTestFailed;
    var legacy_image = [_]u8{0} ** 48;
    writeLittle32(&legacy_image, 0, legacy_image.len);
    writeLittle32(&legacy_image, 4, 44);
    writeLittle16(&legacy_image, 8, 1);
    writeLittle16(&legacy_image, 12, 11);
    writeLittle32(&legacy_image, 16, 1);
    writeLittle32(&legacy_image, 20, 4);
    writeLittle32(&legacy_image, 24, 44);
    var legacy_mec_image = [_]u8{0} ** 52;
    @memcpy(legacy_mec_image[0..44], legacy_image[0..44]);
    writeLittle32(&legacy_mec_image, 0, legacy_mec_image.len);
    writeLittle32(&legacy_mec_image, 20, 8);
    writeLittle32(&legacy_mec_image, 36, 1);
    writeLittle32(&legacy_mec_image, 40, 1);
    const legacy_set = AmdGfx11CpFirmwareSet{
        .pfp = try parseAmdCpFirmware(&legacy_image, .pfp),
        .me = try parseAmdCpFirmware(&legacy_image, .me),
        .mec = try parseAmdCpFirmware(&legacy_mec_image, .mec),
        .rlc = rlc,
    };
    const legacy_plan = try planAmdGfx11CpFirmwareSet(legacy_set);
    if (legacy_plan.count != 5 or legacy_plan.payloads[0].kind != .cp_pfp or
        legacy_plan.payloads[3].kind != .cp_mec_me1 or legacy_plan.payloads[4].kind != .rlc_g)
        return error.AmdCpLegacyFirmwarePlanSelfTestFailed;
    cp_set.me.?.format = .legacy;
    if (cp_set.validate()) |_| return error.MixedAmdCpFirmwareFormatsAccepted else |err| if (err != error.MixedAmdCpFirmwareFormats) return err;

    var image = [_]u8{0} ** 80;
    writeLittle32(&image, 0, image.len);
    writeLittle32(&image, 4, 72);
    writeLittle16(&image, 8, 1);
    writeLittle16(&image, 12, 11);
    writeLittle32(&image, 16, 7);
    writeLittle32(&image, 20, 8);
    writeLittle32(&image, 24, 72);
    writeLittle32(&image, 32, 9);
    writeLittle32(&image, 36, 4);
    writeLittle32(&image, 40, 72);
    writeLittle32(&image, 44, 10);
    writeLittle32(&image, 48, 4);
    writeLittle32(&image, 52, 76);

    const mes = try parseAmdMesFirmware(&image);
    if (mes.ip_version_major != 11 or mes.ucode_version != 9 or mes.data_version != 10 or mes.ucode.len != 4 or mes.data.len != 4)
        return error.AmdMesFirmwareParserSelfTestFailed;

    var manifest = AmdGfxFirmwareManifest{ .family = .v11_0 };
    inline for (.{ AmdGfxFirmwareRole.pfp, .me, .mec, .rlc, .mes_scheduler, .mes_kiq }) |kind| try manifest.add(kind, &image);
    try manifest.validate();
    if (manifest.entries != 6 or manifest.role(.mes_scheduler).payload_bytes != 8)
        return error.AmdGfxFirmwareManifestSelfTestFailed;

    var incomplete = AmdGfxFirmwareManifest{ .family = .v11_0 };
    try incomplete.add(.mes_scheduler, &image);
    if (incomplete.validate()) |_| return error.AmdGfxFirmwareMissingRoleAccepted else |err| if (err != error.RequiredAmdGfxFirmwareMissing) return err;

    var evidence = AmdGfx11PreflightEvidence{};
    if (preflightAmdGfx11Ring(evidence) != .blocked) return error.AmdGfxRingPreflightOpenedEarly;
    evidence = .{ .firmware = true, .psp = true, .gart = true, .gpuvm = true, .ring = true, .mqd = true, .eop = true, .pointers = true, .doorbell = true };
    if (preflightAmdGfx11Ring(evidence) != .resources_ready) return error.AmdGfxRingPreflightStayedClosed;
    const contract = AmdGfx11RingContract{};
    if (contract.ring_dwords != 1024 or contract.ring_bytes != 4096 or contract.eop_bytes != 2048 or
        !contract.uses_64bit_pointers or !contract.requires_doorbell)
        return error.AmdGfxRingContractSelfTestFailed;
}

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
    boot_sclk_10khz: u32,
    boot_mclk_10khz: u32,
    core_refclk_10khz: ?u32,
    capability: u32,
    reserved_kib: u32,
};

pub const AmdGpuClockInfo = struct {
    counter_khz: u32,
    min_engine_khz: u64,
    max_engine_khz: u64,
    min_memory_khz: u64,
    max_memory_khz: u64,
};

pub fn amdGpuClockInfo(atom: AmdAtomFirmwareInfo) !AmdGpuClockInfo {
    const reference = atom.core_refclk_10khz orelse return error.AtomSmuInfoMissing;
    if (reference == 0 or atom.boot_sclk_10khz == 0 or atom.boot_mclk_10khz == 0)
        return error.InvalidAmdAtomClock;
    return .{
        .counter_khz = std.math.mul(u32, reference, 10) catch return error.InvalidAmdAtomClock,
        .min_engine_khz = std.math.mul(u64, atom.boot_sclk_10khz, 10) catch return error.InvalidAmdAtomClock,
        .max_engine_khz = std.math.mul(u64, atom.boot_sclk_10khz, 10) catch return error.InvalidAmdAtomClock,
        .min_memory_khz = std.math.mul(u64, atom.boot_mclk_10khz, 10) catch return error.InvalidAmdAtomClock,
        .max_memory_khz = std.math.mul(u64, atom.boot_mclk_10khz, 10) catch return error.InvalidAmdAtomClock,
    };
}

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
    const smu_offset = @as(usize, readLittle16(tables.master, 20));
    const core_refclk: ?u32 = if (smu_offset != 0) blk: {
        const smu = try atomTable(tables.image, smu_offset, 20);
        if (smu[2] != 3 and smu[2] != 4) return error.UnsupportedAtomSmuInfo;
        const value: u32 = @intCast(readLittle32(smu, 16));
        break :blk if (value == 0) null else value;
    } else null;
    return .{
        .format_revision = format,
        .content_revision = content,
        .boot_sclk_10khz = @intCast(readLittle32(firmware, 8)),
        .boot_mclk_10khz = @intCast(readLittle32(firmware, 12)),
        .core_refclk_10khz = core_refclk,
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
    writeLittle16(&atom, 0xd4, 0x1c0);
    writeLittle16(&atom, 0x120, 12);
    atom[0x122] = 2;
    atom[0x123] = 1;
    writeLittle32(&atom, 0x124, 0x12340);
    writeLittle16(&atom, 0x128, 64);
    writeLittle16(&atom, 0x12a, 20);
    writeLittle16(&atom, 0x160, 88);
    atom[0x162] = 3;
    atom[0x163] = 4;
    writeLittle32(&atom, 0x168, 250000);
    writeLittle32(&atom, 0x16c, 120000);
    writeLittle32(&atom, 0x170, 0x401);
    writeLittle32(&atom, 0x1b4, 3072);
    writeLittle16(&atom, 0x1c0, 20);
    atom[0x1c2] = 4;
    atom[0x1c3] = 0;
    writeLittle32(&atom, 0x1d0, 10000);
    const usage = parseAmdAtomVramUsage(&atom) catch @compileError("ATOM VRAM usage sample was rejected");
    if (usage.format_revision != 2 or usage.content_revision != 1 or usage.firmware_start_kib != 0x12340 or
        usage.firmware_kib != 64 or usage.driver_start_kib != null or usage.driver_kib != 20)
        @compileError("ATOM VRAM usage sample decoded incorrectly");
    const firmware = parseAmdAtomFirmwareInfo(&atom) catch @compileError("ATOM firmware info sample was rejected");
    if (firmware.format_revision != 3 or firmware.content_revision != 4 or firmware.boot_sclk_10khz != 250000 or
        firmware.boot_mclk_10khz != 120000 or firmware.core_refclk_10khz != 10000 or
        firmware.capability != 0x401 or firmware.reserved_kib != 3072)
        @compileError("ATOM firmware info sample decoded incorrectly");
    const clocks = amdGpuClockInfo(firmware) catch @compileError("ATOM clock sample was rejected");
    if (clocks.counter_khz != 100000 or clocks.min_engine_khz != 2500000 or clocks.max_engine_khz != 2500000 or
        clocks.min_memory_khz != 1200000 or clocks.max_memory_khz != 1200000)
        @compileError("ATOM clocks decoded incorrectly");
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

pub fn handleInterrupt() callconv(.c) void {
    _ = @atomicRmw(u64, &interrupt_count, .Add, 1, .monotonic);
}
pub fn interrupts() u64 {
    return @atomicLoad(u64, &interrupt_count, .acquire);
}
