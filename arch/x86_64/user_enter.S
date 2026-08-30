.text
.code64
.global enter_user
.global user_exit_trampoline

enter_user:
    movq %rsp, user_kernel_rsp(%rip)
    leaq .Luser_return(%rip), %rax
    movq %rax, user_kernel_rip(%rip)
    pushq $0x1b
    pushq %rdx
    pushfq
    andq $-513, (%rsp)
    pushq $0x23
    pushq %rcx
    iretq
.Luser_return:
    retq

user_exit_trampoline:
    cli
    movq user_kernel_rsp(%rip), %rsp
    jmpq *user_kernel_rip(%rip)

.data
.p2align 3
user_kernel_rsp:
    .quad 0
user_kernel_rip:
    .quad 0
