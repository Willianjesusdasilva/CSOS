const code_selector = 0x08;
const data_selector = 0x10;

var table align(16) = [_]u64{
    0,
    0x00af9a000000ffff,
    0x00cf92000000ffff,
    0x00cff2000000ffff,
    0x00affa000000ffff,
    0,
    0,
};

const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};

var tss = Tss{};
var privilege_stack: [64 * 1024]u8 align(16) = undefined;
var interrupt_stack: [16 * 1024]u8 align(16) = undefined;

const Register = packed struct {
    limit: u16,
    base: u64,
};

pub fn install() void {
    tss.rsp0 = @intFromPtr(&privilege_stack) + privilege_stack.len;
    // Hardware interrupts arriving from ring 3 must not reuse rsp0: the
    // userspace launcher keeps its suspended call frame there.
    tss.ist1 = @intFromPtr(&interrupt_stack) + interrupt_stack.len;
    const base = @intFromPtr(&tss);
    const limit = @sizeOf(Tss) - 1;
    table[5] = limit |
        ((base & 0x00ffffff) << 16) |
        (@as(u64, 0x89) << 40) |
        (((limit >> 16) & 0x0f) << 48) |
        (((base >> 24) & 0xff) << 56);
    table[6] = base >> 32;
    const register = Register{
        .limit = @sizeOf(@TypeOf(table)) - 1,
        .base = @intFromPtr(&table),
    };

    asm volatile (
        \\lgdt (%[register])
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\xorw %%ax, %%ax
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw $0x28, %%ax
        \\ltr %%ax
        :
        : [register] "r" (&register),
        : .{ .rax = true, .memory = true });

    _ = code_selector;
    _ = data_selector;
}

pub fn privilegeStackTop() u64 {
    return @intFromPtr(&privilege_stack) + privilege_stack.len;
}

pub const ReservedRange = struct { address: u64, pages: u64 };

fn reservedRange(address: u64, bytes: u64) ReservedRange {
    const base = address & ~@as(u64, 4095);
    return .{ .address = base, .pages = (address - base + bytes + 4095) / 4096 };
}

/// Static GDT/TSS storage is outside the physical allocator's ownership, but
/// it is still identity-mapped and used by ring-3 interrupts.  Reserve every
/// backing range so process page-table and userspace allocations cannot reuse
/// the privilege or IST stacks and turn a timer delivery into a triple fault.
pub fn reservedMemoryRanges() [4]ReservedRange {
    return .{
        reservedRange(@intFromPtr(&table), @sizeOf(@TypeOf(table))),
        reservedRange(@intFromPtr(&tss), @sizeOf(Tss)),
        reservedRange(@intFromPtr(&privilege_stack), privilege_stack.len),
        reservedRange(@intFromPtr(&interrupt_stack), interrupt_stack.len),
    };
}
