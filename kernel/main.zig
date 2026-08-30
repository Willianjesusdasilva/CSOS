const serial = @import("serial");

pub const BootInfo = struct {
    framebuffer: Framebuffer,
    memory_map: [*]align(8) u8,
    memory_map_len: usize,
    memory_descriptor_size: usize,
};

pub const Framebuffer = struct {
    base: u64,
    size: usize,
    width: u32,
    height: u32,
    stride: u32,
    pixel_format: u32,
};

pub fn start(info: BootInfo) noreturn {
    serial.write("kernel entry\n");
    if (info.memory_map_len == 0 or info.memory_descriptor_size == 0) panic("empty memory map");
    drawBootMarker(info.framebuffer);
    serial.write("framebuffer ready\n");
    serial.write("CSOS M1 ready\n");

    while (true) asm volatile ("cli; hlt");
}

pub fn panic(message: []const u8) noreturn {
    serial.write("kernel panic: ");
    serial.write(message);
    serial.write("\n");
    while (true) asm volatile ("cli; hlt");
}

fn drawBootMarker(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.size < 4) panic("invalid framebuffer");
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const rows = @min(framebuffer.height, 32);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = if (framebuffer.pixel_format == 0) 0x0000a040 else 0x0040a000;
        }
    }
}
