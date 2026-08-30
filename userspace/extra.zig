extern fn shared_marker() callconv(.c) u64;

pub export fn extra_marker() callconv(.c) u64 {
    if (shared_marker() != 0x43534f53) return 0;
    return 0x45585452;
}
