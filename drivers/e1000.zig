const pci = @import("pci");
const physical = @import("physical");
const apic = @import("apic");

const descriptor_count = 16;
var interrupt_base: u64 = 0;
var interrupts: u64 = 0;
var last_interrupt_apic: u32 = 0xffffffff;

pub const Controller = struct {
    base: u64,
    mac: [6]u8,
    rx_ring: u64,
    tx_ring: u64,
    rx_buffers: [descriptor_count]u64,
    tx_buffer: u64,
    rx_index: u16 = 0,
    tx_index: u16 = 0,

    pub fn init(device: pci.Device, pages: *physical.Allocator) !Controller {
        pci.enableMemoryAndBusMaster(device);
        const base = pci.barAddress(device, 0) orelse return error.NoBar;
        write32(base, 0x0000, read32(base, 0) | (1 << 26));
        var spins: usize = 0;
        while ((read32(base, 0) & (1 << 26)) != 0 and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
        if (spins == 100_000_000) return error.ResetTimeout;
        write32(base, 0x00d8, 0xffffffff);
        const ral = read32(base, 0x5400);
        const rah = read32(base, 0x5404);
        if ((rah & (1 << 31)) == 0) return error.NoMac;
        const mac = [6]u8{ @truncate(ral), @truncate(ral >> 8), @truncate(ral >> 16), @truncate(ral >> 24), @truncate(rah), @truncate(rah >> 8) };
        const rx_ring = pages.allocate(1) orelse return error.OutOfMemory;
        const tx_ring = pages.allocate(1) orelse return error.OutOfMemory;
        const tx_buffer = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(rx_ring); zeroPage(tx_ring); zeroPage(tx_buffer);
        var buffers: [descriptor_count]u64 = undefined;
        const rx_descriptors: [*]u64 = @ptrFromInt(rx_ring);
        for (0..descriptor_count) |index| {
            buffers[index] = pages.allocate(1) orelse return error.OutOfMemory;
            zeroPage(buffers[index]);
            rx_descriptors[index * 2] = buffers[index];
            rx_descriptors[index * 2 + 1] = 0;
        }
        write32(base, 0x2800, @truncate(rx_ring)); write32(base, 0x2804, @truncate(rx_ring >> 32));
        write32(base, 0x2808, descriptor_count * 16); write32(base, 0x2810, 0); write32(base, 0x2818, descriptor_count - 1);
        write32(base, 0x3800, @truncate(tx_ring)); write32(base, 0x3804, @truncate(tx_ring >> 32));
        write32(base, 0x3808, descriptor_count * 16); write32(base, 0x3810, 0); write32(base, 0x3818, 0);
        write32(base, 0x0100, (1 << 1) | (1 << 15) | (1 << 26));
        write32(base, 0x0400, (1 << 1) | (1 << 3) | (0x10 << 4) | (0x40 << 12));
        write32(base, 0x0410, 10 | (8 << 10) | (6 << 20));
        interrupt_base = base;
        interrupts = 0;
        last_interrupt_apic = 0xffffffff;
        return .{ .base = base, .mac = mac, .rx_ring = rx_ring, .tx_ring = tx_ring, .rx_buffers = buffers, .tx_buffer = tx_buffer };
    }

    pub fn send(self: *Controller, frame: []const u8) !void {
        if (frame.len > 1514) return error.FrameTooLarge;
        const buffer: [*]u8 = @ptrFromInt(self.tx_buffer);
        @memcpy(buffer[0..frame.len], frame);
        const descriptor: [*]volatile u8 = @ptrFromInt(self.tx_ring + @as(u64, self.tx_index) * 16);
        put64(descriptor, self.tx_buffer); put16(descriptor + 8, @intCast(frame.len));
        descriptor[10] = 0; descriptor[11] = 0x0b; descriptor[12] = 0;
        self.tx_index = (self.tx_index + 1) % descriptor_count;
        write32(self.base, 0x3818, self.tx_index);
        var spins: usize = 0;
        while ((descriptor[12] & 1) == 0 and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
        if (spins == 100_000_000) return error.TransmitTimeout;
    }

    pub fn receive(self: *Controller, output: []u8) !usize {
        const descriptor: [*]volatile u8 = @ptrFromInt(self.rx_ring + @as(u64, self.rx_index) * 16);
        var spins: usize = 0;
        while ((descriptor[12] & 1) == 0 and spins < 1_000_000_000) : (spins += 1) asm volatile ("pause");
        if (spins == 1_000_000_000) return error.ReceiveTimeout;
        const length = get16(descriptor + 8);
        if (length > output.len) return error.BufferTooSmall;
        const source: [*]const u8 = @ptrFromInt(self.rx_buffers[self.rx_index]);
        @memcpy(output[0..length], source[0..length]);
        descriptor[12] = 0;
        const completed = self.rx_index;
        self.rx_index = (self.rx_index + 1) % descriptor_count;
        write32(self.base, 0x2818, completed);
        return length;
    }
};

pub fn enableInterrupts(controller: *Controller) void {
    _ = read32(controller.base, 0x00c0);
    write32(controller.base, 0x00d0, 0x000000d5);
}

pub fn handleInterrupt() callconv(.c) void {
    if (interrupt_base == 0) return;
    const cause = read32(interrupt_base, 0x00c0);
    if (cause != 0) {
        @atomicStore(u32, &last_interrupt_apic, apic.id(), .release);
        _ = @atomicRmw(u64, &interrupts, .Add, 1, .release);
    }
}

pub fn interruptCount() u64 { return @atomicLoad(u64, &interrupts, .acquire); }
pub fn interruptApic() u32 { return @atomicLoad(u32, &last_interrupt_apic, .acquire); }

fn zeroPage(address: u64) void { const bytes: [*]u8 = @ptrFromInt(address); @memset(bytes[0..4096], 0); }
fn read32(base: u64, offset: u64) u32 { const value: *volatile u32 = @ptrFromInt(base + offset); return value.*; }
fn write32(base: u64, offset: u64, value: u32) void { const target: *volatile u32 = @ptrFromInt(base + offset); target.* = value; }
fn put16(target: [*]volatile u8, value: u16) void { target[0] = @truncate(value); target[1] = @truncate(value >> 8); }
fn put64(target: [*]volatile u8, value: u64) void { var i: usize = 0; while (i < 8) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
fn get16(source: [*]volatile u8) u16 { return @as(u16, source[0]) | (@as(u16, source[1]) << 8); }
