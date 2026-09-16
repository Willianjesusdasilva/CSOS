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
    // Keep timer interrupts enabled in ring 3.  The userspace scheduler uses
    // the APIC tick to preempt WebKit spin loops; clearing IF here made every
    // userspace process non-preemptible.
    orq $0x200, (%rsp)
    pushq $0x23
    pushq %rcx
    iretq
.Luser_return:
    retq

// Resume a userspace syscall frame after a nested process child has exited.
// The normal syscall return path cannot be used here because the child exec
// runs a nested loader loop and returns to Zig instead of the parent's entry
// stack.  Preserve the kernel caller context exactly like enter_user, then
// restore the complete saved SYSRET register frame.
.global resume_user_frame
resume_user_frame:
    // The kernel target uses the MS x64 C ABI: RCX=frame, RDX=stack,
    // R8=syscall result.
    movq %rdx, resume_user_stack(%rip)
    pushq %rbp
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, user_kernel_rsp(%rip)
    leaq .Luser_return(%rip), %r11
    movq %r11, user_kernel_rip(%rip)
    movq %r8, %rax
    movq %rcx, %r12
    movq 0(%r12), %rcx
    movq 8(%r12), %r11
    movq 16(%r12), %r15
    movq 24(%r12), %r14
    movq 32(%r12), %r13
    movq 48(%r12), %r10
    movq 56(%r12), %r9
    movq 64(%r12), %r8
    movq 72(%r12), %rdi
    movq 80(%r12), %rsi
    movq 88(%r12), %rbp
    movq 96(%r12), %rbx
    movq 104(%r12), %rdx
    movq 40(%r12), %r12
    // RAX remains the syscall result; restore the saved userspace stack.
    movq resume_user_stack(%rip), %rsp
    sysretq

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
resume_user_stack:
    .quad 0
