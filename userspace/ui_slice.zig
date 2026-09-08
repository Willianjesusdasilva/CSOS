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

fn append(dst: []u8, used: *usize, text: []const u8) !void {
    if (text.len > dst.len - used.*) return error.UiCompositionTooLarge;
    @memcpy(dst[used.* .. used.* + text.len], text);
    used.* += text.len;
}

fn paintSurface(pixels: []u32, width: usize, height: usize, document: []const u8) void {
    @memset(pixels, 0x101a38ff);
    var y: usize = 24;
    var lines = std.mem.splitScalar(u8, document, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \r\t");
        if (text.len == 0 or y + 8 >= height) continue;
        const bar_width = @min(width -| 32, 16 + text.len * 4);
        for (0..bar_width) |x| pixels[y * width + 16 + x] = 0x70d0ffff;
        y += 18;
    }
}

fn configuredPath(config: []const u8, name: []const u8) ![]const u8 {
    var key: [64]u8 = undefined;
    const key_text = try std.fmt.bufPrint(&key, "{s}=\"", .{name});
    const start = (std.mem.indexOf(u8, config, key_text) orelse return error.MissingVariable) + key_text.len;
    const end = std.mem.indexOfScalarPos(u8, config, start, '"') orelse return error.InvalidVariable;
    return config[start..end];
}

fn validateActions(document: []const u8) !void {
    const allowed = [_][]const u8{ "open_files", "open_terminal", "open_browser", "open_settings", "open_monitor", "open_store", "focus_files", "focus_terminal", "focus_browser", "pause_media" };
    var rest = document;
    while (std.mem.indexOf(u8, rest, "data-action=\"") ) |offset| {
        const start = offset + "data-action=\"".len;
        const end = std.mem.indexOfScalarPos(u8, rest, start, '\"') orelse return error.InvalidAction;
        const action_name = rest[start..end];
        var known = false;
        for (allowed) |candidate| {
            if (std.mem.eql(u8, action_name, candidate)) known = true;
        }
        if (!known) return error.UnauthorizedAction;
        rest = rest[end + 1 ..];
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = try readFile(allocator, "system/ui/interface/desktop.manifest");
    const variables = try readFile(allocator, "system/ui/variables.conf");
    const desktop = try readFile(allocator, "system/ui/interface/desktop.html");
    const topbar = try readFile(allocator, "system/ui/interface/topbar.html");
    const dock = try readFile(allocator, "system/ui/interface/dock.html");
    const launcher = try readFile(allocator, "system/ui/interface/launcher.html");
    const alt_tab = try readFile(allocator, "system/ui/interface/alt-tab.html");
    const widgets = try readFile(allocator, "system/ui/interface/widgets.html");
    const sidebar = try readFile(allocator, "system/ui/interface/sidebar.html");
    const wallpaper = try readFile(allocator, "system/ui/interface/wallpaper.html");
    const notifications = try readFile(allocator, "system/ui/interface/notifications.html");
    const media = try readFile(allocator, "system/ui/interface/media.html");
    const terminal = try readFile(allocator, "system/ui/interface/terminal.html");
    const status = try readFile(allocator, "system/ui/interface/status.html");
    const desktop_actions = try readFile(allocator, "system/ui/interface/desktop-actions.html");
    const css = try readFile(allocator, "system/ui/styles/desktop.css");
    const terminal_css = try readFile(allocator, "system/ui/styles/terminal.css");
    const cpu_path = try configuredPath(variables, "CPU_USAGE");
    const cpu_relative = if (std.mem.startsWith(u8, cpu_path, "/")) cpu_path[1..] else cpu_path;
    const cpu = std.mem.trim(u8, try readFile(allocator, cpu_relative), "\r\n");
    const action = try readFile(allocator, "system/ui/scripts/open_files");
    var composed: [16384]u8 = undefined;
    var composed_len: usize = 0;
    try contains(manifest, "template=desktop.html");
    try contains(manifest, "stylesheet=../styles/desktop.css");
    try contains(manifest, "fragment=topbar.html");
    try contains(manifest, "fragment=dock.html");
    try contains(manifest, "fragment=launcher.html");
    try contains(manifest, "fragment=alt-tab.html");
    try contains(manifest, "fragment=widgets.html");
    try contains(manifest, "fragment=sidebar.html");
    try contains(manifest, "fragment=wallpaper.html");
    try contains(manifest, "fragment=notifications.html");
    try contains(manifest, "fragment=media.html");
    try contains(manifest, "fragment=terminal.html");
    try contains(manifest, "fragment=status.html");
    try contains(manifest, "fragment=desktop-actions.html");
    try contains(manifest, "stylesheet=../styles/terminal.css");
    try contains(desktop_actions, "data-action=\"open_files\"");
    try contains(topbar, "{{ NETWORK_IP }}");
    try contains(dock, "data-action=\"open_files\"");
    try contains(launcher, "Buscar aplicações");
    try contains(alt_tab, "focus_files");
    try contains(widgets, "{{ CURRENT_FPS }}");
    try contains(sidebar, "{{ NETWORK_IP }}");
    try contains(wallpaper, "class=\"wallpaper\"");
    try contains(notifications, "data-action=\"open_store\"");
    try contains(media, "data-action=\"pause_media\"");
    try contains(terminal, "class=\"terminal-window\"");
    try contains(terminal, "CSOS shell");
    try contains(status, "{{ CPU_USAGE }}");
    try contains(status, "class=\"status-card\"");
    try append(&composed, &composed_len, desktop);
    var manifest_lines = std.mem.splitScalar(u8, manifest, '\n');
    while (manifest_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (std.mem.startsWith(u8, line, "fragment=")) {
            const name = line[9..];
            if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null or std.mem.startsWith(u8, name, "/")) return error.InvalidFragmentPath;
            const path = try std.fmt.allocPrint(allocator, "system/ui/interface/{s}", .{name});
            try append(&composed, &composed_len, try readFile(allocator, path));
        } else if (std.mem.startsWith(u8, line, "stylesheet=")) {
            const name = line[11..];
            if (!std.mem.startsWith(u8, name, "../styles/") or std.mem.indexOf(u8, name[10..], "..") != null) return error.InvalidStylesheetPath;
            if (std.mem.endsWith(u8, name, "terminal.css")) try append(&composed, &composed_len, terminal_css) else try append(&composed, &composed_len, css);
        }
    }
    try contains(composed[0..composed_len], "data-action=\"open_files\"");
    try contains(composed[0..composed_len], ".launcher");
    try contains(composed[0..composed_len], ".terminal-window");
    try validateActions(composed[0..composed_len]);
    const variable_names = [_][]const u8{ "CPU_USAGE", "RAM_USAGE", "GPU_USAGE", "NETWORK_IP", "CURRENT_FPS", "FRAME_TIME" };
    var expanded: []const u8 = composed[0..composed_len];
    for (variable_names) |name| {
        const configured = try configuredPath(variables, name);
        if (!std.mem.startsWith(u8, configured, "/system/ui/providers/")) return error.ProviderOutsideReadOnlyTree;
        const path = if (std.mem.startsWith(u8, configured, "/")) configured[1..] else configured;
        const value = std.mem.trim(u8, try readFile(allocator, path), "\r\n");
        if (std.mem.indexOf(u8, value, "action=") != null or std.mem.indexOf(u8, value, "exec=") != null)
            return error.ProviderContainsAction;
        expanded = try std.mem.replaceOwned(u8, allocator, expanded, try std.fmt.allocPrint(allocator, "{{{{ {s} }}}}", .{name}), value);
    }
    if (std.mem.indexOf(u8, expanded, "{{") != null) return error.UnresolvedProvider;
    try contains(expanded, "CPU 32%");
    try contains(css, ".launcher");
    try contains(action, "action=open_files");
    try contains(action, "capability=window");
    const actions = [_][]const u8{ "open_terminal", "open_browser", "open_settings", "open_monitor", "open_store", "focus_files", "focus_terminal", "focus_browser", "pause_media" };
    for (actions) |action_name| {
        const action_path = try std.fmt.allocPrint(allocator, "system/ui/scripts/{s}", .{action_name});
        const action_file = try readFile(allocator, action_path);
        const declaration = try std.fmt.allocPrint(allocator, "action={s}", .{action_name});
        try contains(action_file, declaration);
        try contains(action_file, "capability=");
        if (std.mem.indexOf(u8, action_file, "exec=") != null or std.mem.indexOf(u8, action_file, "command=") != null)
            return error.ArbitraryActionCommand;
    }
    if (!std.mem.eql(u8, cpu, "32")) return error.ProviderMismatch;

    const pixels = try allocator.alloc(u32, 1920 * 1080);
    paintSurface(pixels, 1920, 1080, expanded);
    var backend = ui.Backend.init(.{ .id = 1, .buffer_handle = 1, .width = 1920, .height = 1080, .stride = 1920, .pixels = pixels });
    if (!backend.start() or !backend.negotiate(ui.protocol_version, ui.Capability.surface | ui.Capability.input)) return error.BackendStartup;
    if (pixels[24 * 1920 + 16] != 0x70d0ffff) return error.SurfaceNotPainted;
    if (!backend.enqueueEvent(.{ .pointer = .{ .x = 24, .y = 20, .buttons = 1 } })) return error.InputQueueFailed;
    const pointer = backend.nextEvent() orelse return error.MissingPointerEvent;
    if (pointer != .pointer or pointer.pointer.buttons != 1) return error.PointerRoutingFailed;
    if (!backend.present(.{ .x = 0, .y = 0, .width = 1920, .height = 1080 })) return error.PresentFailed;
    std.debug.print("Zig HTML UI slice passed (provider CPU={s}, surface={d}x{d})\n", .{ cpu, backend.surface.width, backend.surface.height });
}
