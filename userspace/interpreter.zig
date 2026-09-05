pub export const message: [29]u8 = "Linux PT_INTERP loader ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq %%rsp, %%r12
        \\xorq %%r13, %%r13
        \\xorq %%r14, %%r14
        \\xorq %%r15, %%r15
        \\xorq %%rbp, %%rbp
        \\movq (%%rsp), %%rcx
        \\leaq 16(%%rsp,%%rcx,8), %%rdi
        \\1: cmpq $0, (%%rdi)
        \\je 2f
        \\addq $8, %%rdi
        \\jmp 1b
        \\2: addq $8, %%rdi
        \\3: movq (%%rdi), %%rax
        \\testq %%rax, %%rax
        \\jz 6f
        \\cmpq $9, %%rax
        \\je 4f
        \\cmpq $0x6000, %%rax
        \\je 5f
        \\cmpq $0x6001, %%rax
        \\je 7f
        \\cmpq $0x6002, %%rax
        \\je 11f
        \\addq $16, %%rdi
        \\jmp 3b
        \\4: movq 8(%%rdi), %%r13
        \\addq $16, %%rdi
        \\jmp 3b
        \\5: movq 8(%%rdi), %%r14
        \\addq $16, %%rdi
        \\jmp 3b
        \\7: movq 8(%%rdi), %%r15
        \\addq $16, %%rdi
        \\jmp 3b
        \\11: movq 8(%%rdi), %%rbp
        \\addq $16, %%rdi
        \\jmp 3b
        \\6: testq %%r13, %%r13
        \\jz 9f
        \\testq %%rbp, %%rbp
        \\jz 12f
        \\movq (%%rbp), %%rax
        \\testq %%rax, %%rax
        \\jz 12f
        \\movq (%%r12), %%rdi
        \\leaq 8(%%r12), %%rsi
        \\movq 8(%%rbp), %%rdx
        \\leaq 16(%%rbp), %%rcx
        \\call *%%rax
        \\testl %%eax, %%eax
        \\jnz 9f
        \\12:
        \\testq %%r15, %%r15
        \\jz 8f
        \\testq %%r14, %%r14
        \\jz 9f
        \\xorq %%rbx, %%rbx
        \\10: movq (%%r12), %%rdi
        \\leaq 8(%%r12), %%rsi
        \\leaq 16(%%r12,%%rdi,8), %%rdx
        \\call *(%%r14,%%rbx,8)
        \\incq %%rbx
        \\cmpq %%r15, %%rbx
        \\jb 10b
        \\8:
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq message(%%rip), %%rsi
        \\movq $29, %%rdx
        \\syscall
        \\movq %%r12, %%rsp
        \\jmp *%%r13
        \\9: movq $60, %%rax
        \\movq $1, %%rdi
        \\syscall
        \\ud2
    );
}
