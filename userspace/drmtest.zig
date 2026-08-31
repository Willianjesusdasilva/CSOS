pub export const device_path: [15]u8 = "/dev/dri/card0\x00".*;
pub export var version: [64]u8 = .{0} ** 64;
pub export var name: [16]u8 = .{0} ** 16;
pub export var capability: [16]u8 = .{0} ** 16;
pub export var dumb_create: [32]u8 = .{0} ** 32;
pub export var dumb_map: [16]u8 = .{0} ** 16;
pub export var dumb_destroy: [4]u8 = .{0} ** 4;
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
        \\cmpq $1, capability+8(%%rip)
        \\jne 1f
        \\movl $64, dumb_create(%%rip)
        \\movl $64, dumb_create+4(%%rip)
        \\movl $32, dumb_create+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02064b2, %%rsi
        \\leaq dumb_create(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, dumb_create+16(%%rip)
        \\jne 1f
        \\cmpl $256, dumb_create+20(%%rip)
        \\jne 1f
        \\cmpq $16384, dumb_create+24(%%rip)
        \\jne 1f
        \\movl $1, dumb_map(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01064b3, %%rsi
        \\leaq dumb_map(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $0, dumb_map+8(%%rip)
        \\jne 1f
        \\movq $9, %%rax
        \\xorq %%rdi, %%rdi
        \\movq $16384, %%rsi
        \\movq $3, %%rdx
        \\movq $1, %%r10
        \\movq %%r12, %%r8
        \\xorq %%r9, %%r9
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r13
        \\movl $0x00667788, 16380(%%r13)
        \\cmpl $0x00667788, 16380(%%r13)
        \\jne 1f
        \\movq $11, %%rax
        \\movq %%r13, %%rdi
        \\movq $16384, %%rsi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl $1, dumb_destroy(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00464b4, %%rsi
        \\leaq dumb_destroy(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
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
