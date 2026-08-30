pub const Record = struct {
    bytes: [64]u8 = undefined,
    length: usize = 0,

    pub fn text(self: *const Record) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const installing = "installing\n";

pub fn completed(signature: u64) Record {
    var record = Record{};
    append(&record, "ready\nversion=1\nsignature=");
    appendHex(&record, signature);
    append(&record, "\n");
    return record;
}

pub fn matches(bytes: []const u8, signature: u64) bool {
    const expected = completed(signature);
    if (bytes.len != expected.length) return false;
    for (bytes, expected.text()) |left, right| if (left != right) return false;
    return true;
}

fn append(record: *Record, bytes: []const u8) void {
    @memcpy(record.bytes[record.length .. record.length + bytes.len], bytes);
    record.length += bytes.len;
}

fn appendHex(record: *Record, value: u64) void {
    const alphabet = "0123456789abcdef";
    var digits: [16]u8 = undefined;
    var index = digits.len;
    var remaining = value;
    if (remaining == 0) return append(record, "0");
    while (remaining != 0) {
        index -= 1;
        digits[index] = alphabet[@truncate(remaining & 0xf)];
        remaining >>= 4;
    }
    append(record, digits[index..]);
}
