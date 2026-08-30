const paging = @import("paging");
const physical = @import("physical");
const syscalls = @import("syscalls");
const image = @embedFile("hello_elf");
const stack_address: u64 = 0x0000009000000000;
const page_size: u64 = 4096;
const max_mappings = 64;

const Mapping = struct { virtual: u64, physical: u64 };

extern fn enter_user(entry: u64, stack: u64) callconv(.c) void;

pub fn runHello(kernel_root: u64, pages: *physical.Allocator) !void {
    if (image.len < 64 or !isElf()) return error.InvalidElf;
    const entry = read64(24);
    const program_offset = read64(32);
    const program_entry_size = read16(54);
    const program_count = read16(56);
    if (program_entry_size < 56 or program_offset + @as(u64, program_entry_size) * program_count > image.len) return error.InvalidElf;

    var address_space = try paging.AddressSpace.init(kernel_root, pages);
    var mappings: [max_mappings]Mapping = undefined;
    var mapping_count: usize = 0;
    var image_start: u64 = ~@as(u64, 0);
    var image_end: u64 = 0;

    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 1) continue;
        const flags = read32At(header + 4);
        const file_offset = read64At(header + 8);
        const virtual = read64At(header + 16);
        const file_size = read64At(header + 32);
        const memory_size = read64At(header + 40);
        if (file_size > memory_size or file_offset + file_size > image.len or memory_size == 0) return error.InvalidElf;
        image_start = @min(image_start, virtual);
        image_end = @max(image_end, virtual + memory_size);
        try loadSegment(&address_space, pages, &mappings, &mapping_count, virtual, file_offset, file_size, memory_size, (flags & 2) != 0);
    }
    if (mapping_count == 0 or entry < image_start or entry >= image_end) return error.InvalidElf;

    const stack_pages = pages.allocate(2) orelse return error.OutOfMemory;
    try address_space.mapUserPage(stack_address, stack_pages, true);
    try address_space.mapUserPage(stack_address + 4096, stack_pages + 4096, true);
    syscalls.configure(image_start, image_end - image_start);
    address_space.activate();
    enter_user(entry, stack_address + 8192);
    if (syscalls.completedWrites() != 1) return error.SyscallFailed;
}

fn loadSegment(
    address_space: *paging.AddressSpace,
    pages: *physical.Allocator,
    mappings: *[max_mappings]Mapping,
    mapping_count: *usize,
    virtual: u64,
    file_offset: u64,
    file_size: u64,
    memory_size: u64,
    writable: bool,
) !void {
    var page_virtual = virtual & ~(page_size - 1);
    const segment_end = virtual + memory_size;
    while (page_virtual < segment_end) : (page_virtual += page_size) {
        var physical_address: ?u64 = null;
        for (mappings[0..mapping_count.*]) |mapping| {
            if (mapping.virtual == page_virtual) physical_address = mapping.physical;
        }
        if (physical_address == null) {
            if (mapping_count.* == max_mappings) return error.TooManyMappings;
            physical_address = pages.allocate(1) orelse return error.OutOfMemory;
            const bytes: [*]u8 = @ptrFromInt(physical_address.?);
            @memset(bytes[0..page_size], 0);
            try address_space.mapUserPage(page_virtual, physical_address.?, writable);
            mappings[mapping_count.*] = .{ .virtual = page_virtual, .physical = physical_address.? };
            mapping_count.* += 1;
        }

        const copy_start = @max(page_virtual, virtual);
        const copy_end = @min(page_virtual + page_size, virtual + file_size);
        if (copy_start < copy_end) {
            const destination: [*]u8 = @ptrFromInt(physical_address.? + copy_start - page_virtual);
            const source: usize = @intCast(file_offset + copy_start - virtual);
            const length: usize = @intCast(copy_end - copy_start);
            @memcpy(destination[0..length], image[source .. source + length]);
        }
    }
}

fn isElf() bool {
    return image[0] == 0x7f and image[1] == 'E' and image[2] == 'L' and image[3] == 'F' and
        image[4] == 2 and image[5] == 1 and read16(18) == 0x3e;
}

fn read16(offset: usize) u16 {
    return @as(u16, image[offset]) | (@as(u16, image[offset + 1]) << 8);
}

fn read32At(offset: usize) u32 {
    return @as(u32, read16(offset)) | (@as(u32, read16(offset + 2)) << 16);
}

fn read64(offset: usize) u64 {
    return read64At(offset);
}

fn read64At(offset: usize) u64 {
    return @as(u64, read32At(offset)) | (@as(u64, read32At(offset + 4)) << 32);
}
