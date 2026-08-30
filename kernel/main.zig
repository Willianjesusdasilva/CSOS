const serial = @import("serial");
const gdt = @import("gdt");
const idt = @import("idt");
const apic = @import("apic");
const ioapic = @import("ioapic");
const acpi = @import("acpi");
const pci = @import("pci");
const nvme = @import("nvme");
const fat16 = @import("fat16");
const xhci = @import("xhci");
const smp = @import("smp");
const physical = @import("physical");
const paging = @import("paging");
const heap = @import("heap");
const scheduler = @import("scheduler");
const process = @import("process");
const syscalls = @import("syscalls");

var thread_a_runs: usize = 0;
var thread_b_runs: usize = 0;
var preempt_a: usize = 0;
var preempt_b: usize = 0;
var per_cpu_runs: u32 = 0;

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
    syscalls.install(gdt.privilegeStackTop());
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
        scheduler.addCpu(cpu.apic_id) catch panic("per-CPU queue setup failed");
        scheduler.enqueue(cpu.apic_id, &perCpuTask) catch panic("per-CPU enqueue failed");
    }
    smp.setSecondaryEntry(&scheduler.secondaryMain);
    for (madt.cpus[0..madt.cpu_count]) |cpu| {
        if (cpu.apic_id != bsp_id) smp.start(cpu.apic_id, &pages) catch panic("AP startup failed");
    }
    if (smp.online_aps + 1 != madt.cpu_count) panic("SMP CPU count mismatch");
    if (!scheduler.runLocal(bsp_id)) panic("BSP queue failed");
    var queue_spins: usize = 0;
    while (@atomicLoad(u32, &per_cpu_runs, .acquire) != madt.cpu_count and queue_spins < 50_000_000) : (queue_spins += 1) {
        asm volatile ("pause");
    }
    if (@atomicLoad(u32, &per_cpu_runs, .acquire) != madt.cpu_count) panic("per-CPU queues failed");
    scheduler.stopSecondaryWorkers();
    serial.write("SMP ready\n");

    var kernel_heap = heap.Heap.init(&pages, 16) catch panic("heap setup failed");
    const first = kernel_heap.allocate(31, 16) orelse panic("heap allocation failed");
    const second = kernel_heap.allocate(4096, 4096) orelse panic("aligned heap allocation failed");
    if ((@intFromPtr(first.ptr) & 15) != 0 or (@intFromPtr(second.ptr) & 4095) != 0) panic("heap alignment failed");
    @memset(first, 0xa5);
    @memset(second, 0x5a);
    serial.write("heap ready\n");

    scheduler.spawn(&threadA, &pages) catch panic("thread A creation failed");
    scheduler.spawn(&threadB, &pages) catch panic("thread B creation failed");
    scheduler.run();
    if (thread_a_runs != 3 or thread_b_runs != 5) panic("context switch failed");
    serial.write("scheduler context switch ready\n");

    scheduler.spawn(&preemptThreadA, &pages) catch panic("preempt thread A creation failed");
    scheduler.spawn(&preemptThreadB, &pages) catch panic("preempt thread B creation failed");
    scheduler.enablePreemption();
    apic.startPeriodicTimer();
    asm volatile ("sti");
    scheduler.run();
    asm volatile ("cli");
    apic.stopTimer();
    scheduler.disablePreemption();
    if (preempt_a != 2 or preempt_b != 2) panic("timer preemption failed");
    serial.write("scheduler preemption ready\n");

    const echo_arguments = [_][]const u8{ "/bin/busybox", "echo", "BusyBox userspace ready" };
    process.runBusyBox(mapper.root, &pages, &echo_arguments) catch panic("BusyBox echo failed");
    mapper.activate();
    const ls_arguments = [_][]const u8{ "/bin/busybox", "ls", "/" };
    process.runBusyBox(mapper.root, &pages, &ls_arguments) catch panic("BusyBox ls failed");
    mapper.activate();
    const cat_arguments = [_][]const u8{ "/bin/busybox", "cat", "/hello.txt" };
    process.runBusyBox(mapper.root, &pages, &cat_arguments) catch panic("BusyBox cat failed");
    mapper.activate();
    const shell_arguments = [_][]const u8{ "/bin/busybox", "sh", "-c", "echo BusyBox shell ready" };
    process.runBusyBox(mapper.root, &pages, &shell_arguments) catch panic("BusyBox sh failed");
    mapper.activate();
    serial.write("BusyBox applets returned\n");

    const inventory = pci.Inventory.scan();
    if (inventory.count == 0) panic("PCI enumeration failed");
    if (inventory.findClass(0x06, 0x01) == null) panic("PCI ISA bridge missing");
    serial.write("PCI devices: ");
    serial.writeDecimal(inventory.count);
    serial.write("\n");
    const nvme_device = inventory.findClass(0x01, 0x08) orelse panic("NVMe controller missing");
    const nvme_bar = pci.barAddress(nvme_device, 0) orelse panic("NVMe BAR missing");
    mapper.mapIdentity(nvme_bar, 0x4000) catch panic("NVMe MMIO mapping failed");
    mapper.activate();
    var storage = nvme.Controller.init(nvme_device, &pages) catch panic("NVMe setup failed");
    const namespaces = storage.identify(&pages) catch panic("NVMe identify failed");
    serial.write("NVMe namespaces: ");
    serial.writeDecimal(namespaces);
    serial.write("\n");
    storage.initIo(&pages) catch panic("NVMe I/O queues failed");
    const io_buffer = pages.allocate(1) orelse panic("NVMe I/O buffer failed");
    const io_bytes: [*]u8 = @ptrFromInt(io_buffer);
    var io_index: usize = 0;
    while (io_index < storage.block_size) : (io_index += 1) io_bytes[io_index] = @truncate(io_index ^ 0xa5);
    storage.writeBlock(1000, io_buffer) catch panic("NVMe write failed");
    @memset(io_bytes[0..storage.block_size], 0);
    storage.readBlock(1000, io_buffer) catch panic("NVMe read failed");
    io_index = 0;
    while (io_index < storage.block_size) : (io_index += 1) {
        if (io_bytes[io_index] != @as(u8, @truncate(io_index ^ 0xa5))) panic("NVMe data mismatch");
    }
    serial.write("NVMe read/write ready\n");
    var volume = fat16.Volume.mount(&storage, &pages) catch panic("FAT16 mount failed");
    var file_data: [128]u8 = undefined;
    const file_size = volume.readRootFile("SYSTEM  TXT", &file_data) catch panic("FAT16 read failed");
    serial.write(file_data[0..file_size]);
    serial.write("CSOS M10 ready\n");
    const xhci_device = inventory.findClassInterface(0x0c, 0x03, 0x30) orelse panic("xHCI controller missing");
    const xhci_bar = pci.barAddress(xhci_device, 0) orelse panic("xHCI BAR missing");
    mapper.mapIdentity(xhci_bar, 0x10000) catch panic("xHCI MMIO mapping failed");
    mapper.activate();
    var usb = xhci.Controller.init(xhci_device, &pages) catch panic("xHCI setup failed");
    serial.write("xHCI ports connected: ");
    serial.writeDecimal(usb.connected_ports);
    serial.write("\n");
    if (usb.connected_ports < 2) panic("USB HID devices missing");
    serial.write("xHCI controller ready\n");
    const hid = usb.enumerateHid(&pages) catch panic("USB enumeration failed");
    serial.write("USB keyboards: "); serial.writeDecimal(hid.keyboards);
    serial.write(" mice: "); serial.writeDecimal(hid.mice); serial.write("\n");
    if (hid.keyboards == 0 or hid.mice == 0) panic("USB HID descriptors missing");

    drawBootMarker(info.framebuffer);
    serial.write("framebuffer ready\n");

    while (true) asm volatile ("cli; hlt");
}

fn threadA() void {
    var iteration: usize = 0;
    while (iteration < 3) : (iteration += 1) {
        thread_a_runs += 1;
        scheduler.yieldNow();
    }
}

fn threadB() void {
    var iteration: usize = 0;
    while (iteration < 5) : (iteration += 1) {
        thread_b_runs += 1;
        scheduler.yieldNow();
    }
}

fn preemptThreadA() void {
    preempt_a = 1;
    while (preempt_b == 0) asm volatile ("pause" ::: .{ .memory = true });
    preempt_a = 2;
}

fn preemptThreadB() void {
    preempt_b = 1;
    while (preempt_a == 0) asm volatile ("pause" ::: .{ .memory = true });
    preempt_b = 2;
}

fn perCpuTask() void {
    _ = @atomicRmw(u32, &per_cpu_runs, .Add, 1, .release);
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
