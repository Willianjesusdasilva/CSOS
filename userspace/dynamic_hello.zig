pub export const message: [29]u8 = "Linux dynamic ELF main ready\n".*;
extern fn shared_marker() callconv(.c) u64;
extern fn extra_marker() callconv(.c) u64;
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\call shared_marker@PLT
        \\cmpq $0x43534f53, %%rax
        \\jne 1f
        \\call extra_marker@PLT
        \\cmpq $0x45585452, %%rax
        \\jne 1f
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq message(%%rip), %%rsi
        \\movq $29, %%rdx
        \\syscall
        \\1:
        \\movq $60, %%rax
        \\sete %%dil
        \\xorq $1, %%rdi
        \\syscall
        \\ud2
    );
}
