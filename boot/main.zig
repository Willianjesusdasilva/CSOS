const std = @import("std");
const uefi = std.os.uefi;
const GraphicsOutput = uefi.protocol.GraphicsOutput;
const kernel = @import("kernel");
const serial = @import("serial");
const ConfigurationTable = uefi.tables.ConfigurationTable;

var memory_map_buffer: [64 * 1024]u8 align(8) = undefined;

pub fn main() void {
    serial.init();
    serial.write("CSOS booting\n");

    const console = uefi.system_table.con_out orelse fail("no UEFI console");
    _ = console.clearScreen() catch {};
    _ = console.outputString(&unicode("CSOS booting\r\n")) catch {};

    const boot_services = uefi.system_table.boot_services orelse fail("no UEFI boot services");
    const rsdp = findRsdp() orelse fail("no ACPI RSDP");
    const graphics = (boot_services.locateProtocol(GraphicsOutput, null) catch fail("GOP lookup failed")) orelse
        fail("no framebuffer");
    const mode = graphics.mode;
    if (mode.info.pixel_format == .blt_only) fail("linear framebuffer unavailable");

    var memory_map = boot_services.getMemoryMap(&memory_map_buffer) catch fail("memory map failed");
    boot_services.exitBootServices(uefi.handle, memory_map.info.key) catch |err| switch (err) {
        error.InvalidParameter => {
            memory_map = boot_services.getMemoryMap(&memory_map_buffer) catch fail("memory map retry failed");
            boot_services.exitBootServices(uefi.handle, memory_map.info.key) catch fail("ExitBootServices failed");
        },
        else => fail("ExitBootServices failed"),
    };

    kernel.start(.{
        .framebuffer = .{
            .base = mode.frame_buffer_base,
            .size = mode.frame_buffer_size,
            .width = mode.info.horizontal_resolution,
            .height = mode.info.vertical_resolution,
            .stride = mode.info.pixels_per_scan_line,
            .pixel_format = @intFromEnum(mode.info.pixel_format),
        },
        .memory_map = memory_map.ptr,
        .memory_map_len = memory_map.info.len,
        .memory_descriptor_size = memory_map.info.descriptor_size,
        .rsdp = rsdp,
    });
}

fn findRsdp() ?u64 {
    const system_table = uefi.system_table;
    for (system_table.configuration_table[0..system_table.number_of_table_entries]) |entry| {
        if (entry.vendor_guid.eql(ConfigurationTable.acpi_20_table_guid)) return @intFromPtr(entry.vendor_table);
    }
    for (system_table.configuration_table[0..system_table.number_of_table_entries]) |entry| {
        if (entry.vendor_guid.eql(ConfigurationTable.acpi_10_table_guid)) return @intFromPtr(entry.vendor_table);
    }
    return null;
}

fn fail(message: []const u8) noreturn {
    serial.write("boot panic: ");
    serial.write(message);
    serial.write("\n");
    while (true) asm volatile ("cli; hlt");
}

fn unicode(comptime text: []const u8) [text.len:0]u16 {
    var result: [text.len:0]u16 = undefined;
    for (text, 0..) |byte, i| result[i] = byte;
    result[text.len] = 0;
    return result;
}
