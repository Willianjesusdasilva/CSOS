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
