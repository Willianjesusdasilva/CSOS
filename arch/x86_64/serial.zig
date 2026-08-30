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

pub fn writeDecimal(value: u64) void {
    var buffer: [20]u8 = undefined;
    var index = buffer.len;
    var remaining = value;
    if (remaining == 0) return write("0");
    while (remaining != 0) {
        index -= 1;
        buffer[index] = @truncate('0' + remaining % 10);
        remaining /= 10;
    }
    write(buffer[index..]);
}

pub fn readNonblocking() ?u8 {
    if ((in(data + 5) & 1) == 0) return null;
    return in(data);
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
