const paging = @import("paging");
const physical = @import("physical");
const syscalls = @import("syscalls");
const busybox_image = @embedFile("busybox_elf");
const nettest_image = @embedFile("nettest_elf");
const hello_image = @embedFile("hello_elf");
var image: []const u8 = busybox_image;
const stack_address: u64 = 0x0000009000000000;
const mmap_address: u64 = 0x000000a000000000;
const page_size: u64 = 4096;
const max_mappings = 512;
const max_owned_ranges = 512;

const Mapping = struct {
    virtual: u64,
    physical: u64,
    owner_index: usize,
    writable: bool,
    resident: bool = true,
};
const OwnedRange = struct { address: u64, pages: u64 };

var active_address_space: ?*paging.AddressSpace = null;
var active_pages: ?*physical.Allocator = null;
var active_mappings: ?[]Mapping = null;
var active_owned: ?[]OwnedRange = null;
var active_load_bias: u64 = 0;
pub var standby_pages: u64 = 0;
pub var restored_pages: u64 = 0;
pub var pause_count: u64 = 0;
pub const Lifecycle = enum { running, frozen, standby, resuming, finished };
pub var lifecycle: Lifecycle = .finished;

extern fn enter_user(entry: u64, stack: u64) callconv(.c) void;

pub fn runBusyBox(kernel_root: u64, pages: *physical.Allocator, arguments: []const []const u8) !void {
    image = busybox_image;
    return runImage(kernel_root, pages, arguments);
}

pub fn runNetTest(kernel_root: u64, pages: *physical.Allocator) !void {
    image = nettest_image;
    const arguments = [_][]const u8{"/bin/nettest"};
    return runImage(kernel_root, pages, &arguments);
}

pub fn runHelloPie(kernel_root: u64, pages: *physical.Allocator) !void {
    image = hello_image;
    if (read16(16) != 3) return error.NotPie;
    const arguments = [_][]const u8{"/bin/hello-pie"};
    return runImage(kernel_root, pages, &arguments);
}

fn runImage(kernel_root: u64, pages: *physical.Allocator, arguments: []const []const u8) !void {
    if (image.len < 64 or !isElf()) return error.InvalidElf;
    const elf_type = read16(16);
    if (elf_type != 2 and elf_type != 3) return error.UnsupportedElfType;
    const load_bias: u64 = if (elf_type == 3) 0x0000008000000000 else 0;
    const entry = read64(24) + load_bias;
    const program_offset = read64(32);
    const program_entry_size = read16(54);
    const program_count = read16(56);
    if (program_entry_size < 56 or program_offset + @as(u64, program_entry_size) * program_count > image.len) return error.InvalidElf;

    var address_space = try paging.AddressSpace.init(kernel_root, pages);
    var owned: [max_owned_ranges]OwnedRange = undefined;
    var owned_count: usize = 0;
    defer {
        paging.activateRoot(kernel_root);
        address_space.destroy();
        releaseOwned(pages, owned[0..owned_count]);
    }
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
        const virtual = read64At(header + 16) + load_bias;
        const file_size = read64At(header + 32);
        const memory_size = read64At(header + 40);
        if (file_size > memory_size or file_offset + file_size > image.len or memory_size == 0) return error.InvalidElf;
        image_start = @min(image_start, virtual);
        image_end = @max(image_end, virtual + memory_size);
        try loadSegment(&address_space, pages, &mappings, &mapping_count, &owned, &owned_count, virtual, file_offset, file_size, memory_size, (flags & 2) != 0);
    }
    if (mapping_count == 0 or entry < image_start or entry >= image_end) return error.InvalidElf;

    const stack_page_count = 8;
    const initial_stack_size = 4 * page_size;
    const stack_pages = pages.allocate(stack_page_count) orelse return error.OutOfMemory;
    try own(&owned, &owned_count, stack_pages, stack_page_count);
    var stack_page: u64 = 0;
    while (stack_page < stack_page_count) : (stack_page += 1) {
        try address_space.mapUserPage(stack_address + stack_page * page_size, stack_pages + stack_page * page_size, true);
    }
    const break_base = (image_end + page_size - 1) & ~(page_size - 1);
    const arena_pages = 64;
    try mapAnonymous(&address_space, pages, &owned, &owned_count, break_base, arena_pages);
    try mapAnonymous(&address_space, pages, &owned, &owned_count, mmap_address, arena_pages);
    const stack_pointer = try buildInitialStack(stack_pages, initial_stack_size, entry, load_bias, program_offset, program_entry_size, program_count, arguments);
    syscalls.configure(
        image_start,
        image_end - image_start,
        stack_address,
        stack_page_count * page_size,
        break_base,
        break_base + arena_pages * page_size,
        mmap_address,
        mmap_address + arena_pages * page_size,
    );
    active_address_space = &address_space;
    active_pages = pages;
    active_mappings = mappings[0..mapping_count];
    active_owned = owned[0..owned_count];
    active_load_bias = load_bias;
    defer {
        active_address_space = null;
        active_pages = null;
        active_mappings = null;
        active_owned = null;
        active_load_bias = 0;
    }
    lifecycle = .running;
    var user_instruction = entry;
    var user_stack = stack_pointer;
    while (true) {
        address_space.activate();
        enter_user(user_instruction, user_stack);
        const pause = syscalls.takePause() orelse break;
        lifecycle = .frozen;
        pause_count += 1;
        standby_pages += try discardCleanPages(&address_space, pages, mappings[0..mapping_count], owned[0..owned_count]);
        lifecycle = .standby;
        user_instruction = pause.instruction;
        user_stack = pause.stack;
        lifecycle = .resuming;
    }
    lifecycle = .finished;
    if (syscalls.exitStatus() != 0) return error.ProcessFailed;
}

fn mapAnonymous(address_space: *paging.AddressSpace, pages: *physical.Allocator, owned: *[max_owned_ranges]OwnedRange, owned_count: *usize, virtual: u64, count: u64) !void {
    const allocation = pages.allocate(count) orelse return error.OutOfMemory;
    try own(owned, owned_count, allocation, count);
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const physical_page = allocation + index * page_size;
        const bytes: [*]u8 = @ptrFromInt(physical_page);
        @memset(bytes[0..page_size], 0);
        try address_space.mapUserPage(virtual + index * page_size, physical_page, true);
    }
}

fn buildInitialStack(
    physical_base: u64,
    size: u64,
    entry: u64,
    load_bias: u64,
    program_offset: u64,
    program_entry_size: u16,
    program_count: u16,
    arguments: []const []const u8,
) !u64 {
    const bytes: [*]u8 = @ptrFromInt(physical_base);
    @memset(bytes[0..@intCast(size)], 0);
    var offset: usize = @intCast(size);
    var argument_pointers: [16]u64 = undefined;
    if (arguments.len > argument_pointers.len) return error.TooManyArguments;
    var reverse = arguments.len;
    while (reverse > 0) {
        reverse -= 1;
        const argument = arguments[reverse];
        offset -= argument.len + 1;
        @memcpy(bytes[offset .. offset + argument.len], argument);
        bytes[offset + argument.len] = 0;
        argument_pointers[reverse] = stack_address + offset;
    }
    offset -= 16;
    const random_pointer = stack_address + offset;
    var random_index: usize = 0;
    while (random_index < 16) : (random_index += 1) bytes[offset + random_index] = @truncate(0x41 + random_index);

    var phdr_address: u64 = 0;
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 1) continue;
        const file_offset = read64At(header + 8);
        const virtual = read64At(header + 16);
        const file_size = read64At(header + 32);
        if (program_offset >= file_offset and program_offset < file_offset + file_size) {
            phdr_address = virtual + load_bias + program_offset - file_offset;
        }
    }
    if (phdr_address == 0) return error.InvalidElf;

    const auxv = [_][2]u64{
        .{ 3, phdr_address },
        .{ 4, program_entry_size },
        .{ 5, program_count },
        .{ 6, page_size },
        .{ 9, entry },
        .{ 11, 0 }, .{ 12, 0 }, .{ 13, 0 }, .{ 14, 0 },
        .{ 23, 0 },
        .{ 25, random_pointer },
        .{ 31, argument_pointers[0] },
        .{ 0, 0 },
    };
    const word_count = 1 + arguments.len + 1 + 1 + auxv.len * 2;
    offset &= ~@as(usize, 15);
    if (((offset - word_count * 8) & 15) != 0) offset -= 8;
    var aux_index = auxv.len;
    while (aux_index > 0) {
        aux_index -= 1;
        push(bytes, &offset, auxv[aux_index][1]);
        push(bytes, &offset, auxv[aux_index][0]);
    }
    push(bytes, &offset, 0);
    push(bytes, &offset, 0);
    reverse = arguments.len;
    while (reverse > 0) {
        reverse -= 1;
        push(bytes, &offset, argument_pointers[reverse]);
    }
    push(bytes, &offset, arguments.len);
    return stack_address + offset;
}

fn push(bytes: [*]u8, offset: *usize, value: u64) void {
    offset.* -= 8;
    var index: usize = 0;
    while (index < 8) : (index += 1) bytes[offset.* + index] = @truncate(value >> @intCast(index * 8));
}

fn loadSegment(
    address_space: *paging.AddressSpace,
    pages: *physical.Allocator,
    mappings: *[max_mappings]Mapping,
    mapping_count: *usize,
    owned: *[max_owned_ranges]OwnedRange,
    owned_count: *usize,
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
            const owner_index = owned_count.*;
            try own(owned, owned_count, physical_address.?, 1);
            const bytes: [*]u8 = @ptrFromInt(physical_address.?);
            @memset(bytes[0..page_size], 0);
            try address_space.mapUserPage(page_virtual, physical_address.?, writable);
            mappings[mapping_count.*] = .{
                .virtual = page_virtual,
                .physical = physical_address.?,
                .owner_index = owner_index,
                .writable = writable,
            };
            mapping_count.* += 1;
        } else if (writable) {
            for (mappings[0..mapping_count.*]) |*mapping| {
                if (mapping.virtual == page_virtual) mapping.writable = true;
            }
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

fn discardCleanPages(address_space: *paging.AddressSpace, pages: *physical.Allocator, mappings: []Mapping, owned: []OwnedRange) !u64 {
    var discarded: u64 = 0;
    for (mappings) |*mapping| {
        if (mapping.writable or !mapping.resident) continue;
        const physical_address = address_space.unmapUserPage(mapping.virtual) orelse return error.MappingMissing;
        if (physical_address != mapping.physical) return error.MappingMismatch;
        try pages.release(physical_address, 1);
        owned[mapping.owner_index] = .{ .address = 0, .pages = 0 };
        mapping.physical = 0;
        mapping.resident = false;
        discarded += 1;
    }
    return discarded;
}

pub fn handlePageFault(address: u64, instruction: u64, code: u64) callconv(.c) bool {
    _ = instruction;
    if ((code & 1) != 0) return false;
    const address_space = active_address_space orelse return false;
    const pages = active_pages orelse return false;
    const mappings = active_mappings orelse return false;
    const owned = active_owned orelse return false;
    const page_virtual = address & ~(page_size - 1);
    for (mappings) |*mapping| {
        if (mapping.virtual != page_virtual or mapping.resident or mapping.writable) continue;
        const physical_address = pages.allocate(1) orelse return false;
        const bytes: [*]u8 = @ptrFromInt(physical_address);
        @memset(bytes[0..page_size], 0);
        restoreFilePage(page_virtual, physical_address);
        address_space.mapUserPage(page_virtual, physical_address, false) catch {
            pages.release(physical_address, 1) catch {};
            return false;
        };
        mapping.physical = physical_address;
        mapping.resident = true;
        owned[mapping.owner_index] = .{ .address = physical_address, .pages = 1 };
        restored_pages += 1;
        return true;
    }
    return false;
}

fn restoreFilePage(page_virtual: u64, physical_address: u64) void {
    const program_offset = read64(32);
    const program_entry_size = read16(54);
    const program_count = read16(56);
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 1) continue;
        const file_offset = read64At(header + 8);
        const virtual = read64At(header + 16) + active_load_bias;
        const file_size = read64At(header + 32);
        const copy_start = @max(page_virtual, virtual);
        const copy_end = @min(page_virtual + page_size, virtual + file_size);
        if (copy_start >= copy_end) continue;
        const destination: [*]u8 = @ptrFromInt(physical_address + copy_start - page_virtual);
        const source: usize = @intCast(file_offset + copy_start - virtual);
        const length: usize = @intCast(copy_end - copy_start);
        @memcpy(destination[0..length], image[source .. source + length]);
    }
}

fn own(ranges: *[max_owned_ranges]OwnedRange, count: *usize, address: u64, pages: u64) !void {
    if (count.* == ranges.len) return error.TooManyOwnedRanges;
    ranges[count.*] = .{ .address = address, .pages = pages };
    count.* += 1;
}

fn releaseOwned(allocator: *physical.Allocator, ranges: []const OwnedRange) void {
    var index = ranges.len;
    while (index > 0) {
        index -= 1;
        if (ranges[index].pages == 0) continue;
        allocator.release(ranges[index].address, ranges[index].pages) catch unreachable;
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
