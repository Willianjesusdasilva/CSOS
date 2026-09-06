const std = @import("std");
const pci = @import("pci");
const physical = @import("physical");
const sdl = @import("sdl");

pub const Framebuffer = struct {
    base: u64,
    size: usize,
    width: u32,
    height: u32,
    stride: u32,
    pixel_format: u32,
};

pub const Adapter = struct {
    vendor: u16,
    device: u16,
    bus: u8,
    slot: u5,
    function: u3,
    aperture: u64,
};

pub const max_windows = 16;

pub const Window = struct {
    id: u32,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    title_color: u32 = 0x405070,
    body_color: u32 = 0x202838,
    visible: bool = true,
    minimized: bool = false,
};

/// Software window/compositor state. It deliberately renders into Context's
/// backbuffer, so it is usable in QEMU/GOP before a physical GPU exists.
pub const WindowManager = struct {
    windows: [max_windows]Window = undefined,
    count: usize = 0,
    focused: ?usize = null,

    pub fn create(self: *WindowManager, window: Window) !usize {
        if (self.count == max_windows) return error.WindowLimit;
        if (window.width < 32 or window.height < 24) return error.InvalidWindowSize;
        self.windows[self.count] = window;
        const index = self.count;
        self.count += 1;
        self.focused = index;
        return index;
    }

    pub fn close(self: *WindowManager, index: usize) void {
        if (index >= self.count) return;
        const old_focused = self.focused;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.windows[i] = self.windows[i + 1];
        self.count -= 1;
        self.focused = if (self.count == 0) null else if (old_focused) |focused| blk: {
            if (focused > index) break :blk focused - 1;
            if (focused == index) break :blk @min(index, self.count - 1);
            break :blk focused;
        } else @min(index, self.count - 1);
    }

    pub fn focus(self: *WindowManager, index: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        self.windows[index].minimized = false;
        if (index + 1 < self.count) {
            const selected = self.windows[index];
            var i = index;
            while (i + 1 < self.count) : (i += 1) self.windows[i] = self.windows[i + 1];
            self.windows[self.count - 1] = selected;
            self.focused = self.count - 1;
        } else {
            self.focused = index;
        }
        return true;
    }

    pub fn toggleMinimized(self: *WindowManager, index: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        self.windows[index].minimized = !self.windows[index].minimized;
        if (!self.windows[index].minimized) _ = self.focus(index);
        return true;
    }

    pub fn restore(self: *WindowManager, index: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        self.windows[index].minimized = false;
        return self.focus(index);
    }

    pub fn move(self: *WindowManager, index: usize, x: usize, y: usize, screen_width: usize, screen_height: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        const window = &self.windows[index];
        window.x = @min(x, screen_width -| window.width);
        window.y = @min(y, screen_height -| window.height);
        return true;
    }

    pub fn altTab(self: *WindowManager) ?usize {
        if (self.count == 0) return null;
        const start = self.focused orelse 0;
        var offset: usize = 1;
        while (offset <= self.count) : (offset += 1) {
            const index = (start + offset) % self.count;
            if (self.windows[index].visible) {
                self.windows[index].minimized = false;
                _ = self.focus(index);
                return self.focused.?;
            }
        }
        return self.focused;
    }

    pub fn altTabReverse(self: *WindowManager) ?usize {
        if (self.count == 0) return null;
        const start = self.focused orelse 0;
        var offset: usize = 1;
        while (offset <= self.count) : (offset += 1) {
            const index = (start + self.count - (offset % self.count)) % self.count;
            if (self.windows[index].visible) {
                self.windows[index].minimized = false;
                _ = self.focus(index);
                return self.focused.?;
            }
        }
        return self.focused;
    }

    pub fn hitTest(self: *const WindowManager, x: usize, y: usize) ?usize {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            const w = self.windows[i];
            if (w.visible and !w.minimized and x >= w.x and y >= w.y and x < w.x +| w.width and y < w.y +| w.height)
                return i;
        }
        return null;
    }

    pub fn taskbarHitTest(self: *const WindowManager, x: usize, y: usize, screen_height: usize) ?usize {
        if (screen_height < 24 or y < screen_height - 20) return null;
        const slot = x / 112;
        if (slot >= self.count or x % 112 >= 104) return null;
        return slot;
    }

    pub fn compose(self: *const WindowManager, context: *Context) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const w = self.windows[i];
            if (!w.visible or w.minimized) continue;
            context.fillRect(w.x, w.y, w.width, w.height, w.body_color);
            context.fillRect(w.x, w.y, w.width, @min(@as(usize, 20), w.height), if (self.focused == i) 0x5090d0 else w.title_color);
            context.drawWindowTitle(w.x + 6, w.y + 5, if (w.id == 1) "APP1" else "APP2");
            if (w.height >= 64) {
                const content_width = w.width -| 24;
                context.fillRect(w.x + 12, w.y + 32, content_width, 6, 0x304050);
                context.fillRect(w.x + 12, w.y + 32, content_width *| (i + 1) / 3, 6, 0x50b080);
                context.fillRect(w.x + 12, w.y + 48, content_width, 6, 0x304050);
                context.fillRect(w.x + 12, w.y + 48, content_width / (i + 2), 6, 0x5080c0);
            }
            // Small close affordance in every title bar; input handling lives
            // in the kernel loop so this remains a pure software compositor.
            if (w.width >= 32) {
                context.fillRect(w.x + w.width -| 18, w.y + 4, 14, 12, 0xb05050);
                context.fillRect(w.x + w.width -| 15, w.y + 6, 8, 2, 0xf0c0c0);
                context.fillRect(w.x + w.width -| 12, w.y + 3, 2, 8, 0xf0c0c0);
            }
        }
        const taskbar_y = @as(usize, context.framebuffer.height) -| 20;
        context.fillRect(0, taskbar_y, context.framebuffer.width, 20, 0x101820);
        i = 0;
        while (i < self.count) : (i += 1) {
            const w = self.windows[i];
            context.fillRect(i * 112 + 4, taskbar_y + 3, 104, 14, if (self.focused == i and !w.minimized) 0x5070a0 else 0x303848);
            context.drawWindowTitle(i * 112 + 12, taskbar_y + 5, if (w.id == 1) "APP1" else "APP2");
        }
    }
};

test "window manager focus alt-tab hit-test and close" {
    var manager = WindowManager{};
    try std.testing.expectError(error.InvalidWindowSize, manager.create(.{ .id = 1, .x = 0, .y = 0, .width = 31, .height = 24 }));
    try std.testing.expectEqual(@as(usize, 0), manager.count);
    const first = try manager.create(.{ .id = 10, .x = 8, .y = 8, .width = 80, .height = 48 });
    const second = try manager.create(.{ .id = 20, .x = 32, .y = 24, .width = 96, .height = 56 });
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(@as(?usize, 1), manager.hitTest(40, 30));
    try std.testing.expect(manager.focus(first));
    try std.testing.expectEqual(@as(u32, 10), manager.windows[manager.focused.?].id);
    try std.testing.expectEqual(@as(?usize, 1), manager.altTab());
    try std.testing.expectEqual(@as(u32, 20), manager.windows[manager.focused.?].id);
    try std.testing.expectEqual(@as(?usize, 1), manager.altTabReverse());
    try std.testing.expectEqual(@as(u32, 10), manager.windows[manager.focused.?].id);
    manager.close(manager.focused.?);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expectEqual(@as(u32, 20), manager.windows[0].id);
    try std.testing.expect(manager.toggleMinimized(0));
    try std.testing.expect(manager.windows[0].minimized);
    try std.testing.expect(manager.hitTest(20, 20) == null);
    try std.testing.expectEqual(@as(?usize, 0), manager.taskbarHitTest(20, 119, 128));
    try std.testing.expect(manager.taskbarHitTest(104, 119, 128) == null);
    try std.testing.expect(manager.taskbarHitTest(20, 100, 128) == null);
    try std.testing.expect(manager.taskbarHitTest(300, 119, 128) == null);
    try std.testing.expect(manager.focus(0));
    try std.testing.expect(!manager.windows[0].minimized);
    const third = try manager.create(.{ .id = 30, .x = 0, .y = 0, .width = 64, .height = 32 });
    try std.testing.expectEqual(@as(usize, 1), third);
    try std.testing.expect(manager.focus(1));
    manager.close(0);
    try std.testing.expectEqual(@as(?usize, 0), manager.focused);
    try std.testing.expectEqual(@as(u32, 30), manager.windows[0].id);
    try std.testing.expect(manager.move(0, 100, 100, 80, 60));
    try std.testing.expectEqual(@as(usize, 16), manager.windows[0].x);
    try std.testing.expectEqual(@as(usize, 28), manager.windows[0].y);
    try std.testing.expect(!manager.move(8, 0, 0, 100, 100));
    try std.testing.expect(manager.move(0, 999, 999, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), manager.windows[0].x);
    try std.testing.expectEqual(@as(usize, 0), manager.windows[0].y);
    manager.windows[0].minimized = true;
    try std.testing.expect(manager.restore(0));
    try std.testing.expect(!manager.windows[0].minimized);
    manager.windows[0].visible = false;
    try std.testing.expect(!manager.move(0, 0, 0, 100, 100));
    try std.testing.expect(!manager.restore(0));
}

test "window manager enforces maximum window count" {
    var manager = WindowManager{};
    var index: usize = 0;
    while (index < max_windows) : (index += 1) {
        _ = try manager.create(.{ .id = @intCast(index), .x = 0, .y = 0, .width = 32, .height = 24 });
    }
    try std.testing.expectEqual(max_windows, manager.count);
    try std.testing.expectError(error.WindowLimit, manager.create(.{ .id = 99, .x = 0, .y = 0, .width = 32, .height = 24 }));
}

pub const Context = struct {
    framebuffer: Framebuffer,
    adapter: Adapter,
    backbuffer: u64,
    buffer_bytes: usize,
    dirty_left: usize = 0,
    dirty_top: usize = 0,
    dirty_right: usize = 0,
    dirty_bottom: usize = 0,
    frames_presented: u64 = 0,
    pixels_presented: u64 = 0,

    pub fn init(framebuffer: Framebuffer, device: pci.Device, pages: *physical.Allocator) !Context {
        if (framebuffer.base == 0 or framebuffer.width == 0 or framebuffer.height == 0) return error.InvalidFramebuffer;
        if (framebuffer.stride < framebuffer.width or framebuffer.pixel_format > 1) return error.UnsupportedFramebuffer;
        const pixels = @as(usize, framebuffer.stride) * framebuffer.height;
        if (pixels > framebuffer.size / 4) return error.InvalidFramebufferSize;
        const bytes = pixels * 4;
        const page_count = (bytes + 4095) / 4096;
        const backbuffer = pages.allocate(page_count) orelse return error.OutOfMemory;
        const memory: [*]u8 = @ptrFromInt(backbuffer);
        @memset(memory[0..bytes], 0);
        return .{
            .framebuffer = framebuffer,
            .adapter = .{
                .vendor = device.vendor,
                .device = device.device,
                .bus = device.bus,
                .slot = device.slot,
                .function = device.function,
                .aperture = pci.barAddress(device, 0) orelse 0,
            },
            .backbuffer = backbuffer,
            .buffer_bytes = bytes,
        };
    }

    pub fn clear(self: *Context, rgb: u32) void {
        const pixels: [*]u32 = @ptrFromInt(self.backbuffer);
        const native = self.nativeColor(rgb);
        var index: usize = 0;
        while (index < self.buffer_bytes / 4) : (index += 1) pixels[index] = native;
        self.invalidate(0, 0, self.framebuffer.width, self.framebuffer.height);
    }

    pub fn fillRect(self: *Context, x: usize, y: usize, width: usize, height: usize, rgb: u32) void {
        const right = @min(@as(usize, self.framebuffer.width), x +| width);
        const bottom = @min(@as(usize, self.framebuffer.height), y +| height);
        if (x >= right or y >= bottom) return;
        const pixels: [*]u32 = @ptrFromInt(self.backbuffer);
        const native = self.nativeColor(rgb);
        var row = y;
        while (row < bottom) : (row += 1) {
            var column = x;
            while (column < right) : (column += 1)
                pixels[row * self.framebuffer.stride + column] = native;
        }
        self.invalidate(x, y, right - x, bottom - y);
    }

    pub fn present(self: *Context) usize {
        if (self.dirty_right <= self.dirty_left or self.dirty_bottom <= self.dirty_top) return 0;
        const source: [*]const u32 = @ptrFromInt(self.backbuffer);
        const target: [*]volatile u32 = @ptrFromInt(self.framebuffer.base);
        var copied: usize = 0;
        var row = self.dirty_top;
        while (row < self.dirty_bottom) : (row += 1) {
            var column = self.dirty_left;
            while (column < self.dirty_right) : (column += 1) {
                const index = row * self.framebuffer.stride + column;
                target[index] = source[index];
                copied += 1;
            }
        }
        self.dirty_left = 0;
        self.dirty_top = 0;
        self.dirty_right = 0;
        self.dirty_bottom = 0;
        self.frames_presented += 1;
        self.pixels_presented += copied;
        return copied;
    }

    pub fn blitSurface(self: *Context, surface: *sdl.Window, x: usize, y: usize) void {
        const dirty = surface.dirtyRect() orelse return;
        const width = @min(dirty.width, @as(usize, self.framebuffer.width) -| (x + dirty.x));
        const height = @min(dirty.height, @as(usize, self.framebuffer.height) -| (y + dirty.y));
        if (width == 0 or height == 0) return;
        const target: [*]u32 = @ptrFromInt(self.backbuffer);
        for (0..height) |row| {
            const source_start = (dirty.y + row) * surface.width + dirty.x;
            const target_start = (y + dirty.y + row) * self.framebuffer.stride + x + dirty.x;
            @memcpy(target[target_start .. target_start + width], surface.pixels[source_start .. source_start + width]);
        }
        self.invalidate(x + dirty.x, y + dirty.y, width, height);
        _ = surface.consumeDirty();
    }

    pub fn drawBaseline(self: *Context, input_devices: usize, audio_devices: usize) void {
        self.clear(0x101820);
        self.fillRect(0, 0, self.framebuffer.width, 32, 0x203050);
        self.fillRect(16, 8, @min(@as(usize, self.framebuffer.width) -| 16, 304), 16, 0x5070a0);
        const panel_width = @min(@as(usize, self.framebuffer.width) -| 48, 560);
        self.fillRect(24, 64, panel_width, 128, 0x181c28);
        self.fillRect(32, 88, @min(panel_width -| 16, input_devices * 96), 12, 0x50d080);
        self.fillRect(32, 120, @min(panel_width -| 16, audio_devices * 96), 12, 0x5080d0);
        self.drawLogo(32, 66);
        self.drawReadyLabel(32, 176);
        const center_x = @as(usize, self.framebuffer.width) / 2;
        const center_y = @as(usize, self.framebuffer.height) / 2;
        self.fillRect(center_x -| 8, center_y, 17, 1, 0xffffff);
        self.fillRect(center_x, center_y -| 8, 1, 17, 0xffffff);
    }

    pub fn drawWindowTitle(self: *Context, x: usize, y: usize, title: []const u8) void {
        for (title, 0..) |character, index| {
            const glyph: [5]u8 = switch (character) {
                'A' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
                'P' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
                '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
                '2' => .{ 0b110, 0b001, 0b010, 0b100, 0b111 },
                else => .{ 0, 0, 0, 0, 0 },
            };
            for (glyph, 0..) |row_bits, row| {
                var bit: usize = 0;
                while (bit < 3) : (bit += 1)
                    if ((row_bits & (@as(u8, 1) << @intCast(2 - bit))) != 0)
                        self.fillRect(x + index * 8 + bit * 2, y + row * 2, 2, 2, 0xffffff);
            }
        }
    }

    fn drawLogo(self: *Context, x: usize, y: usize) void {
        const glyphs = [_][5]u8{
            .{ 0b11110, 0b10000, 0b10000, 0b10000, 0b11110 },
            .{ 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 },
            .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 },
            .{ 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 },
        };
        for (glyphs, 0..) |glyph, index| {
            for (glyph, 0..) |column, row| {
                var bit: usize = 0;
                while (bit < 5) : (bit += 1)
                    if ((column & (@as(u8, 1) << @intCast(4 - bit))) != 0)
                        self.fillRect(x + index * 14 + bit * 2, y + row * 2, 2, 2, 0x70d0ff);
            }
        }
    }

    fn drawReadyLabel(self: *Context, x: usize, y: usize) void {
        const glyphs = [_][5]u8{
            .{ 0b11110, 0b10001, 0b11110, 0b10100, 0b10010 },
            .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b11111 },
            .{ 0b01110, 0b10001, 0b11111, 0b10001, 0b10001 },
            .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 },
            .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100 },
        };
        for (glyphs, 0..) |glyph, index| {
            for (glyph, 0..) |column, row| {
                var bit: usize = 0;
                while (bit < 5) : (bit += 1)
                    if ((column & (@as(u8, 1) << @intCast(4 - bit))) != 0)
                        self.fillRect(x + index * 12 + bit * 2, y + row * 2, 2, 2, 0xa0b8d0);
            }
        }
    }

    pub fn drawCursor(self: *Context, x: usize, y: usize, rgb: u32) void {
        if (self.framebuffer.width < 3 or self.framebuffer.height < 3) return;
        const center_x = @min(x, @as(usize, self.framebuffer.width) - 1);
        const center_y = @min(y, @as(usize, self.framebuffer.height) - 1);
        self.fillRect(center_x -| 6, center_y, 13, 1, rgb);
        self.fillRect(center_x, center_y -| 6, 1, 13, rgb);
    }

    pub fn drawPointerButtons(self: *Context, buttons: u8) void {
        if (self.framebuffer.width < 64 or self.framebuffer.height < 160) return;
        const width = @min(@as(usize, self.framebuffer.width) -| 64, 160);
        self.fillRect(32, 152, width, 8, if (buttons != 0) 0xffb040 else 0x303038);
    }

    pub fn drawKeyboardActivity(self: *Context) void {
        if (self.framebuffer.width < 64 or self.framebuffer.height < 160) return;
        const width = @min(@as(usize, self.framebuffer.width) -| 64, 160);
        self.fillRect(208, 152, width, 8, 0x50a0e0);
    }

    pub fn drawActionButton(self: *Context, active: bool) void {
        if (self.framebuffer.width < 520 or self.framebuffer.height < 112) return;
        self.fillRect(320, 64, 160, 32, if (active) 0x40c080 else 0x405070);
        self.fillRect(328, 72, 144, 16, if (active) 0x80f0b0 else 0x7090b0);
    }

    pub fn heartbeat(self: *Context, phase: usize) void {
        self.fillRect(16, 16, 16, 4, 0x203050);
        self.fillRect(16 + phase % 16, 16, 1, 4, 0x40e080);
    }

    fn invalidate(self: *Context, x: usize, y: usize, width: usize, height: usize) void {
        const right = @min(@as(usize, self.framebuffer.width), x +| width);
        const bottom = @min(@as(usize, self.framebuffer.height), y +| height);
        if (x >= right or y >= bottom) return;
        if (self.dirty_right == 0 or self.dirty_bottom == 0) {
            self.dirty_left = x;
            self.dirty_top = y;
            self.dirty_right = right;
            self.dirty_bottom = bottom;
        } else {
            self.dirty_left = @min(self.dirty_left, x);
            self.dirty_top = @min(self.dirty_top, y);
            self.dirty_right = @max(self.dirty_right, right);
            self.dirty_bottom = @max(self.dirty_bottom, bottom);
        }
    }

    fn nativeColor(self: *const Context, rgb: u32) u32 {
        if (self.framebuffer.pixel_format == 1) return rgb & 0x00ffffff;
        return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
    }
};
