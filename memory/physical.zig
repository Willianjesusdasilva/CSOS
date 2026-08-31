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
        if (count == 0) return null;
        const bytes = count * page_size;
        var returned_index: usize = 0;
        while (returned_index < self.returned_count) : (returned_index += 1) {
            const range = &self.returned[returned_index];
            if (range.end - range.next < bytes) continue;
            const address = range.next;
            range.next += bytes;
            if (range.next == range.end) {
                var shift = returned_index;
                while (shift + 1 < self.returned_count) : (shift += 1) self.returned[shift] = self.returned[shift + 1];
                self.returned_count -= 1;
            }
            self.free_pages -= count;
            return address;
        }
        for (self.ranges[0..self.range_count]) |*range| {
            if (range.end - range.next < bytes) continue;
            const address = range.next;
            range.next += bytes;
            self.free_pages -= count;
            return address;
        }
        return null;
    }

    pub fn release(self: *Allocator, address: u64, count: u64) !void {
        if (count == 0 or (address & (page_size - 1)) != 0) return error.InvalidRelease;
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
