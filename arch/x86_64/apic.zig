const apic_base_msr = 0x1b;
const expected_base = 0xfee00000;

const spurious = 0x0f0;
const timer_lvt = 0x320;
const timer_initial_count = 0x380;
const timer_divide = 0x3e0;
const id_register = 0x020;
const icr_low = 0x300;
const icr_high = 0x310;

pub fn init() !void {
    var base = readMsr(apic_base_msr);
    if ((base & 0xfffff000) != expected_base) return error.UnsupportedBase;
    base |= 1 << 11;
    writeMsr(apic_base_msr, base);

    maskLegacyPic();
    write(spurious, 0x100 | 0xff);
    write(timer_lvt, 1 << 16);
}

pub fn startPeriodicTimer() void {
    write(timer_divide, 0x3);
    write(timer_lvt, (1 << 17) | 32);
    write(timer_initial_count, 1_000_000);
}

pub fn stopTimer() void {
    write(timer_lvt, 1 << 16);
    write(timer_initial_count, 0);
}

pub fn id() u32 {
    return read(id_register) >> 24;
}

pub fn startCpu(apic_id: u32, vector: u8) void {
    write(icr_high, apic_id << 24);
    write(icr_low, 0x0000c500);
    waitForIpi();
    delay();
    write(icr_high, apic_id << 24);
    write(icr_low, 0x00004600 | @as(u32, vector));
    waitForIpi();
    delay();
    write(icr_high, apic_id << 24);
    write(icr_low, 0x00004600 | @as(u32, vector));
    waitForIpi();
}

fn write(offset: u64, value: u32) void {
    const register: *volatile u32 = @ptrFromInt(expected_base + offset);
    register.* = value;
}

fn read(offset: u64) u32 {
    const register: *volatile u32 = @ptrFromInt(expected_base + offset);
    return register.*;
}

fn waitForIpi() void {
    while ((read(icr_low) & (1 << 12)) != 0) asm volatile ("pause");
}

fn delay() void {
    var count: usize = 0;
    while (count < 1_000_000) : (count += 1) asm volatile ("pause");
}

fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr));
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))));
}

fn maskLegacyPic() void {
    out(0x21, 0xff);
    out(0xa1, 0xff);
}

fn out(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port));
}
