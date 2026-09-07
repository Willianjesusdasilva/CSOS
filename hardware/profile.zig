const profile_version: u8 = 7;

pub const Cpu = struct {
    vendor: [12]u8,
    family: u16,
    model: u16,
    stepping: u8,
    tsc: bool,
    invariant_tsc: bool,
    threads_per_core: u16,
    logical_per_package: u16,
};

pub const Facts = struct {
    logical_cpus: u16,
    memory_pages: u64,
    pci_devices: u16,
    gpu_vendor: u16,
    gpu_device: u16,
    gpu_revision: u8,
    gpu_subsystem_vendor: u16,
    gpu_subsystem_device: u16,
    gpu_chipset: u16,
    gpu_chip_revision: u8,
    gpu_msi: bool,
    gpu_msix: bool,
    gpu_bus: u8,
    gpu_slot: u5,
    nvme_vendor: u16,
    nvme_device: u16,
    nvme_namespaces: u16,
    nic_vendor: u16,
    nic_device: u16,
    network_irq_apic: u32,
    usb_ports: u8,
    keyboards: u8,
    mice: u8,
    input_irq_apic: u32,
    audio_interfaces: u8,
    display_width: u32,
    display_height: u32,
    display_stride: u32,
};

pub const Profile = struct {
    bytes: [2048]u8 = undefined,
    length: usize = 0,
    signature: u64 = 0,

    pub fn text(self: *const Profile) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn addBaseline(
        self: *Profile,
        freeze_p50: u64, freeze_p95: u64, freeze_p99: u64,
        resume_p50: u64, resume_p95: u64, resume_p99: u64,
        nvme_p50: u64, nvme_p95: u64, nvme_p99: u64,
        tcp_p50: u64, tcp_p95: u64, tcp_p99: u64,
    ) !void {
        if (!validPercentiles(freeze_p50, freeze_p95, freeze_p99) or
            !validPercentiles(resume_p50, resume_p95, resume_p99) or
            !validPercentiles(nvme_p50, nvme_p95, nvme_p99) or
            !validPercentiles(tcp_p50, tcp_p95, tcp_p99)) return error.InvalidBaseline;
        const start_length = self.length;
        errdefer self.length = start_length;
        try append(self, "\n[baseline_cycles]\nfreeze_p50="); try appendDecimal(self, freeze_p50);
        try append(self, "\nfreeze_p95="); try appendDecimal(self, freeze_p95);
        try append(self, "\nfreeze_p99="); try appendDecimal(self, freeze_p99);
        try append(self, "\nresume_p50="); try appendDecimal(self, resume_p50);
        try append(self, "\nresume_p95="); try appendDecimal(self, resume_p95);
        try append(self, "\nresume_p99="); try appendDecimal(self, resume_p99);
        try append(self, "\nnvme_p50="); try appendDecimal(self, nvme_p50);
        try append(self, "\nnvme_p95="); try appendDecimal(self, nvme_p95);
        try append(self, "\nnvme_p99="); try appendDecimal(self, nvme_p99);
        try append(self, "\ntcp_p50="); try appendDecimal(self, tcp_p50);
        try append(self, "\ntcp_p95="); try appendDecimal(self, tcp_p95);
        try append(self, "\ntcp_p99="); try appendDecimal(self, tcp_p99);
        try append(self, "\n");
    }
};

fn validPercentiles(p50: u64, p95: u64, p99: u64) bool {
    return p50 <= p95 and p95 <= p99;
}

pub fn matchesSignature(text: []const u8, expected: u64) bool {
    const key = "signature=";
    var offset: usize = 0;
    while (offset + key.len <= text.len) : (offset += 1) {
        if (offset != 0 and text[offset - 1] != '\n') continue;
        if (!equalIgnoreCase(text[offset .. offset + key.len], key)) continue;
        offset += key.len;
        if (offset + 2 <= text.len and text[offset] == '0' and (text[offset + 1] == 'x' or text[offset + 1] == 'X')) offset += 2;
        var value: u64 = 0;
        var digits: usize = 0;
        while (offset < text.len) : (offset += 1) {
            const digit: u8 = if (text[offset] >= '0' and text[offset] <= '9')
                text[offset] - '0'
            else if (text[offset] >= 'a' and text[offset] <= 'f')
                text[offset] - 'a' + 10
            else if (text[offset] >= 'A' and text[offset] <= 'F')
                text[offset] - 'A' + 10
            else break;
            if (digits == 16) return false;
            value = value * 16 + digit;
            digits += 1;
        }
        const terminated = offset == text.len or text[offset] == '\n' or text[offset] == '\r' or text[offset] == ' ' or text[offset] == '\t';
        return digits != 0 and terminated and value == expected;
    }
    return false;
}

pub fn matchesPersistedProfile(text: []const u8, expected: u64) bool {
    if (!hasSystemVersion(text)) return false;
    return matchesSignature(text, expected);
}

fn hasSystemVersion(text: []const u8) bool {
    if (!containsSystemSection(text)) return false;
    const key = "version=";
    var offset: usize = 0;
    while (offset + key.len <= text.len) : (offset += 1) {
        if (offset != 0 and text[offset - 1] != '\n') continue;
        if (!equalIgnoreCase(text[offset .. offset + key.len], key)) continue;
        offset += key.len;
        var value: u16 = 0;
        var digits: usize = 0;
        while (offset < text.len) : (offset += 1) {
            const byte = text[offset];
            if (byte < '0' or byte > '9') break;
            if (digits == 3) return false;
            value = value * 10 + (byte - '0');
            digits += 1;
        }
        const terminated = offset == text.len or text[offset] == '\n' or text[offset] == '\r' or text[offset] == ' ' or text[offset] == '\t';
        return digits != 0 and terminated and value == profile_version;
    }
    return false;
}

fn containsSystemSection(text: []const u8) bool {
    const section = "[system]";
    var offset: usize = 0;
    while (offset + section.len <= text.len) : (offset += 1) {
        if (offset != 0 and text[offset - 1] != '\n') continue;
        if (equalIgnoreCase(text[offset .. offset + section.len], section)) return true;
    }
    return false;
}

fn equalIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        const lower = if (a >= 'A' and a <= 'Z') a + ('a' - 'A') else a;
        if (lower != b) return false;
    }
    return true;
}

pub fn detectCpu() Cpu {
    const vendor_leaf = cpuid(0, 0);
    var vendor: [12]u8 = undefined;
    putNative32(vendor[0..4], vendor_leaf.ebx);
    putNative32(vendor[4..8], vendor_leaf.edx);
    putNative32(vendor[8..12], vendor_leaf.ecx);
    const version = cpuid(1, 0);
    const topology_leaf: u32 = if (vendor_leaf.eax >= 0x1f and cpuid(0x1f, 0).ebx != 0)
        0x1f
    else if (vendor_leaf.eax >= 0x0b and cpuid(0x0b, 0).ebx != 0)
        0x0b
    else
        0;
    var threads_per_core: u16 = 1;
    var logical_per_package: u16 = @truncate((version.ebx >> 16) & 0xff);
    if (logical_per_package == 0) logical_per_package = 1;
    if (topology_leaf != 0) {
        var subleaf: u32 = 0;
        while (subleaf < 8) : (subleaf += 1) {
            const level = cpuid(topology_leaf, subleaf);
            const logical: u16 = @truncate(level.ebx & 0xffff);
            if (logical == 0) break;
            switch ((level.ecx >> 8) & 0xff) {
                1 => threads_per_core = logical,
                2 => logical_per_package = logical,
                else => {},
            }
        }
    }
    const extended_max = cpuid(0x80000000, 0).eax;
    const invariant_tsc = extended_max >= 0x80000007 and (cpuid(0x80000007, 0).edx & (1 << 8)) != 0;
    const base_family = (version.eax >> 8) & 0x0f;
    const base_model = (version.eax >> 4) & 0x0f;
    const extended_family = (version.eax >> 20) & 0xff;
    const extended_model = (version.eax >> 16) & 0x0f;
    return .{
        .vendor = vendor,
        .family = @intCast(if (base_family == 0x0f) base_family + extended_family else base_family),
        .model = @intCast(if (base_family == 0x06 or base_family == 0x0f) base_model | (extended_model << 4) else base_model),
        .stepping = @truncate(version.eax & 0x0f),
        .tsc = (version.edx & (1 << 4)) != 0,
        .invariant_tsc = invariant_tsc,
        .threads_per_core = @max(threads_per_core, 1),
        .logical_per_package = @max(logical_per_package, 1),
    };
}

test "hardware profile signatures accept upper-case hexadecimal" {
    try @import("std").testing.expect(matchesSignature("[system]\nsignature=ABCDEF\n", 0xabcdef));
    try @import("std").testing.expect(matchesSignature("signature=0xABCDEF\n", 0xabcdef));
    try @import("std").testing.expect(matchesSignature("Signature=abcdef\n", 0xabcdef));
    try @import("std").testing.expect(matchesSignature("[system]\r\nsignature=abcdef\r\n", 0xabcdef));
    try @import("std").testing.expect(!matchesSignature("not_signature=ABCDEF\n", 0xabcdef));
    try @import("std").testing.expect(!matchesSignature("signature=ABCDEFgarbage\n", 0xabcdef));
    try @import("std").testing.expect(!matchesSignature("signature=ABCDFE\n", 0xabcdef));
    try @import("std").testing.expect(!matchesSignature("signature=10000000000000000\n", 0));
}

test "hardware profile persistence requires current system version" {
    const valid = "[system]\nversion=7\nsignature=abcdef\n";
    try @import("std").testing.expect(matchesPersistedProfile(valid, 0xabcdef));
    try @import("std").testing.expect(!matchesPersistedProfile("[system]\nversion=6\nsignature=abcdef\n", 0xabcdef));
    try @import("std").testing.expect(!matchesPersistedProfile("version=7\nsignature=abcdef\n", 0xabcdef));
}

test "hardware profile rejects zero CPU topology" {
    var cpu = @import("std").mem.zeroes(Cpu);
    const facts = @import("std").mem.zeroes(Facts);
    cpu.threads_per_core = 0;
    cpu.logical_per_package = 1;
    try @import("std").testing.expectError(error.InvalidCpuTopology, build(cpu, facts));
    cpu.threads_per_core = 1;
    cpu.logical_per_package = 0;
    try @import("std").testing.expectError(error.InvalidCpuTopology, build(cpu, facts));
}

test "hardware profile round-trips its generated signature" {
    var cpu = @import("std").mem.zeroes(Cpu);
    cpu.vendor = "GenuineIntel".*;
    cpu.family = 6;
    cpu.model = 0x9a;
    cpu.threads_per_core = 2;
    cpu.logical_per_package = 8;
    var facts = @import("std").mem.zeroes(Facts);
    facts.logical_cpus = 8;
    facts.memory_pages = 256;
    const profile = try build(cpu, facts);
    try @import("std").testing.expect(matchesSignature(profile.text(), profile.signature));
}

test "hardware profile signature includes timer capability" {
    var cpu = @import("std").mem.zeroes(Cpu);
    cpu.vendor = "GenuineIntel".*;
    cpu.family = 6;
    cpu.model = 1;
    cpu.threads_per_core = 1;
    cpu.logical_per_package = 1;
    var facts = @import("std").mem.zeroes(Facts);
    facts.logical_cpus = 1;
    facts.memory_pages = 128;
    const without_tsc = try build(cpu, facts);
    cpu.tsc = true;
    const with_tsc = try build(cpu, facts);
    try @import("std").testing.expect(without_tsc.signature != with_tsc.signature);
}

test "hardware profile rejects empty hardware facts" {
    const cpu: Cpu = .{ .vendor = "GenuineIntel".*, .family = 6, .model = 1, .stepping = 1,
        .tsc = true, .invariant_tsc = true, .threads_per_core = 1, .logical_per_package = 1 };
    const facts = @import("std").mem.zeroes(Facts);
    try @import("std").testing.expectError(error.InvalidHardwareFacts, build(cpu, facts));
}

test "hardware profile rejects non-monotonic baselines" {
    var profile = Profile{};
    try @import("std").testing.expectError(error.InvalidBaseline, profile.addBaseline(
        10, 9, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    ));
    try profile.addBaseline(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    try @import("std").testing.expect(profile.length != 0);
}

test "hardware profile baseline append rolls back on overflow" {
    var profile = Profile{};
    profile.length = profile.bytes.len - 1;
    try @import("std").testing.expectError(error.ProfileTooLarge, profile.addBaseline(
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
    ));
    try @import("std").testing.expectEqual(@as(usize, profile.bytes.len - 1), profile.length);
    profile.length = profile.bytes.len + 1;
    try @import("std").testing.expectError(error.ProfileTooLarge, profile.addBaseline(
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
    ));
}

pub fn build(cpu: Cpu, facts: Facts) !Profile {
    if (cpu.threads_per_core == 0 or cpu.logical_per_package == 0) return error.InvalidCpuTopology;
    if (facts.logical_cpus == 0 or facts.memory_pages == 0) return error.InvalidHardwareFacts;
    var result = Profile{};
    result.signature = signature(cpu, facts);
    try append(&result, "[system]\nversion="); try appendDecimal(&result, profile_version);
    try append(&result, "\nsignature=");
    try appendHex(&result, result.signature);
    try append(&result, "\n\n[cpu]\nvendor="); try append(&result, &cpu.vendor);
    try append(&result, "\nfamily="); try appendDecimal(&result, cpu.family);
    try append(&result, "\nmodel="); try appendDecimal(&result, cpu.model);
    try append(&result, "\nstepping="); try appendDecimal(&result, cpu.stepping);
    try append(&result, "\nlogical="); try appendDecimal(&result, facts.logical_cpus);
    try append(&result, "\nphysical="); try appendDecimal(&result, (@as(u64, facts.logical_cpus) + cpu.threads_per_core - 1) / cpu.threads_per_core);
    try append(&result, "\nthreads_per_core="); try appendDecimal(&result, cpu.threads_per_core);
    try append(&result, "\nlogical_per_package="); try appendDecimal(&result, cpu.logical_per_package);
    try append(&result, "\nsmt="); try append(&result, if (cpu.threads_per_core > 1) "true" else "false");
    try append(&result, "\ntsc="); try append(&result, if (cpu.tsc) "true" else "false");
    try append(&result, "\ninvariant_tsc="); try append(&result, if (cpu.invariant_tsc) "true" else "false");
    try append(&result, "\npreferred_timer="); try append(&result, if (cpu.tsc and cpu.invariant_tsc) "tsc" else "apic");
    try append(&result, "\n\n[memory]\npages="); try appendDecimal(&result, facts.memory_pages);
    try append(&result, "\n\n[pci]\ndevices="); try appendDecimal(&result, facts.pci_devices);
    try append(&result, "\n\n[gpu]\nvendor="); try appendHex(&result, facts.gpu_vendor);
    try append(&result, "\ndevice="); try appendHex(&result, facts.gpu_device);
    try append(&result, "\nrevision="); try appendHex(&result, facts.gpu_revision);
    try append(&result, "\nsubsystem_vendor="); try appendHex(&result, facts.gpu_subsystem_vendor);
    try append(&result, "\nsubsystem_device="); try appendHex(&result, facts.gpu_subsystem_device);
    try append(&result, "\nchipset="); try appendHex(&result, facts.gpu_chipset);
    try append(&result, "\nchip_revision="); try appendHex(&result, facts.gpu_chip_revision);
    try append(&result, "\nmsi="); try append(&result, if (facts.gpu_msi) "true" else "false");
    try append(&result, "\nmsix="); try append(&result, if (facts.gpu_msix) "true" else "false");
    try append(&result, "\nbus="); try appendDecimal(&result, facts.gpu_bus);
    try append(&result, "\nslot="); try appendDecimal(&result, facts.gpu_slot);
    try append(&result, "\n\n[nvme]\nvendor="); try appendHex(&result, facts.nvme_vendor);
    try append(&result, "\ndevice="); try appendHex(&result, facts.nvme_device);
    try append(&result, "\nnamespaces="); try appendDecimal(&result, facts.nvme_namespaces);
    try append(&result, "\n\n[network]\nvendor="); try appendHex(&result, facts.nic_vendor);
    try append(&result, "\ndevice="); try appendHex(&result, facts.nic_device);
    try append(&result, "\nirq_apic="); try appendDecimal(&result, facts.network_irq_apic);
    try append(&result, "\n\n[usb]\nports="); try appendDecimal(&result, facts.usb_ports);
    try append(&result, "\nkeyboards="); try appendDecimal(&result, facts.keyboards);
    try append(&result, "\nmice="); try appendDecimal(&result, facts.mice);
    try append(&result, "\nirq_apic="); try appendDecimal(&result, facts.input_irq_apic);
    try append(&result, "\n\n[audio]\ninterfaces="); try appendDecimal(&result, facts.audio_interfaces);
    try append(&result, "\n\n[display]\nwidth="); try appendDecimal(&result, facts.display_width);
    try append(&result, "\nheight="); try appendDecimal(&result, facts.display_height);
    try append(&result, "\nstride="); try appendDecimal(&result, facts.display_stride);
    try append(&result, "\n");
    return result;
}

fn signature(cpu: Cpu, facts: Facts) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    hash = hashInteger(hash, profile_version);
    hash = hashBytes(hash, &cpu.vendor);
    hash = hashInteger(hash, cpu.family); hash = hashInteger(hash, cpu.model); hash = hashInteger(hash, cpu.stepping);
    hash = hashInteger(hash, cpu.threads_per_core); hash = hashInteger(hash, cpu.logical_per_package);
    hash = hashInteger(hash, @intFromBool(cpu.tsc));
    hash = hashInteger(hash, @intFromBool(cpu.invariant_tsc));
    hash = hashInteger(hash, facts.logical_cpus); hash = hashInteger(hash, facts.memory_pages);
    hash = hashInteger(hash, facts.pci_devices); hash = hashInteger(hash, facts.gpu_vendor); hash = hashInteger(hash, facts.gpu_device);
    hash = hashInteger(hash, facts.gpu_revision); hash = hashInteger(hash, facts.gpu_subsystem_vendor); hash = hashInteger(hash, facts.gpu_subsystem_device);
    hash = hashInteger(hash, facts.gpu_chipset); hash = hashInteger(hash, facts.gpu_chip_revision);
    hash = hashInteger(hash, @intFromBool(facts.gpu_msi)); hash = hashInteger(hash, @intFromBool(facts.gpu_msix));
    hash = hashInteger(hash, facts.gpu_bus); hash = hashInteger(hash, facts.gpu_slot);
    hash = hashInteger(hash, facts.nvme_vendor); hash = hashInteger(hash, facts.nvme_device); hash = hashInteger(hash, facts.nvme_namespaces);
    hash = hashInteger(hash, facts.nic_vendor); hash = hashInteger(hash, facts.nic_device);
    hash = hashInteger(hash, facts.network_irq_apic);
    hash = hashInteger(hash, facts.usb_ports); hash = hashInteger(hash, facts.keyboards); hash = hashInteger(hash, facts.mice);
    hash = hashInteger(hash, facts.input_irq_apic);
    hash = hashInteger(hash, facts.audio_interfaces); hash = hashInteger(hash, facts.display_width);
    hash = hashInteger(hash, facts.display_height); hash = hashInteger(hash, facts.display_stride);
    return hash;
}

fn hashInteger(initial: u64, value: anytype) u64 {
    var hash = initial;
    var remaining: u64 = @intCast(value);
    var count: usize = 0;
    while (count < @sizeOf(@TypeOf(value))) : (count += 1) {
        hash = (hash ^ @as(u8, @truncate(remaining))) *% 0x100000001b3;
        remaining >>= 8;
    }
    return hash;
}

fn hashBytes(initial: u64, bytes: []const u8) u64 {
    var hash = initial;
    for (bytes) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash;
}

fn append(profile: *Profile, value: []const u8) !void {
    if (profile.length > profile.bytes.len or value.len > profile.bytes.len - profile.length) return error.ProfileTooLarge;
    @memcpy(profile.bytes[profile.length .. profile.length + value.len], value);
    profile.length += value.len;
}

fn appendDecimal(profile: *Profile, value: anytype) !void {
    var digits: [20]u8 = undefined;
    var index = digits.len;
    var remaining: u64 = @intCast(value);
    if (remaining == 0) return append(profile, "0");
    while (remaining != 0) {
        index -= 1;
        digits[index] = @truncate('0' + remaining % 10);
        remaining /= 10;
    }
    try append(profile, digits[index..]);
}

fn appendHex(profile: *Profile, value: anytype) !void {
    const alphabet = "0123456789abcdef";
    var digits: [16]u8 = undefined;
    var index = digits.len;
    var remaining: u64 = @intCast(value);
    if (remaining == 0) return append(profile, "0");
    while (remaining != 0) {
        index -= 1;
        digits[index] = alphabet[@truncate(remaining & 0xf)];
        remaining >>= 4;
    }
    try append(profile, digits[index..]);
}

fn putNative32(output: []u8, value: u32) void {
    output[0] = @truncate(value);
    output[1] = @truncate(value >> 8);
    output[2] = @truncate(value >> 16);
    output[3] = @truncate(value >> 24);
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var eax = leaf;
    var ebx: u32 = undefined;
    var ecx = subleaf;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
        :
        : .{ .memory = true });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
