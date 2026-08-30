const paging = @import("paging");
const physical = @import("physical");
const syscalls = @import("syscalls");
const vfs = @import("vfs");
const busybox_image = @embedFile("busybox_elf");
const nettest_image = @embedFile("nettest_elf");
const hello_image = @embedFile("hello_elf");
const interpreter_image = @embedFile("interpreter_elf");
const dynamic_image = @embedFile("dynamic_elf");
var image: []const u8 = busybox_image;
const stack_address: u64 = 0x0000009000000000;
const mmap_address: u64 = 0x000000a000000000;
const page_size: u64 = 4096;
const max_mappings = 512;
const max_owned_ranges = 512;
const max_shared_objects = 4;

const Mapping = struct {
    virtual: u64,
    physical: u64,
    owner_index: usize,
    writable: bool,
    executable: bool,
    resident: bool = true,
};
const OwnedRange = struct { address: u64, pages: u64 };
const Provider = struct {
    bytes: []const u8,
    program_offset: u64,
    program_entry_size: u16,
    program_count: u16,
    base: u64,
};
const NeededList = struct {
    names: [max_shared_objects][]const u8 = undefined,
    count: usize = 0,
};

var active_address_space: ?*paging.AddressSpace = null;
var active_pages: ?*physical.Allocator = null;
var active_mappings: ?[]Mapping = null;
var active_owned: ?[]OwnedRange = null;
var active_load_bias: u64 = 0;
pub var standby_pages: u64 = 0;
pub var restored_pages: u64 = 0;
pub var pause_count: u64 = 0;
pub var relative_relocations: u64 = 0;
pub var interpreter_loads: u64 = 0;
pub var shared_objects_loaded: u64 = 0;
pub var symbol_relocations: u64 = 0;
pub var data_symbol_relocations: u64 = 0;
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

pub fn runDynamicTest(kernel_root: u64, pages: *physical.Allocator) !void {
    image = dynamic_image;
    const arguments = [_][]const u8{"/bin/dynamic-hello"};
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
    const program_image = image;
    const interpreter_path = try findInterpreter(program_offset, program_entry_size, program_count);
    const needed = try findNeeded(program_offset, program_entry_size, program_count);

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
        try loadSegment(&address_space, pages, &mappings, &mapping_count, &owned, &owned_count, virtual, file_offset, file_size, memory_size, (flags & 2) != 0, (flags & 1) != 0);
    }
    if (mapping_count == 0 or entry < image_start or entry >= image_end) return error.InvalidElf;
    try applyRelativeRelocations(mappings[0..mapping_count], load_bias, program_offset, program_entry_size, program_count, interpreter_path != null);
    var execution_entry = entry;
    var interpreter_base: u64 = 0;
    if (interpreter_path) |path| {
        if (!equal(path, "/lib/ld-csos.so")) return error.UnsupportedInterpreter;
        if (needed.count == 0) return error.SharedObjectMissing;
        var dependency_ranges: [max_shared_objects]OwnedRange = undefined;
        var dependency_count: usize = 0;
        defer releaseOwned(pages, dependency_ranges[0..dependency_count]);
        var providers: [max_shared_objects]Provider = undefined;
        var provider_count: usize = 0;
        var dependency_names: [max_shared_objects][]const u8 = undefined;
        var dependency_name_count = needed.count;
        @memcpy(dependency_names[0..needed.count], needed.names[0..needed.count]);
        while (provider_count < dependency_name_count) {
            const dependency = dependency_names[provider_count];
            const dependency_info = try vfs.infoAt(-100, dependency);
            if (dependency_info.directory or dependency_info.size < 64 or dependency_info.size > 16 * 1024 * 1024) return error.InvalidSharedObject;
            const dependency_pages = (dependency_info.size + page_size - 1) / page_size;
            const dependency_address = pages.allocate(dependency_pages) orelse return error.OutOfMemory;
            dependency_ranges[dependency_count] = .{ .address = dependency_address, .pages = dependency_pages };
            dependency_count += 1;
            const dependency_bytes: [*]u8 = @ptrFromInt(dependency_address);
            const dependency_file = try vfs.openAt(-100, dependency, 0);
            var dependency_read: usize = 0;
            while (dependency_read < dependency_info.size) {
                const count = vfs.pread(dependency_file, dependency_bytes[dependency_read..@intCast(dependency_info.size)], dependency_read) catch |err| {
                    vfs.close(dependency_file) catch {};
                    return err;
                };
                if (count == 0) return error.TruncatedSharedObject;
                dependency_read += count;
            }
            try vfs.close(dependency_file);
            const shared_bytes = dependency_bytes[0..@intCast(dependency_info.size)];
            const shared_base = 0x0000006000000000 + @as(u64, provider_count) * 0x0000000010000000;
            image = shared_bytes;
            if (image.len < 64 or !isElf() or read16(16) != 3) return error.InvalidSharedObject;
            const shared_program_offset = read64(32);
            const shared_program_entry_size = read16(54);
            const shared_program_count = read16(56);
            header_index = 0;
            while (header_index < shared_program_count) : (header_index += 1) {
                const header: usize = @intCast(shared_program_offset + @as(u64, shared_program_entry_size) * header_index);
                if (read32At(header) != 1) continue;
                const flags = read32At(header + 4);
                const file_offset = read64At(header + 8);
                const virtual = read64At(header + 16) + shared_base;
                const file_size = read64At(header + 32);
                const memory_size = read64At(header + 40);
                if (file_size > memory_size or file_offset + file_size > image.len or memory_size == 0) return error.InvalidSharedObject;
                try loadSegment(&address_space, pages, &mappings, &mapping_count, &owned, &owned_count, virtual, file_offset, file_size, memory_size, (flags & 2) != 0, (flags & 1) != 0);
            }
            try applyRelativeRelocations(mappings[0..mapping_count], shared_base, shared_program_offset, shared_program_entry_size, shared_program_count, true);
            providers[provider_count] = .{
                .bytes = shared_bytes,
                .program_offset = shared_program_offset,
                .program_entry_size = shared_program_entry_size,
                .program_count = shared_program_count,
                .base = shared_base,
            };
            const transitive = try findNeeded(shared_program_offset, shared_program_entry_size, shared_program_count);
            for (transitive.names[0..transitive.count]) |name| {
                var duplicate = false;
                for (dependency_names[0..dependency_name_count]) |existing| {
                    if (equal(name, existing)) duplicate = true;
                }
                if (duplicate) continue;
                if (dependency_name_count == dependency_names.len) return error.TooManyDependencies;
                dependency_names[dependency_name_count] = name;
                dependency_name_count += 1;
            }
            provider_count += 1;
            shared_objects_loaded += 1;
        }
        try applySymbolRelocations(program_image, program_offset, program_entry_size, program_count, load_bias, providers[0..provider_count], mappings[0..mapping_count]);
        for (providers[0..provider_count]) |provider| {
            try applySymbolRelocations(provider.bytes, provider.program_offset, provider.program_entry_size, provider.program_count, provider.base, providers[0..provider_count], mappings[0..mapping_count]);
        }
        image = interpreter_image;
        if (image.len < 64 or !isElf() or read16(16) != 3) return error.InvalidInterpreter;
        const interpreter_program_offset = read64(32);
        const interpreter_program_entry_size = read16(54);
        const interpreter_program_count = read16(56);
        if (interpreter_program_entry_size < 56 or interpreter_program_offset + @as(u64, interpreter_program_entry_size) * interpreter_program_count > image.len)
            return error.InvalidInterpreter;
        interpreter_base = 0x0000007000000000;
        execution_entry = read64(24) + interpreter_base;
        header_index = 0;
        while (header_index < interpreter_program_count) : (header_index += 1) {
            const header: usize = @intCast(interpreter_program_offset + @as(u64, interpreter_program_entry_size) * header_index);
            if (read32At(header) != 1) continue;
            const flags = read32At(header + 4);
            const file_offset = read64At(header + 8);
            const virtual = read64At(header + 16) + interpreter_base;
            const file_size = read64At(header + 32);
            const memory_size = read64At(header + 40);
            if (file_size > memory_size or file_offset + file_size > image.len or memory_size == 0) return error.InvalidInterpreter;
            image_start = @min(image_start, virtual);
            image_end = @max(image_end, virtual + memory_size);
            try loadSegment(&address_space, pages, &mappings, &mapping_count, &owned, &owned_count, virtual, file_offset, file_size, memory_size, (flags & 2) != 0, (flags & 1) != 0);
        }
        try applyRelativeRelocations(mappings[0..mapping_count], interpreter_base, interpreter_program_offset, interpreter_program_entry_size, interpreter_program_count, false);
        interpreter_loads += 1;
        image = program_image;
    }

    const stack_page_count = 8;
    const initial_stack_size = 4 * page_size;
    const stack_pages = pages.allocate(stack_page_count) orelse return error.OutOfMemory;
    try own(&owned, &owned_count, stack_pages, stack_page_count);
    var stack_page: u64 = 0;
    while (stack_page < stack_page_count) : (stack_page += 1) {
        try address_space.mapUserPage(stack_address + stack_page * page_size, stack_pages + stack_page * page_size, true, false);
    }
    const entry_permissions = address_space.userPermissions(execution_entry) orelse return error.EntryNotMapped;
    const stack_permissions = address_space.userPermissions(stack_address) orelse return error.StackNotMapped;
    if (!entry_permissions.executable or entry_permissions.writable) return error.InvalidEntryPermissions;
    if (stack_permissions.executable or !stack_permissions.writable) return error.InvalidStackPermissions;
    const break_base = (image_end + page_size - 1) & ~(page_size - 1);
    const arena_pages = 64;
    try mapAnonymous(&address_space, pages, &owned, &owned_count, break_base, arena_pages);
    try mapAnonymous(&address_space, pages, &owned, &owned_count, mmap_address, arena_pages);
    const stack_pointer = try buildInitialStack(stack_pages, initial_stack_size, entry, interpreter_base, load_bias, program_offset, program_entry_size, program_count, arguments);
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
    syscalls.configureMmap(&protectMmap, &unmapMmap);
    defer {
        active_address_space = null;
        active_pages = null;
        active_mappings = null;
        active_owned = null;
        active_load_bias = 0;
        syscalls.configureMmap(null, null);
    }
    lifecycle = .running;
    var user_instruction = execution_entry;
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

fn protectMmap(address: u64, length: u64, writable: bool, executable: bool) callconv(.c) bool {
    const address_space = active_address_space orelse return false;
    var offset: u64 = 0;
    while (offset < length) : (offset += page_size) {
        if (!address_space.protectUserPage(address + offset, writable, executable)) return false;
    }
    return true;
}

fn unmapMmap(address: u64, length: u64) callconv(.c) bool {
    const address_space = active_address_space orelse return false;
    var offset: u64 = 0;
    while (offset < length) : (offset += page_size) {
        if (address_space.unmapUserPage(address + offset) == null) return false;
    }
    return true;
}

fn mapAnonymous(address_space: *paging.AddressSpace, pages: *physical.Allocator, owned: *[max_owned_ranges]OwnedRange, owned_count: *usize, virtual: u64, count: u64) !void {
    const allocation = pages.allocate(count) orelse return error.OutOfMemory;
    try own(owned, owned_count, allocation, count);
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const physical_page = allocation + index * page_size;
        const bytes: [*]u8 = @ptrFromInt(physical_page);
        @memset(bytes[0..page_size], 0);
        try address_space.mapUserPage(virtual + index * page_size, physical_page, true, false);
    }
}

fn buildInitialStack(
    physical_base: u64,
    size: u64,
    entry: u64,
    interpreter_base: u64,
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
        .{ 7, interpreter_base },
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

fn findInterpreter(program_offset: u64, program_entry_size: u16, program_count: u16) !?[]const u8 {
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 3) continue;
        const offset = read64At(header + 8);
        const size = read64At(header + 32);
        if (size < 2 or offset > image.len or size > image.len - offset) return error.InvalidInterpreterPath;
        const path = image[@intCast(offset)..@intCast(offset + size - 1)];
        if (image[@intCast(offset + size - 1)] != 0) return error.InvalidInterpreterPath;
        return path;
    }
    return null;
}

fn findNeeded(program_offset: u64, program_entry_size: u16, program_count: u16) !NeededList {
    var dynamic_offset: ?u64 = null;
    var dynamic_size: u64 = 0;
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 2) continue;
        dynamic_offset = read64At(header + 8);
        dynamic_size = read64At(header + 32);
        break;
    }
    const table = dynamic_offset orelse return .{};
    if (table > image.len or dynamic_size > image.len - table) return error.InvalidDynamicTable;
    var string_virtual: u64 = 0;
    var needed_offsets: [max_shared_objects]u64 = undefined;
    var needed_count: usize = 0;
    var offset = table;
    while (offset + 16 <= table + dynamic_size) : (offset += 16) {
        const tag = read64At(@intCast(offset));
        const value = read64At(@intCast(offset + 8));
        if (tag == 0) break;
        if (tag == 5) string_virtual = value;
        if (tag == 1) {
            if (needed_count == needed_offsets.len) return error.TooManyDependencies;
            needed_offsets[needed_count] = value;
            needed_count += 1;
        }
    }
    if (needed_count == 0) return .{};
    if (string_virtual == 0) return error.InvalidDynamicString;
    var result = NeededList{};
    for (needed_offsets[0..needed_count]) |name_offset| {
        const string_file = try virtualFileOffset(string_virtual + name_offset, 1, program_offset, program_entry_size, program_count);
        result.names[result.count] = try stringFrom(image, string_file);
        result.count += 1;
    }
    return result;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
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
    executable: bool,
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
            try address_space.mapUserPage(page_virtual, physical_address.?, writable, executable);
            mappings[mapping_count.*] = .{
                .virtual = page_virtual,
                .physical = physical_address.?,
                .owner_index = owner_index,
                .writable = writable,
                .executable = executable,
            };
            mapping_count.* += 1;
        } else if (writable) {
            for (mappings[0..mapping_count.*]) |*mapping| {
                if (mapping.virtual == page_virtual) mapping.writable = true;
            }
        } else if (executable) {
            for (mappings[0..mapping_count.*]) |*mapping| {
                if (mapping.virtual == page_virtual) mapping.executable = true;
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

fn applyRelativeRelocations(mappings: []const Mapping, load_bias: u64, program_offset: u64, program_entry_size: u16, program_count: u16, allow_unresolved: bool) !void {
    var dynamic_offset: ?u64 = null;
    var dynamic_size: u64 = 0;
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 2) continue;
        dynamic_offset = read64At(header + 8);
        dynamic_size = read64At(header + 32);
        break;
    }
    const table_offset = dynamic_offset orelse return;
    if (table_offset > image.len or dynamic_size > image.len - table_offset) return error.InvalidDynamicTable;
    var rela_virtual: u64 = 0;
    var rela_size: u64 = 0;
    var rela_entry_size: u64 = 24;
    var offset = table_offset;
    while (offset + 16 <= table_offset + dynamic_size) : (offset += 16) {
        const tag = read64At(@intCast(offset));
        const value = read64At(@intCast(offset + 8));
        if (tag == 0) break;
        switch (tag) {
            7 => rela_virtual = value,
            8 => rela_size = value,
            9 => rela_entry_size = value,
            else => {},
        }
    }
    if (rela_size == 0) return;
    if (rela_virtual == 0 or rela_entry_size != 24 or rela_size % rela_entry_size != 0) return error.InvalidRelaTable;
    const rela_file = try virtualFileOffset(rela_virtual, rela_size, program_offset, program_entry_size, program_count);
    var rela_offset: u64 = 0;
    while (rela_offset < rela_size) : (rela_offset += rela_entry_size) {
        const item: usize = @intCast(rela_file + rela_offset);
        const target = read64At(item) + load_bias;
        const info = read64At(item + 8);
        const addend: i64 = @bitCast(read64At(item + 16));
        if (@as(u32, @truncate(info)) != 8 or (info >> 32) != 0) {
            if (allow_unresolved) continue;
            return error.UnsupportedRelocation;
        }
        try writeMapped64(mappings, target, load_bias +% @as(u64, @bitCast(addend)));
        relative_relocations += 1;
    }
}

const DynamicSymbols = struct {
    symbol_file: u64,
    string_file: u64,
    symbol_count: u32,
    regular_rela_file: u64 = 0,
    regular_rela_size: u64 = 0,
    plt_rela_file: u64 = 0,
    plt_rela_size: u64 = 0,
};

fn applySymbolRelocations(
    consumer: []const u8,
    consumer_program_offset: u64,
    consumer_program_entry_size: u16,
    consumer_program_count: u16,
    consumer_base: u64,
    providers: []const Provider,
    mappings: []const Mapping,
) !void {
    const wanted = try dynamicSymbols(consumer, consumer_program_offset, consumer_program_entry_size, consumer_program_count, true);
    try applySymbolTable(consumer, consumer_base, wanted, providers, mappings, wanted.regular_rela_file, wanted.regular_rela_size);
    try applySymbolTable(consumer, consumer_base, wanted, providers, mappings, wanted.plt_rela_file, wanted.plt_rela_size);
}

fn applySymbolTable(consumer: []const u8, consumer_base: u64, wanted: DynamicSymbols, providers: []const Provider, mappings: []const Mapping, rela_file: u64, rela_size: u64) !void {
    if (rela_size == 0) return;
    var offset: u64 = 0;
    while (offset < rela_size) : (offset += 24) {
        const item: usize = @intCast(rela_file + offset);
        const target = read64From(consumer, item) + consumer_base;
        const info = read64From(consumer, item + 8);
        const relocation_type: u32 = @truncate(info);
        if (relocation_type == 8 and (info >> 32) == 0) continue;
        if (relocation_type != 1 and relocation_type != 6 and relocation_type != 7) return error.UnsupportedSymbolRelocation;
        const symbol_index: u32 = @truncate(info >> 32);
        const consumer_symbol: usize = @intCast(wanted.symbol_file + @as(u64, symbol_index) * 24);
        const name_offset = read32From(consumer, consumer_symbol);
        const name = try stringFrom(consumer, wanted.string_file + name_offset);
        var resolved: ?u64 = null;
        for (providers) |provider| {
            const supplied = try dynamicSymbols(provider.bytes, provider.program_offset, provider.program_entry_size, provider.program_count, false);
            var provider_index: u32 = 0;
            while (provider_index < supplied.symbol_count) : (provider_index += 1) {
                const provider_symbol: usize = @intCast(supplied.symbol_file + @as(u64, provider_index) * 24);
                if (read16From(provider.bytes, provider_symbol + 6) == 0) continue;
                const provider_name_offset = read32From(provider.bytes, provider_symbol);
                const provider_name = try stringFrom(provider.bytes, supplied.string_file + provider_name_offset);
                if (equal(name, provider_name)) {
                    resolved = provider.base + read64From(provider.bytes, provider_symbol + 8);
                    break;
                }
            }
            if (resolved != null) break;
        }
        if (resolved == null and (consumer[consumer_symbol + 4] >> 4) == 2) resolved = 0;
        const symbol_value = resolved orelse return error.DynamicSymbolMissing;
        const addend: i64 = @bitCast(read64From(consumer, item + 16));
        const value = if (relocation_type == 1) symbol_value +% @as(u64, @bitCast(addend)) else symbol_value;
        try writeMapped64(mappings, target, value);
        symbol_relocations += 1;
        if (relocation_type == 1 or relocation_type == 6) data_symbol_relocations += 1;
    }
}

fn dynamicSymbols(bytes: []const u8, program_offset: u64, program_entry_size: u16, program_count: u16, consumer: bool) !DynamicSymbols {
    var dynamic_file: ?u64 = null;
    var dynamic_size: u64 = 0;
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32From(bytes, header) != 2) continue;
        dynamic_file = read64From(bytes, header + 8);
        dynamic_size = read64From(bytes, header + 32);
        break;
    }
    const table = dynamic_file orelse return error.DynamicTableMissing;
    var symbol_virtual: u64 = 0;
    var string_virtual: u64 = 0;
    var hash_virtual: u64 = 0;
    var rela_virtual: u64 = 0;
    var rela_size: u64 = 0;
    var plt_rela_virtual: u64 = 0;
    var plt_rela_size: u64 = 0;
    var offset = table;
    while (offset + 16 <= table + dynamic_size) : (offset += 16) {
        const tag = read64From(bytes, @intCast(offset));
        const value = read64From(bytes, @intCast(offset + 8));
        if (tag == 0) break;
        switch (tag) {
            4 => hash_virtual = value,
            5 => string_virtual = value,
            6 => symbol_virtual = value,
            7 => { if (consumer) rela_virtual = value; },
            8 => { if (consumer) rela_size = value; },
            23 => { if (consumer) plt_rela_virtual = value; },
            2 => { if (consumer) plt_rela_size = value; },
            else => {},
        }
    }
    if (symbol_virtual == 0 or string_virtual == 0 or hash_virtual == 0) return error.InvalidDynamicSymbols;
    const hash_file = try virtualFileOffsetFor(bytes, hash_virtual, 8, program_offset, program_entry_size, program_count);
    return .{
        .symbol_file = try virtualFileOffsetFor(bytes, symbol_virtual, 24, program_offset, program_entry_size, program_count),
        .string_file = try virtualFileOffsetFor(bytes, string_virtual, 1, program_offset, program_entry_size, program_count),
        .symbol_count = read32From(bytes, @intCast(hash_file + 4)),
        .regular_rela_file = if (rela_size == 0) 0 else try virtualFileOffsetFor(bytes, rela_virtual, rela_size, program_offset, program_entry_size, program_count),
        .regular_rela_size = rela_size,
        .plt_rela_file = if (plt_rela_size == 0) 0 else try virtualFileOffsetFor(bytes, plt_rela_virtual, plt_rela_size, program_offset, program_entry_size, program_count),
        .plt_rela_size = plt_rela_size,
    };
}

fn virtualFileOffsetFor(bytes: []const u8, virtual: u64, size: u64, program_offset: u64, program_entry_size: u16, program_count: u16) !u64 {
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32From(bytes, header) != 1) continue;
        const file_offset = read64From(bytes, header + 8);
        const segment_virtual = read64From(bytes, header + 16);
        const file_size = read64From(bytes, header + 32);
        if (virtual >= segment_virtual and size <= file_size and virtual - segment_virtual <= file_size - size)
            return file_offset + virtual - segment_virtual;
    }
    return error.InvalidDynamicAddress;
}

fn stringFrom(bytes: []const u8, raw_offset: u64) ![]const u8 {
    const start: usize = @intCast(raw_offset);
    if (start >= bytes.len) return error.InvalidDynamicString;
    var end = start;
    while (end < bytes.len and bytes[end] != 0) : (end += 1) {}
    if (end == bytes.len) return error.InvalidDynamicString;
    return bytes[start..end];
}

fn read16From(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32From(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16From(bytes, offset)) | (@as(u32, read16From(bytes, offset + 2)) << 16);
}

fn read64From(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32From(bytes, offset)) | (@as(u64, read32From(bytes, offset + 4)) << 32);
}

fn virtualFileOffset(virtual: u64, size: u64, program_offset: u64, program_entry_size: u16, program_count: u16) !u64 {
    var header_index: usize = 0;
    while (header_index < program_count) : (header_index += 1) {
        const header: usize = @intCast(program_offset + @as(u64, program_entry_size) * header_index);
        if (read32At(header) != 1) continue;
        const file_offset = read64At(header + 8);
        const segment_virtual = read64At(header + 16);
        const file_size = read64At(header + 32);
        if (virtual >= segment_virtual and size <= file_size and virtual - segment_virtual <= file_size - size)
            return file_offset + virtual - segment_virtual;
    }
    return error.InvalidDynamicAddress;
}

fn writeMapped64(mappings: []const Mapping, virtual: u64, value: u64) !void {
    const page_virtual = virtual & ~(page_size - 1);
    const offset = virtual - page_virtual;
    if (offset > page_size - 8) return error.CrossPageRelocation;
    for (mappings) |mapping| {
        if (mapping.virtual != page_virtual or !mapping.resident) continue;
        const target: *align(1) u64 = @ptrFromInt(mapping.physical + offset);
        target.* = value;
        return;
    }
    return error.RelocationTargetMissing;
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
        address_space.mapUserPage(page_virtual, physical_address, false, mapping.executable) catch {
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
