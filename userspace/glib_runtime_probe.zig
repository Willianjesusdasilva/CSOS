//! Uses upstream GLib, not a replacement event loop.
extern "c" fn g_strdup([*:0]const u8) ?[*:0]u8;
extern "c" fn g_free(?*anyopaque) void;
extern "c" fn g_thread_new([*:0]const u8, *const fn (?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) ?*anyopaque;
extern "c" fn g_thread_join(*anyopaque) ?*anyopaque;
extern "c" fn g_main_loop_new(?*anyopaque, c_int) ?*anyopaque;
extern "c" fn g_main_loop_run(*anyopaque) void;
extern "c" fn g_main_loop_quit(*anyopaque) void;
extern "c" fn g_main_loop_unref(*anyopaque) void;
extern "c" fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern "c" fn g_get_monotonic_time() i64;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn _exit(c_int) noreturn;
var fired: bool = false;
fn say(s: []const u8) void {
    var offset: usize = 0;
    while (offset < s.len) {
        const n = write(1, s.ptr + offset, s.len - offset);
        if (n <= 0) _exit(90);
        offset += @intCast(n);
    }
}
fn worker(p: ?*anyopaque) callconv(.c) ?*anyopaque { return p; }
fn timer(p: ?*anyopaque) callconv(.c) c_int {
    fired = true;
    g_main_loop_quit(p.?);
    return 0;
}
pub fn main() void {
    say("CSOS upstream GLib probe start\n");
    const copy = g_strdup("CSOS") orelse _exit(10);
    if (copy[0] != 'C' or copy[3] != 'S' or copy[4] != 0) _exit(11);
    g_free(copy);
    const thread = g_thread_new("csos-glib", worker, @ptrFromInt(73)) orelse _exit(12);
    if (@intFromPtr(g_thread_join(thread)) != 73) _exit(13);
    say("CSOS upstream GLib core/thread PASS\n");
    const loop = g_main_loop_new(null, 0) orelse _exit(14);
    const start = g_get_monotonic_time();
    if (g_timeout_add(20, timer, loop) == 0) _exit(15);
    g_main_loop_run(loop);
    const elapsed = g_get_monotonic_time() - start;
    if (!fired or elapsed < 20000) _exit(16);
    g_main_loop_unref(loop);
    say("CSOS upstream GLib event-loop/timer PASS\n");
}
