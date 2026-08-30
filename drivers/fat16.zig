const nvme = @import("nvme");
const physical = @import("physical");

pub const Volume = struct {
    storage: *nvme.Controller,
    buffer: u64,
    sectors_per_cluster: u8,
    root_start: u32,
    root_sectors: u32,
    data_start: u32,

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
        return .{
            .storage = storage,
            .buffer = buffer,
            .sectors_per_cluster = boot[13],
            .root_start = root_start,
            .root_sectors = root_sectors,
            .data_start = root_start + root_sectors,
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
                const cluster = get16(bytes + offset + 26);
                const size = get32(bytes + offset + 28);
                if (cluster < 2 or size > output.len or size > @as(u32, self.sectors_per_cluster) * 512) return error.UnsupportedFile;
                var copied: usize = 0;
                var cluster_sector: u32 = 0;
                while (cluster_sector < self.sectors_per_cluster and copied < size) : (cluster_sector += 1) {
                    const lba = self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster + cluster_sector;
                    try self.storage.readBlock(lba, self.buffer);
                    const count = @min(@as(usize, size) - copied, 512);
                    const source: [*]const u8 = @ptrFromInt(self.buffer);
                    @memcpy(output[copied .. copied + count], source[0..count]);
                    copied += count;
                }
                return copied;
            }
        }
        return error.NotFound;
    }
};

fn equal11(left: [*]const u8, right: *const [11]u8) bool {
    for (0..11) |index| if (left[index] != right[index]) return false;
    return true;
}

fn get16(source: [*]const u8) u16 { return @as(u16, source[0]) | (@as(u16, source[1]) << 8); }
fn get32(source: [*]const u8) u32 { return @as(u32, get16(source)) | (@as(u32, get16(source + 2)) << 16); }
