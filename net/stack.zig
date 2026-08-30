const e1000 = @import("e1000");

const broadcast_ip = [4]u8{ 255, 255, 255, 255 };
const transaction_id: u32 = 0x43534f53;

pub const Stack = struct {
    device: *e1000.Controller,
    gateway_mac: [6]u8 = .{0} ** 6,
    local_ip: [4]u8 = .{0} ** 4,
    gateway_ip: [4]u8 = .{0} ** 4,
    subnet_mask: [4]u8 = .{0} ** 4,
    dns_ip: [4]u8 = .{0} ** 4,
    identification: u16 = 1,
    tcp_nonce: u16 = 0,

    pub fn init(device: *e1000.Controller) Stack { return .{ .device = device }; }

    pub fn tcpConnect(self: *Stack, destination: [4]u8, destination_port: u16, source_port: u16) !TcpConnection {
        var connection = TcpConnection{
            .destination = destination,
            .destination_port = destination_port,
            .source_port = source_port,
            .sequence = 0x43534f53,
        };
        try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, connection.sequence, 0, tcp_syn, "");
        const reply = try self.receiveTcp(destination, destination_port, source_port, null);
        if ((reply.flags & (tcp_syn | tcp_ack)) != (tcp_syn | tcp_ack) or reply.acknowledgement != connection.sequence +% 1)
            return error.InvalidTcpSynAck;
        connection.sequence +%= 1;
        connection.peer_sequence = reply.sequence +% 1;
        try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, connection.sequence, connection.peer_sequence, tcp_ack, "");
        connection.connected = true;
        return connection;
    }

    pub fn tcpSend(self: *Stack, connection: *TcpConnection, payload: []const u8) !usize {
        if (!connection.connected) return error.NotConnected;
        try self.sendTcp(connection.destination, self.gateway_mac, connection.source_port, connection.destination_port, connection.sequence, connection.peer_sequence, tcp_psh | tcp_ack, payload);
        connection.sequence +%= @intCast(payload.len);
        return payload.len;
    }

    pub fn tcpReceive(self: *Stack, connection: *TcpConnection, output: []u8) !usize {
        if (!connection.connected) return error.NotConnected;
        var attempts: u8 = 0;
        while (attempts < 64) : (attempts += 1) {
            const segment = try self.receiveTcp(connection.destination, connection.destination_port, connection.source_port, output);
            if (segment.sequence != connection.peer_sequence and segment.payload_length != 0) continue;
            if (segment.payload_length != 0) connection.peer_sequence +%= @intCast(segment.payload_length);
            if ((segment.flags & tcp_fin) != 0) {
                connection.peer_sequence +%= 1;
                connection.peer_closed = true;
            }
            try self.sendTcp(connection.destination, self.gateway_mac, connection.source_port, connection.destination_port, connection.sequence, connection.peer_sequence, tcp_ack, "");
            if (segment.payload_length != 0 or connection.peer_closed) return segment.payload_length;
        }
        return error.TcpPayloadMissing;
    }

    pub fn tcpClose(self: *Stack, connection: *TcpConnection) !void {
        if (!connection.connected) return;
        if (!connection.peer_closed) {
            try self.sendTcp(connection.destination, self.gateway_mac, connection.source_port, connection.destination_port, connection.sequence, connection.peer_sequence, tcp_fin | tcp_ack, "");
            connection.sequence +%= 1;
        }
        connection.connected = false;
    }

    pub fn configureDhcp(self: *Stack) !void {
        try self.sendDhcp(1, null, null);
        const offer = try self.receiveDhcp(2);
        try self.sendDhcp(3, offer.address, offer.server);
        const acknowledgement = try self.receiveDhcp(5);
        if (!equal(&acknowledgement.address, &offer.address)) return error.DhcpAddressChanged;
        self.local_ip = acknowledgement.address;
        self.gateway_ip = acknowledgement.router;
        self.subnet_mask = acknowledgement.mask;
        self.dns_ip = acknowledgement.dns;
        if (zero(&self.local_ip) or zero(&self.gateway_ip) or zero(&self.dns_ip)) return error.IncompleteDhcpLease;
    }

    pub fn resolveGateway(self: *Stack) !void {
        self.gateway_mac = try self.resolveAddress(self.gateway_ip);
    }

    pub fn resolveDns(self: *Stack, name: []const u8) ![4]u8 {
        const dns_mac = try self.resolveAddress(self.dns_ip);
        var query: [512]u8 = .{0} ** 512;
        put16(query[0..], 0x4353); put16(query[2..], 0x0100); put16(query[4..], 1);
        var offset: usize = 12;
        var label_start: usize = 0;
        while (label_start < name.len) {
            var label_end = label_start;
            while (label_end < name.len and name[label_end] != '.') : (label_end += 1) {}
            const length = label_end - label_start;
            if (length == 0 or length > 63 or offset + 1 + length + 5 > query.len) return error.InvalidDnsName;
            query[offset] = @intCast(length); offset += 1;
            @memcpy(query[offset .. offset + length], name[label_start..label_end]); offset += length;
            label_start = label_end + 1;
        }
        query[offset] = 0; offset += 1;
        put16(query[offset..], 1); put16(query[offset + 2 ..], 1); offset += 4;
        try self.sendUdp(self.dns_ip, dns_mac, 49152, 53, query[0..offset]);
        var response: [512]u8 = undefined;
        const size = try self.receiveUdp(self.dns_ip, 53, 49152, &response);
        if (size < 12 or get16(response[0..]) != 0x4353 or (get16(response[2..]) & 0x800f) != 0x8000 or get16(response[6..]) == 0) return error.InvalidDnsReply;
        offset = 12;
        var question: u16 = 0;
        while (question < get16(response[4..])) : (question += 1) {
            offset = try skipDnsName(response[0..size], offset);
            if (offset + 4 > size) return error.InvalidDnsReply;
            offset += 4;
        }
        var answer: u16 = 0;
        while (answer < get16(response[6..])) : (answer += 1) {
            offset = try skipDnsName(response[0..size], offset);
            if (offset + 10 > size) return error.InvalidDnsReply;
            const record_type = get16(response[offset..]);
            const class = get16(response[offset + 2 ..]);
            const data_length = get16(response[offset + 8 ..]);
            offset += 10;
            if (offset + data_length > size) return error.InvalidDnsReply;
            if (record_type == 1 and class == 1 and data_length == 4)
                return .{ response[offset], response[offset + 1], response[offset + 2], response[offset + 3] };
            offset += data_length;
        }
        return error.DnsAddressMissing;
    }

    pub fn probeTcpHttp(self: *Stack, destination: [4]u8, host: []const u8) !usize {
        if (host.len == 0 or host.len > 128) return error.InvalidHostName;
        const source_port: u16 = 49153 + self.tcp_nonce % 1024;
        const destination_port: u16 = 80;
        var sequence: u32 = 0x43534f53 +% @as(u32, self.tcp_nonce) *% 0x10001;
        self.tcp_nonce +%= 1;
        try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, 0, tcp_syn, "");

        const syn_ack = try self.receiveTcp(destination, destination_port, source_port, null);
        if ((syn_ack.flags & (tcp_syn | tcp_ack)) != (tcp_syn | tcp_ack) or syn_ack.acknowledgement != sequence +% 1)
            return error.InvalidTcpSynAck;
        sequence +%= 1;
        var peer_sequence = syn_ack.sequence +% 1;
        try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, peer_sequence, tcp_ack, "");

        var request: [192]u8 = undefined;
        const prefix = "GET / HTTP/1.0\r\nHost: ";
        const suffix = "\r\nConnection: close\r\n\r\n";
        const request_length = prefix.len + host.len + suffix.len;
        if (request_length > request.len) return error.RequestTooLarge;
        @memcpy(request[0..prefix.len], prefix);
        @memcpy(request[prefix.len .. prefix.len + host.len], host);
        @memcpy(request[prefix.len + host.len .. request_length], suffix);
        try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, peer_sequence, tcp_psh | tcp_ack, request[0..request_length]);
        sequence +%= @intCast(request_length);

        var received_bytes: usize = 0;
        var saw_fin = false;
        var attempts: u8 = 0;
        while (attempts < 64 and received_bytes == 0) : (attempts += 1) {
            const segment = try self.receiveTcp(destination, destination_port, source_port, null);
            if (segment.acknowledgement > sequence) return error.InvalidTcpAcknowledgement;
            if (segment.sequence != peer_sequence and segment.payload_length != 0) continue;
            if (segment.payload_length != 0) {
                received_bytes += segment.payload_length;
                peer_sequence +%= @intCast(segment.payload_length);
            }
            if ((segment.flags & tcp_fin) != 0) {
                peer_sequence +%= 1;
                saw_fin = true;
            }
            try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, peer_sequence, tcp_ack, "");
        }
        if (received_bytes == 0) return error.TcpPayloadMissing;

        if (!saw_fin) {
            try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, peer_sequence, tcp_fin | tcp_ack, "");
            sequence +%= 1;
            attempts = 0;
            while (attempts < 16) : (attempts += 1) {
                const segment = try self.receiveTcp(destination, destination_port, source_port, null);
                if ((segment.flags & tcp_fin) != 0) {
                    peer_sequence = segment.sequence +% @as(u32, @intCast(segment.payload_length)) +% 1;
                    try self.sendTcp(destination, self.gateway_mac, source_port, destination_port, sequence, peer_sequence, tcp_ack, "");
                    saw_fin = true;
                    break;
                }
                if ((segment.flags & tcp_ack) != 0 and segment.acknowledgement == sequence) break;
            }
        }
        return received_bytes;
    }

    fn sendTcp(self: *Stack, destination: [4]u8, destination_mac: [6]u8, source_port: u16, destination_port: u16, sequence: u32, acknowledgement: u32, flags: u8, payload: []const u8) !void {
        if (payload.len > 1400) return error.SegmentTooLarge;
        var frame: [1454]u8 = undefined;
        const tcp_length = 20 + payload.len;
        const size = 14 + 20 + tcp_length;
        @memcpy(frame[0..6], &destination_mac); @memcpy(frame[6..12], &self.device.mac); put16(frame[12..], 0x0800);
        const ip = frame[14..34]; @memset(ip, 0);
        ip[0] = 0x45; put16(ip[2..], @intCast(20 + tcp_length)); put16(ip[4..], self.identification); self.identification +%= 1;
        put16(ip[6..], 0x4000); ip[8] = 64; ip[9] = 6;
        @memcpy(ip[12..16], &self.local_ip); @memcpy(ip[16..20], &destination); put16(ip[10..], checksum(ip));
        const tcp = frame[34..size]; @memset(tcp, 0);
        put16(tcp[0..], source_port); put16(tcp[2..], destination_port);
        put32(tcp[4..], sequence); put32(tcp[8..], acknowledgement);
        tcp[12] = 5 << 4; tcp[13] = flags; put16(tcp[14..], 64240);
        @memcpy(tcp[20..], payload);
        put16(tcp[16..], tcpChecksum(self.local_ip, destination, tcp));
        try self.device.send(frame[0..size]);
    }

    fn receiveTcp(self: *Stack, source: [4]u8, source_port: u16, destination_port: u16, output: ?[]u8) !TcpSegment {
        var frame: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 64) : (attempts += 1) {
            const length = try self.device.receive(&frame);
            if (length < 54 or get16(frame[12..]) != 0x0800 or frame[23] != 6) continue;
            const ip_header = @as(usize, frame[14] & 0x0f) * 4;
            const total_length = get16(frame[16..]);
            if (ip_header < 20 or total_length < ip_header + 20 or length < 14 + total_length) continue;
            if (checksum(frame[14 .. 14 + ip_header]) != 0 or !equal(frame[26..30], &source) or !equal(frame[30..34], &self.local_ip)) continue;
            const tcp_offset = 14 + ip_header;
            const tcp_length = total_length - ip_header;
            const tcp = frame[tcp_offset .. tcp_offset + tcp_length];
            const tcp_header = @as(usize, tcp[12] >> 4) * 4;
            if (tcp_header < 20 or tcp_header > tcp.len or get16(tcp[0..]) != source_port or get16(tcp[2..]) != destination_port) continue;
            if (tcpChecksum(source, self.local_ip, tcp) != 0) continue;
            const payload_length = tcp.len - tcp_header;
            if (output) |target| {
                if (payload_length > target.len) return error.BufferTooSmall;
                @memcpy(target[0..payload_length], tcp[tcp_header..]);
            }
            return .{
                .sequence = get32(tcp[4..]),
                .acknowledgement = get32(tcp[8..]),
                .flags = tcp[13],
                .payload_length = payload_length,
            };
        }
        return error.TcpReplyMissing;
    }

    fn resolveAddress(self: *Stack, address: [4]u8) ![6]u8 {
        var frame: [42]u8 = .{0} ** 42;
        @memset(frame[0..6], 0xff);
        @memcpy(frame[6..12], &self.device.mac);
        put16(frame[12..], 0x0806);
        put16(frame[14..], 1); put16(frame[16..], 0x0800);
        frame[18] = 6; frame[19] = 4; put16(frame[20..], 1);
        @memcpy(frame[22..28], &self.device.mac);
        @memcpy(frame[28..32], &self.local_ip);
        @memcpy(frame[38..42], &address);
        try self.device.send(&frame);

        var received: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 16) : (attempts += 1) {
            const length = try self.device.receive(&received);
            if (length < 42 or get16(received[12..]) != 0x0806 or get16(received[20..]) != 2) continue;
            if (!equal(received[28..32], &address) or !equal(received[38..42], &self.local_ip)) continue;
            return received[22..28].*;
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
        @memcpy(ip[12..16], &self.local_ip); @memcpy(ip[16..20], &self.gateway_ip);
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
            if (!equal(received[26..30], &self.gateway_ip) or !equal(received[30..34], &self.local_ip)) continue;
            const reply = received[14 + header_length ..];
            if (reply[0] == 0 and reply[1] == 0 and get16(reply[4..]) == 0x4353 and checksum(reply[0 .. total_length - header_length]) == 0) return;
        }
        return error.EchoReplyMissing;
    }

    fn sendDhcp(self: *Stack, message_type: u8, requested: ?[4]u8, server: ?[4]u8) !void {
        var frame: [342]u8 = .{0} ** 342;
        @memset(frame[0..6], 0xff);
        @memcpy(frame[6..12], &self.device.mac);
        put16(frame[12..], 0x0800);
        const ip = frame[14..34];
        ip[0] = 0x45; put16(ip[2..], 328); put16(ip[4..], self.identification); self.identification +%= 1;
        put16(ip[6..], 0x4000); ip[8] = 64; ip[9] = 17;
        @memcpy(ip[16..20], &broadcast_ip);
        put16(ip[10..], checksum(ip));
        const udp = frame[34..42];
        put16(udp[0..], 68); put16(udp[2..], 67); put16(udp[4..], 308);
        const bootp = frame[42..342];
        bootp[0] = 1; bootp[1] = 1; bootp[2] = 6;
        put32(bootp[4..], transaction_id); put16(bootp[10..], 0x8000);
        @memcpy(bootp[28..34], &self.device.mac);
        bootp[236] = 99; bootp[237] = 130; bootp[238] = 83; bootp[239] = 99;
        var option: usize = 240;
        bootp[option] = 53; bootp[option + 1] = 1; bootp[option + 2] = message_type; option += 3;
        if (requested) |address| { bootp[option] = 50; bootp[option + 1] = 4; @memcpy(bootp[option + 2 .. option + 6], &address); option += 6; }
        if (server) |address| { bootp[option] = 54; bootp[option + 1] = 4; @memcpy(bootp[option + 2 .. option + 6], &address); option += 6; }
        bootp[option] = 55; bootp[option + 1] = 3; bootp[option + 2] = 1; bootp[option + 3] = 3; bootp[option + 4] = 6; option += 5;
        bootp[option] = 255;
        try self.device.send(&frame);
    }

    fn receiveDhcp(self: *Stack, expected_type: u8) !Lease {
        var frame: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 32) : (attempts += 1) {
            const length = try self.device.receive(&frame);
            if (length < 42 + 240 or get16(frame[12..]) != 0x0800 or frame[23] != 17) continue;
            const ip_header = @as(usize, frame[14] & 0x0f) * 4;
            if (ip_header < 20 or length < 14 + ip_header + 8 + 240) continue;
            const udp = 14 + ip_header;
            if (get16(frame[udp..]) != 67 or get16(frame[udp + 2 ..]) != 68) continue;
            const bootp = frame[udp + 8 ..];
            if (bootp[0] != 2 or get32(bootp[4..]) != transaction_id or !equal(bootp[28..34], &self.device.mac)) continue;
            if (bootp[236] != 99 or bootp[237] != 130 or bootp[238] != 83 or bootp[239] != 99) continue;
            var lease = Lease{ .address = bootp[16..20].* };
            var message_type: u8 = 0;
            const udp_length = get16(frame[udp + 4 ..]);
            if (udp_length < 248 or udp + udp_length > length) continue;
            var option: usize = 240;
            while (option < udp_length - 8) {
                const kind = bootp[option];
                if (kind == 255) break;
                if (kind == 0) { option += 1; continue; }
                if (option + 2 > udp_length - 8) break;
                const option_length = bootp[option + 1];
                if (option + 2 + option_length > udp_length - 8) break;
                const value = bootp[option + 2 .. option + 2 + option_length];
                if (kind == 53 and option_length == 1) message_type = value[0];
                if (kind == 54 and option_length == 4) @memcpy(&lease.server, value);
                if (kind == 1 and option_length >= 4) @memcpy(&lease.mask, value[0..4]);
                if (kind == 3 and option_length >= 4) @memcpy(&lease.router, value[0..4]);
                if (kind == 6 and option_length >= 4) @memcpy(&lease.dns, value[0..4]);
                option += 2 + option_length;
            }
            if (message_type == expected_type) return lease;
        }
        return error.DhcpReplyMissing;
    }

    fn sendUdp(self: *Stack, destination: [4]u8, destination_mac: [6]u8, source_port: u16, destination_port: u16, payload: []const u8) !void {
        if (payload.len > 1400) return error.DatagramTooLarge;
        var frame: [1442]u8 = undefined;
        const size = 14 + 20 + 8 + payload.len;
        @memcpy(frame[0..6], &destination_mac); @memcpy(frame[6..12], &self.device.mac); put16(frame[12..], 0x0800);
        const ip = frame[14..34]; @memset(ip, 0);
        ip[0] = 0x45; put16(ip[2..], @intCast(20 + 8 + payload.len)); put16(ip[4..], self.identification); self.identification +%= 1;
        put16(ip[6..], 0x4000); ip[8] = 64; ip[9] = 17;
        @memcpy(ip[12..16], &self.local_ip); @memcpy(ip[16..20], &destination); put16(ip[10..], checksum(ip));
        const udp = frame[34 .. 42 + payload.len];
        put16(udp[0..], source_port); put16(udp[2..], destination_port); put16(udp[4..], @intCast(8 + payload.len)); put16(udp[6..], 0);
        @memcpy(udp[8..], payload);
        const calculated = udpChecksum(self.local_ip, destination, udp);
        put16(udp[6..], if (calculated == 0) 0xffff else calculated);
        try self.device.send(frame[0..size]);
    }

    fn receiveUdp(self: *Stack, source: [4]u8, source_port: u16, destination_port: u16, output: []u8) !usize {
        var frame: [2048]u8 = undefined;
        var attempts: u8 = 0;
        while (attempts < 32) : (attempts += 1) {
            const length = try self.device.receive(&frame);
            if (length < 42 or get16(frame[12..]) != 0x0800 or frame[23] != 17) continue;
            const header_length = @as(usize, frame[14] & 0x0f) * 4;
            const total_length = get16(frame[16..]);
            if (header_length < 20 or total_length < header_length + 8 or length < 14 + total_length) continue;
            if (checksum(frame[14 .. 14 + header_length]) != 0 or !equal(frame[26..30], &source) or !equal(frame[30..34], &self.local_ip)) continue;
            const udp_offset = 14 + header_length;
            const udp_length = get16(frame[udp_offset + 4 ..]);
            if (udp_length < 8 or udp_length > total_length - header_length or get16(frame[udp_offset..]) != source_port or get16(frame[udp_offset + 2 ..]) != destination_port) continue;
            const udp = frame[udp_offset .. udp_offset + udp_length];
            const received_checksum = get16(udp[6..]);
            if (received_checksum != 0 and udpChecksum(source, self.local_ip, udp) != 0) continue;
            const payload_length = udp_length - 8;
            if (payload_length > output.len) return error.BufferTooSmall;
            @memcpy(output[0..payload_length], udp[8..]);
            return payload_length;
        }
        return error.UdpReplyMissing;
    }
};

const Lease = struct {
    address: [4]u8,
    server: [4]u8 = .{0} ** 4,
    mask: [4]u8 = .{0} ** 4,
    router: [4]u8 = .{0} ** 4,
    dns: [4]u8 = .{0} ** 4,
};

const tcp_fin: u8 = 0x01;
const tcp_syn: u8 = 0x02;
const tcp_psh: u8 = 0x08;
const tcp_ack: u8 = 0x10;

const TcpSegment = struct {
    sequence: u32,
    acknowledgement: u32,
    flags: u8,
    payload_length: usize,
};

pub const TcpConnection = struct {
    destination: [4]u8,
    destination_port: u16,
    source_port: u16,
    sequence: u32,
    peer_sequence: u32 = 0,
    connected: bool = false,
    peer_closed: bool = false,
};

fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];
    if (index < bytes.len) sum += @as(u32, bytes[index]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn udpChecksum(source: [4]u8, destination: [4]u8, udp: []const u8) u16 {
    var sum: u32 = 0;
    sum = addWords(sum, &source); sum = addWords(sum, &destination);
    sum += 17; sum += @intCast(udp.len);
    sum = addWords(sum, udp);
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn tcpChecksum(source: [4]u8, destination: [4]u8, tcp: []const u8) u16 {
    var sum: u32 = 0;
    sum = addWords(sum, &source); sum = addWords(sum, &destination);
    sum += 6; sum += @intCast(tcp.len);
    sum = addWords(sum, tcp);
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn addWords(initial: u32, bytes: []const u8) u32 {
    var sum = initial;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];
    if (index < bytes.len) sum += @as(u32, bytes[index]) << 8;
    return sum;
}

fn skipDnsName(message: []const u8, start: usize) !usize {
    var offset = start;
    while (offset < message.len) {
        const length = message[offset];
        if (length == 0) return offset + 1;
        if ((length & 0xc0) == 0xc0) return if (offset + 2 <= message.len) offset + 2 else error.InvalidDnsReply;
        if (length > 63 or offset + 1 + length > message.len) return error.InvalidDnsReply;
        offset += 1 + length;
    }
    return error.InvalidDnsReply;
}

fn put16(output: []u8, value: u16) void { output[0] = @truncate(value >> 8); output[1] = @truncate(value); }
fn put32(output: []u8, value: u32) void { output[0] = @truncate(value >> 24); output[1] = @truncate(value >> 16); output[2] = @truncate(value >> 8); output[3] = @truncate(value); }
fn get16(input: []const u8) u16 { return (@as(u16, input[0]) << 8) | input[1]; }
fn get32(input: []const u8) u32 { return (@as(u32, get16(input)) << 16) | get16(input[2..]); }
fn equal(left: []const u8, right: []const u8) bool { for (left, right) |a, b| if (a != b) return false; return true; }
fn zero(value: []const u8) bool { for (value) |byte| if (byte != 0) return false; return true; }
