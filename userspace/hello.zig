pub export const hello_message: [21]u8 = "Hello from userspace\n".*;
pub export var hello_pointer: *const [21]u8 = &hello_message;
pub export const hello_path: [11]u8 = "/hello.txt\x00".*;
pub export const mmap_success: [32]u8 = "Linux file mmap userspace ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movl $1, %%eax
        \\movl $1, %%edi
        \\movq hello_pointer(%%rip), %%rsi
        \\movl $21, %%edx
        \\syscall
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq hello_path(%%rip), %%rsi
        \\xorq %%rdx, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r8
        \\movq $9, %%rax
        \\xorq %%rdi, %%rdi
        \\movq $4096, %%rsi
        \\movq $1, %%rdx
        \\movq $2, %%r10
        \\xorq %%r9, %%r9
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movabsq $0x7266206f6c6c6548, %%rcx
        \\cmpq %%rcx, (%%rax)
        \\jne 1f
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq mmap_success(%%rip), %%rsi
        \\movq $32, %%rdx
        \\syscall
        \\movl $60, %%eax
        \\xorl %%edi, %%edi
        \\syscall
        \\1:
        \\movl $60, %%eax
        \\movl $1, %%edi
        \\syscall
        \\ud2
    );
}
