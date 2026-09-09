//! A real musl pthread prerequisite probe, NOT JavaScriptCore or WebKit.
//! The child must execute, preserve its own TLS, and return through join.
const std = @import("std");
extern "c" fn pthread_create(*usize, ?*const anyopaque, *const fn (?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) c_int;
extern "c" fn pthread_join(usize, *?*anyopaque) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn eventfd(c_uint, c_int) c_int;
extern "c" fn poll(*PollFd, usize, c_int) c_int;
const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern "c" fn pthread_mutex_lock(*anyopaque) c_int;
extern "c" fn pthread_mutex_unlock(*anyopaque) c_int;
extern "c" fn pthread_cond_wait(*anyopaque, *anyopaque) c_int;
extern "c" fn pthread_cond_broadcast(*anyopaque) c_int;
extern "c" fn sched_yield() c_int;
// x86_64 musl ABI, zero initializers are PTHREAD_*_INITIALIZER.
var mutex: [40]u8 align(8) = @splat(0);
var condition: [48]u8 align(8) = @splat(0);
var ready: usize = 0;
var go: bool = false;
var counter: usize = 0;
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
fn worker(argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const id = @intFromPtr(argument);
    if (tls_value != 0) _exit(31);
    tls_value = id;
    if (pthread_mutex_lock(&mutex) != 0) _exit(32);
    ready += 1;
    if (pthread_cond_broadcast(&condition) != 0) _exit(33);
    while (!go) {
        if (pthread_cond_wait(&condition, &mutex) != 0) _exit(34);
    }
    if (pthread_mutex_unlock(&mutex) != 0) _exit(35);
    for (0..100) |_| {
        if (pthread_mutex_lock(&mutex) != 0) _exit(36);
        const previous = counter;
        // Force a switch while holding the lock: other workers must block.
        if (sched_yield() != 0) _exit(37);
        counter = previous + 1;
        if (tls_value != id) _exit(38);
        if (pthread_mutex_unlock(&mutex) != 0) _exit(39);
    }
    return argument;
}
pub fn main() void {
    output("CSOS WebKit prerequisite probe: musl pthread/TLS/join\n");
    const event = eventfd(0, 0x80000 | 0x800);
    if (event < 0) { output("CSOS WebKit prerequisite FAIL: eventfd\n"); _exit(20); }
    var event_counter: u64 = 1;
    if (write(event, @ptrCast(&event_counter), 8) != 8) _exit(20);
    var pollfd = PollFd{ .fd = event, .events = 1, .revents = 0 };
    if (poll(&pollfd, 1, 0) != 1 or (pollfd.revents & 1) == 0) _exit(20);
    var read_counter: u64 = 0;
    if (read(event, @ptrCast(&read_counter), 8) != 8 or read_counter != 1) _exit(20);
    output("CSOS WebKit prerequisite PASS: eventfd/poll\n");
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
    var workers: [3]usize = undefined;
    for (&workers, 0..) |*thread_id, i| {
        if (pthread_create(thread_id, null, worker, @ptrFromInt(100 + i)) != 0) _exit(40);
    }
    if (pthread_mutex_lock(&mutex) != 0) _exit(41);
    while (ready != workers.len) {
        if (pthread_cond_wait(&condition, &mutex) != 0) _exit(42);
    }
    go = true;
    if (pthread_cond_broadcast(&condition) != 0) _exit(43);
    if (pthread_mutex_unlock(&mutex) != 0) _exit(44);
    for (workers, 0..) |thread_id, i| {
        if (pthread_join(thread_id, &result) != 0 or @intFromPtr(result) != 100 + i) _exit(45);
    }
    if (counter != 300 or tls_value != 41) _exit(46);
    output("CSOS WebKit threads PASS: mutex/condition/shared-memory/TLS/join counter=300\n");
}
