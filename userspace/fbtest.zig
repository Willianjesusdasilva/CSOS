pub export const framebuffer_path: [9]u8 = "/dev/fb0\x00".*;
pub export var variable_info: [160]u8 = .{0} ** 160;
pub export var fixed_info: [80]u8 = .{0} ** 80;
pub export const success: [40]u8 = "Linux framebuffer ioctl userspace ready\n".*;
pub export const mmap_success: [39]u8 = "Linux framebuffer mmap userspace ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq framebuffer_path(%%rip), %%rsi
        \\movq $2, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r12
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x4600, %%rsi
        \\leaq variable_info(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $0, variable_info(%%rip)
        \\je 1f
        \\cmpl $32, variable_info+24(%%rip)
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x4602, %%rsi
        \\leaq fixed_info(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $0, fixed_info+24(%%rip)
        \\je 1f
        \\cmpl $0, fixed_info+48(%%rip)
        \\je 1f
        \\movl fixed_info+24(%%rip), %%r13d
        \\movq $9, %%rax
        \\xorq %%rdi, %%rdi
        \\movq %%r13, %%rsi
        \\movq $3, %%rdx
        \\movq $1, %%r10
        \\movq %%r12, %%r8
        \\xorq %%r9, %%r9
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r14
        \\movl $0x00112233, (%%r14)
        \\movl $0x00445566, -4(%%r14,%%r13)
        \\cmpl $0x00112233, (%%r14)
        \\jne 1f
        \\cmpl $0x00445566, -4(%%r14,%%r13)
        \\jne 1f
        \\movq $11, %%rax
        \\movq %%r14, %%rdi
        \\movq %%r13, %%rsi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $3, %%rax
        \\movq %%r12, %%rdi
        \\syscall
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq success(%%rip), %%rsi
        \\movq $40, %%rdx
        \\syscall
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq mmap_success(%%rip), %%rsi
        \\movq $39, %%rdx
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
