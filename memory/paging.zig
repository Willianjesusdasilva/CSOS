const physical = @import("physical");

const page_size: u64 = 4096;
const huge_page_size: u64 = 2 * 1024 * 1024;
const entry_count = 512;
const address_mask: u64 = 0x000ffffffffff000;
const present_writable: u64 = 0x003;
const huge_present_writable: u64 = 0x083;

pub const Mapper = struct {
    root: u64,
    pages: *physical.Allocator,

    pub fn init(pages: *physical.Allocator, framebuffer_base: u64, framebuffer_size: usize) !Mapper {
        const root = try allocateTable(pages);
        var self = Mapper{ .root = root, .pages = pages };

        // UEFI images, stacks, legacy devices and the AP trampoline live below 4 GiB.
        try self.identityMapRange(0, 4 * 1024 * 1024 * 1024);
        for (pages.availableRanges()) |range| {
            try self.identityMapRange(range.next, range.end - range.next);
        }
        try self.identityMapRange(framebuffer_base, framebuffer_size);
        return self;
    }

    pub fn activate(self: *const Mapper) void {
        asm volatile ("mov %[root], %%cr3"
            :
            : [root] "r" (self.root),
            : .{ .memory = true });
    }

    fn identityMapRange(self: *Mapper, start: u64, size: u64) !void {
        if (size == 0) return;
        var address = start & ~(huge_page_size - 1);
        const end = (start + size + huge_page_size - 1) & ~(huge_page_size - 1);
        while (address < end) : (address += huge_page_size) try self.mapHuge(address);
    }

    fn mapHuge(self: *Mapper, address: u64) !void {
        const pml4 = table(self.root);
        const pml4_index = (address >> 39) & 0x1ff;
        const pdpt = try childTable(self.pages, pml4, pml4_index);
        const pdpt_index = (address >> 30) & 0x1ff;
        const directory = try childTable(self.pages, pdpt, pdpt_index);
        const directory_index = (address >> 21) & 0x1ff;
        directory[directory_index] = (address & ~(huge_page_size - 1)) | huge_present_writable;
    }
};

pub const AddressSpace = struct {
    root: u64,
    pages: *physical.Allocator,

    pub fn init(kernel_root: u64, pages: *physical.Allocator) !AddressSpace {
        const root = try allocateTable(pages);
        table(root).* = table(kernel_root).*;
        return .{ .root = root, .pages = pages };
    }

    pub fn mapUserPage(self: *AddressSpace, virtual: u64, physical_address: u64, writable: bool) !void {
        if ((virtual & (page_size - 1)) != 0 or (physical_address & (page_size - 1)) != 0) return error.Unaligned;
        const pml4 = table(self.root);
        const pml4_index = (virtual >> 39) & 0x1ff;
        const pdpt = try childUserTable(self.pages, pml4, pml4_index);
        const pdpt_index = (virtual >> 30) & 0x1ff;
        const directory = try childUserTable(self.pages, pdpt, pdpt_index);
        const directory_index = (virtual >> 21) & 0x1ff;
        const page_table = try childUserTable(self.pages, directory, directory_index);
        const page_index = (virtual >> 12) & 0x1ff;
        page_table[page_index] = physical_address | 0x005 | if (writable) @as(u64, 0x002) else 0;
    }

    pub fn activate(self: *const AddressSpace) void {
        asm volatile ("mov %[root], %%cr3"
            :
            : [root] "r" (self.root),
            : .{ .memory = true });
    }
};

fn childTable(pages: *physical.Allocator, parent: *[entry_count]u64, index: u64) !*[entry_count]u64 {
    if ((parent[index] & 1) == 0) parent[index] = (try allocateTable(pages)) | present_writable;
    return table(parent[index] & address_mask);
}

fn childUserTable(pages: *physical.Allocator, parent: *[entry_count]u64, index: u64) !*[entry_count]u64 {
    if ((parent[index] & 1) == 0) parent[index] = (try allocateTable(pages)) | 0x007 else parent[index] |= 0x004;
    if ((parent[index] & 0x080) != 0) return error.HugePageConflict;
    return table(parent[index] & address_mask);
}

fn allocateTable(pages: *physical.Allocator) !u64 {
    const address = pages.allocate(1) orelse return error.OutOfMemory;
    @memset(table(address), 0);
    return address;
}

fn table(address: u64) *[entry_count]u64 {
    return @ptrFromInt(address);
}
