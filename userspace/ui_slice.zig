const std = @import("std");
const ui = @import("ui_backend");

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024);
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.UiContractMismatch;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try readFile(allocator, "system/ui/interface/desktop.manifest");
    const desktop = try readFile(allocator, "system/ui/interface/desktop.html");
    const topbar = try readFile(allocator, "system/ui/interface/topbar.html");
    const dock = try readFile(allocator, "system/ui/interface/dock.html");
    const launcher = try readFile(allocator, "system/ui/interface/launcher.html");
    const alt_tab = try readFile(allocator, "system/ui/interface/alt-tab.html");
    const css = try readFile(allocator, "system/ui/styles/desktop.css");
    const cpu = std.mem.trim(u8, try readFile(allocator, "system/ui/providers/cpu_usage"), "\r\n");
    const action = try readFile(allocator, "system/ui/scripts/open_files");
    try contains(manifest, "template=desktop.html");
    try contains(manifest, "stylesheet=../styles/desktop.css");
    try contains(manifest, "fragment=topbar.html");
    try contains(manifest, "fragment=dock.html");
    try contains(manifest, "fragment=launcher.html");
    try contains(manifest, "fragment=alt-tab.html");
    try contains(desktop, "{{ CPU_USAGE }}");
    try contains(desktop, "data-action=\"open_files\"");
    try contains(topbar, "{{ NETWORK_IP }}");
    try contains(dock, "data-action=\"open_files\"");
    try contains(launcher, "Buscar aplicações");
    try contains(alt_tab, "focus_files");
    try contains(css, ".launcher");
    try contains(action, "action=open_files");
    if (!std.mem.eql(u8, cpu, "32")) return error.ProviderMismatch;

    var pixels = [_]u32{0} ** (1920 * 4);
    var backend = ui.Backend.init(.{ .id = 1, .buffer_handle = 1, .width = 1920, .height = 1080, .stride = 1920, .pixels = &pixels });
    if (!backend.start() or !backend.negotiate(ui.protocol_version, ui.Capability.surface | ui.Capability.input)) return error.BackendStartup;
    pixels[0] = 0x17294fff;
    if (!backend.enqueueEvent(.{ .pointer = .{ .x = 24, .y = 20, .buttons = 1 } })) return error.InputQueueFailed;
    const pointer = backend.nextEvent() orelse return error.MissingPointerEvent;
    if (pointer != .pointer or pointer.pointer.buttons != 1) return error.PointerRoutingFailed;
    if (!backend.present(.{ .x = 0, .y = 0, .width = 1920, .height = 1080 })) return error.PresentFailed;
    std.debug.print("Zig HTML UI slice passed (provider CPU={s}, surface={d}x{d})\n", .{ cpu, backend.surface.width, backend.surface.height });
}
