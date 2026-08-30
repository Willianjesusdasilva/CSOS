const serial = @import("serial");

var user_base: u64 = 0;
var user_size: u64 = 0;
var writes: usize = 0;
pub export var syscall_kernel_rsp: u64 = 0;
pub export var syscall_user_rsp: u64 = 0;

extern fn syscall_entry() callconv(.naked) void;

pub fn install(kernel_stack: u64) void {
    syscall_kernel_rsp = kernel_stack;
    var efer = readMsr(0xc0000080);
    efer |= 1;
    writeMsr(0xc0000080, efer);
    writeMsr(0xc0000081, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    writeMsr(0xc0000082, @intFromPtr(&syscall_entry));
    writeMsr(0xc0000084, 0x200);
}

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

fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr));
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))));
}
