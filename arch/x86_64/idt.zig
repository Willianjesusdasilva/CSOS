const interrupt_gate = 0x8e;
const kernel_code_selector = 0x08;

const Entry = packed struct {
    offset_low: u16 = 0,
    selector: u16 = kernel_code_selector,
    ist: u8 = 0,
    attributes: u8 = interrupt_gate,
    offset_middle: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,

    fn from(handler: *const anyopaque) Entry {
        const address = @intFromPtr(handler);
        return .{
            .offset_low = @truncate(address),
            .offset_middle = @truncate(address >> 16),
            .offset_high = @truncate(address >> 32),
        };
    }
};

const Register = packed struct {
    limit: u16,
    base: u64,
};

var entries: [256]Entry align(16) = undefined;
pub fn install() void {
    for (&entries) |*entry| entry.* = Entry.from(@ptrCast(&unexpected));
    inline for ([_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 }) |vector| {
        entries[vector] = Entry.from(@ptrCast(&unexpectedWithError));
    }
    entries[3] = Entry.from(@ptrCast(&breakpoint));

    const register = Register{
        .limit = @sizeOf(@TypeOf(entries)) - 1,
        .base = @intFromPtr(&entries),
    };
    asm volatile ("lidt (%[register])"
        :
        : [register] "r" (&register),
        : .{ .memory = true });
}

pub fn verifyBreakpoint() bool {
    asm volatile ("int3");
    return true;
}

fn breakpoint() callconv(.naked) void {
    asm volatile ("iretq");
}

fn unexpected() callconv(.naked) void {
    asm volatile ("cli; 1: hlt; jmp 1b");
}

fn unexpectedWithError() callconv(.naked) void {
    asm volatile ("cli; 1: hlt; jmp 1b");
}
