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
const display = @import("display");
const e1000 = @import("e1000");
const net = @import("net");
const smp = @import("smp");
const physical = @import("physical");
const paging = @import("paging");
const heap = @import("heap");
const scheduler = @import("scheduler");
const process = @import("process");
const syscalls = @import("syscalls");
const vfs = @import("vfs");

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

pub const Framebuffer = display.Framebuffer;

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
    const display_device = inventory.findClass(0x03, 0x00) orelse
        inventory.findClass(0x03, 0x80) orelse panic("display adapter missing");
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
    const state = "persistent CSOS state\n" ** 150;
    volume.writeRootFile("STATE   TXT", state) catch panic("FAT16 write failed");
    var state_readback: [state.len]u8 = undefined;
    const state_size = volume.readRootFile("STATE   TXT", &state_readback) catch panic("FAT16 write verification failed");
    if (state_size != state.len or !equalBytes(state, &state_readback)) panic("FAT16 data mismatch");
    serial.write("FAT16 write ready\n");
    vfs.mount(&volume);
    const persist_arguments = [_][]const u8{ "/bin/busybox", "sh", "-c", "echo userspace-persisted > /user.txt" };
    process.runBusyBox(mapper.root, &pages, &persist_arguments) catch panic("userspace filesystem failed");
    mapper.activate();
    var persisted: [64]u8 = undefined;
    const persisted_size = volume.readRootFile("USER    TXT", &persisted) catch panic("userspace file missing");
    if (!equalBytes(persisted[0..persisted_size], "userspace-persisted\n")) panic("userspace file mismatch");
    serial.write(persisted[0..persisted_size]);
    serial.write("userspace filesystem ready\n");
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
    var hid = usb.enumerateHid(&pages) catch |err| switch (err) {
        error.EnableSlotFailed => panic("USB Enable Slot failed"),
        error.AddressDeviceFailed => panic("USB Address Device failed"),
        error.ConfigurationDescriptorFailed => panic("USB configuration descriptor failed"),
        else => panic("USB enumeration failed"),
    };
    serial.write("USB keyboards: "); serial.writeDecimal(hid.keyboards);
    serial.write(" mice: "); serial.writeDecimal(hid.mice); serial.write("\n");
    if (hid.keyboards == 0 or hid.mice == 0) panic("USB HID descriptors missing");
    serial.write("USB HID endpoints armed\n");
    serial.write("CSOS M11 ready\n");
    const audio_info = usb.enumerateAudio(&pages) catch panic("USB audio discovery failed");
    serial.write("USB audio interfaces: ");
    serial.writeDecimal(audio_info.interfaces);
    serial.write(" playback endpoints: ");
    serial.writeDecimal(audio_info.playback_endpoints);
    serial.write("\n");
    serial.write("CSOS M13 audio discovery ready\n");
    if (usb.audioReady()) serial.write("CSOS M13 audio stream candidate ready\n");
    if (audio_info.playback_endpoints != 0) serial.write("CSOS M13 playback format discovery ready\n");
    if (usb.audioReady()) serial.write("CSOS M13 audio endpoint ready\n");
    if (usb.audioReady()) {
        usb.audioStartDiscovered(&pages) catch |err| switch (err) {
            error.AudioSetRateFailed => panic("USB audio SET_CUR rate failed"),
            error.AudioConfigureEndpointFailed => panic("USB audio endpoint configuration failed"),
            else => panic("USB audio configuration failed"),
        };
    }
    const network_device = inventory.findClass(0x02, 0x00) orelse panic("Ethernet controller missing");
    const network_bar = pci.barAddress(network_device, 0) orelse panic("Ethernet BAR missing");
    mapper.mapIdentity(network_bar, 0x20000) catch panic("Ethernet MMIO mapping failed");
    mapper.activate();
    var network = e1000.Controller.init(network_device, &pages) catch panic("Ethernet setup failed");
    if (!network_device.msi) panic("Ethernet MSI missing");
    idt.setExternalHook(&e1000.handleInterrupt);
    pci.enableMsi(network_device, 48, @truncate(bsp_id)) catch panic("Ethernet MSI setup failed");
    e1000.enableInterrupts(&network);
    asm volatile ("sti");
    var network_stack = net.Stack.init(&network);
    syscalls.configureNetwork(&network_stack);
    network_stack.configureDhcp() catch panic("DHCP configuration failed");
    serial.write("DHCP address: ");
    for (network_stack.local_ip, 0..) |part, index| {
        if (index != 0) serial.write(".");
        serial.writeDecimal(part);
    }
    serial.write("\n");
    network_stack.resolveGateway() catch panic("ARP reply missing");
    network_stack.pingGateway() catch panic("IPv4 ICMP failed");
    const resolved = network_stack.resolveDns("example.com") catch panic("DNS resolution failed");
    serial.write("DNS example.com: ");
    for (resolved, 0..) |part, index| {
        if (index != 0) serial.write(".");
        serial.writeDecimal(part);
    }
    serial.write("\n");
    const tcp_bytes = network_stack.probeTcpHttp(resolved, "example.com") catch panic("TCP HTTP probe failed");
    serial.write("TCP response bytes: ");
    serial.writeDecimal(tcp_bytes);
    serial.write("\nCSOS M12 TCP ready\n");
    process.runNetTest(mapper.root, &pages) catch panic("Linux socket userspace test failed");
    mapper.activate();
    serial.write("CSOS Linux socket ABI ready\n");
    var irq_spins: usize = 0;
    while (e1000.interruptCount() == 0 and irq_spins < 100_000_000) : (irq_spins += 1) asm volatile ("pause");
    asm volatile ("cli");
    if (e1000.interruptCount() == 0) panic("Ethernet MSI interrupt missing");
    serial.write("Ethernet ARP ready\n");
    serial.write("Ethernet MSI ready\n");
    serial.write("IPv4 ICMP ready\n");

    var screen = display.Context.init(info.framebuffer, display_device, &pages) catch panic("display initialization failed");
    screen.drawBaseline(@as(usize, hid.keyboards) + hid.mice, audio_info.playback_endpoints);
    const initial_pixels = screen.present();
    if (initial_pixels == 0) panic("display presentation failed");
    serial.write("GPU PCI vendor: "); serial.writeDecimal(screen.adapter.vendor);
    serial.write(" device: "); serial.writeDecimal(screen.adapter.device);
    serial.write("\ndisplay resolution: "); serial.writeDecimal(screen.framebuffer.width);
    serial.write("x"); serial.writeDecimal(screen.framebuffer.height);
    serial.write(" stride: "); serial.writeDecimal(screen.framebuffer.stride);
    serial.write("\ndisplay backbuffer bytes: "); serial.writeDecimal(screen.buffer_bytes);
    serial.write("\ndisplay initial pixels: "); serial.writeDecimal(initial_pixels);
    serial.write("\nCSOS M14 display baseline ready\n");
    if (usb.audioReady()) {
        usb.audioPrime(&pages) catch |err| switch (err) {
            error.AudioSetInterfaceFailed => panic("USB audio SET_INTERFACE failed"),
            else => panic("USB audio stream prime failed"),
        };
        serial.write("USB audio stream started\n");
    }
    var display_ticks: u64 = 0;

    var reported_input: u64 = 0;
    var reported_audio = false;
    while (true) {
        display_ticks +%= 1;
        if ((display_ticks & 0xfffff) == 0) {
            screen.heartbeat(@intCast(display_ticks >> 20));
            if (screen.present() == 0) panic("display heartbeat presentation failed");
        }
        _ = usb.pollHid(&hid) catch |err| switch (err) {
            error.AudioMissedService => panic("USB audio missed service"),
            error.AudioRingOverrun => panic("USB audio ring overrun"),
            error.AudioTransferFailed => {
                serial.write("USB audio completion code: ");
                serial.writeDecimal(usb.audio.last_completion);
                serial.write("\n");
                panic("USB audio transfer failed");
            },
            else => panic("USB HID polling failed"),
        };
        while (hid.pop()) |_| {}
        if (hid.events_total != reported_input) {
            reported_input = hid.events_total;
            serial.write("USB input events: ");
            serial.writeDecimal(reported_input);
            serial.write("\n");
        }
        if (!reported_audio and usb.audio.completed >= 32) {
            if (usb.audio.underruns != 0) panic("USB audio underrun");
            serial.write("CSOS M13 audio streaming ready\n");
            reported_audio = true;
        }
        asm volatile ("pause");
    }
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

fn drawDisplay(framebuffer: Framebuffer, hid: xhci.HidDevices, audio_info: xhci.AudioDevices) void {
    if (framebuffer.base == 0 or framebuffer.size < 4) panic("invalid framebuffer");
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const rows = @min(framebuffer.height, 32);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = if (framebuffer.pixel_format == 0) 0x00101828 else 0x00201810;
        }
    }
    drawDisplayStatusPanel(framebuffer, hid, audio_info);
    drawDisplayHeader(framebuffer);
}

fn drawDisplayHeader(framebuffer: Framebuffer) void {
    if (framebuffer.width < 160 or framebuffer.height < 24) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    var y: usize = 4;
    while (y < 20) : (y += 1) {
        var x: usize = 8;
        while (x < @min(framebuffer.width, 320)) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = if (x < 12 or y < 8) 0x00e0e0e0 else 0x00304060;
        }
    }
}

fn drawDisplayHeartbeat(framebuffer: Framebuffer, ticks: u64) void {
    if (framebuffer.base == 0 or framebuffer.width < 32 or framebuffer.height < 24) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const x = 16 + @as(usize, @intCast((ticks >> 20) & 15));
    const y = 12;
    const offset = y * framebuffer.stride + x;
    if ((offset + 1) * 4 <= framebuffer.size) pixels[offset] = 0x0040d080;
}

fn drawBootPanel(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 128 or framebuffer.height < 64) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const panel_width = @min(framebuffer.width, 640);
    const panel_height = @min(framebuffer.height, 360);
    var y: usize = 40;
    while (y < panel_height) : (y += 1) {
        var x: usize = 0;
        while (x < panel_width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            const border = x < 2 or y < 42 or x + 2 >= panel_width or y + 2 >= panel_height;
            pixels[offset] = if (border) 0x00d0d0d0 else 0x00101018;
        }
    }
}

fn drawDisplayStatus(framebuffer: Framebuffer, hid: xhci.HidDevices, audio_info: xhci.AudioDevices) void {
    if (framebuffer.base == 0 or framebuffer.width < 256 or framebuffer.height < 100) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const y_start: usize = 56;
    const bar_width = @min(framebuffer.width - 32, 704);
    const bar_height: usize = 8;
    var y: usize = y_start;
    while (y < y_start + bar_height and y < framebuffer.height) : (y += 1) {
        var x: usize = 16;
        while (x < 16 + bar_width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = if (x - 16 < @min(bar_width, @as(usize, hid.keyboards + hid.mice) * 80)) 0x0050d070 else 0x00303038;
        }
    }
    _ = audio_info;
}

fn drawDisplayBars(framebuffer: Framebuffer, hid: xhci.HidDevices, audio_info: xhci.AudioDevices) void {
    if (framebuffer.base == 0 or framebuffer.width < 256 or framebuffer.height < 128) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const origin_y: usize = 72;
    const row_height: usize = 12;
    const row_width = @min(framebuffer.width - 32, 704);
    const rows = [_]usize{
        @as(usize, hid.keyboards) + @as(usize, hid.mice),
        @as(usize, audio_info.interfaces),
        @as(usize, audio_info.playback_endpoints),
    };
    for (rows, 0..) |value, row| {
        const y_start = origin_y + row * row_height;
        const filled = @min(row_width, value * 96);
        var y = y_start;
        while (y < y_start + 6 and y < framebuffer.height) : (y += 1) {
            var x: usize = 16;
            while (x < 16 + row_width) : (x += 1) {
                const offset = y * framebuffer.stride + x;
                if ((offset + 1) * 4 > framebuffer.size) return;
                pixels[offset] = if (x - 16 < filled) 0x0040b0e0 else 0x00202028;
            }
        }
    }
}

fn drawDisplayCursor(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 16 or framebuffer.height < 16) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const center_x = framebuffer.width / 2;
    const center_y = framebuffer.height / 2;
    var delta: usize = 0;
    while (delta < 12) : (delta += 1) {
        const horizontal = center_y * framebuffer.stride + center_x + delta;
        const vertical = (center_y + delta) * framebuffer.stride + center_x;
        if ((horizontal + 1) * 4 > framebuffer.size or (vertical + 1) * 4 > framebuffer.size) return;
        pixels[horizontal] = 0x00ffffff;
        pixels[vertical] = 0x00ffffff;
    }
}

fn runDisplaySelfTest(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 64 or framebuffer.height < 64) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const colors = [_]u32{ 0x00d04040, 0x00d0d040, 0x0040d080, 0x004080d0 };
    const block_width = @max(@as(usize, 1), framebuffer.width / colors.len);
    const block_height = @min(@as(usize, 16), framebuffer.height);
    for (colors, 0..) |color, block| {
        const x_start = block * block_width;
        const x_end = @min(framebuffer.width, x_start + block_width);
        var y: usize = 0;
        while (y < block_height) : (y += 1) {
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const offset = y * framebuffer.stride + x;
                if ((offset + 1) * 4 > framebuffer.size) return;
                pixels[offset] = color;
            }
        }
    }
}

fn drawDisplayStatusPanel(framebuffer: Framebuffer, hid: xhci.HidDevices, audio_info: xhci.AudioDevices) void {
    if (framebuffer.base == 0 or framebuffer.width < 160 or framebuffer.height < 96) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const x_start: usize = 24;
    const y_start: usize = 96;
    const width = @min(framebuffer.width - x_start, 512);
    const height = @min(framebuffer.height - y_start, 96);
    const input_level = @min(width - 4, (@as(usize, hid.keyboards) + @as(usize, hid.mice)) * 64);
    const audio_level = @min(width - 4, @as(usize, audio_info.playback_endpoints) * 64);
    var y: usize = y_start;
    while (y < y_start + height) : (y += 1) {
        var x: usize = x_start;
        while (x < x_start + width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            const border = x == x_start or y == y_start or x + 1 == x_start + width or y + 1 == y_start + height;
            const local_y = y - y_start;
            const input_bar = local_y >= 24 and local_y < 32 and x >= x_start + 2 and x < x_start + 2 + input_level;
            const audio_bar = local_y >= 48 and local_y < 56 and x >= x_start + 2 and x < x_start + 2 + audio_level;
            pixels[offset] = if (border) 0x00d0d0d0 else if (input_bar) 0x0050d080 else if (audio_bar) 0x005080d0 else 0x00181820;
        }
    }
}

fn drawDisplayGrid(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 128 or framebuffer.height < 128) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const spacing: usize = 32;
    var y: usize = 0;
    while (y < framebuffer.height) : (y += spacing) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = 0x00202030;
        }
    }
    var x: usize = 0;
    while (x < framebuffer.width) : (x += spacing) {
        var row: usize = 0;
        while (row < framebuffer.height) : (row += 1) {
            const offset = row * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = 0x00202030;
        }
    }
}

fn drawDisplayPalette(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 128 or framebuffer.height < 128) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const colors = [_]u32{ 0x00101018, 0x00202030, 0x00304060, 0x005080a0, 0x00d0d0d0 };
    const swatch_width = @max(@as(usize, 1), framebuffer.width / colors.len);
    const y_start: usize = 16;
    const y_end = @min(framebuffer.height, y_start + 16);
    for (colors, 0..) |color, index| {
        const x_start = index * swatch_width;
        const x_end = @min(framebuffer.width, x_start + swatch_width);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const offset = y * framebuffer.stride + x;
                if ((offset + 1) * 4 > framebuffer.size) return;
                pixels[offset] = color;
            }
        }
    }
}

fn drawDisplaySafeArea(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 64 or framebuffer.height < 64) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const margin_x = @min(@as(usize, 32), framebuffer.width / 8);
    const margin_y = @min(@as(usize, 24), framebuffer.height / 8);
    var x: usize = margin_x;
    while (x + margin_x < framebuffer.width) : (x += 1) {
        for ([_]usize{ margin_y, framebuffer.height - margin_y - 1 }) |y| {
            const offset = y * framebuffer.stride + x;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = 0x00606080;
        }
    }
    var y: usize = margin_y;
    while (y + margin_y < framebuffer.height) : (y += 1) {
        for ([_]usize{ margin_x, framebuffer.width - margin_x - 1 }) |column| {
            const offset = y * framebuffer.stride + column;
            if ((offset + 1) * 4 > framebuffer.size) return;
            pixels[offset] = 0x00606080;
        }
    }
}

fn drawDisplayTestPattern(framebuffer: Framebuffer) void {
    if (framebuffer.base == 0 or framebuffer.width < 64 or framebuffer.height < 64) return;
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const step_x = @max(@as(usize, 1), framebuffer.width / 8);
    const step_y = @max(@as(usize, 1), framebuffer.height / 6);
    var row: usize = 0;
    while (row < 6) : (row += 1) {
        var column: usize = 0;
        while (column < 8) : (column += 1) {
            const color: u32 = switch ((row + column) % 6) {
                0 => 0x00e04040,
                1 => 0x00e0a040,
                2 => 0x00e0e040,
                3 => 0x0040e080,
                4 => 0x004080e0,
                else => 0x00a040e0,
            };
            const x_start = column * step_x;
            const y_start = row * step_y;
            const x_end = @min(framebuffer.width, x_start + step_x);
            const y_end = @min(framebuffer.height, y_start + step_y);
            var y = y_start;
            while (y < y_end) : (y += 1) {
                var x = x_start;
                while (x < x_end) : (x += 1) {
                    const offset = y * framebuffer.stride + x;
                    if ((offset + 1) * 4 > framebuffer.size) return;
                    pixels[offset] = color;
                }
            }
        }
    }
}

fn equalBytes(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
