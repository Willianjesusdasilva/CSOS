/// Kernel-side bounded mailbox for the pointer-free csos_ui_backend wire.
/// It only transports validated bytes; surfaces and visual policy stay in the
/// compositor/backend layers.
pub const max_message: usize = 255;
pub const capacity: usize = 16;

pub const Mailbox = struct {
    slots: [capacity][max_message]u8 = undefined,
    lengths: [capacity]u8 = [_]u8{0} ** capacity,
    read_index: usize = 0,
    write_index: usize = 0,

    pub fn push(self: *Mailbox, message: []const u8) bool {
        if (message.len < 2 or message.len > max_message or message[1] != message.len) return false;
        if (self.write_index - self.read_index >= capacity) return false;
        const slot = self.write_index % capacity;
        @memcpy(self.slots[slot][0..message.len], message);
        self.lengths[slot] = @intCast(message.len);
        self.write_index += 1;
        return true;
    }

    pub fn pop(self: *Mailbox, output: []u8) ?usize {
        if (self.read_index == self.write_index) return null;
        const slot = self.read_index % capacity;
        const length = self.lengths[slot];
        if (output.len < length) return null;
        @memcpy(output[0..length], self.slots[slot][0..length]);
        self.read_index += 1;
        return length;
    }
};

test "kernel UI mailbox bounds and preserves wire frames" {
    const std = @import("std");
    var mailbox = Mailbox{};
    const hello = [_]u8{ 9, 4, 1, 0 };
    try std.testing.expect(mailbox.push(&hello));
    var output: [max_message]u8 = undefined;
    const length = mailbox.pop(&output) orelse return error.MissingMessage;
    try std.testing.expectEqual(@as(usize, 4), length);
    try std.testing.expectEqualSlices(u8, &hello, output[0..length]);
    try std.testing.expect(!mailbox.push(&[_]u8{ 9, 4, 1 }));
}
