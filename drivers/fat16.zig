const std = @import("std");
const nvme = @import("nvme");
const physical = @import("physical");

pub const Volume = struct {
    storage: *nvme.Controller,
    buffer: u64,
    sectors_per_cluster: u8,
    fat_start: u32,
    fat_sectors: u16,
    fat_count: u8,
    root_start: u32,
    root_sectors: u32,
    data_start: u32,
    cluster_count: u32,

    pub const DirectoryEntry = struct {
        name: [11]u8,
        size: u32,
        first_cluster: u16 = 0,
        directory: bool = false,
    };

    pub fn mount(storage: *nvme.Controller, pages: *physical.Allocator) !Volume {
        if (storage.block_size != 512) return error.UnsupportedSectorSize;
        const buffer = pages.allocate(1) orelse return error.OutOfMemory;
        errdefer pages.release(buffer, 1) catch {};
        try storage.readBlock(0, buffer);
        const boot: [*]const u8 = @ptrFromInt(buffer);
        const layout = try parseBootSector(boot, storage.block_count);
        return .{
            .storage = storage,
            .buffer = buffer,
            .sectors_per_cluster = layout.sectors_per_cluster,
            .fat_start = layout.fat_start,
            .fat_sectors = layout.fat_sectors,
            .fat_count = layout.fat_count,
            .root_start = layout.root_start,
            .root_sectors = layout.root_sectors,
            .data_start = layout.data_start,
            .cluster_count = layout.cluster_count,
        };
    }

    pub fn readRootFile(self: *Volume, name: *const [11]u8, output: []u8) !usize {
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if (!entryIsRegularFile(bytes + offset)) continue;
                if (!equal11(bytes + offset, name)) continue;
                var cluster = get16(bytes + offset + 26);
                const size = get32(bytes + offset + 28);
                if (size > output.len) return error.UnsupportedFile;
                if (size == 0) return 0;
                try validateDataCluster(cluster, self.cluster_count);
                var copied: usize = 0;
                var traversed: u32 = 0;
                while (copied < size) {
                    if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
                    traversed += 1;
                    var cluster_sector: u32 = 0;
                    while (cluster_sector < self.sectors_per_cluster and copied < size) : (cluster_sector += 1) {
                        try self.storage.readBlock(self.clusterLba(cluster) + cluster_sector, self.buffer);
                        const count = @min(@as(usize, size) - copied, 512);
                        const source: [*]const u8 = @ptrFromInt(self.buffer);
                        @memcpy(output[copied .. copied + count], source[0..count]);
                        copied += count;
                    }
                    if (copied < size) {
                        cluster = try self.fatEntry(cluster);
                        if (cluster >= 0xfff8) return error.BrokenChain;
                        try validateDataCluster(cluster, self.cluster_count);
                    }
                }
                return copied;
            }
        }
        return error.NotFound;
    }

    pub fn fileSize(self: *Volume, name: *const [11]u8) !usize {
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if (entryIsRegularFile(bytes + offset) and equal11(bytes + offset, name))
                    return get32(bytes + offset + 28);
            }
        }
        return error.NotFound;
    }

    pub fn listRootFiles(self: *Volume, output: []DirectoryEntry) !usize {
        var count: usize = 0;
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            const result = collectRootEntries(bytes, output, count);
            count = result.count;
            if (result.end_of_directory or count == output.len) break;
        }
        return count;
    }

    /// Enumerate both regular files and subdirectory entries in the FAT16 root.
    /// Long-name entries, volume labels, deleted entries and the end marker are
    /// skipped. The fixed FAT16 root remains bounded by `root_sectors`.
    pub fn listRootEntries(self: *Volume, output: []DirectoryEntry) !usize {
        var count: usize = 0;
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            const result = collectRootEntriesAll(bytes, output, count);
            count = result.count;
            if (result.end_of_directory or count == output.len) break;
        }
        return count;
    }

    /// Enumerate entries from a subdirectory cluster chain.
    /// FAT16 directories use the same 32-byte entry format as the root, but
    /// occupy normal data clusters and therefore may span multiple clusters.
    pub fn listDirectory(self: *Volume, first_cluster: u16, output: []DirectoryEntry) !usize {
        try validateDataCluster(first_cluster, self.cluster_count);
        var cluster = first_cluster;
        var traversed: u32 = 0;
        var count: usize = 0;
        while (true) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            var sector: u8 = 0;
            while (sector < self.sectors_per_cluster) : (sector += 1) {
                try self.storage.readBlock(self.clusterLba(cluster) + sector, self.buffer);
                const bytes: [*]const u8 = @ptrFromInt(self.buffer);
                const result = collectRootEntriesAll(bytes, output, count);
                count = result.count;
                if (result.end_of_directory or count == output.len) return count;
            }
            const next = try self.fatEntry(cluster);
            if (next >= 0xfff8) return count;
            try validateDataCluster(next, self.cluster_count);
            cluster = next;
        }
    }

    pub fn findRootEntry(self: *Volume, name: *const [11]u8) !DirectoryEntry {
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if ((!entryIsRegularFile(bytes + offset) and !entryIsDirectory(bytes + offset)) or
                    !equal11(bytes + offset, name)) continue;
                var result = DirectoryEntry{ .name = undefined, .size = get32(bytes + offset + 28) };
                @memcpy(&result.name, bytes[offset .. offset + 11]);
                result.first_cluster = get16(bytes + offset + 26);
                result.directory = entryIsDirectory(bytes + offset);
                return result;
            }
        }
        return error.NotFound;
    }

    pub fn findDirectoryEntry(self: *Volume, first_cluster: u16, name: *const [11]u8) !DirectoryEntry {
        try validateDataCluster(first_cluster, self.cluster_count);
        var cluster = first_cluster;
        var traversed: u32 = 0;
        while (true) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            var sector: u8 = 0;
            while (sector < self.sectors_per_cluster) : (sector += 1) {
                try self.storage.readBlock(self.clusterLba(cluster) + sector, self.buffer);
                const bytes: [*]const u8 = @ptrFromInt(self.buffer);
                var offset: usize = 0;
                while (offset < 512) : (offset += 32) {
                    if (bytes[offset] == 0) return error.NotFound;
                    if ((!entryIsRegularFile(bytes + offset) and !entryIsDirectory(bytes + offset)) or
                        !equal11(bytes + offset, name)) continue;
                    var result = DirectoryEntry{ .name = undefined, .size = get32(bytes + offset + 28) };
                    @memcpy(&result.name, bytes[offset .. offset + 11]);
                    result.first_cluster = get16(bytes + offset + 26);
                    result.directory = entryIsDirectory(bytes + offset);
                    return result;
                }
            }
            const next = try self.fatEntry(cluster);
            if (next >= 0xfff8) return error.NotFound;
            try validateDataCluster(next, self.cluster_count);
            cluster = next;
        }
    }

    pub fn readDirectoryFileAt(self: *Volume, directory_cluster: u16, name: *const [11]u8, output: []u8, file_offset: usize) !usize {
        const entry = try self.findDirectoryEntry(directory_cluster, name);
        if (entry.directory) return error.IsDirectory;
        const size: usize = entry.size;
        if (file_offset >= size or output.len == 0) return 0;
        try validateDataCluster(entry.first_cluster, self.cluster_count);
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * 512;
        var cluster = entry.first_cluster;
        var skip = file_offset / cluster_bytes;
        var traversed: u32 = 0;
        while (skip != 0) : (skip -= 1) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            cluster = try self.fatEntry(cluster);
            if (cluster >= 0xfff8) return error.BrokenChain;
            try validateDataCluster(cluster, self.cluster_count);
        }
        var within_cluster = file_offset % cluster_bytes;
        var copied: usize = 0;
        const wanted = @min(output.len, size - file_offset);
        while (copied < wanted) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            var cluster_sector: u8 = @intCast(within_cluster / 512);
            var sector_offset = within_cluster % 512;
            while (cluster_sector < self.sectors_per_cluster and copied < wanted) : (cluster_sector += 1) {
                try self.storage.readBlock(self.clusterLba(cluster) + cluster_sector, self.buffer);
                const bytes: [*]const u8 = @ptrFromInt(self.buffer);
                const count = @min(wanted - copied, 512 - sector_offset);
                @memcpy(output[copied .. copied + count], bytes[sector_offset .. sector_offset + count]);
                copied += count;
                sector_offset = 0;
            }
            within_cluster = 0;
            if (copied < wanted) {
                cluster = try self.fatEntry(cluster);
                if (cluster >= 0xfff8) return error.BrokenChain;
                try validateDataCluster(cluster, self.cluster_count);
            }
        }
        return copied;
    }

    pub fn deleteDirectoryFile(self: *Volume, directory_cluster: u16, name: *const [11]u8) !void {
        try validateDataCluster(directory_cluster, self.cluster_count);
        var cluster = directory_cluster;
        var traversed: u32 = 0;
        while (true) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            var sector: u8 = 0;
            while (sector < self.sectors_per_cluster) : (sector += 1) {
                const lba = self.clusterLba(cluster) + sector;
                try self.storage.readBlock(lba, self.buffer);
                const bytes: [*]const u8 = @ptrFromInt(self.buffer);
                var offset: usize = 0;
                while (offset < 512) : (offset += 32) {
                    if (bytes[offset] == 0) return error.NotFound;
                    if (!entryIsRegularFile(bytes + offset) or !equal11(bytes + offset, name)) continue;
                    const first_cluster = get16(bytes + offset + 26);
                    const entry: [*]u8 = @ptrFromInt(self.buffer + offset);
                    entry[0] = 0xe5;
                    try self.storage.writeBlock(lba, self.buffer);
                    if (first_cluster >= 2) try self.freeChain(first_cluster);
                    return;
                }
            }
            const next = try self.fatEntry(cluster);
            if (next >= 0xfff8) return error.NotFound;
            try validateDataCluster(next, self.cluster_count);
            cluster = next;
        }
    }

    pub fn readRootFileAt(self: *Volume, name: *const [11]u8, output: []u8, file_offset: usize) !usize {
        var first_cluster: u16 = 0;
        var size: usize = 0;
        var sector: u32 = 0;
        var found = false;
        while (sector < self.root_sectors and !found) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) break;
                if (!entryIsRegularFile(bytes + offset) or !equal11(bytes + offset, name)) continue;
                first_cluster = get16(bytes + offset + 26);
                size = get32(bytes + offset + 28);
                found = true;
                break;
            }
        }
        if (!found) return error.NotFound;
        if (file_offset >= size or output.len == 0) return 0;
        try validateDataCluster(first_cluster, self.cluster_count);
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * 512;
        var cluster = first_cluster;
        var skip = file_offset / cluster_bytes;
        var traversed: u32 = 0;
        while (skip != 0) : (skip -= 1) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            cluster = try self.fatEntry(cluster);
            if (cluster >= 0xfff8) return error.BrokenChain;
            try validateDataCluster(cluster, self.cluster_count);
        }
        var within_cluster = file_offset % cluster_bytes;
        var copied: usize = 0;
        const wanted = @min(output.len, size - file_offset);
        while (copied < wanted) {
            if (!chainTraversalAllowed(traversed, self.cluster_count)) return error.BrokenChain;
            traversed += 1;
            var cluster_sector: u32 = @intCast(within_cluster / 512);
            var sector_offset = within_cluster % 512;
            while (cluster_sector < self.sectors_per_cluster and copied < wanted) : (cluster_sector += 1) {
                try self.storage.readBlock(self.clusterLba(cluster) + cluster_sector, self.buffer);
                const bytes: [*]const u8 = @ptrFromInt(self.buffer);
                const count = @min(wanted - copied, 512 - sector_offset);
                @memcpy(output[copied .. copied + count], bytes[sector_offset .. sector_offset + count]);
                copied += count;
                sector_offset = 0;
            }
            within_cluster = 0;
            if (copied < wanted) {
                cluster = try self.fatEntry(cluster);
                if (cluster >= 0xfff8) return error.BrokenChain;
                try validateDataCluster(cluster, self.cluster_count);
            }
        }
        return copied;
    }

    pub fn writeRootFile(self: *Volume, name: *const [11]u8, data: []const u8) !void {
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * 512;
        const needed = try clustersForLength(data.len, cluster_bytes, self.cluster_count);
        var directory_sector: u32 = 0;
        var directory_offset: usize = 0;
        var old_cluster: u16 = 0;
        var found = false;
        var have_free = false;
        var sector: u32 = 0;
        while (sector < self.root_sectors and !found) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (!have_free and (bytes[offset] == 0 or bytes[offset] == 0xe5)) {
                    directory_sector = sector;
                    directory_offset = offset;
                    have_free = true;
                }
                if (entryIsRegularFile(bytes + offset) and equal11(bytes + offset, name)) {
                    directory_sector = sector;
                    directory_offset = offset;
                    old_cluster = get16(bytes + offset + 26);
                    found = true;
                    break;
                }
                if (entryIsAllocated(bytes + offset) and !entryIsLongName(bytes + offset) and equal11(bytes + offset, name)) return error.NameConflict;
                if (bytes[offset] == 0) break;
            }
        }
        if (!found and !have_free) return error.DirectoryFull;

        var first_cluster: u16 = 0;
        var previous_cluster: u16 = 0;
        var allocated: usize = 0;
        var committed = false;
        errdefer if (!committed and first_cluster != 0) self.freeChain(first_cluster) catch {};
        var search: u16 = 2;
        var written: usize = 0;
        while (allocated < needed) {
            const cluster = try self.findFree(search);
            try self.setFatEntry(cluster, 0xffff);
            if (previous_cluster != 0) {
                self.setFatEntry(previous_cluster, cluster) catch |err| {
                    self.setFatEntry(cluster, 0) catch {};
                    return err;
                };
            } else {
                first_cluster = cluster;
            }
            previous_cluster = cluster;
            allocated += 1;
            search = cluster + 1;
            var cluster_sector: u32 = 0;
            while (cluster_sector < self.sectors_per_cluster) : (cluster_sector += 1) {
                const bytes: [*]u8 = @ptrFromInt(self.buffer);
                @memset(bytes[0..512], 0);
                const count = @min(data.len - written, 512);
                if (count != 0) @memcpy(bytes[0..count], data[written .. written + count]);
                try self.storage.writeBlock(self.clusterLba(cluster) + cluster_sector, self.buffer);
                written += count;
            }
        }

        try self.storage.readBlock(self.root_start + directory_sector, self.buffer);
        const entry: [*]u8 = @ptrFromInt(self.buffer + directory_offset);
        @memset(entry[0..32], 0);
        @memcpy(entry[0..11], name);
        entry[11] = 0x20;
        put16(entry + 26, first_cluster);
        put32(entry + 28, @intCast(data.len));
        try self.storage.writeBlock(self.root_start + directory_sector, self.buffer);
        committed = true;
        if (old_cluster >= 2) try self.freeChain(old_cluster);
    }

    pub fn deleteRootFile(self: *Volume, name: *const [11]u8) !void {
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if (!entryIsRegularFile(bytes + offset) or !equal11(bytes + offset, name)) continue;
                const first_cluster = get16(bytes + offset + 26);
                try self.storage.readBlock(self.root_start + sector, self.buffer);
                const entry: [*]u8 = @ptrFromInt(self.buffer + offset);
                entry[0] = 0xe5;
                try self.storage.writeBlock(self.root_start + sector, self.buffer);
                if (first_cluster >= 2) try self.freeChain(first_cluster);
                return;
            }
        }
        return error.NotFound;
    }

    pub fn renameRootFile(self: *Volume, old_name: *const [11]u8, new_name: *const [11]u8) !void {
        var sector: u32 = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if (entryIsRegularFile(bytes + offset) and equal11(bytes + offset, new_name)) return error.AlreadyExists;
            }
        }
        sector = 0;
        while (sector < self.root_sectors) : (sector += 1) {
            try self.storage.readBlock(self.root_start + sector, self.buffer);
            const bytes: [*]const u8 = @ptrFromInt(self.buffer);
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (bytes[offset] == 0) return error.NotFound;
                if (!entryIsRegularFile(bytes + offset) or !equal11(bytes + offset, old_name)) continue;
                const entry: [*]u8 = @ptrFromInt(self.buffer + offset);
                @memcpy(entry[0..11], new_name);
                try self.storage.writeBlock(self.root_start + sector, self.buffer);
                return;
            }
        }
        return error.NotFound;
    }

    fn clusterLba(self: *const Volume, cluster: u16) u32 {
        return self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster;
    }

    fn fatEntry(self: *Volume, cluster: u16) !u16 {
        try validateDataCluster(cluster, self.cluster_count);
        const byte_offset = @as(u32, cluster) * 2;
        try self.storage.readBlock(self.fat_start + byte_offset / 512, self.buffer);
        const bytes: [*]const u8 = @ptrFromInt(self.buffer);
        return get16(bytes + byte_offset % 512);
    }

    fn setFatEntry(self: *Volume, cluster: u16, value: u16) !void {
        try validateDataCluster(cluster, self.cluster_count);
        const byte_offset = @as(u32, cluster) * 2;
        var copy: u8 = 0;
        while (copy < self.fat_count) : (copy += 1) {
            const sector = self.fat_start + @as(u32, copy) * self.fat_sectors + byte_offset / 512;
            try self.storage.readBlock(sector, self.buffer);
            const bytes: [*]u8 = @ptrFromInt(self.buffer);
            put16(bytes + byte_offset % 512, value);
            try self.storage.writeBlock(sector, self.buffer);
        }
    }

    fn findFree(self: *Volume, start: u16) !u16 {
        var cluster: u32 = start;
        while (cluster < self.cluster_count + 2 and cluster < 0xfff0) : (cluster += 1) {
            if (try self.fatEntry(@intCast(cluster)) == 0) return @intCast(cluster);
        }
        return error.DiskFull;
    }

    fn freeChain(self: *Volume, first: u16) !void {
        var cluster = first;
        var traversed: u32 = 0;
        while (cluster >= 2 and cluster < 0xfff8) {
            if (traversed >= self.cluster_count) return error.BrokenChain;
            const next = try self.fatEntry(cluster);
            try self.setFatEntry(cluster, 0);
            cluster = next;
            traversed += 1;
        }
    }
};

fn equal11(left: [*]const u8, right: *const [11]u8) bool {
    for (0..11) |index| if (left[index] != right[index]) return false;
    return true;
}

fn entryIsAllocated(entry: [*]const u8) bool {
    return entry[0] != 0 and entry[0] != 0xe5;
}

fn entryIsLongName(entry: [*]const u8) bool {
    return (entry[11] & 0x0f) == 0x0f;
}

fn entryIsRegularFile(entry: [*]const u8) bool {
    return entryIsAllocated(entry) and !entryIsLongName(entry) and (entry[11] & 0x18) == 0;
}

const CollectionResult = struct {
    count: usize,
    end_of_directory: bool,
};

fn collectRootEntries(sector: [*]const u8, output: []Volume.DirectoryEntry, initial_count: usize) CollectionResult {
    var count = initial_count;
    var offset: usize = 0;
    while (offset < 512) : (offset += 32) {
        if (sector[offset] == 0) return .{ .count = count, .end_of_directory = true };
        if (!entryIsRegularFile(sector + offset)) continue;
        if (count == output.len) return .{ .count = count, .end_of_directory = false };
        @memcpy(&output[count].name, sector[offset .. offset + 11]);
        output[count].size = get32(sector + offset + 28);
        output[count].first_cluster = get16(sector + offset + 26);
        output[count].directory = false;
        count += 1;
    }
    return .{ .count = count, .end_of_directory = false };
}

fn collectRootEntriesAll(sector: [*]const u8, output: []Volume.DirectoryEntry, initial_count: usize) CollectionResult {
    var count = initial_count;
    var offset: usize = 0;
    while (offset < 512) : (offset += 32) {
        if (sector[offset] == 0) return .{ .count = count, .end_of_directory = true };
        if (!entryIsRegularFile(sector + offset) and !entryIsDirectory(sector + offset)) continue;
        if (count == output.len) return .{ .count = count, .end_of_directory = false };
        @memcpy(&output[count].name, sector[offset .. offset + 11]);
        output[count].size = get32(sector + offset + 28);
        output[count].first_cluster = get16(sector + offset + 26);
        output[count].directory = entryIsDirectory(sector + offset);
        count += 1;
    }
    return .{ .count = count, .end_of_directory = false };
}

fn entryIsDirectory(entry: [*]const u8) bool {
    return entryIsAllocated(entry) and !entryIsLongName(entry) and (entry[11] & 0x18) == 0x10;
}

const Layout = struct {
    sectors_per_cluster: u8,
    fat_start: u32,
    fat_sectors: u16,
    fat_count: u8,
    root_start: u32,
    root_sectors: u32,
    data_start: u32,
    cluster_count: u32,
};

fn parseBootSector(boot: [*]const u8, device_blocks: u64) !Layout {
    if (boot[510] != 0x55 or boot[511] != 0xaa) return error.InvalidBootSector;
    if (get16(boot + 11) != 512) return error.UnsupportedSectorSize;

    const sectors_per_cluster = boot[13];
    const reserved = get16(boot + 14);
    const fats = boot[16];
    const root_entries = get16(boot + 17);
    const fat_sectors = get16(boot + 22);
    if (sectors_per_cluster == 0 or (sectors_per_cluster & (sectors_per_cluster - 1)) != 0) return error.InvalidBootSector;
    if (reserved == 0 or fats == 0 or root_entries == 0 or fat_sectors == 0) return error.InvalidBootSector;

    const total_sectors = if (get16(boot + 19) != 0) @as(u32, get16(boot + 19)) else get32(boot + 32);
    if (total_sectors == 0 or @as(u64, total_sectors) > device_blocks) return error.VolumeOutsideDevice;
    const fat_area = std.math.mul(u32, @as(u32, fats), fat_sectors) catch return error.InvalidBootSector;
    const root_start = std.math.add(u32, reserved, fat_area) catch return error.InvalidBootSector;
    const root_bytes = std.math.mul(u32, @as(u32, root_entries), 32) catch return error.InvalidBootSector;
    const root_sectors = (std.math.add(u32, root_bytes, 511) catch return error.InvalidBootSector) / 512;
    const data_start = std.math.add(u32, root_start, root_sectors) catch return error.InvalidBootSector;
    if (total_sectors <= data_start) return error.InvalidBootSector;
    const cluster_count = (total_sectors - data_start) / sectors_per_cluster;
    if (cluster_count < 4085 or cluster_count >= 65525) return error.NotFat16;
    if (cluster_count + 2 > @as(u32, fat_sectors) * 256) return error.FatTooSmall;

    return .{
        .sectors_per_cluster = sectors_per_cluster,
        .fat_start = reserved,
        .fat_sectors = fat_sectors,
        .fat_count = fats,
        .root_start = root_start,
        .root_sectors = root_sectors,
        .data_start = data_start,
        .cluster_count = cluster_count,
    };
}

fn validateDataCluster(cluster: u16, cluster_count: u32) !void {
    if (cluster < 2 or @as(u32, cluster) >= cluster_count + 2 or cluster >= 0xfff0) return error.BrokenChain;
}

fn chainTraversalAllowed(traversed: u32, cluster_count: u32) bool {
    return cluster_count != 0 and traversed < cluster_count;
}

fn clustersForLength(length: usize, cluster_bytes: usize, cluster_count: u32) !usize {
    if (cluster_bytes == 0) return error.InvalidClusterSize;
    if (length > std.math.maxInt(u32)) return error.FileTooLarge;
    if (length == 0) return 0;
    const needed = (length - 1) / cluster_bytes + 1;
    if (needed > cluster_count) return error.DiskFull;
    return needed;
}

fn validBootSector() [512]u8 {
    var boot = [_]u8{0} ** 512;
    put16(boot[11..].ptr, 512);
    boot[13] = 4;
    put16(boot[14..].ptr, 1);
    boot[16] = 2;
    put16(boot[17..].ptr, 512);
    put16(boot[22..].ptr, 64);
    put32(boot[32..].ptr, 32768);
    boot[510] = 0x55;
    boot[511] = 0xaa;
    return boot;
}

test "FAT16 BPB produces a bounded volume layout" {
    const boot = validBootSector();
    const layout = try parseBootSector(&boot, 32768);
    try std.testing.expectEqual(@as(u32, 129), layout.root_start);
    try std.testing.expectEqual(@as(u32, 32), layout.root_sectors);
    try std.testing.expectEqual(@as(u32, 161), layout.data_start);
    try std.testing.expectEqual(@as(u32, 8151), layout.cluster_count);
}

test "FAT16 BPB rejects invalid geometry and device overflow" {
    var boot = validBootSector();
    try std.testing.expectError(error.VolumeOutsideDevice, parseBootSector(&boot, 32767));
    boot[13] = 3;
    try std.testing.expectError(error.InvalidBootSector, parseBootSector(&boot, 32768));
    boot = validBootSector();
    put16(boot[22..].ptr, 1);
    try std.testing.expectError(error.FatTooSmall, parseBootSector(&boot, 32768));
}

test "FAT16 BPB rejects missing allocation structures" {
    var boot = validBootSector();
    boot[16] = 0;
    try std.testing.expectError(error.InvalidBootSector, parseBootSector(&boot, 32768));
    boot = validBootSector();
    put16(boot[17..].ptr, 0);
    try std.testing.expectError(error.InvalidBootSector, parseBootSector(&boot, 32768));
    boot = validBootSector();
    put16(boot[22..].ptr, 0);
    try std.testing.expectError(error.InvalidBootSector, parseBootSector(&boot, 32768));
}

test "FAT16 data cluster validation excludes reserved and out-of-volume entries" {
    try std.testing.expectError(error.BrokenChain, validateDataCluster(0, 8000));
    try std.testing.expectError(error.BrokenChain, validateDataCluster(1, 8000));
    try validateDataCluster(2, 8000);
    try validateDataCluster(8001, 8000);
    try std.testing.expectError(error.BrokenChain, validateDataCluster(8002, 8000));
    try std.testing.expectError(error.BrokenChain, validateDataCluster(0xfff0, 65524));
}

test "FAT16 chain traversal is bounded by the volume cluster count" {
    try std.testing.expect(chainTraversalAllowed(0, 1));
    try std.testing.expect(!chainTraversalAllowed(1, 1));
    try std.testing.expect(!chainTraversalAllowed(0, 0));
}

test "FAT16 file sizing is volume-bound instead of stack-bound" {
    try std.testing.expectError(error.InvalidClusterSize, clustersForLength(1, 0, 8000));
    try std.testing.expectEqual(@as(usize, 0), try clustersForLength(0, 512, 8000));
    try std.testing.expectEqual(@as(usize, 33), try clustersForLength(33 * 512, 512, 8000));
    try std.testing.expectError(error.DiskFull, clustersForLength(8001 * 512, 512, 8000));
    if (@sizeOf(usize) > 4) {
        try std.testing.expectError(error.FileTooLarge, clustersForLength(@as(usize, std.math.maxInt(u32)) + 1, 512, 65524));
    }
}

test "FAT16 entry classification excludes deleted names directories and labels" {
    var entry = [_]u8{0} ** 32;
    entry[0] = 'F';
    entry[11] = 0x20;
    try std.testing.expect(entryIsRegularFile(&entry));
    entry[0] = 0xe5;
    try std.testing.expect(!entryIsRegularFile(&entry));
    entry[0] = 'F';
    entry[11] = 0x10;
    try std.testing.expect(!entryIsRegularFile(&entry));
    entry[11] = 0x08;
    try std.testing.expect(!entryIsRegularFile(&entry));
    entry[11] = 0x0f;
    try std.testing.expect(entryIsLongName(&entry));
    try std.testing.expect(!entryIsRegularFile(&entry));
}

test "FAT16 root collection returns regular files and honors output capacity" {
    var sector = [_]u8{0} ** 512;
    @memcpy(sector[0..11], "FIRST   TXT");
    sector[11] = 0x20;
    put32(sector[28..].ptr, 12);
    @memcpy(sector[32..43], "SUBDIR     ");
    sector[43] = 0x10;
    @memcpy(sector[64..75], "SECOND  BIN");
    sector[75] = 0x20;
    put32(sector[92..].ptr, 4096);
    var entries: [2]Volume.DirectoryEntry = undefined;
    const result = collectRootEntries(&sector, &entries, 0);
    try std.testing.expect(result.end_of_directory);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualSlices(u8, "FIRST   TXT", &entries[0].name);
    try std.testing.expectEqual(@as(u32, 4096), entries[1].size);

    var one: [1]Volume.DirectoryEntry = undefined;
    const limited = collectRootEntries(&sector, &one, 0);
    try std.testing.expectEqual(@as(usize, 1), limited.count);
    try std.testing.expect(!limited.end_of_directory);
}

test "FAT16 all-entry collection exposes directories without treating labels as entries" {
    var sector = [_]u8{0} ** 512;
    @memcpy(sector[0..11], "SUBDIR     ");
    sector[11] = 0x10;
    put16(sector[26..].ptr, 7);
    @memcpy(sector[32..43], "LABEL     ");
    sector[43] = 0x08;
    @memcpy(sector[64..75], "FILE    TXT");
    sector[75] = 0x20;
    put32(sector[92..].ptr, 99);
    var entries: [2]Volume.DirectoryEntry = undefined;
    const result = collectRootEntriesAll(&sector, &entries, 0);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expect(entries[0].directory);
    try std.testing.expectEqual(@as(u16, 7), entries[0].first_cluster);
    try std.testing.expect(!entries[1].directory);
    try std.testing.expectEqual(@as(u32, 99), entries[1].size);
}

fn get16(source: [*]const u8) u16 {
    return @as(u16, source[0]) | (@as(u16, source[1]) << 8);
}
fn get32(source: [*]const u8) u32 {
    return @as(u32, get16(source)) | (@as(u32, get16(source + 2)) << 16);
}
fn put16(target: [*]u8, value: u16) void {
    target[0] = @truncate(value);
    target[1] = @truncate(value >> 8);
}
fn put32(target: [*]u8, value: u32) void {
    put16(target, @truncate(value));
    put16(target + 2, @truncate(value >> 16));
}
