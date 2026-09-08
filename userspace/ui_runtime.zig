pub export const ready_message: [30]u8 = "CSOS userspace UI files ready\n".*;
pub export const manifest_path = "/system/ui/interface/desktop.manifest\x00";
pub export const html_path = "/system/ui/interface/desktop.html\x00";
pub export const css_path = "/system/ui/styles/desktop.css\x00";

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov $257, %%eax
        \\mov $-100, %%edi
        \\lea manifest_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\mov $-100, %%edi
        \\lea html_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\mov $-100, %%edi
        \\lea css_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 1f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
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
