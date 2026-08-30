const data = 0x3f8;

pub fn init() void {
    out(data + 1, 0x00);
    out(data + 3, 0x80);
    out(data + 0, 0x01);
    out(data + 1, 0x00);
    out(data + 3, 0x03);
    out(data + 2, 0xc7);
    out(data + 4, 0x0b);
}

pub fn write(text: []const u8) void {
    for (text) |byte| {
        while ((in(data + 5) & 0x20) == 0) {}
        out(data, byte);
    }
}

fn out(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn in(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
