pub export const message: [29]u8 = "Linux dynamic ELF main ready\n".*;
extern fn shared_marker() callconv(.c) u64;
pub export var shared_reference: *const fn () callconv(.c) u64 = &shared_marker;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq message(%%rip), %%rsi
        \\movq $29, %%rdx
        \\syscall
        \\movq $60, %%rax
        \\xorq %%rdi, %%rdi
        \\syscall
        \\ud2
    );
}
