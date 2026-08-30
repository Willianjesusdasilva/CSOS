pub export const socket_address: [16]u8 = .{ 2, 0, 0, 80, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
pub export const request: [63]u8 = "GET / HTTP/1.0\r\nHost: cloudflare-dns.com\r\nConnection: close\r\n\r\n".*;
pub export var response: [512]u8 = undefined;
pub export const success: [29]u8 = "Linux socket userspace ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq $41, %%rax
        \\movq $2, %%rdi
        \\movq $1, %%rsi
        \\movq $6, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r12
        \\movq $42, %%rax
        \\movq %%r12, %%rdi
        \\leaq socket_address(%%rip), %%rsi
        \\movq $16, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq $44, %%rax
        \\movq %%r12, %%rdi
        \\leaq request(%%rip), %%rsi
        \\movq $63, %%rdx
        \\xorq %%r10, %%r10
        \\xorq %%r8, %%r8
        \\xorq %%r9, %%r9
        \\syscall
        \\cmpq $63, %%rax
        \\jne 1f
        \\movq $45, %%rax
        \\movq %%r12, %%rdi
        \\leaq response(%%rip), %%rsi
        \\movq $512, %%rdx
        \\xorq %%r10, %%r10
        \\xorq %%r8, %%r8
        \\xorq %%r9, %%r9
        \\syscall
        \\testq %%rax, %%rax
        \\jle 1f
        \\movq $48, %%rax
        \\movq %%r12, %%rdi
        \\movq $2, %%rsi
        \\syscall
        \\movq $3, %%rax
        \\movq %%r12, %%rdi
        \\syscall
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq success(%%rip), %%rsi
        \\movq $29, %%rdx
        \\syscall
        \\movq $24, %%rax
        \\syscall
        \\movq $60, %%rax
        \\xorq %%rdi, %%rdi
        \\syscall
        \\1:
        \\movq $60, %%rax
        \\movq $1, %%rdi
        \\syscall
        \\ud2
    );
}
