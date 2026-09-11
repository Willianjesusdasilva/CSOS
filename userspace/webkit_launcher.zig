//! Minimal WPE WebKit userspace entry point.
//! The CSOS compositor owns the view backend; WebKit owns HTML/CSS/JS.
const WpeViewBackend = opaque {};
extern fn wpe_view_backend_destroy(?*WpeViewBackend) void;
extern fn wpe_view_backend_initialize(?*WpeViewBackend) void;
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
extern fn webkit_web_view_backend_new(?*WpeViewBackend, ?*const anyopaque, ?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_new(?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_load_html(?*anyopaque, [*:0]const u8, [*:0]const u8) void;
extern fn g_main_context_default() ?*anyopaque;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;
extern fn write(c_int, *const anyopaque, usize) isize;

fn mark(message: []const u8) void {
    _ = write(1, message.ptr, message.len);
}

fn exportBuffer(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

pub fn main() void {
    // QEMU currently has no physical EGL/KMS device. WPE FDO's SHM target
    // still exercises the real WebKit pipeline without a fake renderer.
    wpe_fdo_initialize_shm();
    mark("WPE shm ready\n");
    const client = WpeExportableClient{
        .export_buffer_resource = exportBuffer,
        .export_dmabuf_resource = exportBuffer,
        .export_shm_buffer = exportBuffer,
        .reserved0 = null,
        .reserved1 = null,
    };
    const exportable = wpe_view_backend_exportable_fdo_create(&client, null, 1280, 800) orelse return;
    const view_backend = wpe_view_backend_exportable_fdo_get_view_backend(exportable) orelse return;
    wpe_view_backend_initialize(view_backend);
    mark("WPE backend ready\n");
    const web_backend = webkit_web_view_backend_new(view_backend, null, null) orelse return;
    mark("WebKit backend ready\n");
    const view = webkit_web_view_new(web_backend) orelse return;
    mark("WebKit view ready\n");
    const document = "<html><body><main id=app>CSOS WebKit</main><script>document.getElementById('app').dataset.ready='true';</script></body></html>";
    webkit_web_view_load_html(view, document, "csos://desktop");
    mark("WebKit HTML submitted\n");
    const context = g_main_context_default();
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        _ = g_main_context_iteration(context, 0);
    }
    mark("WebKit GLib loop complete\n");
    wpe_view_backend_destroy(view_backend);
    wpe_view_backend_exportable_fdo_destroy(exportable);
}
