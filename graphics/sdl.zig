pub const PixelFormat = enum { rgba8888 };
pub const Rect = struct { x: usize, y: usize, width: usize, height: usize };
pub const AudioSpec = struct { sample_rate: u32, channels: u8 };

pub const Event = union(enum) {
    quit: void,
    key: struct { scancode: u8, pressed: bool, modifiers: u8 },
    mouse: struct { x: i32, y: i32, wheel: i32, buttons: u8 },
};

pub const EventQueue = struct {
    items: [64]Event = undefined,
    read: usize = 0,
    write: usize = 0,
    dropped: u64 = 0,

    pub fn push(self: *EventQueue, event: Event) bool {
        if (self.write - self.read == self.items.len) {
            self.dropped +%= 1;
            return false;
        }
        self.items[self.write % self.items.len] = event;
        self.write += 1;
        return true;
    }

    pub fn poll(self: *EventQueue) ?Event {
        if (self.read == self.write) return null;
        const event = self.items[self.read % self.items.len];
        self.read += 1;
        return event;
    }

    pub fn peek(self: *const EventQueue) ?Event {
        if (self.read == self.write) return null;
        return self.items[self.read % self.items.len];
    }

    pub fn len(self: *const EventQueue) usize {
        return self.write - self.read;
    }

    pub fn remaining(self: *const EventQueue) usize {
        return self.items.len -| self.len();
    }

    pub fn isFull(self: *const EventQueue) bool {
        return self.len() == self.items.len;
    }

    pub fn isEmpty(self: *const EventQueue) bool {
        return self.read == self.write;
    }

    pub fn droppedCount(self: *const EventQueue) u64 {
        return self.dropped;
    }

    pub fn takeDroppedCount(self: *EventQueue) u64 {
        const dropped = self.dropped;
        self.dropped = 0;
        return dropped;
    }

    pub fn clear(self: *EventQueue) void {
        self.read = self.write;
    }

    pub fn pushKeyboard(self: *EventQueue, scancode: u8, pressed: bool, modifiers: u8) bool {
        return self.push(.{ .key = .{ .scancode = scancode, .pressed = pressed, .modifiers = modifiers } });
    }

    pub fn pushMouse(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        return self.push(.{ .mouse = .{ .x = x, .y = y, .wheel = wheel, .buttons = buttons } });
    }

    pub fn pushMouseCoalesced(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        if (self.remaining() == 0 and self.write != 0) {
            const slot = (self.write - 1) % self.items.len;
            if (self.items[slot] == .mouse) {
                self.items[slot].mouse.x += x;
                self.items[slot].mouse.y += y;
                self.items[slot].mouse.wheel += wheel;
                self.items[slot].mouse.buttons = buttons;
                return true;
            }
        }
        return self.pushMouse(x, y, wheel, buttons);
    }

    pub fn pushQuit(self: *EventQueue) bool {
        return self.push(.{ .quit = {} });
    }
};

pub const Window = struct {
    width: usize,
    height: usize,
    pixels: []u32,
    format: PixelFormat = .rgba8888,
    dirty: bool = false,
    dirty_left: usize = 0,
    dirty_top: usize = 0,
    dirty_right: usize = 0,
    dirty_bottom: usize = 0,

    pub fn clear(self: *Window, color: u32) void {
        for (self.pixels) |*pixel| pixel.* = color;
        self.markDirty(0, 0, self.width, self.height);
    }

    pub fn fillRect(self: *Window, x: usize, y: usize, width: usize, height: usize, color: u32) void {
        const right = @min(self.width, x +| width);
        const bottom = @min(self.height, y +| height);
        if (x >= right or y >= bottom) return;
        for (y..bottom) |row| {
            for (x..right) |column| self.pixels[row * self.width + column] = color;
        }
        self.markDirty(x, y, right - x, bottom - y);
    }

    pub fn consumeDirty(self: *Window) bool {
        const was_dirty = self.dirty;
        self.dirty = false;
        return was_dirty;
    }

    pub fn dirtyRect(self: *const Window) ?Rect {
        if (!self.dirty) return null;
        return .{ .x = self.dirty_left, .y = self.dirty_top, .width = self.dirty_right - self.dirty_left, .height = self.dirty_bottom - self.dirty_top };
    }

    fn markDirty(self: *Window, x: usize, y: usize, width: usize, height: usize) void {
        const right = @min(self.width, x +| width);
        const bottom = @min(self.height, y +| height);
        if (x >= right or y >= bottom) return;
        if (!self.dirty) {
            self.dirty_left = x; self.dirty_top = y; self.dirty_right = right; self.dirty_bottom = bottom;
        } else {
            self.dirty_left = @min(self.dirty_left, x); self.dirty_top = @min(self.dirty_top, y);
            self.dirty_right = @max(self.dirty_right, right); self.dirty_bottom = @max(self.dirty_bottom, bottom);
        }
        self.dirty = true;
    }
};

pub const Application = struct {
    window: Window,
    running: bool = true,
    last_event: ?Event = null,

    pub fn pump(self: *Application, events: *EventQueue, on_event: *const fn (*Application, Event) void) void {
        while (events.poll()) |event| {
            self.last_event = event;
            if (event == .quit) self.running = false;
            on_event(self, event);
        }
    }

    pub fn takeLastEvent(self: *Application) ?Event {
        const event = self.last_event;
        self.last_event = null;
        return event;
    }

    pub fn render(self: *Application, draw: *const fn (*Window) void) bool {
        if (!self.running) return false;
        draw(&self.window);
        return self.window.dirtyRect() != null;
    }

    pub fn frame(self: *Application, events: *EventQueue, on_event: *const fn (*Application, Event) void, draw: *const fn (*Window) void) bool {
        self.pump(events, on_event);
        if (!self.running) return false;
        return self.render(draw);
    }
};

pub const AudioDevice = struct {
    spec: AudioSpec,
    queued_frames: u64 = 0,
    paused: bool = false,

    pub fn init(spec: AudioSpec) !AudioDevice {
        if (spec.sample_rate == 0 or spec.channels == 0 or spec.channels > 8) return error.InvalidAudioSpec;
        return .{ .spec = spec };
    }

    pub fn queue(self: *AudioDevice, frames: u64) void {
        const result = @addWithOverflow(self.queued_frames, frames);
        self.queued_frames = if (result[1] != 0) ~@as(u64, 0) else result[0];
    }

    pub fn consume(self: *AudioDevice, frames: u64) u64 {
        if (self.paused) return 0;
        const used = @min(frames, self.queued_frames);
        self.queued_frames -= used;
        return used;
    }

    pub fn pause(self: *AudioDevice, value: bool) void {
        self.paused = value;
    }
};

pub fn createWindow(storage: []u32, width: usize, height: usize) !Window {
    if (width == 0 or height == 0 or width * height != storage.len) return error.InvalidSurface;
    return .{ .width = width, .height = height, .pixels = storage };
}

fn testApplicationEvent(_: *Application, _: Event) void {}
fn testApplicationDraw(window: *Window) void { window.fillRect(0, 0, 1, 1, 0xffffffff); }

test "SDL software event queue and surface contract" {
    var events = EventQueue{};
    try @import("std").testing.expectEqual(@as(usize, 0), events.len());
    try @import("std").testing.expectEqual(@as(usize, 64), events.remaining());
    try @import("std").testing.expect(!events.isFull());
    try @import("std").testing.expect(events.isEmpty());
    try @import("std").testing.expect(events.pushQuit());
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), events.peek());
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), events.poll());
    try @import("std").testing.expect(events.pushKeyboard(0x04, true, 0x04));
    try @import("std").testing.expect(events.pushMouse(12, -3, 1, 1));
    try @import("std").testing.expect(events.poll() != null);
    try @import("std").testing.expect(events.poll() != null);
    try @import("std").testing.expectEqual(@as(usize, 0), events.len());
    var full = EventQueue{};
    var index: usize = 0;
    while (index < full.items.len) : (index += 1)
        try @import("std").testing.expect(full.push(.{ .mouse = .{ .x = @intCast(index), .y = 0, .wheel = 0, .buttons = 0 } }));
    try @import("std").testing.expect(!full.push(.{ .quit = {} }));
    try @import("std").testing.expect(full.isFull());
    try @import("std").testing.expect(!full.isEmpty());
    try @import("std").testing.expectEqual(@as(u64, 1), full.droppedCount());
    try @import("std").testing.expectEqual(@as(u64, 1), full.takeDroppedCount());
    try @import("std").testing.expectEqual(@as(u64, 0), full.droppedCount());
    try @import("std").testing.expect(full.pushMouseCoalesced(2, -1, 1, 1));
    try @import("std").testing.expectEqual(@as(u64, 0), full.droppedCount());
    index = 0;
    while (index < full.items.len) : (index += 1) {
        const event = full.poll() orelse return error.MissingEvent;
        try @import("std").testing.expect(event == .mouse);
        if (index == full.items.len - 1) {
            try @import("std").testing.expectEqual(@as(i32, 65), event.mouse.x);
            try @import("std").testing.expectEqual(@as(i32, -1), event.mouse.y);
            try @import("std").testing.expectEqual(@as(i32, 1), event.mouse.wheel);
            try @import("std").testing.expectEqual(@as(u8, 1), event.mouse.buttons);
        }
    }
    try @import("std").testing.expect(full.poll() == null);
    try @import("std").testing.expect(full.push(.{ .quit = {} }));
    full.clear();
    try @import("std").testing.expectEqual(@as(usize, 0), full.len());
    var pixels: [16]u32 = .{0} ** 16;
    const window = try createWindow(&pixels, 4, 4);
    try @import("std").testing.expectEqual(@as(usize, 4), window.width);
    var drawable = window;
    try @import("std").testing.expect(!drawable.consumeDirty());
    drawable.clear(0x11223344);
    try @import("std").testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, drawable.dirtyRect().?);
    try @import("std").testing.expect(drawable.consumeDirty());
    drawable.fillRect(1, 1, 2, 2, 0xaabbccdd);
    try @import("std").testing.expectEqual(@as(u32, 0xaabbccdd), pixels[5]);
    drawable.fillRect(3, 3, 8, 8, 0x55667788);
    try @import("std").testing.expectEqual(@as(u32, 0x55667788), pixels[15]);
    drawable.fillRect(0, 0, 1, 1, 0x01020304);
    try @import("std").testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, drawable.dirtyRect().?);
    var app = Application{ .window = drawable };
    var app_events = EventQueue{};
    try @import("std").testing.expect(app_events.push(.{ .quit = {} }));
    app.pump(&app_events, &testApplicationEvent);
    try @import("std").testing.expect(!app.running);
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), app.last_event);
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), app.takeLastEvent());
    try @import("std").testing.expect(app.takeLastEvent() == null);
    try @import("std").testing.expect(!app.render(&testApplicationDraw));
    app.running = true;
    try @import("std").testing.expect(app.render(&testApplicationDraw));
    try @import("std").testing.expect(app.frame(&app_events, &testApplicationEvent, &testApplicationDraw));
    var audio = try AudioDevice.init(.{ .sample_rate = 48000, .channels = 2 });
    audio.queue(256);
    try @import("std").testing.expectEqual(@as(u64, 128), audio.consume(128));
    audio.pause(true);
    try @import("std").testing.expect(audio.paused);
    try @import("std").testing.expectEqual(@as(u64, 0), audio.consume(64));
    try @import("std").testing.expectEqual(@as(u64, 128), audio.queued_frames);
    audio.pause(false);
    audio.queued_frames = ~@as(u64, 0) - 1;
    audio.queue(4);
    try @import("std").testing.expectEqual(~@as(u64, 0), audio.queued_frames);
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 0, .channels = 2 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 0 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 9 }));
}
