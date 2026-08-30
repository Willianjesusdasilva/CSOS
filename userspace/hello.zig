pub export const hello_message: [21]u8 = "Hello from userspace\n".*;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movl $1, %%eax
        \\movl $1, %%edi
        \\leaq hello_message(%%rip), %%rsi
        \\movl $21, %%edx
        \\syscall
        \\movl $60, %%eax
        \\xorl %%edi, %%edi
        \\syscall
        \\ud2
    );
}
