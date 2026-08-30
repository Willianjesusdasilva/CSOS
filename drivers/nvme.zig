const pci = @import("pci");
const physical = @import("physical");

const queue_depth = 16;

pub const Controller = struct {
    base: u64,
    doorbell_stride: u8,
    admin_submission: u64,
    admin_completion: u64,
    submission_tail: u16 = 0,
    completion_head: u16 = 0,
    completion_phase: u1 = 1,
    io_submission: u64 = 0,
    io_completion: u64 = 0,
    io_submission_tail: u16 = 0,
    io_completion_head: u16 = 0,
    io_completion_phase: u1 = 1,
    block_size: u32 = 0,

    pub fn init(device: pci.Device, pages: *physical.Allocator) !Controller {
        pci.enableMemoryAndBusMaster(device);
        const base = pci.barAddress(device, 0) orelse return error.NoBar;
        const capability = read64(base, 0);
        if ((capability & 0xffff) + 1 < queue_depth) return error.QueueTooLarge;
        const submission = pages.allocate(1) orelse return error.OutOfMemory;
        const completion = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(submission);
        zeroPage(completion);

        write32(base, 0x14, read32(base, 0x14) & ~@as(u32, 1));
        try waitReady(base, false);
        write32(base, 0x24, ((queue_depth - 1) << 16) | (queue_depth - 1));
        write64(base, 0x28, submission);
        write64(base, 0x30, completion);
        write32(base, 0x14, (6 << 16) | (4 << 20) | 1);
        try waitReady(base, true);

        return .{
            .base = base,
            .doorbell_stride = @truncate((capability >> 32) & 0xf),
            .admin_submission = submission,
            .admin_completion = completion,
        };
    }

    pub fn identify(self: *Controller, pages: *physical.Allocator) !u32 {
        const buffer = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(buffer);
        const command = self.submissionCommand();
        @memset(command[0..64], 0);
        command[0] = 0x06;
        put16(command + 2, self.submission_tail + 1);
        put64(command + 24, buffer);
        put32(command + 40, 1);
        self.submit();
        try self.complete();
        const identify_data: [*]const u8 = @ptrFromInt(buffer);
        const namespace_count = get32(identify_data + 516);
        if (namespace_count == 0) return error.NoNamespace;
        return namespace_count;
    }

    pub fn initIo(self: *Controller, pages: *physical.Allocator) !void {
        self.io_submission = pages.allocate(1) orelse return error.OutOfMemory;
        self.io_completion = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(self.io_submission);
        zeroPage(self.io_completion);

        var command = self.submissionCommand();
        @memset(command[0..64], 0);
        command[0] = 0x05;
        put16(command + 2, self.submission_tail + 1);
        put64(command + 24, self.io_completion);
        put32(command + 40, 1 | ((queue_depth - 1) << 16));
        put32(command + 44, 1);
        self.submit();
        try self.complete();

        command = self.submissionCommand();
        @memset(command[0..64], 0);
        command[0] = 0x01;
        put16(command + 2, self.submission_tail + 1);
        put64(command + 24, self.io_submission);
        put32(command + 40, 1 | ((queue_depth - 1) << 16));
        put32(command + 44, 1 | (1 << 16));
        self.submit();
        try self.complete();

        const namespace = pages.allocate(1) orelse return error.OutOfMemory;
        zeroPage(namespace);
        command = self.submissionCommand();
        @memset(command[0..64], 0);
        command[0] = 0x06;
        put16(command + 2, self.submission_tail + 1);
        put32(command + 4, 1);
        put64(command + 24, namespace);
        self.submit();
        try self.complete();
        const data: [*]const u8 = @ptrFromInt(namespace);
        const format = data[26] & 0x0f;
        const exponent = data[128 + @as(usize, format) * 4 + 2];
        if (exponent < 9 or exponent > 12) return error.UnsupportedBlockSize;
        self.block_size = @as(u32, 1) << @as(u5, @intCast(exponent));
    }

    pub fn writeBlock(self: *Controller, lba: u64, buffer: u64) !void {
        try self.ioCommand(0x01, lba, buffer);
    }

    pub fn readBlock(self: *Controller, lba: u64, buffer: u64) !void {
        try self.ioCommand(0x02, lba, buffer);
    }

    fn submissionCommand(self: *Controller) [*]u8 {
        return @ptrFromInt(self.admin_submission + @as(u64, self.submission_tail) * 64);
    }

    fn submit(self: *Controller) void {
        self.submission_tail = (self.submission_tail + 1) % queue_depth;
        write32(self.base, doorbellOffset(self.doorbell_stride, 0), self.submission_tail);
    }

    fn complete(self: *Controller) !void {
        const completion: [*]volatile u8 = @ptrFromInt(self.admin_completion + @as(u64, self.completion_head) * 16);
        var spins: usize = 0;
        while ((completion[14] & 1) != self.completion_phase and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
        if (spins == 100_000_000) return error.Timeout;
        const status = (@as(u16, completion[15]) << 8 | completion[14]) >> 1;
        if (status != 0) return error.CommandFailed;
        self.completion_head += 1;
        if (self.completion_head == queue_depth) {
            self.completion_head = 0;
            self.completion_phase ^= 1;
        }
        write32(self.base, doorbellOffset(self.doorbell_stride, 1), self.completion_head);
    }

    fn ioCommand(self: *Controller, opcode: u8, lba: u64, buffer: u64) !void {
        const command: [*]u8 = @ptrFromInt(self.io_submission + @as(u64, self.io_submission_tail) * 64);
        @memset(command[0..64], 0);
        command[0] = opcode;
        put16(command + 2, self.io_submission_tail + 1);
        put32(command + 4, 1);
        put64(command + 24, buffer);
        put32(command + 40, @truncate(lba));
        put32(command + 44, @truncate(lba >> 32));
        self.io_submission_tail = (self.io_submission_tail + 1) % queue_depth;
        write32(self.base, doorbellOffset(self.doorbell_stride, 2), self.io_submission_tail);

        const completion: [*]volatile u8 = @ptrFromInt(self.io_completion + @as(u64, self.io_completion_head) * 16);
        var spins: usize = 0;
        while ((completion[14] & 1) != self.io_completion_phase and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
        if (spins == 100_000_000) return error.Timeout;
        const status = (@as(u16, completion[15]) << 8 | completion[14]) >> 1;
        if (status != 0) return error.CommandFailed;
        self.io_completion_head += 1;
        if (self.io_completion_head == queue_depth) {
            self.io_completion_head = 0;
            self.io_completion_phase ^= 1;
        }
        write32(self.base, doorbellOffset(self.doorbell_stride, 3), self.io_completion_head);
    }
};

fn waitReady(base: u64, expected: bool) !void {
    var spins: usize = 0;
    while (((read32(base, 0x1c) & 1) != 0) != expected and spins < 100_000_000) : (spins += 1) asm volatile ("pause");
    if (spins == 100_000_000) return error.Timeout;
}

fn doorbellOffset(stride: u8, index: u8) u64 {
    return 0x1000 + (@as(u64, index) * (@as(u64, 4) << @as(u6, @intCast(stride))));
}

fn zeroPage(address: u64) void {
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..4096], 0);
}

fn read32(base: u64, offset: u64) u32 { const value: *volatile u32 = @ptrFromInt(base + offset); return value.*; }
fn read64(base: u64, offset: u64) u64 { const value: *volatile u64 = @ptrFromInt(base + offset); return value.*; }
fn write32(base: u64, offset: u64, value: u32) void { const target: *volatile u32 = @ptrFromInt(base + offset); target.* = value; }
fn write64(base: u64, offset: u64, value: u64) void { const target: *volatile u64 = @ptrFromInt(base + offset); target.* = value; }
fn put16(target: [*]u8, value: u16) void { target[0] = @truncate(value); target[1] = @truncate(value >> 8); }
fn put32(target: [*]u8, value: u32) void { var i: usize = 0; while (i < 4) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
fn put64(target: [*]u8, value: u64) void { var i: usize = 0; while (i < 8) : (i += 1) target[i] = @truncate(value >> @intCast(i * 8)); }
fn get32(source: [*]const u8) u32 { return @as(u32, source[0]) | (@as(u32, source[1]) << 8) | (@as(u32, source[2]) << 16) | (@as(u32, source[3]) << 24); }
