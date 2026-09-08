const std = @import("std");
const ui = @import("ui_backend");

const Endpoint = struct {
    request: [256]u8 = undefined,
    response: [256]u8 = undefined,
    surface_alive: bool = false,
    presents: u32 = 0,

    fn roundTrip(self: *Endpoint, request: ui.Request) !ui.Response {
        const request_len = try ui.encodeRequest(request, self.request[0..]);
        const decoded = try ui.decodeRequest(self.request[0..request_len]);
        const response: ui.Response = switch (decoded) {
            .hello => |hello| ui.Response{ .hello_ack = .{ .version = hello.version, .capabilities = hello.capabilities & ui.supported_capabilities } },
            .create_window => |window| blk: {
                if (window.width == 0 or window.height == 0) break :blk .{ .failure = 1 };
                self.surface_alive = true;
                break :blk .{ .surface_created = .{ .id = 1, .buffer_handle = 1, .width = window.width, .height = window.height, .stride = @as(u32, window.width) * 4, .format = .rgba8888, .generation = 1 } };
            },
            .present => |present| blk: {
                if (!self.surface_alive or present.surface_id != 1) break :blk .{ .failure = 2 };
                self.presents += 1;
                break :blk .{ .hello_ack = .{ .version = ui.protocol_version, .capabilities = ui.Capability.surface | ui.Capability.damage } };
            },
            .destroy_window => |id| blk: {
                if (!self.surface_alive or id != 1) break :blk .{ .failure = 3 };
                self.surface_alive = false;
                break :blk .{ .surface_destroyed = id };
            },
            else => .{ .failure = 4 },
        };
        const response_len = try ui.encodeResponse(response, self.response[0..]);
        return try ui.decodeResponse(self.response[0..response_len]);
    }
};

pub fn main() !void {
    var endpoint = Endpoint{};
    const hello = try endpoint.roundTrip(.{ .hello = .{ .version = ui.protocol_version, .capabilities = ui.supported_capabilities } });
    try expectHello(hello);
    const created = try endpoint.roundTrip(.{ .create_window = .{ .width = 640, .height = 480, .title = "FILES" } });
    switch (created) { .surface_created => |surface| try std.testing.expect(surface.width == 640 and surface.height == 480), else => return error.BadResponse }
    _ = try endpoint.roundTrip(.{ .present = .{ .surface_id = 1, .generation = 1, .damage = .{ .x = 0, .y = 0, .width = 640, .height = 480 } } });
    const destroyed = try endpoint.roundTrip(.{ .destroy_window = 1 });
    switch (destroyed) { .surface_destroyed => |id| try std.testing.expect(id == 1), else => return error.BadResponse }
    try std.testing.expect(endpoint.presents == 1 and !endpoint.surface_alive);
    std.debug.print("Zig UI IPC wire loopback passed (requests=5, presents={d})\n", .{endpoint.presents});
}

fn expectHello(response: ui.Response) !void {
    switch (response) { .hello_ack => |ack| try std.testing.expect(ack.version == ui.protocol_version), else => return error.BadResponse }
}
