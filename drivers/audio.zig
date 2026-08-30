pub const Format = struct {
    channels: u8 = 0,
    bits_per_sample: u8 = 0,
    sample_rate: u32 = 0,
};

pub const State = enum {
    absent,
    discovered,
    configured,
    streaming,
};

pub const Device = struct {
    state: State = .absent,
    format: Format = .{},
    interface_number: u8 = 0,
    alternate_setting: u8 = 0,
    endpoint_address: u8 = 0,
    endpoint_packet: u16 = 0,
    underruns: u64 = 0,
    overruns: u64 = 0,
    suspended: bool = false,

    pub fn ready(self: *const Device) bool {
        return self.state == .streaming;
    }

    pub fn frameBytes(self: *const Device) ?usize {
        if (self.format.channels == 0 or self.format.bits_per_sample == 0) return null;
        if (self.format.bits_per_sample % 8 != 0) return null;
        return @as(usize, self.format.channels) * (@as(usize, self.format.bits_per_sample) / 8);
    }

    pub fn periodBytes(self: *const Device, periods_per_second: u32) ?usize {
        const frame_bytes = self.frameBytes() orelse return null;
        if (periods_per_second == 0 or self.format.sample_rate == 0) return null;
        return (@as(usize, self.format.sample_rate) * frame_bytes + periods_per_second - 1) / periods_per_second;
    }

    pub fn validate(self: *const Device, periods_per_second: u32, packet_size: u16) !void {
        const bytes = self.periodBytes(periods_per_second) orelse return error.UnsupportedFormat;
        if (bytes == 0 or bytes > packet_size) return error.EndpointCapacity;
    }

    pub fn suspendDevice(self: *Device) void {
        self.suspended = true;
        if (self.state == .streaming) self.state = .configured;
    }

    pub fn resumeDevice(self: *Device) !void {
        if (self.state != .configured) return error.DeviceNotConfigured;
        self.suspended = false;
        self.state = .streaming;
    }
};

pub const Subsystem = struct {
    device: Device = .{},
    periods: u8 = 8,
    period_index: u8 = 0,
    metrics: Metrics = .{},
    mixer: Mixer = .{},

    pub fn discover(self: *Subsystem, interfaces: u8, playback_endpoints: u8, format: Format) void {
        if (interfaces == 0 or playback_endpoints == 0) {
            self.device = .{};
            return;
        }
        self.device = .{
            .state = .discovered,
            .format = format,
        };
    }

    pub fn configure(self: *Subsystem) !void {
        if (self.device.state != .discovered) return error.DeviceNotDiscovered;
        if (self.device.frameBytes() == null) return error.UnsupportedFormat;
        self.device.state = .configured;
    }

    pub fn start(self: *Subsystem) !void {
        if (self.device.state != .configured) return error.DeviceNotConfigured;
        self.period_index = 0;
        self.device.state = .streaming;
    }

    pub fn submit(self: *Subsystem) !void {
        if (!self.device.ready()) return error.DeviceNotStreaming;
        if (self.device.suspended) return error.DeviceSuspended;
        if (self.metrics.submitted - self.metrics.completed >= self.periods) {
            self.metrics.recordOverrun();
            return error.QueueFull;
        }
        self.metrics.recordSubmit();
    }

    pub fn completePeriod(self: *Subsystem) !void {
        if (!self.device.ready()) return error.DeviceNotStreaming;
        if (self.metrics.completed >= self.metrics.submitted) {
            self.metrics.recordUnderrun();
            return error.QueueEmpty;
        }
        self.period_index = (self.period_index + 1) % self.periods;
        self.metrics.recordComplete();
    }
};

pub const Stream = struct {
    device: Device = .{},
    buffers: [8][4096]u8 = undefined,
    queued: u8 = 0,
    completed: u64 = 0,
    phase: u16 = 0,

    pub fn init(format: Format) !Stream {
        var stream = Stream{ .device = .{ .state = .discovered, .format = format } };
        try stream.device.validate(1000, 4096);
        return stream;
    }

    pub fn configure(self: *Stream) !void {
        if (self.device.state != .discovered) return error.InvalidState;
        self.device.state = .configured;
    }

    pub fn start(self: *Stream) !void {
        if (self.device.state != .configured) return error.InvalidState;
        self.queued = 8;
        self.completed = 0;
        self.device.state = .streaming;
    }

    pub fn complete(self: *Stream) !void {
        if (!self.device.ready()) return error.InvalidState;
        if (self.queued == 0) {
            self.device.underruns += 1;
            return error.Underrun;
        }
        self.queued -= 1;
        self.queued += 1;
        self.completed += 1;
    }
};

pub const BufferQueue = struct {
    count: u8 = 0,
    head: u8 = 0,
    tail: u8 = 0,

    pub fn push(self: *BufferQueue) !void {
        if (self.count == 8) return error.QueueFull;
        self.tail = (self.tail + 1) % 8;
        self.count += 1;
    }

    pub fn pop(self: *BufferQueue) !void {
        if (self.count == 0) return error.QueueEmpty;
        self.head = (self.head + 1) % 8;
        self.count -= 1;
    }
};

pub const Metrics = struct {
    submitted: u64 = 0,
    completed: u64 = 0,
    underruns: u64 = 0,
    overruns: u64 = 0,

    pub fn recordSubmit(self: *Metrics) void {
        self.submitted += 1;
    }

    pub fn recordComplete(self: *Metrics) void {
        self.completed += 1;
    }

    pub fn recordUnderrun(self: *Metrics) void {
        self.underruns += 1;
    }

    pub fn recordOverrun(self: *Metrics) void {
        self.overruns += 1;
    }
};

pub const Mixer = struct {
    volume: u8 = 100,
    muted: bool = false,

    pub fn setVolume(self: *Mixer, volume: u8) void {
        self.volume = volume;
    }

    pub fn setMuted(self: *Mixer, muted: bool) void {
        self.muted = muted;
    }

    pub fn applyPcm16(self: *const Mixer, samples: []u8) void {
        if (samples.len % 2 != 0) return;
        var offset: usize = 0;
        while (offset < samples.len) : (offset += 2) {
            var value = @as(i16, @bitCast(@as(u16, samples[offset]) | (@as(u16, samples[offset + 1]) << 8)));
            if (self.muted) {
                value = 0;
            } else {
                value = @intCast((@as(i32, value) * self.volume) / 100);
            }
            const bits = @as(u16, @bitCast(value));
            samples[offset] = @truncate(bits);
            samples[offset + 1] = @truncate(bits >> 8);
        }
    }
};

pub const PcmRing = struct {
    buffers: [8]?u64 = .{null} ** 8,
    ready: u8 = 0,
    read_index: u8 = 0,
    write_index: u8 = 0,

    pub fn enqueue(self: *PcmRing, buffer: u64) !void {
        if (self.ready == self.buffers.len) return error.QueueFull;
        self.buffers[self.write_index] = buffer;
        self.write_index = (self.write_index + 1) % self.buffers.len;
        self.ready += 1;
    }

    pub fn dequeue(self: *PcmRing) ?u64 {
        if (self.ready == 0) return null;
        const buffer = self.buffers[self.read_index];
        self.buffers[self.read_index] = null;
        self.read_index = (self.read_index + 1) % self.buffers.len;
        self.ready -= 1;
        return buffer;
    }
};

pub const DeviceManager = struct {
    device: Device = .{},
    stream: ?Stream = null,
    mixer: Mixer = .{},
    metrics: Metrics = .{},

    pub fn attach(self: *DeviceManager, format: Format, periods_per_second: u32, packet_size: u16) !void {
        var device = Device{ .state = .discovered, .format = format };
        try device.validate(periods_per_second, packet_size);
        self.device = device;
        self.stream = try Stream.init(format);
    }

    pub fn attachPreferred(self: *DeviceManager, formats: []const Format, preferred_rate: u32, periods_per_second: u32, packet_size: u16) !void {
        const format = chooseFormat(formats, preferred_rate) orelse return error.UnsupportedFormat;
        try self.attach(format, periods_per_second, packet_size);
    }

    pub fn configure(self: *DeviceManager) !void {
        if (self.stream == null) return error.DeviceNotAttached;
        self.stream.?.configure() catch return error.StreamConfigurationFailed;
        self.device.state = .configured;
    }

    pub fn snapshot(self: *const DeviceManager) Snapshot {
        return .{
            .state = self.device.state,
            .channels = self.device.format.channels,
            .bits_per_sample = self.device.format.bits_per_sample,
            .sample_rate = self.device.format.sample_rate,
            .submitted = self.metrics.submitted,
            .completed = self.metrics.completed,
            .underruns = self.metrics.underruns,
            .overruns = self.metrics.overruns,
        };
    }

    pub fn start(self: *DeviceManager) !void {
        if (self.stream == null or self.device.state != .configured) return error.DeviceNotConfigured;
        self.stream.?.start() catch return error.StreamStartFailed;
        self.device.state = .streaming;
    }

    pub fn pause(self: *DeviceManager) !void {
        if (self.device.state != .streaming) return error.DeviceNotStreaming;
        self.device.state = .configured;
    }

    pub fn resume(self: *DeviceManager) !void {
        if (self.device.state != .configured) return error.DeviceNotConfigured;
        self.device.state = .streaming;
    }

    pub fn applyMixer(self: *DeviceManager, samples: []u8) !void {
        if (self.device.format.bits_per_sample != 16) return error.UnsupportedFormat;
        try applyPcm16(samples, self.mixer.volume, self.mixer.muted);
    }

    pub fn setVolume(self: *DeviceManager, value: u16) void {
        self.mixer.setVolume(clampVolume(value));
    }

    pub fn setMuted(self: *DeviceManager, value: bool) void {
        self.mixer.setMuted(value);
    }

    pub fn resetMetrics(self: *DeviceManager) void {
        self.metrics = .{};
    }

    pub fn metricsSnapshot(self: *const DeviceManager) Metrics {
        return self.metrics;
    }

    pub fn noteSubmit(self: *DeviceManager) !void {
        if (self.device.state != .streaming) return error.DeviceNotStreaming;
        if (self.metrics.submitted - self.metrics.completed >= 8) {
            self.metrics.recordOverrun();
            return error.QueueFull;
        }
        self.metrics.recordSubmit();
    }

    pub fn noteComplete(self: *DeviceManager) !void {
        if (self.device.state != .streaming) return error.DeviceNotStreaming;
        if (self.metrics.completed >= self.metrics.submitted) {
            self.metrics.recordUnderrun();
            return error.QueueEmpty;
        }
        self.metrics.recordComplete();
    }

    pub fn isHealthy(self: *const DeviceManager) bool {
        return self.device.state != .absent and self.metrics.underruns == 0 and self.metrics.overruns == 0;
    }

    pub fn needsRecovery(self: *const DeviceManager) bool {
        return self.device.state == .streaming and !self.isHealthy();
    }

    pub fn recover(self: *DeviceManager) !void {
        if (!self.needsRecovery()) return;
        self.stream = null;
        self.metrics = .{};
        self.device.state = .configured;
    }

    pub fn restart(self: *DeviceManager) !void {
        try self.recover();
        try self.configure();
        try self.start();
    }

    pub fn stopAndDetach(self: *DeviceManager) void {
        self.stop();
        self.detach();
    }

    pub fn canStart(self: *const DeviceManager) bool {
        return self.stream != null and self.device.state == .configured and
            self.device.frameBytes() != null;
    }

    pub fn queuedPeriods(self: *const DeviceManager) u64 {
        return self.metrics.submitted -| self.metrics.completed;
    }

    pub fn hasFault(self: *const DeviceManager) bool {
        return self.metrics.underruns != 0 or self.metrics.overruns != 0;
    }

    pub fn clearFault(self: *DeviceManager) void {
        self.metrics.underruns = 0;
        self.metrics.overruns = 0;
    }

    pub fn recoverIfNeeded(self: *DeviceManager) !bool {
        if (!self.needsRecovery()) return false;
        try self.restart();
        return true;
    }

    pub fn healthScore(self: *const DeviceManager) u8 {
        if (self.device.state == .absent) return 0;
        if (self.hasFault()) return 50;
        if (self.device.state == .streaming) return 100;
        if (self.device.state == .configured) return 75;
        return 25;
    }

    pub fn shouldRestart(self: *const DeviceManager) bool {
        return self.device.state == .streaming and self.healthScore() < 75;
    }

    pub fn resetStream(self: *DeviceManager) void {
        self.stream = null;
        self.device.state = .discovered;
        self.metrics = .{};
    }

    pub fn shutdown(self: *DeviceManager) void {
        self.stream = null;
        self.device = .{};
        self.mixer = .{};
        self.metrics = .{};
    }

    pub fn errorRate(self: *const DeviceManager) u8 {
        const total = self.metrics.completed + self.metrics.underruns + self.metrics.overruns;
        if (total == 0) return 0;
        const errors = self.metrics.underruns + self.metrics.overruns;
        return @intCast(@min(@as(u64, 100), (errors * 100) / total));
    }

    pub fn isDegraded(self: *const DeviceManager) bool {
        return self.errorRate() >= 5;
    }

    pub fn updateHealth(self: *DeviceManager) !void {
        if (self.device.state == .absent) return error.DeviceNotAttached;
        if (!self.isDegraded()) return;
        try self.recoverIfNeeded();
    }

    pub fn reset(self: *DeviceManager) void {
        self.shutdown();
        self.device.state = .absent;
    }

    pub fn stop(self: *DeviceManager) void {
        self.stream = null;
        self.device.state = .configured;
    }

    pub fn detach(self: *DeviceManager) void {
        self.stream = null;
        self.device = .{};
        self.metrics = .{};
    }
};

pub const PowerState = enum {
    active,
    idle,
    suspended,
};

pub const PowerManager = struct {
    state: PowerState = .active,

    pub fn idle(self: *PowerManager) void {
        if (self.state == .active) self.state = .idle;
    }

    pub fn wake(self: *PowerManager) void {
        self.state = .active;
    }

    pub fn suspendDevice(self: *PowerManager) void {
        self.state = .suspended;
    }

    pub fn resumeDevice(self: *PowerManager) void {
        self.state = .active;
    }
};

pub fn clampVolume(value: u16) u8 {
    return @intCast(@min(value, 100));
}

pub fn scalePcm16(sample: i16, volume: u8, muted: bool) i16 {
    if (muted or volume == 0) return 0;
    const scaled = (@as(i32, sample) * volume) / 100;
    return @intCast(@max(-32768, @min(scaled, 32767)));
}

pub fn applyPcm16(samples: []u8, volume: u8, muted: bool) !void {
    if (samples.len % 2 != 0) return error.InvalidPcmBuffer;
    const safe_volume = clampVolume(volume);
    var offset: usize = 0;
    while (offset < samples.len) : (offset += 2) {
        const bits = @as(u16, samples[offset]) | (@as(u16, samples[offset + 1]) << 8);
        const scaled = scalePcm16(@bitCast(bits), safe_volume, muted);
        const output = @as(u16, @bitCast(scaled));
        samples[offset] = @truncate(output);
        samples[offset + 1] = @truncate(output >> 8);
    }
}

pub fn pcmFrameBytes(channels: u8, bits_per_sample: u8) !usize {
    if (channels == 0 or channels > 8) return error.InvalidChannels;
    if (bits_per_sample == 0 or bits_per_sample % 8 != 0) return error.InvalidSampleWidth;
    const bytes = @as(usize, channels) * (@as(usize, bits_per_sample) / 8);
    if (bytes > 32) return error.FrameTooLarge;
    return bytes;
}

pub fn validatePcmBuffer(buffer_length: usize, channels: u8, bits_per_sample: u8) !void {
    const frame_bytes = try pcmFrameBytes(channels, bits_per_sample);
    if (buffer_length == 0 or buffer_length % frame_bytes != 0) return error.MisalignedPcmBuffer;
}

pub const FormatError = error{
    InvalidChannels,
    InvalidSampleWidth,
    FrameTooLarge,
    MisalignedPcmBuffer,
    UnsupportedFormat,
};

pub fn isSupportedRate(rate: u32) bool {
    return switch (rate) {
        8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000 => true,
        else => false,
    };
}

pub fn chooseRate(supported: []const u32, preferred: u32) ?u32 {
    for (supported) |rate| if (rate == preferred and isSupportedRate(rate)) return rate;
    for (supported) |rate| if (isSupportedRate(rate)) return rate;
    return null;
}

pub fn chooseFormat(supported: []const Format, preferred_rate: u32) ?Format {
    var fallback: ?Format = null;
    for (supported) |format| {
        if (!isSupportedRate(format.sample_rate)) continue;
        if (format.sample_rate == preferred_rate) return format;
        if (fallback == null) fallback = format;
    }
    return fallback;
}

pub fn normalizeFormat(channels: u16, bits_per_sample: u16, sample_rate: u64) !Format {
    if (channels == 0 or channels > 8) return error.InvalidChannels;
    if (bits_per_sample == 0 or bits_per_sample > 32 or bits_per_sample % 8 != 0) return error.InvalidSampleWidth;
    if (!isSupportedRate(@intCast(sample_rate))) return error.UnsupportedFormat;
    return .{
        .channels = @intCast(channels),
        .bits_per_sample = @intCast(bits_per_sample),
        .sample_rate = @intCast(sample_rate),
    };
}

pub const Control = struct {
    mixer: Mixer = .{},
    active: bool = false,

    pub fn start(self: *Control) void {
        self.active = true;
    }

    pub fn stop(self: *Control) void {
        self.active = false;
    }

    pub fn setVolume(self: *Control, value: u8) void {
        self.mixer.setVolume(value);
    }

    pub fn setMuted(self: *Control, value: bool) void {
        self.mixer.setMuted(value);
    }
};

pub const Event = union(enum) {
    period_complete: u8,
    underrun: void,
    overrun: void,
    device_removed: void,
};

pub const EventQueue = struct {
    events: [16]?Event = .{null} ** 16,
    head: u8 = 0,
    tail: u8 = 0,
    count: u8 = 0,

    pub fn push(self: *EventQueue, event: Event) !void {
        if (self.count == self.events.len) return error.QueueFull;
        self.events[self.tail] = event;
        self.tail = (self.tail + 1) % self.events.len;
        self.count += 1;
    }

    pub fn pop(self: *EventQueue) ?Event {
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.events[self.head] = null;
        self.head = (self.head + 1) % self.events.len;
        self.count -= 1;
        return event;
    }
};

pub const Port = struct {
    connected: bool = false,
    suspended: bool = false,
    generation: u32 = 0,

    pub fn attach(self: *Port) void {
        self.connected = true;
        self.suspended = false;
        self.generation +%= 1;
    }

    pub fn detach(self: *Port) void {
        self.connected = false;
        self.suspended = false;
        self.generation +%= 1;
    }

    pub fn suspendPort(self: *Port) !void {
        if (!self.connected) return error.DeviceAbsent;
        self.suspended = true;
    }

    pub fn resumePort(self: *Port) !void {
        if (!self.connected) return error.DeviceAbsent;
        self.suspended = false;
    }
};

pub const Registry = struct {
    ports: [16]Port = .{Port{}} ** 16,
    count: u8 = 0,

    pub fn attach(self: *Registry, index: u8) !void {
        if (index >= self.ports.len) return error.InvalidPort;
        self.ports[index].attach();
        if (index >= self.count) self.count = index + 1;
    }

    pub fn detach(self: *Registry, index: u8) !void {
        if (index >= self.count) return error.InvalidPort;
        self.ports[index].detach();
    }

    pub fn connected(self: *const Registry, index: u8) bool {
        if (index >= self.count) return false;
        return self.ports[index].connected;
    }
};

pub const Snapshot = struct {
    state: State,
    channels: u8,
    bits_per_sample: u8,
    sample_rate: u32,
    submitted: u64,
    completed: u64,
    underruns: u64,
    overruns: u64,
};


pub fn snapshot(subsystem: *const Subsystem, metrics: Metrics) Snapshot {
    return .{
        .state = subsystem.device.state,
        .channels = subsystem.device.format.channels,
        .bits_per_sample = subsystem.device.format.bits_per_sample,
        .sample_rate = subsystem.device.format.sample_rate,
        .submitted = metrics.submitted,
        .completed = metrics.completed,
        .underruns = metrics.underruns,
        .overruns = metrics.overruns,
    };
}

pub fn pcm16(period: []u8, channels: u8, phase: *u16) !void {
    if (channels == 0 or channels > 8 or period.len % (@as(usize, channels) * 2) != 0) return error.InvalidPcmFormat;
    var offset: usize = 0;
    while (offset < period.len) : (offset += @as(usize, channels) * 2) {
        const value: i16 = if ((phase.* & 32) == 0) 12000 else -12000;
        phase.* +%= 1;
        var channel: usize = 0;
        while (channel < channels) : (channel += 1) {
            const sample = offset + channel * 2;
            const bits = @as(u16, @bitCast(value));
            period[sample] = @truncate(bits);
            period[sample + 1] = @truncate(bits >> 8);
        }
    }
}

pub fn periodRate(interval: u8, high_speed: bool) u32 {
    if (interval == 0) return 1000;
    if (high_speed) return 8000 >> @min(interval - 1, 7);
    return 1000 >> @min(interval - 1, 3);
}
