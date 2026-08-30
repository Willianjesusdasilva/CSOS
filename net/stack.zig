const e1000 = @import("e1000");

const local_ip = [4]u8{ 10, 0, 2, 15 };
const gateway_ip = [4]u8{ 10, 0, 2, 2 };

pub const Stack = struct {
    device: *e1000.Controller,
    gateway_mac: [6]u8 = .{0} ** 6,
    identification: u16 = 1,

    pub fn init(device: *e1000.Controller) Stack { return .{ .device = device }; }

    pub fn resolveGateway(self: *Stack) !void {
        var frame: [42]u8 = .{0} ** 42;
        @memset(frame[0..6], 0xff);
        @memcpy(frame[6..12], &self.device.mac);
        put16(frame[12..], 0x0806);
        put16(frame[14..], 1); put16(frame[16..], 0x0800);
        frame[18] = 6; frame[19] = 4; put16(frame[20..], 1);
        @memcpy(frame[22..28], &self.device.mac);
        @memcpy(frame[28..32], &local_ip);
        @memcpy(frame[38..42], &gateway_ip);
        try self.device.send(&frame);

        var received: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 16) : (attempts += 1) {
            const length = try self.device.receive(&received);
            if (length < 42 or get16(received[12..]) != 0x0806 or get16(received[20..]) != 2) continue;
            if (!equal(received[28..32], &gateway_ip) or !equal(received[38..42], &local_ip)) continue;
            @memcpy(&self.gateway_mac, received[22..28]);
            return;
        }
        return error.ArpReplyMissing;
    }

    pub fn pingGateway(self: *Stack) !void {
        var frame: [50]u8 = .{0} ** 50;
        @memcpy(frame[0..6], &self.gateway_mac);
        @memcpy(frame[6..12], &self.device.mac);
        put16(frame[12..], 0x0800);
        const ip = frame[14..34];
        ip[0] = 0x45; ip[1] = 0; put16(ip[2..], 36);
        put16(ip[4..], self.identification); self.identification +%= 1;
        put16(ip[6..], 0x4000); ip[8] = 64; ip[9] = 1;
        @memcpy(ip[12..16], &local_ip); @memcpy(ip[16..20], &gateway_ip);
        put16(ip[10..], checksum(ip));
        const icmp = frame[34..50];
        icmp[0] = 8; icmp[1] = 0; put16(icmp[4..], 0x4353); put16(icmp[6..], 1);
        @memcpy(icmp[8..16], "CSOSPING");
        put16(icmp[2..], checksum(icmp));
        try self.device.send(&frame);

        var received: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 16) : (attempts += 1) {
            const length = try self.device.receive(&received);
            if (length < 42 or get16(received[12..]) != 0x0800) continue;
            const header_length = @as(usize, received[14] & 0x0f) * 4;
            const total_length = get16(received[16..]);
            if (header_length < 20 or total_length < header_length + 8 or length < 14 + total_length or received[23] != 1) continue;
            if (!equal(received[26..30], &gateway_ip) or !equal(received[30..34], &local_ip)) continue;
            const reply = received[14 + header_length ..];
            if (reply[0] == 0 and reply[1] == 0 and get16(reply[4..]) == 0x4353 and checksum(reply[0 .. total_length - header_length]) == 0) return;
        }
        return error.EchoReplyMissing;
    }
};

fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];
    if (index < bytes.len) sum += @as(u32, bytes[index]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn put16(output: []u8, value: u16) void { output[0] = @truncate(value >> 8); output[1] = @truncate(value); }
fn get16(input: []const u8) u16 { return (@as(u16, input[0]) << 8) | input[1]; }
fn equal(left: []const u8, right: []const u8) bool { for (left, right) |a, b| if (a != b) return false; return true; }
