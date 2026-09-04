const syscalls = @import("syscalls");
const builtin = @import("builtin");

extern "kernel32" fn VirtualAlloc(?*anyopaque, usize, u32, u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(*anyopaque, usize, u32) callconv(.winapi) i32;

test "AMDGPU ioctl ABI validates state before dispatch and signals after fence" {
    try syscalls.validateAmdGpuDrmAbiSelfTest();
}

test "GEM aligned GTT and exhausted VRAM fallback preserve backing memory" {
    // The real GEM handler rejects physical addresses above 44 bits. Reserve
    // low host memory rather than weakening that production check for tests.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var allocation: ?*anyopaque = null;
    var attempt: usize = 0;
    while (attempt < 16 and allocation == null) : (attempt += 1)
        allocation = VirtualAlloc(@ptrFromInt(0x20000000 + attempt * 0x1000000), 4 * 1024 * 1024, 0x3000, 0x04);
    const address = allocation orelse return error.LowAddressTestAllocationFailed;
    defer _ = VirtualFree(address, 0, 0x8000);
    const bytes: [*]u8 = @ptrCast(address);
    try syscalls.validateAmdGpuGttAlignmentSelfTest(bytes[0 .. 4 * 1024 * 1024]);
}
