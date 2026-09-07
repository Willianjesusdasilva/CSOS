const std = @import("std");

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
    suspended_streaming: bool = false,

    pub fn ready(self: *const Device) bool {
        return self.state == .streaming;
    }

    pub fn frameBytes(self: *const Device) ?usize {
        return pcmFrameBytes(self.format.channels, self.format.bits_per_sample) catch null;
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
        if (self.state == .absent or self.state == .discovered or self.suspended) return;
        self.suspended_streaming = self.state == .streaming;
        self.suspended = true;
        if (self.state == .streaming) self.state = .configured;
    }

    pub fn resumeDevice(self: *Device) !void {
        if (!self.suspended) return error.DeviceNotSuspended;
        if (self.state != .configured) return error.DeviceNotConfigured;
        self.suspended = false;
        if (self.suspended_streaming) self.state = .streaming;
        self.suspended_streaming = false;
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
            self.period_index = 0;
            self.metrics = .{};
            return;
        }
        self.device = .{
            .state = .discovered,
            .format = format,
        };
        self.period_index = 0;
        self.metrics = .{};
    }

    pub fn configure(self: *Subsystem) !void {
        if (self.device.state != .discovered) return error.DeviceNotDiscovered;
        if (self.periods == 0) return error.InvalidPeriodCount;
        if (!isSupportedRate(self.device.format.sample_rate)) return error.UnsupportedFormat;
        if (self.device.frameBytes() == null) return error.UnsupportedFormat;
        self.device.state = .configured;
    }

    pub fn start(self: *Subsystem) !void {
        if (self.device.state != .configured) return error.DeviceNotConfigured;
        if (self.periods == 0) return error.InvalidPeriodCount;
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

test "audio subsystem rejects an empty period ring" {
    var subsystem = Subsystem{};
    subsystem.discover(1, 1, .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 });
    subsystem.periods = 0;
    try std.testing.expectError(error.InvalidPeriodCount, subsystem.configure());
}

test "audio subsystem rejects unsupported sample rates" {
    var subsystem = Subsystem{};
    subsystem.discover(1, 1, .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 12_345 });
    try std.testing.expectError(error.UnsupportedFormat, subsystem.configure());
}

test "audio rediscovery resets stream metrics" {
    var subsystem = Subsystem{};
    subsystem.discover(1, 1, .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 });
    try subsystem.configure();
    try subsystem.start();
    try subsystem.submit();
    try subsystem.completePeriod();
    try std.testing.expect(subsystem.metrics.submitted != 0);
    subsystem.discover(1, 1, .{ .channels = 1, .bits_per_sample = 16, .sample_rate = 44_100 });
    try std.testing.expectEqual(@as(u64, 0), subsystem.metrics.submitted);
    try std.testing.expectEqual(@as(u64, 0), subsystem.metrics.completed);
    try std.testing.expectEqual(@as(u8, 0), subsystem.period_index);
}

test "audio suspension only applies after configuration" {
    var device = Device{ .state = .discovered, .format = .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 } };
    device.suspendDevice();
    try std.testing.expect(!device.suspended);
    device.state = .configured;
    device.suspendDevice();
    try std.testing.expect(device.suspended);
    try device.resumeDevice();
    try std.testing.expect(!device.suspended);
}

test "audio manager resets metrics when attaching a new device" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 }, 1000, 4096);
    try manager.configure();
    try manager.start();
    try manager.noteSubmit();
    try std.testing.expect(manager.metrics.submitted != 0);
    try manager.attach(.{ .channels = 1, .bits_per_sample = 16, .sample_rate = 44_100 }, 1000, 4096);
    try std.testing.expectEqual(@as(u64, 0), manager.metrics.submitted);
    try std.testing.expectEqual(@as(u64, 0), manager.metrics.completed);
}

test "audio manager detaches and can be attached again" {
    var manager = DeviceManager{};
    const format = Format{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 };
    try manager.attach(format, 1000, 4096);
    try manager.configure();
    try manager.start();
    try manager.noteSubmit();
    manager.detach();
    try std.testing.expect(manager.stream == null);
    try std.testing.expectEqual(State.absent, manager.device.state);
    try std.testing.expectEqual(@as(u64, 0), manager.metrics.submitted);
    try std.testing.expectError(error.DeviceNotAttached, manager.configure());
    try manager.attach(format, 1000, 4096);
    try std.testing.expect(manager.stream != null);
}

test "audio attach failure preserves the previous device" {
    var manager = DeviceManager{};
    const original = Format{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 };
    try manager.attach(original, 1000, 4096);
    try std.testing.expectError(error.EndpointCapacity, manager.attach(.{ .channels = 8, .bits_per_sample = 32, .sample_rate = 192_000 }, 1, 1));
    try std.testing.expectEqual(original.sample_rate, manager.device.format.sample_rate);
    try std.testing.expect(manager.stream != null);
}

pub const Stream = struct {
    device: Device = .{},
    buffers: [8][4096]u8 = undefined,
    queued: u8 = 0,
    completed: u64 = 0,
    phase: u16 = 0,

    pub fn init(format: Format) !Stream {
        if (!isSupportedRate(format.sample_rate)) return error.UnsupportedFormat;
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

    pub fn pause(self: *Stream) !void {
        if (self.device.state != .streaming) return error.InvalidState;
        self.device.state = .configured;
    }

    pub fn complete(self: *Stream) !void {
        if (!self.device.ready()) return error.InvalidState;
        if (self.queued == 0) {
            self.device.underruns +%= 1;
            return error.Underrun;
        }
        self.queued -= 1;
        self.queued += 1;
        self.completed +%= 1;
    }
};

test "audio stream init rejects unsupported sample rates" {
    try std.testing.expectError(error.UnsupportedFormat, Stream.init(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 123 }));
}

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
        self.submitted +%= 1;
    }

    pub fn recordComplete(self: *Metrics) void {
        self.completed +%= 1;
    }

    pub fn recordUnderrun(self: *Metrics) void {
        self.underruns +%= 1;
    }

    pub fn recordOverrun(self: *Metrics) void {
        self.overruns +%= 1;
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
        self.write_index = @intCast((@as(usize, self.write_index) + 1) % self.buffers.len);
        self.ready += 1;
    }

    pub fn dequeue(self: *PcmRing) ?u64 {
        if (self.ready == 0) return null;
        const buffer = self.buffers[self.read_index];
        self.buffers[self.read_index] = null;
        self.read_index = @intCast((@as(usize, self.read_index) + 1) % self.buffers.len);
        self.ready -= 1;
        return buffer;
    }

    pub fn clear(self: *PcmRing) void {
        self.buffers = .{null} ** self.buffers.len;
        self.ready = 0;
        self.read_index = 0;
        self.write_index = 0;
    }
};

test "PCM ring clear drops queued buffers and rewinds indices" {
    var ring = PcmRing{};
    try ring.enqueue(0x11);
    try ring.enqueue(0x22);
    try std.testing.expectEqual(@as(u8, 2), ring.ready);
    ring.clear();
    try std.testing.expectEqual(@as(u8, 0), ring.ready);
    try std.testing.expect(ring.dequeue() == null);
    try ring.enqueue(0x33);
    try std.testing.expectEqual(@as(?u64, 0x33), ring.dequeue());
}

test "PCM ring reports full capacity before rejecting enqueue" {
    var ring = PcmRing{};
    for (0..8) |index| try ring.enqueue(@intCast(index));
    try std.testing.expectError(error.QueueFull, ring.enqueue(8));
    ring.clear();
    try ring.enqueue(9);
    try std.testing.expectEqual(@as(?u64, 9), ring.dequeue());
}

test "PCM ring preserves FIFO order across index wrap" {
    var ring = PcmRing{};
    for (0..8) |index| try ring.enqueue(@intCast(index));
    for (0..8) |index| try std.testing.expectEqual(@as(?u64, @intCast(index)), ring.dequeue());
    for (8..16) |index| try ring.enqueue(@intCast(index));
    for (8..16) |index| try std.testing.expectEqual(@as(?u64, @intCast(index)), ring.dequeue());
}

pub const DeviceManager = struct {
    device: Device = .{},
    stream: ?Stream = null,
    mixer: Mixer = .{},
    metrics: Metrics = .{},

    pub fn attach(self: *DeviceManager, format: Format, periods_per_second: u32, packet_size: u16) !void {
        var device = Device{ .state = .discovered, .format = format };
        try device.validate(periods_per_second, packet_size);
        const stream = try Stream.init(format);
        self.device = device;
        self.stream = stream;
        self.metrics = .{};
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
        self.stream.?.pause() catch return error.StreamPauseFailed;
        self.device.state = .configured;
    }

    pub fn resumeStream(self: *DeviceManager) !void {
        if (self.stream == null or self.device.state != .configured) return error.DeviceNotConfigured;
        // Re-arm the transport as well as the manager state. Merely marking the
        // manager streaming leaves the paused stream configured with no queued
        // periods, causing the first completion to underrun immediately.
        self.stream.?.start() catch return error.StreamStartFailed;
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
        const stream = try Stream.init(self.device.format);
        self.stream = stream;
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

    pub fn resetStream(self: *DeviceManager) !void {
        const stream = try Stream.init(self.device.format);
        self.stream = stream;
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
        if (self.device.state == .streaming) self.device.state = .configured;
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
    if (bits_per_sample == 0 or bits_per_sample > 32 or bits_per_sample % 8 != 0) return error.InvalidSampleWidth;
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

test "audio format selection prefers requested supported rate" {
    const formats = [_]Format{
        .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 44_100 },
        .{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 },
    };
    try std.testing.expectEqual(@as(u32, 48_000), chooseFormat(&formats, 48_000).?.sample_rate);
    try std.testing.expectEqual(@as(u32, 44_100), chooseFormat(&formats, 96_000).?.sample_rate);
    try std.testing.expect(chooseFormat(&[_]Format{.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 123 }}, 48_000) == null);
}

test "audio rate selection prefers valid rate and falls back" {
    const rates = [_]u32{ 123, 48_000, 44_100 };
    try std.testing.expectEqual(@as(?u32, 48_000), chooseRate(&rates, 48_000));
    try std.testing.expectEqual(@as(?u32, 48_000), chooseRate(&rates, 96_000));
    try std.testing.expectEqual(@as(?u32, null), chooseRate(&[_]u32{ 123, 456 }, 48_000));
}

test "audio format normalization rejects invalid parameters" {
    try std.testing.expectError(error.InvalidChannels, normalizeFormat(0, 16, 48_000));
    try std.testing.expectError(error.InvalidChannels, normalizeFormat(9, 16, 48_000));
    try std.testing.expectError(error.InvalidSampleWidth, normalizeFormat(2, 12, 48_000));
    try std.testing.expectError(error.UnsupportedFormat, normalizeFormat(2, 16, 123));
    const normalized = try normalizeFormat(2, 16, 48_000);
    try std.testing.expectEqual(@as(u8, 2), normalized.channels);
    try std.testing.expectEqual(@as(u8, 16), normalized.bits_per_sample);
}

test "audio PCM buffer validation enforces frame alignment" {
    try validatePcmBuffer(8, 2, 16);
    try std.testing.expectError(error.MisalignedPcmBuffer, validatePcmBuffer(7, 2, 16));
    try std.testing.expectError(error.MisalignedPcmBuffer, validatePcmBuffer(0, 2, 16));
    try std.testing.expectError(error.InvalidChannels, validatePcmBuffer(8, 0, 16));
}

test "audio PCM frame sizing enforces channel and width limits" {
    try std.testing.expectEqual(@as(usize, 4), try pcmFrameBytes(2, 16));
    try std.testing.expectEqual(@as(usize, 32), try pcmFrameBytes(8, 32));
    try std.testing.expectError(error.InvalidChannels, pcmFrameBytes(0, 16));
    try std.testing.expectError(error.InvalidSampleWidth, pcmFrameBytes(2, 12));
    try std.testing.expectError(error.InvalidSampleWidth, pcmFrameBytes(8, 64));
}

test "audio device rejects frame formats outside the PCM contract" {
    const invalid_channels = Device{ .format = .{ .channels = 9, .bits_per_sample = 16, .sample_rate = 48_000 } };
    const invalid_width = Device{ .format = .{ .channels = 2, .bits_per_sample = 64, .sample_rate = 48_000 } };
    try std.testing.expectEqual(@as(?usize, null), invalid_channels.frameBytes());
    try std.testing.expectEqual(@as(?usize, null), invalid_width.frameBytes());
}

pub fn normalizeFormat(channels: u16, bits_per_sample: u16, sample_rate: u64) !Format {
    if (channels == 0 or channels > 8) return error.InvalidChannels;
    if (bits_per_sample == 0 or bits_per_sample > 32 or bits_per_sample % 8 != 0) return error.InvalidSampleWidth;
    if (sample_rate > @import("std").math.maxInt(u32)) return error.UnsupportedFormat;
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

test "device manager pauses and resumes stream" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48000 }, 1000, 4096);
    try manager.configure();
    try manager.start();
    try manager.pause();
    try @import("std").testing.expectError(error.DeviceNotStreaming, manager.pause());
    try @import("std").testing.expectEqual(State.configured, manager.device.state);
    try @import("std").testing.expectEqual(State.configured, manager.stream.?.device.state);
    try manager.resumeStream();
    try @import("std").testing.expectError(error.DeviceNotConfigured, manager.resumeStream());
    try @import("std").testing.expectEqual(State.streaming, manager.device.state);
    try @import("std").testing.expectEqual(State.streaming, manager.stream.?.device.state);
}

test "device manager stop preserves absent state" {
    var manager = DeviceManager{};
    manager.stop();
    try @import("std").testing.expectEqual(State.absent, manager.device.state);
    try @import("std").testing.expect(manager.stream == null);
}

test "device manager reset clears stream mixer and metrics" {
    var manager = DeviceManager{};
    const format = Format{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 };
    try manager.attach(format, 1000, 4096);
    try manager.configure();
    try manager.start();
    try manager.noteSubmit();
    manager.setVolume(12);
    manager.setMuted(true);
    manager.reset();
    try std.testing.expect(manager.stream == null);
    try std.testing.expectEqual(State.absent, manager.device.state);
    try std.testing.expectEqual(@as(u8, 100), manager.mixer.volume);
    try std.testing.expect(!manager.mixer.muted);
    try std.testing.expectEqual(@as(u64, 0), manager.metrics.submitted);
}

test "device manager stop and detach leaves an absent device" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 }, 1000, 4096);
    try manager.configure();
    try manager.start();
    manager.stopAndDetach();
    try std.testing.expect(manager.stream == null);
    try std.testing.expectEqual(State.absent, manager.device.state);
    try std.testing.expectError(error.DeviceNotConfigured, manager.start());
}

test "device manager rebuilds stream during recovery" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 }, 1000, 4096);
    try manager.configure();
    try manager.start();
    try std.testing.expectError(error.QueueEmpty, manager.noteComplete());
    try std.testing.expect(manager.needsRecovery());
    try manager.restart();
    try std.testing.expect(manager.device.state == .streaming);
    try std.testing.expect(manager.stream != null);
    try std.testing.expectEqual(@as(u64, 0), manager.metrics.underruns);
}

test "device manager resetStream rebuilds a configurable stream" {
    var manager = DeviceManager{};
    const format = Format{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 };
    try manager.attach(format, 1000, 4096);
    try manager.configure();
    try manager.start();
    try manager.resetStream();
    try std.testing.expect(manager.stream != null);
    try std.testing.expectEqual(State.discovered, manager.device.state);
    try manager.configure();
    try manager.start();
    try std.testing.expectEqual(State.streaming, manager.device.state);
}

test "device manager resetStream preserves stream on invalid format" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 }, 1000, 4096);
    try manager.configure();
    manager.device.format.sample_rate = 123;
    try std.testing.expectError(error.UnsupportedFormat, manager.resetStream());
    try std.testing.expect(manager.stream != null);
    try std.testing.expectEqual(State.configured, manager.device.state);
}

test "device manager reports whether recovery was needed" {
    var manager = DeviceManager{};
    try manager.attach(.{ .channels = 2, .bits_per_sample = 16, .sample_rate = 48_000 }, 1000, 4096);
    try manager.configure();
    try manager.start();
    try std.testing.expect(!(try manager.recoverIfNeeded()));
    try std.testing.expectError(error.QueueEmpty, manager.noteComplete());
    try std.testing.expect(try manager.recoverIfNeeded());
    try std.testing.expect(manager.device.state == .streaming);
}

test "device resume preserves non-streaming state" {
    var device = Device{ .state = .configured };
    device.suspendDevice();
    try device.resumeDevice();
    try @import("std").testing.expectEqual(State.configured, device.state);
    try @import("std").testing.expect(!device.suspended);
}

test "device resume requires suspension" {
    var device = Device{ .state = .configured };
    try @import("std").testing.expectError(error.DeviceNotSuspended, device.resumeDevice());
}

test "absent device cannot enter suspended state" {
    var device = Device{};
    device.suspendDevice();
    try @import("std").testing.expect(!device.suspended);
    try @import("std").testing.expectError(error.DeviceNotSuspended, device.resumeDevice());
}

test "power manager follows idle suspend and wake cycle" {
    var power = PowerManager{};
    try @import("std").testing.expectEqual(PowerState.active, power.state);
    power.idle();
    try @import("std").testing.expectEqual(PowerState.idle, power.state);
    power.suspendDevice();
    try @import("std").testing.expectEqual(PowerState.suspended, power.state);
    power.resumeDevice();
    try @import("std").testing.expectEqual(PowerState.active, power.state);
    power.wake();
    try @import("std").testing.expectEqual(PowerState.active, power.state);
}
