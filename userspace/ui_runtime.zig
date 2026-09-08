pub export const ready_message: [30]u8 = "CSOS userspace UI files ready\n".*;
pub export var hello_frame: [23]u8 = ([_]u8{ 1, 23 } ++ "UI_HELLO file-backed\n").*;
pub export var create_frame: [19]u8 = ([_]u8{ 2, 19, 0x80, 0x02, 0xe0, 0x01, 12 } ++ "HTML DESKTOP").*;
pub export var present_frame: [22]u8 = .{ 1, 22, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x02, 0xe0, 0x01 };
pub export var pixel_frame: [10]u8 = .{ 12, 10, 1, 0, 0, 0, 0x20, 0x40, 0x80, 0xff };
pub export const manifest_path: [38:0]u8 = "/system/ui/interface/desktop.manifest\x00".*;
pub export const html_path: [34:0]u8 = "/system/ui/interface/desktop.html\x00".*;
pub export const css_path: [30:0]u8 = "/system/ui/styles/desktop.css\x00".*;
pub export const wallpaper_path: [36:0]u8 = "/system/ui/interface/wallpaper.html\x00".*;
pub export const topbar_path: [33:0]u8 = "/system/ui/interface/topbar.html\x00".*;
pub export const sidebar_path: [34:0]u8 = "/system/ui/interface/sidebar.html\x00".*;
pub export const media_path: [32:0]u8 = "/system/ui/interface/media.html\x00".*;
pub export const widgets_path: [34:0]u8 = "/system/ui/interface/widgets.html\x00".*;
pub export const notifications_path: [40:0]u8 = "/system/ui/interface/notifications.html\x00".*;
pub export const launcher_path: [35:0]u8 = "/system/ui/interface/launcher.html\x00".*;
pub export const terminal_path: [35:0]u8 = "/system/ui/interface/terminal.html\x00".*;
pub export const status_path: [33:0]u8 = "/system/ui/interface/status.html\x00".*;
pub export const dock_path: [31:0]u8 = "/system/ui/interface/dock.html\x00".*;
pub export const alt_tab_path: [34:0]u8 = "/system/ui/interface/alt-tab.html\x00".*;
pub export const cpu_provider_path: [31:0]u8 = "/system/ui/providers/CPU_USAGE\x00".*;
pub export const script_path: [30:0]u8 = "/system/ui/scripts/open_files\x00".*;

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
        \\js 11f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea html_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 12f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea css_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 13f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea wallpaper_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 14f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea topbar_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 15f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea sidebar_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 16f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea media_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 17f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea widgets_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 18f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea notifications_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 19f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea launcher_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 20f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea cpu_provider_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 21f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea script_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 22f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea terminal_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 23f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea status_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 24f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea dock_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 25f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $257, %%eax
        \\movq $-100, %%rdi
        \\lea alt_tab_path(%%rip), %%rsi
        \\xor %%edx, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 26f
        \\movl %%eax, %%edi
        \\mov $3, %%eax
        \\syscall
        \\mov $451, %%eax
        \\mov $1, %%edi
        \\lea hello_frame(%%rip), %%rsi
        \\mov $23, %%edx
        \\syscall
        \\mov $451, %%eax
        \\mov $1, %%edi
        \\lea create_frame(%%rip), %%rsi
        \\mov $19, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 42f
        \\mov $451, %%eax
        \\mov $1, %%edi
        \\lea present_frame(%%rip), %%rsi
        \\mov $22, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 43f
        \\mov $451, %%eax
        \\mov $1, %%edi
        \\lea pixel_frame(%%rip), %%rsi
        \\mov $10, %%edx
        \\syscall
        \\test %%rax, %%rax
        \\js 44f
        \\mov $1, %%eax
        \\mov $1, %%edi
        \\lea ready_message(%%rip), %%rsi
        \\mov $30, %%edx
        \\syscall
        \\xor %%edi, %%edi
        \\mov $60, %%eax
        \\syscall
        \\jmp 1f
        \\42:
        \\mov $60, %%eax
        \\mov $42, %%edi
        \\syscall
        \\43:
        \\mov $60, %%eax
        \\mov $43, %%edi
        \\syscall
        \\44:
        \\mov $60, %%eax
        \\mov $44, %%edi
        \\syscall
        \\11:
        \\mov $60, %%eax
        \\mov $11, %%edi
        \\syscall
        \\12:
        \\mov $60, %%eax
        \\mov $12, %%edi
        \\syscall
        \\13:
        \\mov $60, %%eax
        \\mov $13, %%edi
        \\syscall
        \\14:
        \\mov $60, %%eax
        \\mov $14, %%edi
        \\syscall
        \\15:
        \\mov $60, %%eax
        \\mov $15, %%edi
        \\syscall
        \\16:
        \\mov $60, %%eax
        \\mov $16, %%edi
        \\syscall
        \\17:
        \\mov $60, %%eax
        \\mov $17, %%edi
        \\syscall
        \\18:
        \\mov $60, %%eax
        \\mov $18, %%edi
        \\syscall
        \\19:
        \\mov $60, %%eax
        \\mov $19, %%edi
        \\syscall
        \\20:
        \\mov $60, %%eax
        \\mov $20, %%edi
        \\syscall
        \\21:
        \\mov $60, %%eax
        \\mov $21, %%edi
        \\syscall
        \\22:
        \\mov $60, %%eax
        \\mov $22, %%edi
        \\syscall
        \\23:
        \\mov $60, %%eax
        \\mov $23, %%edi
        \\syscall
        \\24:
        \\mov $60, %%eax
        \\mov $24, %%edi
        \\syscall
        \\25:
        \\mov $60, %%eax
        \\mov $25, %%edi
        \\syscall
        \\26:
        \\mov $60, %%eax
        \\mov $26, %%edi
        \\syscall
        \\1:
        \\mov $60, %%eax
        \\mov $1, %%edi
        \\syscall
        \\ud2
    );
}
