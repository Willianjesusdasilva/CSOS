const pci = @import("pci");
const physical = @import("physical");

pub const Controller = struct {
    base: u64,
    operational: u64,
    runtime: u64,
    doorbells: u64,
    max_ports: u8,
    connected_ports: u8,

    pub fn init(device: pci.Device, pages: *physical.Allocator) !Controller {
        if (device.programming_interface != 0x30) return error.NotXhci;
        pci.enableMemoryAndBusMaster(device);
        const base = pci.barAddress(device, 0) orelse return error.NoBar;
        const capability_length = read8(base, 0);
        const parameters = read32(base, 4);
        const max_slots: u8 = @truncate(parameters);
        const max_ports: u8 = @truncate(parameters >> 24);
        if (capability_length < 0x20 or max_slots == 0 or max_ports == 0) return error.InvalidController;
        const operational = base + capability_length;
        const runtime = base + (read32(base, 0x18) & ~@as(u32, 0x1f));
        const doorbells = base + (read32(base, 0x14) & ~@as(u32, 3));

        write32(operational, 0, read32(operational, 0) & ~@as(u32, 1));
        try waitBits(operational + 4, 1, true);
        write32(operational, 0, read32(operational, 0) | 2);
        try waitBits(operational, 2, false);
        try waitBits(operational + 4, 1 << 11, false);
        if ((read32(operational, 8) & 1) == 0) return error.UnsupportedPageSize;

        const dcbaa = pages.allocate(1) orelse return error.OutOfMemory;
        const command_ring = pages.allocate(1) orelse return error.OutOfMemory;
        const event_ring = pages.allocate(1) orelse return error.OutOfMemory;
        const erst = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(dcbaa); zeroPage(command_ring); zeroPage(event_ring); zeroPage(erst);
        const link: [*]u32 = @ptrFromInt(command_ring + 4096 - 16);
        link[0] = @truncate(command_ring);
        link[1] = @truncate(command_ring >> 32);
        link[3] = (6 << 10) | (1 << 1) | 1;
        const table: [*]u32 = @ptrFromInt(erst);
        table[0] = @truncate(event_ring);
        table[1] = @truncate(event_ring >> 32);
        table[2] = 256;
        write64(operational, 0x30, dcbaa);
        write64(operational, 0x18, command_ring | 1);
        write32(operational, 0x38, @min(max_slots, 32));
        const interrupter = runtime + 0x20;
        write32(interrupter, 8, 1);
        write64(interrupter, 0x10, erst);
        write64(interrupter, 0x18, event_ring);
        write32(operational, 0, read32(operational, 0) | 1);
        try waitBits(operational + 4, 1, false);

        var connected: u8 = 0;
        var port: u8 = 0;
        while (port < max_ports) : (port += 1) {
            if ((read32(operational, 0x400 + @as(u64, port) * 0x10) & 1) != 0) connected += 1;
        }
        return .{ .base = base, .operational = operational, .runtime = runtime, .doorbells = doorbells, .max_ports = max_ports, .connected_ports = connected };
    }
};

fn waitBits(address: u64, mask: u32, set: bool) !void {
    var spins: usize = 0;
    while ((((read32(address, 0) & mask) != 0) != set) and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
    if (spins == 100_000_000) return error.Timeout;
}

fn zeroPage(address: u64) void { const bytes: [*]u8 = @ptrFromInt(address); @memset(bytes[0..4096], 0); }
fn read8(base: u64, offset: u64) u8 { const value: *volatile u8 = @ptrFromInt(base + offset); return value.*; }
fn read32(base: u64, offset: u64) u32 { const value: *volatile u32 = @ptrFromInt(base + offset); return value.*; }
fn write32(base: u64, offset: u64, value: u32) void { const target: *volatile u32 = @ptrFromInt(base + offset); target.* = value; }
fn write64(base: u64, offset: u64, value: u64) void { const target: *volatile u64 = @ptrFromInt(base + offset); target.* = value; }
