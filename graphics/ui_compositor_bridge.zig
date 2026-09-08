const std = @import("std");
const ui = @import("ui_backend");

/// Kernel-side adapter: it translates engine-neutral UI requests into the
/// compositor's existing surface operations without exposing DOM/CSS types.
pub const Sink = struct {
    userdata: ?*anyopaque = null,
    present: *const fn (?*anyopaque, *const ui.Surface, ui.Damage) bool,
    resize: *const fn (?*anyopaque, *const ui.Surface) bool,
    close: *const fn (?*anyopaque, u32) void,
};

pub const Bridge = struct {
    backend: *ui.Backend,
    sink: Sink,

    pub fn init(backend: *ui.Backend, sink: Sink) Bridge {
        return .{ .backend = backend, .sink = sink };
    }

    pub fn dispatch(self: *Bridge, request: ui.Request) bool {
        return switch (request) {
            .present => |value| if (value.surface_id == self.backend.surface.id and value.generation == self.backend.surface.generation)
                self.sink.present(self.sink.userdata, &self.backend.surface, value.damage) else false,
            .resize => |value| self.backend.resize(value.width, value.height, self.backend.surface.pixels) and
                self.sink.resize(self.sink.userdata, &self.backend.surface),
            .close => { self.sink.close(self.sink.userdata, self.backend.surface.id); return true; },
            else => true,
        };
    }

    pub fn pump(self: *Bridge) usize {
        var processed: usize = 0;
        while (self.backend.nextRequest()) |request| {
            if (!self.dispatch(request)) break;
            processed += 1;
        }
        return processed;
    }
};

test "bridge forwards present and resize without DOM knowledge" {
    var pixels = [_]u32{0} ** 16;
    var backend = ui.Backend.init(.{ .id = 3, .width = 4, .height = 4, .stride = 4, .pixels = &pixels });
    var presents: usize = 0;
    var resizes: usize = 0;
    const Hooks = struct {
        fn present(value: ?*anyopaque, surface: *const ui.Surface, damage: ui.Damage) bool {
            _ = surface; _ = damage; const count: *usize = @ptrCast(@alignCast(value.?)); count.* += 1; return true;
        }
        fn resize(value: ?*anyopaque, surface: *const ui.Surface) bool {
            _ = surface; const count: *usize = @ptrCast(@alignCast(value.?)); count.* += 1; return true;
        }
        fn close(_: ?*anyopaque, _: u32) void {}
    };
    var bridge = Bridge.init(&backend, .{ .userdata = &presents, .present = Hooks.present, .resize = Hooks.resize, .close = Hooks.close });
    try std.testing.expect(backend.enqueueRequest(.{ .present = .{ .surface_id = 3, .generation = 0, .damage = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } }));
    try std.testing.expectEqual(@as(usize, 1), bridge.pump());
    try std.testing.expectEqual(@as(usize, 1), presents);
    bridge.sink.userdata = &resizes;
    try std.testing.expect(bridge.dispatch(.{ .resize = .{ .width = 2, .height = 2 } }));
    try std.testing.expectEqual(@as(usize, 1), resizes);
}
