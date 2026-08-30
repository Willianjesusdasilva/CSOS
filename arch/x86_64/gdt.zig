const code_selector = 0x08;
const data_selector = 0x10;

var table align(16) = [_]u64{
    0,
    0x00af9a000000ffff,
    0x00cf92000000ffff,
};

const Register = packed struct {
    limit: u16,
    base: u64,
};

pub fn install() void {
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
        :
        : [register] "r" (&register),
        : .{ .rax = true, .memory = true });

    _ = code_selector;
    _ = data_selector;
}
