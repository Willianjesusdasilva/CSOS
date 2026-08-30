.text
.code64
.global syscall_entry

syscall_entry:
    movq %rsp, syscall_user_rsp(%rip)
    movq syscall_kernel_rsp(%rip), %rsp
    cmpq $60, %rax
    je .Lprocess_exit
    cmpq $231, %rax
    je .Lprocess_exit
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
    movq %rsp, %r12
    andq $-16, %rsp
    subq $64, %rsp
    movq 56(%r12), %r10
    movq %r10, 32(%rsp)
    movq 40(%r12), %r10
    movq %r10, 40(%rsp)
    movq 48(%r12), %r10
    movq %r10, 48(%rsp)
    movq %rax, %rcx
    movq 32(%r12), %rdx
    movq 24(%r12), %r8
    movq 0(%r12), %r9
    callq user_syscall_dispatch
    movq %r12, %rsp
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

.Lprocess_exit:
    movq %rdi, %rcx
    subq $32, %rsp
    callq process_exit_dispatch
    addq $32, %rsp
    jmp user_exit_trampoline
