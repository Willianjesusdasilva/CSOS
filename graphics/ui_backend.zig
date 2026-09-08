const std = @import("std");

pub const Surface = struct {
    id: u32,
    buffer_handle: u32 = 0,
    format: PixelFormat = .rgba8888,
    width: u16,
    height: u16,
    stride: u32,
    pixels: []u32,
    generation: u64 = 0,
};

pub const PixelFormat = enum(u8) { rgba8888 = 1, bgra8888 = 2, argb8888 = 3 };
pub const SurfaceInfo = struct { id: u32, buffer_handle: u32, width: u16, height: u16, stride: u32, format: PixelFormat, generation: u64 };
pub const Response = union(enum) { hello_ack: struct { version: u16, capabilities: u64 }, surface_created: SurfaceInfo, surface_destroyed: u32, failure: u16 };

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
    clipboard_set: []const u8,
    resize: struct { width: u16, height: u16 },
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

pub fn encodeResponse(response: Response, output: []u8) WireError!usize {
    if (output.len < 2) return error.BufferTooSmall;
    switch (response) {
        .hello_ack => |ack| { if (output.len < 12) return error.BufferTooSmall; output[0] = 4; output[1] = 12; writeU16(output[2..], ack.version); writeU64(output[4..], ack.capabilities); return 12; },
        .surface_created => |info| {
            if (output.len < 27) return error.BufferTooSmall;
            output[0] = 1; output[1] = 27;
            writeU32(output[2..], info.id); writeU32(output[6..], info.buffer_handle);
            writeU16(output[10..], info.width); writeU16(output[12..], info.height);
            writeU32(output[14..], info.stride); output[18] = @intFromEnum(info.format); writeU64(output[19..], info.generation);
            return 27;
        },
        .surface_destroyed => |id| { if (output.len < 6) return error.BufferTooSmall; output[0] = 2; output[1] = 6; writeU32(output[2..], id); return 6; },
        .failure => |code| { if (output.len < 4) return error.BufferTooSmall; output[0] = 3; output[1] = 4; writeU16(output[2..], code); return 4; },
    }
}

pub fn decodeResponse(input: []const u8) WireError!Response {
    if (input.len < 2 or input[1] != input.len) return error.InvalidMessage;
    return switch (input[0]) {
        4 => if (input.len == 12) .{ .hello_ack = .{ .version = readU16(input[2..]), .capabilities = readU64(input[4..]) } } else error.InvalidMessage,
        1 => if (input.len == 27 and readU16(input[10..]) != 0 and readU16(input[12..]) != 0 and readU32(input[14..]) >= readU16(input[10..]) and input[18] >= 1 and input[18] <= 3) .{ .surface_created = .{ .id = readU32(input[2..]), .buffer_handle = readU32(input[6..]), .width = readU16(input[10..]), .height = readU16(input[12..]), .stride = readU32(input[14..]), .format = @enumFromInt(input[18]), .generation = readU64(input[19..]) } } else error.InvalidMessage,
        2 => if (input.len == 6) .{ .surface_destroyed = readU32(input[2..]) } else error.InvalidMessage,
        3 => if (input.len == 4) .{ .failure = readU16(input[2..]) } else error.InvalidMessage,
        else => error.UnsupportedRequest,
    };
}

/// Little-endian, pointer-free wire envelope for a userspace IPC transport.
/// The transport can later be a socket, channel or shared ring without
/// exposing kernel or renderer data structures.
pub fn encodeRequest(request: Request, output: []u8) WireError!usize {
    if (output.len < 2) return error.BufferTooSmall;
    var length: usize = 2;
    output[0] = switch (request) { .hello => 9, .clipboard_set => 10, .resize => 11, .present => 1, .create_window => 2, .destroy_window => 3, .open_file => 4, .connect => 5, .audio => 6, .set_timer => 7, .close => 8 };
    switch (request) {
        .hello => |value| { if (output.len < 12) return error.BufferTooSmall; writeU16(output[2..], value.version); writeU64(output[4..], value.capabilities); length = 12; },
        .clipboard_set => |text| { if (text.len > 252 or output.len < 3 + text.len) return error.BufferTooSmall; output[2] = @intCast(text.len); @memcpy(output[3 .. 3 + text.len], text); length = 3 + text.len; },
        .resize => |value| { if (output.len < 6 or value.width == 0 or value.height == 0) return error.InvalidMessage; writeU16(output[2..], value.width); writeU16(output[4..], value.height); length = 6; },
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
        1 => if (input.len == 22 and readU16(input[18..]) != 0 and readU16(input[20..]) != 0) .{ .present = .{ .surface_id = readU32(input[2..]), .generation = readU64(input[6..]), .damage = .{ .x = readU16(input[14..]), .y = readU16(input[16..]), .width = readU16(input[18..]), .height = readU16(input[20..]) } } } else error.InvalidMessage,
        2 => if (input.len >= 7 and input[6] == input.len - 7) .{ .create_window = .{ .width = readU16(input[2..]), .height = readU16(input[4..]), .title = input[7..] } } else error.InvalidMessage,
        3 => if (input.len == 6) .{ .destroy_window = readU32(input[2..]) } else error.InvalidMessage,
        4 => if (input.len >= 3 and input[2] == input.len - 3) .{ .open_file = input[3..] } else error.InvalidMessage,
        5 => if (input.len >= 5 and input[4] == input.len - 5) .{ .connect = .{ .port = readU16(input[2..]), .address = input[5..] } } else error.InvalidMessage,
        6 => if (input.len == 7) .{ .audio = .{ .sample_rate = readU32(input[2..]), .channels = input[6] } } else error.InvalidMessage,
        7 => if (input.len == 14) .{ .set_timer = .{ .timer_id = readU32(input[2..]), .ticks = readU64(input[6..]) } } else error.InvalidMessage,
        8 => if (input.len == 2) .{ .close = {} } else error.InvalidMessage,
        9 => if (input.len == 12) .{ .hello = .{ .version = readU16(input[2..]), .capabilities = readU64(input[4..]) } } else error.InvalidMessage,
        10 => if (input.len >= 3 and input[2] == input.len - 3) .{ .clipboard_set = input[3..] } else error.InvalidMessage,
        11 => if (input.len == 6 and readU16(input[2..]) != 0 and readU16(input[4..]) != 0) .{ .resize = .{ .width = readU16(input[2..]), .height = readU16(input[4..]) } } else error.InvalidMessage,
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
    responses: [32]Response = undefined,
    response_read: usize = 0,
    response_write: usize = 0,
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
        if (self.request_write - self.request_read >= self.requests.len or self.response_write - self.response_read >= self.responses.len) return false;
        self.negotiated_version = protocol_version;
        self.negotiated_capabilities = capabilities & supported_capabilities;
        self.requests[self.request_write % self.requests.len] = .{ .hello = .{ .version = protocol_version, .capabilities = self.negotiated_capabilities } };
        self.request_write += 1;
        self.responses[self.response_write % self.responses.len] = .{ .hello_ack = .{ .version = self.negotiated_version, .capabilities = self.negotiated_capabilities } };
        self.response_write += 1;
        return true;
    }

    pub fn stop(self: *Backend) bool {
        if (!self.running) return false;
        self.running = false;
        return self.enqueueRequest(.close);
    }

    pub fn destroySurface(self: *Backend) bool {
        if (!self.surface_alive) return false;
        self.surface_alive = false;
        return self.enqueueRequest(.{ .destroy_window = self.surface.id }) and self.enqueueResponse(.{ .surface_destroyed = self.surface.id });
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
        if (self.response_write - self.response_read >= self.responses.len) return false;
        self.surface.width = width;
        self.surface.height = height;
        self.surface.stride = width;
        self.surface.pixels = pixels;
        self.surface.generation +|= 1;
        if (!self.enqueueEvent(.{ .focus = self.focused })) return false;
        return self.enqueueResponse(.{ .surface_created = self.surfaceInfo() });
    }

    pub fn attachBuffer(self: *Backend, buffer_handle: u32, pixels: []u32, stride: u32) bool {
        if (!self.surface_alive or buffer_handle == 0 or stride < self.surface.width or pixels.len < @as(usize, stride) * self.surface.height) return false;
        if (self.response_write - self.response_read >= self.responses.len) return false;
        self.surface.buffer_handle = buffer_handle;
        self.surface.stride = stride;
        self.surface.pixels = pixels;
        self.surface.generation +|= 1;
        return self.enqueueResponse(.{ .surface_created = self.surfaceInfo() });
    }

    pub fn setFormat(self: *Backend, format: PixelFormat) bool {
        if (!self.surface_alive) return false;
        self.surface.format = format;
        self.surface.generation +|= 1;
        return true;
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

    pub fn enqueueResponse(self: *Backend, response: Response) bool {
        if (self.response_write - self.response_read >= self.responses.len) return false;
        self.responses[self.response_write % self.responses.len] = response;
        self.response_write += 1;
        return true;
    }

    pub fn nextResponse(self: *Backend) ?Response {
        if (self.response_read == self.response_write) return null;
        const response = self.responses[self.response_read % self.responses.len];
        self.response_read += 1;
        return response;
    }

    pub fn submitResponseWire(self: *Backend, message: []const u8) WireError!bool {
        return self.enqueueResponse(try decodeResponse(message));
    }

    pub fn nextResponseWire(self: *Backend, output: []u8) WireError!?usize {
        const response = self.nextResponse() orelse return null;
        return try encodeResponse(response, output);
    }

    pub fn surfaceInfo(self: *const Backend) SurfaceInfo {
        return .{ .id = self.surface.id, .buffer_handle = self.surface.buffer_handle, .width = self.surface.width, .height = self.surface.height, .stride = self.surface.stride, .format = self.surface.format, .generation = self.surface.generation };
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

test "negotiation emits a confirmed hello acknowledgement" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 14, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    try std.testing.expect(backend.negotiate(protocol_version, supported_capabilities));
    switch (backend.nextResponse().?) {
        .hello_ack => |ack| { try std.testing.expectEqual(protocol_version, ack.version); try std.testing.expectEqual(supported_capabilities, ack.capabilities); },
        else => return error.UnexpectedBackendResponse,
    }
}

test "negotiation does not enqueue hello without acknowledgement capacity" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 17, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    var i: usize = 0;
    while (i < backend.responses.len) : (i += 1) try std.testing.expect(backend.enqueueResponse(.{ .failure = 1 }));
    try std.testing.expect(!backend.negotiate(protocol_version, supported_capabilities));
    try std.testing.expectEqual(@as(usize, 0), backend.request_write);
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

test "resize publishes updated shared surface metadata" {
    var pixels = [_]u32{0} ** 16;
    var backend = Backend.init(.{ .id = 15, .width = 2, .height = 2, .stride = 2, .pixels = pixels[0..4] });
    try std.testing.expect(backend.resize(4, 4, &pixels));
    switch (backend.nextResponse().?) {
        .surface_created => |info| { try std.testing.expectEqual(@as(u16, 4), info.width); try std.testing.expectEqual(@as(u64, 1), info.generation); },
        else => return error.UnexpectedBackendResponse,
    }
}

test "resize does not mutate when lifecycle response queue is full" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 16, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    var i: usize = 0;
    while (i < backend.responses.len) : (i += 1) {
        try std.testing.expect(backend.enqueueResponse(.{ .failure = 1 }));
    }
    try std.testing.expect(!backend.resize(1, 1, pixels[0..1]));
    try std.testing.expectEqual(@as(u16, 2), backend.surface.width);
}

test "backend attaches an opaque shared buffer handle" {
    var pixels = [_]u32{0} ** 16;
    var backend = Backend.init(.{ .id = 10, .width = 4, .height = 4, .stride = 4, .pixels = &pixels });
    try std.testing.expect(backend.attachBuffer(0x44, &pixels, 4));
    try std.testing.expectEqual(@as(u32, 0x44), backend.surface.buffer_handle);
    switch (backend.nextResponse().?) {
        .surface_created => |info| try std.testing.expectEqual(@as(u32, 0x44), info.buffer_handle),
        else => return error.UnexpectedBackendResponse,
    }
    try std.testing.expect(!backend.attachBuffer(0, &pixels, 4));
    try std.testing.expect(!backend.attachBuffer(0x45, pixels[0..4], 4));
}

test "backend exposes an explicit pixel format" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 11, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    try std.testing.expect(backend.setFormat(.bgra8888));
    try std.testing.expectEqual(PixelFormat.bgra8888, backend.surface.format);
    try std.testing.expect(backend.destroySurface());
    try std.testing.expect(!backend.setFormat(.argb8888));
}

test "backend returns opaque surface lifecycle responses" {
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 12, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    backend.surface.buffer_handle = 0x55;
    try std.testing.expect(backend.enqueueResponse(.{ .surface_created = backend.surfaceInfo() }));
    switch (backend.nextResponse().?) {
        .surface_created => |info| { try std.testing.expectEqual(@as(u32, 0x55), info.buffer_handle); },
        else => return error.UnexpectedBackendResponse,
    }
    try std.testing.expect(backend.destroySurface());
    switch (backend.nextResponse().?) {
        .surface_destroyed => |id| try std.testing.expectEqual(@as(u32, 12), id),
        else => return error.UnexpectedBackendResponse,
    }
}

test "surface lifecycle response round-trips through wire" {
    var wire: [40]u8 = undefined;
    var pixels = [_]u32{0} ** 4;
    var backend = Backend.init(.{ .id = 13, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    const length = try encodeResponse(.{ .surface_created = .{ .id = 5, .buffer_handle = 0x77, .width = 640, .height = 480, .stride = 640, .format = .bgra8888, .generation = 9 } }, &wire);
    switch (try decodeResponse(wire[0..length])) {
        .surface_created => |info| { try std.testing.expectEqual(@as(u32, 0x77), info.buffer_handle); try std.testing.expectEqual(PixelFormat.bgra8888, info.format); },
        else => return error.UnexpectedBackendResponse,
    }
    try std.testing.expectError(error.InvalidMessage, decodeResponse(wire[0..length - 1]));
    try std.testing.expect(try backend.submitResponseWire(wire[0..length]));
    try std.testing.expectEqual(@as(?usize, length), try backend.nextResponseWire(&wire));
}

test "hello acknowledgement round-trips through wire" {
    var wire: [16]u8 = undefined;
    const length = try encodeResponse(.{ .hello_ack = .{ .version = protocol_version, .capabilities = supported_capabilities } }, &wire);
    try std.testing.expectEqual(@as(usize, 12), length);
    switch (try decodeResponse(wire[0..length])) {
        .hello_ack => |ack| { try std.testing.expectEqual(protocol_version, ack.version); try std.testing.expectEqual(supported_capabilities, ack.capabilities); },
        else => return error.UnexpectedBackendResponse,
    }
}

test "invalid surface metadata is rejected" {
    var wire: [27]u8 = [_]u8{0} ** 27;
    wire[0] = 1; wire[1] = 27; wire[18] = 1;
    try std.testing.expectError(error.InvalidMessage, decodeResponse(&wire));
}

test "empty present damage is rejected" {
    var wire: [22]u8 = [_]u8{0} ** 22;
    wire[0] = 1; wire[1] = 22;
    try std.testing.expectError(error.InvalidMessage, decodeRequest(&wire));
}
