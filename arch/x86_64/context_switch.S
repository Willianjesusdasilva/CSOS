.text
.code64
.global context_switch
context_switch:
    pushq %rbp
    pushq %rbx
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, 0(%rcx)
    fxsave64 16(%rcx)
    fxrstor64 16(%rdx)
    movq 0(%rdx), %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbx
    popq %rbp
    retq
