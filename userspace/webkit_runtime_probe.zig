//! A real musl pthread prerequisite probe, NOT JavaScriptCore or WebKit.
//! The child must execute, preserve its own TLS, and return through join.
const std = @import("std");
extern "c" fn pthread_create(*usize, ?*const anyopaque, *const fn (?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) c_int;
extern "c" fn pthread_join(usize, *?*anyopaque) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn _exit(c_int) noreturn;
threadlocal var tls_value: usize = 0;
var child_ran: bool = false;

fn output(message: []const u8) void {
    var offset: usize = 0;
    while (offset < message.len) {
        const written = write(1, message.ptr + offset, message.len - offset);
        if (written <= 0) _exit(90);
        offset += @intCast(written);
    }
}
fn child(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (tls_value != 0) return @ptrFromInt(2);
    tls_value = 73;
    child_ran = true;
    return @ptrFromInt(73);
}
pub fn main() void {
    output("CSOS WebKit prerequisite probe: musl pthread/TLS/join\n");
    tls_value = 41;
    var thread: usize = 0;
    const created = pthread_create(&thread, null, child, null);
    if (created != 0) {
        var buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "CSOS WebKit prerequisite FAIL: pthread_create errno={d}\n", .{created}) catch unreachable;
        output(message);
        _exit(21);
    }
    var result: ?*anyopaque = null;
    if (pthread_join(thread, &result) != 0) {
        output("CSOS WebKit prerequisite FAIL: pthread_join\n");
        _exit(22);
    }
    if (!child_ran or result != @as(?*anyopaque, @ptrFromInt(73)) or tls_value != 41) {
        output("CSOS WebKit prerequisite FAIL: child execution or TLS isolation\n");
        _exit(23);
    }
    output("CSOS WebKit prerequisite PASS: pthread/TLS/join only\n");
}
