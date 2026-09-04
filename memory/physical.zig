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
    total_pages: u64 = 0,
    installed_pages: u64 = 0,
    returned: [512]Range = undefined,
    returned_count: usize = 0,
    reclaimed_pages: u64 = 0,

    pub fn init(map: [*]align(8) const u8, descriptor_count: usize, descriptor_size: usize) Allocator {
        var self = Allocator{};
        var index: usize = 0;
        while (index < descriptor_count and self.range_count < self.ranges.len) : (index += 1) {
            const descriptor: *align(1) const Descriptor = @ptrCast(map + index * descriptor_size);
            if ((descriptor.kind >= 1 and descriptor.kind <= 10) or descriptor.kind == 14)
                self.installed_pages += descriptor.page_count;
            if (descriptor.kind != conventional_memory or descriptor.page_count == 0) continue;

            var start = descriptor.physical_start;
            const end = start + descriptor.page_count * page_size;
            if (end <= 0x100000) continue;
            if (start < 0x100000) start = 0x100000;
            self.ranges[self.range_count] = .{ .next = start, .end = end };
            self.range_count += 1;
            self.free_pages += (end - start) / page_size;
            self.total_pages += (end - start) / page_size;
        }
        return self;
    }

    pub fn allocate(self: *Allocator, count: u64) ?u64 {
        return self.allocateAligned(count, page_size);
    }

    pub fn allocateAligned(self: *Allocator, count: u64, alignment: u64) ?u64 {
        if (count == 0 or count > (~@as(u64, 0)) / page_size or
            alignment < page_size or (alignment & (alignment - 1)) != 0) return null;
        const bytes = count * page_size;
        var returned_index: usize = 0;
        while (returned_index < self.returned_count) : (returned_index += 1) {
            const range = self.returned[returned_index];
            const address = alignedFit(range, bytes, alignment) orelse continue;
            const end = address + bytes;
            if (address != range.next and end != range.end) {
                if (self.returned_count == self.returned.len) continue;
                var shift = self.returned_count;
                while (shift > returned_index + 1) : (shift -= 1) self.returned[shift] = self.returned[shift - 1];
                self.returned[returned_index] = .{ .next = range.next, .end = address };
                self.returned[returned_index + 1] = .{ .next = end, .end = range.end };
                self.returned_count += 1;
            } else if (address != range.next) {
                self.returned[returned_index].end = address;
            } else if (end != range.end) {
                self.returned[returned_index].next = end;
            } else {
                var shift = returned_index;
                while (shift + 1 < self.returned_count) : (shift += 1) self.returned[shift] = self.returned[shift + 1];
                self.returned_count -= 1;
            }
            self.free_pages -= count;
            return address;
        }
        for (self.ranges[0..self.range_count]) |*range| {
            const address = alignedFit(range.*, bytes, alignment) orelse continue;
            if (address != range.next) {
                // Preserve padding in the sorted free list, without counting
                // it as reclaimed or allocated memory.
                if (self.returned_count == self.returned.len) continue;
                var index: usize = 0;
                while (index < self.returned_count and self.returned[index].next < range.next) : (index += 1) {}
                var shift = self.returned_count;
                while (shift > index) : (shift -= 1) self.returned[shift] = self.returned[shift - 1];
                self.returned[index] = .{ .next = range.next, .end = address };
                self.returned_count += 1;
            }
            range.next = address + bytes;
            self.free_pages -= count;
            return address;
        }
        return null;
    }

    pub fn release(self: *Allocator, address: u64, count: u64) !void {
        if (count == 0 or count > (~@as(u64, 0)) / page_size or (address & (page_size - 1)) != 0) return error.InvalidRelease;
        const bytes = count * page_size;
        const end = address +% bytes;
        if (end <= address) return error.InvalidRelease;
        for (self.ranges[0..self.range_count]) |*range| {
            if (range.next != end) continue;
            range.next = address;
            var returned_index: usize = 0;
            while (returned_index < self.returned_count) : (returned_index += 1) {
                if (self.returned[returned_index].end != range.next) continue;
                range.next = self.returned[returned_index].next;
                var shift = returned_index;
                while (shift + 1 < self.returned_count) : (shift += 1) self.returned[shift] = self.returned[shift + 1];
                self.returned_count -= 1;
                break;
            }
            self.free_pages += count;
            self.reclaimed_pages += count;
            return;
        }
        var index: usize = 0;
        while (index < self.returned_count and self.returned[index].next < address) : (index += 1) {}
        if (index > 0 and self.returned[index - 1].end > address) return error.OverlappingRelease;
        if (index < self.returned_count and end > self.returned[index].next) return error.OverlappingRelease;
        if (index > 0 and self.returned[index - 1].end == address) {
            self.returned[index - 1].end = end;
            if (index < self.returned_count and end == self.returned[index].next) {
                self.returned[index - 1].end = self.returned[index].end;
                var shift = index;
                while (shift + 1 < self.returned_count) : (shift += 1) self.returned[shift] = self.returned[shift + 1];
                self.returned_count -= 1;
            }
        } else if (index < self.returned_count and end == self.returned[index].next) {
            self.returned[index].next = address;
        } else {
            if (self.returned_count == self.returned.len) return error.ReleaseListFull;
            var shift = self.returned_count;
            while (shift > index) : (shift -= 1) self.returned[shift] = self.returned[shift - 1];
            self.returned[index] = .{ .next = address, .end = end };
            self.returned_count += 1;
        }
        self.free_pages += count;
        self.reclaimed_pages += count;
    }

    pub fn availableRanges(self: *const Allocator) []const Range {
        return self.ranges[0..self.range_count];
    }
};

fn alignedFit(range: Range, bytes: u64, alignment: u64) ?u64 {
    if (range.next > (~@as(u64, 0)) - (alignment - 1)) return null;
    const address = (range.next + alignment - 1) & ~(alignment - 1);
    if (address > range.end or bytes > range.end - address) return null;
    return address;
}

pub fn validateAlignedAllocationSelfTest() !void {
    var allocator = Allocator{ .range_count = 1, .free_pages = 1023 };
    allocator.ranges[0] = .{ .next = 0x1000, .end = 0x400000 };
    const address = allocator.allocateAligned(2, 0x200000) orelse return error.AlignedAllocationFailed;
    if (address != 0x200000 or allocator.free_pages != 1021 or allocator.reclaimed_pages != 0 or
        allocator.returned_count != 1 or allocator.returned[0].next != 0x1000 or allocator.returned[0].end != address)
        return error.AlignedAllocationPaddingLost;
    try allocator.release(address, 2);
    if (allocator.free_pages != 1023 or allocator.ranges[0].next != 0x1000 or allocator.returned_count != 0)
        return error.AlignedAllocationReleaseMismatch;
    allocator.range_count = 0;
    allocator.returned_count = 1;
    allocator.returned[0] = .{ .next = 0x1000, .end = 0x400000 };
    if (allocator.allocateAligned(2, 0x200000) != address or allocator.returned_count != 2)
        return error.AlignedReturnedRangeSplitFailed;
    try allocator.release(address, 2);
    if (allocator.returned_count != 1 or allocator.returned[0].next != 0x1000 or
        allocator.returned[0].end != 0x400000 or allocator.free_pages != 1023)
        return error.AlignedReturnedRangeMergeFailed;
    if (allocator.allocateAligned(1024, 0x200000) != null or allocator.allocateAligned(1, 6000) != null or
        allocator.allocateAligned(~@as(u64, 0), 4096) != null or allocator.free_pages != 1023)
        return error.AlignedInvalidAllocationMutatedState;
    allocator.returned[0] = .{ .next = 0xfffffffffffff000, .end = 0xffffffffffffffff };
    if (allocator.allocateAligned(1, 0x200000) != null) return error.AlignedAddressOverflowAccepted;
}
