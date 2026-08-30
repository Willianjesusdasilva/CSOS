const max_cpus = 256;
const max_ioapics = 8;
const max_overrides = 32;

pub const Cpu = struct { apic_id: u32 };
pub const IoApic = struct { id: u8, address: u32, gsi_base: u32 };
pub const InterruptOverride = struct { source: u8, gsi: u32, flags: u16 };

pub const Madt = struct {
    local_apic_address: u32,
    cpus: [max_cpus]Cpu = undefined,
    cpu_count: usize = 0,
    ioapics: [max_ioapics]IoApic = undefined,
    ioapic_count: usize = 0,
    overrides: [max_overrides]InterruptOverride = undefined,
    override_count: usize = 0,
};

pub fn findMadt(rsdp_address: u64) !Madt {
    const rsdp: [*]const u8 = @ptrFromInt(rsdp_address);
    if (!equal(rsdp, "RSD PTR ") or !checksum(rsdp, 20)) return error.InvalidRsdp;

    if (rsdp[15] >= 2 and read32(rsdp + 20) >= 36 and checksum(rsdp, read32(rsdp + 20))) {
        const xsdt = read64(rsdp + 24);
        if (xsdt != 0) return scanRoot(xsdt, 8);
    }
    const rsdt = read32(rsdp + 16);
    if (rsdt == 0) return error.NoRootTable;
    return scanRoot(rsdt, 4);
}

fn scanRoot(address: u64, entry_size: usize) !Madt {
    const root: [*]const u8 = @ptrFromInt(address);
    const length = read32(root + 4);
    if (length < 36 or !checksum(root, length)) return error.InvalidRootTable;

    var offset: usize = 36;
    while (offset + entry_size <= length) : (offset += entry_size) {
        const table_address = if (entry_size == 8) read64(root + offset) else read32(root + offset);
        const header: [*]const u8 = @ptrFromInt(table_address);
        if (equal(header, "APIC")) return parseMadt(header);
    }
    return error.NoMadt;
}

fn parseMadt(table: [*]const u8) !Madt {
    const length = read32(table + 4);
    if (length < 44 or !checksum(table, length)) return error.InvalidMadt;
    var result = Madt{ .local_apic_address = read32(table + 36) };

    var offset: usize = 44;
    while (offset + 2 <= length) {
        const entry = table + offset;
        const entry_length = entry[1];
        if (entry_length < 2 or offset + entry_length > length) return error.InvalidMadtEntry;
        switch (entry[0]) {
            0 => if (entry_length >= 8 and (read32(entry + 4) & 1) != 0 and result.cpu_count < max_cpus) {
                result.cpus[result.cpu_count] = .{ .apic_id = entry[3] };
                result.cpu_count += 1;
            },
            1 => if (entry_length >= 12 and result.ioapic_count < max_ioapics) {
                result.ioapics[result.ioapic_count] = .{
                    .id = entry[2],
                    .address = read32(entry + 4),
                    .gsi_base = read32(entry + 8),
                };
                result.ioapic_count += 1;
            },
            2 => if (entry_length >= 10 and result.override_count < max_overrides) {
                result.overrides[result.override_count] = .{
                    .source = entry[3],
                    .gsi = read32(entry + 4),
                    .flags = read16(entry + 8),
                };
                result.override_count += 1;
            },
            5 => {
                if (entry_length >= 12) result.local_apic_address = @truncate(read64(entry + 4));
            },
            9 => if (entry_length >= 16 and (read32(entry + 8) & 1) != 0 and result.cpu_count < max_cpus) {
                result.cpus[result.cpu_count] = .{ .apic_id = read32(entry + 4) };
                result.cpu_count += 1;
            },
            else => {},
        }
        offset += entry_length;
    }
    return result;
}

fn checksum(bytes: [*]const u8, length: usize) bool {
    var sum: u8 = 0;
    for (bytes[0..length]) |byte| sum +%= byte;
    return sum == 0;
}

fn equal(bytes: [*]const u8, text: []const u8) bool {
    for (text, 0..) |byte, index| if (bytes[index] != byte) return false;
    return true;
}

fn read16(bytes: [*]const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn read32(bytes: [*]const u8) u32 {
    return @as(u32, read16(bytes)) | (@as(u32, read16(bytes + 2)) << 16);
}

fn read64(bytes: [*]const u8) u64 {
    return @as(u64, read32(bytes)) | (@as(u64, read32(bytes + 4)) << 32);
}
