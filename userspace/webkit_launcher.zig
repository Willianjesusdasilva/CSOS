//! Minimal WPE WebKit userspace entry point.
//! The CSOS compositor owns the view backend; WebKit owns HTML/CSS/JS.
const std = @import("std");
const WpeViewBackend = opaque {};
extern fn wpe_view_backend_initialize(?*WpeViewBackend) void;
extern fn wpe_view_backend_add_activity_state(?*WpeViewBackend, u32) void;
extern fn wpe_fdo_initialize_shm() void;
extern fn wpe_fdo_initialize_for_egl_display(?*anyopaque) void;
const EglGetPlatformDisplayFn = *const fn (u32, ?*anyopaque, ?*const isize) callconv(.c) ?*anyopaque;
const EglInitializeFn = *const fn (?*anyopaque, *i32, *i32) callconv(.c) u32;
extern var epoxy_eglGetPlatformDisplay: EglGetPlatformDisplayFn;
extern var epoxy_eglInitialize: EglInitializeFn;
extern fn eglGetDisplay(?*anyopaque) ?*anyopaque;
extern fn eglGetPlatformDisplay(u32, ?*anyopaque, ?*const isize) ?*anyopaque;
extern fn eglInitialize(?*anyopaque, *i32, *i32) u32;
extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const WpeExportable = opaque {};
const ExportBufferFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const ExportDmabufFn = *const fn (?*anyopaque, *WpeDmabufResource) callconv(.c) void;
const ExportShmFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const WpeDmabufResource = extern struct {
    buffer_resource: ?*anyopaque,
    width: u32,
    height: u32,
    format: u32,
    n_planes: u8,
    fds: [4]c_int,
    strides: [4]u32,
    offsets: [4]u32,
    modifiers: [4]u64,
};
const WpeExportableClient = extern struct {
    export_buffer_resource: ?ExportBufferFn,
    export_dmabuf_resource: ?ExportDmabufFn,
    export_shm_buffer: ?ExportShmFn,
    reserved0: ?*const anyopaque,
    reserved1: ?*const anyopaque,
};
extern fn wpe_view_backend_exportable_fdo_create(*const WpeExportableClient, ?*anyopaque, u32, u32) ?*WpeExportable;
extern fn wpe_view_backend_exportable_fdo_get_view_backend(?*WpeExportable) ?*WpeViewBackend;
extern fn wpe_view_backend_exportable_fdo_destroy(?*WpeExportable) void;
extern fn wpe_view_backend_exportable_fdo_dispatch_frame_complete(?*WpeExportable) void;
extern fn wpe_view_backend_exportable_fdo_dispatch_release_buffer(?*WpeExportable, ?*anyopaque) void;
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
extern fn open([*:0]const u8, c_int) c_int;
extern fn ioctl(c_int, usize, ?*anyopaque) c_int;
extern fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
extern fn munmap(?*anyopaque, usize) c_int;
extern fn close(c_int) c_int;
extern fn write(c_int, *const anyopaque, usize) isize;
extern fn __tls_get_addr(*const [2]usize) ?*anyopaque;

fn mark(message: []const u8) void {
    _ = write(1, message.ptr, message.len);
}

var exported_frame_count: u32 = 0;
var active_exportable: ?*WpeExportable = null;
var framebuffer_pixels: ?[*]u8 = null;
var framebuffer_width: usize = 0;
var framebuffer_height: usize = 0;
var framebuffer_stride: usize = 0;

fn exportBuffer(_: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    // The generic FDO exportable API uses this callback for EGL-backed
    // wl_buffer resources.  The embedder must release the resource and
    // acknowledge the frame; leaving it empty stalls the backend after the
    // first surface commit.  Pixel extraction remains backend-specific and
    // is intentionally handled by the SHM/DMA-BUF callbacks below.
    mark("WebKit buffer callback\n");
    const exportable = active_exportable orelse return;
    if (buffer) |resource|
        wpe_view_backend_exportable_fdo_dispatch_release_buffer(exportable, resource);
    wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
}

fn exportDmabufBuffer(_: ?*anyopaque, resource: *WpeDmabufResource) callconv(.c) void {
    mark("WebKit DMA-BUF callback\n");
    const exportable = active_exportable orelse return;
    defer {
        wpe_view_backend_exportable_fdo_dispatch_release_buffer(exportable, resource.buffer_resource);
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    }
    if (resource.n_planes == 0 or resource.fds[0] < 0) return;
    const width = @as(usize, resource.width);
    const height = @as(usize, resource.height);
    const stride = @as(usize, resource.strides[0]);
    const offset = @as(usize, resource.offsets[0]);
    if (width == 0 or height == 0 or stride < width * 4) return;
    const length = std.math.add(usize, offset, std.math.mul(usize, stride, height) catch return) catch return;
    const mapped = mmap(null, length, 1, 1, resource.fds[0], 0) orelse return;
    if (@intFromPtr(mapped) == std.math.maxInt(usize)) return;
    defer _ = munmap(mapped, length);
    const source: [*]const u8 = @as([*]const u8, @ptrCast(mapped)) + offset;
    if (framebuffer_pixels) |destination| {
        const row_bytes = @min(width * 4, framebuffer_stride);
        const rows = @min(height, framebuffer_height);
        for (0..rows) |row| {
            const dst = destination + row * framebuffer_stride;
            const src = source + row * stride;
            @memcpy(dst[0..row_bytes], src[0..row_bytes]);
        }
        mark("WebKit first frame\n");
    }
}

fn exportShmBuffer(_: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    mark("WebKit SHM callback\n");
    const exportable = active_exportable orelse return;
    const exported = buffer orelse return;
    defer {
        wpe_view_backend_exportable_fdo_dispatch_release_shm_exported_buffer(exportable, exported);
        // The FDO backend dispatches frame callbacks and calls
        // wpe_view_backend_dispatch_frame_displayed() when those callbacks
        // are actually delivered.  The embedder only needs to release the
        // exported buffer and acknowledge the completed frame here.
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    }
    const shm = wpe_fdo_shm_exported_buffer_get_shm_buffer(exported) orelse return;
    const source = wl_shm_buffer_get_data(shm) orelse return;
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
    if (framebuffer_pixels) |destination| {
        const source_width = wl_shm_buffer_get_width(shm);
        const source_height = wl_shm_buffer_get_height(shm);
        const source_stride = wl_shm_buffer_get_stride(shm);
        if (source_width > 0 and source_height > 0 and source_stride > 0) {
            const row_bytes = @min(@as(usize, @intCast(source_width)) * 4, framebuffer_stride);
            const rows = @min(@as(usize, @intCast(source_height)), framebuffer_height);
            const source_bytes: [*]const u8 = @ptrCast(source);
            for (0..rows) |row| {
                const src = source_bytes + row * @as(usize, @intCast(source_stride));
                const dst = destination + row * framebuffer_stride;
                @memcpy(dst[0..row_bytes], src[0..row_bytes]);
            }
            mark("WebKit first frame\n");
        }
    }
}
fn destroyBackend(_: ?*anyopaque) callconv(.c) void {}

fn mapFramebuffer() void {
    const path: [*:0]const u8 = "/dev/fb0";
    const fd = open(path, 2);
    if (fd < 0) return;
    var variable: [160]u8 = .{0} ** 160;
    var fixed: [80]u8 = .{0} ** 80;
    defer _ = close(fd);
    if (ioctl(fd, 0x4600, &variable) != 0 or ioctl(fd, 0x4602, &fixed) != 0) return;
    const width = @as(usize, @intCast(@as(*align(1) const u32, @ptrCast(&variable[0])).*));
    const height = @as(usize, @intCast(@as(*align(1) const u32, @ptrCast(&variable[4])).*));
    const bpp = @as(usize, @intCast(@as(*align(1) const u32, @ptrCast(&variable[24])).*));
    const stride = @as(usize, @intCast(@as(*align(1) const u32, @ptrCast(&fixed[48])).*));
    if (width == 0 or height == 0 or bpp != 32 or stride < width * 4) return;
    const length = std.math.mul(usize, stride, height) catch return;
    const mapped = mmap(null, length, 3, 1, fd, 0) orelse return;
    if (@intFromPtr(mapped) == std.math.maxInt(usize)) return;
    framebuffer_pixels = @ptrCast(mapped);
    framebuffer_width = width;
    framebuffer_height = height;
    framebuffer_stride = stride;
    mark("CSOS framebuffer mapped\n");
}

pub fn main() void {
    // Prefer a surfaceless EGL display backed by Mesa software rendering.
    // SHM remains a diagnostic fallback for images that do not ship EGL yet.
    _ = setenv("EGL_PLATFORM", "surfaceless", 1);
    _ = setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    _ = setenv("MESA_LOADER_DRIVER_OVERRIDE", "swrast", 1);
    _ = eglGetDisplay(null);
    epoxy_eglGetPlatformDisplay = eglGetPlatformDisplay;
    epoxy_eglInitialize = eglInitialize;
    var egl_ready = false;
    if (@intFromPtr(epoxy_eglGetPlatformDisplay) != 0 and @intFromPtr(epoxy_eglInitialize) != 0) {
        const display = epoxy_eglGetPlatformDisplay(0x31dd, null, null);
        if (display) |egl_display| {
            var major: i32 = 0;
            var minor: i32 = 0;
            if (epoxy_eglInitialize(egl_display, &major, &minor) != 0) {
                wpe_fdo_initialize_for_egl_display(egl_display);
                mark("WPE EGL ready ");
                var version: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&version, "{}.{}\n", .{ major, minor }) catch unreachable;
                mark(text);
                egl_ready = true;
            }
        }
    }
    if (!egl_ready) {
        wpe_fdo_initialize_shm();
        mark("WPE shm ready\n");
    }
    const client = WpeExportableClient{
        .export_buffer_resource = exportBuffer,
        .export_dmabuf_resource = exportDmabufBuffer,
        .export_shm_buffer = exportShmBuffer,
        .reserved0 = null,
        .reserved1 = null,
    };
    const exportable = wpe_view_backend_exportable_fdo_create(&client, null, 1280, 800) orelse return;
    active_exportable = exportable;
    mapFramebuffer();
    const view_backend = wpe_view_backend_exportable_fdo_get_view_backend(exportable) orelse return;
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
    // The FDO headless backend marks the view active before constructing the
    // WebKit view.  WebKit snapshots the initial activity state while it
    // creates the page and renderer process.
    wpe_view_backend_add_activity_state(view_backend, 1 | 2 | 4);
    mark("WebKit view begin\n");
    const view = webkit_web_view_new(web_backend) orelse return;
    mark("WebKit view ready\n");
    const document = "<html><body><main id=app>CSOS WebKit</main><script>document.getElementById('app').dataset.ready='true';</script></body></html>";
    webkit_web_view_load_html(view, document, "csos://desktop");
    mark("WebKit HTML submitted\n");
    // Start the first compositor cycle. Subsequent cycles are acknowledged
    // only after exportShmBuffer has released the real WPE buffer.
    wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    const context = g_main_context_default();
    var rounds: usize = 0;
    while (rounds < 300 and exported_frame_count == 0) : (rounds += 1) {
        _ = g_main_context_iteration(context, 0);
        // The initial dispatch can precede WebKit's surface registration.
        // Re-dispatch after each event turn so a newly registered surface
        // receives the pending frame callback.
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    }
    // Frame delivery is asynchronous. Keep the real GLib context alive for
    // bounded blocking turns while continuing to acknowledge frame callbacks.
    rounds = 0;
    while (rounds < 16 and exported_frame_count == 0) : (rounds += 1) {
        _ = g_main_context_iteration(context, 1);
        wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable);
    }
    mark("WebKit GLib loop complete\n");
    // The FDO exportable owns the view backend and destroys it as part of its
    // teardown.  Do not call wpe_view_backend_destroy here: that would free
    // the same backend twice and corrupt musl's allocator metadata.
    wpe_view_backend_exportable_fdo_destroy(exportable);
}
