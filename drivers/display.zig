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

test "window manager keeps focus when closing a sibling" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 4, .y = 4, .width = 64, .height = 48 });
    _ = try manager.create(.{ .id = 2, .x = 12, .y = 12, .width = 64, .height = 48 });
    try std.testing.expect(manager.focus(0));
    try std.testing.expectEqual(@as(u32, 1), manager.windows[manager.focused.?].id);
    manager.close(0);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expectEqual(@as(u32, 1), manager.windows[manager.focused.?].id);
}

test "window manager recovers stale focus after close" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 4, .y = 4, .width = 64, .height = 48 });
    _ = try manager.create(.{ .id = 2, .x = 12, .y = 12, .width = 64, .height = 48 });
    manager.focused = 99;
    manager.close(0);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expectEqual(@as(?usize, 0), manager.focused);
    try std.testing.expectEqual(@as(u32, 2), manager.windows[0].id);
}

pub const Adapter = struct {
    vendor: u16,
    device: u16,
    bus: u8,
    slot: u5,
    function: u3,
    aperture: u64,
};

pub const max_windows = 16;
pub const min_window_width = 64;
pub const min_window_height = 48;
pub const launcher_item_count = 4;
const launcher_menu_height = launcher_item_count * 24 + 24;
const launcher_labels = [_][]const u8{ "TERMINAL", "MONITOR", "SYSTEM", "FILES" };

pub fn applyPointerDelta(position: usize, delta: i8, extent: usize) usize {
    if (extent == 0) return 0;
    const bounded = @min(position, extent - 1);
    if (delta < 0) return bounded -| @as(usize, @intCast(-@as(i16, delta)));
    return @min(extent - 1, bounded +| @as(usize, @intCast(delta)));
}

test "pointer delta clamps invalid positions and both edges" {
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(7, 12, 0));
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(999, -12, 1));
    try std.testing.expectEqual(@as(usize, 9), applyPointerDelta(999, 0, 10));
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(0, -128, 10));
    try std.testing.expectEqual(@as(usize, 9), applyPointerDelta(9, 127, 10));
}

test "pointer wheel feedback distinguishes direction" {
    try std.testing.expectEqual(@as(u32, 0x4080e0), pointerWheelColor(-1));
    try std.testing.expectEqual(@as(u32, 0x506070), pointerWheelColor(0));
    try std.testing.expectEqual(@as(u32, 0x80a0e0), pointerWheelColor(1));
}

pub fn pointerWheelColor(wheel: i8) u32 {
    return if (wheel < 0) 0x4080e0 else if (wheel > 0) 0x80a0e0 else 0x506070;
}

pub const Window = struct {
    id: u32,
    title: []const u8 = "APP",
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    title_color: u32 = 0x405070,
    body_color: u32 = 0x202838,
    visible: bool = true,
    minimized: bool = false,
    maximized: bool = false,
    restore_x: usize = 0,
    restore_y: usize = 0,
    restore_width: usize = 0,
    restore_height: usize = 0,
    surface: ?*sdl.Window = null,
};

/// Software window/compositor state. It deliberately renders into Context's
/// backbuffer, so it is usable in QEMU/GOP before a physical GPU exists.
pub const WindowManager = struct {
    windows: [max_windows]Window = undefined,
    count: usize = 0,
    focused: ?usize = null,
    launcher_open: bool = false,
    launcher_selection: u8 = 0,
    switcher_open: bool = false,

    pub fn reset(self: *WindowManager) void {
        for (&self.windows) |*window| window.* = undefined;
        self.count = 0;
        self.focused = null;
        self.launcher_open = false;
        self.launcher_selection = 0;
        self.switcher_open = false;
    }

    pub fn create(self: *WindowManager, window: Window) !usize {
        if (self.count == max_windows) return error.WindowLimit;
        if (window.width < 32 or window.height < 24) return error.InvalidWindowSize;
        self.windows[self.count] = window;
        const index = self.count;
        self.count += 1;
        self.focused = index;
        // A nova janela assume o desktop; overlays não devem cobrir seu primeiro frame.
        self.launcher_open = false;
        self.launcher_selection = 0;
        self.switcher_open = false;
        return index;
    }

    pub fn close(self: *WindowManager, index: usize) void {
        if (index >= self.count) return;
        self.launcher_open = false;
        self.launcher_selection = 0;
        self.switcher_open = false;
        const old_focused = self.focused;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.windows[i] = self.windows[i + 1];
        self.count -= 1;
        // Do not retain a stale surface pointer in the reusable tail slot.
        self.windows[self.count] = undefined;
        if (self.count == 0) {
            self.launcher_open = false;
            self.switcher_open = false;
            self.launcher_selection = 0;
        }
        self.focused = if (self.count == 0) null else if (old_focused) |focused| blk: {
            if (focused >= self.count) break :blk self.topVisible();
            if (focused > index) break :blk focused - 1;
            if (focused == index) break :blk self.topVisible();
            break :blk focused;
        } else self.topVisible();
    }

    pub fn focus(self: *WindowManager, index: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        self.windows[index].minimized = false;
        // Clicking or otherwise focusing a window dismisses the launcher
        // overlay; leaving it open would paint the menu over the new focus.
        self.launcher_open = false;
        self.launcher_selection = 0;
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
        if (!self.windows[index].minimized) {
            _ = self.focus(index);
        } else if (self.focused == index) {
            self.focused = self.topVisible();
        }
        return true;
    }

    fn topVisible(self: *const WindowManager) ?usize {
        var index = self.count;
        while (index > 0) {
            index -= 1;
            if (self.windows[index].visible and !self.windows[index].minimized) return index;
        }
        return null;
    }

    pub fn restore(self: *WindowManager, index: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        self.windows[index].minimized = false;
        return self.focus(index);
    }

    pub fn findById(self: *const WindowManager, id: u32) ?usize {
        for (self.windows[0..self.count], 0..) |window, index|
            if (window.id == id and window.visible) return index;
        return null;
    }

    pub fn move(self: *WindowManager, index: usize, x: usize, y: usize, screen_width: usize, screen_height: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        const window = &self.windows[index];
        if (window.maximized) return false;
        window.x = @min(x, screen_width -| window.width);
        // Keep the window above the 20px taskbar, matching resize/maximize.
        const usable_height = screen_height -| 20;
        window.y = @min(y, usable_height -| window.height);
        return true;
    }

    pub fn resize(self: *WindowManager, index: usize, width: usize, height: usize, screen_width: usize, screen_height: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        const window = &self.windows[index];
        if (window.maximized) return false;
        const available_width = screen_width -| window.x;
        const available_height = (screen_height -| 20) -| window.y;
        if (available_width < min_window_width or available_height < min_window_height) return false;
        window.width = @min(@max(width, min_window_width), available_width);
        window.height = @min(@max(height, min_window_height), available_height);
        return true;
    }

    pub fn toggleMaximized(self: *WindowManager, index: usize, screen_width: usize, screen_height: usize) bool {
        if (index >= self.count or !self.windows[index].visible) return false;
        const window = &self.windows[index];
        if (window.maximized) {
            const usable_height = screen_height -| 20;
            window.width = @min(@max(window.restore_width, min_window_width), screen_width);
            window.height = @min(@max(window.restore_height, min_window_height), usable_height);
            window.x = @min(window.restore_x, screen_width -| window.width);
            window.y = @min(window.restore_y, usable_height -| window.height);
            window.maximized = false;
        } else {
            if (screen_width < min_window_width or screen_height -| 20 < min_window_height) return false;
            window.restore_x = window.x;
            window.restore_y = window.y;
            window.restore_width = window.width;
            window.restore_height = window.height;
            window.x = 0;
            window.y = 0;
            window.width = screen_width;
            window.height = screen_height - 20;
            window.maximized = true;
            window.minimized = false;
        }
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
        self.focused = null;
        return null;
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
        self.focused = null;
        return null;
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

    pub fn closeHitTest(self: *const WindowManager, index: usize, x: usize, y: usize) bool {
        if (index >= self.count) return false;
        const window = self.windows[index];
        return window.visible and !window.minimized and
            x >= window.x +| window.width -| 20 and x < window.x +| window.width and
            y >= window.y and y < window.y +| 20;
    }

    pub fn maximizeHitTest(self: *const WindowManager, index: usize, x: usize, y: usize) bool {
        if (index >= self.count) return false;
        const window = self.windows[index];
        return window.visible and !window.minimized and window.width >= 52 and
            x >= window.x +| window.width -| 38 and x < window.x +| window.width -| 22 and
            y >= window.y and y < window.y +| 20;
    }

    pub fn minimizeHitTest(self: *const WindowManager, index: usize, x: usize, y: usize) bool {
        if (index >= self.count) return false;
        const window = self.windows[index];
        return window.visible and !window.minimized and window.width >= 72 and
            x >= window.x +| window.width -| 58 and x < window.x +| window.width -| 42 and
            y >= window.y and y < window.y +| 20;
    }

    pub fn resizeHitTest(self: *const WindowManager, index: usize, x: usize, y: usize) bool {
        if (index >= self.count) return false;
        const window = self.windows[index];
        return window.visible and !window.minimized and !window.maximized and
            x >= window.x +| window.width -| 12 and x < window.x +| window.width and
            y >= window.y +| window.height -| 12 and y < window.y +| window.height;
    }

    pub fn contentListRowHitTest(self: *const WindowManager, index: usize, x: usize, y: usize, top: usize, row_height: usize, row_pixels: usize, visible_rows: usize) ?usize {
        if (index >= self.count or row_height == 0 or row_pixels == 0 or row_pixels > row_height) return null;
        const window = self.windows[index];
        if (!window.visible or window.minimized or window.surface == null or window.width <= 24 or window.height <= 32) return null;
        const content_left = window.x +| 12;
        const content_right = window.x +| window.width -| 12;
        const list_top = window.y +| 28 +| top;
        if (x < content_left or x >= content_right or y < list_top) return null;
        const local_y = y - list_top;
        const row = local_y / row_height;
        if (row >= visible_rows or local_y % row_height >= row_pixels) return null;
        return row;
    }

    pub fn contentRectHitTest(self: *const WindowManager, index: usize, x: usize, y: usize, left: usize, top: usize, width: usize, height: usize) bool {
        if (index >= self.count or width == 0 or height == 0) return false;
        const window = self.windows[index];
        if (!window.visible or window.minimized or window.surface == null or window.width <= 24 or window.height <= 32) return false;
        const content_width = window.width - 24;
        const content_height = window.height - 32;
        if (left >= content_width or top >= content_height) return false;
        const clipped_width = @min(width, content_width - left);
        const clipped_height = @min(height, content_height - top);
        const rect_x = window.x +| 12 +| left;
        const rect_y = window.y +| 28 +| top;
        return x >= rect_x and x < rect_x +| clipped_width and y >= rect_y and y < rect_y +| clipped_height;
    }

    pub fn taskbarHitTest(self: *const WindowManager, x: usize, y: usize, screen_height: usize) ?usize {
        if (screen_height < 24 or y < screen_height - 20 or y >= screen_height) return null;
        if (x < 64) return null;
        const task_x = x - 64;
        const slot = task_x / 112;
        if (slot >= self.count or task_x % 112 >= 104) return null;
        return slot;
    }

    pub fn launcherButtonHitTest(_: *const WindowManager, x: usize, y: usize, screen_height: usize) bool {
        return screen_height >= 24 and y < screen_height and x >= 4 and x < 56 and y >= screen_height - 17 and y < screen_height - 3;
    }

    pub fn launcherItemHitTest(self: *const WindowManager, x: usize, y: usize, screen_height: usize) ?u32 {
        if (!self.launcher_open or screen_height < launcher_menu_height + 4 or y >= screen_height or x < 4 or x >= 180) return null;
        const menu_top = screen_height - launcher_menu_height;
        for (0..launcher_item_count) |index| {
            const item_top = menu_top + 4 + index * 24;
            if (y >= item_top and y < item_top + 20) return @intCast(index + 1);
        }
        return null;
    }

    pub fn launcherSelectNext(self: *WindowManager) void {
        self.launcher_selection = (self.launcher_selection + 1) % launcher_item_count;
    }

    pub fn launcherSelectPrevious(self: *WindowManager) void {
        self.launcher_selection = if (self.launcher_selection == 0) launcher_item_count - 1 else self.launcher_selection - 1;
    }

    pub fn launcherSelectedApplication(self: *const WindowManager) ?u32 {
        if (!self.launcher_open) return null;
        return @as(u32, self.launcher_selection % launcher_item_count) + 1;
    }

    pub fn compose(self: *const WindowManager, context: *Context) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const w = self.windows[i];
            if (!w.visible or w.minimized) continue;
            context.fillRect(w.x, w.y, w.width, w.height, w.body_color);
            context.fillRect(w.x, w.y, w.width, @min(@as(usize, 20), w.height), if (self.focused == i) 0x5090d0 else w.title_color);
            context.drawWindowTitleLimited(w.x + 6, w.y + 5, w.title, w.width -| 34);
            if (w.height >= 64) {
                const content_width = w.width -| 24;
                context.fillRect(w.x + 12, w.y + 32, content_width, 6, 0x304050);
                context.fillRect(w.x + 12, w.y + 32, content_width *| (i + 1) / 3, 6, 0x50b080);
                context.fillRect(w.x + 12, w.y + 48, content_width, 6, 0x304050);
                context.fillRect(w.x + 12, w.y + 48, content_width / (i + 2), 6, 0x5080c0);
            }
            if (w.surface) |surface| {
                const content_width = w.width -| 24;
                const content_height = w.height -| 32;
                if (content_width != 0 and content_height != 0) {
                    surface.invalidate();
                    context.blitSurfaceClipped(surface, w.x + 12, w.y + 28, content_width, content_height);
                }
            }
            // Small close affordance in every title bar; input handling lives
            // in the kernel loop so this remains a pure software compositor.
            if (w.width >= 32) {
                context.fillRect(w.x + w.width -| 18, w.y + 4, 14, 12, 0xb05050);
                context.fillRect(w.x + w.width -| 15, w.y + 6, 8, 2, 0xf0c0c0);
                context.fillRect(w.x + w.width -| 12, w.y + 3, 2, 8, 0xf0c0c0);
            }
            if (w.width >= 52) {
                context.fillRect(w.x + w.width -| 38, w.y + 4, 14, 12, 0x506080);
                if (w.maximized) {
                    context.fillRect(w.x + w.width -| 34, w.y + 7, 7, 5, 0xd0d8e8);
                    context.fillRect(w.x + w.width -| 32, w.y + 5, 7, 5, 0x506080);
                } else {
                    context.fillRect(w.x + w.width -| 34, w.y + 7, 7, 5, 0xd0d8e8);
                }
            }
            if (w.width >= 72) {
                context.fillRect(w.x + w.width -| 58, w.y + 4, 14, 12, 0x506080);
                context.fillRect(w.x + w.width -| 54, w.y + 12, 7, 2, 0xd0d8e8);
            }
            if (!w.maximized and w.width >= min_window_width and w.height >= min_window_height) {
                context.fillRect(w.x + w.width -| 10, w.y + w.height -| 3, 8, 1, 0x90a0b8);
                context.fillRect(w.x + w.width -| 7, w.y + w.height -| 6, 5, 1, 0x90a0b8);
                context.fillRect(w.x + w.width -| 4, w.y + w.height -| 9, 2, 1, 0x90a0b8);
            }
        }
        const taskbar_y = @as(usize, context.framebuffer.height) -| 20;
        context.fillRect(0, taskbar_y, context.framebuffer.width, 20, 0x101820);
        context.fillRect(4, taskbar_y + 3, 52, 14, if (self.launcher_open) 0x50a078 else 0x405070);
        context.drawWindowTitle(12, taskbar_y + 5, "CS");
        i = 0;
        while (i < self.count) : (i += 1) {
            const w = self.windows[i];
            const slot_x = 64 + i * 112 + 4;
            if (slot_x >= context.framebuffer.width) break;
            const slot_width = @min(@as(usize, 104), context.framebuffer.width - slot_x);
            context.fillRect(slot_x, taskbar_y + 3, slot_width, 14, if (self.focused == i and !w.minimized) 0x5070a0 else 0x303848);
            context.drawWindowTitleLimited(slot_x + 8, taskbar_y + 5, w.title, slot_width -| 16);
        }
        if (self.launcher_open and context.framebuffer.height >= launcher_menu_height + 4) {
            const menu_top = @as(usize, context.framebuffer.height) - launcher_menu_height;
            context.fillRect(4, menu_top, 176, launcher_item_count * 24 + 4, 0x182430);
            for (launcher_labels, 0..) |label, index| {
                context.fillRect(8, menu_top + 4 + index * 24, 168, 20, if (self.launcher_selection == index) 0x5070a0 else 0x304860);
                context.drawWindowTitle(16, menu_top + 9 + index * 24, label);
            }
        }
        if (self.switcher_open and self.count != 0 and context.framebuffer.width >= 144 and context.framebuffer.height >= 96) {
            const visible_slots = @min(self.count, (@as(usize, context.framebuffer.width) - 32) / 112);
            const focused_index = self.focused orelse 0;
            const first_slot = if (focused_index < visible_slots) 0 else focused_index - visible_slots + 1;
            const overlay_width = visible_slots * 112 + 16;
            const overlay_x = (@as(usize, context.framebuffer.width) - overlay_width) / 2;
            const overlay_y = @as(usize, context.framebuffer.height) / 2 -| 24;
            context.fillRect(overlay_x, overlay_y, overlay_width, 48, 0x182430);
            for (self.windows[first_slot .. first_slot + visible_slots], 0..) |window, slot| {
                const window_index = first_slot + slot;
                context.fillRect(overlay_x + 8 + slot * 112, overlay_y + 8, 104, 32, if (self.focused == window_index) 0x5070a0 else 0x303848);
                context.drawWindowTitleLimited(overlay_x + 16 + slot * 112, overlay_y + 19, window.title, 88);
            }
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
    try std.testing.expect(manager.hitTest(std.math.maxInt(usize), std.math.maxInt(usize)) == null);
    try std.testing.expect(manager.closeHitTest(1, 120, 24));
    try std.testing.expect(!manager.closeHitTest(1, 107, 24));
    try std.testing.expect(!manager.closeHitTest(1, 1000, 24));
    try std.testing.expect(manager.maximizeHitTest(1, 94, 24));
    try std.testing.expect(!manager.maximizeHitTest(1, 120, 24));
    try std.testing.expect(manager.minimizeHitTest(1, 74, 24));
    try std.testing.expect(!manager.minimizeHitTest(1, 94, 24));
    try std.testing.expect(manager.resizeHitTest(1, 126, 78));
    try std.testing.expect(!manager.resizeHitTest(1, 100, 50));
    manager.windows[1].surface = @ptrFromInt(@as(usize, 8));
    try std.testing.expectEqual(@as(?usize, 0), manager.contentListRowHitTest(1, 50, 69, 17, 11, 10, 7));
    try std.testing.expectEqual(@as(?usize, 1), manager.contentListRowHitTest(1, 50, 80, 17, 11, 10, 7));
    try std.testing.expect(manager.contentListRowHitTest(1, 50, 79, 17, 11, 10, 7) == null);
    try std.testing.expect(manager.contentListRowHitTest(1, 20, 69, 17, 11, 10, 7) == null);
    try std.testing.expect(manager.contentRectHitTest(1, 50, 56, 4, 4, 20, 10));
    try std.testing.expect(!manager.contentRectHitTest(1, 40, 56, 4, 4, 20, 10));
    try std.testing.expect(!manager.contentRectHitTest(1, 50, 56, 500, 4, 20, 10));
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
    try std.testing.expect(manager.focused == null);
    try std.testing.expect(manager.hitTest(20, 20) == null);
    try std.testing.expect(manager.launcherButtonHitTest(20, 119, 128));
    try std.testing.expect(!manager.launcherButtonHitTest(60, 119, 128));
    try std.testing.expectEqual(@as(?usize, 0), manager.taskbarHitTest(80, 119, 128));
    try std.testing.expect(manager.taskbarHitTest(168, 119, 128) == null);
    try std.testing.expect(manager.taskbarHitTest(20, 100, 128) == null);
    try std.testing.expect(manager.taskbarHitTest(300, 119, 128) == null);
    try std.testing.expect(manager.launcherItemHitTest(20, 62, 128) == null);
    manager.launcher_open = true;
    try std.testing.expectEqual(@as(?u32, 1), manager.launcherSelectedApplication());
    manager.launcher_selection = 255;
    try std.testing.expectEqual(@as(?u32, 4), manager.launcherSelectedApplication());
    manager.launcher_selection = 0;
    manager.launcherSelectNext();
    try std.testing.expectEqual(@as(?u32, 2), manager.launcherSelectedApplication());
    manager.launcherSelectNext();
    try std.testing.expectEqual(@as(?u32, 3), manager.launcherSelectedApplication());
    manager.launcherSelectNext();
    try std.testing.expectEqual(@as(?u32, 4), manager.launcherSelectedApplication());
    manager.launcherSelectNext();
    try std.testing.expectEqual(@as(?u32, 1), manager.launcherSelectedApplication());
    manager.launcherSelectPrevious();
    try std.testing.expectEqual(@as(?u32, 4), manager.launcherSelectedApplication());
    manager.launcher_selection = 0;
    try std.testing.expectEqual(@as(?u32, 1), manager.launcherItemHitTest(20, 14, 128));
    try std.testing.expectEqual(@as(?u32, 2), manager.launcherItemHitTest(20, 38, 128));
    try std.testing.expectEqual(@as(?u32, 3), manager.launcherItemHitTest(20, 62, 128));
    try std.testing.expectEqual(@as(?u32, 4), manager.launcherItemHitTest(20, 86, 128));
    try std.testing.expect(manager.launcherItemHitTest(200, 14, 128) == null);
    manager.launcher_open = false;
    try std.testing.expect(manager.launcherSelectedApplication() == null);
    manager.switcher_open = true;
    manager.launcher_open = true;
    try std.testing.expect(manager.switcher_open);
    try std.testing.expectEqual(@as(?usize, 0), manager.findById(20));
    try std.testing.expect(manager.findById(999) == null);
    try std.testing.expect(manager.focus(0));
    try std.testing.expect(!manager.windows[0].minimized);
    const third = try manager.create(.{ .id = 30, .x = 0, .y = 0, .width = 64, .height = 32 });
    try std.testing.expectEqual(@as(usize, 1), third);
    try std.testing.expect(!manager.launcher_open);
    try std.testing.expectEqual(@as(u8, 0), manager.launcher_selection);
    try std.testing.expect(!manager.switcher_open);
    try std.testing.expect(manager.focus(1));
    manager.close(0);
    try std.testing.expectEqual(@as(?usize, 0), manager.focused);
    try std.testing.expectEqual(@as(u32, 30), manager.windows[0].id);
    try std.testing.expect(manager.move(0, 100, 100, 80, 60));
    try std.testing.expectEqual(@as(usize, 16), manager.windows[0].x);
    try std.testing.expectEqual(@as(usize, 8), manager.windows[0].y);
    try std.testing.expect(manager.resize(0, 4, 200, 128, 128));
    try std.testing.expectEqual(min_window_width, manager.windows[0].width);
    try std.testing.expectEqual(@as(usize, 100), manager.windows[0].height);
    try std.testing.expect(manager.toggleMaximized(0, 128, 96));
    try std.testing.expect(manager.windows[0].maximized);
    try std.testing.expectEqual(@as(usize, 128), manager.windows[0].width);
    try std.testing.expectEqual(@as(usize, 76), manager.windows[0].height);
    try std.testing.expect(!manager.move(0, 10, 10, 128, 96));
    try std.testing.expect(!manager.resize(0, 80, 60, 128, 96));
    try std.testing.expect(manager.toggleMaximized(0, 128, 96));
    try std.testing.expect(!manager.windows[0].maximized);
    try std.testing.expectEqual(@as(usize, 76), manager.windows[0].height);
    try std.testing.expectEqual(@as(usize, 0), manager.windows[0].y);
    try std.testing.expectEqual(@as(usize, 16), manager.windows[0].x);
    try std.testing.expect(!manager.toggleMaximized(0, 32, 44));
    try std.testing.expect(!manager.move(8, 0, 0, 100, 100));
    try std.testing.expect(manager.move(0, 999, 999, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), manager.windows[0].x);
    try std.testing.expectEqual(@as(usize, 0), manager.windows[0].y);
    manager.windows[0].minimized = true;
    try std.testing.expect(manager.restore(0));
    try std.testing.expect(!manager.windows[0].minimized);
    manager.windows[0].visible = false;
    try std.testing.expect(!manager.move(0, 0, 0, 100, 100));
    try std.testing.expect(!manager.resize(0, 80, 60, 100, 100));
    try std.testing.expect(!manager.restore(0));
    try std.testing.expect(manager.altTab() == null);
    try std.testing.expect(manager.altTabReverse() == null);
    try std.testing.expect(manager.focused == null);
    const count_before_invalid_close = manager.count;
    manager.close(max_windows);
    try std.testing.expectEqual(count_before_invalid_close, manager.count);
    manager.windows[0].visible = true;
    manager.launcher_open = true;
    manager.switcher_open = true;
    manager.launcher_selection = 3;
    manager.close(0);
    try std.testing.expectEqual(@as(usize, 0), manager.count);
    try std.testing.expect(!manager.launcher_open);
    try std.testing.expect(!manager.switcher_open);
    try std.testing.expectEqual(@as(u8, 0), manager.launcher_selection);
}

test "window manager dismisses launcher when focusing a window" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 0, .y = 0, .width = 80, .height = 48 });
    _ = try manager.create(.{ .id = 2, .x = 8, .y = 8, .width = 80, .height = 48 });
    manager.launcher_open = true;
    manager.launcher_selection = 2;
    try std.testing.expect(manager.focus(0));
    try std.testing.expect(!manager.launcher_open);
    try std.testing.expectEqual(@as(u8, 0), manager.launcher_selection);
}

test "window manager rejects hit tests outside the screen" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 0, .y = 0, .width = 80, .height = 48 });
    try std.testing.expect(manager.taskbarHitTest(70, 89, 90) != null);
    try std.testing.expect(manager.taskbarHitTest(70, 90, 90) == null);
    try std.testing.expect(manager.launcherButtonHitTest(8, 75, 90));
    try std.testing.expect(!manager.launcherButtonHitTest(8, 90, 90));
    manager.launcher_open = true;
    try std.testing.expect(manager.launcherItemHitTest(8, 90, 90) == null);
}

test "window manager reset clears desktop session state" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 0, .y = 0, .width = 80, .height = 48 });
    manager.launcher_open = true;
    manager.launcher_selection = 3;
    manager.switcher_open = true;
    manager.reset();
    try std.testing.expectEqual(@as(usize, 0), manager.count);
    try std.testing.expect(manager.focused == null);
    try std.testing.expect(!manager.launcher_open and !manager.switcher_open);
    try std.testing.expectEqual(@as(u8, 0), manager.launcher_selection);
    const recreated = try manager.create(.{ .id = 2, .x = 4, .y = 4, .width = 80, .height = 48 });
    try std.testing.expectEqual(@as(usize, 0), recreated);
    try std.testing.expectEqual(@as(?usize, 0), manager.focused);
}

test "window manager dismisses switcher when closing non-last window" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 0, .y = 0, .width = 64, .height = 48 });
    _ = try manager.create(.{ .id = 2, .x = 4, .y = 4, .width = 64, .height = 48 });
    manager.switcher_open = true;
    manager.launcher_open = true;
    manager.launcher_selection = 3;
    manager.close(0);
    try std.testing.expect(!manager.switcher_open);
    try std.testing.expect(!manager.launcher_open);
    try std.testing.expectEqual(@as(u8, 0), manager.launcher_selection);
    try std.testing.expectEqual(@as(usize, 1), manager.count);
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

test "window manager can unmaximize after display shrink" {
    var manager = WindowManager{};
    _ = try manager.create(.{ .id = 1, .x = 8, .y = 8, .width = 80, .height = 48 });
    try std.testing.expect(manager.toggleMaximized(0, 128, 96));
    try std.testing.expect(manager.windows[0].maximized);
    try std.testing.expect(manager.toggleMaximized(0, 32, 44));
    try std.testing.expect(!manager.windows[0].maximized);
    try std.testing.expect(manager.windows[0].width <= 32);
}

test "window manager clamps geometry to usable screen" {
    var manager = WindowManager{};
    const index = try manager.create(.{ .id = 7, .x = 4, .y = 4, .width = 80, .height = 48 });

    try std.testing.expect(manager.move(index, 999, 999, 120, 90));
    try std.testing.expectEqual(@as(usize, 40), manager.windows[index].x);
    try std.testing.expectEqual(@as(usize, 22), manager.windows[index].y);

    try std.testing.expect(manager.resize(index, 500, 500, 120, 90));
    try std.testing.expectEqual(@as(usize, 80), manager.windows[index].width);
    try std.testing.expectEqual(@as(usize, 48), manager.windows[index].height);

    try std.testing.expect(!manager.resize(index, 80, 48, 30, 30));
    try std.testing.expect(manager.move(index, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), manager.windows[index].x);
    try std.testing.expectEqual(@as(usize, 0), manager.windows[index].y);
}

test "pointer delta saturates at both display edges" {
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(4, -5, 100));
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(50, -128, 100));
    try std.testing.expectEqual(@as(usize, 99), applyPointerDelta(96, 5, 100));
    try std.testing.expectEqual(@as(usize, 99), applyPointerDelta(1000, 0, 100));
    try std.testing.expectEqual(@as(usize, 15), applyPointerDelta(10, 5, 100));
    try std.testing.expectEqual(@as(usize, 0), applyPointerDelta(10, 5, 0));
    try std.testing.expectEqual(@as(u32, 0x4080e0), pointerWheelColor(-1));
    try std.testing.expectEqual(@as(u32, 0x80a0e0), pointerWheelColor(1));
    try std.testing.expectEqual(@as(u32, 0x506070), pointerWheelColor(0));
}

pub const Context = struct {
    framebuffer: Framebuffer,
    adapter: Adapter,
    backbuffer: u64,
    frontbuffer_shadow: u64,
    buffer_bytes: usize,
    dirty_left: usize = 0,
    dirty_top: usize = 0,
    dirty_right: usize = 0,
    dirty_bottom: usize = 0,
    frames_presented: u64 = 0,
    pixels_examined: u64 = 0,
    pixels_presented: u64 = 0,

    pub fn init(framebuffer: Framebuffer, device: pci.Device, pages: *physical.Allocator) !Context {
        if (framebuffer.base == 0 or framebuffer.width == 0 or framebuffer.height == 0) return error.InvalidFramebuffer;
        if (framebuffer.stride < framebuffer.width or framebuffer.pixel_format > 1) return error.UnsupportedFramebuffer;
        const pixels = std.math.mul(usize, @as(usize, framebuffer.stride), framebuffer.height) catch return error.InvalidFramebufferSize;
        if (pixels > framebuffer.size / 4) return error.InvalidFramebufferSize;
        const bytes = std.math.mul(usize, pixels, 4) catch return error.InvalidFramebufferSize;
        const page_count = (std.math.add(usize, bytes, 4095) catch return error.InvalidFramebufferSize) / 4096;
        const backbuffer = pages.allocate(page_count) orelse return error.OutOfMemory;
        const frontbuffer_shadow = pages.allocate(page_count) orelse {
            pages.release(backbuffer, page_count) catch {};
            return error.OutOfMemory;
        };
        const memory: [*]u8 = @ptrFromInt(backbuffer);
        @memset(memory[0..bytes], 0);
        const shadow: [*]u8 = @ptrFromInt(frontbuffer_shadow);
        @memset(shadow[0..bytes], 0);
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
            .frontbuffer_shadow = frontbuffer_shadow,
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
        const shadow: [*]u32 = @ptrFromInt(self.frontbuffer_shadow);
        const target: [*]volatile u32 = @ptrFromInt(self.framebuffer.base);
        const first_frame = self.frames_presented == 0;
        var examined: usize = 0;
        var written: usize = 0;
        var row = self.dirty_top;
        while (row < self.dirty_bottom) : (row += 1) {
            var column = self.dirty_left;
            while (column < self.dirty_right) : (column += 1) {
                const index = row * self.framebuffer.stride + column;
                const pixel = source[index];
                if (first_frame or shadow[index] != pixel) {
                    target[index] = pixel;
                    shadow[index] = pixel;
                    written +|= 1;
                }
                examined +|= 1;
            }
        }
        self.dirty_left = 0;
        self.dirty_top = 0;
        self.dirty_right = 0;
        self.dirty_bottom = 0;
        self.frames_presented = saturatingCount(self.frames_presented, 1);
        self.pixels_examined = saturatingCount(self.pixels_examined, examined);
        self.pixels_presented = saturatingCount(self.pixels_presented, written);
        return examined;
}

fn saturatingCount(value: u64, increment: u64) u64 {
    return std.math.add(u64, value, increment) catch std.math.maxInt(u64);
}

test "display telemetry counters saturate" {
    try std.testing.expectEqual(std.math.maxInt(u64), saturatingCount(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(u64, 7), saturatingCount(5, 2));
}

    pub fn blitSurface(self: *Context, surface: *sdl.Window, x: usize, y: usize) void {
        self.blitSurfaceClipped(surface, x, y, surface.width, surface.height);
    }

    pub fn blitSurfaceClipped(self: *Context, surface: *sdl.Window, x: usize, y: usize, maximum_width: usize, maximum_height: usize) void {
        const dirty = surface.dirtyRect() orelse return;
        const width = @min(dirty.width, @min(maximum_width -| dirty.x, @as(usize, self.framebuffer.width) -| (x + dirty.x)));
        const height = @min(dirty.height, @min(maximum_height -| dirty.y, @as(usize, self.framebuffer.height) -| (y + dirty.y)));
        if (width == 0 or height == 0) {
            _ = surface.consumeDirty();
            return;
        }
        const target: [*]u32 = @ptrFromInt(self.backbuffer);
        for (0..height) |row| {
            const source_start = (dirty.y + row) * surface.width + dirty.x;
            const target_start = (y + dirty.y + row) * self.framebuffer.stride + x + dirty.x;
            for (0..width) |column| {
                const destination_rgb = self.logicalColor(target[target_start + column]);
                const blended_rgb = sdl.blendRgbaOverRgb(surface.pixels[source_start + column], destination_rgb);
                target[target_start + column] = self.nativeColor(blended_rgb);
            }
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
                'C' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
                'c' => .{ 0b111, 0b100, 0b100, 0b100, 0b111 },
                'S' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
                's' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
                'O' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
                'o' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
                'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
                'r' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
                'E' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
                'e' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
                'I' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
                'i' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
                'M' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
                'm' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
                'N' => .{ 0b101, 0b111, 0b111, 0b111, 0b101 },
                'n' => .{ 0b101, 0b111, 0b111, 0b111, 0b101 },
                'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
                't' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
                'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
                'u' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
                ' ' => .{ 0, 0, 0, 0, 0 },
                '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
                '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
                '2' => .{ 0b110, 0b001, 0b010, 0b100, 0b111 },
                '3' => .{ 0b110, 0b001, 0b010, 0b001, 0b110 },
                '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
                '5' => .{ 0b111, 0b100, 0b110, 0b001, 0b110 },
                '6' => .{ 0b011, 0b100, 0b111, 0b101, 0b111 },
                '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
                '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
                '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b110 },
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

    pub fn drawWindowTitleLimited(self: *Context, x: usize, y: usize, title: []const u8, width: usize) void {
        const characters = @min(title.len, width / 8);
        self.drawWindowTitle(x, y, title[0..characters]);
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

    pub fn drawPointerWheel(self: *Context, wheel: i8) void {
        if (wheel == 0 or self.framebuffer.width < 64 or self.framebuffer.height < 176) return;
        const width = @min(@as(usize, self.framebuffer.width) -| 64, 160);
        self.fillRect(32, 168, width, 4, pointerWheelColor(wheel));
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

    fn logicalColor(self: *const Context, native: u32) u32 {
        if (self.framebuffer.pixel_format == 1) return native & 0x00ffffff;
        return ((native & 0xff) << 16) | (native & 0xff00) | ((native >> 16) & 0xff);
    }
};
