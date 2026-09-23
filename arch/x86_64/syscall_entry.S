.text
.code64
.global syscall_entry

syscall_entry:
    movq %rsp, syscall_user_rsp(%rip)
    movq syscall_kernel_rsp(%rip), %rsp
    cmpb $0, user_threads_enabled(%rip)
    jne .Ldispatch
    cmpq $60, %rax
    je .Lprocess_exit
    cmpq $231, %rax
    je .Lprocess_exit
    cmpq $24, %rax
    je .Lprocess_pause
.Ldispatch:
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
    // The syscall dispatcher is Zig code and may use XMM registers while
    // servicing WebKit futex/mmap/poll calls. Preserve the interrupted
    // userspace SIMD state across that call; user_thread_resume then captures
    // the restored state before selecting the next thread.
    subq $640, %rsp
    fxsave64 128(%rsp)
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
    movq %rax, %rdx
    fxrstor64 128(%rsp)
    movq %r12, %rcx
    callq user_thread_resume
    cmpb $0, exec_pause_requested(%rip)
    jne .Lexec_pause
    cmpb $0, user_threads_done(%rip)
    jne user_exit_trampoline
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

.Lexec_pause:
    // syscall_entry's saved register block is ordered from the final push:
    // RDX..R11,RCX.  The paused instruction is the original RCX/RIP at
    // offset 104; offset 0 is merely the syscall's RDX argument.
    movq 104(%r12), %rcx
    movq syscall_user_rsp(%rip), %rdx
    subq $32, %rsp
    callq process_pause_dispatch
    addq $32, %rsp
    jmp user_exit_trampoline

.Lprocess_exit:
    movq %rdi, %rcx
    subq $32, %rsp
    callq process_exit_dispatch
    addq $32, %rsp
    jmp user_exit_trampoline

.Lprocess_pause:
    movq syscall_user_rsp(%rip), %rdx
    subq $32, %rsp
    callq process_pause_dispatch
    addq $32, %rsp
    jmp user_exit_trampoline
