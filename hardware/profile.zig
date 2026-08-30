const profile_version: u8 = 2;

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
    gpu_bus: u8,
    gpu_slot: u5,
    nvme_vendor: u16,
    nvme_device: u16,
    nvme_namespaces: u16,
    nic_vendor: u16,
    nic_device: u16,
    usb_ports: u8,
    keyboards: u8,
    mice: u8,
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

    pub fn addBaseline(self: *Profile, nvme_p50: u64, nvme_p95: u64, nvme_p99: u64, tcp_p50: u64, tcp_p95: u64, tcp_p99: u64) !void {
        try append(self, "\n[baseline_cycles]\nnvme_p50="); try appendDecimal(self, nvme_p50);
        try append(self, "\nnvme_p95="); try appendDecimal(self, nvme_p95);
        try append(self, "\nnvme_p99="); try appendDecimal(self, nvme_p99);
        try append(self, "\ntcp_p50="); try appendDecimal(self, tcp_p50);
        try append(self, "\ntcp_p95="); try appendDecimal(self, tcp_p95);
        try append(self, "\ntcp_p99="); try appendDecimal(self, tcp_p99);
        try append(self, "\n");
    }
};

pub fn matchesSignature(text: []const u8, expected: u64) bool {
    const key = "signature=";
    var offset: usize = 0;
    while (offset + key.len <= text.len) : (offset += 1) {
        if (!equal(text[offset .. offset + key.len], key)) continue;
        offset += key.len;
        var value: u64 = 0;
        var digits: usize = 0;
        while (offset < text.len) : (offset += 1) {
            const digit: u8 = if (text[offset] >= '0' and text[offset] <= '9')
                text[offset] - '0'
            else if (text[offset] >= 'a' and text[offset] <= 'f')
                text[offset] - 'a' + 10
            else break;
            value = value *% 16 +% digit;
            digits += 1;
        }
        return digits != 0 and value == expected;
    }
    return false;
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

pub fn build(cpu: Cpu, facts: Facts) !Profile {
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
    try append(&result, "\nbus="); try appendDecimal(&result, facts.gpu_bus);
    try append(&result, "\nslot="); try appendDecimal(&result, facts.gpu_slot);
    try append(&result, "\n\n[nvme]\nvendor="); try appendHex(&result, facts.nvme_vendor);
    try append(&result, "\ndevice="); try appendHex(&result, facts.nvme_device);
    try append(&result, "\nnamespaces="); try appendDecimal(&result, facts.nvme_namespaces);
    try append(&result, "\n\n[network]\nvendor="); try appendHex(&result, facts.nic_vendor);
    try append(&result, "\ndevice="); try appendHex(&result, facts.nic_device);
    try append(&result, "\n\n[usb]\nports="); try appendDecimal(&result, facts.usb_ports);
    try append(&result, "\nkeyboards="); try appendDecimal(&result, facts.keyboards);
    try append(&result, "\nmice="); try appendDecimal(&result, facts.mice);
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
    hash = hashInteger(hash, @intFromBool(cpu.invariant_tsc));
    hash = hashInteger(hash, facts.logical_cpus); hash = hashInteger(hash, facts.memory_pages);
    hash = hashInteger(hash, facts.pci_devices); hash = hashInteger(hash, facts.gpu_vendor); hash = hashInteger(hash, facts.gpu_device);
    hash = hashInteger(hash, facts.gpu_bus); hash = hashInteger(hash, facts.gpu_slot);
    hash = hashInteger(hash, facts.nvme_vendor); hash = hashInteger(hash, facts.nvme_device); hash = hashInteger(hash, facts.nvme_namespaces);
    hash = hashInteger(hash, facts.nic_vendor); hash = hashInteger(hash, facts.nic_device);
    hash = hashInteger(hash, facts.usb_ports); hash = hashInteger(hash, facts.keyboards); hash = hashInteger(hash, facts.mice);
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
    if (value.len > profile.bytes.len - profile.length) return error.ProfileTooLarge;
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
