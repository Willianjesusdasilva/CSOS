const std = @import("std");

pub const Kind = enum { heading, paragraph, button };
pub const Element = struct { kind: Kind, text: []const u8 };

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
};

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
