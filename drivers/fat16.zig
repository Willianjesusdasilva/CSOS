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

    pub fn mount(storage: *nvme.Controller, pages: *physical.Allocator) !Volume {
        if (storage.block_size != 512) return error.UnsupportedSectorSize;
        const buffer = pages.allocate(1) orelse return error.OutOfMemory;
        try storage.readBlock(0, buffer);
        const boot: [*]const u8 = @ptrFromInt(buffer);
        if (boot[510] != 0x55 or boot[511] != 0xaa or get16(boot + 11) != 512) return error.InvalidBootSector;
        const reserved = get16(boot + 14);
        const fats = boot[16];
        const root_entries = get16(boot + 17);
        const fat_sectors = get16(boot + 22);
        if (fats == 0 or fat_sectors == 0 or boot[13] == 0) return error.InvalidBootSector;
        const root_start = @as(u32, reserved) + @as(u32, fats) * fat_sectors;
        const root_sectors = (@as(u32, root_entries) * 32 + 511) / 512;
        const total_sectors = if (get16(boot + 19) != 0) @as(u32, get16(boot + 19)) else get32(boot + 32);
        const data_start = root_start + root_sectors;
        if (total_sectors <= data_start) return error.InvalidBootSector;
        return .{
            .storage = storage,
            .buffer = buffer,
            .sectors_per_cluster = boot[13],
            .fat_start = reserved,
            .fat_sectors = fat_sectors,
            .fat_count = fats,
            .root_start = root_start,
            .root_sectors = root_sectors,
            .data_start = data_start,
            .cluster_count = (total_sectors - data_start) / boot[13],
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
                if (bytes[offset] == 0xe5 or (bytes[offset + 11] & 0x0f) == 0x0f) continue;
                if (!equal11(bytes + offset, name)) continue;
                var cluster = get16(bytes + offset + 26);
                const size = get32(bytes + offset + 28);
                if (cluster < 2 or size > output.len) return error.UnsupportedFile;
                var copied: usize = 0;
                while (copied < size) {
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
                        if (cluster < 2 or cluster >= 0xfff8) return error.BrokenChain;
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
                if (bytes[offset] != 0xe5 and (bytes[offset + 11] & 0x0f) != 0x0f and equal11(bytes + offset, name))
                    return get32(bytes + offset + 28);
            }
        }
        return error.NotFound;
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
                if (bytes[offset] == 0xe5 or (bytes[offset + 11] & 0x0f) == 0x0f or !equal11(bytes + offset, name)) continue;
                first_cluster = get16(bytes + offset + 26);
                size = get32(bytes + offset + 28);
                found = true;
                break;
            }
        }
        if (!found) return error.NotFound;
        if (file_offset >= size or output.len == 0) return 0;
        if (first_cluster < 2) return error.BrokenChain;
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * 512;
        var cluster = first_cluster;
        var skip = file_offset / cluster_bytes;
        while (skip != 0) : (skip -= 1) {
            cluster = try self.fatEntry(cluster);
            if (cluster < 2 or cluster >= 0xfff8) return error.BrokenChain;
        }
        var within_cluster = file_offset % cluster_bytes;
        var copied: usize = 0;
        const wanted = @min(output.len, size - file_offset);
        while (copied < wanted) {
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
                if (cluster < 2 or cluster >= 0xfff8) return error.BrokenChain;
            }
        }
        return copied;
    }

    pub fn writeRootFile(self: *Volume, name: *const [11]u8, data: []const u8) !void {
        const cluster_bytes = @as(usize, self.sectors_per_cluster) * 512;
        const needed = if (data.len == 0) 0 else (data.len + cluster_bytes - 1) / cluster_bytes;
        if (needed > 32) return error.FileTooLarge;
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
                    directory_sector = sector; directory_offset = offset; have_free = true;
                }
                if (bytes[offset] != 0 and bytes[offset] != 0xe5 and equal11(bytes + offset, name)) {
                    directory_sector = sector; directory_offset = offset;
                    old_cluster = get16(bytes + offset + 26); found = true; break;
                }
                if (bytes[offset] == 0) break;
            }
        }
        if (!found and !have_free) return error.DirectoryFull;
        if (old_cluster >= 2) try self.freeChain(old_cluster);

        var clusters: [32]u16 = undefined;
        var allocated: usize = 0;
        var search: u16 = 2;
        while (allocated < needed) : (allocated += 1) {
            const cluster = try self.findFree(search);
            clusters[allocated] = cluster;
            try self.setFatEntry(cluster, 0xffff);
            if (allocated != 0) try self.setFatEntry(clusters[allocated - 1], cluster);
            search = cluster + 1;
        }

        var written: usize = 0;
        for (clusters[0..needed]) |cluster| {
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
        put16(entry + 26, if (needed == 0) 0 else clusters[0]);
        put32(entry + 28, @intCast(data.len));
        try self.storage.writeBlock(self.root_start + directory_sector, self.buffer);
    }

    fn clusterLba(self: *const Volume, cluster: u16) u32 {
        return self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster;
    }

    fn fatEntry(self: *Volume, cluster: u16) !u16 {
        const byte_offset = @as(u32, cluster) * 2;
        try self.storage.readBlock(self.fat_start + byte_offset / 512, self.buffer);
        const bytes: [*]const u8 = @ptrFromInt(self.buffer);
        return get16(bytes + byte_offset % 512);
    }

    fn setFatEntry(self: *Volume, cluster: u16, value: u16) !void {
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
        while (cluster >= 2 and cluster < 0xfff8) {
            const next = try self.fatEntry(cluster);
            try self.setFatEntry(cluster, 0);
            cluster = next;
        }
    }
};

fn equal11(left: [*]const u8, right: *const [11]u8) bool {
    for (0..11) |index| if (left[index] != right[index]) return false;
    return true;
}

fn get16(source: [*]const u8) u16 { return @as(u16, source[0]) | (@as(u16, source[1]) << 8); }
fn get32(source: [*]const u8) u32 { return @as(u32, get16(source)) | (@as(u32, get16(source + 2)) << 16); }
fn put16(target: [*]u8, value: u16) void { target[0] = @truncate(value); target[1] = @truncate(value >> 8); }
fn put32(target: [*]u8, value: u32) void { put16(target, @truncate(value)); put16(target + 2, @truncate(value >> 16)); }
