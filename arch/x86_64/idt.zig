const serial = @import("serial");

const interrupt_gate = 0x8e;
const kernel_code_selector = 0x08;

pub export var lapic_ticks: u64 = 0;
var timer_hook: ?*const fn () callconv(.c) void = null;
var external_hook: ?*const fn () callconv(.c) void = null;
var usb_hook: ?*const fn () callconv(.c) void = null;
var gpu_hook: ?*const fn () callconv(.c) void = null;
var page_fault_hook: ?*const fn (u64, u64, u64) callconv(.c) bool = null;
var user_timer_hook: ?*const fn (*anyopaque, *anyopaque) callconv(.c) bool = null;

const Entry = packed struct {
    offset_low: u16 = 0,
    selector: u16 = kernel_code_selector,
    ist: u8 = 0,
    attributes: u8 = interrupt_gate,
    offset_middle: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,

    fn from(handler: *const anyopaque) Entry {
        const address = @intFromPtr(handler);
        return .{
            .offset_low = @truncate(address),
            .offset_middle = @truncate(address >> 16),
            .offset_high = @truncate(address >> 32),
        };
    }
};

const Register = packed struct {
    limit: u16,
    base: u64,
};

var entries: [256]Entry align(16) = undefined;
pub fn install() void {
    for (&entries) |*entry| entry.* = Entry.from(@ptrCast(&unexpected));
    inline for ([_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 }) |vector| {
        entries[vector] = Entry.from(@ptrCast(&unexpectedWithError));
    }
    entries[3] = Entry.from(@ptrCast(&breakpoint));
    entries[13] = Entry.from(@ptrCast(&generalProtection));
    entries[14] = Entry.from(@ptrCast(&pageFault));
    entries[32] = Entry.from(@ptrCast(&timer));
    entries[32].ist = 1;
    entries[48] = Entry.from(@ptrCast(&external));
    entries[49] = Entry.from(@ptrCast(&usbInterrupt));
    entries[50] = Entry.from(@ptrCast(&gpuInterrupt));
    entries[128] = Entry.from(@ptrCast(&syscall));
    entries[128].attributes = 0xee;
    entries[255] = Entry.from(@ptrCast(&spurious));

    load();
}

pub fn load() void {
    const register = Register{
        .limit = @sizeOf(@TypeOf(entries)) - 1,
        .base = @intFromPtr(&entries),
    };
    asm volatile ("lidt (%[register])"
        :
        : [register] "r" (&register),
        : .{ .memory = true });
}

pub fn verifyBreakpoint() bool {
    asm volatile ("int3");
    return true;
}

pub fn timerTicks() u64 {
    return @atomicLoad(u64, &lapic_ticks, .acquire);
}

/// Physical storage occupied by the IDT. The table is static kernel memory
/// and must not be reused by userspace image/page-table allocations.
pub fn reservedMemoryRange() struct { address: u64, pages: u64 } {
    const address = @intFromPtr(&entries) & ~@as(usize, 4095);
    return .{ .address = address, .pages = 2 };
}

pub fn setTimerHook(hook: ?*const fn () callconv(.c) void) void {
    timer_hook = hook;
}

pub fn setExternalHook(hook: ?*const fn () callconv(.c) void) void {
    external_hook = hook;
}

pub fn setUsbHook(hook: ?*const fn () callconv(.c) void) void {
    usb_hook = hook;
}

pub fn setGpuHook(hook: ?*const fn () callconv(.c) void) void { gpu_hook = hook; }

pub fn setPageFaultHook(hook: ?*const fn (u64, u64, u64) callconv(.c) bool) void {
    page_fault_hook = hook;
}

pub fn setUserTimerHook(hook: ?*const fn (*anyopaque, *anyopaque) callconv(.c) bool) void {
    user_timer_hook = hook;
}

export fn user_timer_dispatch_bridge(registers: *anyopaque, frame: *anyopaque) callconv(.c) bool {
    if (user_timer_hook) |hook| return hook(registers, frame);
    return false;
}

fn breakpoint() callconv(.naked) void {
    asm volatile ("iretq");
}

fn unexpected() callconv(.naked) void {
    asm volatile ("movw $0x3f8, %dx; movb $'E', %al; outb %al, %dx; cli; 1: hlt; jmp 1b");
}

fn unexpectedWithError() callconv(.naked) void {
    asm volatile ("movw $0x3f8, %dx; movb $'E', %al; outb %al, %dx; cli; 1: hlt; jmp 1b");
}

fn generalProtection() callconv(.naked) void {
    asm volatile ("movw $0x3f8, %dx; movb $'G', %al; outb %al, %dx; cli; 1: hlt; jmp 1b");
}

fn pageFault() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq %%rsp, %%rax
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%rax, 32(%%rsp)
        \\movq %%cr2, %%rdi
        // A page fault pushes error-code, RIP, CS, RFLAGS, RSP and SS;
        // after the seven saved registers the error code is at +56 and RIP
        // at +64.  Keep the hook arguments in (address, RIP, error-code)
        // order so lazy MAP_NORESERVE faults can be resolved correctly.
        \\movq 64(%%rax), %%rsi
        \\movq 56(%%rax), %%rdx
        \\callq page_fault_dispatch
        \\testb %%al, %%al
        \\jz 1f
        \\movq 32(%%rsp), %%rsp
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\addq $8, %%rsp
        \\iretq
        \\1:
        \\cli
        \\2: hlt
        \\jmp 2b
    );
}

export fn page_fault_dispatch(address: u64, instruction: u64, code: u64) callconv(.c) bool {
    if (page_fault_hook) |hook| if (hook(address, instruction, code)) return true;
    const lapic_id: *volatile u32 = @ptrFromInt(0xfee00020);
    serial.write("cpu ");
    serial.writeDecimal(lapic_id.* >> 24);
    serial.write(" ");
    serial.write("page fault at ");
    serial.writeDecimal(address);
    serial.write(" rip ");
    serial.writeDecimal(instruction);
    serial.write(" code ");
    serial.writeDecimal(code);
    serial.write("\n");
    return false;
}

fn timer() callconv(.naked) void {
    asm volatile (
        // A ring-3 timer frame is RIP, CS, RFLAGS, RSP, SS. Preserve all
        // general registers before invoking the optional scheduler hook.
        \\cmpw $0x23, 8(%%rsp)
        \\jne .Lkernel_timer
        \\pushq %%r15
        \\pushq %%r14
        \\pushq %%r13
        \\pushq %%r12
        \\pushq %%r11
        \\pushq %%r10
        \\pushq %%r9
        \\pushq %%r8
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%rdx
        \\pushq %%rcx
        \\pushq %%rax
        \\incq lapic_ticks(%%rip)
        \\movq %%rsp, %%r11
        \\leaq 120(%%r11), %%r10
        \\movq %%r11, %%rcx
        \\movq %%r10, %%rdx
        \\callq user_timer_dispatch_bridge
        // Acknowledge the LAPIC while the saved register block is still on
        // the stack; doing this after the pops would leak the MMIO address in
        // RAX back into the interrupted userspace process.
        \\movabsq $0xfee000b0, %%rax
        \\movl $0, (%%rax)
        // QEMU may leave the local timer count exhausted after an IST/IRET
        // transition. Reload it explicitly so userspace keeps receiving
        // preemption ticks even when the periodic LVT bit is lost.
        \\movabsq $0xfee00380, %%rax
        \\movl $100000, (%%rax)
        \\movabsq $0xfee00320, %%rax
        \\movl $(1 << 17) | 32, (%%rax)
        \\popq %%rax
        \\popq %%rcx
        \\popq %%rdx
        \\popq %%rbx
        \\popq %%rbp
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%r8
        \\popq %%r9
        \\popq %%r10
        \\popq %%r11
        \\popq %%r12
        \\popq %%r13
        \\popq %%r14
        \\popq %%r15
        \\iretq
        \\.Lkernel_timer:
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq %%rsp, %%rax
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%rax, 32(%%rsp)
        \\callq timer_dispatch
        \\movq 32(%%rsp), %%rsp
        \\incq lapic_ticks(%%rip)
        \\movabsq $0xfee000b0, %%rax
        \\movl $0, (%%rax)
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\iretq
    );
}

export fn timer_dispatch() callconv(.c) void {
    if (timer_hook) |hook| hook();
}

fn external() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq %%rsp, %%rax
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%rax, 32(%%rsp)
        \\callq external_dispatch
        \\movq 32(%%rsp), %%rsp
        \\movabsq $0xfee000b0, %%rax
        \\movl $0, (%%rax)
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\iretq
    );
}

export fn external_dispatch() callconv(.c) void {
    if (external_hook) |hook| hook();
}

fn usbInterrupt() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq %%rsp, %%rax
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%rax, 32(%%rsp)
        \\callq usb_interrupt_dispatch
        \\movq 32(%%rsp), %%rsp
        \\movabsq $0xfee000b0, %%rax
        \\movl $0, (%%rax)
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\iretq
    );
}

export fn usb_interrupt_dispatch() callconv(.c) void {
    if (usb_hook) |hook| hook();
}

fn gpuInterrupt() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq %%rsp, %%rax
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%rax, 32(%%rsp)
        \\callq gpu_interrupt_dispatch
        \\movq 32(%%rsp), %%rsp
        \\movabsq $0xfee000b0, %%rax
        \\movl $0, (%%rax)
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\iretq
    );
}

export fn gpu_interrupt_dispatch() callconv(.c) void {
    if (gpu_hook) |hook| hook();
}

fn spurious() callconv(.naked) void {
    asm volatile ("iretq");
}

fn syscall() callconv(.naked) void {
    asm volatile (
        \\cmpq $60, %%rax
        \\je user_exit_trampoline
        \\pushq %%r15
        \\pushq %%r14
        \\pushq %%r13
        \\pushq %%r12
        \\pushq %%r11
        \\pushq %%r10
        \\pushq %%r9
        \\pushq %%r8
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%rdx
        \\pushq %%rcx
        \\movq %%rsp, %%r11
        \\andq $-16, %%rsp
        \\subq $48, %%rsp
        \\movq %%r11, 32(%%rsp)
        \\movq %%rax, %%rcx
        \\movq 40(%%r11), %%rdx
        \\movq 32(%%r11), %%r8
        \\movq 8(%%r11), %%r9
        \\callq user_syscall_dispatch
        \\movq 32(%%rsp), %%rsp
        \\popq %%rcx
        \\popq %%rdx
        \\popq %%rbx
        \\popq %%rbp
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%r8
        \\popq %%r9
        \\popq %%r10
        \\popq %%r11
        \\popq %%r12
        \\popq %%r13
        \\popq %%r14
        \\popq %%r15
        \\iretq
    );
}
