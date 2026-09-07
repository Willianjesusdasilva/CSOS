const std = @import("std");

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
        // Discard pending input but preserve the drop counter for diagnostics.
        self.read = self.write;
    }

    pub fn pushKeyboard(self: *EventQueue, scancode: u8, pressed: bool, modifiers: u8) bool {
        return self.push(.{ .key = .{ .scancode = scancode, .pressed = pressed, .modifiers = modifiers } });
    }

    pub fn pushText(self: *EventQueue, byte: u8) bool {
        return self.push(.{ .text = byte });
    }

    pub fn pushMouse(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        return self.push(.{ .mouse = .{ .x = x, .y = y, .wheel = wheel, .buttons = buttons } });
    }

    pub fn pushMouseCoalesced(self: *EventQueue, x: i32, y: i32, wheel: i32, buttons: u8) bool {
        // Never merge across a button transition: doing so could erase a click.
        if (self.write != self.read) {
            const slot = (self.write - 1) % self.items.len;
            if (self.items[slot] == .mouse and self.items[slot].mouse.buttons == buttons) {
                self.items[slot].mouse.x = saturatingAdd(self.items[slot].mouse.x, x);
                self.items[slot].mouse.y = saturatingAdd(self.items[slot].mouse.y, y);
                self.items[slot].mouse.wheel = saturatingAdd(self.items[slot].mouse.wheel, wheel);
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

pub const ListSelection = struct {
    count: usize = 0,
    selected: usize = 0,
    first_visible: usize = 0,
    visible_rows: usize,

    pub fn init(count: usize, visible_rows: usize) ListSelection {
        return .{ .count = count, .visible_rows = @max(@as(usize, 1), visible_rows) };
    }

    pub fn next(self: *ListSelection) bool {
        if (self.count == 0 or self.selected + 1 >= self.count) return false;
        self.selected += 1;
        self.reveal();
        return true;
    }

    pub fn previous(self: *ListSelection) bool {
        if (self.count == 0 or self.selected == 0) return false;
        self.selected -= 1;
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
        const index = self.first_visible + row;
        if (index >= self.count) return false;
        const changed = self.selected != index;
        self.selected = index;
        return changed;
    }

    pub fn setCount(self: *ListSelection, count: usize) void {
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
        if (self.selected >= self.first_visible + self.visible_rows)
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
        if (self.offset >= self.total or self.page_size >= self.total - self.offset) return false;
        self.offset += self.page_size;
        return true;
    }

    pub fn previous(self: *Pager) bool {
        if (self.offset == 0) return false;
        self.offset -|= self.page_size;
        return true;
    }

    pub fn home(self: *Pager) bool {
        if (self.offset == 0) return false;
        self.offset = 0;
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
                cursor_y +|= 12;
                continue;
            }
            if (character == '\t') {
                const column = (cursor_x -| x) / 8;
                cursor_x = x +| ((column + 4) & ~@as(usize, 3)) * 8;
                if (cursor_x >= self.width) {
                    cursor_x = x;
                    cursor_y +|= 12;
                }
                continue;
            }
            const glyph_x = cursor_x;
            const glyph = glyph3x5(character);
            for (glyph, 0..) |row_bits, row| {
                const glyph_y = cursor_y +| row * 2;
                for (0..3) |column| {
                    if ((row_bits & (@as(u8, 1) << @intCast(2 - column))) != 0)
                        self.fillRect(glyph_x +| column * 2, glyph_y, 2, 2, color);
                }
            }
            cursor_x +|= 8;
            if (cursor_x >= self.width) {
                cursor_x = x;
                cursor_y +|= 12;
            }
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

pub const Application = struct {
    window: Window,
    running: bool = true,
    last_event: ?Event = null,
    processed_events: u64 = 0,

    pub fn pump(self: *Application, events: *EventQueue, on_event: *const fn (*Application, Event) void) void {
        while (events.poll()) |event| {
            self.last_event = event;
            self.processed_events +|= 1;
            if (event == .quit) self.running = false;
            on_event(self, event);
            if (!self.running) break;
        }
    }

    pub fn takeLastEvent(self: *Application) ?Event {
        const event = self.last_event;
        self.last_event = null;
        return event;
    }

    pub fn takeProcessedEvents(self: *Application) u64 {
        const processed = self.processed_events;
        self.processed_events = 0;
        return processed;
    }

    pub fn reset(self: *Application) void {
        self.running = true;
        self.last_event = null;
        self.processed_events = 0;
        self.window.clear(0);
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
        return true;
    }

    pub fn backspace(self: *TextInput) bool {
        self.cursor = @min(self.cursor, self.len);
        if (self.cursor == 0) return false;
        var index = self.cursor - 1;
        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];
        self.cursor -= 1;
        self.len -= 1;
        return true;
    }

    pub fn delete(self: *TextInput) bool {
        self.cursor = @min(self.cursor, self.len);
        if (self.cursor >= self.len) return false;
        var index = self.cursor;
        while (index + 1 < self.len) : (index += 1) self.bytes[index] = self.bytes[index + 1];
        self.len -= 1;
        return true;
    }

    pub fn replace(self: *TextInput, text: []const u8) void {
        self.len = @min(text.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], text[0..self.len]);
        self.cursor = self.len;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor = 0;
        @memset(&self.bytes, 0);
    }

    pub fn moveLeft(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        self.cursor -|= 1;
    }

    pub fn moveRight(self: *TextInput) void {
        self.cursor = @min(self.cursor, self.len);
        self.cursor = @min(self.len, self.cursor + 1);
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
    input: TextInput = .{},
    output: [256]u8 = undefined,
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
        } else {
            self.append("> ");
            self.append(command);
            self.append("\n");
            if (bytesEqualIgnoreCase(command, "help"))
                self.append("HELP CLEAR STATUS VERSION ECHO HISTORY [TEXT]\n")
            else if (bytesEqualIgnoreCase(command, "status"))
                self.append("CSOS READY\n")
            else if (bytesEqualIgnoreCase(command, "version"))
                self.append("CSOS 0.1\n")
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
                self.append(command[5..]);
                self.append("\n");
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
        return self.output[0..self.output_len];
    }

    pub fn outputTailLines(self: *const Terminal, max_lines: usize) []const u8 {
        if (max_lines == 0) return self.output[self.output_len..self.output_len];
        var boundaries: usize = 0;
        var index = self.output_len;
        if (index > 0 and self.output[index - 1] == '\n') index -= 1;
        while (index > 0) {
            index -= 1;
            if (self.output[index] == '\n') {
                boundaries += 1;
                if (boundaries == max_lines) return self.output[index + 1 .. self.output_len];
            }
        }
        return self.output[0..self.output_len];
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
};

fn trimCommand(bytes: []const u8) []const u8 {
    var first: usize = 0;
    while (first < bytes.len and (bytes[first] == ' ' or bytes[first] == '\t')) : (first += 1) {}
    var last = bytes.len;
    while (last > first and (bytes[last - 1] == ' ' or bytes[last - 1] == '\t')) : (last -= 1) {}
    return bytes[first..last];
}

fn bytesEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |lhs, rhs| {
        const lower = if (lhs >= 'A' and lhs <= 'Z') lhs + 32 else lhs;
        if (lower != rhs) return false;
    }
    return true;
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn saturatingAdd(left: i32, right: i32) i32 {
    return std.math.add(i32, left, right) catch if (right < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

pub const AudioDevice = struct {
    spec: AudioSpec,
    queued_frames: u64 = 0,
    paused: bool = false,

    pub fn init(spec: AudioSpec) !AudioDevice {
        if (spec.sample_rate == 0 or spec.channels == 0 or spec.channels > 8) return error.InvalidAudioSpec;
        return .{ .spec = spec };
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

    pub fn isPaused(self: *const AudioDevice) bool {
        return self.paused;
    }
};

pub fn createWindow(storage: []u32, width: usize, height: usize) !Window {
    if (width == 0 or height == 0 or width * height != storage.len) return error.InvalidSurface;
    return .{ .width = width, .height = height, .pixels = storage };
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

test "SDL software event queue and surface contract" {
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
    try @import("std").testing.expect(events.poll() != null);
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
    try @import("std").testing.expect(full.push(.{ .quit = {} }));
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
    try @import("std").testing.expect(input.backspace());
    try @import("std").testing.expectEqualStrings("ac", input.slice());
    input.moveRight();
    try @import("std").testing.expectEqual(@as(usize, 2), input.cursor);
    input.moveHome();
    try @import("std").testing.expect(input.delete());
    try @import("std").testing.expectEqualStrings("c", input.slice());
    input.moveEnd();
    input.cursor = input.bytes.len + 1;
    try @import("std").testing.expect(input.insert('x'));
    try @import("std").testing.expectEqual(@as(usize, 2), input.cursor);
    input.cursor = input.bytes.len + 1;
    try @import("std").testing.expect(!input.delete());
    try @import("std").testing.expect(input.backspace());
    try @import("std").testing.expectEqual(@as(usize, 1), input.cursor);
    input.clear();
    try @import("std").testing.expectEqual(@as(usize, 0), input.len);
    try @import("std").testing.expectEqual(@as(usize, 0), input.cursor);
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
    terminal.input.replace("ClEaR");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqual(@as(usize, 0), terminal.output_len);
    terminal.clearOutput();
    terminal.input.replace("help");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> help\nHELP CLEAR STATUS VERSION ECHO HISTORY [TEXT]\n", terminal.outputSlice());
    terminal.clearOutput();
    terminal.input.replace("history");
    try @import("std").testing.expect(terminal.submit());
    try @import("std").testing.expectEqualStrings("> history\nHISTORY\n  ECHO ready\n  ClEaR\n  help\n  history\n", terminal.outputSlice());
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
    try @import("std").testing.expectEqual(@as(u64, 0), audio.drain());
    try @import("std").testing.expect(audio.pause(false));
    try @import("std").testing.expect(!audio.pause(false));
    try @import("std").testing.expectEqual(@as(u64, 192), audio.drain());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.drain());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.clearQueue());
    try @import("std").testing.expectEqual(@as(u64, 0), audio.queuedFrames());
    _ = audio.pause(false);
    try @import("std").testing.expect(!audio.isPaused());
    audio.queued_frames = ~@as(u64, 0) - 1;
    try @import("std").testing.expectEqual(~@as(u64, 0), audio.queue(4));
    try @import("std").testing.expectEqual(~@as(u64, 0), audio.queued_frames);
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 0, .channels = 2 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 0 }));
    try @import("std").testing.expectError(error.InvalidAudioSpec, AudioDevice.init(.{ .sample_rate = 48000, .channels = 9 }));
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
}
