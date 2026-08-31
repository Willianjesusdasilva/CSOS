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
const gpu = @import("gpu");
const display = @import("display");
const hardware_profile = @import("hardware_profile");
const metrics = @import("metrics");
const installer_state = @import("installer_state");
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
var lifecycle_a: u8 = 0;
var lifecycle_b: u8 = 0;
var lifecycle_error = false;
var workload_sequence: u8 = 0;
var input_workload_order: u8 = 0;
var background_workload_order: u8 = 0;
var timer_lifecycle_phase: u8 = 0;
var console_usb: ?*xhci.Controller = null;
var console_hid: ?*xhci.HidDevices = null;
var console_last_key: u8 = 0;
var console_input_irq_apic: u32 = 0;
var audio_reported = false;

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
    syscalls.configureFramebuffer(.{
        .base = info.framebuffer.base,
        .size = @intCast(info.framebuffer.size),
        .width = info.framebuffer.width,
        .height = info.framebuffer.height,
        .stride = info.framebuffer.stride,
        .pixel_format = info.framebuffer.pixel_format,
    });
    const madt = acpi.findMadt(info.rsdp) catch panic("ACPI MADT invalid");
    const power = acpi.findPower(info.rsdp) catch panic("ACPI power invalid");
    if (madt.cpu_count == 0 or madt.ioapic_count == 0) panic("ACPI topology missing");
    serial.write("ACPI MADT ready\n");
    _ = power;
    serial.write("ACPI power control ready\n");
    for (madt.ioapics[0..madt.ioapic_count]) |controller| {
        ioapic.init(controller.address) catch panic("IOAPIC setup failed");
    }
    serial.write("IOAPIC ready\n");
    gdt.install();
    syscalls.install(gdt.privilegeStackTop()) catch panic("CPU NX support required");
    serial.write("GDT ready\n");
    idt.install();
    idt.setPageFaultHook(&process.handlePageFault);
    if (!idt.verifyBreakpoint()) panic("breakpoint handler failed");
    serial.write("IDT ready\n");
    const cpu_profile = hardware_profile.detectCpu();
    apic.init() catch panic("local APIC setup failed");
    apic.startPeriodicTimer();
    asm volatile ("sti; hlt; cli");
    apic.stopTimer();
    if (idt.timerTicks() == 0) panic("APIC timer failed");
    serial.write("APIC timer ready\n");
    if (info.memory_map_len == 0 or info.memory_descriptor_size == 0) panic("empty memory map");
    var pages = physical.Allocator.init(info.memory_map, info.memory_map_len, info.memory_descriptor_size);
    syscalls.configureDrmMemory(&pages);
    serial.write("physical allocator ready\n");

    var mapper = paging.Mapper.init(&pages, info.framebuffer.base, info.framebuffer.size) catch panic("paging setup failed");
    mapper.activate();
    serial.write("paging ready\n");
    const inventory = pci.Inventory.scan();
    if (inventory.count == 0) panic("PCI enumeration failed");
    if (inventory.findClass(0x06, 0x01) == null) panic("PCI ISA bridge missing");
    const display_device = inventory.findClass(0x03, 0x00) orelse
        inventory.findClass(0x03, 0x80) orelse panic("display adapter missing");
    syscalls.configureDrm(switch (display_device.vendor) { 0x1002 => .amdgpu, 0x10de => .nouveau, else => .csos });

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

    const service_group: u16 = 7;
    _ = scheduler.spawnProcess(&lifecycleThreadA, &pages, 100, service_group, .freeze, .background) catch panic("lifecycle process A creation failed");
    _ = scheduler.spawnProcess(&lifecycleThreadB, &pages, 101, service_group, .auto, .background) catch panic("lifecycle process B creation failed");
    if (scheduler.groupProcessCount(service_group) != 2) panic("lifecycle process group failed");
    if (scheduler.backgroundGroup(service_group) != 2 or scheduler.groupLifecycle(service_group) != .background)
        panic("lifecycle background transition failed");
    scheduler.run();
    if (lifecycle_error or lifecycle_a != 1 or lifecycle_b != 1 or scheduler.groupLifecycle(service_group) != .frozen)
        panic("lifecycle freeze failed");
    scheduler.setMode(.game);
    if (scheduler.applyMode(service_group) != 0 or scheduler.groupLifecycle(service_group) != .frozen)
        panic("GAME lifecycle policy failed");
    scheduler.setMode(.match);
    if (scheduler.applyMode(service_group) != 2 or scheduler.groupLifecycle(service_group) != .standby)
        panic("lifecycle standby transition failed");
    if (scheduler.resumeGroup(service_group) != 2 or scheduler.groupLifecycle(service_group) != .resuming)
        panic("lifecycle resume transition failed");
    scheduler.setMode(.normal);
    scheduler.run();
    if (lifecycle_error or lifecycle_a != 2 or lifecycle_b != 2 or scheduler.groupLifecycle(service_group) != .finished)
        panic("lifecycle completion failed");
    if (scheduler.mode() != .normal) panic("NORMAL lifecycle policy failed");
    serial.write("CSOS M17 multiprocess lifecycle ready\nCSOS M18 gaming modes ready\n");

    _ = scheduler.spawnClassified(&backgroundWorkload, &pages, 8, .auto, .background) catch panic("background workload creation failed");
    _ = scheduler.spawnClassified(&inputWorkload, &pages, 8, .keep_alive, .input) catch panic("input workload creation failed");
    scheduler.setMode(.game);
    scheduler.run();
    scheduler.setMode(.normal);
    if (input_workload_order != 1 or background_workload_order != 2) panic("GAME workload priority failed");
    const scheduler_latency = scheduler.dispatchLatency() catch panic("scheduler latency metrics missing");
    serial.write("profile scheduler dispatch cycles p50: "); serial.writeDecimal(scheduler_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(scheduler_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(scheduler_latency.p99);
    serial.write(" migrations: "); serial.writeDecimal(scheduler.migrationCount());
    serial.write("\nCSOS M18 scheduler latency ready\n");
    serial.write("CSOS M18 workload policy ready\n");

    const timer_group: u16 = 9;
    _ = scheduler.spawnManaged(&timerLifecycleThread, &pages, timer_group, .freeze) catch panic("lifecycle timer creation failed");
    scheduler.run();
    if (timer_lifecycle_phase != 1 or scheduler.groupSleepTicks(timer_group) != 3) panic("lifecycle timer sleep failed");
    var freeze_samples = metrics.Samples{};
    var resume_samples = metrics.Samples{};
    var lifecycle_sample: usize = 0;
    while (lifecycle_sample < 16) : (lifecycle_sample += 1) {
        const freeze_started = timestamp(cpu_profile.tsc);
        if (scheduler.freezeGroup(timer_group) != 1) panic("lifecycle sleeping freeze failed");
        freeze_samples.add(elapsed(freeze_started, cpu_profile.tsc)) catch panic("freeze metric capacity failed");
        const resume_started = timestamp(cpu_profile.tsc);
        if (scheduler.resumeGroup(timer_group) != 1) panic("lifecycle timer resume failed");
        resume_samples.add(elapsed(resume_started, cpu_profile.tsc)) catch panic("resume metric capacity failed");
    }
    const freeze_latency = freeze_samples.summarize() catch panic("freeze metrics missing");
    const resume_latency = resume_samples.summarize() catch panic("resume metrics missing");
    if (scheduler.freezeGroup(timer_group) != 1) panic("lifecycle sleeping freeze failed");
    scheduler.tick();
    scheduler.tick();
    if (scheduler.groupSleepTicks(timer_group) != 3) panic("frozen lifecycle timer advanced");
    if (scheduler.resumeGroup(timer_group) != 1) panic("lifecycle timer resume failed");
    scheduler.tick();
    scheduler.tick();
    scheduler.tick();
    scheduler.run();
    if (timer_lifecycle_phase != 2 or scheduler.groupLifecycle(timer_group) != .finished) panic("lifecycle timer completion failed");
    serial.write("CSOS M17 paused timers ready\n");

    const userspace_pages_before = pages.free_pages;
    process.runHelloPie(mapper.root, &pages) catch panic("PIE userspace failed");
    mapper.activate();
    if (process.relative_relocations == 0) panic("PIE relative relocation missing");
    if (syscalls.file_mmaps == 0) panic("Linux file mmap missing");
    if (syscalls.protected_mmaps == 0 or syscalls.unmapped_mmaps == 0) panic("Linux mmap lifecycle missing");
    serial.write("Linux PIE userspace ready\nLinux W^X userspace ready\n");
    process.runFramebufferTest(mapper.root, &pages) catch panic("Linux framebuffer ioctl userspace failed");
    mapper.activate();
    if (syscalls.framebuffer_ioctls != 2) panic("Linux framebuffer ioctl coverage failed");
    if (syscalls.framebuffer_mmaps != 1) panic("Linux framebuffer mmap coverage failed");
    serial.write("CSOS M14 userspace framebuffer ioctl ready\n");
    serial.write("CSOS M14 userspace framebuffer mmap ready\n");
    const drm_guard: *volatile const u32 = @ptrFromInt(info.framebuffer.base + 16380);
    const drm_guard_before = drm_guard.*;
    process.runDrmTest(mapper.root, &pages) catch {
        serial.write("DRM last request: "); serial.writeDecimal(syscalls.drm_last_request);
        serial.write(" result: "); serial.writeDecimal(syscalls.drm_last_result); serial.write("\n");
        panic("Linux DRM core userspace failed");
    };
    mapper.activate();
    if (syscalls.drm_ioctls != 35 or syscalls.drm_mmaps != 2) panic("Linux DRM ioctl coverage failed");
    if (syscalls.drm_allocations != 3 or syscalls.drm_releases != 3) panic("DRM backing memory lifecycle failed");
    if (drm_guard.* != drm_guard_before) panic("DRM buffer aliased firmware framebuffer");
    serial.write("CSOS M14 userspace DRM core ready\n");
    const echo_arguments = [_][]const u8{ "/bin/busybox", "echo", "BusyBox userspace ready" };
    process.runBusyBox(mapper.root, &pages, &echo_arguments) catch panic("BusyBox echo failed");
    mapper.activate();
    const ls_arguments = [_][]const u8{ "/bin/busybox", "ls", "/" };
    process.runBusyBox(mapper.root, &pages, &ls_arguments) catch panic("BusyBox ls failed");
    mapper.activate();
    const cat_arguments = [_][]const u8{ "/bin/busybox", "cat", "/hello.txt" };
    process.runBusyBox(mapper.root, &pages, &cat_arguments) catch panic("BusyBox cat failed");
    mapper.activate();
    if (syscalls.sendfile_calls == 0) panic("Linux sendfile missing");
    const shell_arguments = [_][]const u8{ "/bin/busybox", "sh", "-c", "echo BusyBox shell ready" };
    process.runBusyBox(mapper.root, &pages, &shell_arguments) catch panic("BusyBox sh failed");
    mapper.activate();
    if (pages.free_pages != userspace_pages_before) panic("userspace page reclaim mismatch");
    serial.write("userspace reclaimed pages: "); serial.writeDecimal(pages.reclaimed_pages);
    serial.write("\nCSOS M17 process reclaim ready\n");
    serial.write("BusyBox applets returned\n");

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
    var nvme_samples = metrics.Samples{};
    var nvme_sample: usize = 0;
    while (nvme_sample < 1) : (nvme_sample += 1) {
        const nvme_read_started = timestamp(cpu_profile.tsc);
        storage.readBlock(1000, io_buffer) catch panic("NVMe read failed");
        nvme_samples.add(elapsed(nvme_read_started, cpu_profile.tsc)) catch panic("NVMe metric capacity failed");
    }
    io_index = 0;
    while (io_index < storage.block_size) : (io_index += 1) {
        if (io_bytes[io_index] != @as(u8, @truncate(io_index ^ 0xa5))) panic("NVMe data mismatch");
    }
    serial.write("NVMe read/write ready\n");
    var volume = fat16.Volume.mount(&storage, &pages) catch panic("FAT16 mount failed");
    const boot_state_name: [11]u8 = "BOOTSTATCSC".*;
    const boot_starting = "starting\n";
    const boot_ready = "ready\n";
    var previous_boot_state: [16]u8 = undefined;
    const previous_boot_length = volume.readRootFile(&boot_state_name, &previous_boot_state) catch |err| switch (err) {
        error.NotFound => 0,
        else => panic("boot recovery state read failed"),
    };
    const recovering = equalBytes(previous_boot_state[0..previous_boot_length], boot_starting);
    if (recovering) {
        scheduler.setMode(.normal);
        serial.write("recovery: previous boot incomplete, safe defaults active\n");
    }
    volume.writeRootFile(&boot_state_name, boot_starting) catch panic("boot recovery state write failed");
    var file_data: [128]u8 = undefined;
    const file_size = volume.readRootFile("SYSTEM  TXT", &file_data) catch panic("FAT16 read failed");
    serial.write(file_data[0..file_size]);
    const state = "persistent CSOS state\n" ** 600;
    volume.writeRootFile("STATE   TXT", state) catch panic("FAT16 write failed");
    var state_readback: [1024]u8 = undefined;
    var state_offset: usize = 0;
    while (state_offset < state.len) {
        const state_size = volume.readRootFileAt("STATE   TXT", &state_readback, state_offset) catch panic("FAT16 ranged read failed");
        if (state_size == 0 or !equalBytes(state[state_offset .. state_offset + state_size], state_readback[0..state_size])) panic("FAT16 ranged data mismatch");
        state_offset += state_size;
    }
    serial.write("FAT16 write ready\n");
    vfs.mount(&volume);
    vfs.reset();
    const state_fd = vfs.openAt(-100, "/state.txt", 0) catch panic("VFS large file open failed");
    state_offset = 0;
    while (state_offset < state.len) {
        const state_size = vfs.read(state_fd, &state_readback) catch panic("VFS large file read failed");
        if (state_size == 0 or !equalBytes(state[state_offset .. state_offset + state_size], state_readback[0..state_size])) panic("VFS large file mismatch");
        state_offset += state_size;
    }
    vfs.close(state_fd) catch panic("VFS large file close failed");
    serial.write("VFS large file streaming ready\n");
    const dynamic_pages_before = pages.free_pages;
    process.runDynamicTest(mapper.root, &pages) catch panic("filesystem PT_INTERP userspace failed");
    mapper.activate();
    if (process.interpreter_loads == 0) panic("PT_INTERP loader missing");
    if (process.shared_objects_loaded < 2 or process.symbol_relocations < 2) panic("multiple shared object resolution missing");
    if (process.data_symbol_relocations == 0) panic("dynamic data symbol resolution missing");
    if (process.gnu_hash_tables == 0) panic("GNU dynamic hash resolution missing");
    if (process.tls_modules == 0 or process.tls_relocations == 0) panic("dynamic TLS setup missing");
    if (process.versioned_symbols == 0) panic("dynamic symbol version resolution missing");
    if (pages.free_pages != dynamic_pages_before) panic("dynamic loader page reclaim mismatch");
    serial.write("Linux filesystem shared object ready\nLinux dynamic userspace ready\n");
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
    if (!xhci_device.msi and !xhci_device.msix) panic("xHCI MSI/MSI-X missing");
    const input_irq_apic = bsp_id;
    if (input_irq_apic > 255) panic("xHCI MSI APIC ID unsupported");
    idt.setUsbHook(&xhci.handleInterrupt);
    usb.enableInterrupts();
    if (!usb.interruptEnabled()) panic("xHCI interrupter enable failed");
    if (xhci_device.msi)
        pci.enableMsi(xhci_device, 49, @truncate(input_irq_apic)) catch panic("xHCI MSI setup failed")
    else
        pci.enableMsix(xhci_device, 49, @truncate(input_irq_apic)) catch panic("xHCI MSI-X setup failed");
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
    var network_irq_apic = bsp_id;
    for (madt.cpus[0..madt.cpu_count]) |cpu| {
        if (cpu.apic_id != bsp_id) {
            network_irq_apic = cpu.apic_id;
            break;
        }
    }
    if (network_irq_apic > 255) panic("Ethernet MSI APIC ID unsupported");
    idt.setExternalHook(&e1000.handleInterrupt);
    pci.enableMsi(network_device, 48, @truncate(network_irq_apic)) catch panic("Ethernet MSI setup failed");
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
    var tcp_samples = metrics.Samples{};
    var tcp_sample: usize = 0;
    var tcp_bytes: usize = 0;
    while (tcp_sample < 1) : (tcp_sample += 1) {
        const tcp_started = timestamp(cpu_profile.tsc);
        const received = network_stack.probeTcpHttp(resolved, "example.com") catch panic("TCP HTTP probe failed");
        tcp_samples.add(elapsed(tcp_started, cpu_profile.tsc)) catch panic("TCP metric capacity failed");
        if (received == 0 or (tcp_bytes != 0 and received != tcp_bytes)) panic("TCP response instability");
        tcp_bytes = received;
    }
    serial.write("TCP response bytes: ");
    serial.writeDecimal(tcp_bytes);
    serial.write("\nCSOS M12 TCP ready\n");
    const nettest_pages_before = pages.free_pages;
    process.runNetTest(mapper.root, &pages) catch panic("Linux socket userspace test failed");
    mapper.activate();
    if (pages.free_pages != nettest_pages_before) panic("network userspace page reclaim mismatch");
    if (process.pause_count != 1 or process.standby_pages == 0 or process.restored_pages == 0 or process.lifecycle != .finished)
        panic("persistent userspace standby failed");
    serial.write("standby pages discarded: "); serial.writeDecimal(process.standby_pages);
    serial.write(" restored: "); serial.writeDecimal(process.restored_pages);
    serial.write("\nCSOS M17 persistent standby resume ready\n");
    serial.write("CSOS Linux socket ABI ready\n");
    var irq_spins: usize = 0;
    while (e1000.interruptCount() == 0 and irq_spins < 100_000_000) : (irq_spins += 1) asm volatile ("pause");
    asm volatile ("cli");
    if (e1000.interruptCount() == 0) panic("Ethernet MSI interrupt missing");
    if (e1000.interruptApic() != network_irq_apic) panic("Ethernet MSI affinity mismatch");
    const network_rx_latency = network.rx_latency.summarize() catch panic("Ethernet RX latency metrics missing");
    serial.write("profile Ethernet RX IRQ-to-consume cycles p50: "); serial.writeDecimal(network_rx_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(network_rx_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(network_rx_latency.p99);
    serial.write("\nCSOS M18 network processing latency ready\n");
    serial.write("Ethernet ARP ready\n");
    serial.write("Ethernet MSI ready\n");
    serial.write("Ethernet IRQ APIC: "); serial.writeDecimal(network_irq_apic); serial.write("\n");
    serial.write("xHCI MSI-X armed APIC: "); serial.writeDecimal(input_irq_apic); serial.write("\n");
    serial.write("IPv4 ICMP ready\n");
    const gpu_adapter = gpu.Adapter.discover(display_device) catch panic("GPU discovery failed");
    if (gpu_adapter.bar_count == 0) panic("GPU BAR discovery failed");
    idt.setGpuHook(&gpu.handleInterrupt);
    asm volatile ("int $50");
    if (gpu.interrupts() != 1) panic("GPU interrupt route failed");
    const gpu_firmware = gpu.loadFirmware(&volume, &pages) catch panic("GPU firmware load failed");
    if ((gpu_adapter.driver == .amdgpu or gpu_adapter.driver == .nouveau) and gpu_firmware == null) panic("GPU firmware archive missing");
    const gpu_firmware_entries = if (gpu_firmware) |firmware| firmware.entryCount() catch panic("GPU firmware archive invalid") else 0;
    const gpu_catalog_entries = if (gpu_firmware) |firmware|
        (firmware.countPrefix("amdgpu/") catch panic("AMDGPU firmware index invalid")) +
        (firmware.countPrefix("nouveau/") catch panic("Nouveau firmware index invalid"))
    else 0;
    const gpu_firmware_mappings = if (gpu_firmware) |firmware| firmware.mappingCount() catch panic("GPU firmware manifest invalid") else 0;
    const gpu_selection = if (gpu_firmware) |firmware| firmware.select(display_device, gpu_adapter.driver) catch panic("GPU firmware selection invalid") else null;
    const gpu_backend_entries = if (gpu_selection) |selection| selection.entries else 0;
    const gpu_required_blocks = if (gpu_selection) |selection| selection.required_blocks else 0;
    if ((gpu_adapter.driver == .amdgpu or gpu_adapter.driver == .nouveau) and gpu_selection == null) panic("GPU model firmware mapping missing");
    const gpu_validated_entries = if (gpu_firmware) |firmware|
        if (gpu_selection) |selection| firmware.validateSelection(selection, gpu_adapter.driver) catch panic("GPU firmware validation failed") else 0
    else 0;
    var gpu_inventory = gpu.FirmwareInventory{};
    var gpu_ip_discovery: ?gpu.AmdIpDiscovery = null;
    if (gpu_firmware) |firmware| if (gpu_selection) |selection| {
        gpu_inventory = firmware.inventory(selection, gpu_adapter.driver) catch panic("GPU firmware inventory invalid");
        if (gpu_adapter.driver == .amdgpu)
            gpu_ip_discovery = firmware.amdDiscovery(selection) catch panic("AMDGPU IP discovery invalid");
    };
    const gpu_psp_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.psp, 0)) |ip| ip.major else 0 else 0;
    const gpu_gfx_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.gfx, 0)) |ip| ip.major else 0 else 0;
    const gpu_mmhub_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.mmhub, 0)) |ip| ip.major else 0 else 0;
    const gpu_sdma_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.sdma0, 0)) |ip| ip.major else 0 else 0;
    const gpu_registers = gpu_adapter.register_bar orelse panic("GPU register BAR missing");
    if (gpu_registers.size > 16 * 1024 * 1024) panic("GPU register BAR unexpectedly large");
    mapper.mapIdentity(gpu_registers.address, @intCast(gpu_registers.size)) catch panic("GPU register MMIO mapping failed");
    mapper.activate();
    const gpu_identity = gpu_adapter.identifyChip() catch panic("GPU chipset identification failed");
    const gpu_register_probe = gpu_identity.boot0 orelse gpu_adapter.readRegister(0) catch panic("GPU register MMIO read failed");
    var screen = display.Context.init(info.framebuffer, display_device, &pages) catch panic("display initialization failed");
    screen.drawBaseline(@as(usize, hid.keyboards) + hid.mice, audio_info.playback_endpoints);
    const initial_pixels = screen.present();
    if (initial_pixels == 0) panic("display presentation failed");
    serial.write("GPU PCI vendor: "); serial.writeDecimal(screen.adapter.vendor);
    serial.write(" device: "); serial.writeDecimal(screen.adapter.device);
    serial.write(" revision: "); serial.writeDecimal(display_device.revision);
    serial.write(" bars: "); serial.writeDecimal(gpu_adapter.bar_count);
    serial.write(" bytes: "); serial.writeDecimal(gpu_adapter.mmio_bytes);
    serial.write(" registers: "); serial.writeDecimal(gpu_registers.size);
    serial.write(" probe: "); serial.writeDecimal(gpu_register_probe);
    serial.write(" chipset: "); serial.writeDecimal(gpu_identity.chipset orelse 0);
    serial.write(" chiprev: "); serial.writeDecimal(gpu_identity.chip_revision orelse 0);
    serial.write(" firmware: "); serial.writeDecimal(if (gpu_firmware) |firmware| firmware.size else 0);
    serial.write(" entries: "); serial.writeDecimal(gpu_firmware_entries);
    serial.write(" catalog: "); serial.writeDecimal(gpu_catalog_entries);
    serial.write(" mappings: "); serial.writeDecimal(gpu_firmware_mappings);
    serial.write(" selected: "); serial.writeDecimal(gpu_backend_entries);
    serial.write(" required-mask: "); serial.writeDecimal(gpu_required_blocks);
    serial.write(" validated: "); serial.writeDecimal(gpu_validated_entries);
    serial.write(" payloads: "); serial.writeDecimal(gpu_inventory.entries);
    serial.write(" payload-bytes: "); serial.writeDecimal(gpu_inventory.payload_bytes);
    serial.write(" security: "); serial.writeDecimal(gpu_inventory.block(.security).entries);
    serial.write(" graphics: "); serial.writeDecimal(gpu_inventory.block(.graphics).entries);
    serial.write(" dma: "); serial.writeDecimal(gpu_inventory.block(.dma).entries);
    serial.write(" ip-dies: "); serial.writeDecimal(if (gpu_ip_discovery) |discovery| discovery.dies else 0);
    serial.write(" ips: "); serial.writeDecimal(if (gpu_ip_discovery) |discovery| discovery.ips else 0);
    serial.write(" psp: "); serial.writeDecimal(gpu_psp_major);
    serial.write(" gfx: "); serial.writeDecimal(gpu_gfx_major);
    serial.write(" mmhub: "); serial.writeDecimal(gpu_mmhub_major);
    serial.write(" sdma: "); serial.writeDecimal(gpu_sdma_major);
    serial.write(" driver: ");
    serial.write(switch (gpu_adapter.driver) {
        .amdgpu => "amdgpu",
        .nouveau => "nouveau",
        .qemu_vga => "qemu-vga",
        .unsupported => "unsupported",
    });
    serial.write("\ndisplay resolution: "); serial.writeDecimal(screen.framebuffer.width);
    serial.write("x"); serial.writeDecimal(screen.framebuffer.height);
    serial.write(" stride: "); serial.writeDecimal(screen.framebuffer.stride);
    serial.write("\ndisplay backbuffer bytes: "); serial.writeDecimal(screen.buffer_bytes);
    serial.write("\ndisplay initial pixels: "); serial.writeDecimal(initial_pixels);
    serial.write("\nCSOS M14 GPU discovery baseline ready\n");
    serial.write("CSOS M14 display baseline ready\n");
    var current_profile = hardware_profile.build(cpu_profile, .{
        .logical_cpus = @intCast(madt.cpu_count),
        .memory_pages = pages.installed_pages,
        .pci_devices = @intCast(inventory.count),
        .gpu_vendor = display_device.vendor,
        .gpu_device = display_device.device,
        .gpu_revision = display_device.revision,
        .gpu_subsystem_vendor = display_device.subsystem_vendor,
        .gpu_subsystem_device = display_device.subsystem_device,
        .gpu_chipset = gpu_identity.chipset orelse 0,
        .gpu_chip_revision = gpu_identity.chip_revision orelse 0,
        .gpu_msi = display_device.msi,
        .gpu_msix = display_device.msix,
        .gpu_bus = display_device.bus,
        .gpu_slot = display_device.slot,
        .nvme_vendor = nvme_device.vendor,
        .nvme_device = nvme_device.device,
        .nvme_namespaces = @intCast(namespaces),
        .nic_vendor = network_device.vendor,
        .nic_device = network_device.device,
        .network_irq_apic = network_irq_apic,
        .usb_ports = usb.connected_ports,
        .keyboards = hid.keyboards,
        .mice = hid.mice,
        .input_irq_apic = input_irq_apic,
        .audio_interfaces = audio_info.interfaces,
        .display_width = screen.framebuffer.width,
        .display_height = screen.framebuffer.height,
        .display_stride = screen.framebuffer.stride,
    }) catch panic("hardware profile generation failed");
    const install_name: [11]u8 = "INSTALL CSC".*;
    var stored_install: [64]u8 = undefined;
    const stored_install_length = volume.readRootFile(&install_name, &stored_install) catch |err| switch (err) {
        error.NotFound => 0,
        else => panic("installation state read failed"),
    };
    const installation_current = installer_state.matches(stored_install[0..stored_install_length], current_profile.signature);
    if (!installation_current) {
        volume.writeRootFile(&install_name, installer_state.installing) catch panic("installation transaction start failed");
        var installation_started: [16]u8 = undefined;
        const started_length = volume.readRootFile(&install_name, &installation_started) catch panic("installation transaction verification failed");
        if (!equalBytes(installation_started[0..started_length], installer_state.installing)) panic("installation transaction state mismatch");
        serial.write("CSOS first installation started\n");
    }
    const hardware_name: [11]u8 = "HARDWARECSC".*;
    var stored_profile: [2048]u8 = undefined;
    const stored_length = volume.readRootFile(&hardware_name, &stored_profile) catch |err| switch (err) {
        error.NotFound => 0,
        else => panic("hardware profile read failed"),
    };
    const profile_reused = hardware_profile.matchesSignature(stored_profile[0..stored_length], current_profile.signature);
    if (!installation_current or !profile_reused) {
        while (nvme_sample < 16) : (nvme_sample += 1) {
            const started = timestamp(cpu_profile.tsc);
            storage.readBlock(1000, io_buffer) catch panic("NVMe profiling read failed");
            nvme_samples.add(elapsed(started, cpu_profile.tsc)) catch panic("NVMe metric capacity failed");
        }
        while (tcp_sample < 8) : (tcp_sample += 1) {
            const started = timestamp(cpu_profile.tsc);
            const received = network_stack.probeTcpHttp(resolved, "example.com") catch panic("TCP profiling probe failed");
            tcp_samples.add(elapsed(started, cpu_profile.tsc)) catch panic("TCP metric capacity failed");
            if (received != tcp_bytes) panic("TCP response instability");
        }
    }
    const nvme_latency = nvme_samples.summarize() catch panic("NVMe metrics missing");
    const tcp_latency = tcp_samples.summarize() catch panic("TCP metrics missing");
    if (!profile_reused) current_profile.addBaseline(
        freeze_latency.p50, freeze_latency.p95, freeze_latency.p99,
        resume_latency.p50, resume_latency.p95, resume_latency.p99,
        nvme_latency.p50, nvme_latency.p95, nvme_latency.p99,
        tcp_latency.p50, tcp_latency.p95, tcp_latency.p99,
    ) catch panic("hardware baseline append failed");
    serial.write("profile scheduler freeze cycles p50: "); serial.writeDecimal(freeze_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(freeze_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(freeze_latency.p99);
    serial.write(" resume p50: "); serial.writeDecimal(resume_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(resume_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(resume_latency.p99);
    serial.write("\nprofile NVMe read cycles p50: "); serial.writeDecimal(nvme_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(nvme_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(nvme_latency.p99);
    serial.write("\nprofile TCP transaction cycles p50: "); serial.writeDecimal(tcp_latency.p50);
    serial.write(" p95: "); serial.writeDecimal(tcp_latency.p95);
    serial.write(" p99: "); serial.writeDecimal(tcp_latency.p99);
    serial.write(if (installation_current and profile_reused) "\nCSOS M18 boot validation ready\n" else "\nCSOS M18 install profiling baseline ready\n");
    if (!profile_reused) volume.writeRootFile(&hardware_name, current_profile.text()) catch panic("hardware profile write failed");
    var verified_profile: [2048]u8 = undefined;
    const verified_length = volume.readRootFile(&hardware_name, &verified_profile) catch panic("hardware profile verification read failed");
    if (!hardware_profile.matchesSignature(verified_profile[0..verified_length], current_profile.signature))
        panic("hardware profile verification failed");
    if (!profile_reused and (!containsBytes(verified_profile[0..verified_length], "[baseline_cycles]") or
        !containsBytes(verified_profile[0..verified_length], "freeze_p99=") or
        !containsBytes(verified_profile[0..verified_length], "resume_p99=")))
        panic("hardware baseline persistence failed");
    serial.write("hardware signature: "); serial.writeDecimal(current_profile.signature);
    serial.write(if (profile_reused) "\nhardware.csc reused\n" else "\nhardware.csc generated\n");
    serial.write("CSOS M16 hardware profile ready\n");
    if (usb.audioReady()) {
        usb.audioPrime(&pages) catch |err| switch (err) {
            error.AudioSetInterfaceFailed => panic("USB audio SET_INTERFACE failed"),
            else => panic("USB audio stream prime failed"),
        };
        serial.write("USB audio stream started\n");
    }
    volume.writeRootFile(&boot_state_name, boot_ready) catch panic("boot ready state write failed");
    var verified_boot_state: [16]u8 = undefined;
    const verified_boot_length = volume.readRootFile(&boot_state_name, &verified_boot_state) catch panic("boot ready state read failed");
    if (!equalBytes(verified_boot_state[0..verified_boot_length], boot_ready)) panic("boot ready state verification failed");
    const completed_install = installer_state.completed(current_profile.signature);
    if (!installation_current) volume.writeRootFile(&install_name, completed_install.text()) catch panic("installation completion write failed");
    var verified_install: [64]u8 = undefined;
    const verified_install_length = volume.readRootFile(&install_name, &verified_install) catch panic("installation completion read failed");
    if (!installer_state.matches(verified_install[0..verified_install_length], current_profile.signature)) panic("installation completion verification failed");
    serial.write(if (installation_current) "CSOS installation reused\n" else "CSOS installation completed\n");
    serial.write(if (recovering) "CSOS recovery completed\n" else "CSOS boot health ready\n");
    console_usb = &usb;
    console_hid = &hid;
    console_input_irq_apic = input_irq_apic;
    syscalls.configureConsole(&consoleRead, &consoleWait);
    serial.write("CSOS console shell ready\n");
    const console_arguments = [_][]const u8{ "/bin/busybox", "sh" };
    process.runBusyBox(mapper.root, &pages, &console_arguments) catch panic("console shell failed");
    mapper.activate();
    syscalls.configureConsole(null, null);
    serial.write("CSOS console shell exited\n");
    if (hid.latency.count != 0) {
        const input_latency = hid.latency.summarize() catch panic("input metrics missing");
        serial.write("profile USB input queue cycles p50: "); serial.writeDecimal(input_latency.p50);
        serial.write(" p95: "); serial.writeDecimal(input_latency.p95);
        serial.write(" p99: "); serial.writeDecimal(input_latency.p99);
        serial.write("\nCSOS M18 input latency ready\n");
    }
    var display_ticks: u64 = 0;

    var reported_input: u64 = 0;
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
        reportAudio(&usb);
        asm volatile ("pause");
    }
}

fn reportAudio(usb: *xhci.Controller) void {
    if (audio_reported or usb.audio.completed < 32) return;
    if (usb.audio.underruns != 0) panic("USB audio underrun");
    const audio_jitter = usb.audio.completion_intervals.summarize() catch panic("USB audio jitter metrics missing");
    serial.write("profile USB audio period cycles p50: "); serial.writeDecimal(audio_jitter.p50);
    serial.write(" p95: "); serial.writeDecimal(audio_jitter.p95);
    serial.write(" p99: "); serial.writeDecimal(audio_jitter.p99);
    serial.write("\nCSOS M18 audio jitter ready\n");
    serial.write("CSOS M13 audio streaming ready\n");
    audio_reported = true;
}

fn consoleRead(output: [*]u8, length: usize) callconv(.c) usize {
    if (length == 0) return 0;
    var count: usize = 0;
    while (count == 0) {
        if (serial.readNonblocking()) |byte| {
            output[count] = if (byte == '\r') '\n' else byte;
            count += 1;
            break;
        }
        consoleWait();
        if (console_hid) |hid| {
            while (hid.pop()) |event| {
                if (event.kind != .keyboard) continue;
                if (event.a == 0) {
                    console_last_key = 0;
                    continue;
                }
                if (event.a == console_last_key) continue;
                console_last_key = event.a;
                if (hidCharacter(event.a, event.b)) |byte| {
                    output[count] = byte;
                    count += 1;
                    break;
                }
            }
        }
        asm volatile ("pause");
    }
    return count;
}

fn hidCharacter(usage: u8, modifiers: u8) ?u8 {
    const shifted = (modifiers & 0x22) != 0;
    if (usage >= 4 and usage <= 29) {
        const base: u8 = if (shifted) 'A' else 'a';
        return base + usage - 4;
    }
    if (usage >= 30 and usage <= 38) return "123456789"[usage - 30];
    return switch (usage) {
        39 => '0',
        40 => '\n',
        42 => 0x7f,
        44 => ' ',
        45 => if (shifted) '_' else '-',
        46 => if (shifted) '+' else '=',
        54 => if (shifted) '<' else ',',
        55 => if (shifted) '>' else '.',
        56 => if (shifted) '?' else '/',
        else => null,
    };
}

fn consoleWait() callconv(.c) void {
    const usb = console_usb orelse return;
    const hid = console_hid orelse return;
    _ = usb.pollHid(hid) catch {};
    reportAudio(usb);
    if (xhci.interruptCount() != 0 and xhci.interruptApic() != console_input_irq_apic)
        panic("xHCI MSI affinity mismatch");
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

fn lifecycleThreadA() void {
    lifecycle_a = 1;
    scheduler.freezeCurrent() catch {
        lifecycle_error = true;
        return;
    };
    lifecycle_a = 2;
}

fn lifecycleThreadB() void {
    lifecycle_b = 1;
    scheduler.freezeCurrent() catch {
        lifecycle_error = true;
        return;
    };
    lifecycle_b = 2;
}

fn inputWorkload() void {
    workload_sequence += 1;
    input_workload_order = workload_sequence;
}

fn backgroundWorkload() void {
    workload_sequence += 1;
    background_workload_order = workload_sequence;
}

fn timerLifecycleThread() void {
    timer_lifecycle_phase = 1;
    scheduler.sleepCurrent(3) catch {
        lifecycle_error = true;
        return;
    };
    timer_lifecycle_phase = 2;
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

fn containsBytes(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1)
        if (equalBytes(haystack[offset .. offset + needle.len], needle)) return true;
    return false;
}

fn timestamp(supported: bool) u64 {
    if (!supported) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}

fn elapsed(begin: u64, supported: bool) u64 {
    return if (supported) timestamp(true) -% begin else 0;
}
