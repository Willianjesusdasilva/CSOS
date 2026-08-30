const pci = @import("pci");
const physical = @import("physical");
const apic = @import("apic");

var interrupt_runtime: u64 = 0;
var interrupts: u64 = 0;
var last_interrupt_apic: u32 = 0xffffffff;

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
    devices: [16]UsbDevice = .{UsbDevice{}} ** 16,
    device_count: u8 = 0,
    audio: AudioDevices = .{},

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
        try self.enumerateDevices(pages);
        for (self.devices[0..self.device_count]) |device| {
            const bytes: [*]const u8 = @ptrFromInt(device.descriptor);
            const length = device.descriptor_length;
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
            if (protocol == 0) continue;
            if (endpoint_address == 0 or endpoint_packet == 0) return error.HidEndpointMissing;
            const endpoint_id: u5 = @intCast((endpoint_address & 0x0f) * 2 + 1);
            const interrupt_ring = pages.allocate(1) orelse return error.OutOfMemory;
            const report = pages.allocate(1) orelse return error.OutOfMemory;
            const configure = pages.allocate(1) orelse return error.OutOfMemory;
            zeroPage(interrupt_ring); zeroPage(report); zeroPage(configure);
            const config: [*]u32 = @ptrFromInt(configure);
            config[1] = 1 | (@as(u32, 1) << endpoint_id);
            const config_slot = @as(usize, self.context_size) / 4;
            config[config_slot] = (@as(u32, device.speed) << 20) | (@as(u32, endpoint_id) << 27);
            config[config_slot + 1] = @as(u32, device.port + 1) << 16;
            const config_ep = @as(usize, endpoint_id + 1) * config_slot;
            config[config_ep] = @as(u32, intervalValue(device.speed, interval)) << 16;
            config[config_ep + 1] = (@as(u32, endpoint_packet) << 16) | (7 << 3) | (3 << 1);
            config[config_ep + 2] = @as(u32, @truncate(interrupt_ring)) | 1;
            config[config_ep + 3] = @truncate(interrupt_ring >> 32);
            config[config_ep + 4] = @as(u32, endpoint_packet) | (@as(u32, endpoint_packet) << 16);
            _ = try self.command(configure, 0, 0, 12, device.slot);
            try self.setConfiguration(device.slot, device.ring, bytes[5]);
            var endpoint = Endpoint{ .slot = device.slot, .id = endpoint_id, .ring = interrupt_ring, .report = report, .packet_size = endpoint_packet };
            endpoint.installLink();
            self.armEndpoint(&endpoint);
            if (protocol == 1) { devices.keyboards += 1; devices.keyboard = endpoint; }
            if (protocol == 2) { devices.mice += 1; devices.mouse = endpoint; }
        }
        return devices;
    }

    pub fn enableInterrupts(self: *Controller) void {
        interrupt_runtime = self.runtime;
        interrupts = 0;
        last_interrupt_apic = 0xffffffff;
        write32(self.runtime + 0x20, 0, 3);
        write32(self.operational, 0, read32(self.operational, 0) | 4);
    }

    pub fn interruptEnabled(self: *const Controller) bool {
        return (read32(self.runtime + 0x20, 0) & 2) != 0 and (read32(self.operational, 0) & 4) != 0;
    }

    pub fn enumerateAudio(self: *Controller, pages: *physical.Allocator) !AudioDevices {
        var devices = AudioDevices{};
        try self.enumerateDevices(pages);
        for (self.devices[0..self.device_count], 0..) |device, device_index| {
            const bytes: [*]const u8 = @ptrFromInt(device.descriptor);
            var offset: usize = 0;
            var audio_interface = false;
            while (offset + 2 <= device.descriptor_length and bytes[offset] >= 2 and offset + bytes[offset] <= device.descriptor_length) : (offset += bytes[offset]) {
                if (bytes[offset + 1] == 4 and bytes[offset] >= 9 and offset + 7 < device.descriptor_length) {
                    audio_interface = bytes[offset + 5] == 1 and bytes[offset + 6] == 2 and bytes[offset + 3] != 0;
                    if (audio_interface) {
                        devices.interfaces += 1;
                        devices.interface_number = bytes[offset + 2];
                        devices.alternate = bytes[offset + 3];
                        devices.device_index = @intCast(device_index);
                        const payload = pages.allocate(1) orelse return error.OutOfMemory;
                        zeroPage(payload);
                        devices.rate_payload = payload;
                    }
                } else if (audio_interface and bytes[offset + 1] == 36 and bytes[offset] >= 8 and bytes[offset + 2] == 2) {
                    if (offset + 7 < device.descriptor_length) {
                        devices.channels = bytes[offset + 4];
                        devices.bits_per_sample = bytes[offset + 7];
                        if (bytes[offset] >= 11 and offset + 10 < device.descriptor_length) {
                            devices.sample_rate = get24(bytes + offset + 9);
                            devices.sample_rates += 1;
                            if (devices.sample_rates == 1) devices.sample_rate = get24(bytes + offset + 9);
                        }
                    }
                } else if (audio_interface and bytes[offset + 1] == 5 and bytes[offset] >= 7 and (bytes[offset + 2] & 0x80) == 0 and (bytes[offset + 3] & 3) == 1) {
                    devices.playback_endpoints += 1;
                    devices.endpoint_address = bytes[offset + 2];
                    devices.endpoint_packet = get16(bytes + offset + 4) & 0x7ff;
                    devices.interval = bytes[offset + 6];
                    devices.slot = device.slot;
                    devices.endpoint_id = @intCast((bytes[offset + 2] & 0x0f) * 2);
                } else if (audio_interface and bytes[offset + 1] == 37 and bytes[offset] >= 4 and bytes[offset + 2] == 1) {
                    devices.rate_control = (bytes[offset + 3] & 1) != 0;
                }
            }
        }
        self.audio = devices;
        return devices;
    }

    pub fn audioReady(self: *const Controller) bool {
        return self.audio.playback_endpoints != 0 and self.audio.endpoint_packet != 0;
    }

    pub fn audioFormatFits(self: *const Controller) bool {
        if (self.audio.sample_rate == 0 or self.audio.channels == 0 or self.audio.bits_per_sample == 0) return false;
        const bytes_per_second = @as(u64, self.audio.sample_rate) *
            @as(u64, self.audio.channels) *
            (@as(u64, self.audio.bits_per_sample) / 8);
        const periods_per_second: u64 = if (self.audio.interval == 0) 1000 else
            @max(@as(u64, 1), @as(u64, 8000) >> @as(u6, @intCast(@min(self.audio.interval - 1, 7))));
        const bytes_per_period = (bytes_per_second + periods_per_second - 1) / periods_per_second;
        return bytes_per_period <= self.audio.endpoint_packet;
    }

    pub fn audioStatus(self: *const Controller) AudioStatus {
        return .{
            .interfaces = self.audio.interfaces,
            .playback_endpoints = self.audio.playback_endpoints,
            .interface_number = self.audio.interface_number,
            .endpoint_address = self.audio.endpoint_address,
            .endpoint_packet = self.audio.endpoint_packet,
            .configured = false,
        };
    }

    pub fn audioConfigure(self: *Controller, pages: *physical.Allocator) !void {
        if (!self.audioReady()) return error.AudioEndpointMissing;
        if (self.audio.configured) return;
        const device = self.devices[self.audio.device_index];
        const ring = pages.allocate(1) orelse return error.OutOfMemory;
        const configure = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(ring);
        zeroPage(configure);
        const endpoint_id: u5 = @intCast((self.audio.endpoint_address & 0x0f) * 2);
        const config: [*]u32 = @ptrFromInt(configure);
        config[1] = 1 | (@as(u32, 1) << endpoint_id);
        const slot_offset = @as(usize, self.context_size) / 4;
        config[slot_offset] = (@as(u32, device.speed) << 20) | (@as(u32, endpoint_id) << 27);
        config[slot_offset + 1] = @as(u32, device.port + 1) << 16;
        const endpoint_offset = @as(usize, endpoint_id + 1) * slot_offset;
        config[endpoint_offset] = @as(u32, intervalValue(device.speed, self.audio.interval)) << 16;
        config[endpoint_offset + 1] = (@as(u32, self.audio.endpoint_packet) << 16) | (1 << 3) | (1 << 1);
        config[endpoint_offset + 2] = @as(u32, @truncate(ring)) | 1;
        config[endpoint_offset + 3] = @truncate(ring >> 32);
        config[endpoint_offset + 4] = @as(u32, self.audio.endpoint_packet) |
            (@as(u32, self.audio.endpoint_packet) << 16);
        _ = try self.command(configure, 0, 0, 12, device.slot);
        self.audio.ring = ring;
        self.audio.configured = true;
    }

    pub fn audioSetInterface(self: *Controller, interface: u8, alternate: u8) !void {
        if (self.audio.device_index >= self.device_count) return error.AudioDeviceMissing;
        const device = self.devices[self.audio.device_index];
        const setup = 0x01 | (@as(u32, 11) << 8) | (@as(u32, alternate) << 16);
        try self.controlTransfer(device.slot, device.ring, setup, interface, 0, null);
    }

    pub fn audioStart(self: *Controller, pages: *physical.Allocator, interface: u8, alternate: u8) !void {
        if (!self.audioReady()) return error.AudioEndpointMissing;
        if (!self.audioFormatFits()) return error.UnsupportedAudioFormat;
        if (self.audio.rate_control and self.audio.sample_rate != 0)
            self.audioSetSampleRate(self.audio.sample_rate) catch return error.AudioSetRateFailed;
        self.audioConfigure(pages) catch return error.AudioConfigureEndpointFailed;
        self.audio.interface_number = interface;
        self.audio.alternate = alternate;
    }

    fn audioSetSampleRate(self: *Controller, rate: u32) !void {
        if (self.audio.device_index >= self.device_count) return error.AudioDeviceMissing;
        const device = self.devices[self.audio.device_index];
        const request = 0x22 | (@as(u32, 1) << 8) | (@as(u32, 0x0100) << 16);
        const payload = self.audio.rate_payload orelse return error.AudioRatePayloadMissing;
        const bytes: [*]u8 = @ptrFromInt(payload);
        bytes[0] = @truncate(rate);
        bytes[1] = @truncate(rate >> 8);
        bytes[2] = @truncate(rate >> 16);
        try self.controlTransfer(device.slot, device.ring, request, self.audio.endpoint_address, 3, payload);
        self.audio.sample_rate = rate;
    }

    pub fn audioStartDiscovered(self: *Controller, pages: *physical.Allocator) !void {
        if (self.audio.interfaces == 0) return error.AudioDeviceMissing;
        try self.audioStart(pages, self.audio.interface_number, self.audio.alternate);
    }

    pub fn audioSubmitSilence(self: *Controller, pages: *physical.Allocator) !void {
        if (!self.audio.configured or self.audio.ring == 0) return error.AudioNotConfigured;
        const sample = self.audio.sample orelse blk: {
            const allocated = pages.allocate(1) orelse return error.OutOfMemory;
            zeroPage(allocated);
            self.audio.sample = allocated;
            break :blk allocated;
        };
        const trb: [*]volatile u32 = @ptrFromInt(self.audio.ring);
        trb[0] = @truncate(sample);
        trb[1] = @truncate(sample >> 32);
        trb[2] = self.audio.endpoint_packet;
        trb[3] = (5 << 10) | (1 << 31) | (1 << 5) | (1 << 2) | 1;
        write32(self.doorbells + @as(u64, self.audio.slot) * 4, 0, self.audio.endpoint_id);
    }

    pub fn audioSubmitTone(self: *Controller, pages: *physical.Allocator) !void {
        if (!self.audio.configured or self.audio.ring == 0) return error.AudioNotConfigured;
        if (self.audio.channels == 0 or self.audio.bits_per_sample != 16) return error.UnsupportedAudioFormat;
        const frame_size = @as(usize, self.audio.channels) * 2;
        const transfer_length = @min(@as(usize, self.audio.endpoint_packet), 4096);
        if (frame_size == 0 or transfer_length < frame_size) return error.UnsupportedAudioFormat;
        const sample = self.audio.sample orelse blk: {
            const allocated = pages.allocate(1) orelse return error.OutOfMemory;
            const output: [*]u8 = @ptrFromInt(allocated);
            var index: usize = 0;
            while (index + frame_size <= transfer_length) : (index += frame_size) {
                const phase = @as(i16, @intCast((index / frame_size) & 63));
                const value: i16 = if (phase < 32) 12000 else -12000;
                var channel: usize = 0;
                while (channel < self.audio.channels) : (channel += 1) {
                    const target = index + channel * 2;
                    output[target] = @truncate(@as(u16, @bitCast(value)));
                    output[target + 1] = @truncate(@as(u16, @bitCast(value)) >> 8);
                }
            }
            self.audio.sample = allocated;
            break :blk allocated;
        };
        const trb: [*]volatile u32 = @ptrFromInt(self.audio.ring);
        trb[0] = @truncate(sample);
        trb[1] = @truncate(sample >> 32);
        trb[2] = @intCast(transfer_length);
        trb[3] = (5 << 10) | (1 << 31) | (1 << 5) | (1 << 2) | 1;
        write32(self.doorbells + @as(u64, self.audio.slot) * 4, 0, self.audio.endpoint_id);
    }

    pub fn audioPrime(self: *Controller, pages: *physical.Allocator) !void {
        if (!self.audio.configured) return error.AudioNotConfigured;
        if (self.audio.endpoint_packet == 0) return error.UnsupportedAudioFormat;
        self.audio.dequeue = 0;
        self.audio.cycle = 1;
        var period: u16 = 0;
        while (period < 255) : (period += 1) {
            const buffer_index: u8 = @intCast(period % 64);
            const buffer = self.audio.buffers[buffer_index] orelse blk: {
                const allocated = pages.allocate(1) orelse return error.OutOfMemory;
                self.audio.buffers[buffer_index] = allocated;
                break :blk allocated;
            };
            fillAudioPeriod(buffer, self.audio.endpoint_packet, self.audio.channels);
            const trb: [*]volatile u32 = @ptrFromInt(self.audio.ring + @as(u64, period) * 16);
            trb[0] = @truncate(buffer);
            trb[1] = @truncate(buffer >> 32);
            trb[2] = self.audio.endpoint_packet;
            trb[3] = (5 << 10) | (1 << 31) | (1 << 5) | (1 << 2) | @as(u32, self.audio.cycle);
        }
        const link: [*]volatile u32 = @ptrFromInt(self.audio.ring + 255 * 16);
        link[0] = @truncate(self.audio.ring);
        link[1] = @truncate(self.audio.ring >> 32);
        link[2] = 0;
        link[3] = (6 << 10) | (1 << 1) | @as(u32, self.audio.cycle);
        self.audioSetInterface(self.audio.interface_number, self.audio.alternate) catch return error.AudioSetInterfaceFailed;
        write32(self.doorbells + @as(u64, self.audio.slot) * 4, 0, self.audio.endpoint_id);
    }

    pub fn pollAudio(self: *Controller) !bool {
        while (self.nextEvent()) |typed| {
            if (typed.kind != 32) continue;
            if (try self.handleAudioEvent(typed.event)) return true;
        }
        return false;
    }

    fn handleAudioEvent(self: *Controller, event: Event) !bool {
        if (event.slot != self.audio.slot or event.endpoint != self.audio.endpoint_id) return false;
        self.audio.last_completion = event.completion;
        if (event.completion == 14) {
            self.audio.cycle ^= 1;
            self.audio.dequeue = 0;
            var period: u16 = 0;
            while (period < 255) : (period += 1) {
                const buffer = self.audio.buffers[period % 64] orelse return error.AudioBufferMissing;
                fillAudioPeriod(buffer, self.audio.endpoint_packet, self.audio.channels);
                const trb: [*]volatile u32 = @ptrFromInt(self.audio.ring + @as(u64, period) * 16);
                trb[0] = @truncate(buffer);
                trb[1] = @truncate(buffer >> 32);
                trb[2] = self.audio.endpoint_packet;
                trb[3] = (5 << 10) | (1 << 31) | (1 << 5) | (1 << 2) | @as(u32, self.audio.cycle);
            }
            const link: [*]volatile u32 = @ptrFromInt(self.audio.ring + 255 * 16);
            link[0] = @truncate(self.audio.ring);
            link[1] = @truncate(self.audio.ring >> 32);
            link[2] = 0;
            link[3] = (6 << 10) | (1 << 1) | @as(u32, self.audio.cycle);
            self.audio.completed += 255;
            write32(self.doorbells + @as(u64, self.audio.slot) * 4, 0, self.audio.endpoint_id);
            return true;
        }
        if (event.completion != 1 and event.completion != 13) {
            self.audio.underruns += 1;
            return switch (event.completion) {
                21 => error.AudioMissedService,
                15 => error.AudioRingOverrun,
                else => error.AudioTransferFailed,
            };
        }
        const period = self.audio.dequeue;
        const buffer = self.audio.buffers[period % 64] orelse return error.AudioBufferMissing;
        fillAudioPeriod(buffer, self.audio.endpoint_packet, self.audio.channels);
        const trb: [*]volatile u32 = @ptrFromInt(self.audio.ring + @as(u64, period) * 16);
        trb[0] = @truncate(buffer);
        trb[1] = @truncate(buffer >> 32);
        trb[2] = self.audio.endpoint_packet;
        trb[3] = (5 << 10) | (1 << 31) | (1 << 5) | (1 << 2) | @as(u32, self.audio.cycle ^ 1);
        self.audio.dequeue = if (period == 254) 0 else period + 1;
        if (self.audio.dequeue == 0) self.audio.cycle ^= 1;
        self.audio.completed += 1;
        write32(self.doorbells + @as(u64, self.audio.slot) * 4, 0, self.audio.endpoint_id);
        return true;
    }

    fn enumerateDevices(self: *Controller, pages: *physical.Allocator) !void {
        if (self.device_count != 0) return;
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
            const slot = self.command(0, 0, 0, 9, 0) catch return error.EnableSlotFailed;
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
            const max_packet: u16 = switch (speed) { 1, 3 => 64, 4 => 512, else => 8 };
            input[ep_offset + 1] = (@as(u32, max_packet) << 16) | (4 << 3) | (3 << 1);
            input[ep_offset + 2] = @as(u32, @truncate(transfer_ring)) | 1;
            input[ep_offset + 3] = @truncate(transfer_ring >> 32);
            input[ep_offset + 4] = 8;
            _ = self.command(input_context, 0, 0, 11, slot) catch return error.AddressDeviceFailed;
            const length = self.getDescriptor(slot, transfer_ring, descriptor, 0x0200, 255) catch return error.ConfigurationDescriptorFailed;
            if (length < 18) continue;
            self.devices[self.device_count] = .{ .slot = slot, .port = port, .speed = speed, .descriptor = descriptor, .descriptor_length = length, .ring = transfer_ring };
            self.device_count += 1;
        }
    }

    pub fn pollHid(self: *Controller, devices: *HidDevices) !bool {
        var handled = false;
        while (self.nextEvent()) |typed| {
            if (typed.kind != 32) continue;
            const event = typed.event;
            if (try self.handleAudioEvent(event)) { handled = true; continue; }
            if (event.completion != 1 and event.completion != 13) return error.TransferFailed;
            const endpoint: *Endpoint = if (event.slot == devices.keyboard.slot and event.endpoint == devices.keyboard.id)
                &devices.keyboard
            else if (event.slot == devices.mouse.slot and event.endpoint == devices.mouse.id)
                &devices.mouse
            else
                continue;
            const size: u16 = endpoint.packet_size - @min(endpoint.packet_size, @as(u16, @truncate(event.residual)));
            const report: [*]const u8 = @ptrFromInt(endpoint.report);
            const saved_size = @min(@as(usize, size), endpoint.last_report.len);
            var changed = endpoint.last_size != saved_size;
            var report_index: usize = 0;
            while (report_index < saved_size and !changed) : (report_index += 1) changed = report[report_index] != endpoint.last_report[report_index];
            if (changed) {
                @memcpy(endpoint.last_report[0..saved_size], report[0..saved_size]);
                endpoint.last_size = @intCast(saved_size);
                if (endpoint.slot == devices.keyboard.slot) {
                    devices.push(.{ .kind = .keyboard, .a = if (size > 2) report[2] else 0, .b = if (size > 0) report[0] else 0 });
                } else {
                    devices.push(.{ .kind = .mouse, .a = if (size > 1) report[1] else 0, .b = if (size > 2) report[2] else 0 });
                }
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

    fn controlTransfer(self: *Controller, slot: u8, ring: u64, setup: u32, value: u32, length: u16, payload: ?u64) !void {
        const trbs: [*]volatile u32 = @ptrFromInt(ring + @as(u64, self.audio.control_enqueue) * 16);
        trbs[0] = setup;
        trbs[1] = value;
        trbs[2] = 8;
        trbs[3] = (2 << 10) | (1 << 6) | (if (length == 0) 0 else @as(u32, 2) << 16) | 1;
        trbs[4] = @truncate(payload orelse 0); trbs[5] = @truncate((payload orelse 0) >> 32); trbs[6] = length;
        trbs[7] = if (length == 0)
            (4 << 10) | (1 << 16) | (1 << 5) | 1
        else
            (3 << 10) | 1;
        if (length != 0) {
            trbs[8] = 0; trbs[9] = 0; trbs[10] = 0;
            trbs[11] = (4 << 10) | (1 << 16) | (1 << 5) | 1;
        }
        self.audio.control_enqueue += if (length == 0) 2 else 3;
        write32(self.doorbells + @as(u64, slot) * 4, 0, 1);
        const event = try self.waitEvent(32);
        if (event.completion != 1) return error.ControlTransferFailed;
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

pub fn handleInterrupt() callconv(.c) void {
    if (interrupt_runtime == 0) return;
    const iman = read32(interrupt_runtime + 0x20, 0);
    if ((iman & 1) == 0) return;
    write32(interrupt_runtime + 0x20, 0, iman | 3);
    @atomicStore(u32, &last_interrupt_apic, apic.id(), .release);
    _ = @atomicRmw(u64, &interrupts, .Add, 1, .release);
}

pub fn interruptCount() u64 { return @atomicLoad(u64, &interrupts, .acquire); }
pub fn interruptApic() u32 { return @atomicLoad(u32, &last_interrupt_apic, .acquire); }

const Endpoint = struct {
    slot: u8 = 0,
    id: u5 = 0,
    ring: u64 = 0,
    report: u64 = 0,
    packet_size: u16 = 0,
    enqueue: u16 = 0,
    cycle: u1 = 1,
    last_report: [64]u8 = .{0} ** 64,
    last_size: u8 = 0,

    fn installLink(self: *Endpoint) void {
        const link: [*]volatile u32 = @ptrFromInt(self.ring + 255 * 16);
        link[0] = @truncate(self.ring); link[1] = @truncate(self.ring >> 32); link[2] = 0;
        link[3] = (6 << 10) | (1 << 1) | @as(u32, self.cycle);
    }
};

const UsbDevice = struct {
    slot: u8 = 0,
    port: u8 = 0,
    speed: u4 = 0,
    descriptor: u64 = 0,
    descriptor_length: usize = 0,
    ring: u64 = 0,
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

pub const AudioDevices = struct {
    interfaces: u8 = 0,
    playback_endpoints: u8 = 0,
    interface_number: u8 = 0,
    endpoint_address: u8 = 0,
    endpoint_packet: u16 = 0,
    interval: u8 = 0,
    device_index: u8 = 0,
    ring: u64 = 0,
    configured: bool = false,
    slot: u8 = 0,
    endpoint_id: u5 = 0,
    sample: ?u64 = null,
    alternate: u8 = 0,
    channels: u8 = 0,
    bits_per_sample: u8 = 0,
    sample_rate: u32 = 0,
    sample_rates: u8 = 0,
    rate_payload: ?u64 = null,
    rate_control: bool = false,
    buffers: [64]?u64 = .{null} ** 64,
    dequeue: u8 = 0,
    cycle: u1 = 1,
    completed: u64 = 0,
    underruns: u64 = 0,
    control_enqueue: u8 = 3,
    last_completion: u8 = 0,
};

pub const AudioStatus = struct {
    interfaces: u8,
    playback_endpoints: u8,
    interface_number: u8,
    endpoint_address: u8,
    endpoint_packet: u16,
    configured: bool,
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
fn get24(source: [*]const u8) u32 {
    return @as(u32, source[0]) | (@as(u32, source[1]) << 8) | (@as(u32, source[2]) << 16);
}

fn fillAudioPeriod(address: u64, length: u16, channels: u8) void {
    if (channels == 0) return;
    const output: [*]u8 = @ptrFromInt(address);
    const frame_size = @as(usize, channels) * 2;
    var offset: usize = 0;
    while (offset + frame_size <= length) : (offset += frame_size) {
        const phase = @as(i16, @intCast((offset / frame_size) & 63));
        const value: i16 = if (phase < 32) 12000 else -12000;
        var channel: usize = 0;
        while (channel < channels) : (channel += 1) {
            const sample = offset + channel * 2;
            output[sample] = @truncate(@as(u16, @bitCast(value)));
            output[sample + 1] = @truncate(@as(u16, @bitCast(value)) >> 8);
        }
    }
}
