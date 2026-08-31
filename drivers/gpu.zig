const pci = @import("pci");

pub const Driver = enum {
    unsupported,
    qemu_vga,
    amdgpu,
    nouveau,
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
        pci.enableMemoryAndBusMaster(device);
        return .{
            .device = device,
            .driver = driverFor(device.vendor, device.device),
            .bars = bars,
            .bar_count = count,
            .mmio_bytes = bytes,
            .register_bar = register_bar,
        };
    }

    pub fn isAmd(self: *const Adapter) bool {
        return self.driver == .amdgpu;
    }
};

pub fn driverFor(vendor: u16, device: u16) Driver {
    _ = device;
    return switch (vendor) {
        0x1002 => .amdgpu,
        0x10de => .nouveau,
        0x1234, 0x1b36 => .qemu_vga,
        else => .unsupported,
    };
}
