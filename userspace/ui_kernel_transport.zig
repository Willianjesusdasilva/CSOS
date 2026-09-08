/// Userspace adapter for the kernel UI mailbox ABI.
/// The HTML engine sees only send/receive; syscall entry is injectable in tests.
pub const syscall_ui_channel_create: u64 = 450;
pub const syscall_ui_channel_send: u64 = 451;
pub const syscall_ui_channel_receive: u64 = 452;

pub const Syscall = *const fn (number: u64, arg1: u64, arg2: u64, arg3: u64) callconv(.c) u64;

pub const Transport = struct {
    channel: u64 = 0,
    syscall: Syscall,

    pub fn open(self: *Transport) bool {
        self.channel = (self.syscall)(syscall_ui_channel_create, 0, 0, 0);
        return self.channel != 0;
    }

    pub fn send(self: *Transport, message: []const u8) bool {
        if (self.channel == 0 or message.len < 2 or message.len > 255) return false;
        return (self.syscall)(syscall_ui_channel_send, self.channel, @intFromPtr(message.ptr), message.len) == message.len;
    }

    pub fn receive(self: *Transport, output: []u8) ?usize {
        if (self.channel == 0 or output.len < 2 or output.len > 255) return null;
        const result = (self.syscall)(syscall_ui_channel_receive, self.channel, @intFromPtr(output.ptr), output.len);
        return if (result <= output.len) result else null;
    }
};

test "userspace UI transport maps channel syscalls" {
    const std = @import("std");
    const Mock = struct {
        fn call(number: u64, _: u64, _: u64, _: u64) callconv(.c) u64 {
            return switch (number) { syscall_ui_channel_create => 3, syscall_ui_channel_send => 2, syscall_ui_channel_receive => 0, else => 0 };
        }
    };
    var transport = Transport{ .syscall = Mock.call };
    try std.testing.expect(transport.open());
    try std.testing.expect(transport.send(&[_]u8{ 9, 2 }));
    var output: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), transport.receive(&output));
}
