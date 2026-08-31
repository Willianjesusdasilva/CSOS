pub export const device_path: [15]u8 = "/dev/dri/card0\x00".*;
pub export const render_path: [20]u8 = "/dev/dri/renderD128\x00".*;
pub export var version: [64]u8 = .{0} ** 64;
pub export var render_version: [64]u8 = .{0} ** 64;
pub export var name: [16]u8 = .{0} ** 16;
pub export var capability: [16]u8 = .{0} ** 16;
pub export var dumb_create: [32]u8 = .{0} ** 32;
pub export var dumb_map: [16]u8 = .{0} ** 16;
pub export var dumb_destroy: [4]u8 = .{0} ** 4;
pub export var second_create: [32]u8 = .{0} ** 32;
pub export var second_map: [16]u8 = .{0} ** 16;
pub export var second_destroy: [4]u8 = .{0} ** 4;
pub export var resources: [64]u8 = .{0} ** 64;
pub export var resource_ids: [3]u32 = .{ 0, 0, 0 };
pub export var connector: [80]u8 = .{0} ** 80;
pub export var mode: [68]u8 = .{0} ** 68;
pub export var connector_encoder: u32 = 0;
pub export var encoder: [20]u8 = .{0} ** 20;
pub export var crtc: [104]u8 = .{0} ** 104;
pub export var scanout_create: [32]u8 = .{0} ** 32;
pub export var framebuffer_command: [28]u8 = .{0} ** 28;
pub export var scanout_connector: u32 = 2;
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
        \\cmpq $6, version+16(%%rip)
        \\je 2f
        \\cmpq $7, version+16(%%rip)
        \\jne 1f
        \\2:
        \\cmpb $0, name(%%rip)
        \\je 1f
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
        \\movl $32, second_create(%%rip)
        \\movl $32, second_create+4(%%rip)
        \\movl $32, second_create+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02064b2, %%rsi
        \\leaq second_create(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $2, second_create+16(%%rip)
        \\jne 1f
        \\cmpq $4096, second_create+24(%%rip)
        \\jne 1f
        \\movl $2, second_map(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01064b3, %%rsi
        \\leaq second_map(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $16777216, second_map+8(%%rip)
        \\jne 1f
        \\movq $9, %%rax
        \\xorq %%rdi, %%rdi
        \\movq $4096, %%rsi
        \\movq $3, %%rdx
        \\movq $1, %%r10
        \\movq %%r12, %%r8
        \\movq second_map+8(%%rip), %%r9
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r14
        \\movl $0x00123456, (%%r14)
        \\cmpl $0x00123456, (%%r14)
        \\jne 1f
        \\cmpl $0x00667788, 16380(%%r13)
        \\jne 1f
        \\movq $11, %%rax
        \\movq %%r14, %%rdi
        \\movq $4096, %%rsi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl $2, second_destroy(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00464b4, %%rsi
        \\leaq second_destroy(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
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
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc04064a0, %%rsi
        \\leaq resources(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, resources+36(%%rip)
        \\jne 1f
        \\cmpl $1, resources+40(%%rip)
        \\jne 1f
        \\cmpl $1, resources+44(%%rip)
        \\jne 1f
        \\leaq resource_ids(%%rip), %%rax
        \\movq %%rax, resources+8(%%rip)
        \\leaq resource_ids+4(%%rip), %%rax
        \\movq %%rax, resources+16(%%rip)
        \\leaq resource_ids+8(%%rip), %%rax
        \\movq %%rax, resources+24(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc04064a0, %%rsi
        \\leaq resources(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, resource_ids(%%rip)
        \\jne 1f
        \\cmpl $2, resource_ids+4(%%rip)
        \\jne 1f
        \\cmpl $3, resource_ids+8(%%rip)
        \\jne 1f
        \\movl $2, connector+48(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc05064a7, %%rsi
        \\leaq connector(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, connector+32(%%rip)
        \\jne 1f
        \\cmpl $1, connector+40(%%rip)
        \\jne 1f
        \\leaq connector_encoder(%%rip), %%rax
        \\movq %%rax, connector(%%rip)
        \\leaq mode(%%rip), %%rax
        \\movq %%rax, connector+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc05064a7, %%rsi
        \\leaq connector(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $3, connector_encoder(%%rip)
        \\jne 1f
        \\cmpl $3, connector+44(%%rip)
        \\jne 1f
        \\cmpl $1, connector+60(%%rip)
        \\jne 1f
        \\cmpw $0, mode+4(%%rip)
        \\je 1f
        \\movl $3, encoder(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01464a6, %%rsi
        \\leaq encoder(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, encoder+8(%%rip)
        \\jne 1f
        \\movl $1, crtc+12(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc06864a1, %%rsi
        \\leaq crtc(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, crtc+32(%%rip)
        \\jne 1f
        \\cmpw $0, crtc+40(%%rip)
        \\je 1f
        \\movl resources+60(%%rip), %%eax
        \\movl %%eax, scanout_create(%%rip)
        \\movl resources+52(%%rip), %%eax
        \\movl %%eax, scanout_create+4(%%rip)
        \\movl $32, scanout_create+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02064b2, %%rsi
        \\leaq scanout_create(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl scanout_create+4(%%rip), %%eax
        \\movl %%eax, framebuffer_command+4(%%rip)
        \\movl scanout_create(%%rip), %%eax
        \\movl %%eax, framebuffer_command+8(%%rip)
        \\movl scanout_create+20(%%rip), %%eax
        \\movl %%eax, framebuffer_command+12(%%rip)
        \\movl $32, framebuffer_command+16(%%rip)
        \\movl $24, framebuffer_command+20(%%rip)
        \\movl $1, framebuffer_command+24(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01c64ae, %%rsi
        \\leaq framebuffer_command(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $4, framebuffer_command(%%rip)
        \\jne 1f
        \\leaq scanout_connector(%%rip), %%rax
        \\movq %%rax, crtc(%%rip)
        \\movl $1, crtc+8(%%rip)
        \\movl $1, crtc+12(%%rip)
        \\movl $4, crtc+16(%%rip)
        \\movl $1, crtc+32(%%rip)
        \\leaq mode(%%rip), %%rsi
        \\leaq crtc+36(%%rip), %%rdi
        \\movq $68, %%rcx
        \\rep movsb
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc06864a2, %%rsi
        \\leaq crtc(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl $1, crtc+12(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc06864a1, %%rsi
        \\leaq crtc(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $4, crtc+16(%%rip)
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00464af, %%rsi
        \\leaq framebuffer_command(%%rip), %%rdx
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
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq render_path(%%rip), %%rsi
        \\movq $2, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r12
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0406400, %%rsi
        \\leaq render_version(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, render_version(%%rip)
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
