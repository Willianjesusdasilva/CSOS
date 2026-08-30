const pci = @import("pci");

pub const Driver = enum {
    unsupported,
    qemu_vga,
    amdgpu,
};

pub const Adapter = struct {
    device: pci.Device,
    driver: Driver,
    bars: [6]?u64,
    bar_count: u8,

    pub fn discover(device: pci.Device) !Adapter {
        if (device.class != 0x03) return error.NotDisplayController;
        var bars: [6]?u64 = .{null} ** 6;
        var count: u8 = 0;
        for (0..bars.len) |index| {
            bars[index] = pci.barAddress(device, @intCast(index));
            if (bars[index] != null) count += 1;
        }
        return .{
            .device = device,
            .driver = driverFor(device.vendor, device.device),
            .bars = bars,
            .bar_count = count,
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
        0x1234, 0x1b36 => .qemu_vga,
        else => .unsupported,
    };
}
