const register_select = 0x00;
const register_window = 0x10;
const version_register = 0x01;
const redirection_base = 0x10;
const masked = 1 << 16;

pub fn init(address: u32) !void {
    if ((address & 0xfff) != 0) return error.UnalignedAddress;
    const version = read(address, version_register);
    if (version == 0 or version == 0xffffffff) return error.NotPresent;
    const max_entry: u8 = @truncate(version >> 16);
    if (max_entry > 239) return error.InvalidVersion;

    var entry: u32 = 0;
    while (entry <= max_entry) : (entry += 1) {
        write(address, redirection_base + entry * 2 + 1, 0);
        write(address, redirection_base + entry * 2, masked);
    }
}

fn read(address: u32, register: u32) u32 {
    const select: *volatile u32 = @ptrFromInt(@as(u64, address) + register_select);
    const window: *volatile u32 = @ptrFromInt(@as(u64, address) + register_window);
    select.* = register;
    return window.*;
}

fn write(address: u32, register: u32, value: u32) void {
    const select: *volatile u32 = @ptrFromInt(@as(u64, address) + register_select);
    const window: *volatile u32 = @ptrFromInt(@as(u64, address) + register_window);
    select.* = register;
    window.* = value;
}
