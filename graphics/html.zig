const std = @import("std");

pub const Kind = enum { heading, paragraph, button };
pub const Element = struct { kind: Kind, text: []const u8 };
pub const DrawText = *const fn (x: usize, y: usize, text: []const u8, color: u32) void;

/// Small allocation-free HTML subset used by the planned system UI.
/// Supported elements are h1, p and button; unknown tags are ignored while
/// their text remains available to the next supported element.
pub const Document = struct {
    elements: [16]Element = undefined,
    count: usize = 0,

    pub fn parse(source: []const u8) Document {
        var document = Document{};
        var cursor: usize = 0;
        while (cursor < source.len and document.count < document.elements.len) {
            const open = std.mem.indexOfScalarPos(u8, source, cursor, '<') orelse break;
            const close = std.mem.indexOfScalarPos(u8, source, open + 1, '>') orelse break;
            const tag = source[open + 1 .. close];
            const kind: ?Kind = if (std.mem.eql(u8, tag, "h1")) .heading else if (std.mem.eql(u8, tag, "p")) .paragraph else if (std.mem.eql(u8, tag, "button")) .button else null;
            if (kind) |value| {
                const end_tag = switch (value) { .heading => "</h1>", .paragraph => "</p>", .button => "</button>" };
                if (std.mem.indexOfPos(u8, source, close + 1, end_tag)) |end| {
                    document.elements[document.count] = .{ .kind = value, .text = std.mem.trim(u8, source[close + 1 .. end], " \t\r\n") };
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
        for (self.elements[0..self.count]) |element| {
            const color: u32 = switch (element.kind) {
                .heading => 0x70d0ffff,
                .paragraph => 0xa0b8d0ff,
                .button => 0xffd070ff,
            };
            draw(origin_x, y, element.text, color);
            y += if (element.kind == .heading) 16 else 12;
        }
    }

    pub fn hitTest(self: *const Document, x: usize, y: usize, origin_x: usize, origin_y: usize) ?usize {
        var cursor_y = origin_y;
        for (self.elements[0..self.count], 0..) |element, index| {
            const height: usize = if (element.kind == .heading) 16 else 12;
            if (element.kind == .button and x >= origin_x and x < origin_x +| element.text.len * 8 and y >= cursor_y and y < cursor_y + height) return index;
            cursor_y +|= height;
        }
        return null;
    }

    pub fn activateAt(self: *const Document, x: usize, y: usize, origin_x: usize, origin_y: usize) ?[]const u8 {
        const index = self.hitTest(x, y, origin_x, origin_y) orelse return null;
        return self.elements[index].text;
    }

    pub fn nextButton(self: *const Document, current: ?usize, forward: bool) ?usize {
        if (self.count == 0) return null;
        var offset: usize = if (current) |value| if (forward) (value + 1) % self.count else if (value == 0) self.count - 1 else value - 1 else if (forward) 0 else self.count - 1;
        var checked: usize = 0;
        while (checked < self.count) : (checked += 1) {
            if (self.elements[offset].kind == .button) return offset;
            offset = if (forward) (offset + 1) % self.count else if (offset == 0) self.count - 1 else offset - 1;
        }
        return null;
    }

    pub fn activateIndex(self: *const Document, index: usize) ?[]const u8 {
        if (index >= self.count or self.elements[index].kind != .button) return null;
        return self.elements[index].text;
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

test "HTML subset ignores unsupported tags" {
    const document = Document.parse("<div>x</div><p>ok</p><script>bad</script>");
    try std.testing.expectEqual(@as(usize, 1), document.count);
    try std.testing.expectEqualStrings("ok", document.elements[0].text);
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

test "HTML button focus cycles with keyboard direction" {
    const document = Document.parse("<p>Top</p><button>One</button><p>Middle</p><button>Two</button>");
    const first = document.nextButton(null, true).?;
    const second = document.nextButton(first, true).?;
    try std.testing.expectEqualStrings("One", document.activateIndex(first).?);
    try std.testing.expectEqualStrings("Two", document.activateIndex(second).?);
    try std.testing.expectEqual(first, document.nextButton(second, true).?);
    try std.testing.expectEqualStrings("Two", document.activateIndex(document.nextButton(null, false).?).?);
}
