const max_devices = 256;

pub const Device = struct {
    bus: u8,
    slot: u5,
    function: u3,
    vendor: u16,
    device: u16,
    revision: u8,
    subsystem_vendor: u16,
    subsystem_device: u16,
    class: u8,
    subclass: u8,
    programming_interface: u8,
    header_type: u8,
    msi: bool,
    msix: bool,
};

pub const Inventory = struct {
    devices: [max_devices]Device = undefined,
    count: usize = 0,
    visited_buses: [256]bool = .{false} ** 256,

    pub fn scan() Inventory {
        var inventory = Inventory{};
        inventory.scanBus(0);
        return inventory;
    }

    pub fn findClass(self: *const Inventory, class: u8, subclass: u8) ?Device {
        for (self.devices[0..self.count]) |device| {
            if (device.class == class and device.subclass == subclass) return device;
        }
        return null;
    }

    pub fn findClassInterface(self: *const Inventory, class: u8, subclass: u8, programming_interface: u8) ?Device {
        for (self.devices[0..self.count]) |device| {
            if (device.class == class and device.subclass == subclass and device.programming_interface == programming_interface) return device;
        }
        return null;
    }

    fn scanBus(self: *Inventory, bus: u8) void {
        if (self.visited_buses[bus]) return;
        self.visited_buses[bus] = true;
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            if (read16(bus, @intCast(slot), 0, 0) == 0xffff) continue;
            const functions: u8 = if ((read8(bus, @intCast(slot), 0, 0x0e) & 0x80) != 0) 8 else 1;
            var function: u8 = 0;
            while (function < functions) : (function += 1) self.scanFunction(bus, @intCast(slot), @intCast(function));
        }
    }

    fn scanFunction(self: *Inventory, bus: u8, slot: u5, function: u3) void {
        const vendor = read16(bus, slot, function, 0);
        if (vendor == 0xffff or self.count == max_devices) return;
        const class = read8(bus, slot, function, 0x0b);
        const subclass = read8(bus, slot, function, 0x0a);
        const header_type = read8(bus, slot, function, 0x0e) & 0x7f;
        const probe = Device{ .bus = bus, .slot = slot, .function = function, .vendor = vendor, .device = 0, .revision = 0, .subsystem_vendor = 0, .subsystem_device = 0, .class = class, .subclass = subclass, .programming_interface = 0, .header_type = header_type, .msi = false, .msix = false };
        self.devices[self.count] = .{
            .bus = bus,
            .slot = slot,
            .function = function,
            .vendor = vendor,
            .device = read16(bus, slot, function, 2),
            .revision = read8(bus, slot, function, 8),
            .subsystem_vendor = if (header_type == 0) read16(bus, slot, function, 0x2c) else 0,
            .subsystem_device = if (header_type == 0) read16(bus, slot, function, 0x2e) else 0,
            .class = class,
            .subclass = subclass,
            .programming_interface = read8(bus, slot, function, 9),
            .header_type = header_type,
            .msi = capabilityOffset(probe, 0x05) != null,
            .msix = capabilityOffset(probe, 0x11) != null,
        };
        self.count += 1;
        if (class == 0x06 and subclass == 0x04) self.scanBus(read8(bus, slot, function, 0x19));
    }
};

pub fn capabilityOffset(device: Device, wanted: u8) ?u8 {
    if ((read16(device.bus, device.slot, device.function, 6) & (1 << 4)) == 0) return null;
    var offset = read8(device.bus, device.slot, device.function, 0x34) & 0xfc;
    var visited: u8 = 0;
    while (offset >= 0x40 and visited < 48) : (visited += 1) {
        if (read8(device.bus, device.slot, device.function, offset) == wanted) return offset;
        offset = read8(device.bus, device.slot, device.function, offset + 1) & 0xfc;
    }
    return null;
}

pub fn enableMsi(device: Device, vector: u8, destination_apic: u8) !void {
    const offset = capabilityOffset(device, 0x05) orelse return error.MsiUnavailable;
    var control = read16(device.bus, device.slot, device.function, offset + 2);
    write32(device.bus, device.slot, device.function, offset + 4, 0xfee00000 | (@as(u32, destination_apic) << 12));
    const data_offset: u8 = if ((control & (1 << 7)) != 0) offset + 12 else offset + 8;
    write16(device.bus, device.slot, device.function, data_offset, vector);
    control &= ~@as(u16, 0x70);
    control |= 1;
    write16(device.bus, device.slot, device.function, offset + 2, control);
}

pub fn enableMsix(device: Device, vector: u8, destination_apic: u8) !void {
    const offset = capabilityOffset(device, 0x11) orelse return error.MsixUnavailable;
    var control = read16(device.bus, device.slot, device.function, offset + 2);
    const table = read32(device.bus, device.slot, device.function, offset + 4);
    const bir: u3 = @truncate(table & 7);
    const table_base = (barAddress(device, bir) orelse return error.MsixTableBarMissing) + (table & ~@as(u32, 7));
    const entry: [*]volatile u32 = @ptrFromInt(table_base);
    control |= 1 << 14;
    write16(device.bus, device.slot, device.function, offset + 2, control);
    entry[3] = 1;
    entry[0] = 0xfee00000 | (@as(u32, destination_apic) << 12);
    entry[1] = 0;
    entry[2] = vector;
    entry[3] = 0;
    control = (control | (1 << 15)) & ~@as(u16, 1 << 14);
    write16(device.bus, device.slot, device.function, offset + 2, control);
    if (entry[0] != 0xfee00000 | (@as(u32, destination_apic) << 12) or entry[1] != 0 or entry[2] != vector or entry[3] != 0)
        return error.MsixTableVerificationFailed;
    if ((read16(device.bus, device.slot, device.function, offset + 2) & (1 << 15)) == 0)
        return error.MsixEnableFailed;
}

pub fn read32(bus: u8, slot: u5, function: u3, offset: u8) u32 {
    const address = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) |
        (offset & 0xfc);
    out32(0xcf8, address);
    return in32(0xcfc);
}

pub fn write32(bus: u8, slot: u5, function: u3, offset: u8, value: u32) void {
    const address = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) |
        (offset & 0xfc);
    out32(0xcf8, address);
    out32(0xcfc, value);
}

pub fn enableMemoryAndBusMaster(device: Device) void {
    const value = read32(device.bus, device.slot, device.function, 4);
    write32(device.bus, device.slot, device.function, 4, value | 0x6);
}

pub fn barAddress(device: Device, index: u3) ?u64 {
    return if (barInfo(device, index, false)) |bar| bar.address else null;
}

pub const Bar = struct {
    address: u64,
    size: u64,
    is_64_bit: bool,
    prefetchable: bool,
};

pub const RomBar = struct { address: u64, size: u64, enabled: bool };

pub fn romInfo(device: Device, probe_size: bool) ?RomBar {
    if (device.header_type != 0) return null;
    const offset: u8 = 0x30;
    const original = read32(device.bus, device.slot, device.function, offset);
    if (original == 0xffffffff) return null;
    const address: u64 = original & 0xfffff800;
    if (address == 0) return null;
    var size: u64 = 0;
    if (probe_size) {
        const command = read16(device.bus, device.slot, device.function, 4);
        write16(device.bus, device.slot, device.function, 4, command & ~@as(u16, 3));
        write32(device.bus, device.slot, device.function, offset, 0xfffff800);
        const mask = read32(device.bus, device.slot, device.function, offset) & 0xfffff800;
        write32(device.bus, device.slot, device.function, offset, original);
        write16(device.bus, device.slot, device.function, 4, command);
        if (mask != 0) size = @as(u64, (~mask) +% 1);
    }
    return .{ .address = address, .size = size, .enabled = (original & 1) != 0 };
}

pub fn barInfo(device: Device, index: u3, probe_size: bool) ?Bar {
    if (index >= 6) return null;
    if (index != 0) {
        const previous = read32(device.bus, device.slot, device.function, 0x10 + (@as(u8, index) - 1) * 4);
        if ((previous & 1) == 0 and ((previous >> 1) & 3) == 2) return null;
    }
    const offset: u8 = 0x10 + @as(u8, index) * 4;
    const low = read32(device.bus, device.slot, device.function, offset);
    if ((low & 1) != 0) return null;
    const is_64_bit = ((low >> 1) & 3) == 2;
    if (is_64_bit and index == 5) return null;
    var address: u64 = low & 0xfffffff0;
    const high = if (is_64_bit) read32(device.bus, device.slot, device.function, offset + 4) else 0;
    address |= @as(u64, high) << 32;
    if (address == 0) return null;
    var size: u64 = 0;
    if (probe_size) {
        const command = read16(device.bus, device.slot, device.function, 4);
        write16(device.bus, device.slot, device.function, 4, command & ~@as(u16, 3));
        write32(device.bus, device.slot, device.function, offset, 0xffffffff);
        const size_low = read32(device.bus, device.slot, device.function, offset) & 0xfffffff0;
        var mask: u64 = size_low;
        if (is_64_bit) {
            write32(device.bus, device.slot, device.function, offset + 4, 0xffffffff);
            mask |= @as(u64, read32(device.bus, device.slot, device.function, offset + 4)) << 32;
            write32(device.bus, device.slot, device.function, offset + 4, high);
        }
        write32(device.bus, device.slot, device.function, offset, low);
        write16(device.bus, device.slot, device.function, 4, command);
        if (mask != 0) size = if (is_64_bit) (~mask) +% 1 else @as(u64, (~@as(u32, @truncate(mask))) +% 1);
    }
    return .{ .address = address, .size = size, .is_64_bit = is_64_bit, .prefetchable = (low & 8) != 0 };
}

pub fn read16(bus: u8, slot: u5, function: u3, offset: u8) u16 {
    return @truncate(read32(bus, slot, function, offset) >> @intCast((offset & 2) * 8));
}

pub fn write16(bus: u8, slot: u5, function: u3, offset: u8, value: u16) void {
    const shift: u5 = @intCast((offset & 2) * 8);
    const current = read32(bus, slot, function, offset);
    const mask = @as(u32, 0xffff) << shift;
    write32(bus, slot, function, offset, (current & ~mask) | (@as(u32, value) << shift));
}

fn read8(bus: u8, slot: u5, function: u3, offset: u8) u8 {
    return @truncate(read32(bus, slot, function, offset) >> @intCast((offset & 3) * 8));
}

fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port));
}

fn in32(port: u16) u32 {
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "{dx}" (port));
}
