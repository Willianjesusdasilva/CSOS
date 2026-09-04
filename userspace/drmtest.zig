pub export const device_path: [15]u8 = "/dev/dri/card0\x00".*;
pub export const render_path: [20]u8 = "/dev/dri/renderD128\x00".*;
pub export const pci_vendor_path: [34]u8 = "/sys/dev/char/226:0/device/vendor\x00".*;
pub export const pci_uevent_path: [34]u8 = "/sys/dev/char/226:0/device/uevent\x00".*;
pub export const pci_subsystem_path: [37]u8 = "/sys/dev/char/226:0/device/subsystem\x00".*;
pub export const pci_subsystem_target: [19]u8 = "../../../../bus/pci".*;
pub export const pci_slot_prefix: [14]u8 = "PCI_SLOT_NAME=".*;
pub export var stat_buffer: [144]u8 = .{0} ** 144;
pub export var pci_attribute: [64]u8 = .{0} ** 64;
pub export var version: [64]u8 = .{0} ** 64;
pub export var render_version: [64]u8 = .{0} ** 64;
pub export var name: [16]u8 = .{0} ** 16;
pub export var capability: [16]u8 = .{0} ** 16;
pub export var dumb_create: [32]u8 = .{0} ** 32;
pub export var dumb_map: [16]u8 = .{0} ** 16;
pub export var dumb_destroy: [8]u8 = .{0} ** 8;
pub export var second_create: [32]u8 = .{0} ** 32;
pub export var second_map: [16]u8 = .{0} ** 16;
pub export var second_destroy: [8]u8 = .{0} ** 8;
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
pub export var sync_create_signaled: [8]u8 = .{ 0, 0, 0, 0, 1, 0, 0, 0 };
pub export var sync_create_pending: [8]u8 = .{0} ** 8;
pub export var sync_handles: [2]u32 = .{ 0, 0 };
pub export var sync_array: [16]u8 = .{0} ** 16;
pub export var sync_wait: [40]u8 = .{0} ** 40;
pub export var sync_destroy: [8]u8 = .{0} ** 8;
pub export var timeline_point: u64 = 5;
pub export var timeline_query_point: u64 = 0;
pub export var timeline_array: [24]u8 = .{0} ** 24;
pub export var timeline_wait: [48]u8 = .{0} ** 48;
pub export var amd_create: [32]u8 = .{0} ** 32;
pub export var amd_metadata_set: [288]u8 = .{0} ** 288;
pub export var amd_metadata_get: [288]u8 = .{0} ** 288;
pub export var amd_create_info: [32]u8 = .{0} ** 32;
pub export var amd_gem_op: [24]u8 = .{0} ** 24;
pub export var amd_handle_list: [16]u8 = .{0} ** 16;
pub export var amd_handle_entry: [40]u8 = .{0} ** 40;
pub export var amd_va: [64]u8 = .{0} ** 64;
pub export var amd_wait_idle: [16]u8 = .{0} ** 16;
pub export var amd_close: [8]u8 = .{0} ** 8;
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
        \\movq $5, %%rax
        \\movq %%r12, %%rdi
        \\leaq stat_buffer(%%rip), %%rsi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl stat_buffer+24(%%rip), %%eax
        \\andl $0xf000, %%eax
        \\cmpl $0x2000, %%eax
        \\jne 1f
        \\cmpq $0xe200, stat_buffer+40(%%rip)
        \\jne 1f
        \\movq $89, %%rax
        \\leaq pci_subsystem_path(%%rip), %%rdi
        \\leaq pci_attribute(%%rip), %%rsi
        \\movq $64, %%rdx
        \\syscall
        \\cmpq $19, %%rax
        \\jne 1f
        \\leaq pci_attribute(%%rip), %%rsi
        \\leaq pci_subsystem_target(%%rip), %%rdi
        \\movq $19, %%rcx
        \\repe cmpsb
        \\jne 1f
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq pci_vendor_path(%%rip), %%rsi
        \\xorq %%rdx, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r15
        \\movq $0, %%rax
        \\movq %%r15, %%rdi
        \\leaq pci_attribute(%%rip), %%rsi
        \\movq $64, %%rdx
        \\syscall
        \\cmpq $7, %%rax
        \\jne 1f
        \\cmpw $0x7830, pci_attribute(%%rip)
        \\jne 1f
        \\cmpb $10, pci_attribute+6(%%rip)
        \\jne 1f
        \\movq $3, %%rax
        \\movq %%r15, %%rdi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $257, %%rax
        \\movq $-100, %%rdi
        \\leaq pci_uevent_path(%%rip), %%rsi
        \\xorq %%rdx, %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\js 1f
        \\movq %%rax, %%r15
        \\movq $0, %%rax
        \\movq %%r15, %%rdi
        \\leaq pci_attribute(%%rip), %%rsi
        \\movq $64, %%rdx
        \\syscall
        \\cmpq $14, %%rax
        \\jle 1f
        \\leaq pci_attribute(%%rip), %%rsi
        \\leaq pci_slot_prefix(%%rip), %%rdi
        \\movq $14, %%rcx
        \\repe cmpsb
        \\jne 1f
        \\movq $3, %%rax
        \\movq %%r15, %%rdi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0406400, %%rsi
        \\leaq version(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, version(%%rip)
        \\je 4f
        \\cmpl $3, version(%%rip)
        \\jne 1f
        \\4:
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
        \\movq $0x40086409, %%rsi
        \\leaq second_destroy(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01064b3, %%rsi
        \\leaq second_map(%%rip), %%rdx
        \\syscall
        \\cmpq $-2, %%rax
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
        \\movl $1, dumb_destroy(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x40086409, %%rsi
        \\leaq dumb_destroy(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00464af, %%rsi
        \\leaq framebuffer_command(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movabsq $0x0000757067646d61, %%rax
        \\cmpq %%rax, name(%%rip)
        \\jne 3f
        \\movq $4096, amd_create(%%rip)
        \\movq $2097152, amd_create+8(%%rip)
        \\movq $2, amd_create+16(%%rip)
        \\movq $4, amd_create+24(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0206440, %%rsi
        \\leaq amd_create(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_metadata_set(%%rip)
        \\movl $1, amd_metadata_set+4(%%rip)
        \\movq $0x12, amd_metadata_set+8(%%rip)
        \\movq $0x34, amd_metadata_set+16(%%rip)
        \\movl $4, amd_metadata_set+24(%%rip)
        \\movl $0xdeadbeef, amd_metadata_set+28(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc1206446, %%rsi
        \\leaq amd_metadata_set(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_metadata_get(%%rip)
        \\movl $2, amd_metadata_get+4(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc1206446, %%rsi
        \\leaq amd_metadata_get(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $0x12, amd_metadata_get+8(%%rip)
        \\jne 1f
        \\cmpq $0x34, amd_metadata_get+16(%%rip)
        \\jne 1f
        \\cmpl $4, amd_metadata_get+24(%%rip)
        \\jne 1f
        \\cmpl $0xdeadbeef, amd_metadata_get+28(%%rip)
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_gem_op(%%rip)
        \\leaq amd_create_info(%%rip), %%rax
        \\movq %%rax, amd_gem_op+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0186450, %%rsi
        \\leaq amd_gem_op(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $4096, amd_create_info(%%rip)
        \\jne 1f
        \\cmpq $2097152, amd_create_info+8(%%rip)
        \\jne 1f
        \\cmpq $2, amd_create_info+16(%%rip)
        \\jne 1f
        \\cmpq $4, amd_create_info+24(%%rip)
        \\jne 1f
        \\leaq amd_handle_entry(%%rip), %%rax
        \\movq %%rax, amd_handle_list(%%rip)
        \\movl $1, amd_handle_list+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0106459, %%rsi
        \\leaq amd_handle_list(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, amd_handle_list+8(%%rip)
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\cmpl %%eax, amd_handle_entry(%%rip)
        \\jne 1f
        \\cmpq $4096, amd_handle_entry+8(%%rip)
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_va(%%rip)
        \\movl $1, amd_va+8(%%rip)
        \\movl $6, amd_va+12(%%rip)
        \\movabsq $0x400000000, %%rax
        \\movq %%rax, amd_va+16(%%rip)
        \\movq $4096, amd_va+32(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x40406448, %%rsi
        \\leaq amd_va(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_close(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x40086409, %%rsi
        \\leaq amd_close(%%rip), %%rdx
        \\syscall
        \\cmpq $-16, %%rax
        \\jne 1f
        \\movl $2, amd_va+8(%%rip)
        \\movl $0, amd_va+12(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x40406448, %%rsi
        \\leaq amd_va(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_wait_idle(%%rip)
        \\movq $-1, amd_wait_idle+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0106447, %%rsi
        \\leaq amd_wait_idle(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $0, amd_wait_idle+8(%%rip)
        \\jne 1f
        \\movl amd_create(%%rip), %%eax
        \\movl %%eax, amd_close(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0x40086409, %%rsi
        \\leaq amd_close(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\3:
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
        \\movq $5, %%rax
        \\movq %%r12, %%rdi
        \\leaq stat_buffer(%%rip), %%rsi
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $0xe280, stat_buffer+40(%%rip)
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc0406400, %%rsi
        \\leaq render_version(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, render_version(%%rip)
        \\je 5f
        \\cmpl $3, render_version(%%rip)
        \\jne 1f
        \\5:
        \\movq $0x13, capability(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc010640c, %%rsi
        \\leaq capability(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $1, capability+8(%%rip)
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00864bf, %%rsi
        \\leaq sync_create_signaled(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00864bf, %%rsi
        \\leaq sync_create_pending(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl sync_create_pending(%%rip), %%eax
        \\movl %%eax, sync_handles(%%rip)
        \\movl sync_create_signaled(%%rip), %%eax
        \\movl %%eax, sync_handles+4(%%rip)
        \\leaq sync_handles(%%rip), %%rax
        \\movq %%rax, sync_wait(%%rip)
        \\movl $2, sync_wait+16(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02864c3, %%rsi
        \\leaq sync_wait(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpl $1, sync_wait+24(%%rip)
        \\jne 1f
        \\leaq sync_handles+4(%%rip), %%rax
        \\movq %%rax, sync_array(%%rip)
        \\movl $1, sync_array+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01064c4, %%rsi
        \\leaq sync_array(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl $1, sync_wait+20(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02864c3, %%rsi
        \\leaq sync_wait(%%rip), %%rdx
        \\syscall
        \\cmpq $-62, %%rax
        \\jne 1f
        \\leaq sync_handles(%%rip), %%rax
        \\movq %%rax, sync_array(%%rip)
        \\movl $2, sync_array+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01064c5, %%rsi
        \\leaq sync_array(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc02864c3, %%rsi
        \\leaq sync_wait(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $0x14, capability(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc010640c, %%rsi
        \\leaq capability(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $1, capability+8(%%rip)
        \\jne 1f
        \\leaq sync_handles(%%rip), %%rax
        \\movq %%rax, timeline_array(%%rip)
        \\leaq timeline_point(%%rip), %%rax
        \\movq %%rax, timeline_array+8(%%rip)
        \\movl $1, timeline_array+16(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01864cd, %%rsi
        \\leaq timeline_array(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\leaq timeline_query_point(%%rip), %%rax
        \\movq %%rax, timeline_array+8(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc01864cb, %%rsi
        \\leaq timeline_array(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\cmpq $5, timeline_query_point(%%rip)
        \\jne 1f
        \\leaq sync_handles(%%rip), %%rax
        \\movq %%rax, timeline_wait(%%rip)
        \\leaq timeline_point(%%rip), %%rax
        \\movq %%rax, timeline_wait+8(%%rip)
        \\movl $1, timeline_wait+24(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc03064ca, %%rsi
        \\leaq timeline_wait(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movq $6, timeline_point(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc03064ca, %%rsi
        \\leaq timeline_wait(%%rip), %%rdx
        \\syscall
        \\cmpq $-62, %%rax
        \\jne 1f
        \\movl sync_handles(%%rip), %%eax
        \\movl %%eax, sync_destroy(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00864c0, %%rsi
        \\leaq sync_destroy(%%rip), %%rdx
        \\syscall
        \\testq %%rax, %%rax
        \\jne 1f
        \\movl sync_handles+4(%%rip), %%eax
        \\movl %%eax, sync_destroy(%%rip)
        \\movq $16, %%rax
        \\movq %%r12, %%rdi
        \\movq $0xc00864c0, %%rsi
        \\leaq sync_destroy(%%rip), %%rdx
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
