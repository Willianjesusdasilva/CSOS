const apic = @import("apic");
const physical = @import("physical");

const trampoline_address = 0x8000;
const stack_pages = 4;

extern const ap_trampoline_start: u8;
extern const ap_trampoline_end: u8;
extern const ap_trampoline_cr3: u8;
extern const ap_trampoline_stack: u8;
extern const ap_trampoline_entry: u8;

pub export var online_aps: u32 = 0;
var secondary_entry: ?*const fn (u32) callconv(.c) noreturn = null;

pub fn prepare(cr3: u64) !void {
    const source_address = @intFromPtr(&ap_trampoline_start);
    const length = @intFromPtr(&ap_trampoline_end) - source_address;
    if (length > 4096 or cr3 > 0xffffffff) return error.InvalidTrampoline;

    const source: [*]const u8 = @ptrFromInt(source_address);
    const destination: [*]u8 = @ptrFromInt(trampoline_address);
    @memcpy(destination[0..length], source[0..length]);
    patch(u64, &ap_trampoline_cr3, cr3);
    patch(u64, &ap_trampoline_entry, @intFromPtr(&apMain));
}

pub fn start(apic_id: u32, pages: *physical.Allocator) !void {
    const stack = pages.allocate(stack_pages) orelse return error.OutOfMemory;
    patch(u64, &ap_trampoline_stack, stack + stack_pages * 4096);
    const expected = @atomicLoad(u32, &online_aps, .acquire) + 1;
    apic.startCpu(apic_id, trampoline_address >> 12);

    var spins: usize = 0;
    while (@atomicLoad(u32, &online_aps, .acquire) < expected and spins < 50_000_000) : (spins += 1) {
        asm volatile ("pause");
    }
    if (@atomicLoad(u32, &online_aps, .acquire) < expected) return error.StartTimeout;
}

pub fn setSecondaryEntry(entry: *const fn (u32) callconv(.c) noreturn) void {
    secondary_entry = entry;
}

fn patch(comptime T: type, source_symbol: *const u8, value: T) void {
    const offset = @intFromPtr(source_symbol) - @intFromPtr(&ap_trampoline_start);
    const target: *align(1) T = @ptrFromInt(trampoline_address + offset);
    target.* = value;
}

fn apMain() callconv(.c) noreturn {
    _ = @atomicRmw(u32, &online_aps, .Add, 1, .release);
    if (secondary_entry) |entry| entry(apic.id());
    while (true) asm volatile ("cli; hlt");
}
