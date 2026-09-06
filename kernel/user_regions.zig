const std = @import("std");

pub const Region = struct { base: u64, size: u64 };

pub fn append(regions: []Region, count: *usize, base: u64, size: u64) !void {
    if (size == 0 or base > std.math.maxInt(u64) - (size - 1)) return error.InvalidRegion;
    if (count.* != 0) {
        const previous = &regions[count.* - 1];
        if (base >= previous.base and base - previous.base == previous.size) {
            if (previous.size > std.math.maxInt(u64) - size) return error.InvalidRegion;
            previous.size += size;
            return;
        }
    }
    if (count.* == regions.len) return error.TooManyUserRegions;
    regions[count.*] = .{ .base = base, .size = size };
    count.* += 1;
}

pub fn contains(regions: []const Region, address: u64, length: u64) bool {
    for (regions) |region| {
        if (address >= region.base and length <= region.size and
            address - region.base <= region.size - length) return true;
    }
    return false;
}

test "mapped user regions require a whole slice inside one region" {
    const regions = [_]Region{
        .{ .base = 0x5000, .size = 0x1000 },
        .{ .base = 0x7000, .size = 0x2000 },
    };
    try std.testing.expect(contains(&regions, 0x5000, 1));
    try std.testing.expect(contains(&regions, 0x5fff, 1));
    try std.testing.expect(contains(&regions, 0x7000, 0x2000));
    try std.testing.expect(!contains(&regions, 0x5fff, 2));
    try std.testing.expect(!contains(&regions, 0x6000, 1));
    try std.testing.expect(!contains(&regions, 0x7000, 0x2001));
    try std.testing.expect(!contains(&regions, std.math.maxInt(u64), 2));
}

test "mapped user regions compact only adjacent insertion-order ranges" {
    var regions: [3]Region = undefined;
    var count: usize = 0;
    try append(&regions, &count, 0x6000, 0x1000);
    try append(&regions, &count, 0x7000, 0x1000);
    try append(&regions, &count, 0x5000, 0x1000);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 0x2000), regions[0].size);
    try std.testing.expectEqual(@as(u64, 0x5000), regions[1].base);
    try std.testing.expectError(error.InvalidRegion, append(&regions, &count, 0, 0));
    try std.testing.expectError(error.InvalidRegion, append(&regions, &count, std.math.maxInt(u64), 2));
    try append(&regions, &count, 0x9000, 0x1000);
    try std.testing.expectError(error.TooManyUserRegions, append(&regions, &count, 0xb000, 0x1000));
}
