pub export const ready_message: [30]u8 = "CSOS userspace UI files ready\n".*;
pub export const hello_frame = [_]u8{ 1, 21 } ++ "UI_HELLO file-backed\n";
pub export const create_frame = [_]u8{ 2, 19, 0x80, 0x02, 0xe0, 0x01, 12 } ++ "HTML DESKTOP";
pub export const present_frame = [_]u8{ 1, 22, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x02, 0xe0, 0x01 };
pub export const pixel_frame = [_]u8{ 12, 10, 1, 0, 0, 0, 0x20, 0x40, 0x80, 0xff };
pub export const manifest_path = "/system/ui/interface/desktop.manifest\x00";
pub export const html_path = "/system/ui/interface/desktop.html\x00";
pub export const css_path = "/system/ui/styles/desktop.css\x00";

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov $450, %%eax
        \\syscall
        \\movl %%eax, %%r12d
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea manifest_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea html_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea css_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $451, %%eax
        \\movl %%r12d, %%edi
        \\lea hello_frame(%%rip), %%rsi
        \\mov $21, %%edx
        \\syscall
        \\mov $451, %%eax
        \\movl %%r12d, %%edi
        \\lea create_frame(%%rip), %%rsi
        \\mov $19, %%edx
        \\syscall
        \\mov $451, %%eax
        \\movl %%r12d, %%edi
        \\lea present_frame(%%rip), %%rsi
        \\mov $22, %%edx
        \\syscall
        \\mov $451, %%eax
        \\movl %%r12d, %%edi
        \\lea pixel_frame(%%rip), %%rsi
        \\mov $10, %%edx
        \\syscall
        \\mov $1, %%eax
        \\mov $1, %%edi
        \\lea ready_message(%%rip), %%rsi
        \\mov $30, %%edx
        \\syscall
        \\xor %%edi, %%edi
        \\mov $60, %%eax
        \\syscall
        \\1:
        \\mov $60, %%eax
        \\mov $1, %%edi
        \\syscall
        \\ud2
    );
}
