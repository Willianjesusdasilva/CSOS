const serial = @import("serial");
const gdt = @import("gdt");
const idt = @import("idt");
const apic = @import("apic");
const ioapic = @import("ioapic");
const acpi = @import("acpi");
const smp = @import("smp");
const physical = @import("physical");
const paging = @import("paging");
const heap = @import("heap");

pub const BootInfo = struct {
    framebuffer: Framebuffer,
    memory_map: [*]align(8) u8,
    memory_map_len: usize,
    memory_descriptor_size: usize,
    rsdp: u64,
};

pub const Framebuffer = struct {
    base: u64,
    size: usize,
    width: u32,
    height: u32,
    stride: u32,
    pixel_format: u32,
};

pub fn start(info: BootInfo) noreturn {
    serial.write("kernel entry\n");
    const madt = acpi.findMadt(info.rsdp) catch panic("ACPI MADT invalid");
    if (madt.cpu_count == 0 or madt.ioapic_count == 0) panic("ACPI topology missing");
    serial.write("ACPI MADT ready\n");
    for (madt.ioapics[0..madt.ioapic_count]) |controller| {
        ioapic.init(controller.address) catch panic("IOAPIC setup failed");
    }
    serial.write("IOAPIC ready\n");
    gdt.install();
    serial.write("GDT ready\n");
    idt.install();
    if (!idt.verifyBreakpoint()) panic("breakpoint handler failed");
    serial.write("IDT ready\n");
    apic.init() catch panic("local APIC setup failed");
    apic.startPeriodicTimer();
    asm volatile ("sti; hlt; cli");
    apic.stopTimer();
    if (idt.timerTicks() == 0) panic("APIC timer failed");
    serial.write("APIC timer ready\n");
    if (info.memory_map_len == 0 or info.memory_descriptor_size == 0) panic("empty memory map");
    var pages = physical.Allocator.init(info.memory_map, info.memory_map_len, info.memory_descriptor_size);
    serial.write("physical allocator ready\n");

    var mapper = paging.Mapper.init(&pages, info.framebuffer.base, info.framebuffer.size) catch panic("paging setup failed");
    mapper.activate();
    serial.write("paging ready\n");

    smp.prepare(mapper.root) catch panic("SMP trampoline failed");
    const bsp_id = apic.id();
    for (madt.cpus[0..madt.cpu_count]) |cpu| {
        if (cpu.apic_id != bsp_id) smp.start(cpu.apic_id, &pages) catch panic("AP startup failed");
    }
    if (smp.online_aps + 1 != madt.cpu_count) panic("SMP CPU count mismatch");
    serial.write("SMP ready\n");

    var kernel_heap = heap.Heap.init(&pages, 16) catch panic("heap setup failed");
    const first = kernel_heap.allocate(31, 16) orelse panic("heap allocation failed");
    const second = kernel_heap.allocate(4096, 4096) orelse panic("aligned heap allocation failed");
    if ((@intFromPtr(first.ptr) & 15) != 0 or (@intFromPtr(second.ptr) & 4095) != 0) panic("heap alignment failed");
    @memset(first, 0xa5);
    @memset(second, 0x5a);
    serial.write("heap ready\n");

    drawBootMarker(info.framebuffer);
    serial.write("framebuffer ready\n");
    serial.write("CSOS M3 ready\n");

    while (true) asm volatile ("cli; hlt");
}

pub fn panic(message: []const u8) noreturn {
    serial.write("kernel panic: ");
    serial.write(message);
    serial.write("\n");
    while (true) asm volatile ("cli; hlt");
}

fn drawBootMarker(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.size < 4) panic("invalid framebuffer");
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const rows = @min(framebuffer.height, 32);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = if (framebuffer.pixel_format == 0) 0x0000a040 else 0x0040a000;
        }
    }
}
