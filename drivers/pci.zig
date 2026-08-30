const max_devices = 256;

pub const Device = struct {
    bus: u8,
    slot: u5,
    function: u3,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    programming_interface: u8,
    header_type: u8,
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
        self.devices[self.count] = .{
            .bus = bus,
            .slot = slot,
            .function = function,
            .vendor = vendor,
            .device = read16(bus, slot, function, 2),
            .class = class,
            .subclass = subclass,
            .programming_interface = read8(bus, slot, function, 9),
            .header_type = read8(bus, slot, function, 0x0e) & 0x7f,
        };
        self.count += 1;
        if (class == 0x06 and subclass == 0x04) self.scanBus(read8(bus, slot, function, 0x19));
    }
};

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
    const offset: u8 = 0x10 + @as(u8, index) * 4;
    const low = read32(device.bus, device.slot, device.function, offset);
    if ((low & 1) != 0) return null;
    var address: u64 = low & 0xfffffff0;
    if (((low >> 1) & 3) == 2) address |= @as(u64, read32(device.bus, device.slot, device.function, offset + 4)) << 32;
    return if (address == 0) null else address;
}

fn read16(bus: u8, slot: u5, function: u3, offset: u8) u16 {
    return @truncate(read32(bus, slot, function, offset) >> @intCast((offset & 2) * 8));
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
