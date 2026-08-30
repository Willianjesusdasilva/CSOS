pub export const message: [29]u8 = "Linux PT_INTERP loader ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq %%rsp, %%r12
        \\movq (%%rsp), %%rcx
        \\leaq 16(%%rsp,%%rcx,8), %%rdi
        \\1: cmpq $0, (%%rdi)
        \\je 2f
        \\addq $8, %%rdi
        \\jmp 1b
        \\2: addq $8, %%rdi
        \\3: movq (%%rdi), %%rax
        \\testq %%rax, %%rax
        \\jz 5f
        \\cmpq $9, %%rax
        \\je 4f
        \\addq $16, %%rdi
        \\jmp 3b
        \\4: movq 8(%%rdi), %%r13
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq message(%%rip), %%rsi
        \\movq $29, %%rdx
        \\syscall
        \\movq %%r12, %%rsp
        \\jmp *%%r13
        \\5: movq $60, %%rax
        \\movq $1, %%rdi
        \\syscall
        \\ud2
    );
}
