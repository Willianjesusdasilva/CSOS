.text
.code64
.global syscall_entry

syscall_entry:
    movq %rsp, syscall_user_rsp(%rip)
    movq syscall_kernel_rsp(%rip), %rsp
    cmpq $60, %rax
    je user_exit_trampoline
    pushq %rcx
    pushq %r11
    pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %r10
    pushq %r9
    pushq %r8
    pushq %rdi
    pushq %rsi
    pushq %rbp
    pushq %rbx
    pushq %rdx
    movq %rsp, %r11
    andq $-16, %rsp
    subq $48, %rsp
    movq %r11, 32(%rsp)
    movq %rax, %rcx
    movq 32(%r11), %rdx
    movq 24(%r11), %r8
    movq 0(%r11), %r9
    callq user_syscall_dispatch
    movq 32(%rsp), %rsp
    popq %rdx
    popq %rbx
    popq %rbp
    popq %rsi
    popq %rdi
    popq %r8
    popq %r9
    popq %r10
    popq %r12
    popq %r13
    popq %r14
    popq %r15
    popq %r11
    popq %rcx
    movq syscall_user_rsp(%rip), %rsp
    sysretq
