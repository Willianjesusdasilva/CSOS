pub export const hello_message: [21]u8 = "Hello from userspace\n".*;
pub export var hello_pointer: *const [21]u8 = &hello_message;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movl $1, %%eax
        \\movl $1, %%edi
        \\movq hello_pointer(%%rip), %%rsi
        \\movl $21, %%edx
        \\syscall
        \\movl $60, %%eax
        \\xorl %%edi, %%edi
        \\syscall
        \\ud2
    );
}
