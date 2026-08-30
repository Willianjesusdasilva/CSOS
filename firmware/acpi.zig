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

const Gas = packed struct {
    space: u8,
    width: u8,
    offset: u8,
    access: u8,
    address: u64,
};

pub const Power = struct {
    reset_register: Gas,
    reset_value: u8,
    pm1a: Gas,
    pm1b: ?Gas,
    sleep_a: u16,
    sleep_b: u16,

    pub fn reset(self: Power) noreturn {
        writeGas(self.reset_register, self.reset_value) catch halt();
        halt();
    }

    pub fn shutdown(self: Power) noreturn {
        writeGas(self.pm1a, (@as(u64, self.sleep_a) << 10) | (1 << 13)) catch halt();
        if (self.pm1b) |register| writeGas(register, (@as(u64, self.sleep_b) << 10) | (1 << 13)) catch halt();
        halt();
    }
};

pub fn findMadt(rsdp_address: u64) !Madt {
    const table = try findTable(rsdp_address, "APIC");
    return parseMadt(table);
}

pub fn findPower(rsdp_address: u64) !Power {
    const fadt = try findTable(rsdp_address, "FACP");
    const length = read32(fadt + 4);
    if (length < 129 or !checksum(fadt, length)) return error.InvalidFadt;
    const reset_register = readGas(fadt + 116);
    if (reset_register.address == 0) return error.ResetUnsupported;
    const dsdt_address = if (length >= 148 and read64(fadt + 140) != 0) read64(fadt + 140) else read32(fadt + 40);
    if (dsdt_address == 0) return error.MissingDsdt;
    const dsdt: [*]const u8 = @ptrFromInt(dsdt_address);
    const dsdt_length = read32(dsdt + 4);
    if (dsdt_length < 36 or !equal(dsdt, "DSDT") or !checksum(dsdt, dsdt_length)) return error.InvalidDsdt;
    const sleep = try findSleepTypes(dsdt + 36, dsdt_length - 36);
    var pm1a = if (length >= 184 and readGas(fadt + 172).address != 0)
        readGas(fadt + 172)
    else
        legacyGas(read32(fadt + 64), 16);
    if (pm1a.address == 0) return error.PowerControlUnsupported;
    if (pm1a.width == 0) pm1a.width = 16;
    var pm1b: ?Gas = null;
    const extended_pm1b = if (length >= 196) readGas(fadt + 184) else Gas{ .space = 0, .width = 0, .offset = 0, .access = 0, .address = 0 };
    if (extended_pm1b.address != 0) pm1b = extended_pm1b else if (read32(fadt + 68) != 0) pm1b = legacyGas(read32(fadt + 68), 16);
    return .{
        .reset_register = reset_register,
        .reset_value = fadt[128],
        .pm1a = pm1a,
        .pm1b = pm1b,
        .sleep_a = sleep[0],
        .sleep_b = sleep[1],
    };
}

fn findTable(rsdp_address: u64, signature: []const u8) ![*]const u8 {
    const rsdp: [*]const u8 = @ptrFromInt(rsdp_address);
    if (!equal(rsdp, "RSD PTR ") or !checksum(rsdp, 20)) return error.InvalidRsdp;

    if (rsdp[15] >= 2 and read32(rsdp + 20) >= 36 and checksum(rsdp, read32(rsdp + 20))) {
        const xsdt = read64(rsdp + 24);
        if (xsdt != 0) return scanRoot(xsdt, 8, signature);
    }
    const rsdt = read32(rsdp + 16);
    if (rsdt == 0) return error.NoRootTable;
    return scanRoot(rsdt, 4, signature);
}

fn scanRoot(address: u64, entry_size: usize, signature: []const u8) ![*]const u8 {
    const root: [*]const u8 = @ptrFromInt(address);
    const length = read32(root + 4);
    if (length < 36 or !checksum(root, length)) return error.InvalidRootTable;

    var offset: usize = 36;
    while (offset + entry_size <= length) : (offset += entry_size) {
        const table_address = if (entry_size == 8) read64(root + offset) else read32(root + offset);
        const header: [*]const u8 = @ptrFromInt(table_address);
        if (equal(header, signature)) return header;
    }
    return error.TableNotFound;
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

fn readGas(bytes: [*]const u8) Gas {
    return .{ .space = bytes[0], .width = bytes[1], .offset = bytes[2], .access = bytes[3], .address = read64(bytes + 4) };
}

fn legacyGas(address: u32, width: u8) Gas {
    return .{ .space = 1, .width = width, .offset = 0, .access = 2, .address = address };
}

fn findSleepTypes(aml: [*]const u8, length: usize) ![2]u16 {
    var index: usize = 0;
    while (index + 7 < length) : (index += 1) {
        if (!equal(aml + index, "_S5_") or aml[index + 4] != 0x12) continue;
        var cursor = index + 5;
        cursor += try packageLengthBytes(aml + cursor, length - cursor);
        if (cursor >= length or aml[cursor] < 2) return error.InvalidSleepPackage;
        cursor += 1;
        const first = try amlInteger(aml, length, &cursor);
        const second = try amlInteger(aml, length, &cursor);
        if (first > 7 or second > 7) return error.InvalidSleepType;
        return .{ @intCast(first), @intCast(second) };
    }
    return error.SleepTypeMissing;
}

fn packageLengthBytes(bytes: [*]const u8, remaining: usize) !usize {
    if (remaining == 0) return error.InvalidPackageLength;
    const following = bytes[0] >> 6;
    if (@as(usize, following) + 1 > remaining) return error.InvalidPackageLength;
    return @as(usize, following) + 1;
}

fn amlInteger(bytes: [*]const u8, length: usize, cursor: *usize) !u64 {
    if (cursor.* >= length) return error.InvalidSleepPackage;
    const prefix = bytes[cursor.*];
    cursor.* += 1;
    return switch (prefix) {
        0x00 => 0,
        0x01 => 1,
        0x0a => readAml(bytes, length, cursor, 1),
        0x0b => readAml(bytes, length, cursor, 2),
        0x0c => readAml(bytes, length, cursor, 4),
        else => error.InvalidSleepPackage,
    };
}

fn readAml(bytes: [*]const u8, length: usize, cursor: *usize, count: usize) !u64 {
    if (count > length - cursor.*) return error.InvalidSleepPackage;
    var value: u64 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) value |= @as(u64, bytes[cursor.* + index]) << @intCast(index * 8);
    cursor.* += count;
    return value;
}

fn writeGas(register: Gas, value: u64) !void {
    if (register.offset != 0 or register.address == 0) return error.UnsupportedRegister;
    const width: u8 = if (register.width != 0) register.width else switch (register.access) { 1 => 8, 2 => 16, 3 => 32, else => 0 };
    switch (register.space) {
        0 => switch (width) {
            8 => { const target: *volatile u8 = @ptrFromInt(register.address); target.* = @truncate(value); },
            16 => { const target: *volatile u16 = @ptrFromInt(register.address); target.* = @truncate(value); },
            32 => { const target: *volatile u32 = @ptrFromInt(register.address); target.* = @truncate(value); },
            else => return error.UnsupportedRegister,
        },
        1 => switch (width) {
            8 => asm volatile ("outb %[value], %[port]" :: [value] "{al}" (@as(u8, @truncate(value))), [port] "{dx}" (@as(u16, @truncate(register.address)))),
            16 => asm volatile ("outw %[value], %[port]" :: [value] "{ax}" (@as(u16, @truncate(value))), [port] "{dx}" (@as(u16, @truncate(register.address)))),
            32 => asm volatile ("outl %[value], %[port]" :: [value] "{eax}" (@as(u32, @truncate(value))), [port] "{dx}" (@as(u16, @truncate(register.address)))),
            else => return error.UnsupportedRegister,
        },
        else => return error.UnsupportedAddressSpace,
    }
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}
