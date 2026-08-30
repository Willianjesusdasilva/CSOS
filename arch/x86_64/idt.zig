const serial = @import("serial");

const interrupt_gate = 0x8e;
const kernel_code_selector = 0x08;

pub export var lapic_ticks: u64 = 0;
var timer_hook: ?*const fn () callconv(.c) void = null;
var external_hook: ?*const fn () callconv(.c) void = null;
var page_fault_hook: ?*const fn (u64, u64, u64) callconv(.c) bool = null;

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
    entries[48] = Entry.from(@ptrCast(&external));
    entries[128] = Entry.from(@ptrCast(&syscall));
    entries[128].attributes = 0xee;
    entries[255] = Entry.from(@ptrCast(&spurious));

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

pub fn setTimerHook(hook: ?*const fn () callconv(.c) void) void {
    timer_hook = hook;
}

pub fn setExternalHook(hook: ?*const fn () callconv(.c) void) void {
    external_hook = hook;
}

pub fn setPageFaultHook(hook: ?*const fn (u64, u64, u64) callconv(.c) bool) void {
    page_fault_hook = hook;
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
        \\movq %%cr2, %%rcx
        \\movq 64(%%rax), %%rdx
        \\movq 56(%%rax), %%r8
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
