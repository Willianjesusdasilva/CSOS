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
            var protocol: u8 = 0;
            var endpoint_address: u8 = 0;
            var endpoint_packet: u16 = 0;
            var interval: u8 = 0;
            while (offset + 2 <= length and bytes[offset] >= 2 and offset + bytes[offset] <= length) : (offset += bytes[offset]) {
                if (bytes[offset + 1] == 4 and bytes[offset] >= 9 and bytes[offset + 5] == 3 and bytes[offset + 6] == 1) {
                    protocol = bytes[offset + 7];
                } else if (protocol != 0 and bytes[offset + 1] == 5 and bytes[offset] >= 7 and (bytes[offset + 2] & 0x80) != 0 and (bytes[offset + 3] & 3) == 3) {
                    endpoint_address = bytes[offset + 2];
                    endpoint_packet = get16(bytes + offset + 4) & 0x7ff;
                    interval = bytes[offset + 6];
                    break;
                }
            }
            if (protocol == 0 or endpoint_address == 0 or endpoint_packet == 0) return error.HidEndpointMissing;
            const endpoint_id: u5 = @intCast((endpoint_address & 0x0f) * 2 + 1);
            const interrupt_ring = pages.allocate(1) orelse return error.OutOfMemory;
            const report = pages.allocate(1) orelse return error.OutOfMemory;
            const configure = pages.allocate(1) orelse return error.OutOfMemory;
            zeroPage(interrupt_ring); zeroPage(report); zeroPage(configure);
            const config: [*]u32 = @ptrFromInt(configure);
            config[1] = 1 | (@as(u32, 1) << endpoint_id);
            const config_slot = @as(usize, self.context_size) / 4;
            config[config_slot] = (@as(u32, speed) << 20) | (@as(u32, endpoint_id) << 27);
            config[config_slot + 1] = @as(u32, port + 1) << 16;
            const config_ep = @as(usize, endpoint_id + 1) * config_slot;
            config[config_ep] = @as(u32, intervalValue(speed, interval)) << 16;
            config[config_ep + 1] = (@as(u32, endpoint_packet) << 16) | (7 << 3) | (3 << 1);
            config[config_ep + 2] = @as(u32, @truncate(interrupt_ring)) | 1;
            config[config_ep + 3] = @truncate(interrupt_ring >> 32);
            config[config_ep + 4] = @as(u32, endpoint_packet) | (@as(u32, endpoint_packet) << 16);
            _ = try self.command(configure, 0, 0, 12, slot);
            try self.setConfiguration(slot, transfer_ring, bytes[5]);
            var endpoint = Endpoint{ .slot = slot, .id = endpoint_id, .ring = interrupt_ring, .report = report, .packet_size = endpoint_packet };
            endpoint.installLink();
            self.armEndpoint(&endpoint);
            if (protocol == 1) { devices.keyboards += 1; devices.keyboard = endpoint; }
            if (protocol == 2) { devices.mice += 1; devices.mouse = endpoint; }
        }
        return devices;
    }

    pub fn pollHid(self: *Controller, devices: *HidDevices) !bool {
        var handled = false;
        while (self.nextEvent()) |typed| {
            if (typed.kind != 32) continue;
            const event = typed.event;
            if (event.completion != 1 and event.completion != 13) return error.TransferFailed;
            const endpoint: *Endpoint = if (event.slot == devices.keyboard.slot and event.endpoint == devices.keyboard.id)
                &devices.keyboard
            else if (event.slot == devices.mouse.slot and event.endpoint == devices.mouse.id)
                &devices.mouse
            else
                continue;
            const size: u16 = endpoint.packet_size - @min(endpoint.packet_size, @as(u16, @truncate(event.residual)));
            const report: [*]const u8 = @ptrFromInt(endpoint.report);
            if (endpoint.slot == devices.keyboard.slot) {
                devices.push(.{ .kind = .keyboard, .a = if (size > 2) report[2] else 0, .b = if (size > 0) report[0] else 0 });
            } else {
                devices.push(.{ .kind = .mouse, .a = if (size > 1) report[1] else 0, .b = if (size > 2) report[2] else 0 });
            }
            self.armEndpoint(endpoint);
            handled = true;
        }
        return handled;
    }

    fn armEndpoint(self: *Controller, endpoint: *Endpoint) void {
        if (endpoint.enqueue == 255) {
            endpoint.installLink();
            endpoint.enqueue = 0;
            endpoint.cycle ^= 1;
        }
        const trb: [*]volatile u32 = @ptrFromInt(endpoint.ring + @as(u64, endpoint.enqueue) * 16);
        trb[0] = @truncate(endpoint.report); trb[1] = @truncate(endpoint.report >> 32);
        trb[2] = endpoint.packet_size;
        trb[3] = (1 << 10) | (1 << 5) | (1 << 2) | @as(u32, endpoint.cycle);
        endpoint.enqueue += 1;
        write32(self.doorbells + @as(u64, endpoint.slot) * 4, 0, endpoint.id);
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

    fn setConfiguration(self: *Controller, slot: u8, ring: u64, configuration: u8) !void {
        const trbs: [*]volatile u32 = @ptrFromInt(ring + 3 * 16);
        trbs[0] = (9 << 8) | (@as(u32, configuration) << 16);
        trbs[1] = 0; trbs[2] = 8;
        trbs[3] = (2 << 10) | (1 << 6) | 1;
        trbs[4] = 0; trbs[5] = 0; trbs[6] = 0;
        trbs[7] = (4 << 10) | (1 << 16) | (1 << 5) | 1;
        write32(self.doorbells + @as(u64, slot) * 4, 0, 1);
        const event = try self.waitEvent(32);
        if (event.completion != 1) return error.SetConfigurationFailed;
    }

    fn waitEvent(self: *Controller, wanted_type: u6) !Event {
        var spins: usize = 0;
        while (spins < 10_000_000_000) : (spins += 1) {
            if (self.nextEvent()) |typed| {
                if (typed.kind == wanted_type) return typed.event;
            } else asm volatile ("pause");
        }
        return error.EventTimeout;
    }

    fn nextEvent(self: *Controller) ?TypedEvent {
        const trb: [*]volatile u32 = @ptrFromInt(self.event_ring + @as(u64, self.event_index) * 16);
        if ((trb[3] & 1) != self.event_phase) return null;
        const typed = TypedEvent{
            .kind = @truncate(trb[3] >> 10),
            .event = .{
                .residual = trb[2] & 0xffffff,
                .completion = @truncate(trb[2] >> 24),
                .endpoint = @truncate(trb[3] >> 16),
                .slot = @truncate(trb[3] >> 24),
            },
        };
        self.event_index += 1;
        if (self.event_index == 256) { self.event_index = 0; self.event_phase ^= 1; }
        write64(self.runtime, 0x38, self.event_ring + @as(u64, self.event_index) * 16 | 8);
        return typed;
    }
};

const Endpoint = struct {
    slot: u8 = 0,
    id: u5 = 0,
    ring: u64 = 0,
    report: u64 = 0,
    packet_size: u16 = 0,
    enqueue: u16 = 0,
    cycle: u1 = 1,

    fn installLink(self: *Endpoint) void {
        const link: [*]volatile u32 = @ptrFromInt(self.ring + 255 * 16);
        link[0] = @truncate(self.ring); link[1] = @truncate(self.ring >> 32); link[2] = 0;
        link[3] = (6 << 10) | (1 << 1) | @as(u32, self.cycle);
    }
};

pub const InputKind = enum { keyboard, mouse };
pub const InputEvent = struct { kind: InputKind, a: u8, b: u8 };
pub const HidDevices = struct {
    keyboards: u8 = 0,
    mice: u8 = 0,
    keyboard: Endpoint = .{},
    mouse: Endpoint = .{},
    queue: [64]InputEvent = undefined,
    queue_head: u8 = 0,
    queue_tail: u8 = 0,
    events_total: u64 = 0,

    fn push(self: *HidDevices, event: InputEvent) void {
        const next: u8 = (self.queue_tail + 1) % 64;
        if (next == self.queue_head) self.queue_head = (self.queue_head + 1) % 64;
        self.queue[self.queue_tail] = event;
        self.queue_tail = @intCast(next);
        self.events_total += 1;
    }

    pub fn pop(self: *HidDevices) ?InputEvent {
        if (self.queue_head == self.queue_tail) return null;
        const event = self.queue[self.queue_head];
        self.queue_head = (self.queue_head + 1) % 64;
        return event;
    }
};
const Event = struct { residual: u32, completion: u8, endpoint: u5, slot: u8 };
const TypedEvent = struct { kind: u6, event: Event };

fn intervalValue(speed: u4, interval: u8) u8 {
    if (speed >= 3) return if (interval == 0) 0 else interval - 1;
    var value: u8 = 0;
    var period: u16 = 1;
    while (period < interval and value < 7) : (value += 1) period <<= 1;
    return value + 3;
}

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
fn get16(source: [*]const u8) u16 { return @as(u16, source[0]) | (@as(u16, source[1]) << 8); }
