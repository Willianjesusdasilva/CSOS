const std = @import("std");
const ui = @import("ui_backend");

pub const RenderCallback = *const fn (backend: *ui.Backend) bool;

pub const Engine = struct {
    backend: *ui.Backend,
    transport: ui.WireTransport,
    render: RenderCallback,
    running: bool = false,
    frames: u64 = 0,

    pub fn start(self: *Engine) bool {
        if (self.running or !self.backend.start()) return false;
        self.running = true;
        return true;
    }

    pub fn step(self: *Engine) !bool {
        if (!self.running) return false;
        if (!try self.backend.pumpTransport(self.transport)) return false;
        if (!(self.render)(self.backend)) return false;
        self.frames += 1;
        return true;
    }

    pub fn stop(self: *Engine) bool {
        if (!self.running) return false;
        self.running = false;
        return self.backend.stop();
    }
};

test "userspace engine loop pumps transport and renders frames" {
    var pixels = [_]u32{0} ** 4;
    var backend = ui.Backend.init(.{ .id = 30, .width = 2, .height = 2, .stride = 2, .pixels = &pixels });
    var request_count: usize = 0;
    const Hooks = struct {
        fn send(context: *anyopaque, message: []const u8) bool {
            const count: *usize = @ptrCast(@alignCast(context));
            _ = ui.decodeRequest(message) catch return false;
            count.* += 1;
            return true;
        }
        fn receive(_: *anyopaque, _: []u8) ?usize { return null; }
        fn render(target: *ui.Backend) bool { return target.present(.{ .x = 0, .y = 0, .width = 2, .height = 2 }); }
    };
    var engine = Engine{ .backend = &backend, .transport = .{ .context = &request_count, .send = Hooks.send, .receive = Hooks.receive }, .render = Hooks.render };
    try std.testing.expect(backend.negotiate(ui.protocol_version, ui.Capability.surface));
    try std.testing.expect(engine.start());
    try std.testing.expect(try engine.step());
    try std.testing.expectEqual(@as(u64, 1), engine.frames);
    try std.testing.expect(request_count == 1);
    try std.testing.expect(engine.stop());
}
