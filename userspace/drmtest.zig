pub export const device_path: [15]u8 = "/dev/dri/card0\x00".*;
pub export var version: [64]u8 = .{0} ** 64;
pub export var name: [16]u8 = .{0} ** 16;
pub export var capability: [16]u8 = .{0} ** 16;
pub export const success: [31]u8 = "Linux DRM core userspace ready\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq $16, version+16(%%rip)
        \\leaq name(%%rip), %%rax
        \\movq %%rax, version+24(%%rip)
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq device_path(%%rip), %%rsi
        \\movq $2, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r12
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0406400, %%rsi
        \\leaq version(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, version(%%rip)
        \\jne 1f
        \\cmpq $7, version+16(%%rip)
        \\jne 1f
        \\movabsq $0x6d7264736f7363, %%rax
        \\cmpq %%rax, name(%%rip)
        \\jne 1f
        \\movq $6, capability(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc010640c, %%rsi
        \\leaq capability(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $1, capability+8(%%rip)
        \\jne 1f
        \\movq $1, capability(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc010640c, %%rsi
        \\leaq capability(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $0, capability+8(%%rip)
        \\jne 1f
        \\movq $3, %%rax
        \\movq %%r12, %%rdi
        \\syscall
        \\movq $1, %%rax
        \\movq $1, %%rdi
        \\leaq success(%%rip), %%rsi
        \\movq $31, %%rdx
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
