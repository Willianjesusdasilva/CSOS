.section .text.ap_trampoline,"xr"
.code16
.p2align 4
.global ap_trampoline_start
.global ap_trampoline_end
.global ap_trampoline_cr3
.global ap_trampoline_stack
.global ap_trampoline_entry

ap_trampoline_start:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    lgdtl 0x8000 + (ap_gdt_register - ap_trampoline_start)

    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4
    movl 0x8000 + (ap_trampoline_cr3 - ap_trampoline_start), %eax
    movl %eax, %cr3

    movl $0xc0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    movl %cr0, %eax
    orl $0x80000001, %eax
    movl %eax, %cr0
    ljmpl $0x08, $(0x8000 + ap_long_mode - ap_trampoline_start)

.code64
ap_long_mode:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movq 0x8000 + (ap_trampoline_stack - ap_trampoline_start), %rsp
    movq 0x8000 + (ap_trampoline_entry - ap_trampoline_start), %rax
    subq $32, %rsp
    callq *%rax
1:
    cli
    hlt
    jmp 1b

.p2align 3
ap_gdt:
    .quad 0
    .quad 0x00af9a000000ffff
    .quad 0x00cf92000000ffff
ap_gdt_end:
ap_gdt_register:
    .word ap_gdt_end - ap_gdt - 1
    .long 0x8000 + (ap_gdt - ap_trampoline_start)

.p2align 3
ap_trampoline_cr3:
    .quad 0
ap_trampoline_stack:
    .quad 0
ap_trampoline_entry:
    .quad 0
ap_trampoline_end:
