const std = @import("std");
const uefi = std.os.uefi;

pub fn main() void {
    const console = uefi.system_table.con_out orelse return;
    _ = console.clearScreen() catch {};
    _ = console.outputString(&unicode("CSOS booting\r\n")) catch {};

    while (true) asm volatile ("hlt");
}

fn unicode(comptime text: []const u8) [text.len:0]u16 {
    var result: [text.len:0]u16 = undefined;
    for (text, 0..) |byte, i| result[i] = byte;
    result[text.len] = 0;
    return result;
}
