const std = @import("std");

pub const Kind = enum { heading, paragraph, container, button, link, input };
pub const Activation = union(enum) { none, focus_input: usize, action: []const u8 };
pub const Element = struct { kind: Kind, text: []const u8, target: []const u8 = "", accent: bool = false, muted: bool = false, danger: bool = false, color: ?u32 = null };
pub const DrawText = *const fn (x: usize, y: usize, text: []const u8, color: u32) void;

/// Small allocation-free HTML subset used by the planned system UI.
/// Supported elements are h1, p and button; unknown tags are ignored while
/// their text remains available to the next supported element.
pub const Document = struct {
    elements: [16]Element = undefined,
    input_values: [16][64]u8 = undefined,
    input_lengths: [16]usize = .{0} ** 16,
    count: usize = 0,

    pub fn parse(source: []const u8) Document {
        var document = Document{};
        var cursor: usize = 0;
        while (cursor < source.len and document.count < document.elements.len) {
            const open = std.mem.indexOfScalarPos(u8, source, cursor, '<') orelse break;
            const close = std.mem.indexOfScalarPos(u8, source, open + 1, '>') orelse break;
            const tag = source[open + 1 .. close];
            const name_end = std.mem.indexOfScalar(u8, tag, ' ') orelse tag.len;
            const name = tag[0..name_end];
            const kind: ?Kind = if (std.mem.eql(u8, name, "h1")) .heading else if (std.mem.eql(u8, name, "p")) .paragraph else if (std.mem.eql(u8, name, "div") or std.mem.eql(u8, name, "span")) .container else if (std.mem.eql(u8, name, "button")) .button else if (std.mem.eql(u8, name, "a")) .link else if (std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "textarea")) .input else null;
            if (kind) |value| {
                const end_tag = switch (value) { .heading => "</h1>", .paragraph => "</p>", .container => if (std.mem.eql(u8, name, "div")) "</div>" else "</span>", .button => "</button>", .link => "</a>", .input => if (std.mem.eql(u8, name, "textarea")) "</textarea>" else "</input>" };
                if (value == .input and std.mem.indexOfPos(u8, source, close + 1, end_tag) == null) {
                    var initial: []const u8 = "";
                    if (std.mem.indexOf(u8, tag, "value=") ) |value_start| {
                        var start = value_start + 6;
                        if (start < tag.len and (tag[start] == '"' or tag[start] == '\'')) {
                            const quote = tag[start];
                            start += 1;
                            const finish = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse tag.len;
                            initial = tag[start..finish];
                        }
                    }
                    document.elements[document.count] = .{ .kind = .input, .text = initial, .accent = std.mem.indexOf(u8, tag, "accent") != null, .muted = std.mem.indexOf(u8, tag, "muted") != null, .danger = std.mem.indexOf(u8, tag, "danger") != null, .color = parseColor(tag) };
                    const length = @min(initial.len, document.input_values[document.count].len);
                    @memcpy(document.input_values[document.count][0..length], initial[0..length]);
                    document.input_lengths[document.count] = length;
                    document.count += 1;
                    cursor = close + 1;
                    continue;
                }
                if (std.mem.indexOfPos(u8, source, close + 1, end_tag)) |end| {
                    var target: []const u8 = "";
                    if (value == .link) {
                        if (std.mem.indexOf(u8, tag, "href=")) |href_start| {
                            var value_start = href_start + 5;
                            if (value_start < tag.len and (tag[value_start] == '"' or tag[value_start] == '\'')) value_start += 1;
                            const quote: u8 = if (href_start + 5 < tag.len and tag[href_start + 5] == '\'') '\'' else '"';
                            const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse tag.len;
                            target = tag[value_start..value_end];
                        }
                    }
                    document.elements[document.count] = .{ .kind = value, .text = std.mem.trim(u8, source[close + 1 .. end], " \t\r\n"), .target = target, .accent = std.mem.indexOf(u8, tag, "accent") != null, .muted = std.mem.indexOf(u8, tag, "muted") != null, .danger = std.mem.indexOf(u8, tag, "danger") != null, .color = parseColor(tag) };
                    if (value == .input) {
                        const initial = document.elements[document.count].text;
                        const length = @min(initial.len, document.input_values[document.count].len);
                        @memcpy(document.input_values[document.count][0..length], initial[0..length]);
                        document.input_lengths[document.count] = length;
                    }
                    document.count += 1;
                    cursor = end + end_tag.len;
                    continue;
                }
            }
            cursor = close + 1;
        }
        return document;
    }

    /// Emits a simple vertical layout consumable by any text renderer.
    pub fn render(self: *const Document, draw: DrawText, origin_x: usize, origin_y: usize) void {
        var y = origin_y;
        for (self.elements[0..self.count], 0..) |element, index| {
            const text = if (element.kind == .input) self.inputText(index) else element.text;
            const color: u32 = element.color orelse switch (element.kind) {
                .heading => 0x70d0ffff,
                .paragraph => 0xa0b8d0ff,
                .container => if (element.muted) 0x788898ff else 0xb0b8c0ff,
                .button => 0xffd070ff,
                .link => 0x70b8ffff,
                .input => 0xd0d0d0ff,
            };
            draw(origin_x, y, text, color);
            y += if (element.kind == .heading) 16 else 12;
        }
    }

    pub fn inputText(self: *const Document, index: usize) []const u8 {
        if (index >= self.count or self.elements[index].kind != .input) return "";
        return self.input_values[index][0..self.input_lengths[index]];
    }

    pub fn editInput(self: *Document, index: usize, byte: u8) bool {
        if (index >= self.count or self.elements[index].kind != .input) return false;
        if (self.input_lengths[index] == self.input_values[index].len) return false;
        self.input_values[index][self.input_lengths[index]] = byte;
        self.input_lengths[index] += 1;
        return true;
    }

    pub fn backspaceInput(self: *Document, index: usize) bool {
        if (index >= self.count or self.elements[index].kind != .input or self.input_lengths[index] == 0) return false;
        self.input_lengths[index] -= 1;
        return true;
    }

    pub fn inputKey(self: *Document, index: usize, key: u8) bool {
        return if (key == 8 or key == 127) self.backspaceInput(index) else if (key >= 0x20 and key <= 0x7e) self.editInput(index, key) else false;
    }

    pub fn hitTest(self: *const Document, x: usize, y: usize, origin_x: usize, origin_y: usize) ?usize {
        var cursor_y = origin_y;
        for (self.elements[0..self.count], 0..) |element, index| {
            const height: usize = if (element.kind == .heading) 16 else 12;
            const width = if (element.kind == .input) @max(element.text.len, 8) * 8 else element.text.len * 8;
            if ((element.kind == .button or element.kind == .link or element.kind == .input) and x >= origin_x and x < origin_x +| width and y >= cursor_y and y < cursor_y + height) return index;
            cursor_y +|= height;
        }
        return null;
    }

    pub fn activateAt(self: *const Document, x: usize, y: usize, origin_x: usize, origin_y: usize) ?[]const u8 {
        const index = self.hitTest(x, y, origin_x, origin_y) orelse return null;
        return if (self.elements[index].kind == .link and self.elements[index].target.len != 0) self.elements[index].target else self.elements[index].text;
    }

    pub fn nextButton(self: *const Document, current: ?usize, forward: bool) ?usize {
        if (self.count == 0) return null;
        var offset: usize = if (current) |value| if (forward) (value + 1) % self.count else if (value == 0) self.count - 1 else value - 1 else if (forward) 0 else self.count - 1;
        var checked: usize = 0;
        while (checked < self.count) : (checked += 1) {
            if (self.elements[offset].kind == .button or self.elements[offset].kind == .link or self.elements[offset].kind == .input) return offset;
            offset = if (forward) (offset + 1) % self.count else if (offset == 0) self.count - 1 else offset - 1;
        }
        return null;
    }

    pub fn activateIndex(self: *const Document, index: usize) ?[]const u8 {
        if (index >= self.count or (self.elements[index].kind != .button and self.elements[index].kind != .link)) return null;
        return if (self.elements[index].kind == .link and self.elements[index].target.len != 0) self.elements[index].target else self.elements[index].text;
    }
};

fn parseColor(tag: []const u8) ?u32 {
    const marker = std.mem.indexOf(u8, tag, "color:#") orelse return null;
    if (marker + 13 > tag.len) return null;
    var value: u32 = 0;
    for (tag[marker + 7 .. marker + 13]) |digit| {
        const nibble: u32 = if (digit >= '0' and digit <= '9') digit - '0' else if (digit >= 'a' and digit <= 'f') digit - 'a' + 10 else if (digit >= 'A' and digit <= 'F') digit - 'A' + 10 else return null;
        value = (value << 4) | nibble;
    }
    return (value << 8) | 0xff;
}

pub const Session = struct {
    document: Document,
    focused: ?usize = null,

    pub fn init(source: []const u8) Session {
        return .{ .document = Document.parse(source) };
    }

    pub fn focusNext(self: *Session, forward: bool) ?usize {
        self.focused = self.document.nextButton(self.focused, forward);
        return self.focused;
    }

    pub fn handleKey(self: *Session, key: u8) bool {
        const index = self.focused orelse return false;
        return self.document.inputKey(index, key);
    }

    /// Hit-tests and activates an interactive element at document coordinates.
    /// Inputs become focused; buttons and links return their action target.
    pub fn activateAt(self: *Session, x: usize, y: usize, origin_x: usize, origin_y: usize) ?[]const u8 {
        const index = self.document.hitTest(x, y, origin_x, origin_y) orelse return null;
        self.focused = index;
        return self.document.activateIndex(index);
    }

    pub fn activateEvent(self: *Session, x: usize, y: usize, origin_x: usize, origin_y: usize) Activation {
        const index = self.document.hitTest(x, y, origin_x, origin_y) orelse return .none;
        self.focused = index;
        return if (self.document.elements[index].kind == .input)
            .{ .focus_input = index }
        else if (self.document.activateIndex(index)) |target|
            .{ .action = target }
        else
            .none;
    }

    pub fn activateFocused(self: *const Session) ?[]const u8 {
        const index = self.focused orelse return null;
        return self.document.activateIndex(index);
    }

    /// Handles keyboard activation commands for the currently focused control.
    pub fn activateKey(self: *const Session, key: u8) ?[]const u8 {
        if (key != 13 and key != 32) return null;
        return self.activateFocused();
    }
};

var rendered_count: usize = 0;
fn countDraw(_: usize, _: usize, _: []const u8, _: u32) void { rendered_count += 1; }

test "HTML subset parses UI elements in document order" {
    const document = Document.parse("<h1>CSOS</h1><p>Ready</p><button>Launch</button>");
    try std.testing.expectEqual(@as(usize, 3), document.count);
    try std.testing.expectEqual(Kind.heading, document.elements[0].kind);
    try std.testing.expectEqualStrings("Ready", document.elements[1].text);
    try std.testing.expectEqual(Kind.button, document.elements[2].kind);
}

test "HTML parser ignores unknown tags but keeps containers" {
    const document = Document.parse("<div>x</div><p>ok</p><script>bad</script>");
    try std.testing.expectEqual(@as(usize, 2), document.count);
    try std.testing.expectEqual(Kind.container, document.elements[0].kind);
    try std.testing.expectEqualStrings("ok", document.elements[1].text);
}

test "HTML subset emits vertical render operations" {
    const document = Document.parse("<h1>Title</h1><p>Body</p><button>Go</button>");
    rendered_count = 0;
    document.render(&countDraw, 4, 8);
    try std.testing.expectEqual(@as(usize, 3), rendered_count);
}

test "HTML buttons support hit testing and activation" {
    const document = Document.parse("<p>Ready</p><button>Launch</button>");
    try std.testing.expect(document.hitTest(12, 13, 4, 4) == null);
    try std.testing.expectEqualStrings("Launch", document.activateAt(12, 20, 4, 4).?);
    try std.testing.expect(document.activateAt(60, 20, 4, 4) == null);
}

test "HTML accent class is preserved for renderers" {
    const document = Document.parse("<button class=accent>Launch</button><p>Ready</p>");
    try std.testing.expect(document.elements[0].accent);
    try std.testing.expect(!document.elements[1].accent);
}

test "HTML muted class is preserved for status text" {
    const document = Document.parse("<p class=muted>ONLINE</p>");
    try std.testing.expect(document.elements[0].muted);
}

test "HTML danger class is preserved for destructive actions" {
    const document = Document.parse("<button class=danger>RESET</button>");
    try std.testing.expect(document.elements[0].danger);
}

test "HTML links are actionable and participate in focus" {
    const document = Document.parse("<p>Menu</p><a href=/system>System</a>");
    try std.testing.expectEqual(Kind.link, document.elements[1].kind);
    try std.testing.expectEqualStrings("/system", document.activateAt(12, 20, 4, 4).?);
    try std.testing.expectEqual(@as(usize, 1), document.nextButton(null, true).?);
    try std.testing.expectEqualStrings("/system", document.activateIndex(1).?);
}

test "HTML button focus cycles with keyboard direction" {
    const document = Document.parse("<p>Top</p><button>One</button><p>Middle</p><button>Two</button>");
    const first = document.nextButton(null, true).?;
    const second = document.nextButton(first, true).?;
    try std.testing.expectEqualStrings("One", document.activateIndex(first).?);
    try std.testing.expectEqualStrings("Two", document.activateIndex(second).?);
    try std.testing.expectEqual(first, document.nextButton(second, true).?);
    try std.testing.expectEqualStrings("Two", document.activateIndex(document.nextButton(null, false).?).?);
}

test "HTML inputs participate in focus and hit testing" {
    const document = Document.parse("<p>Name</p><input>enter</input><button>Go</button>");
    try std.testing.expectEqual(Kind.input, document.elements[1].kind);
    try std.testing.expectEqual(@as(usize, 1), document.nextButton(null, true).?);
    try std.testing.expectEqual(@as(usize, 1), document.hitTest(12, 20, 4, 4).?);
    try std.testing.expect(document.activateIndex(1) == null);
}

test "HTML session activates mouse targets and focuses inputs" {
    var session = Session.init("<p>Name</p><input>enter</input><button>Go</button>");
    try std.testing.expect(session.activateAt(12, 20, 4, 4) == null);
    try std.testing.expectEqual(@as(usize, 1), session.focused.?);
    try std.testing.expectEqualStrings("Go", session.activateAt(12, 32, 4, 4).?);
    try std.testing.expectEqual(@as(usize, 2), session.focused.?);
}

test "HTML activation events distinguish focus from actions" {
    var session = Session.init("<input>name</input><button>Go</button>");
    switch (session.activateEvent(8, 4, 4, 4)) {
        .focus_input => |index| try std.testing.expectEqual(@as(usize, 0), index),
        else => return error.UnexpectedActivation,
    }
    switch (session.activateEvent(8, 16, 4, 4)) {
        .action => |target| try std.testing.expectEqualStrings("Go", target),
        else => return error.UnexpectedActivation,
    }
}

test "HTML session activates focused controls from keyboard navigation" {
    var session = Session.init("<p>Menu</p><button>Launch</button>");
    _ = session.focusNext(true);
    try std.testing.expectEqualStrings("Launch", session.activateFocused().?);
    try std.testing.expectEqualStrings("Launch", session.activateKey(13).?);
    try std.testing.expect(session.activateKey('x') == null);
}

test "HTML input values are mutable independently of source markup" {
    var document = Document.parse("<input>name</input>");
    try std.testing.expectEqualStrings("name", document.inputText(0));
    try std.testing.expect(document.editInput(0, '!'));
    try std.testing.expectEqualStrings("name!", document.inputText(0));
    try std.testing.expect(document.backspaceInput(0));
    try std.testing.expectEqualStrings("name", document.inputText(0));
}

test "HTML input key handler accepts printable bytes and delete" {
    var document = Document.parse("<input></input>");
    try std.testing.expect(document.inputKey(0, 'x'));
    try std.testing.expect(document.inputKey(0, 8));
    try std.testing.expectEqualStrings("", document.inputText(0));
}

test "HTML session preserves focus and input state" {
    var session = Session.init("<p>Label</p><input></input><button>Go</button>");
    try std.testing.expectEqual(@as(usize, 1), session.focusNext(true).?);
    try std.testing.expect(session.handleKey('a'));
    try std.testing.expectEqualStrings("a", session.document.inputText(1));
    try std.testing.expect(session.handleKey(8));
    try std.testing.expectEqualStrings("", session.document.inputText(1));
}
