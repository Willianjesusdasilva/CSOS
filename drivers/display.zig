const pci = @import("pci");
const physical = @import("physical");

pub const Framebuffer = struct {
    base: u64,
    size: usize,
    width: u32,
    height: u32,
    stride: u32,
    pixel_format: u32,
};

pub const Adapter = struct {
    vendor: u16,
    device: u16,
    bus: u8,
    slot: u5,
    function: u3,
    aperture: u64,
};

pub const Context = struct {
    framebuffer: Framebuffer,
    adapter: Adapter,
    backbuffer: u64,
    buffer_bytes: usize,
    dirty_left: usize = 0,
    dirty_top: usize = 0,
    dirty_right: usize = 0,
    dirty_bottom: usize = 0,
    frames_presented: u64 = 0,
    pixels_presented: u64 = 0,

    pub fn init(framebuffer: Framebuffer, device: pci.Device, pages: *physical.Allocator) !Context {
        if (framebuffer.base == 0 or framebuffer.width == 0 or framebuffer.height == 0) return error.InvalidFramebuffer;
        if (framebuffer.stride < framebuffer.width or framebuffer.pixel_format > 1) return error.UnsupportedFramebuffer;
        const pixels = @as(usize, framebuffer.stride) * framebuffer.height;
        if (pixels > framebuffer.size / 4) return error.InvalidFramebufferSize;
        const bytes = pixels * 4;
        const page_count = (bytes + 4095) / 4096;
        const backbuffer = pages.allocate(page_count) orelse return error.OutOfMemory;
        const memory: [*]u8 = @ptrFromInt(backbuffer);
        @memset(memory[0..bytes], 0);
        return .{
            .framebuffer = framebuffer,
            .adapter = .{
                .vendor = device.vendor,
                .device = device.device,
                .bus = device.bus,
                .slot = device.slot,
                .function = device.function,
                .aperture = pci.barAddress(device, 0) orelse 0,
            },
            .backbuffer = backbuffer,
            .buffer_bytes = bytes,
        };
    }

    pub fn clear(self: *Context, rgb: u32) void {
        const pixels: [*]u32 = @ptrFromInt(self.backbuffer);
        const native = self.nativeColor(rgb);
        var index: usize = 0;
        while (index < self.buffer_bytes / 4) : (index += 1) pixels[index] = native;
        self.invalidate(0, 0, self.framebuffer.width, self.framebuffer.height);
    }

    pub fn fillRect(self: *Context, x: usize, y: usize, width: usize, height: usize, rgb: u32) void {
        const right = @min(@as(usize, self.framebuffer.width), x +| width);
        const bottom = @min(@as(usize, self.framebuffer.height), y +| height);
        if (x >= right or y >= bottom) return;
        const pixels: [*]u32 = @ptrFromInt(self.backbuffer);
        const native = self.nativeColor(rgb);
        var row = y;
        while (row < bottom) : (row += 1) {
            var column = x;
            while (column < right) : (column += 1)
                pixels[row * self.framebuffer.stride + column] = native;
        }
        self.invalidate(x, y, right - x, bottom - y);
    }

    pub fn present(self: *Context) usize {
        if (self.dirty_right <= self.dirty_left or self.dirty_bottom <= self.dirty_top) return 0;
        const source: [*]const u32 = @ptrFromInt(self.backbuffer);
        const target: [*]volatile u32 = @ptrFromInt(self.framebuffer.base);
        var copied: usize = 0;
        var row = self.dirty_top;
        while (row < self.dirty_bottom) : (row += 1) {
            var column = self.dirty_left;
            while (column < self.dirty_right) : (column += 1) {
                const index = row * self.framebuffer.stride + column;
                target[index] = source[index];
                copied += 1;
            }
        }
        self.dirty_left = 0;
        self.dirty_top = 0;
        self.dirty_right = 0;
        self.dirty_bottom = 0;
        self.frames_presented += 1;
        self.pixels_presented += copied;
        return copied;
    }

    pub fn drawBaseline(self: *Context, input_devices: usize, audio_devices: usize) void {
        self.clear(0x101820);
        self.fillRect(0, 0, self.framebuffer.width, 32, 0x203050);
        self.fillRect(16, 8, @min(@as(usize, self.framebuffer.width) -| 16, 304), 16, 0x5070a0);
        const panel_width = @min(@as(usize, self.framebuffer.width) -| 48, 560);
        self.fillRect(24, 64, panel_width, 128, 0x181c28);
        self.fillRect(32, 88, @min(panel_width -| 16, input_devices * 96), 12, 0x50d080);
        self.fillRect(32, 120, @min(panel_width -| 16, audio_devices * 96), 12, 0x5080d0);
        const center_x = @as(usize, self.framebuffer.width) / 2;
        const center_y = @as(usize, self.framebuffer.height) / 2;
        self.fillRect(center_x -| 8, center_y, 17, 1, 0xffffff);
        self.fillRect(center_x, center_y -| 8, 1, 17, 0xffffff);
    }

    pub fn heartbeat(self: *Context, phase: usize) void {
        self.fillRect(16, 16, 16, 4, 0x203050);
        self.fillRect(16 + phase % 16, 16, 1, 4, 0x40e080);
    }

    fn invalidate(self: *Context, x: usize, y: usize, width: usize, height: usize) void {
        const right = @min(@as(usize, self.framebuffer.width), x +| width);
        const bottom = @min(@as(usize, self.framebuffer.height), y +| height);
        if (x >= right or y >= bottom) return;
        if (self.dirty_right == 0 or self.dirty_bottom == 0) {
            self.dirty_left = x;
            self.dirty_top = y;
            self.dirty_right = right;
            self.dirty_bottom = bottom;
        } else {
            self.dirty_left = @min(self.dirty_left, x);
            self.dirty_top = @min(self.dirty_top, y);
            self.dirty_right = @max(self.dirty_right, right);
            self.dirty_bottom = @max(self.dirty_bottom, bottom);
        }
    }

    fn nativeColor(self: *const Context, rgb: u32) u32 {
        if (self.framebuffer.pixel_format == 1) return rgb & 0x00ffffff;
        return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
    }
};
