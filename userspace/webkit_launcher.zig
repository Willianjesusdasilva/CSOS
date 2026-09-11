//! Minimal WPE WebKit userspace entry point.
//! The CSOS compositor owns the view backend; WebKit owns HTML/CSS/JS.
const WpeViewBackend = opaque {};
extern fn wpe_view_backend_create() ?*WpeViewBackend;
extern fn wpe_view_backend_destroy(?*WpeViewBackend) void;
extern fn webkit_web_view_backend_new(?*WpeViewBackend, ?*const anyopaque, ?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_new(?*anyopaque) ?*anyopaque;
extern fn webkit_web_view_load_html(?*anyopaque, [*:0]const u8, [*:0]const u8) void;
extern fn g_main_context_default() ?*anyopaque;
extern fn g_main_context_iteration(?*anyopaque, c_int) c_int;

pub fn main() void {
    const view_backend = wpe_view_backend_create() orelse return;
    const web_backend = webkit_web_view_backend_new(view_backend, null, null) orelse return;
    const view = webkit_web_view_new(web_backend) orelse return;
    const document = "<html><body><main id=app>CSOS WebKit</main><script>document.getElementById('app').dataset.ready='true';</script></body></html>";
    webkit_web_view_load_html(view, document, "csos://desktop");
    const context = g_main_context_default();
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        _ = g_main_context_iteration(context, 0);
    }
    wpe_view_backend_destroy(view_backend);
}
