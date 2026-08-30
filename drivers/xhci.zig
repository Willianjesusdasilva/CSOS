const pci = @import("pci");
const physical = @import("physical");

pub const Controller = struct {
    base: u64,
    operational: u64,
    runtime: u64,
    doorbells: u64,
    max_ports: u8,
    connected_ports: u8,
    context_size: u8,
    dcbaa: u64,
    command_ring: u64,
    command_index: u16 = 0,
    event_ring: u64,
    event_index: u16 = 0,
    event_phase: u1 = 1,

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
        return .{
            .base = base, .operational = operational, .runtime = runtime, .doorbells = doorbells,
            .max_ports = max_ports, .connected_ports = connected,
            .context_size = if ((read32(base, 0x10) & 4) != 0) 64 else 32,
            .dcbaa = dcbaa, .command_ring = command_ring, .event_ring = event_ring,
        };
    }

    pub fn enumerateHid(self: *Controller, pages: *physical.Allocator) !HidDevices {
        var devices = HidDevices{};
        var port: u8 = 0;
        while (port < self.max_ports) : (port += 1) {
            const port_register = self.operational + 0x400 + @as(u64, port) * 0x10;
            var status = read32(port_register, 0);
            if ((status & 1) == 0) continue;
            write32(port_register, 0, (status & (1 << 9)) | (1 << 4));
            var spins: usize = 0;
            while ((read32(port_register, 0) & (1 << 4)) != 0 and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
            if (spins == 100_000_000) return error.PortResetTimeout;
            status = read32(port_register, 0);
            if ((status & 2) == 0) return error.PortNotEnabled;
            const speed: u4 = @truncate(status >> 10);
            const slot = try self.command(0, 0, 0, 9, 0);
            const device_context = pages.allocate(1) orelse return error.OutOfMemory;
            const input_context = pages.allocate(1) orelse return error.OutOfMemory;
            const transfer_ring = pages.allocate(1) orelse return error.OutOfMemory;
            const descriptor = pages.allocate(1) orelse return error.OutOfMemory;
            zeroPage(device_context); zeroPage(input_context); zeroPage(transfer_ring); zeroPage(descriptor);
            const dcbaa_entries: [*]u64 = @ptrFromInt(self.dcbaa);
            dcbaa_entries[slot] = device_context;
            const input: [*]u32 = @ptrFromInt(input_context);
            input[1] = 3;
            const slot_offset = @as(usize, self.context_size) / 4;
            input[slot_offset] = (@as(u32, speed) << 20) | (1 << 27);
            input[slot_offset + 1] = @as(u32, port + 1) << 16;
            const ep_offset = slot_offset * 2;
            const max_packet: u16 = switch (speed) { 3 => 64, 4 => 512, else => 8 };
            input[ep_offset + 1] = (@as(u32, max_packet) << 16) | (4 << 3) | (3 << 1);
            input[ep_offset + 2] = @as(u32, @truncate(transfer_ring)) | 1;
            input[ep_offset + 3] = @truncate(transfer_ring >> 32);
            input[ep_offset + 4] = 8;
            _ = try self.command(input_context, 0, 0, 11, slot);
            const length = try self.getDescriptor(slot, transfer_ring, descriptor, 0x0200, 255);
            const bytes: [*]const u8 = @ptrFromInt(descriptor);
            var offset: usize = 0;
            while (offset + 2 <= length and bytes[offset] >= 2 and offset + bytes[offset] <= length) : (offset += bytes[offset]) {
                if (bytes[offset + 1] == 4 and bytes[offset] >= 9 and bytes[offset + 5] == 3 and bytes[offset + 6] == 1) {
                    if (bytes[offset + 7] == 1) devices.keyboards += 1;
                    if (bytes[offset + 7] == 2) devices.mice += 1;
                }
            }
        }
        return devices;
    }

    fn command(self: *Controller, parameter: u64, status: u32, control: u32, trb_type: u6, slot: u8) !u8 {
        const trb: [*]volatile u32 = @ptrFromInt(self.command_ring + @as(u64, self.command_index) * 16);
        trb[0] = @truncate(parameter); trb[1] = @truncate(parameter >> 32); trb[2] = status;
        trb[3] = control | (@as(u32, trb_type) << 10) | 1 | (@as(u32, slot) << 24);
        self.command_index += 1;
        write32(self.doorbells, 0, 0);
        const event = try self.waitEvent(33);
        if (event.completion != 1) return error.CommandFailed;
        return event.slot;
    }

    fn getDescriptor(self: *Controller, slot: u8, ring: u64, buffer: u64, value: u16, length: u16) !usize {
        const trbs: [*]volatile u32 = @ptrFromInt(ring);
        trbs[0] = 0x80 | (6 << 8) | (@as(u32, value) << 16);
        trbs[1] = @as(u32, length) << 16;
        trbs[2] = 8;
        trbs[3] = (2 << 10) | (1 << 6) | (3 << 16) | 1;
        trbs[4] = @truncate(buffer); trbs[5] = @truncate(buffer >> 32);
        trbs[6] = length;
        trbs[7] = (3 << 10) | (1 << 16) | (1 << 2) | 1;
        trbs[8] = 0; trbs[9] = 0; trbs[10] = 0;
        trbs[11] = (4 << 10) | (1 << 5) | 1;
        write32(self.doorbells + @as(u64, slot) * 4, 0, 1);
        const event = try self.waitEvent(32);
        if (event.completion != 1 and event.completion != 13) return error.TransferFailed;
        return length - @as(u16, @truncate(event.residual));
    }

    fn waitEvent(self: *Controller, wanted_type: u6) !Event {
        var spins: usize = 0;
        while (spins < 100_000_000) : (spins += 1) {
            const trb: [*]volatile u32 = @ptrFromInt(self.event_ring + @as(u64, self.event_index) * 16);
            if ((trb[3] & 1) != self.event_phase) { asm volatile ("pause"); continue; }
            const event = Event{ .residual = trb[2] & 0xffffff, .completion = @truncate(trb[2] >> 24), .slot = @truncate(trb[3] >> 24) };
            const event_type: u6 = @truncate(trb[3] >> 10);
            self.event_index += 1;
            if (self.event_index == 256) { self.event_index = 0; self.event_phase ^= 1; }
            write64(self.runtime, 0x38, self.event_ring + @as(u64, self.event_index) * 16 | 8);
            if (event_type == wanted_type) return event;
        }
        return error.EventTimeout;
    }
};

pub const HidDevices = struct { keyboards: u8 = 0, mice: u8 = 0 };
const Event = struct { residual: u32, completion: u8, slot: u8 };

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
