//! Minimal WPE WebKit userspace entry point.
//! The CSOS compositor owns the view backend; WebKit owns HTML/CSS/JS.
const std = @import("std");
const WpeViewBackend = opaque {};
extern fn wpe_view_backend_initialize(?*WpeViewBackend) void;
extern fn wpe_view_backend_add_activity_state(?*WpeViewBackend, u32) void;
extern fn wpe_fdo_initialize_shm() void;
const WpeExportable = opaque {};
const ExportBufferFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const ExportShmFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const WpeExportableClient = extern struct {
    export_buffer_resource: ?ExportBufferFn,
    export_dmabuf_resource: ?ExportBufferFn,
    export_shm_buffer: ?ExportShmFn,
    reserved0: ?*const anyopaque,
    reserved1: ?*const anyopaque,
};
extern fn wpe_view_backend_exportable_fdo_create(*const WpeExportableClient, ?*anyopaque, u32, u32) ?*WpeExportable;
extern fn wpe_view_backend_exportable_fdo_get_view_backend(?*WpeExportable) ?*WpeViewBackend;
extern fn wpe_view_backend_exportable_fdo_destroy(?*WpeExportable) void;
extern fn wpe_view_backend_exportable_fdo_dispatch_frame_complete(?*WpeExportable) void;
extern fn wpe_view_backend_dispatch_frame_displayed(?*WpeViewBackend) void;
extern fn wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer(?*WpeExportable, ?*anyopaque) void;
extern fn wpe_fdo_shm_exported_buffer_get_shm_buffer(?*anyopaque) ?*anyopaque;
extern fn wl_shm_buffer_get_data(?*anyopaque) ?*anyopaque;
extern fn wl_shm_buffer_get_width(?*anyopaque) c_int;
extern fn wl_shm_buffer_get_height(?*anyopaque) c_int;
extern fn wl_shm_buffer_get_stride(?*anyopaque) c_int;
extern fn webkit_web_view_backend_new(?*WpeViewBackend, ?*const anyopaque, ?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_new(?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_load_html(?*anyopaque, [*:0]const u8, [*:0]const u8) void;
extern fn g_main_context_default() ?*anyopaque;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern fn write(c_int, *const anyopaque, usize) isize;
extern fn __tls_get_addr(*const [2]usize) ?*anyopaque;

fn mark(message: []const u8) void {
    _ = write(1, message.ptr, message.len);
}

var exported_frame_count: u32 = 0;
var active_exportable: ?*WpeExportable = null;
var active_view_backend: ?*WpeViewBackend = null;

fn exportBuffer(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

fn exportShmBuffer(_: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    mark("WebKit SHM callback\n");
    const exportable = active_exportable orelse return;
    const exported = buffer orelse return;
    defer {
        wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer(exportable, exported);
        // frame_complete dispatches Wayland callbacks; libwpe advances the
        // render cadence when the client confirms the frame was displayed.
        wpe_view_backend_dispatch_frame_displayed(active_view_backend);
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    }
    const shm = wpe_fdo_shm_exported_buffer_get_shm_buffer(exported) orelse return;
    _ = wl_shm_buffer_get_data(shm) orelse return;
    exported_frame_count += 1;
    mark("WebKit frame exported ");
    var number: [24]u8 = undefined;
    const width = std.fmt.bufPrint(&number, "{}", .{wl_shm_buffer_get_width(shm)}) catch unreachable;
    mark(width);
    mark("x");
    const height = std.fmt.bufPrint(&number, "{}", .{wl_shm_buffer_get_height(shm)}) catch unreachable;
    mark(height);
    mark(" stride=");
    const stride = std.fmt.bufPrint(&number, "{}", .{wl_shm_buffer_get_stride(shm)}) catch unreachable;
    mark(stride);
    mark("\n");
}
fn destroyBackend(_: ?*anyopaque) callconv(.c) void {}

pub fn main() void {
    // QEMU currently has no physical EGL/KMS device. WPE FDO's SHM target
    // still exercises the real WebKit pipeline without a fake renderer.
    wpe_fdo_initialize_shm();
    mark("WPE shm ready\n");
    const client = WpeExportableClient{
        .export_buffer_resource = exportBuffer,
        .export_dmabuf_resource = exportBuffer,
        .export_shm_buffer = exportShmBuffer,
        .reserved0 = null,
        .reserved1 = null,
    };
    const exportable = wpe_view_backend_exportable_fdo_create(&client, null, 1280, 800) orelse return;
    active_exportable = exportable;
    const view_backend = wpe_view_backend_exportable_fdo_get_view_backend(exportable) orelse return;
    active_view_backend = view_backend;
    wpe_view_backend_initialize(view_backend);
    mark("WPE backend ready\n");
    const tls_probe = [_]usize{ 1, 8 };
    const tls_state = __tls_get_addr(&tls_probe) orelse return;
    _ = @as(*const u64, @ptrCast(@alignCast(tls_state))).*;
    mark("WebKit TLS ready\n");
    const web_backend = webkit_web_view_backend_new(view_backend, destroyBackend, null) orelse return;
    mark("WebKit backend ready\n");
    // webkit_web_view_new() uses and owns the default WPE context. Creating
    // a separate context here and discarding it initializes a second process
    // pool before the view is constructed.
    mark("WebKit context default\n");
    mark("WebKit view begin\n");
    const view = webkit_web_view_new(web_backend) orelse return;
    mark("WebKit view ready\n");
    // A WPE view starts inactive.  Mark it visible/focused/in-window only
    // after WebKit has attached its view, matching the normal embedder order.
    wpe_view_backend_add_activity_state(view_backend, 1 | 2 | 4);
    const document = "<html><body><main id=app>CSOS WebKit</main><script>document.getElementById('app').dataset.ready='true';</script></body></html>";
    webkit_web_view_load_html(view, document, "csos://desktop");
    mark("WebKit HTML submitted\n");
    // Start the first compositor cycle. Subsequent cycles are acknowledged
    // only after exportShmBuffer has released the real WPE buffer.
    wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    const context = g_main_context_default();
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        _ = g_main_context_iteration(context, 0);
    }
    // Frame delivery is asynchronous. Keep the real GLib context alive for
    // one blocking dispatch so WPE can deliver the SHM buffer to the client.
    _ = g_main_context_iteration(context, 1);
    mark("WebKit GLib loop complete\n");
    // The FDO exportable owns the view backend and destroys it as part of its
    // teardown.  Do not call wpe_view_backend_destroy here: that would free
    // the same backend twice and corrupt musl's allocator metadata.
    wpe_view_backend_exportable_fdo_destroy(exportable);
}
