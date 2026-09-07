pub const Summary = struct { minimum: u64, p50: u64, p95: u64, p99: u64, maximum: u64 };

pub const Samples = struct {
    values: [32]u64 = undefined,
    count: usize = 0,

    pub fn add(self: *Samples, value: u64) !void {
        if (self.count == self.values.len) return error.Full;
        self.values[self.count] = value;
        self.count += 1;
    }

    pub fn summarize(self: *const Samples) !Summary {
        if (self.count == 0) return error.Empty;
        var ordered: [32]u64 = undefined;
        @memcpy(ordered[0..self.count], self.values[0..self.count]);
        var index: usize = 1;
        while (index < self.count) : (index += 1) {
            const value = ordered[index];
            var position = index;
            while (position > 0 and ordered[position - 1] > value) : (position -= 1)
                ordered[position] = ordered[position - 1];
            ordered[position] = value;
        }
        return .{
            .minimum = ordered[0],
            .p50 = ordered[percentileIndex(self.count, 50)],
            .p95 = ordered[percentileIndex(self.count, 95)],
            .p99 = ordered[percentileIndex(self.count, 99)],
            .maximum = ordered[self.count - 1],
        };
    }
};

fn percentileIndex(count: usize, percentile: usize) usize {
    return (count * percentile + 99) / 100 - 1;
}

test "metrics summary orders samples and computes percentiles" {
    var samples = Samples{};
    try samples.add(50);
    try samples.add(10);
    try samples.add(30);
    const summary = try samples.summarize();
    try @import("std").testing.expectEqual(@as(u64, 10), summary.minimum);
    try @import("std").testing.expectEqual(@as(u64, 30), summary.p50);
    try @import("std").testing.expectEqual(@as(u64, 50), summary.p95);
    try @import("std").testing.expectEqual(@as(u64, 50), summary.p99);
    try @import("std").testing.expectEqual(@as(u64, 50), summary.maximum);
}

test "metrics rejects empty and overfull sample sets" {
    var samples = Samples{};
    try @import("std").testing.expectError(error.Empty, samples.summarize());
    for (0..samples.values.len) |index| try samples.add(@intCast(index));
    try @import("std").testing.expectError(error.Full, samples.add(99));
}
