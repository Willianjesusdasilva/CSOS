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
    present: struct { surface_id: u32, generation: u64, damage: Damage },
    create_window: struct { width: u16, height: u16, title: []const u8 },
    destroy_window: u32,
    open_file: []const u8,
    connect: struct { address: []const u8, port: u16 },
    audio: struct { sample_rate: u32, channels: u8 },
    set_timer: struct { timer_id: u32, ticks: u64 },
    close,
};

pub const WireError = error{BufferTooSmall, InvalidMessage, UnsupportedRequest};

/// Little-endian, pointer-free wire envelope for a userspace IPC transport.
/// The transport can later be a socket, channel or shared ring without
/// exposing kernel or renderer data structures.
pub fn encodeRequest(request: Request, output: []u8) WireError!usize {
    if (output.len < 2) return error.BufferTooSmall;
    var length: usize = 2;
    output[0] = switch (request) { .present => 1, .create_window => 2, .destroy_window => 3, .open_file => 4, .connect => 5, .audio => 6, .set_timer => 7, .close => 8 };
    switch (request) {
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

fn writeU8(output: []u8, value: u8) void { output[0] = value; }
fn writeU16(output: []u8, value: u16) void { std.mem.writeInt(u16, output[0..2], value, .little); }
fn writeU32(output: []u8, value: u32) void { std.mem.writeInt(u32, output[0..4], value, .little); }
fn writeU64(output: []u8, value: u64) void { std.mem.writeInt(u64, output[0..8], value, .little); }

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

    pub fn init(surface: Surface) Backend { return .{ .surface = surface }; }

    pub fn start(self: *Backend) bool {
        if (self.running) return false;
        self.running = true;
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
        if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height) return false;
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

    pub fn present(self: *Backend, damage: Damage) bool {
        return self.enqueueRequest(.{ .present = .{ .surface_id = self.surface.id, .generation = self.surface.generation, .damage = damage } });
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
}
