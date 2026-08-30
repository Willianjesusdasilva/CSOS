const page_size = 4096;
const conventional_memory = 7;

const Descriptor = extern struct {
    kind: u32,
    _padding: u32,
    physical_start: u64,
    virtual_start: u64,
    page_count: u64,
    attributes: u64,
};

pub const Range = struct {
    next: u64,
    end: u64,
};

pub const Allocator = struct {
    ranges: [128]Range = undefined,
    range_count: usize = 0,
    free_pages: u64 = 0,

    pub fn init(map: [*]align(8) const u8, descriptor_count: usize, descriptor_size: usize) Allocator {
        var self = Allocator{};
        var index: usize = 0;
        while (index < descriptor_count and self.range_count < self.ranges.len) : (index += 1) {
            const descriptor: *align(1) const Descriptor = @ptrCast(map + index * descriptor_size);
            if (descriptor.kind != conventional_memory or descriptor.page_count == 0) continue;

            var start = descriptor.physical_start;
            const end = start + descriptor.page_count * page_size;
            if (end <= 0x100000) continue;
            if (start < 0x100000) start = 0x100000;
            self.ranges[self.range_count] = .{ .next = start, .end = end };
            self.range_count += 1;
            self.free_pages += (end - start) / page_size;
        }
        return self;
    }

    pub fn allocate(self: *Allocator, count: u64) ?u64 {
        if (count == 0) return null;
        const bytes = count * page_size;
        for (self.ranges[0..self.range_count]) |*range| {
            if (range.end - range.next < bytes) continue;
            const address = range.next;
            range.next += bytes;
            self.free_pages -= count;
            return address;
        }
        return null;
    }

    pub fn availableRanges(self: *const Allocator) []const Range {
        return self.ranges[0..self.range_count];
    }
};
