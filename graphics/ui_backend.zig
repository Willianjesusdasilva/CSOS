const std = @import("std");

pub const Surface = struct {
    id: u32,
    width: u16,
    height: u16,
    stride: u32,
    pixels: []u32,
    generation: u64 = 0,
};

pub const Damage = struct { x: u16, y: u16, width: u16, height: u16 };

pub const Event = union(enum) {
    pointer: struct { x: i32, y: i32, buttons: u8 },
    wheel: struct { delta: i32 },
    key: struct { code: u32, pressed: bool, modifiers: u8 },
    focus: bool,
    timer: u32,
    close,
};

pub const Request = union(enum) {
    hello: struct { version: u16, capabilities: u64 },
    present: struct { surface_id: u32, generation: u64, damage: Damage },
    create_window: struct { width: u16, height: u16, title: []const u8 },
    destroy_window: u32,
    open_file: []const u8,
    connect: struct { address: []const u8, port: u16 },
    audio: struct { sample_rate: u32, channels: u8 },
    set_timer: struct { timer_id: u32, ticks: u64 },
    close,
};

pub const protocol_version: u16 = 1;
pub const Capability = struct {
    pub const surface: u64 = 1 << 0;
    pub const damage: u64 = 1 << 1;
    pub const input: u64 = 1 << 2;
    pub const clipboard: u64 = 1 << 3;
    pub const timers: u64 = 1 << 4;
    pub const ipc: u64 = 1 << 5;
    pub const windows: u64 = 1 << 6;
    pub const audio: u64 = 1 << 7;
};
pub const supported_capabilities = Capability.surface | Capability.damage | Capability.input | Capability.clipboard | Capability.timers | Capability.ipc | Capability.windows | Capability.audio;

pub const WireError = error{BufferTooSmall, InvalidMessage, UnsupportedRequest};

/// Little-endian, pointer-free wire envelope for a userspace IPC transport.
/// The transport can later be a socket, channel or shared ring without
/// exposing kernel or renderer data structures.
pub fn encodeRequest(request: Request, output: []u8) WireError!usize {
    if (output.len < 2) return error.BufferTooSmall;
    var length: usize = 2;
    output[0] = switch (request) { .hello => 9, .present => 1, .create_window => 2, .destroy_window => 3, .open_file => 4, .connect => 5, .audio => 6, .set_timer => 7, .close => 8 };
    switch (request) {
        .hello => |value| { if (output.len < 12) return error.BufferTooSmall; writeU16(output[2..], value.version); writeU64(output[4..], value.capabilities); length = 12; },
        .present => |value| {
            if (output.len < 2 + 4 + 8 + 8) return error.BufferTooSmall;
            writeU32(output[2..], value.surface_id);
            writeU64(output[6..], value.generation);
            writeU16(output[14..], value.damage.x); writeU16(output[16..], value.damage.y);
            writeU16(output[18..], value.damage.width); writeU16(output[20..], value.damage.height); length = 22;
        },
        .create_window => |value| {
            if (value.title.len > 255 or output.len < 7 + value.title.len) return error.BufferTooSmall;
            writeU16(output[2..], value.width); writeU16(output[4..], value.height); output[6] = @intCast(value.title.len);
            @memcpy(output[7 .. 7 + value.title.len], value.title); length = 7 + value.title.len;
        },
        .destroy_window => |id| { if (output.len < 6) return error.BufferTooSmall; writeU32(output[2..], id); length = 6; },
        .open_file => |path| { if (path.len > 255 or output.len < 3 + path.len) return error.BufferTooSmall; output[2] = @intCast(path.len); @memcpy(output[3 .. 3 + path.len], path); length = 3 + path.len; },
        .connect => |value| { if (value.address.len > 255 or output.len < 6 + value.address.len) return error.BufferTooSmall; writeU16(output[2..], value.port); output[4] = @intCast(value.address.len); @memcpy(output[5 .. 5 + value.address.len], value.address); length = 5 + value.address.len; },
        .audio => |value| { if (output.len < 7) return error.BufferTooSmall; writeU32(output[2..], value.sample_rate); output[6] = value.channels; length = 7; },
        .set_timer => |value| { if (output.len < 14) return error.BufferTooSmall; writeU32(output[2..], value.timer_id); writeU64(output[6..], value.ticks); length = 14; },
        .close => {},
    }
    writeU8(output[1..], @intCast(length));
    return length;
}

pub fn decodeRequest(input: []const u8) WireError!Request {
    if (input.len < 2 or input[1] != input.len) return error.InvalidMessage;
    return switch (input[0]) {
        1 => if (input.len == 22) .{ .present = .{ .surface_id = readU32(input[2..]), .generation = readU64(input[6..]), .damage = .{ .x = readU16(input[14..]), .y = readU16(input[16..]), .width = readU16(input[18..]), .height = readU16(input[20..]) } } } else error.InvalidMessage,
        2 => if (input.len >= 7 and input[6] == input.len - 7) .{ .create_window = .{ .width = readU16(input[2..]), .height = readU16(input[4..]), .title = input[7..] } } else error.InvalidMessage,
        3 => if (input.len == 6) .{ .destroy_window = readU32(input[2..]) } else error.InvalidMessage,
        4 => if (input.len >= 3 and input[2] == input.len - 3) .{ .open_file = input[3..] } else error.InvalidMessage,
        5 => if (input.len >= 5 and input[4] == input.len - 5) .{ .connect = .{ .port = readU16(input[2..]), .address = input[5..] } } else error.InvalidMessage,
        6 => if (input.len == 7) .{ .audio = .{ .sample_rate = readU32(input[2..]), .channels = input[6] } } else error.InvalidMessage,
        7 => if (input.len == 14) .{ .set_timer = .{ .timer_id = readU32(input[2..]), .ticks = readU64(input[6..]) } } else error.InvalidMessage,
        8 => if (input.len == 2) .{ .close = {} } else error.InvalidMessage,
        9 => if (input.len == 12) .{ .hello = .{ .version = readU16(input[2..]), .capabilities = readU64(input[4..]) } } else error.InvalidMessage,
        else => error.UnsupportedRequest,
    };
}

pub fn encodeEvent(event: Event, output: []u8) WireError!usize {
    if (output.len < 2) return error.BufferTooSmall;
    output[0] = switch (event) { .pointer => 1, .wheel => 2, .key => 3, .focus => 4, .timer => 5, .close => 6 };
    switch (event) {
        .pointer => |v| { if (output.len < 11) return error.BufferTooSmall; writeU32(output[2..], @bitCast(v.x)); writeU32(output[6..], @bitCast(v.y)); output[10] = v.buttons; output[1] = 11; return 11; },
        .wheel => |v| { if (output.len < 6) return error.BufferTooSmall; writeU32(output[2..], @bitCast(v.delta)); output[1] = 6; return 6; },
        .key => |v| { if (output.len < 8) return error.BufferTooSmall; writeU32(output[2..], v.code); output[6] = @intFromBool(v.pressed); output[7] = v.modifiers; output[1] = 8; return 8; },
        .focus => |v| { output[2] = @intFromBool(v); output[1] = 3; return 3; },
        .timer => |v| { if (output.len < 6) return error.BufferTooSmall; writeU32(output[2..], v); output[1] = 6; return 6; },
        .close => { output[1] = 2; return 2; },
    }
}

pub fn decodeEvent(input: []const u8) WireError!Event {
    if (input.len < 2 or input[1] != input.len) return error.InvalidMessage;
    return switch (input[0]) {
        1 => if (input.len == 11) .{ .pointer = .{ .x = @bitCast(readU32(input[2..])), .y = @bitCast(readU32(input[6..])), .buttons = input[10] } } else error.InvalidMessage,
        2 => if (input.len == 6) .{ .wheel = .{ .delta = @bitCast(readU32(input[2..])) } } else error.InvalidMessage,
        3 => if (input.len == 8 and input[6] <= 1) .{ .key = .{ .code = readU32(input[2..]), .pressed = input[6] != 0, .modifiers = input[7] } } else error.InvalidMessage,
        4 => if (input.len == 3 and input[2] <= 1) .{ .focus = input[2] != 0 } else error.InvalidMessage,
        5 => if (input.len == 6) .{ .timer = readU32(input[2..]) } else error.InvalidMessage,
        6 => if (input.len == 2) .{ .close = {} } else error.InvalidMessage,
        else => error.UnsupportedRequest,
    };
}

fn writeU8(output: []u8, value: u8) void { output[0] = value; }
fn writeU16(output: []u8, value: u16) void { std.mem.writeInt(u16, output[0..2], value, .little); }
fn writeU32(output: []u8, value: u32) void { std.mem.writeInt(u32, output[0..4], value, .little); }
fn writeU64(output: []u8, value: u64) void { std.mem.writeInt(u64, output[0..8], value, .little); }
fn readU16(input: []const u8) u16 { return std.mem.readInt(u16, input[0..2], .little); }
fn readU32(input: []const u8) u32 { return std.mem.readInt(u32, input[0..4], .little); }
fn readU64(input: []const u8) u64 { return std.mem.readInt(u64, input[0..8], .little); }

pub const Backend = struct {
    surface: Surface,
    events: [64]Event = undefined,
    event_read: usize = 0,
    event_write: usize = 0,
    requests: [64]Request = undefined,
    request_read: usize = 0,
    request_write: usize = 0,
    running: bool = false,
    focused: bool = false,
    clipboard: [1024]u8 = undefined,
    clipboard_len: usize = 0,
    surface_alive: bool = true,
    negotiated_version: u16 = 0,
    negotiated_capabilities: u64 = 0,

    pub fn init(surface: Surface) Backend { return .{ .surface = surface }; }

    pub fn start(self: *Backend) bool {
        if (self.running) return false;
        self.running = true;
        return true;
    }

    pub fn negotiate(self: *Backend, version: u16, capabilities: u64) bool {
        if (version != protocol_version) return false;
        self.negotiated_version = protocol_version;
        self.negotiated_capabilities = capabilities & supported_capabilities;
        return self.enqueueRequest(.{ .hello = .{ .version = protocol_version, .capabilities = self.negotiated_capabilities } });
    }

    pub fn stop(self: *Backend) bool {
        if (!self.running) return false;
        self.running = false;
        return self.enqueueRequest(.close);
    }

    pub fn destroySurface(self: *Backend) bool {
        if (!self.surface_alive) return false;
        self.surface_alive = false;
        return self.enqueueRequest(.{ .destroy_window = self.surface.id });
    }

    pub fn createWindow(self: *Backend, width: u16, height: u16, title: []const u8) bool {
        if (width == 0 or height == 0 or title.len > 128) return false;
        return self.enqueueRequest(.{ .create_window = .{ .width = width, .height = height, .title = title } });
    }

    pub fn setTimer(self: *Backend, timer_id: u32, ticks: u64) bool {
        if (timer_id == 0 or ticks == 0) return false;
        return self.enqueueRequest(.{ .set_timer = .{ .timer_id = timer_id, .ticks = ticks } });
    }

    pub fn setClipboard(self: *Backend, text: []const u8) bool {
        if (text.len > self.clipboard.len) return false;
        @memcpy(self.clipboard[0..text.len], text);
        self.clipboard_len = text.len;
        return true;
    }

    pub fn getClipboard(self: *const Backend) []const u8 {
        return self.clipboard[0..self.clipboard_len];
    }

    pub fn resize(self: *Backend, width: u16, height: u16, pixels: []u32) bool {
        if (!self.surface_alive or width == 0 or height == 0 or pixels.len < @as(usize, width) * height) return false;
        self.surface.width = width;
        self.surface.height = height;
        self.surface.stride = width;
        self.surface.pixels = pixels;
        self.surface.generation +|= 1;
        return self.enqueueEvent(.{ .focus = self.focused });
    }

    pub fn enqueueEvent(self: *Backend, event: Event) bool {
        if (self.event_write - self.event_read >= self.events.len) return false;
        self.events[self.event_write % self.events.len] = event;
        self.event_write += 1;
        return true;
    }

    pub fn nextEvent(self: *Backend) ?Event {
        if (self.event_read == self.event_write) return null;
        const event = self.events[self.event_read % self.events.len];
        self.event_read += 1;
        return event;
    }

    pub fn enqueueRequest(self: *Backend, request: Request) bool {
        if (self.request_write - self.request_read >= self.requests.len) return false;
        self.requests[self.request_write % self.requests.len] = request;
        self.request_write += 1;
        return true;
    }

    pub fn nextRequest(self: *Backend) ?Request {
        if (self.request_read == self.request_write) return null;
        const request = self.requests[self.request_read % self.requests.len];
        self.request_read += 1;
        return request;
    }

    pub fn submitRequestWire(self: *Backend, message: []const u8) WireError!bool {
        return self.enqueueRequest(try decodeRequest(message));
    }

    pub fn nextRequestWire(self: *Backend, output: []u8) WireError!?usize {
        const request = self.nextRequest() orelse return null;
        return try encodeRequest(request, output);
    }

    pub fn dispatchRequests(self: *Backend, handler: *const fn (Request) void) usize {
        var dispatched: usize = 0;
        while (self.nextRequest()) |request| {
            handler(request);
            dispatched += 1;
        }
        return dispatched;
    }

    pub fn submitEventWire(self: *Backend, message: []const u8) WireError!bool {
        return self.enqueueEvent(try decodeEvent(message));
    }

    pub fn nextEventWire(self: *Backend, output: []u8) WireError!?usize {
        const event = self.nextEvent() orelse return null;
        return try encodeEvent(event, output);
    }

    pub fn present(self: *Backend, damage: Damage) bool {
        if (!self.surface_alive) return false;
        const clipped = self.clipDamage(damage) orelse return false;
        return self.enqueueRequest(.{ .present = .{ .surface_id = self.surface.id, .generation = self.surface.generation, .damage = clipped } });
    }

    fn clipDamage(self: *const Backend, damage: Damage) ?Damage {
        if (damage.x >= self.surface.width or damage.y >= self.surface.height) return null;
        const right = @min(@as(u32, self.surface.width), @as(u32, damage.x) + damage.width);
        const bottom = @min(@as(u32, self.surface.height), @as(u32, damage.y) + damage.height);
        if (right <= damage.x or bottom <= damage.y) return null;
        return .{ .x = damage.x, .y = damage.y, .width = @intCast(right - damage.x), .height = @intCast(bottom - damage.y) };
    }

    pub fn setFocus(self: *Backend, focused: bool) bool {
        self.focused = focused;
        return self.enqueueEvent(.{ .focus = focused });
    }
};

test "generic UI backend lifecycle, surface, damage and IPC requests" {
    var pixels = [_]u32{0} ** 64;
    var backend = Backend.init(.{ .id = 4, .width = 8, .height = 8, .stride = 8, .pixels = &pixels });
    try std.testing.expect(backend.start());
    try std.testing.expect(backend.createWindow(320, 200, "FILES"));
    try std.testing.expect(backend.setTimer(1, 60));
    try std.testing.expect(backend.setClipboard("CSOS"));
    try std.testing.expectEqualStrings("CSOS", backend.getClipboard());
    try std.testing.expect(backend.enqueueEvent(.{ .pointer = .{ .x = 2, .y = 3, .buttons = 1 } }));
    try std.testing.expect(backend.present(.{ .x = 0, .y = 0, .width = 8, .height = 8 }));
    try std.testing.expect(backend.enqueueRequest(.{ .open_file = "/system/config/hardware.csc" }));
    try std.testing.expect(backend.resize(4, 4, pixels[0..16]));
    try std.testing.expect(backend.stop());
    try std.testing.expect(backend.destroySurface());
    try std.testing.expect(!backend.running);
    try std.testing.expect(backend.nextEvent() != null);
    try std.testing.expect(backend.nextRequest() != null);
}

test "backend request wire encoding is pointer-free" {
    var wire: [64]u8 = undefined;
    const length = try encodeRequest(.{ .present = .{ .surface_id = 9, .generation = 3, .damage = .{ .x = 1, .y = 2, .width = 8, .height = 9 } } }, &wire);
    try std.testing.expectEqual(@as(usize, 22), length);
    try std.testing.expectEqual(@as(u8, 1), wire[0]);
    try std.testing.expectEqual(@as(u8, 22), wire[1]);
    const title_length = try encodeRequest(.{ .create_window = .{ .width = 100, .height = 80, .title = "FILES" } }, &wire);
    try std.testing.expectEqual(@as(usize, 12), title_length);
    try std.testing.expectEqualStrings("FILES", wire[7..12]);
    switch (try decodeRequest(wire[0..title_length])) {
        .create_window => |window| try std.testing.expectEqualStrings("FILES", window.title),
        else => return error.UnexpectedBackendCommand,
    }
    try std.testing.expectError(error.InvalidMessage, decodeRequest(wire[0..title_length - 1]));
    const hello_length = try encodeRequest(.{ .hello = .{ .version = protocol_version, .capabilities = supported_capabilities } }, &wire);
    switch (try decodeRequest(wire[0..hello_length])) {
        .hello => |hello| try std.testing.expectEqual(protocol_version, hello.version),
        else => return error.UnexpectedBackendCommand,
    }
}

test "backend event wire encoding round-trips input" {
    var wire: [16]u8 = undefined;
    const length = try encodeEvent(.{ .pointer = .{ .x = -4, .y = 9, .buttons = 1 } }, &wire);
    switch (try decodeEvent(wire[0..length])) {
        .pointer => |pointer| { try std.testing.expectEqual(@as(i32, -4), pointer.x); try std.testing.expectEqual(@as(u8, 1), pointer.buttons); },
        else => return error.UnexpectedBackendEvent,
    }
    try std.testing.expectError(error.InvalidMessage, decodeEvent(wire[0..length - 1]));
    var exact: [11]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 11), try encodeEvent(.{ .pointer = .{ .x = 1, .y = 2, .buttons = 0 } }, &exact));
}

test "backend consumes and emits wire messages through its queues" {
    var pixels = [_]u32{0} ** 16;
    var backend = Backend.init(.{ .id = 2, .width = 4, .height = 4, .stride = 4, .pixels = &pixels });
    var wire: [64]u8 = undefined;
    const request_length = try encodeRequest(.{ .close = {} }, &wire);
    try std.testing.expect(try backend.submitRequestWire(wire[0..request_length]));
    try std.testing.expectEqual(@as(?usize, request_length), try backend.nextRequestWire(&wire));
    const event_length = try encodeEvent(.{ .focus = true }, &wire);
    try std.testing.expect(try backend.submitEventWire(wire[0..event_length]));
    try std.testing.expectEqual(@as(?usize, event_length), try backend.nextEventWire(&wire));
}

test "backend clips damage to the shared surface" {
    var pixels = [_]u32{0} ** 16;
    var backend = Backend.init(.{ .id = 3, .width = 4, .height = 4, .stride = 4, .pixels = &pixels });
    try std.testing.expect(backend.present(.{ .x = 3, .y = 3, .width = 10, .height = 10 }));
    switch (backend.nextRequest().?) {
        .present => |present| { try std.testing.expectEqual(@as(u16, 1), present.damage.width); try std.testing.expectEqual(@as(u16, 1), present.damage.height); },
        else => return error.UnexpectedBackendCommand,
    }
    try std.testing.expect(!backend.present(.{ .x = 4, .y = 0, .width = 1, .height = 1 }));
}

var dispatched_requests: usize = 0;
fn countDispatchedRequest(_: Request) void { dispatched_requests += 1; }

test "backend dispatches requests without knowing the window manager" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 8, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    _ = backend.createWindow(10, 10, "APP");
    _ = backend.present(.{ .x = 0, .y = 0, .width = 2, .height = 2 });
    dispatched_requests = 0;
    try std.testing.expectEqual(@as(usize, 2), backend.dispatchRequests(&countDispatchedRequest));
    try std.testing.expectEqual(@as(usize, 2), dispatched_requests);
}

test "destroyed surface rejects later resize and present" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 9, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    try std.testing.expect(backend.destroySurface());
    try std.testing.expect(!backend.resize(2, 2, &pixels));
    try std.testing.expect(!backend.present(.{ .x = 0, .y = 0, .width = 1, .height = 1 }));
}
