pub export fn shared_marker() callconv(.c) u64 {
    return 0x43534f53;
}

pub export fn __tls_get_addr(descriptor: *const [2]u64) callconv(.c) *u8 {
    const tls_base: u64 = 0x0000005000000000;
    const module_stride: u64 = 0x10000;
    return @ptrFromInt(tls_base + (descriptor[0] - 1) * module_stride + descriptor[1]);
}
