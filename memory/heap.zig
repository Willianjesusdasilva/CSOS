const physical = @import("physical");

const page_size = 4096;

pub const Heap = struct {
    base: [*]u8,
    size: usize,
    used: usize = 0,

    pub fn init(pages: *physical.Allocator, page_count: u64) !Heap {
        const address = pages.allocate(page_count) orelse return error.OutOfMemory;
        return .{ .base = @ptrFromInt(address), .size = @intCast(page_count * page_size) };
    }

    pub fn allocate(self: *Heap, size: usize, alignment: usize) ?[]u8 {
        if (size == 0 or alignment == 0 or !isPowerOfTwo(alignment)) return null;
        const start = (self.used + alignment - 1) & ~(alignment - 1);
        if (start > self.size or size > self.size - start) return null;
        self.used = start + size;
        return self.base[start..self.used];
    }
};

fn isPowerOfTwo(value: usize) bool {
    return (value & (value - 1)) == 0;
}
