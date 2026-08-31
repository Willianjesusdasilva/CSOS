const pci = @import("pci");
const fat16 = @import("fat16");
const physical = @import("physical");

const firmware_name: [11]u8 = "GPUFW   BIN".*;
const maximum_firmware_bytes = 56 * 1024 * 1024;

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

pub const Firmware = struct {
    address: u64,
    size: usize,
    pages: u64,

    pub fn bytes(self: Firmware) []const u8 {
        const pointer: [*]const u8 = @ptrFromInt(self.address);
        return pointer[0..self.size];
    }
};

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
