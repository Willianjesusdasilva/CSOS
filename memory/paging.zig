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

    pub fn mapIdentity(self: *Mapper, address: u64, size: u64) !void {
        try self.identityMapRange(address, size);
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
        const root = try cloneTable(pages, kernel_root, 4);
        return .{ .root = root, .pages = pages };
    }

    pub fn mapUserPage(self: *AddressSpace, virtual: u64, physical_address: u64, writable: bool, executable: bool) !void {
        if ((virtual & (page_size - 1)) != 0 or (physical_address & (page_size - 1)) != 0) return error.Unaligned;
        const pml4 = table(self.root);
        const pml4_index = (virtual >> 39) & 0x1ff;
        const pdpt = try childUserTable(self.pages, pml4, pml4_index);
        const pdpt_index = (virtual >> 30) & 0x1ff;
        const directory = try childUserTable(self.pages, pdpt, pdpt_index);
        const directory_index = (virtual >> 21) & 0x1ff;
        const page_table = try childUserPageTable(self.pages, directory, directory_index);
        const page_index = (virtual >> 12) & 0x1ff;
        page_table[page_index] = physical_address | 0x005 |
            (if (writable) @as(u64, 0x002) else 0) |
            (if (executable) @as(u64, 0) else @as(u64, 1) << 63);
    }

    pub fn unmapUserPage(self: *AddressSpace, virtual: u64) ?u64 {
        const entry = userLeaf(self.root, virtual) orelse return null;
        if ((entry.* & 1) == 0) return null;
        const physical_address = entry.* & address_mask;
        entry.* = 0;
        asm volatile ("invlpg (%[address])"
            :
            : [address] "r" (virtual),
            : .{ .memory = true });
        return physical_address;
    }

    pub fn userPermissions(self: *const AddressSpace, virtual: u64) ?Permissions {
        const entry = userLeaf(self.root, virtual) orelse return null;
        if ((entry.* & 1) == 0) return null;
        return .{ .writable = (entry.* & 0x002) != 0, .executable = (entry.* & (@as(u64, 1) << 63)) == 0 };
    }

    pub fn activate(self: *const AddressSpace) void {
        asm volatile ("mov %[root], %%cr3"
            :
            : [root] "r" (self.root),
            : .{ .memory = true });
    }

    pub fn destroy(self: *AddressSpace) void {
        if (self.root == 0) return;
        destroyTable(self.pages, self.root, 4);
        self.root = 0;
    }
};

pub const Permissions = struct { writable: bool, executable: bool };

pub fn activateRoot(root: u64) void {
    asm volatile ("mov %[root], %%cr3"
        :
        : [root] "r" (root),
        : .{ .memory = true });
}

fn cloneTable(pages: *physical.Allocator, source_address: u64, level: u8) !u64 {
    const destination_address = try allocateTable(pages);
    const source = table(source_address);
    const destination = table(destination_address);
    for (source, destination) |source_entry, *destination_entry| {
        if ((source_entry & 1) == 0 or level == 1 or (source_entry & 0x080) != 0) {
            destination_entry.* = source_entry;
            continue;
        }
        const child = try cloneTable(pages, source_entry & address_mask, level - 1);
        destination_entry.* = child | (source_entry & ~address_mask);
    }
    return destination_address;
}

fn childTable(pages: *physical.Allocator, parent: *[entry_count]u64, index: u64) !*[entry_count]u64 {
    if ((parent[index] & 1) == 0) parent[index] = (try allocateTable(pages)) | present_writable;
    return table(parent[index] & address_mask);
}

fn childUserTable(pages: *physical.Allocator, parent: *[entry_count]u64, index: u64) !*[entry_count]u64 {
    if ((parent[index] & 1) == 0) parent[index] = (try allocateTable(pages)) | 0x007 else parent[index] |= 0x004;
    if ((parent[index] & 0x080) != 0) return error.HugePageConflict;
    return table(parent[index] & address_mask);
}

fn childUserPageTable(pages: *physical.Allocator, directory: *[entry_count]u64, index: u64) !*[entry_count]u64 {
    if ((directory[index] & 0x080) != 0) {
        const huge_entry = directory[index];
        const huge_base = huge_entry & 0x000fffffffe00000;
        const leaf_flags = huge_entry & 0x8000000000000fff & ~@as(u64, 0x080);
        const page_table_address = try allocateTable(pages);
        const page_table = table(page_table_address);
        for (page_table, 0..) |*entry, page_index| {
            entry.* = huge_base + @as(u64, page_index) * page_size | leaf_flags;
        }
        directory[index] = page_table_address | 0x007;
        return page_table;
    }
    return childUserTable(pages, directory, index);
}

fn allocateTable(pages: *physical.Allocator) !u64 {
    const address = pages.allocate(1) orelse return error.OutOfMemory;
    @memset(table(address), 0);
    return address;
}

fn table(address: u64) *[entry_count]u64 {
    return @ptrFromInt(address);
}

fn userLeaf(root: u64, virtual: u64) ?*u64 {
    const pml4_entry = &table(root)[(virtual >> 39) & 0x1ff];
    if ((pml4_entry.* & 1) == 0 or (pml4_entry.* & 0x080) != 0) return null;
    const pdpt_entry = &table(pml4_entry.* & address_mask)[(virtual >> 30) & 0x1ff];
    if ((pdpt_entry.* & 1) == 0 or (pdpt_entry.* & 0x080) != 0) return null;
    const directory_entry = &table(pdpt_entry.* & address_mask)[(virtual >> 21) & 0x1ff];
    if ((directory_entry.* & 1) == 0 or (directory_entry.* & 0x080) != 0) return null;
    return &table(directory_entry.* & address_mask)[(virtual >> 12) & 0x1ff];
}

fn destroyTable(pages: *physical.Allocator, address: u64, level: u8) void {
    if (level > 1) {
        for (table(address)) |entry| {
            if ((entry & 1) == 0 or (entry & 0x080) != 0) continue;
            destroyTable(pages, entry & address_mask, level - 1);
        }
    }
    pages.release(address, 1) catch unreachable;
}
