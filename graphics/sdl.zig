const std = @import("std");
const html = @import("html");
const ui_backend = @import("ui_backend");

pub const PixelFormat = enum { rgba8888 };
pub const Rect = struct { x: usize, y: usize, width: usize, height: usize };
pub const AudioSpec = struct { sample_rate: u32, channels: u8 };

/// Blend an RGBA8888 source pixel (R in the most-significant byte) over an
/// RGB888 destination. The result remains logical RGB; framebuffer byte order
/// conversion belongs to the display backend.
pub fn blendRgbaOverRgb(source: u32, destination: u32) u32 {
    const alpha = source & 0xff;
    if (alpha == 0) return destination & 0x00ffffff;
    const source_rgb = source >> 8;
    if (alpha == 0xff) return source_rgb;
    const inverse = 0xff - alpha;
    const red = (((source_rgb >> 16) & 0xff) * alpha + ((destination >> 16) & 0xff) * inverse + 127) / 255;
    const green = (((source_rgb >> 8) & 0xff) * alpha + ((destination >> 8) & 0xff) * inverse + 127) / 255;
    const blue = ((source_rgb & 0xff) * alpha + (destination & 0xff) * inverse + 127) / 255;
    return (red << 16) | (green << 8) | blue;
}

pub const Event = union(enum) {
    quit: void,
    key: struct { scancode: u8, pressed: bool, modifiers: u8 },
    text: u8,
    mouse: struct { x: i32, y: i32, wheel: i32, buttons: u8 },
};

pub const EventQueue = struct {
    pub const capacity: usize = 64;
    items: [capacity]Event = undefined,
    read: usize = 0,
    write: usize = 0,
    dropped: u64 = 0,

    pub fn push(self: *EventQueue, event: Event) bool {
        if (self.write -% self.read == self.items.len) {
            self.dropped = saturatingCount(self.dropped, 1);
            return false;
        }
        self.items[self.write % self.items.len] = event;
        self.write +%= 1;
        return true;
    }

    pub fn poll(self: *EventQueue) ?Event {
        if (self.read == self.write) return null;
        const event = self.items[self.read % self.items.len];
        self.read +%= 1;
        return event;
    }

    pub fn peek(self: *const EventQueue) ?Event {
        if (self.read == self.write) return null;
        return self.items[self.read % self.items.len];
    }

    pub fn len(self: *const EventQueue) usize {
        return self.write -% self.read;
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
        // Discard pending input but preserve the drop counter for diagnostics.
        self.read = 0;
        self.write = 0;
    }

    pub fn pushKeyboard(self: *EventQueue, scancode: u8, pressed: bool, modifiers: u8) bool {
        const event = Event{ .key = .{ .scancode = scancode, .pressed = pressed, .modifiers = modifiers } };
        if (!pressed and self.isFull()) {
            // A release must not disappear behind a burst of motion/text:
            // dropping it leaves the application believing the key is held.
            var index = self.read;
            while (index != self.write) : (index +%= 1) {
                const slot = index % self.items.len;
                if (self.items[slot] == .mouse or self.items[slot] == .text) {
                    self.items[slot] = event;
                    self.dropped = saturatingCount(self.dropped, 1);
                    return true;
                }
            }
        }
        return self.push(event);
    }

    pub fn pushText(self: *EventQueue, byte: u8) bool {
        if (self.isFull()) {
            // Texto é entrada de controle: preserve-o durante uma rajada de
            // movimento, substituindo somente movimento sem clique ou roda.
            var index = self.read;
            while (index != self.write) : (index +%= 1) {
                const slot = index % self.items.len;
                if (self.items[slot] == .mouse and self.items[slot].mouse.buttons == 0 and self.items[slot].mouse.wheel == 0) {
                    self.items[slot] = .{ .text = byte };
                    self.dropped = saturatingCount(self.dropped, 1);
                    return true;
                }
            }
        }
        return self.push(.{ .text = byte });
    }

    pub fn pushMouse(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        return self.push(.{ .mouse = .{ .x = x, .y = y, .wheel = wheel, .buttons = buttons } });
    }

    pub fn pushMouseCoalesced(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        // Never merge across a button transition: doing so could erase a click.
        if (self.write != self.read) {
            const slot = (self.write -% 1) % self.items.len;
            if (self.items[slot] == .mouse and self.items[slot].mouse.buttons == buttons) {
                self.items[slot].mouse.x = saturatingAdd(self.items[slot].mouse.x, x);
                self.items[slot].mouse.y = saturatingAdd(self.items[slot].mouse.y, y);
                self.items[slot].mouse.wheel = saturatingAdd(self.items[slot].mouse.wheel, wheel);
                self.items[slot].mouse.buttons = buttons;
                return true;
            }
        }
        if (self.isFull()) {
            // Button transitions are control input, not motion noise.  Keep
            // them observable even when a burst has filled the queue: replace
            // the oldest coalescible motion/text slot instead of dropping a
            // click or release behind stale pointer movement.
            var previous_buttons: ?u8 = null;
            var index = self.read;
            while (index != self.write) : (index +%= 1) {
                const slot = index % self.items.len;
                if (self.items[slot] == .mouse) previous_buttons = self.items[slot].mouse.buttons;
            }
            if (previous_buttons == null or previous_buttons.? != buttons) {
                index = self.read;
                while (index != self.write) : (index +%= 1) {
                    const slot = index % self.items.len;
                    if (self.items[slot] == .mouse or self.items[slot] == .text) {
                        self.items[slot] = .{ .mouse = .{ .x = x, .y = y, .wheel = wheel, .buttons = buttons } };
                        self.dropped = saturatingCount(self.dropped, 1);
                        return true;
                    }
                }
            }
        }
        return self.pushMouse(x, y, wheel, buttons);
    }

    pub fn pushQuit(self: *EventQueue) bool {
        if (self.isFull()) {
            // Encerramento é controle de vida da aplicação: preserve-o mesmo
            // sob uma rajada de input, descartando o evento mais antigo.
            self.items[self.read % self.items.len] = .{ .quit = {} };
            self.dropped = saturatingCount(self.dropped, 1);
            return true;
        }
        return self.push(.{ .quit = {} });
    }
};

pub const ListSelection = struct {
    count: usize = 0,
    selected: usize = 0,
    first_visible: usize = 0,
    visible_rows: usize,

    pub fn init(count: usize, visible_rows: usize) ListSelection {
        return .{ .count = count, .visible_rows = @max(@as(usize, 1), visible_rows) };
    }

    pub fn next(self: *ListSelection) bool {
        if (self.count == 0) return false;
        if (self.selected >= self.count) self.selected = self.count - 1;
        if (self.selected + 1 >= self.count) return false;
        self.selected += 1;
        self.reveal();
        return true;
    }

    pub fn previous(self: *ListSelection) bool {
        if (self.count == 0) return false;
        if (self.selected >= self.count) self.selected = self.count - 1;
        if (self.selected == 0) return false;
        self.selected -= 1;
        self.reveal();
        return true;
    }

    pub fn home(self: *ListSelection) bool {
        if (self.count == 0 or self.selected == 0) return false;
        self.selected = 0;
        self.first_visible = 0;
        return true;
    }

    pub fn end(self: *ListSelection) bool {
        if (self.count == 0 or self.selected + 1 >= self.count) return false;
        self.selected = self.count - 1;
        self.reveal();
        return true;
    }

    pub fn pageNext(self: *ListSelection) bool {
        if (self.count == 0) return false;
        const target = @min(self.count - 1, self.selected +| self.visible_rows);
        if (target == self.selected) return false;
        self.selected = target;
        self.reveal();
        return true;
    }

    pub fn pagePrevious(self: *ListSelection) bool {
        if (self.count == 0 or self.selected == 0) return false;
        self.selected -|= self.visible_rows;
        self.reveal();
        return true;
    }

    pub fn wheel(self: *ListSelection, delta: i16) bool {
        if (delta < 0) return self.next();
        if (delta > 0) return self.previous();
        return false;
    }

    pub fn selectVisibleRow(self: *ListSelection, row: usize) bool {
        if (row >= self.visible_rows) return false;
        if (self.count == 0) return false;
        if (self.first_visible >= self.count)
            self.first_visible = self.count -| @min(self.count, self.visible_rows);
        const index = self.first_visible +| row;
        if (index >= self.count) return false;
        const changed = self.selected != index;
        self.selected = index;
        return changed;
    }

    pub fn setCount(self: *ListSelection, count: usize) void {
        self.visible_rows = @max(@as(usize, 1), self.visible_rows);
        self.count = count;
        if (count == 0) {
            self.selected = 0;
            self.first_visible = 0;
            return;
        }
        if (self.selected >= count) self.selected = count - 1;
        const maximum_first = count -| self.visible_rows;
        self.first_visible = @min(self.first_visible, maximum_first);
        self.reveal();
    }

    fn reveal(self: *ListSelection) void {
        if (self.selected < self.first_visible) self.first_visible = self.selected;
        if (self.selected >= self.first_visible +| self.visible_rows)
            self.first_visible = self.selected - self.visible_rows + 1;
    }
};

pub fn displayTextByte(byte: u8) u8 {
    if (byte == '\t') return ' ';
    if (byte >= 0x20 and byte <= 0x7e) return byte;
    return '.';
}

pub const Pager = struct {
    total: usize = 0,
    offset: usize = 0,
    page_size: usize,

    pub fn init(page_size: usize) Pager {
        return .{ .page_size = @max(@as(usize, 1), page_size) };
    }

    pub fn reset(self: *Pager, total: usize) void {
        self.total = total;
        self.offset = 0;
    }

    pub fn next(self: *Pager) bool {
        if (self.offset > self.total) self.offset = self.total;
        if (self.offset >= self.total or self.page_size >= self.total - self.offset) return false;
        self.offset += self.page_size;
        return true;
    }

    pub fn previous(self: *Pager) bool {
        if (self.offset > self.total) self.offset = self.total;
        if (self.offset == 0) return false;
        self.offset -|= self.page_size;
        return true;
    }

    pub fn home(self: *Pager) bool {
        if (self.offset == 0) return false;
        self.offset = 0;
        return true;
    }

    pub fn end(self: *Pager) bool {
        const last = if (self.total == 0) 0 else ((self.total - 1) / self.page_size) * self.page_size;
        if (self.offset == last) return false;
        self.offset = last;
        return true;
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

    pub fn drawText(self: *Window, x: usize, y: usize, text: []const u8, color: u32) void {
        self.drawTextScaled(x, y, text, color, 2);
    }

    /// Draw built-in glyphs at an integer scale for readable headings.
    pub fn drawTextScaled(self: *Window, x: usize, y: usize, text: []const u8, color: u32, scale: usize) void {
        if (scale == 0) return;
        var cursor_x = x;
        var cursor_y = y;
        for (text) |character| {
            if (cursor_y >= self.height) break;
            if (character == '\r') {
                cursor_x = x;
                continue;
            }
            if (character == '\n') {
                cursor_x = x;
                cursor_y +|= 6 * scale;
                continue;
            }
            if (character == '\t') {
                const column = (cursor_x -| x) / 8;
                cursor_x = x +| ((column + 4) & ~@as(usize, 3)) * 8;
                if (cursor_x >= self.width) {
                    cursor_x = x;
                    cursor_y +|= 6 * scale;
                }
                continue;
            }
            const glyph_x = cursor_x;
            const glyph = glyph3x5(character);
            for (glyph, 0..) |row_bits, row| {
                const glyph_y = cursor_y +| row * scale;
                for (0..3) |column| {
                    if ((row_bits & (@as(u8, 1) << @intCast(2 - column))) != 0)
                        self.fillRect(glyph_x +| column * scale, glyph_y, scale, scale, color);
                }
            }
            cursor_x +|= 4 * scale;
            if (cursor_x >= self.width) {
                cursor_x = x;
                cursor_y +|= 6 * scale;
            }
        }
    }

    pub fn drawHtml(self: *Window, document: *const html.Document, x: usize, y: usize) void {
        self.drawHtmlFocused(document, x, y, null);
    }

    pub fn drawHtmlFocused(self: *Window, document: *const html.Document, x: usize, y: usize, focused: ?usize) void {
        var cursor_y = y;
        for (document.elements[0..document.count], 0..) |element, index| {
            const checkbox = element.kind == .input and document.isCheckbox(index);
            const text = if (checkbox) (if (element.checked) "[x]" else "[ ]") else if (element.kind == .input) document.inputText(index) else element.text;
            const color: u32 = if (element.muted) 0x7890a0ff else if (element.danger) 0xff8060ff else switch (element.kind) {
                .heading => 0x70d0ffff,
                .paragraph, .container, .line_break => 0xa0b8d0ff,
                .button => if (element.accent) 0x70e0a0ff else 0xffd070ff,
                .link => 0x70b8ffff,
                .input => 0xd0d0d0ff,
            };
            if (element.kind == .input) {
                const input_width = @max(text.len, 8) * 8 + 6;
                self.fillRect(x -| 2, cursor_y -| 2, input_width, 14, 0x182430ff);
            }
            if (focused != null and focused.? == index and (element.kind == .button or element.kind == .link or element.kind == .input)) {
                const text_width: usize = if (element.kind == .input) @max(text.len, 8) * 8 + 4 else text.len * (if (element.kind == .heading) @as(usize, 12) else 8) + 4;
                const text_height: usize = if (element.kind == .heading) 20 else 14;
                self.fillRect(x -| 2, cursor_y -| 2, text_width, text_height, 0x304860ff);
            }
            if (element.kind == .heading) self.drawTextScaled(x, cursor_y, text, color, 3) else self.drawText(x, cursor_y, text, color);
            if (focused != null and focused.? == index and element.kind == .input)
                self.fillRect(x +| text.len * 8, cursor_y, 1, 10, 0xffd070ff);
            cursor_y +|= if (element.kind == .heading) 16 else 12;
        }
    }

    pub fn consumeDirty(self: *Window) bool {
        const was_dirty = self.dirty;
        self.dirty = false;
        return was_dirty;
    }

    pub fn invalidate(self: *Window) void {
        self.markDirty(0, 0, self.width, self.height);
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
        self.dirty = true;
    }
};

/// Reference desktop composition used by the bootstrap renderer until a real
/// userspace compositor supplies these surfaces. It deliberately uses only
/// Window drawing primitives; applications still arrive through html.Session.
pub fn drawReferenceDesktop(window: *Window) void {
    const width = window.width;
    const height = window.height;
    window.clear(0x101a38ff);
    const bands = @max(@as(usize, 1), @min(@as(usize, 12), height));
    for (0..bands) |band| {
        const y = band * height / bands;
        const band_height = @max(@as(usize, 1), height / bands);
        const red: u32 = 16 + @as(u32, @intCast(band * 3));
        const blue: u32 = 48 + @as(u32, @intCast(band * 8));
        window.fillRect(0, y, width, band_height, (red << 24) | (32 << 16) | (blue << 8) | 0xff);
    }
    // Layered stepped silhouettes keep the PNG's mountain-at-dusk character
    // without requiring an image decoder in the early boot compositor.
    const horizon = height * 3 / 5;
    const mountain_color = 0x172443b8;
    for (0..8) |step| {
        const inset = step * (width / 16 + 1);
        window.fillRect(inset, horizon -| step * 10, width -| inset * 2, step * 10 + 1, mountain_color);
    }
    for (0..6) |step| {
        const inset = width / 3 + step * (width / 24 + 1);
        window.fillRect(inset, horizon + 18 -| step * 8, width -| inset, step * 8 + 1, 0x0f1b35d0);
    }
    window.fillRect(0, 0, width, @min(height, 38), 0x17294fff);
    window.drawText(18, 12, "CSOS", 0xf0f6ffff);
    window.drawText(78, 12, "Arquivo   Editar   Visualizar   Janela   Ajuda", 0xc4d5f0ff);
    window.drawText(width -| 112, 12, "Sistema Online", 0x8de0a8ff);
    window.drawText(width -| 238, 12, "WiFi  🔊   Seg, 7 de Set   18:42", 0xe1eaffff);

    // Desktop shortcuts.
    const labels = [_][]const u8{ "Home", "Sistema", "Jogos", "Lixeira" };
    for (labels, 0..) |label, index| {
        const y = 72 + index * 74;
        window.fillRect(28, y, 48, 38, if (index == 3) 0x71809aff else 0x3d9ce8ff);
        window.drawText(24, y + 46, label, 0xe1eaffff);
    }

    // FILES glass panel.
    window.fillRect(178, 66, @min(@as(usize, 690), width -| 198), @min(@as(usize, 400), height -| 150), 0x273958dd);
    window.fillRect(178, 66, @min(@as(usize, 690), width -| 198), 40, 0x17253fdd);
    window.drawText(198, 80, "●  ●  ●", 0xb0b8d0ff);
    window.drawText(290, 80, "⌂  /home/willian", 0xe5efffff);
    window.drawText(178 + @min(@as(usize, 690), width -| 198) -| 112, 80, "FILES", 0x9eb5d8ff);
    window.fillRect(178 + @min(@as(usize, 690), width -| 198) -| 18, 66 + @min(@as(usize, 400), height -| 150) -| 18, 12, 12, 0x8aa1c0cc);
    window.drawText(204, 128, "Recentes", 0x9eb5d8ff);
    window.drawText(204, 158, "Home", 0xf1f6ffff);
    window.drawText(204, 188, "Documentos", 0xb9c9e5ff);
    window.drawText(204, 218, "Downloads", 0xb9c9e5ff);
    window.drawText(204, 248, "Imagens", 0xb9c9e5ff);
    window.drawText(370, 128, "Pastas", 0xf1f6ffff);
    const folders = [_][]const u8{ "Projetos", "CSOS", "Downloads", "Imagens", "Música", "Vídeos", "Jogos", "Apps" };
    for (folders, 0..) |label, index| {
        const x = 370 + (index % 4) * 126;
        const y = 160 + (index / 4) * 86;
        window.fillRect(x, y, 52, 38, 0x47b7f0ff);
        window.drawText(x -| 4, y + 48, label, 0xe1eaffff);
    }

    // System card and terminal.
    const card_x = width -| 310;
    window.fillRect(card_x, 66, 286, 164, 0x273958dd);
    window.drawText(card_x + 22, 84, "CSOS", 0xf1f6ffff);
    window.drawText(card_x + 22, 110, "● Sistema Online", 0x7ee6a0ff);
    window.drawText(card_x + 22, 148, "CPU 32%   RAM 48%   GPU 12%", 0xc5d7f2ff);
    window.drawText(card_x + 22, 182, "Rede  ↓125 MB/s  ↑8 MB/s", 0xb7c9e7ff);
    const gauges = [_]u32{ 0x70e0a0ff, 0x8ca8ffff, 0x70e0a0ff };
    for (gauges, 0..) |color, index| {
        const gauge_x = card_x + 20 + index * 82;
        window.fillRect(gauge_x, 198, 62, 5, 0x536784cc);
        window.fillRect(gauge_x, 198, if (index == 0) 20 else if (index == 1) 30 else 8, 5, color);
    }
    const player_y = 246;
    window.fillRect(card_x, player_y, 286, 104, 0x273958dd);
    window.drawText(card_x + 18, player_y + 18, "Midnight City", 0xf1f6ffff);
    window.drawText(card_x + 18, player_y + 42, "M83", 0xb7c9e7ff);
    window.fillRect(card_x + 18, player_y + 56, 250, 4, 0x536784cc);
    window.fillRect(card_x + 18, player_y + 56, 96, 4, 0x9b7dffff);
    window.drawText(card_x + 18, player_y + 72, "|<<     ||     >>|", 0xd9e8ffff);
    const notification_x = width -| 312;
    const notification_y = @min(height -| 154, player_y + 122);
    const notifications = [_][]const u8{ "Sistema iniciado", "Rede conectada", "Download concluído", "Steam pronto" };
    for (notifications, 0..) |notification, index| {
        const y = notification_y + index * 38;
        window.fillRect(notification_x, y, 286, 30, 0x273958dd);
        window.drawText(notification_x + 14, y + 10, notification, 0xe1eaffff);
    }
    const launcher_x: usize = 24;
    const launcher_y = height -| 330;
    window.fillRect(launcher_x, launcher_y, 300, 286, 0x273958ee);
    window.fillRect(launcher_x + 16, launcher_y + 16, 268, 30, 0x17253fee);
    window.drawText(launcher_x + 28, launcher_y + 26, "Buscar aplicações, arquivos...", 0xb7c9e7ff);
    window.drawText(launcher_x + 20, launcher_y + 70, "Favoritos", 0xf1f6ffff);
    window.drawText(launcher_x + 24, launcher_y + 102, "Arquivos    Terminal    Browser", 0xe1eaffff);
    window.drawText(launcher_x + 20, launcher_y + 140, "Recentes", 0xf1f6ffff);
    window.drawText(launcher_x + 24, launcher_y + 172, "GOAL.md    dashboard.html", 0xb9c9e5ff);
    window.drawText(launcher_x + 24, launcher_y + 198, "wallpaper.png", 0xb9c9e5ff);
    window.drawText(launcher_x + 20, launcher_y + 246, "Willian                         ⏻", 0xe1eaffff);
    const term_y = height / 2 + 18;
    window.fillRect(360, term_y, @min(@as(usize, 600), width -| 380), 178, 0x101827ee);
    window.drawText(382, term_y + 18, "willian@csos:~$ neofetch", 0x6ff1e0ff);
    window.drawText(382, term_y + 48, "CSOS 0.1   Kernel: csos 0.1.0", 0x9d9beeff);
    window.drawText(382, term_y + 72, "Resolution: 1920x1080", 0xa9b9eaff);
    window.drawText(382, term_y + 96, "GPU: Virtual   Memory: 1.2GiB", 0xa9b9eaff);

    // Dock.
    const dock_width: usize = @min(620, width -| 40);
    const dock_x = (width -| dock_width) / 2;
    const dock_y = height -| 82;
    window.fillRect(dock_x, dock_y, dock_width, 58, 0x273958ee);
    const dock_labels = [_][]const u8{ "Finder", "Apps", "Files", "Terminal", "Browser", "Music", "Steam", "⚙" };
    for (dock_labels, 0..) |label, index| window.drawText(dock_x + 18 + index * 72, dock_y + 22, label, 0xf1f6ffff);
    window.fillRect(dock_x + 18 + 2 * 72, dock_y + 48, 34, 3, 0x70d0ffff);
    window.fillRect(dock_x + 18 + 3 * 72, dock_y + 48, 34, 3, 0x70d0ffff);
    window.invalidate();
}

pub const Application = struct {
    window: Window,
    html_session: ?html.Session = null,
    backend: ?ui_backend.Backend = null,
    running: bool = true,
    last_event: ?Event = null,
    processed_events: u64 = 0,
    last_html_activation: ?[]const u8 = null,
    html_origin_x: usize = 0,
    html_origin_y: usize = 0,
    pointer_x: usize = 0,
    pointer_y: usize = 0,

    pub const reference_desktop_source = "<style>.accent{color:#70d0ff}.muted{color:#8de0a8}</style><h1 class=accent>CSOS</h1><input value=\"Buscar aplicações, arquivos...\"><p class=muted>● Sistema Online</p><p>Recentes   Home   Documentos   Downloads   Imagens   Música</p><p>Pastas</p><a href=\"projetos\">Projetos</a><a href=\"csos\">CSOS</a><a href=\"downloads\">Downloads</a><a href=\"imagens\">Imagens</a><p>Arquivos</p><a href=\"GOAL.md\">GOAL.md</a><a href=\"README.md\">README.md</a><a href=\"config.sys\">config.sys</a><p>CPU 32%   RAM 48%   GPU 12%   Rede 125 MB/s</p><a href=\"files\">Arquivos</a><a href=\"terminal\">Terminal</a><a href=\"browser\">Browser</a>";

    pub fn pump(self: *Application, events: *EventQueue, on_event: *const fn (*Application, Event) void) void {
        while (events.poll()) |event| {
            self.last_event = event;
            self.processed_events +|= 1;
            if (event == .quit) self.running = false;
            on_event(self, event);
            if (!self.running) break;
        }
    }

    /// Dispatch queued input to the active HTML document and retain the last
    /// action target for the host application to consume.
    pub fn pumpHtml(self: *Application, events: *EventQueue) void {
        while (events.poll()) |event| {
            self.last_event = event;
            self.processed_events +|= 1;
            switch (event) {
                .quit => self.running = false,
                .text => |byte| {
                    if (self.backend) |*backend| _ = backend.enqueueEvent(.{ .key = .{ .code = byte, .pressed = true, .modifiers = 0 } });
                    _ = self.handleHtmlKey(byte);
                },
                .key => |key| if (key.pressed) {
                    if (self.backend) |*backend| _ = backend.enqueueEvent(.{ .key = .{ .code = key.scancode, .pressed = key.pressed, .modifiers = key.modifiers } });
                    if (key.scancode == 0x29) {
                        self.startReferenceDesktop();
                        continue;
                    }
                    if (key.scancode == 0x2b) _ = self.focusHtmlNext((key.modifiers & 0x01) == 0);
                    switch (self.activateHtmlEventKey(key.scancode)) {
                        .action => |target| {
                            self.last_html_activation = target;
                            _ = self.dispatchReferenceAction(target);
                        },
                        else => {},
                    }
                },
                .mouse => |mouse| {
                    self.pointer_x = @intCast(@max(mouse.x, 0));
                    self.pointer_y = @intCast(@max(mouse.y, 0));
                    if (self.backend) |*backend| {
                        _ = backend.enqueueEvent(if (mouse.wheel != 0) .{ .wheel = .{ .delta = mouse.wheel } } else .{ .pointer = .{ .x = mouse.x, .y = mouse.y, .buttons = mouse.buttons } });
                    }
                    if ((mouse.buttons & 1) != 0) {
                        switch (self.activateHtmlEvent(
                            @intCast(@max(mouse.x, 0)), @intCast(@max(mouse.y, 0)), self.html_origin_x, self.html_origin_y,
                        )) {
                            .action => |target| {
                                self.last_html_activation = target;
                                _ = self.dispatchReferenceAction(target);
                            },
                            else => if (self.dispatchReferenceDock(@intCast(@max(mouse.x, 0)), @intCast(@max(mouse.y, 0)))) |target| {
                                self.last_html_activation = target;
                                _ = self.dispatchReferenceAction(target);
                            } else if (dispatchReferenceShortcut(@intCast(@max(mouse.x, 0)), @intCast(@max(mouse.y, 0)))) |target| {
                                self.last_html_activation = target;
                                _ = self.dispatchReferenceAction(target);
                            },
                        }
                    }
                },
            }
            if (!self.running) break;
        }
    }

    pub fn takeHtmlActivation(self: *Application) ?[]const u8 {
        const target = self.last_html_activation;
        self.last_html_activation = null;
        self.html_origin_x = 0;
        self.html_origin_y = 0;
        return target;
    }

    pub fn takeLastEvent(self: *Application) ?Event {
        const event = self.last_event;
        self.last_event = null;
        return event;
    }

    pub fn takeProcessedEvents(self: *Application) u64 {
        const processed = self.processed_events;
        self.processed_events = 0;
        self.last_html_activation = null;
        return processed;
    }

    pub fn reset(self: *Application) void {
        self.running = true;
        self.html_session = null;
        if (self.backend) |*backend| _ = backend.stop();
        self.backend = null;
        self.last_event = null;
        self.processed_events = 0;
        self.window.clear(0);
    }

    pub fn startHtml(self: *Application, source: []const u8) void {
        self.html_session = html.Session.init(source);
        self.backend = ui_backend.Backend.init(.{ .id = 1, .width = @intCast(self.window.width), .height = @intCast(self.window.height), .stride = @intCast(self.window.width), .pixels = self.window.pixels });
        _ = self.backend.?.start();
        self.window.invalidate();
    }

    /// Starts the PNG-inspired desktop through the engine-neutral HTML path.
    /// The native shell remains the fallback backdrop; controls are owned by
    /// the existing HTML session and therefore keep keyboard/mouse behavior.
    pub fn startReferenceDesktop(self: *Application) void {
        self.html_origin_x = 196;
        self.html_origin_y = 92;
        self.startHtml(reference_desktop_source);
    }

    /// Paints the reference shell and overlays the interactive HTML surface.
    pub fn renderReferenceDesktop(self: *Application) bool {
    if (!self.running) return false;
    drawReferenceDesktop(&self.window);
    if (self.html_session) |*session| {
        // The HTML surface owns the controls, while the native shell supplies
        // the translucent card behind them until a GPU compositor is active.
        self.window.fillRect(self.html_origin_x -| 14, self.html_origin_y -| 14, 470, 232, 0x14243bd9);
        self.window.drawHtmlFocused(&session.document, self.html_origin_x, self.html_origin_y, session.focused);
        }
        const dock_width = @min(@as(usize, 620), self.window.width -| 40);
        const dock_x = (self.window.width -| dock_width) / 2;
        const dock_y = self.window.height -| 82;
        if (self.pointer_x >= dock_x +| 18 and self.pointer_x < dock_x +| 18 +| 8 * 72 and self.pointer_y >= dock_y and self.pointer_y < dock_y +| 58) {
            const item = (self.pointer_x - (dock_x + 18)) / 72;
            self.window.fillRect(dock_x + 12 + item * 72, dock_y + 8, 52, 38, 0x70d0ff38);
        }
        self.window.fillRect(self.pointer_x, self.pointer_y, 2, 12, 0xf1f6ffff);
        self.window.fillRect(self.pointer_x, self.pointer_y, 8, 2, 0xf1f6ffff);
        if (self.backend) |*backend| _ = backend.present(.{ .x = 0, .y = 0, .width = @intCast(self.window.width), .height = @intCast(self.window.height) });
        return true;
    }

    /// Routes desktop launcher targets into the existing HTML application
    /// surface. The compositor stays unchanged; each target gets a new
    /// document in the same backend session.
    pub fn dispatchReferenceAction(self: *Application, target: []const u8) bool {
        const source = if (std.mem.eql(u8, target, "files"))
            "<h1>FILES</h1><p class=muted>/home/willian</p><a href=\"GOAL.md\">GOAL.md</a><a href=\"README.md\">README.md</a><a href=\"config.sys\">config.sys</a>"
        else if (std.mem.eql(u8, target, "terminal"))
            "<h1>Terminal</h1><p class=muted>willian@csos:~$</p><input value=\"\">"
        else if (std.mem.eql(u8, target, "browser"))
            "<h1>Browser</h1><input value=\"https://csos.local\"><p>CSOS Web</p>"
        else if (std.mem.eql(u8, target, "settings"))
            "<h1>Configurações</h1><p>Display   Audio   Rede   Energia</p>"
        else if (std.mem.eql(u8, target, "music"))
            "<h1>Música</h1><p>Midnight City — M83</p><a href=\"pause\">||</a>"
        else if (std.mem.eql(u8, target, "steam"))
            "<h1>Jogos</h1><p class=muted>Steam está pronto</p><a href=\"steam\">Abrir Steam</a>"
        else return false;
        self.startHtml(source);
        return true;
    }

    fn dispatchReferenceDock(self: *Application, x: usize, y: usize) ?[]const u8 {
        const dock_width = @min(@as(usize, 620), self.window.width -| 40);
        const dock_x = (self.window.width -| dock_width) / 2;
        const dock_y = self.window.height -| 82;
        if (y < dock_y or y >= dock_y +| 58 or x < dock_x +| 18 or x >= dock_x +| 18 +| 8 * 72) return null;
        const index = (x - (dock_x + 18)) / 72;
        return switch (index) {
            2 => "files",
            3 => "terminal",
            4 => "browser",
            5 => "music",
            else => null,
        };
    }

    fn dispatchReferenceShortcut(x: usize, y: usize) ?[]const u8 {
        if (x < 20 or x >= 92) return null;
        if (y < 64 or y >= 72 + 4 * 74) return null;
        const index = (y - 64) / 74;
        return switch (index) {
            0 => "files",
            1 => "settings",
            2 => "steam",
            3 => "files",
            else => null,
        };
    }

    pub fn handleHtmlKey(self: *Application, key: u8) bool {
        if (self.html_session) |*session| return session.handleKey(key);
        return false;
    }

    /// Activates an HTML control under pointer coordinates and updates focus.
    pub fn activateHtmlAt(self: *Application, x: usize, y: usize, origin_x: usize, origin_y: usize) ?[]const u8 {
        if (self.html_session) |*session| return session.activateAt(x, y, origin_x, origin_y);
        return null;
    }

    pub fn activateHtmlEvent(self: *Application, x: usize, y: usize, origin_x: usize, origin_y: usize) html.Activation {
        if (self.html_session) |*session| return session.activateEvent(x, y, origin_x, origin_y);
        return .none;
    }

    pub fn activateFocusedHtml(self: *const Application) ?[]const u8 {
        if (self.html_session) |session| return session.activateFocused();
        return null;
    }

    pub fn activateHtmlKey(self: *Application, key: u8) ?[]const u8 {
        if (self.html_session) |session| return session.activateKey(key);
        return null;
    }

    pub fn activateHtmlEventKey(self: *Application, key: u8) html.Activation {
        if (self.html_session) |*session| {
            return if (session.activateKey(key)) |target| .{ .action = target } else .none;
        }
        return .none;
    }

    pub fn focusHtmlNext(self: *Application, forward: bool) ?usize {
        if (self.html_session) |*session| return session.focusNext(forward);
        return null;
    }

    pub fn render(self: *Application, draw: *const fn (*Window) void) bool {
        if (!self.running) return false;
        draw(&self.window);
        if (self.window.dirtyRect()) |rect| {
            if (self.backend) |*backend| _ = backend.present(.{ .x = @intCast(rect.x), .y = @intCast(rect.y), .width = @intCast(rect.width), .height = @intCast(rect.height) });
            return true;
        }
        return false;
    }

    pub fn frame(self: *Application, events: *EventQueue, on_event: *const fn (*Application, Event) void, draw: *const fn (*Window) void) bool {
        self.pump(events, on_event);
        if (!self.running) return false;
        return self.render(draw);
    }
};

/// Lightweight desktop stacking model. Windows are owned by the caller;
/// this manager only tracks stacking and focus order.
pub const WindowManager = struct {
    pub const capacity: usize = 16;
    windows: [capacity]*Window = undefined,
    positions: [capacity]struct { x: i32, y: i32 } = undefined,
    count: usize = 0,
    focused: usize = 0,
    dragging: ?usize = null,
    drag_offset: struct { x: i32, y: i32 } = .{ .x = 0, .y = 0 },

    pub fn add(self: *WindowManager, window: *Window) !void {
        if (self.count == capacity) return error.TooManyWindows;
        self.windows[self.count] = window;
        self.positions[self.count] = .{ .x = 0, .y = 0 };
        self.count += 1;
        self.focused = self.count - 1;
    }

    pub fn remove(self: *WindowManager, window: *Window) bool {
        for (self.windows[0..self.count], 0..) |candidate, index| {
            if (candidate != window) continue;
            for (index + 1..self.count) |move| self.windows[move - 1] = self.windows[move];
            for (index + 1..self.count) |move| self.positions[move - 1] = self.positions[move];
            self.count -= 1;
            if (self.dragging) |drag| {
                if (drag == index) self.dragging = null else if (drag > index) self.dragging = drag - 1;
            }
            if (self.count == 0) self.focused = 0 else if (self.focused >= self.count) self.focused = self.count - 1;
            return true;
        }
        return false;
    }

    pub fn focus(self: *WindowManager, index: usize) bool {
        if (index >= self.count) return false;
        self.focused = index;
        return true;
    }

    pub fn moveTo(self: *WindowManager, index: usize, x: i32, y: i32) bool {
        if (index >= self.count) return false;
        self.positions[index] = .{ .x = x, .y = y };
        return true;
    }

    pub fn resize(self: *WindowManager, index: usize, width: usize, height: usize) bool {
        if (index >= self.count or width == 0 or height == 0) return false;
        const window = self.windows[index];
        const new_width = @max(width, 16);
        const new_height = @max(height, 16);
        // Window storage is caller-owned; resize is supported when the
        // existing surface already has capacity for the requested geometry.
        if (new_width * new_height > window.pixels.len) return false;
        const old_width = window.width;
        const old_height = window.height;
        if (new_width > old_width) {
            var row = @min(old_height, new_height);
            while (row > 0) {
                row -= 1;
                std.mem.copyBackwards(u32, window.pixels[row * new_width .. row * new_width + old_width], window.pixels[row * old_width .. row * old_width + old_width]);
            }
        } else if (new_width < old_width) for (0..@min(old_height, new_height)) |row|
            std.mem.copyForwards(u32, window.pixels[row * new_width .. row * new_width + new_width], window.pixels[row * old_width .. row * old_width + new_width]);
        window.width = new_width;
        window.height = new_height;
        if (new_width > old_width) for (0..@min(old_height, new_height)) |row|
            @memset(window.pixels[row * new_width + old_width .. row * new_width + new_width], 0);
        if (new_height > old_height) for (old_height..new_height) |row|
            @memset(window.pixels[row * new_width .. row * new_width + new_width], 0);
        window.markDirty(0, 0, new_width, new_height);
        return true;
    }

    pub fn hitTest(self: *const WindowManager, x: i32, y: i32) ?usize {
        var index = self.count;
        while (index > 0) {
            index -= 1;
            const position = self.positions[index];
            if (x >= position.x and y >= position.y and
                x - position.x < @as(i32, @intCast(self.windows[index].width)) and
                y - position.y < @as(i32, @intCast(self.windows[index].height))) return index;
        }
        return null;
    }

    pub fn click(self: *WindowManager, x: i32, y: i32) ?*Window {
        const index = self.hitTest(x, y) orelse return null;
        _ = self.raise(index);
        self.dragging = self.focused;
        self.drag_offset = .{ .x = x - self.positions[self.focused].x, .y = y - self.positions[self.focused].y };
        return self.focusedWindow();
    }

    pub fn dragTo(self: *WindowManager, x: i32, y: i32) bool {
        const index = self.dragging orelse return false;
        self.positions[index] = .{ .x = x - self.drag_offset.x, .y = y - self.drag_offset.y };
        return true;
    }

    pub fn endDrag(self: *WindowManager) void {
        self.dragging = null;
    }

    pub fn focusedWindow(self: *const WindowManager) ?*Window {
        return if (self.count == 0) null else self.windows[self.focused];
    }

    pub fn focusedIndex(self: *const WindowManager) ?usize {
        return if (self.count == 0) null else self.focused;
    }

    pub fn windowPosition(self: *const WindowManager, index: usize) ?struct { x: i32, y: i32 } {
        return if (index < self.count) self.positions[index] else null;
    }

    pub fn altTab(self: *WindowManager, reverse: bool) ?*Window {
        if (self.count == 0) return null;
        self.focused = if (reverse) (self.focused + self.count - 1) % self.count else (self.focused + 1) % self.count;
        return self.windows[self.focused];
    }

    pub fn raise(self: *WindowManager, index: usize) bool {
        if (index >= self.count) return false;
        const selected = self.windows[index];
        const selected_position = self.positions[index];
        for (index + 1..self.count) |move| self.windows[move - 1] = self.windows[move];
        for (index + 1..self.count) |move| self.positions[move - 1] = self.positions[move];
        self.windows[self.count - 1] = selected;
        self.positions[self.count - 1] = selected_position;
        self.focused = self.count - 1;
        return true;
    }

    /// Composite the stack from back to front into a destination surface.
    /// All windows are clipped to the destination; alpha is blended in RGB.
    pub fn compose(self: *const WindowManager, destination: *Window) void {
        destination.clear(0);
        for (self.windows[0..self.count], 0..) |source, window_index| {
            const position = self.positions[window_index];
            for (0..source.height) |row| for (0..source.width) |column| {
                const target_x = @as(i64, position.x) + @as(i64, @intCast(column));
                const target_y = @as(i64, position.y) + @as(i64, @intCast(row));
                if (target_x < 0 or target_y < 0 or target_x >= destination.width or target_y >= destination.height) continue;
                const index = @as(usize, @intCast(target_y)) * destination.width + @as(usize, @intCast(target_x));
                destination.pixels[index] = blendRgbaOverRgb(source.pixels[row * source.width + column], destination.pixels[index]);
            };
        }
        destination.markDirty(0, 0, destination.width, destination.height);
    }
};

pub const TextInput = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn insert(self: *TextInput, byte: u8) bool {
        if (byte < 0x20 or byte > 0x7e or self.len == self.bytes.len) return false;
        self.cursor = @min(self.cursor, self.len);
        var index = self.len;
        while (index > self.cursor) : (index -= 1) self.bytes[index] = self.bytes[index - 1];
        self.bytes[self.cursor] = byte;
        self.cursor += 1;
        self.len += 1;
        if (self.len < self.bytes.len) self.bytes[self.len] = 0;
        return true;
    }

    pub fn backspace(self: *TextInput) bool {
        self.cursor = @min(self.cursor, self.len);
        if (self.cursor == 0) return false;
        var index = self.cursor - 1;
        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];
        self.cursor -= 1;
        self.len -= 1;
        self.bytes[self.len] = 0;
        return true;
    }

    pub fn delete(self: *TextInput) bool {
        self.cursor = @min(self.cursor, self.len);
        if (self.cursor >= self.len) return false;
        var index = self.cursor;
        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];
        self.len -= 1;
        self.bytes[self.len] = 0;
        return true;
    }

    pub fn replace(self: *TextInput, text: []const u8) void {
        const old_len = @min(self.len, self.bytes.len);
        self.len = @min(text.len, self.bytes.len);
        @memmove(self.bytes[0..self.len], text[0..self.len]);
        if (old_len > self.len) @memset(self.bytes[self.len..old_len], 0);
        if (self.len < self.bytes.len) self.bytes[self.len] = 0;
        self.cursor = self.len;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor = 0;
        @memset(&self.bytes, 0);
    }

    pub fn eraseToEnd(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        @memset(self.bytes[self.cursor..self.len], 0);
        self.len = self.cursor;
    }

    pub fn eraseWordBackward(self: *TextInput) void {
        self.len = @min(self.len, self.bytes.len);
        self.cursor = @min(self.cursor, self.len);
        const old_cursor = self.cursor;
        while (self.cursor > 0 and isWordSeparator(self.bytes[self.cursor - 1])) : (self.cursor -= 1) {}
        while (self.cursor > 0 and !isWordSeparator(self.bytes[self.cursor - 1])) : (self.cursor -= 1) {}
        const old_len = self.len;
        const tail = old_len - old_cursor;
        if (tail > 0) @memmove(self.bytes[self.cursor..self.cursor + tail], self.bytes[old_cursor..old_len]);
        self.len = self.cursor + tail;
        @memset(self.bytes[self.len..old_len], 0);
    }

    pub fn moveLeft(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        self.cursor -|= 1;
    }

    pub fn moveRight(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        self.cursor = @min(self.len, self.cursor + 1);
    }

    pub fn moveWordLeft(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        while (self.cursor > 0 and isWordSeparator(self.bytes[self.cursor - 1])) : (self.cursor -= 1) {}
        while (self.cursor > 0 and !isWordSeparator(self.bytes[self.cursor - 1])) : (self.cursor -= 1) {}
    }

    pub fn moveWordRight(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        while (self.cursor < self.len and !isWordSeparator(self.bytes[self.cursor])) : (self.cursor += 1) {}
        while (self.cursor < self.len and isWordSeparator(self.bytes[self.cursor])) : (self.cursor += 1) {}
    }

    pub fn moveHome(self: *TextInput) void {
        self.cursor = 0;
    }

    pub fn moveEnd(self: *TextInput) void {
        self.cursor = self.len;
    }

    pub fn slice(self: *const TextInput) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Terminal = struct {
    pub const FileReader = *const fn (path: []const u8, output: []u8) ?[]const u8;
    pub const DirectoryReader = *const fn (output: []u8) ?[]const u8;
    pub const StatReader = *const fn (path: []const u8, output: []u8) ?[]const u8;
    pub const FileWriter = *const fn (path: []const u8, contents: []const u8, append: bool) bool;
    pub const FileRemover = *const fn (path: []const u8) bool;
    pub const FileCopier = *const fn (source: []const u8, destination: []const u8) bool;
    pub const FileMover = *const fn (source: []const u8, destination: []const u8) bool;
    pub const ProgramRunner = *const fn (command: []const u8) ?u8;
    input: TextInput = .{},
    output: [256]u8 = undefined,
    file_reader: ?FileReader = null,
    directory_reader: ?DirectoryReader = null,
    stat_reader: ?StatReader = null,
    file_writer: ?FileWriter = null,
    file_remover: ?FileRemover = null,
    file_copier: ?FileCopier = null,
    file_mover: ?FileMover = null,
    program_runner: ?ProgramRunner = null,
    file_scratch: [128]u8 = undefined,
    output_len: usize = 0,
    history: [4][64]u8 = undefined,
    history_lengths: [4]u8 = .{0} ** 4,
    history_len: usize = 0,
    history_cursor: usize = 0,

    pub fn submit(self: *Terminal) bool {
        const command = trimCommand(self.input.slice());
        if (command.len == 0) return false;
        self.remember(command);
            if (bytesEqualIgnoreCase(command, "clear")) {
                self.clearOutput();
            } else if (bytesEqualIgnoreCase(command, "reset")) {
                self.clearOutput();
                self.history_len = 0;
                self.history_cursor = 0;
            } else {
            self.append("> ");
            self.append(command);
            self.append("\n");
            if (bytesEqualIgnoreCase(command, "help"))
                self.append("HELP CLEAR RESET STATUS VERSION WHOAMI PWD LS CAT STAT RM CP MV TOUCH RUN HTTP FRAMEBUFFER DRM LIBDRM RADV GPU ECHO HISTORY [TEXT] ECHO > FILE\n")
            else if (bytesEqualIgnoreCase(command, "status"))
                self.append("CSOS READY\n")
            else if (bytesEqualIgnoreCase(command, "version"))
                self.append("CSOS 0.1\n")
            else if (bytesEqualIgnoreCase(command, "whoami"))
                self.append("root\n")
            else if (bytesEqualIgnoreCase(command, "pwd"))
                self.append("/\n")
            else if (bytesEqualIgnoreCase(command, "ls")) {
                if (self.directory_reader) |reader| {
                    if (reader(&self.file_scratch)) |listing| self.append(listing) else self.append("ls: READ ERROR\n");
                } else self.append("SYSTEM.TXT  BOOT.CFG  CONFIG/\n");
            }
            else if (command.len >= 5 and bytesEqualIgnoreCase(command[0..5], "stat ")) {
                const path = trimCommand(command[5..]);
                if (self.stat_reader) |reader| {
                    if (reader(path, &self.file_scratch)) |metadata| self.append(metadata) else self.append("stat: FILE NOT FOUND\n");
                } else self.append("stat: VFS UNAVAILABLE\n");
            }
            else if (command.len >= 4 and bytesEqualIgnoreCase(command[0..4], "cat ")) {
                const path = trimCommand(command[4..]);
                if (path.len == 0) {
                    self.append("cat: MISSING FILE\n");
                } else if (self.file_reader) |reader| {
                    if (reader(path, &self.file_scratch)) |contents| {
                        self.append(contents);
                        if (contents.len == 0 or contents[contents.len - 1] != '\n') self.append("\n");
                    } else self.append("cat: FILE NOT FOUND\n");
                } else if (bytesEqualIgnoreCase(path, "hello.txt") or bytesEqualIgnoreCase(path, "/hello.txt")) {
                    self.append("Hello from initramfs\n");
                } else self.append("cat: FILE NOT FOUND\n");
            }
            else if (command.len >= 3 and bytesEqualIgnoreCase(command[0..3], "rm ")) {
                const path = trimCommand(command[3..]);
                if (path.len == 0) self.append("rm: MISSING FILE\n") else if (self.file_remover) |remover| {
                    if (remover(path)) self.append("OK\n") else self.append("rm: FILE NOT FOUND\n");
                } else self.append("rm: VFS UNAVAILABLE\n");
            }
            else if (command.len >= 3 and bytesEqualIgnoreCase(command[0..3], "cp ")) {
                const args = trimCommand(command[3..]);
                var split: ?usize = null;
                for (args, 0..) |byte, index| if (byte == ' ' or byte == '\t') { split = index; break; };
                if (split) |at| {
                    const source = trimCommand(args[0..at]);
                    const destination = trimCommand(args[at..]);
                    if (source.len == 0 or destination.len == 0) self.append("cp: MISSING FILE\n") else if (self.file_copier) |copier| {
                        if (copier(source, destination)) self.append("OK\n") else self.append("cp: COPY ERROR\n");
                    } else self.append("cp: VFS UNAVAILABLE\n");
                } else self.append("cp: MISSING DESTINATION\n");
            }
            else if (command.len >= 3 and bytesEqualIgnoreCase(command[0..3], "mv ")) {
                const args = trimCommand(command[3..]);
                var split: ?usize = null;
                for (args, 0..) |byte, index| if (byte == ' ' or byte == '\t') { split = index; break; };
                if (split) |at| {
                    const source = trimCommand(args[0..at]);
                    const destination = trimCommand(args[at..]);
                    if (source.len == 0 or destination.len == 0) self.append("mv: MISSING FILE\n") else if (self.file_mover) |mover| {
                        if (mover(source, destination)) self.append("OK\n") else self.append("mv: MOVE ERROR\n");
                    } else self.append("mv: VFS UNAVAILABLE\n");
                } else self.append("mv: MISSING DESTINATION\n");
            }
            else if (command.len >= 6 and bytesEqualIgnoreCase(command[0..6], "touch ")) {
                const path = trimCommand(command[6..]);
                if (path.len == 0) self.append("touch: MISSING FILE\n") else if (self.file_writer) |writer| {
                    if (writer(path, "", false)) self.append("OK\n") else self.append("touch: WRITE ERROR\n");
                } else self.append("touch: VFS UNAVAILABLE\n");
            }
            else if (command.len >= 4 and bytesEqualIgnoreCase(command[0..4], "run ")) {
                const program = trimCommand(command[4..]);
                if (program.len == 0) self.append("run: MISSING PROGRAM\n") else if (self.program_runner) |runner| {
                    if (runner(program)) |status| {
                        var status_text: [24]u8 = undefined;
                        const rendered = @import("std").fmt.bufPrint(&status_text, "PROGRAM EXITED {d}\n", .{status}) catch "PROGRAM EXITED\n";
                        self.append(rendered);
                    } else self.append("run: PROGRAM FAILED\n");
                } else self.append("run: USERSPACE UNAVAILABLE\n");
            }
            else if (bytesEqualIgnoreCase(command, "echo"))
                self.append("ECHO READY\n")
            else if (bytesEqualIgnoreCase(command, "history")) {
                self.append("HISTORY\n");
                for (self.history[0..self.history_len], 0..) |entry, index| {
                    self.append("  ");
                    self.append(entry[0..self.history_lengths[index]]);
                    self.append("\n");
                }
            }
            else if (command.len > 5 and bytesEqualIgnoreCase(command[0..5], "echo ")) {
                const body = command[5..];
                if (findRedirect(body)) |redirect| {
                    const text = trimCommand(body[0..redirect]);
                    const append_mode = redirect + 1 < body.len and body[redirect + 1] == '>';
                    const path_start = redirect + 1 + @intFromBool(append_mode);
                    const path = trimCommand(body[path_start..]);
                    if (path.len == 0) self.append("echo: MISSING FILE\n") else if (self.file_writer) |writer| {
                        if (writer(path, text, append_mode)) self.append("OK\n") else self.append("echo: WRITE ERROR\n");
                    } else self.append("echo: VFS UNAVAILABLE\n");
                } else {
                    self.append(body);
                    self.append("\n");
                }
            }
            else
                self.append("UNKNOWN COMMAND\n");
        }
        self.input.clear();
        self.history_cursor = self.history_len;
        return true;
    }

    pub fn cancel(self: *Terminal) void {
        self.input.clear();
        self.history_cursor = self.history_len;
    }

    pub fn clearOutput(self: *Terminal) void {
        self.output_len = 0;
    }

    pub fn outputSlice(self: *const Terminal) []const u8 {
        return self.output[0..@min(self.output_len, self.output.len)];
    }

    pub fn outputTailLines(self: *const Terminal, max_lines: usize) []const u8 {
        const output_len = @min(self.output_len, self.output.len);
        if (max_lines == 0) return self.output[output_len..output_len];
        var boundaries: usize = 0;
        var index = output_len;
        if (index > 0 and self.output[index - 1] == '\n') index -= 1;
        while (index > 0) {
            index -= 1;
            if (self.output[index] == '\n') {
                boundaries += 1;
                if (boundaries == max_lines) return self.output[index + 1 .. output_len];
            }
        }
        return self.output[0..output_len];
    }

    pub fn historyPrevious(self: *Terminal) bool {
        if (self.history_len == 0) return false;
        self.history_cursor = @min(self.history_cursor, self.history_len);
        if (self.history_cursor > 0) self.history_cursor -= 1;
        self.loadHistory(self.history_cursor);
        return true;
    }

    pub fn historyNext(self: *Terminal) bool {
        self.history_cursor = @min(self.history_cursor, self.history_len);
        if (self.history_cursor >= self.history_len) return false;
        self.history_cursor += 1;
        if (self.history_cursor == self.history_len) self.input.replace("") else self.loadHistory(self.history_cursor);
        return true;
    }

    fn remember(self: *Terminal, command: []const u8) void {
        if (self.history_len == self.history.len) {
            for (1..self.history.len) |index| {
                self.history[index - 1] = self.history[index];
                self.history_lengths[index - 1] = self.history_lengths[index];
            }
            self.history_len -= 1;
        }
        const length = @min(command.len, self.history[0].len);
        @memcpy(self.history[self.history_len][0..length], command[0..length]);
        self.history_lengths[self.history_len] = @intCast(length);
        self.history_len += 1;
    }

    fn loadHistory(self: *Terminal, index: usize) void {
        const length = self.history_lengths[index];
        self.input.replace(self.history[index][0..length]);
    }

    fn append(self: *Terminal, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.output_len == self.output.len) {
                for (1..self.output.len) |index| self.output[index - 1] = self.output[index];
                self.output_len -= 1;
            }
            self.output[self.output_len] = byte;
            self.output_len += 1;
        }
    }

    pub fn appendProgramOutput(self: *Terminal, bytes: []const u8) void {
        self.append(bytes);
    }
};

fn trimCommand(bytes: []const u8) []const u8 {
    var first: usize = 0;
    while (first < bytes.len and (bytes[first] == ' ' or bytes[first] == '\t')) : (first += 1) {}
    var last = bytes.len;
    while (last > first and (bytes[last - 1] == ' ' or bytes[last - 1] == '\t')) : (last -= 1) {}
    return bytes[first..last];
}

fn findRedirect(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, index| if (byte == '>') return index;
    return null;
}

fn isWordSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn bytesEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |lhs, rhs| {
        if (asciiLower(lhs) != asciiLower(rhs)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn saturatingAdd(left: i32, right: i32) i32 {
    return std.math.add(i32, left, right) catch if (right < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

fn saturatingCount(value: u64, increment: u64) u64 {
    return std.math.add(u64, value, increment) catch std.math.maxInt(u64);
}

pub const AudioDevice = struct {
    spec: AudioSpec,
    queued_frames: u64 = 0,
    paused: bool = false,

    pub fn init(spec: AudioSpec) !AudioDevice {
        if (spec.sample_rate == 0 or spec.channels == 0 or spec.channels > 8) return error.InvalidAudioSpec;
        return .{ .spec = spec };
    }

    pub fn reconfigure(self: *AudioDevice, spec: AudioSpec) !void {
        if (spec.sample_rate == 0 or spec.channels == 0 or spec.channels > 8) return error.InvalidAudioSpec;
        if (self.queued_frames != 0 and (spec.sample_rate != self.spec.sample_rate or spec.channels != self.spec.channels))
            return error.AudioQueued;
        self.spec = spec;
    }

    pub fn queue(self: *AudioDevice, frames: u64) u64 {
        // Return the post-operation depth so callers can apply backpressure.
        const result = @addWithOverflow(self.queued_frames, frames);
        self.queued_frames = if (result[1] != 0) ~@as(u64, 0) else result[0];
        return self.queued_frames;
    }

    pub fn consume(self: *AudioDevice, frames: u64) u64 {
        if (self.paused) return 0;
        const used = @min(frames, self.queued_frames);
        self.queued_frames -= used;
        return used;
    }

    pub fn drain(self: *AudioDevice) u64 {
        // A paused device intentionally drains zero frames; use clearQueue to discard.
        return self.consume(self.queued_frames);
    }

    pub fn pause(self: *AudioDevice, value: bool) bool {
        const previous = self.paused;
        self.paused = value;
        return previous;
    }

    pub fn queuedFrames(self: *const AudioDevice) u64 {
        return self.queued_frames;
    }

    pub fn availableFrames(self: *const AudioDevice) u64 {
        // Paused output retains queued data but exposes no consumable frames.
        return if (self.paused) 0 else self.queued_frames;
    }

    pub fn clearQueue(self: *AudioDevice) u64 {
        const cleared = self.queued_frames;
        self.queued_frames = 0;
        return cleared;
    }

    pub fn reset(self: *AudioDevice) void {
        self.queued_frames = 0;
        self.paused = false;
    }

    pub fn isPaused(self: *const AudioDevice) bool {
        return self.paused;
    }
};

pub fn createWindow(storage: []u32, width: usize, height: usize) !Window {
    if (width == 0 or height == 0) return error.InvalidSurface;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidSurface;
    if (pixels != storage.len) return error.InvalidSurface;
    return .{ .width = width, .height = height, .pixels = storage };
}

test "SDL window creation rejects invalid storage dimensions" {
    var storage = [_]u32{0} ** 4;
    try @import("std").testing.expectError(error.InvalidSurface, createWindow(&storage, 3, 3));
    try @import("std").testing.expectError(error.InvalidSurface, createWindow(&storage, std.math.maxInt(usize), 2));
    try @import("std").testing.expectError(error.InvalidSurface, createWindow(&storage, 0, 4));
}

test "SDL fillRect clips extreme coordinates without wrapping" {
    var storage = [_]u32{0} ** 4;
    var window = try createWindow(&storage, 2, 2);
    window.fillRect(std.math.maxInt(usize), std.math.maxInt(usize), 4, 4, 0xffffffff);
    try @import("std").testing.expectEqual(@as(u32, 0), storage[0]);
    window.fillRect(0, 0, std.math.maxInt(usize), std.math.maxInt(usize), 0x11223344);
    try @import("std").testing.expectEqual(@as(u32, 0x11223344), storage[3]);
}

pub fn glyph3x5(character: u8) [5]u8 {
    const upper = if (character >= 'a' and character <= 'z') character - 32 else character;
    return switch (upper) {
        'A' => .{ 2, 5, 7, 5, 5 },
        'B' => .{ 6, 5, 6, 5, 6 },
        'C' => .{ 7, 4, 4, 4, 7 },
        'D' => .{ 6, 5, 5, 5, 6 },
        'E' => .{ 7, 4, 6, 4, 7 },
        'F' => .{ 7, 4, 6, 4, 4 },
        'G' => .{ 7, 4, 5, 5, 7 },
        'H' => .{ 5, 5, 7, 5, 5 },
        'I' => .{ 7, 2, 2, 2, 7 },
        'J' => .{ 1, 1, 1, 5, 7 },
        'K' => .{ 5, 5, 6, 5, 5 },
        'L' => .{ 4, 4, 4, 4, 7 },
        'M' => .{ 5, 7, 7, 5, 5 },
        'N' => .{ 5, 7, 7, 7, 5 },
        'O' => .{ 7, 5, 5, 5, 7 },
        'P' => .{ 6, 5, 6, 4, 4 },
        'Q' => .{ 7, 5, 5, 7, 1 },
        'R' => .{ 6, 5, 6, 5, 5 },
        'S' => .{ 7, 4, 7, 1, 7 },
        'T' => .{ 7, 2, 2, 2, 2 },
        'U' => .{ 5, 5, 5, 5, 7 },
        'V' => .{ 5, 5, 5, 5, 2 },
        'W' => .{ 5, 5, 7, 7, 5 },
        'X' => .{ 5, 5, 2, 5, 5 },
        'Y' => .{ 5, 5, 2, 2, 2 },
        'Z' => .{ 7, 1, 2, 4, 7 },
        '0' => .{ 7, 5, 5, 5, 7 },
        '1' => .{ 2, 6, 2, 2, 7 },
        '2' => .{ 6, 1, 2, 4, 7 },
        '3' => .{ 6, 1, 2, 1, 6 },
        '4' => .{ 5, 5, 7, 1, 1 },
        '5' => .{ 7, 4, 6, 1, 6 },
        '6' => .{ 3, 4, 7, 5, 7 },
        '7' => .{ 7, 1, 2, 2, 2 },
        '8' => .{ 7, 5, 7, 5, 7 },
        '9' => .{ 7, 5, 7, 1, 6 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        '-' => .{ 0, 0, 7, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 7 },
        '.' => .{ 0, 0, 0, 0, 2 },
        ':' => .{ 0, 2, 0, 2, 0 },
        '/' => .{ 1, 1, 2, 4, 4 },
        '\\' => .{ 4, 4, 2, 1, 1 },
        '(' => .{ 1, 2, 2, 2, 1 },
        ')' => .{ 4, 2, 2, 2, 4 },
        '[' => .{ 3, 2, 2, 2, 3 },
        ']' => .{ 6, 2, 2, 2, 6 },
        ',' => .{ 0, 0, 0, 2, 4 },
        ';' => .{ 0, 2, 0, 2, 4 },
        '@' => .{ 7, 5, 7, 4, 7 },
        '!' => .{ 2, 2, 2, 0, 2 },
        '?' => .{ 7, 1, 2, 0, 2 },
        '=' => .{ 0, 7, 0, 7, 0 },
        '#' => .{ 5, 7, 5, 7, 5 },
        '*' => .{ 2, 7, 2, 7, 2 },
        '\'' => .{ 2, 2, 0, 0, 0 },
        '"' => .{ 5, 5, 0, 0, 0 },
        '+' => .{ 2, 2, 7, 2, 2 },
        '%' => .{ 5, 1, 2, 4, 5 },
        '|' => .{ 2, 2, 2, 2, 2 },
        '~' => .{ 0, 5, 2, 5, 0 },
        '^' => .{ 2, 5, 0, 0, 0 },
        '&' => .{ 2, 5, 2, 5, 7 },
        '<' => .{ 1, 2, 4, 2, 1 },
        '>' => .{ 4, 2, 1, 2, 4 },
        else => .{ 7, 1, 2, 0, 2 },
    };
}

fn testApplicationEvent(_: *Application, _: Event) void {}
fn testApplicationDraw(window: *Window) void {
    window.fillRect(0, 0, 1, 1, 0xffffffff);
}

fn testDirectoryReader(output: []u8) ?[]const u8 {
    if (output.len < 11) return null;
    @memcpy(output[0..11], "SYSTEM.TXT\n");
    return output[0..11];
}

fn testStatReader(_: []const u8, output: []u8) ?[]const u8 {
    if (output.len < 14) return null;
    @memcpy(output[0..14], "file 42 bytes\n");
    return output[0..14];
}

fn testFileWriter(path: []const u8, contents: []const u8, append: bool) bool {
    if (!bytesEqual(path, "notes.txt")) return false;
    if (contents.len == 0) return true;
    return bytesEqual(contents, "again") and append;
}

fn testFileRemover(path: []const u8) bool {
    return bytesEqual(path, "notes.txt");
}

fn testFileCopier(source: []const u8, destination: []const u8) bool {
    return bytesEqual(source, "notes.txt") and bytesEqual(destination, "backup.txt");
}

fn testFileMover(source: []const u8, destination: []const u8) bool {
    return bytesEqual(source, "notes.txt") and bytesEqual(destination, "renamed.txt");
}

fn testProgramRunner(command: []const u8) ?u8 {
    return if (bytesEqual(command, "echo ready")) 0 else null;
}

test "SDL software event queue and surface contract" {
    try @import("std").testing.expectEqual(std.math.maxInt(i32), saturatingAdd(std.math.maxInt(i32), 1));
    try @import("std").testing.expectEqual(std.math.minInt(i32), saturatingAdd(std.math.minInt(i32), -1));
    try @import("std").testing.expect(bytesEqualIgnoreCase("StAtUs", "STATUS"));
    try @import("std").testing.expect(!bytesEqualIgnoreCase("status", "status "));
    try @import("std").testing.expectEqual([5]u8{ 0, 2, 0, 2, 0 }, glyph3x5(':'));
    try @import("std").testing.expectEqual([5]u8{ 1, 1, 2, 4, 4 }, glyph3x5('/'));
    try @import("std").testing.expectEqual([5]u8{ 4, 4, 2, 1, 1 }, glyph3x5('\\'));
    try @import("std").testing.expectEqual([5]u8{ 2, 2, 2, 0, 2 }, glyph3x5('!'));
    try @import("std").testing.expectEqual([5]u8{ 0, 7, 0, 7, 0 }, glyph3x5('='));
    try @import("std").testing.expectEqual([5]u8{ 5, 7, 5, 7, 5 }, glyph3x5('#'));
    try @import("std").testing.expectEqual([5]u8{ 2, 2, 0, 0, 0 }, glyph3x5('\''));
    try @import("std").testing.expectEqual([5]u8{ 5, 5, 0, 0, 0 }, glyph3x5('"'));
    try @import("std").testing.expectEqual([5]u8{ 2, 2, 7, 2, 2 }, glyph3x5('+'));
    try @import("std").testing.expectEqual([5]u8{ 5, 1, 2, 4, 5 }, glyph3x5('%'));
    try @import("std").testing.expectEqual([5]u8{ 1, 2, 4, 2, 1 }, glyph3x5('<'));
    try @import("std").testing.expectEqual([5]u8{ 0, 5, 2, 5, 0 }, glyph3x5('~'));
    try @import("std").testing.expectEqual([5]u8{ 2, 5, 0, 0, 0 }, glyph3x5('^'));
    try @import("std").testing.expectEqual([5]u8{ 2, 5, 2, 5, 7 }, glyph3x5('&'));
    try @import("std").testing.expectEqual([5]u8{ 0, 2, 0, 2, 4 }, glyph3x5(';'));
    try @import("std").testing.expect(glyph3x5('(')[0] != glyph3x5(')')[0]);
    try @import("std").testing.expectEqual(@as(u32, 0x112233), blendRgbaOverRgb(0x112233ff, 0xaabbcc));
    try @import("std").testing.expectEqual(@as(u32, 0xaabbcc), blendRgbaOverRgb(0x11223300, 0xaabbcc));
    try @import("std").testing.expectEqual(@as(u32, 0x80007f), blendRgbaOverRgb(0xff000080, 0x0000ff));
    var clipped_storage = [_]u32{0} ** 16;
    var clipped = try createWindow(&clipped_storage, 4, 4);
    clipped.drawText(std.math.maxInt(usize), std.math.maxInt(usize), "A", 0xffffffff);
    try @import("std").testing.expect(!clipped.consumeDirty());
    var multiline_storage = [_]u32{0} ** 256;
    var multiline = try createWindow(&multiline_storage, 16, 16);
    multiline.drawText(0, 0, "A\r\nB", 0xffffffff);
    try @import("std").testing.expect(multiline.pixels[2] != 0);
    var lower_pixels: usize = 0;
    for (multiline.pixels[12 * 16 ..]) |pixel| {
        if (pixel != 0) lower_pixels += 1;
    }
    try @import("std").testing.expect(lower_pixels != 0);
    var wrapped_storage = [_]u32{0} ** 256;
    var wrapped = try createWindow(&wrapped_storage, 16, 16);
    wrapped.drawText(0, 0, "ABC", 0xffffffff);
    var wrapped_lower: usize = 0;
    for (wrapped.pixels[12 * 16 ..]) |pixel| {
        if (pixel != 0) wrapped_lower += 1;
    }
    try @import("std").testing.expect(wrapped_lower != 0);
    var tab_storage = [_]u32{0} ** 640;
    var tabbed = try createWindow(&tab_storage, 40, 16);
    tabbed.drawText(0, 0, "A\tB", 0xffffffff);
    try @import("std").testing.expect(tabbed.pixels[2] != 0);
    try @import("std").testing.expect(tabbed.pixels[32 + 2] != 0);
    var events = EventQueue{};
    try @import("std").testing.expectEqual(@as(usize, 0), events.len());
    try @import("std").testing.expectEqual(EventQueue.capacity, events.remaining());
    try @import("std").testing.expect(!events.isFull());
    try @import("std").testing.expect(events.isEmpty());
    try @import("std").testing.expect(events.pushQuit());
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), events.peek());
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), events.poll());
    try @import("std").testing.expect(events.pushKeyboard(0x04, true, 0x04));
    try @import("std").testing.expect(events.pushText('a'));
    try @import("std").testing.expect(events.pushMouse(12, -3, 1, 1));
    try @import("std").testing.expectEqual(Event{ .key = .{ .scancode = 0x04, .pressed = true, .modifiers = 0x04 } }, events.poll().?);
    try @import("std").testing.expect(events.poll() != null);
    try @import("std").testing.expect(events.poll() != null);
    try @import("std").testing.expectEqual(@as(usize, 0), events.len());
    try @import("std").testing.expect(events.pushMouse(4, 2, 0, 1));
    try @import("std").testing.expect(events.pushMouseCoalesced(3, -1, 1, 1));
    try @import("std").testing.expectEqual(@as(usize, 1), events.len());
    try @import("std").testing.expectEqual(Event{ .mouse = .{ .x = 7, .y = 1, .wheel = 1, .buttons = 1 } }, events.poll().?);
    try @import("std").testing.expect(events.pushMouse(1, 0, 0, 0));
    try @import("std").testing.expect(events.pushMouseCoalesced(1, 0, 0, 1));
    try @import("std").testing.expectEqual(@as(usize, 2), events.len());
    try @import("std").testing.expectEqual(Event{ .mouse = .{ .x = 1, .y = 0, .wheel = 0, .buttons = 0 } }, events.poll().?);
    try @import("std").testing.expectEqual(Event{ .mouse = .{ .x = 1, .y = 0, .wheel = 0, .buttons = 1 } }, events.poll().?);
    try @import("std").testing.expect(events.pushMouse(std.math.maxInt(i32), 0, 0, 1));
    try @import("std").testing.expect(events.pushMouseCoalesced(1, 0, 0, 1));
    try @import("std").testing.expectEqual(std.math.maxInt(i32), events.poll().?.mouse.x);
    try @import("std").testing.expect(events.pushMouse(std.math.minInt(i32), 0, 0, 1));
    try @import("std").testing.expect(events.pushMouseCoalesced(-1, 0, 0, 1));
    try @import("std").testing.expectEqual(std.math.minInt(i32), events.poll().?.mouse.x);
    var full = EventQueue{};
    var index: usize = 0;
    while (index < full.items.len) : (index += 1)
        try @import("std").testing.expect(full.push(.{ .mouse = .{ .x = @intCast(index), .y = 0, .wheel = 0, .buttons = 1 } }));
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
    var transition_full = EventQueue{};
    index = 0;
    while (index < transition_full.items.len) : (index += 1)
        try @import("std").testing.expect(transition_full.push(.{ .mouse = .{ .x = @intCast(index), .y = 0, .wheel = 0, .buttons = 1 } }));
    try @import("std").testing.expect(transition_full.pushMouseCoalesced(9, 2, 0, 0));
    try @import("std").testing.expectEqual(@as(u64, 1), transition_full.droppedCount());
    try @import("std").testing.expectEqual(Event{ .mouse = .{ .x = 9, .y = 2, .wheel = 0, .buttons = 0 } }, transition_full.poll().?);
    index = 0;
    while (index < full.items.len) : (index += 1)
        try @import("std").testing.expect(full.push(.{ .mouse = .{ .x = 0, .y = 0, .wheel = 0, .buttons = 0 } }));
    try @import("std").testing.expect(full.pushQuit());
    try @import("std").testing.expect(full.isFull());
    var saw_quit = false;
    while (full.poll()) |event| {
        if (event == .quit) saw_quit = true;
    }
    try @import("std").testing.expect(saw_quit);
    full.dropped = 7;
    full.clear();
    try @import("std").testing.expectEqual(@as(usize, 0), full.len());
    try @import("std").testing.expectEqual(@as(u64, 7), full.droppedCount());
    var pixels: [16]u32 = .{0} ** 16;
    const window = try createWindow(&pixels, 4, 4);
    try @import("std").testing.expectEqual(@as(usize, 4), window.width);
    var drawable = window;
    try @import("std").testing.expect(!drawable.consumeDirty());
    drawable.clear(0x11223344);
    try @import("std").testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, drawable.dirtyRect().?);
    try @import("std").testing.expect(drawable.consumeDirty());
    drawable.invalidate();
    try @import("std").testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, drawable.dirtyRect().?);
    try @import("std").testing.expect(drawable.consumeDirty());
    drawable.fillRect(1, 1, 2, 2, 0xaabbccdd);
    try @import("std").testing.expectEqual(@as(u32, 0xaabbccdd), pixels[5]);
    drawable.fillRect(3, 3, 8, 8, 0x55667788);
    try @import("std").testing.expectEqual(@as(u32, 0x55667788), pixels[15]);
    drawable.fillRect(0, 0, 1, 1, 0x01020304);
    try @import("std").testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 4, .height = 4 }, drawable.dirtyRect().?);
    var text_pixels: [128]u32 = .{0} ** 128;
    var text_window = try createWindow(&text_pixels, 16, 8);
    text_window.drawText(0, 0, "A", 0xffffffff);
    try @import("std").testing.expect(text_pixels[2] == 0xffffffff);
    try @import("std").testing.expectEqual(glyph3x5('A'), glyph3x5('a'));
    var input = TextInput{};
    try @import("std").testing.expect(input.insert('a'));
    try @import("std").testing.expect(input.insert('c'));
    input.moveLeft();
    try @import("std").testing.expect(input.insert('b'));
    try @import("std").testing.expectEqualStrings("abc", input.slice());
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[input.len]);
    input.replace("xy");
    try @import("std").testing.expectEqualStrings("xy", input.slice());
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[input.len]);
    input.replace("abc");
    input.cursor = 2;
    try @import("std").testing.expect(input.backspace());
    try @import("std").testing.expectEqualStrings("ac", input.slice());
    input.moveRight();
    try @import("std").testing.expectEqual(@as(usize, 2), input.cursor);
    input.moveHome();
    try @import("std").testing.expect(input.delete());
    try @import("std").testing.expectEqualStrings("c", input.slice());
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[input.len]);
    input.moveEnd();
    input.cursor = input.bytes.len + 1;
    try @import("std").testing.expect(input.insert('x'));
    try @import("std").testing.expectEqual(@as(usize, 2), input.cursor);
    input.cursor = input.bytes.len + 1;
    try @import("std").testing.expect(!input.delete());
    try @import("std").testing.expect(input.backspace());
    try @import("std").testing.expectEqual(@as(usize, 1), input.cursor);
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[input.len]);
    input.clear();
    try @import("std").testing.expectEqual(@as(usize, 0), input.len);
    try @import("std").testing.expectEqual(@as(usize, 0), input.cursor);
    input.replace("stale command");
    input.replace("ok");
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[2]);
    input.replace("abcdef");
    const aliased = input.slice()[1..];
    input.replace(aliased);
    try @import("std").testing.expectEqualStrings("bcdef", input.slice());
    var long_text: [64]u8 = [_]u8{'x'} ** 64;
    input.replace(&long_text);
    input.replace("z");
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[63]);
    input.len = std.math.maxInt(usize);
    input.replace("safe");
    try @import("std").testing.expectEqualStrings("safe", input.slice());
    input.clear();
    input.len = std.math.maxInt(usize);
    input.eraseWordBackward();
    try @import("std").testing.expectEqual(@as(usize, 64), input.len);
    input.replace("abcdef");
    input.cursor = 2;
    input.eraseToEnd();
    try @import("std").testing.expectEqualStrings("ab", input.slice());
    try @import("std").testing.expectEqual(@as(u8, 0), input.bytes[2]);
    input.replace("one two three");
    input.eraseWordBackward();
    try @import("std").testing.expectEqualStrings("one two ", input.slice());
    input.eraseWordBackward();
    try @import("std").testing.expectEqualStrings("one ", input.slice());
    input.replace("one\ttwo");
    input.eraseWordBackward();
    try @import("std").testing.expectEqualStrings("one\t", input.slice());
    input.replace("one two three");
    input.moveWordLeft();
    try @import("std").testing.expectEqual(@as(usize, 8), input.cursor);
    input.moveWordLeft();
    try @import("std").testing.expectEqual(@as(usize, 4), input.cursor);
    input.moveWordRight();
    try @import("std").testing.expectEqual(@as(usize, 8), input.cursor);
    input.replace("one  three");
    input.cursor = 3;
    input.moveWordRight();
    try @import("std").testing.expectEqual(@as(usize, 5), input.cursor);
    input.cursor = 5;
    input.moveWordLeft();
    try @import("std").testing.expectEqual(@as(usize, 0), input.cursor);
    input.replace("one two three");
    input.cursor = 7;
    input.eraseWordBackward();
    try @import("std").testing.expectEqualStrings("one  three", input.slice());
    input.moveHome();
    input.eraseWordBackward();
    try @import("std").testing.expectEqualStrings("one  three", input.slice());
    var terminal = Terminal{};
    for ("discard") |byte| try @import("std").testing.expect(terminal.input.insert(byte));
    terminal.cancel();
    try @import("std").testing.expectEqualStrings("", terminal.input.slice());
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    for ("status") |byte| try @import("std").testing.expect(terminal.input.insert(byte));
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> status\nCSOS READY\n", terminal.outputSlice());
    try @import("std").testing.expectEqualStrings("CSOS READY\n", terminal.outputTailLines(1));
    terminal.clearOutput();
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    terminal.input.replace("status");
    terminal.input.replace("version");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> version\nCSOS 0.1\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("echo");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> echo\nECHO READY\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("echo hello CSOS");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> echo hello CSOS\nhello CSOS\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("  status \t");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> status\nCSOS READY\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("STATUS");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> STATUS\nCSOS READY\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("ECHO ready");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> ECHO ready\nready\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("HiStOrY");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expect(std.mem.startsWith(u8, terminal.outputSlice(), "> HiStOrY\nHISTORY\n"));
    terminal.input.replace("ClEaR");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    terminal.input.replace("status");
    try @import("std").testing.expect(terminal.submit());
    terminal.input.replace("reset");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.history_len);
    terminal.clearOutput();
    terminal.input.replace("help");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> help\nHELP CLEAR RESET STATUS VERSION WHOAMI PWD LS CAT STAT RM CP MV TOUCH RUN HTTP FRAMEBUFFER DRM LIBDRM RADV GPU ECHO HISTORY [TEXT] ECHO > FILE\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.file_writer = &testFileWriter;
    terminal.input.replace("echo hello > notes.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> echo hello > notes.txt\necho: WRITE ERROR\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("echo again >> notes.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> echo again >> notes.txt\nOK\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.file_remover = &testFileRemover;
    terminal.input.replace("rm notes.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> rm notes.txt\nOK\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.file_copier = &testFileCopier;
    terminal.input.replace("cp notes.txt backup.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> cp notes.txt backup.txt\nOK\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.file_mover = &testFileMover;
    terminal.input.replace("mv notes.txt renamed.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> mv notes.txt renamed.txt\nOK\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("touch notes.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> touch notes.txt\nOK\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.program_runner = &testProgramRunner;
    terminal.input.replace("run echo ready");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> run echo ready\nPROGRAM EXITED 0\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("cat /hello.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> cat /hello.txt\nHello from initramfs\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("cat missing.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> cat missing.txt\ncat: FILE NOT FOUND\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("whoami");
    try @import("std").testing.expect(terminal.submit());
    terminal.input.replace("pwd");
    try @import("std").testing.expect(terminal.submit());
    terminal.input.replace("ls");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expect(std.mem.indexOf(u8, terminal.outputSlice(), "root\n") != null);
    try @import("std").testing.expect(std.mem.indexOf(u8, terminal.outputSlice(), "> pwd\n/\n") != null);
    try @import("std").testing.expect(std.mem.indexOf(u8, terminal.outputSlice(), "SYSTEM.TXT") != null);
    terminal.clearOutput();
    terminal.input.replace("history");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> history\nHISTORY\n  whoami\n  pwd\n  ls\n  history\n", terminal.outputSlice());
    terminal.clearOutput();
    try @import("std").testing.expect(terminal.historyPrevious());
    try @import("std").testing.expectEqualStrings("history", terminal.input.slice());
    try @import("std").testing.expect(terminal.historyNext());
    try @import("std").testing.expectEqualStrings("", terminal.input.slice());
    terminal.history_cursor = terminal.history_len + 1;
    try @import("std").testing.expect(!terminal.historyNext());
    terminal.history_cursor = terminal.history_len + 1;
    try @import("std").testing.expect(terminal.historyPrevious());
    try @import("std").testing.expectEqualStrings("history", terminal.input.slice());
    terminal.input.clear();
    for ("clear") |byte| try @import("std").testing.expect(terminal.input.insert(byte));
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    try @import("std").testing.expectEqualStrings("", terminal.outputTailLines(0));
    terminal.output_len = std.math.maxInt(usize);
    try @import("std").testing.expect(terminal.outputSlice().len <= terminal.output.len);
    try @import("std").testing.expectEqualStrings("", terminal.outputTailLines(0));
    var app = Application{ .window = drawable };
    var app_events = EventQueue{};
    try @import("std").testing.expect(app_events.push(.{ .quit = {} }));
    try @import("std").testing.expect(app_events.pushText('x'));
    app.pump(&app_events, &testApplicationEvent);
    try @import("std").testing.expect(!app.running);
    try @import("std").testing.expectEqual(@as(u64, 1), app.processed_events);
    try @import("std").testing.expectEqual(@as(u64, 1), app.takeProcessedEvents());
    try @import("std").testing.expectEqual(@as(usize, 1), app_events.len());
    try @import("std").testing.expectEqual(@as(u64, 0), app.processed_events);
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), app.last_event);
    try @import("std").testing.expectEqual(@as(?Event, .{ .quit = {} }), app.takeLastEvent());
    try @import("std").testing.expect(app.takeLastEvent() == null);
    app.reset();
    try @import("std").testing.expect(app.running);
    try @import("std").testing.expect(app.last_event == null);
    try @import("std").testing.expect(app.window.pixels[0] == 0);
    try @import("std").testing.expect(app.window.dirtyRect() != null);
    try @import("std").testing.expect(app.render(&testApplicationDraw));
    app.running = true;
    try @import("std").testing.expect(app.render(&testApplicationDraw));
    try @import("std").testing.expect(app.frame(&app_events, &testApplicationEvent, &testApplicationDraw));
    var audio = try AudioDevice.init(.{ .sample_rate = 48000, .channels = 2 });
    try @import("std").testing.expectEqual(@as(u64, 256), audio.queue(256));
    try @import("std").testing.expectEqual(@as(u64, 256), audio.queue(0));
    try @import("std").testing.expectEqual(@as(u64, 256), audio.queuedFrames());
    try @import("std").testing.expectEqual(@as(u64, 256), audio.availableFrames());
    try @import("std").testing.expectEqual(@as(u64, 128), audio.consume(128));
    try @import("std").testing.expect(!audio.pause(true));
    try @import("std").testing.expect(audio.pause(true));
    try @import("std").testing.expect(audio.paused);
    try @import("std").testing.expect(audio.isPaused());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.availableFrames());
    try @import("std").testing.expectEqual(@as(u64, 192), audio.queue(64));
    try @import("std").testing.expectEqual(@as(u64, 0), audio.availableFrames());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.consume(64));
    try @import("std").testing.expectEqual(@as(u64, 192), audio.queuedFrames());
    try audio.reconfigure(.{ .sample_rate = 48000, .channels = 2 });
    try @import("std").testing.expect(audio.pause(true));
    try audio.reconfigure(.{ .sample_rate = 48000, .channels = 2 });
    try @import("std").testing.expect(audio.paused);
    try @import("std").testing.expectError(error.AudioQueued, audio.reconfigure(.{ .sample_rate = 44100, .channels = 2 }));
    try @import("std").testing.expectEqual(@as(u64, 0), audio.drain());
    try @import("std").testing.expect(audio.pause(false));
    try @import("std").testing.expect(!audio.pause(false));
    try @import("std").testing.expectEqual(@as(u64, 192), audio.drain());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.drain());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.clearQueue());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    audio.queued_frames = 64;
    audio.paused = true;
    audio.reset();
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    try @import("std").testing.expect(!audio.paused);
    try @import("std").testing.expectEqual(@as(u32, 48000), audio.spec.sample_rate);
    audio.reset();
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    try @import("std").testing.expect(!audio.paused);
    try audio.reconfigure(.{ .sample_rate = 44100, .channels = 2 });
    try @import("std").testing.expectEqual(@as(u32, 44100), audio.spec.sample_rate);
    _ = audio.pause(false);
    try @import("std").testing.expect(!audio.isPaused());
    audio.queued_frames = ~@as(u64, 0) - 1;
    try @import("std").testing.expectEqual(~@as(u64, 0), audio.queue(4));
    try @import("std").testing.expectEqual(~@as(u64, 0), audio.queued_frames);
    audio.reset();
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queued_frames);
    try @import("std").testing.expectError(error.InvalidAudioSpec, audio.reconfigure(.{ .sample_rate = 0, .channels = 2 }));
    try @import("std").testing.expectEqual(@as(u32, 44100), audio.spec.sample_rate);
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 0, .channels = 2 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 0 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 9 }));
}

test "SDL terminal uses directory callback for real ls output" {
    var terminal = Terminal{ .directory_reader = &testDirectoryReader };
    terminal.input.replace("ls");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> ls\nSYSTEM.TXT\n", terminal.outputSlice());
}

test "SDL terminal uses stat callback for file metadata" {
    var terminal = Terminal{ .stat_reader = &testStatReader };
    terminal.input.replace("stat hello.txt");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> stat hello.txt\nfile 42 bytes\n", terminal.outputSlice());
}

test "SDL text input displaces oldest mouse event in a full queue" {
    var events = EventQueue{};
    var index: usize = 0;
    while (index < events.items.len) : (index += 1)
        try @import("std").testing.expect(events.pushMouse(@intCast(index), 0, 0, 0));
    try @import("std").testing.expect(events.pushText('x'));
    try @import("std").testing.expectEqual(@as(u64, 1), events.droppedCount());
    var saw_text = false;
    while (events.poll()) |event| {
        if (event == .text and event.text == 'x') saw_text = true;
    }
    try @import("std").testing.expect(saw_text);

    var protected = EventQueue{};
    index = 0;
    while (index < protected.items.len) : (index += 1)
        try @import("std").testing.expect(protected.pushMouse(0, 0, 0, 1));
    try @import("std").testing.expect(!protected.pushText('y'));
    try @import("std").testing.expectEqual(@as(u64, 1), protected.droppedCount());
    while (protected.poll()) |event| try @import("std").testing.expect(event == .mouse);
}

test "SDL event queue survives counter wraparound" {
    var queue = EventQueue{};
    const start = std.math.maxInt(usize) - 1;
    queue.read = start;
    queue.write = start;
    try @import("std").testing.expect(queue.pushText('a'));
    try @import("std").testing.expect(queue.pushText('b'));
    try @import("std").testing.expectEqual(@as(usize, 2), queue.len());
    try @import("std").testing.expectEqual(Event{ .text = 'a' }, queue.poll().?);
    try @import("std").testing.expectEqual(Event{ .text = 'b' }, queue.poll().?);
    try @import("std").testing.expect(queue.isEmpty());
}

test "SDL mouse coalescing saturates motion and wheel" {
    var queue = EventQueue{};
    try @import("std").testing.expect(queue.pushMouseCoalesced(std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(i32), 0));
    try @import("std").testing.expect(queue.pushMouseCoalesced(1, 1, 1, 0));
    try @import("std").testing.expectEqual(Event{ .mouse = .{
        .x = std.math.maxInt(i32),
        .y = std.math.maxInt(i32),
        .wheel = std.math.maxInt(i32),
        .buttons = 0,
    } }, queue.poll().?);
    try @import("std").testing.expect(queue.pushMouseCoalesced(std.math.minInt(i32), std.math.minInt(i32), std.math.minInt(i32), 0));
    try @import("std").testing.expect(queue.pushMouseCoalesced(-1, -1, -1, 0));
    try @import("std").testing.expectEqual(Event{ .mouse = .{
        .x = std.math.minInt(i32),
        .y = std.math.minInt(i32),
        .wheel = std.math.minInt(i32),
        .buttons = 0,
    } }, queue.poll().?);
}

test "SDL event queue clear compacts indices and preserves drops" {
    var queue = EventQueue{};
    try @import("std").testing.expect(queue.pushText('x'));
    queue.dropped = 3;
    queue.clear();
    try @import("std").testing.expect(queue.isEmpty());
    try @import("std").testing.expectEqual(@as(usize, 0), queue.read);
    try @import("std").testing.expectEqual(@as(usize, 0), queue.write);
    try @import("std").testing.expectEqual(@as(u64, 3), queue.droppedCount());
}

test "SDL drop counter saturates" {
    var queue = EventQueue{};
    queue.dropped = std.math.maxInt(u64);
    queue.write = EventQueue.capacity;
    try std.testing.expect(!queue.push(.{ .text = 'x' }));
    try std.testing.expectEqual(std.math.maxInt(u64), queue.droppedCount());
}

test "SDL quit preservation saturates drop counter" {
    var queue = EventQueue{};
    queue.write = EventQueue.capacity;
    queue.dropped = std.math.maxInt(u64);
    try std.testing.expect(queue.pushQuit());
    try std.testing.expectEqual(std.math.maxInt(u64), queue.droppedCount());
    try std.testing.expectEqual(Event{ .quit = {} }, queue.peek().?);
}

test "SDL keyboard release displaces discardable full-queue input" {
    var queue = EventQueue{};
    for (0..EventQueue.capacity) |_| try @import("std").testing.expect(queue.pushMouse(1, 0, 0, 0));
    try @import("std").testing.expect(queue.pushKeyboard(0x04, false, 0));
    try @import("std").testing.expectEqual(@as(u64, 1), queue.droppedCount());
    var saw_release = false;
    while (queue.poll()) |event| {
        if (event == .key and event.key.scancode == 0x04 and !event.key.pressed) saw_release = true;
    }
    try @import("std").testing.expect(saw_release);
}

test "SDL audio queue saturates on frame overflow" {
    var audio = try AudioDevice.init(.{ .sample_rate = 48_000, .channels = 2 });
    try @import("std").testing.expectEqual(std.math.maxInt(u64), audio.queue(std.math.maxInt(u64)));
    try @import("std").testing.expectEqual(std.math.maxInt(u64), audio.queue(1));
    try @import("std").testing.expectEqual(std.math.maxInt(u64), audio.queuedFrames());
}

test "SDL list selection normalizes zero visible rows" {
    var selection = ListSelection{ .visible_rows = 0 };
    selection.setCount(3);
    try @import("std").testing.expectEqual(@as(usize, 1), selection.visible_rows);
    try @import("std").testing.expect(!selection.selectVisibleRow(0));
}

test "SDL list selection recovers an out-of-range selected index" {
    var selection = ListSelection.init(3, 2);
    selection.selected = 99;
    try @import("std").testing.expect(!selection.next());
    try @import("std").testing.expectEqual(@as(usize, 2), selection.selected);
    selection.selected = 99;
    try @import("std").testing.expect(selection.previous());
    try @import("std").testing.expectEqual(@as(usize, 1), selection.selected);
}

test "SDL list selection repairs an out-of-range viewport" {
    var selection = ListSelection.init(5, 2);
    selection.first_visible = 99;
    try @import("std").testing.expect(selection.selectVisibleRow(0));
    try @import("std").testing.expectEqual(@as(usize, 3), selection.first_visible);
    try @import("std").testing.expectEqual(@as(usize, 3), selection.selected);
}

test "list selection keeps the selected row inside its viewport" {
    const testing = @import("std").testing;
    var list = ListSelection.init(10, 3);
    try testing.expect(!list.previous());
    try testing.expect(list.next());
    try testing.expect(list.next());
    try testing.expectEqual(@as(usize, 0), list.first_visible);
    try testing.expect(list.next());
    try testing.expectEqual(@as(usize, 1), list.first_visible);
    try testing.expect(list.wheel(-1));
    try testing.expectEqual(@as(usize, 4), list.selected);
    try testing.expect(list.wheel(1));
    try testing.expectEqual(@as(usize, 3), list.selected);
    try testing.expect(!list.wheel(0));
    try testing.expect(list.selectVisibleRow(2));
    try testing.expectEqual(@as(usize, 4), list.selected);
    try testing.expect(!list.selectVisibleRow(2));
    try testing.expect(!list.selectVisibleRow(3));
    try testing.expect(list.pageNext());
    try testing.expectEqual(@as(usize, 7), list.selected);
    try testing.expect(list.pagePrevious());
    try testing.expectEqual(@as(usize, 4), list.selected);
    try testing.expect(list.end());
    try testing.expectEqual(@as(usize, 9), list.selected);
    try testing.expect(list.home());
    try testing.expectEqual(@as(usize, 0), list.selected);
    list.selected = 4;
    list.setCount(3);
    try testing.expectEqual(@as(usize, 2), list.selected);
    try testing.expectEqual(@as(usize, 0), list.first_visible);
    list.setCount(0);
    try testing.expectEqual(@as(usize, 0), list.selected);
    try testing.expectEqual(@as(usize, 0), list.first_visible);

    var empty = ListSelection.init(0, 0);
    try testing.expectEqual(@as(usize, 1), empty.visible_rows);
    try testing.expect(!empty.next());
    try testing.expectEqual(@as(u8, 'A'), displayTextByte('A'));
    try testing.expectEqual(@as(u8, ' '), displayTextByte('\t'));
    try testing.expectEqual(@as(u8, '.'), displayTextByte(0));
    try testing.expectEqual(@as(u8, '.'), displayTextByte(0xff));

    var pager = Pager.init(192);
    pager.reset(400);
    try testing.expect(pager.next());
    try testing.expectEqual(@as(usize, 192), pager.offset);
    try testing.expect(pager.next());
    try testing.expectEqual(@as(usize, 384), pager.offset);
    try testing.expect(!pager.next());
    try testing.expect(pager.previous());
    try testing.expectEqual(@as(usize, 192), pager.offset);
    try testing.expect(pager.home());
    try testing.expectEqual(@as(usize, 0), pager.offset);
    try testing.expect(pager.end());
    try testing.expectEqual(@as(usize, 384), pager.offset);
    try testing.expect(!pager.end());
}

test "SDL pager recovers an offset beyond the current total" {
    var pager = Pager.init(4);
    pager.reset(10);
    pager.offset = 99;
    try @import("std").testing.expect(!pager.next());
    try @import("std").testing.expectEqual(@as(usize, 10), pager.offset);
    try @import("std").testing.expect(pager.previous());
    try @import("std").testing.expectEqual(@as(usize, 6), pager.offset);
}

test "SDL pager clamps page movement and zero page sizes" {
    var pager = Pager.init(0);
    try @import("std").testing.expectEqual(@as(usize, 1), pager.page_size);
    pager.reset(3);
    try @import("std").testing.expect(pager.next());
    try @import("std").testing.expectEqual(@as(usize, 1), pager.offset);
    try @import("std").testing.expect(pager.next());
    try @import("std").testing.expectEqual(@as(usize, 2), pager.offset);
    try @import("std").testing.expect(!pager.next());
    try @import("std").testing.expect(pager.previous());
    try @import("std").testing.expect(pager.home());
    try @import("std").testing.expectEqual(@as(usize, 0), pager.offset);
}

test "SDL window renders parsed HTML elements" {
    var pixels: [64 * 32]u32 = .{0} ** (64 * 32);
    var window = Window{ .width = 64, .height = 32, .pixels = &pixels };
    const document = html.Document.parse("<h1>CSOS</h1><p>Ready</p><button>Go</button>");
    window.drawHtml(&document, 0, 0);
    try @import("std").testing.expect(window.dirtyRect() != null);
    var changed = false;
    for (pixels) |pixel| if (pixel != 0) { changed = true; break; };
    try @import("std").testing.expect(changed);
    window.clear(0);
    window.drawHtmlFocused(&document, 0, 0, 2);
    try @import("std").testing.expect(pixels[27 * 64 + 1] == 0x304860ff);
}

test "reference desktop paints shell, files panel, system card and dock" {
    var pixels = [_]u32{0} ** (320 * 200);
    var window = Window{ .width = 320, .height = 200, .pixels = &pixels };
    drawReferenceDesktop(&window);
    try @import("std").testing.expectEqual(@as(u32, 0x17294fff), pixels[10]);
    try @import("std").testing.expect(pixels[100 * 320 + 200] != 0);
    try @import("std").testing.expect(window.dirtyRect() != null);
}

test "reference desktop starts through HTML session backend" {
    var pixels = [_]u32{0} ** (64 * 32);
    var application = Application{ .window = .{ .width = 64, .height = 32, .pixels = &pixels } };
    application.startReferenceDesktop();
    try @import("std").testing.expect(application.html_session != null);
    try @import("std").testing.expect(application.backend != null);
    try @import("std").testing.expect(application.html_session.?.document.count > 0);
    try @import("std").testing.expectEqual(@as(usize, 16), application.html_session.?.document.count);
    try @import("std").testing.expectEqualStrings("Buscar aplicações, arquivos...", application.html_session.?.document.inputText(1));
    try @import("std").testing.expectEqualStrings("projetos", application.activateHtmlAt(196, 156, 196, 92).?);
}

test "reference desktop renders shell with interactive HTML overlay" {
    var pixels = [_]u32{0} ** (320 * 200);
    var application = Application{ .window = .{ .width = 320, .height = 200, .pixels = &pixels } };
    application.startReferenceDesktop();
    try @import("std").testing.expect(application.renderReferenceDesktop());
    try @import("std").testing.expectEqual(@as(u32, 0x17294fff), pixels[10]);
    application.pointer_x = 12;
    application.pointer_y = 44;
    try @import("std").testing.expect(application.renderReferenceDesktop());
    try @import("std").testing.expectEqual(@as(u32, 0xf1f6ffff), pixels[44 * 320 + 12]);
}

test "reference desktop dispatches launcher actions into HTML apps" {
    var pixels = [_]u32{0} ** (320 * 200);
    var application = Application{ .window = .{ .width = 320, .height = 200, .pixels = &pixels } };
    application.startReferenceDesktop();
    try @import("std").testing.expect(application.dispatchReferenceAction("files"));
    try @import("std").testing.expectEqualStrings("FILES", application.html_session.?.document.elements[0].text);
    try @import("std").testing.expect(!application.dispatchReferenceAction("unknown"));
    try @import("std").testing.expectEqualStrings("terminal", application.dispatchReferenceDock(20 + 18 + 3 * 72 + 4, 200 - 82 + 20).?);
    try @import("std").testing.expectEqualStrings("settings", Application.dispatchReferenceShortcut(30, 72 + 74 + 8).?);
    try @import("std").testing.expect(application.dispatchReferenceAction("terminal"));
    var events = EventQueue{};
    try @import("std").testing.expect(events.pushKeyboard(0x29, true, 0));
    application.pumpHtml(&events);
    try @import("std").testing.expectEqualStrings("CSOS", application.html_session.?.document.elements[0].text);
}

test "SDL application persists and edits HTML session" {
    var pixels: [256]u32 = .{0} ** 256;
    var application = Application{ .window = try createWindow(&pixels, 16, 16) };
    application.startHtml("<input></input><button>Go</button>");
    try std.testing.expectEqual(@as(usize, 0), application.focusHtmlNext(true).?);
    try std.testing.expect(application.handleHtmlKey('z'));
    try std.testing.expectEqualStrings("z", application.html_session.?.document.inputText(0));
}
