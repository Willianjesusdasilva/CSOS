const serial = @import("serial");

var user_base: u64 = 0;
var user_size: u64 = 0;
var writes: usize = 0;

pub fn configure(base: u64, size: u64) void {
    user_base = base;
    user_size = size;
    writes = 0;
}

pub fn completedWrites() usize {
    return writes;
}

export fn user_syscall_dispatch(number: u64, arg1: u64, arg2: u64, arg3: u64) callconv(.c) u64 {
    if (number != 1) return errno(38);
    if (arg1 != 1 or !validUserSlice(arg2, arg3)) return errno(14);
    const text: [*]const u8 = @ptrFromInt(arg2);
    serial.write(text[0..@intCast(arg3)]);
    writes += 1;
    return arg3;
}

fn validUserSlice(address: u64, length: u64) bool {
    if (address < user_base or length > user_size) return false;
    return address - user_base <= user_size - length;
}

fn errno(value: i64) u64 {
    return @bitCast(-value);
}
