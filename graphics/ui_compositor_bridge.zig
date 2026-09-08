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
            .hello => |value| if (value.version == ui.protocol_version) blk: {
                self.backend.negotiated_version = ui.protocol_version;
                self.backend.negotiated_capabilities = value.capabilities & ui.supported_capabilities;
                break :blk self.backend.enqueueResponse(.{ .hello_ack = .{ .version = ui.protocol_version, .capabilities = self.backend.negotiated_capabilities } });
            } else false,
            .create_window => |value| self.backend.resize(value.width, value.height, self.backend.surface.pixels) and
                self.sink.resize(self.sink.userdata, &self.backend.surface),
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

    pub fn pushEvent(self: *Bridge, event: ui.Event) bool {
        return self.backend.enqueueEvent(event);
    }
};

test "bridge forwards present and resize without DOM knowledge" {
    var pixels = [_]u32{0} ** 16;
    var backend = ui.Backend.init(.{ .id = 3, .width = 4, .height = 4, .stride = 4, .pixels = &pixels });
    var presents: usize = 0;
    var resizes: usize = 0;
    var closes: usize = 0;
    const Hooks = struct {
        fn present(value: ?*anyopaque, surface: *const ui.Surface, damage: ui.Damage) bool {
            _ = surface; _ = damage; const count: *usize = @ptrCast(@alignCast(value.?)); count.* += 1; return true;
        }
        fn resize(value: ?*anyopaque, surface: *const ui.Surface) bool {
            _ = surface; const count: *usize = @ptrCast(@alignCast(value.?)); count.* += 1; return true;
        }
        fn close(value: ?*anyopaque, _: u32) void { const count: *usize = @ptrCast(@alignCast(value.?)); count.* += 1; }
    };
    var bridge = Bridge.init(&backend, .{ .userdata = &presents, .present = Hooks.present, .resize = Hooks.resize, .close = Hooks.close });
    try std.testing.expect(backend.enqueueRequest(.{ .hello = .{ .version = ui.protocol_version, .capabilities = ui.supported_capabilities } }));
    try std.testing.expectEqual(@as(usize, 1), bridge.pump());
    switch (backend.nextResponse().?) {
        .hello_ack => |ack| try std.testing.expectEqual(ui.supported_capabilities, ack.capabilities),
        else => return error.UnexpectedBridgeResponse,
    }
    try std.testing.expect(backend.enqueueRequest(.{ .create_window = .{ .width = 2, .height = 2, .title = "demo" } }));
    try std.testing.expectEqual(@as(usize, 1), bridge.pump());
    switch (backend.nextResponse().?) {
        .surface_created => |info| try std.testing.expectEqual(@as(u16, 2), info.width),
        else => return error.UnexpectedBridgeResponse,
    }
    presents = 0;
    try std.testing.expect(backend.enqueueRequest(.{ .present = .{ .surface_id = 3, .generation = 1, .damage = .{ .x = 0, .y = 0, .width = 2, .height = 2 } } }));
    try std.testing.expectEqual(@as(usize, 1), bridge.pump());
    try std.testing.expectEqual(@as(usize, 1), presents);
    bridge.sink.userdata = &resizes;
    try std.testing.expect(bridge.dispatch(.{ .resize = .{ .width = 2, .height = 2 } }));
    try std.testing.expectEqual(@as(usize, 1), resizes);
    while (backend.nextEvent()) |_| {}
    try std.testing.expect(bridge.pushEvent(.{ .pointer = .{ .x = 12, .y = 8, .buttons = 1 } }));
    switch (backend.nextEvent().?) {
        .pointer => |pointer| { try std.testing.expectEqual(@as(i32, 12), pointer.x); try std.testing.expectEqual(@as(u8, 1), pointer.buttons); },
        else => return error.UnexpectedBridgeEvent,
    }
    bridge.sink.userdata = &closes;
    try std.testing.expect(bridge.dispatch(.{ .close = {} }));
    try std.testing.expectEqual(@as(usize, 1), closes);
}
