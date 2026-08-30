extern fn shared_marker() callconv(.c) u64;
pub export var shared_reference: *const fn () callconv(.c) u64 = &shared_marker;
pub export threadlocal var tls_marker: u64 = 0x544c534f;

pub export fn extra_marker() callconv(.c) u64 {
    if (shared_reference() != 0x43534f53) return 0;
    if (tls_marker != 0x544c534f) return 0;
    return 0x45585452;
}
