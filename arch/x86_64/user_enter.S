.text
.code64
.global enter_user
.global user_exit_trampoline

enter_user:
    pushq %rbp
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
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
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbx
    popq %rbp
    jmpq *user_kernel_rip(%rip)

.data
.p2align 3
user_kernel_rsp:
    .quad 0
user_kernel_rip:
    .quad 0
