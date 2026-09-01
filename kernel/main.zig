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
const build_options = @import("build_options");

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
var gpu_gmc11_activation_workspace = gpu.AmdGmc11ActivationWorkspace{};
const GpuVmRuntime = struct {
    transport: ?gpu.AmdGmc11MmioTransport = null,
    registers: ?gpu.AmdGmc11GartRegisters = null,
    context: gpu.AmdGmc11VmContextWorkspace = .{},
    active: bool = false,
};
var gpu_vm_runtime = GpuVmRuntime{};
const GpuCsRuntime = struct {
    mmio: ?gpu.AmdGmc11MmioTransport = null,
    doorbell: ?gpu.AmdGfx11DoorbellTransport = null,
    plan: ?gpu.AmdGfx11CpGfxPlan = null,
    ring: ?*[1024]u32 = null,
    pointers: ?*[512]u64 = null,
    fence: ?*u64 = null,
    fence_gpu: u64 = 0,
    queue: gpu.AmdGfx11SubmissionQueue = .{},
    active: bool = false,
};
var gpu_cs_runtime = GpuCsRuntime{};

fn submitDrmAmdGpuCs(raw: *anyopaque, vmid: u4, ib_address: u64, ib_dwords: u32) !u64 {
    const runtime: *GpuCsRuntime = @ptrCast(@alignCast(raw));
    if (!runtime.active or !gpu_vm_runtime.active or !gpu_vm_runtime.context.bound or
        gpu_vm_runtime.context.vmid != vmid)
        return error.AmdGpuVmContextNotBound;
    const mmio = if (runtime.mmio) |*value| value else return error.AmdGpuVmHardwareUnavailable;
    const doorbell = if (runtime.doorbell) |*value| value else return error.AmdGpuVmHardwareUnavailable;
    try mmio.arm();
    defer mmio.disarm();
    try doorbell.arm();
    defer doorbell.disarm();
    const result = try gpu.submitAmdGfx11IndirectBuffer(
        runtime.plan.?, &runtime.queue, runtime.ring.?, runtime.pointers.?, runtime.fence.?,
        runtime.fence_gpu, vmid, ib_address, ib_dwords, 2_100_000, mmio.io(), doorbell.io(),
    );
    return result.sequence;
}

fn bindDrmGpuVm(raw: *anyopaque, vmid: u4, root: u64) !void {
    const runtime: *GpuVmRuntime = @ptrCast(@alignCast(raw));
    if (!runtime.active or !gpu_gmc11_activation_workspace.active) return error.AmdGpuVmHardwareUnavailable;
    const transport = if (runtime.transport) |*value| value else return error.AmdGpuVmHardwareUnavailable;
    try transport.arm();
    defer transport.disarm();
    asm volatile ("mfence" ::: .{ .memory = true });
    _ = try gpu.bindAmdGmc11VmContext(&runtime.context, runtime.registers.?, vmid, root, 1, 100_000, transport.io());
}

fn invalidateDrmGpuVm(raw: *anyopaque, vmid: u4) !void {
    const runtime: *GpuVmRuntime = @ptrCast(@alignCast(raw));
    if (!runtime.active or !runtime.context.bound or runtime.context.vmid != vmid) return error.AmdGpuVmContextNotBound;
    const transport = if (runtime.transport) |*value| value else return error.AmdGpuVmHardwareUnavailable;
    try transport.arm();
    defer transport.disarm();
    asm volatile ("mfence" ::: .{ .memory = true });
    _ = try gpu.invalidateAmdGmc11Gart(runtime.registers.?, runtime.context.engine, vmid, 100_000, transport.io());
}

fn unbindDrmGpuVm(raw: *anyopaque, vmid: u4) !void {
    const runtime: *GpuVmRuntime = @ptrCast(@alignCast(raw));
    if (!runtime.active or !runtime.context.bound or runtime.context.vmid != vmid) return error.AmdGpuVmContextNotBound;
    const transport = if (runtime.transport) |*value| value else return error.AmdGpuVmHardwareUnavailable;
    try transport.arm();
    defer transport.disarm();
    asm volatile ("mfence" ::: .{ .memory = true });
    _ = try gpu.unbindAmdGmc11VmContext(&runtime.context, runtime.registers.?, 100_000, transport.io());
}

pub const BootInfo = struct {
    framebuffer: Framebuffer,
    memory_map: [*]align(8) u8,
    memory_map_len: usize,
    memory_descriptor_size: usize,
    rsdp: u64,
};

pub const Framebuffer = display.Framebuffer;

pub fn start(info: BootInfo) noreturn {
    if (build_options.amd_rlc_resume and !build_options.amd_psp_ring)
        panic("AMDGPU RLC resume gate requires PSP firmware load gate");
    if (build_options.amd_mes_mmio and !build_options.amd_rlc_resume)
        panic("AMDGPU MES load gate requires RLC resume gate");
    if (build_options.amd_mes_activate and !build_options.amd_mes_mmio)
        panic("AMDGPU MES activation gate requires MES load gate");
    if (build_options.amd_mes_kiq and !build_options.amd_mes_activate)
        panic("AMDGPU MES KIQ gate requires MES activation gate");
    if (build_options.amd_mes_kiq_test and !build_options.amd_mes_kiq)
        panic("AMDGPU MES KIQ test gate requires KIQ activation gate");
    if (build_options.amd_mes_scheduler_map and !build_options.amd_mes_kiq_test)
        panic("AMDGPU MES scheduler map gate requires verified KIQ gate");
    if (build_options.amd_mes_scheduler_init and !build_options.amd_mes_scheduler_map)
        panic("AMDGPU MES scheduler init gate requires scheduler map gate");
    if (build_options.amd_mes_scheduler_resource1 and !build_options.amd_mes_scheduler_init)
        panic("AMDGPU MES scheduler resource1 gate requires scheduler init gate");
    if (build_options.amd_cp_gfx and !build_options.amd_mes_scheduler_resource1)
        panic("AMDGPU CP graphics gate requires complete MES scheduler resources");
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
    gpu.validateAmdPspHandoff(&pages) catch panic("AMDGPU PSP handoff self-test failed");
    gpu.validateAmdPspGtt(&pages) catch panic("AMDGPU PSP GTT self-test failed");
    gpu.validateAmdGmc11GartRollbackSelfTest() catch panic("AMDGPU GART rollback self-test failed");
    serial.write("CSOS M14 PSP handoff state machine ready\n");
    serial.write("physical allocator ready\n");

    var mapper = paging.Mapper.init(&pages, info.framebuffer.base, info.framebuffer.size) catch panic("paging setup failed");
    mapper.activate();
    serial.write("paging ready\n");
    const inventory = pci.Inventory.scan();
    if (inventory.count == 0) panic("PCI enumeration failed");
    if (inventory.findClass(0x06, 0x01) == null) panic("PCI ISA bridge missing");
    const display_device = inventory.findClass(0x03, 0x00) orelse
        inventory.findClass(0x03, 0x80) orelse panic("display adapter missing");
    syscalls.configureDrm(switch (display_device.vendor) {
        0x1002 => .amdgpu,
        0x10de => .nouveau,
        else => .csos,
    });

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
    serial.write("profile scheduler dispatch cycles p50: ");
    serial.writeDecimal(scheduler_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(scheduler_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(scheduler_latency.p99);
    serial.write(" migrations: ");
    serial.writeDecimal(scheduler.migrationCount());
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
    const drm_guard: *const volatile u32 = @ptrFromInt(info.framebuffer.base + 16380);
    const drm_guard_before = drm_guard.*;
    process.runDrmTest(mapper.root, &pages) catch {
        serial.write("DRM last request: ");
        serial.writeDecimal(syscalls.drm_last_request);
        serial.write(" result: ");
        serial.writeDecimal(syscalls.drm_last_result);
        serial.write("\n");
        panic("Linux DRM core userspace failed");
    };
    mapper.activate();
    const expected_drm_ioctls: u64 = if (display_device.vendor == 0x1002) 44 else 35;
    const expected_drm_objects: u64 = if (display_device.vendor == 0x1002) 4 else 3;
    if (syscalls.drm_ioctls != expected_drm_ioctls or syscalls.drm_mmaps != 2) panic("Linux DRM ioctl coverage failed");
    if (syscalls.drm_allocations != expected_drm_objects or syscalls.drm_releases != expected_drm_objects) panic("DRM backing memory lifecycle failed");
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
    serial.write("userspace reclaimed pages: ");
    serial.writeDecimal(pages.reclaimed_pages);
    serial.write("\nCSOS M17 process reclaim ready\n");
    serial.write("BusyBox applets returned\n");

    serial.write("PCI devices: ");
    serial.writeDecimal(inventory.count);
    serial.write("\n");
    const nvme_device = inventory.findClass(0x01, 0x08) orelse panic("NVMe controller missing");
    const nvme_bar = pci.barAddress(nvme_device, 0) orelse panic("NVMe BAR missing");
    mapper.mapIdentityUncached(nvme_bar, 0x4000) catch panic("NVMe MMIO mapping failed");
    if (!mapper.identityIsUncached(nvme_bar)) panic("NVMe MMIO cache policy failed");
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
    mapper.mapIdentityUncached(xhci_bar, 0x10000) catch panic("xHCI MMIO mapping failed");
    if (!mapper.identityIsUncached(xhci_bar)) panic("xHCI MMIO cache policy failed");
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
    serial.write("USB keyboards: ");
    serial.writeDecimal(hid.keyboards);
    serial.write(" mice: ");
    serial.writeDecimal(hid.mice);
    serial.write("\n");
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
    mapper.mapIdentityUncached(network_bar, 0x20000) catch panic("Ethernet MMIO mapping failed");
    if (!mapper.identityIsUncached(network_bar)) panic("Ethernet MMIO cache policy failed");
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
    serial.write("standby pages discarded: ");
    serial.writeDecimal(process.standby_pages);
    serial.write(" restored: ");
    serial.writeDecimal(process.restored_pages);
    serial.write("\nCSOS M17 persistent standby resume ready\n");
    serial.write("CSOS Linux socket ABI ready\n");
    var irq_spins: usize = 0;
    while (e1000.interruptCount() == 0 and irq_spins < 100_000_000) : (irq_spins += 1) asm volatile ("pause");
    asm volatile ("cli");
    if (e1000.interruptCount() == 0) panic("Ethernet MSI interrupt missing");
    if (e1000.interruptApic() != network_irq_apic) panic("Ethernet MSI affinity mismatch");
    const network_rx_latency = network.rx_latency.summarize() catch panic("Ethernet RX latency metrics missing");
    serial.write("profile Ethernet RX IRQ-to-consume cycles p50: ");
    serial.writeDecimal(network_rx_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(network_rx_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(network_rx_latency.p99);
    serial.write("\nCSOS M18 network processing latency ready\n");
    serial.write("Ethernet ARP ready\n");
    serial.write("Ethernet MSI ready\n");
    serial.write("Ethernet IRQ APIC: ");
    serial.writeDecimal(network_irq_apic);
    serial.write("\n");
    serial.write("xHCI MSI-X armed APIC: ");
    serial.writeDecimal(input_irq_apic);
    serial.write("\n");
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
    else
        0;
    const gpu_firmware_mappings = if (gpu_firmware) |firmware| firmware.mappingCount() catch panic("GPU firmware manifest invalid") else 0;
    const gpu_selection = if (gpu_firmware) |firmware| firmware.select(display_device, gpu_adapter.driver) catch panic("GPU firmware selection invalid") else null;
    const gpu_backend_entries = if (gpu_selection) |selection| selection.entries else 0;
    const gpu_required_blocks = if (gpu_selection) |selection| selection.required_blocks else 0;
    if ((gpu_adapter.driver == .amdgpu or gpu_adapter.driver == .nouveau) and gpu_selection == null) panic("GPU model firmware mapping missing");
    const gpu_validated_entries = if (gpu_firmware) |firmware|
        if (gpu_selection) |selection| firmware.validateSelection(selection, gpu_adapter.driver) catch panic("GPU firmware validation failed") else 0
    else
        0;
    var gpu_inventory = gpu.FirmwareInventory{};
    var gpu_ip_discovery: ?gpu.AmdIpDiscovery = null;
    var gpu_backend_plan: ?gpu.AmdBackendPlan = null;
    if (gpu_firmware) |firmware| if (gpu_selection) |selection| {
        gpu_inventory = firmware.inventory(selection, gpu_adapter.driver) catch panic("GPU firmware inventory invalid");
        if (gpu_adapter.driver == .amdgpu)
            gpu_ip_discovery = firmware.amdDiscovery(selection) catch panic("AMDGPU IP discovery invalid");
    };
    if (gpu_ip_discovery) |*discovery| gpu_backend_plan = gpu.planAmdBackend(discovery) catch panic("AMDGPU IP combination unsupported");
    const gpu_gfx_firmware = if (gpu_backend_plan) |plan| if (plan.gfx == .v11_0)
        (gpu_firmware orelse panic("AMDGPU firmware archive missing")).amdGfxFirmwareManifest(
            gpu_selection orelse panic("AMDGPU firmware selection missing"),
            plan.gfx,
        ) catch panic("AMDGPU GFX11 firmware set incomplete")
    else
        null else null;
    const gpu_mes_firmware = if (gpu_gfx_firmware != null)
        (gpu_firmware orelse panic("AMDGPU firmware archive missing")).amdMesFirmwareSet(
            gpu_selection orelse panic("AMDGPU firmware selection missing"),
        ) catch panic("AMDGPU MES firmware selection failed")
    else
        null;
    const gpu_cp_firmware = if (gpu_gfx_firmware != null)
        (gpu_firmware orelse panic("AMDGPU firmware archive missing")).amdGfx11CpFirmwareSet(
            gpu_selection orelse panic("AMDGPU firmware selection missing"),
        ) catch panic("AMDGPU CP/RLC firmware selection failed")
    else
        null;
    const gpu_cp_firmware_staging = if (gpu_cp_firmware) |firmware|
        gpu.stageAmdGfx11CpFirmwareSet(firmware, &pages) catch panic("AMDGPU CP/RLC firmware staging failed")
    else
        gpu.AmdGfx11CpFirmwareStaging{};
    const gpu_mes_firmware_staging = if (gpu_mes_firmware) |firmware|
        gpu.stageAmdMesFirmwareSet(firmware, &pages) catch panic("AMDGPU MES firmware staging failed")
    else
        gpu.AmdMesFirmwareStaging{};
    const gpu_gfx_ring_resources = if (gpu_gfx_firmware != null)
        gpu.allocateAmdGfx11RingResources(gpu.physicalAmdGpuVmPageAllocator(&pages)) catch
            panic("AMDGPU GFX11 ring resource allocation failed")
    else
        gpu.AmdGfx11RingResources{};
    const gpu_mes_control_resources = if (gpu_gfx_firmware != null)
        gpu.allocateAmdMesControlResources(gpu.physicalAmdGpuVmPageAllocator(&pages)) catch
            panic("AMDGPU MES control resource allocation failed")
    else
        gpu.AmdMesControlResources{};
    const gpu_rlc_resources = if (gpu_gfx_firmware != null)
        gpu.allocateAmdGfx11RlcResources(gpu.physicalAmdGpuVmPageAllocator(&pages)) catch
            panic("AMDGPU GFX11 RLC clear-state allocation failed")
    else
        gpu.AmdGfx11RlcResources{};
    const gpu_gfx_command_ring_resources = if (gpu_gfx_firmware != null)
        gpu.allocateAmdGfx11GfxRingResources(gpu.physicalAmdGpuVmPageAllocator(&pages)) catch
            panic("AMDGPU GFX11 graphics command ring allocation failed")
    else
        gpu.AmdGfx11GfxRingResources{};
    if (gpu_gfx_firmware != null)
        gpu.prepareAmdGfx11GfxRingClearState(gpu_gfx_command_ring_resources, gpu_rlc_resources) catch
            panic("AMDGPU graphics clear-state ring preparation failed");
    const gpu_memory_plan = if (gpu_backend_plan) |plan| gpu.planAmdMemory(gpu_adapter.bars, gpu_adapter.register_bar, plan.gmc) catch
        panic("AMDGPU memory apertures invalid") else null;
    const gpu_psp_gtt = if (gpu_memory_plan != null) gpu.prepareAmdPspGtt(&pages) catch panic("AMDGPU PSP GTT staging failed") else gpu.AmdPspGttStaging{};
    var gpu_gart_plan = if (gpu_memory_plan) |memory| gpu.planAmdGart(&gpu_ip_discovery.?, memory, gpu_psp_gtt) catch
        panic("AMDGPU GART plan invalid") else null;
    const gpu_gart_registers = if (gpu_gart_plan) |plan| if (plan.family == .v11_0)
        gpu.resolveAmdGmc11GartRegisters(plan, gpu_adapter.register_bar.?.size) catch panic("AMDGPU GART registers invalid")
    else
        null else null;
    const gpu_gmc11_nbio_registers = if (gpu_gart_plan) |plan| if (plan.family == .v11_0) blk: {
        const nbio_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.nbif, 0) orelse panic("AMDGPU NBIO IP missing");
        break :blk gpu.resolveAmdGmc11NbioRegisters(nbio_ip, gpu_adapter.register_bar.?.size) catch panic("AMDGPU NBIO registers invalid");
    } else null else null;
    var gpu_firmware_staging = gpu.AmdFirmwareStaging{};
    var gpu_psp_boot_images: ?gpu.AmdPspBootImages = null;
    var gpu_psp_handoff = gpu.AmdPspHandoff{};
    if (gpu_backend_plan != null) {
        const firmware = gpu_firmware orelse panic("AMDGPU firmware archive missing");
        const selection = gpu_selection orelse panic("AMDGPU firmware selection missing");
        gpu_firmware_staging = firmware.stageAmdSecurity(selection, &pages) catch panic("AMDGPU security firmware staging failed");
        if (gpu_backend_plan.?.psp.host_boot_components) {
            gpu_psp_boot_images = gpu.selectAmdPspBootImages(&gpu_firmware_staging, gpu_backend_plan.?.psp, .unknown) catch
                panic("AMDGPU PSP boot image selection failed");
            const profile = gpu.amdPspMailboxProfile(gpu_backend_plan.?.psp) catch panic("AMDGPU PSP mailbox unsupported");
            gpu_psp_handoff = gpu.prepareAmdPspHandoff(gpu_psp_boot_images.?, profile, &pages) catch
                panic("AMDGPU PSP handoff preparation failed");
        }
    }
    const gpu_psp_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.psp, 0)) |ip| ip.major else 0 else 0;
    const gpu_gfx_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.gfx, 0)) |ip| ip.major else 0 else 0;
    const gpu_mmhub_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.mmhub, 0)) |ip| ip.major else 0 else 0;
    const gpu_sdma_major = if (gpu_ip_discovery) |discovery| if (discovery.find(gpu.amd_hw_id.sdma0, 0)) |ip| ip.major else 0 else 0;
    const gpu_registers = gpu_adapter.register_bar orelse panic("GPU register BAR missing");
    if (gpu_registers.size > 16 * 1024 * 1024) panic("GPU register BAR unexpectedly large");
    var gpu_psp_mailbox_profile: ?gpu.AmdPspMailboxProfile = null;
    var gpu_psp_mailbox_registers: ?gpu.AmdPspMailboxRegisters = null;
    var gpu_psp_ring_registers: ?gpu.AmdPspRingRegisters = null;
    const gpu_mes_registers = if (gpu_backend_plan) |plan| if (plan.gfx == .v11_0) blk: {
        const gfx_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.gfx, 0) orelse panic("AMDGPU GFX IP missing");
        break :blk gpu.resolveAmdGfx11MesRegisters(gfx_ip, gpu_registers.size) catch panic("AMDGPU MES registers invalid");
    } else null else null;
    const gpu_rlc_registers = if (gpu_backend_plan) |plan| if (plan.gfx == .v11_0) blk: {
        const gfx_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.gfx, 0) orelse panic("AMDGPU GFX IP missing");
        break :blk gpu.resolveAmdGfx11RlcRegisters(gfx_ip, gpu_registers.size) catch panic("AMDGPU RLC registers invalid");
    } else null else null;
    const gpu_cp_gfx_registers = if (gpu_backend_plan) |plan| if (plan.gfx == .v11_0) blk: {
        const gfx_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.gfx, 0) orelse panic("AMDGPU GFX IP missing");
        break :blk gpu.resolveAmdGfx11CpGfxRegisters(gfx_ip, gpu_registers.size) catch panic("AMDGPU CP graphics registers invalid");
    } else null else null;
    const gpu_cu_registers = if (gpu_backend_plan) |plan| if (plan.gfx == .v11_0) blk: {
        const gfx_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.gfx, 0) orelse panic("AMDGPU GFX IP missing");
        break :blk gpu.resolveAmdGfx11CuRegisters(gfx_ip, gpu_registers.size) catch panic("AMDGPU CU registers invalid");
    } else null else null;
    if (gpu_backend_plan) |plan| if (plan.psp.host_boot_components) {
        const psp_ip = if (gpu_ip_discovery) |*discovery| discovery.find(gpu.amd_hw_id.psp, 0) orelse
            panic("AMDGPU PSP IP missing") else panic("AMDGPU IP discovery missing");
        const profile = gpu.amdPspMailboxProfile(plan.psp) catch panic("AMDGPU PSP mailbox unsupported");
        gpu_psp_mailbox_profile = profile;
        gpu_psp_mailbox_registers = gpu.resolveAmdPspMailboxRegisters(psp_ip, profile, gpu_registers.size) catch
            panic("AMDGPU PSP mailbox registers invalid");
        if (plan.psp.ip_version == 0x0d0002)
            gpu_psp_ring_registers = gpu.resolveAmdPsp13RingRegisters(psp_ip, gpu_registers.size) catch
                panic("AMDGPU PSP ring registers invalid");
    };
    mapper.mapIdentityUncached(gpu_registers.address, gpu_registers.size) catch panic("GPU register MMIO mapping failed");
    if (!mapper.identityIsUncached(gpu_registers.address)) panic("GPU register MMIO cache policy failed");
    if (gpu_memory_plan) |plan| {
        mapper.mapIdentityUncached(plan.doorbell_bar.address, plan.doorbell_bar.size) catch panic("AMDGPU doorbell mapping failed");
        if (!mapper.identityIsUncached(plan.doorbell_bar.address)) panic("AMDGPU doorbell cache policy failed");
    }
    if (gpu_adapter.rom_bar) |rom| {
        if (rom.size == 0 or rom.size > 1024 * 1024) panic("GPU expansion ROM size invalid");
        mapper.mapIdentityUncached(rom.address, rom.size) catch panic("GPU expansion ROM mapping failed");
        if (!mapper.identityIsUncached(rom.address)) panic("GPU expansion ROM cache policy failed");
    }
    mapper.activate();
    const gpu_cu_info = if (gpu_cu_registers != null and gpu_ip_discovery.?.gc_info != null)
        gpu.probeAmdGfx11CuInfo(&gpu_adapter, gpu_cu_registers.?, gpu_ip_discovery.?.gc_info.?) catch panic("AMDGPU active CU probe failed")
    else
        null;
    const gpu_mes_control = if (gpu_mes_registers) |registers|
        gpu_adapter.readRegister(registers.mes_control) catch panic("AMDGPU MES control read failed")
    else
        0;
    const gpu_mes_halted = gpu_mes_registers != null and gpu.amdGfx11MesIsHalted(gpu_mes_control);
    var gpu_atom_vram_usage: ?gpu.AmdAtomVramUsage = null;
    var gpu_atom_firmware_info: ?gpu.AmdAtomFirmwareInfo = null;
    var gpu_atom_vram_info: ?gpu.AmdAtomVramInfo = null;
    var gpu_rom_read = false;
    var gpu_rom_restored = false;
    if (gpu_adapter.rom_bar) |rom| {
        const rom_pages = (rom.size + 4095) / 4096;
        const rom_copy = pages.allocate(rom_pages) orelse panic("GPU expansion ROM buffer failed");
        const bytes: [*]u8 = @ptrFromInt(rom_copy);
        pci.copyExpansionRom(gpu_adapter.device, rom, bytes[0..rom.size]) catch panic("GPU expansion ROM read failed");
        gpu_rom_read = true;
        if (gpu_adapter.isAmd()) {
            gpu_atom_vram_usage = gpu.parseAmdAtomVramUsage(bytes[0..rom.size]) catch null;
            gpu_atom_firmware_info = gpu.parseAmdAtomFirmwareInfo(bytes[0..rom.size]) catch null;
            gpu_atom_vram_info = gpu.parseAmdAtomVramInfo(bytes[0..rom.size]) catch null;
        }
        pages.release(rom_copy, rom_pages) catch panic("GPU expansion ROM buffer release failed");
        const restored = pci.romInfo(gpu_adapter.device, false) orelse panic("GPU expansion ROM restore missing");
        gpu_rom_restored = restored.address == rom.address and restored.enabled == rom.enabled;
        if (!gpu_rom_restored) panic("GPU expansion ROM state not restored");
    }
    const gpu_clock_info = if (gpu_atom_firmware_info) |atom| gpu.amdGpuClockInfo(atom) catch null else null;
    const gpu_pcie_link = inventory.pciePathLink(display_device) catch null;
    const gpu_cache_info = if (gpu_ip_discovery.?.gc_info) |topology| topology.cacheInfo() catch null else null;
    if (gpu_adapter.driver == .amdgpu and gpu_gmc11_nbio_registers != null and gpu_ip_discovery.?.gc_info != null and gpu_cu_info != null and gpu_clock_info != null and gpu_pcie_link != null and gpu_atom_vram_info != null and gpu_cache_info != null) {
        const gfx_ip = gpu_ip_discovery.?.find(gpu.amd_hw_id.gfx, 0) orelse panic("AMDGPU GFX IP missing");
        const strap = gpu_adapter.readRegister(gpu_gmc11_nbio_registers.?.revision_strap) catch panic("AMDGPU revision strap read failed");
        const identity = gpu.decodeAmdGfx11AsicIdentity(gfx_ip, strap) catch panic("AMDGPU ASIC identity unsupported");
        if (identity.device_id != display_device.device) panic("AMDGPU revision strap PCI identity mismatch");
        syscalls.configureAmdGpuInfoProfile(.{
            .pci_device = identity.device_id,
            .pci_revision = display_device.revision,
            .chip_revision = identity.chip_rev,
            .external_revision = identity.external_rev,
            .family = identity.family,
            .gfx_major = gfx_ip.major,
            .gfx_minor = gfx_ip.minor,
            .gfx_revision = gfx_ip.revision,
            .topology = gpu_ip_discovery.?.gc_info.?,
            .cu_info = gpu_cu_info.?,
            .clocks = gpu_clock_info.?,
            .pcie_generation = gpu_pcie_link.?.generation,
            .pcie_width = gpu_pcie_link.?.width,
            .vm_info = gpu.amdGpuVmInfo(),
            .vram_info = gpu_atom_vram_info.?,
            .cache_info = gpu_cache_info.?,
        });
    } else syscalls.configureAmdGpuInfoProfile(null);
    const gpu_gmc11_memory = if (gpu_gart_registers) |registers| gpu.decodeAmdGmc11MemorySnapshot(
        gpu_adapter.readRegister(registers.fb_location_base) catch panic("AMDGPU VRAM MC base read failed"),
        gpu_adapter.readRegister(registers.fb_offset) catch panic("AMDGPU VRAM MC offset read failed"),
        gpu_adapter.readRegister(gpu_gmc11_nbio_registers.?.memsize) catch panic("AMDGPU VRAM size read failed"),
    ) catch panic("AMDGPU memory topology unavailable") else null;
    const gpu_gmc11_gart_window = if (gpu_gmc11_memory) |memory| gpu.planAmdGmc11HighGartWindow(memory, gpu_gart_plan.?.window_bytes) catch
        panic("AMDGPU GART high window invalid") else null;
    const gpu_psp_ring_layout = if (gpu_gmc11_gart_window != null)
        gpu.planAmdPspRingLayout(gpu_psp_gtt, gpu_gmc11_gart_window.?.start) catch panic("AMDGPU PSP ring GART layout invalid")
    else
        null;
    const gpu_gfx_mes_bootstrap = if (gpu_gfx_firmware != null and gpu_gmc11_gart_window != null)
        gpu.prepareAmdGfx11MesBootstrap(
            gpu_psp_gtt,
            gpu_gfx_ring_resources,
            gpu_gmc11_gart_window.?.start,
            gpu_memory_plan.?.doorbell_bar.size,
        ) catch panic("AMDGPU GFX11 MES bootstrap preparation failed")
    else
        null;
    const gpu_mes_firmware_gpu = if (gpu_mes_firmware != null and gpu_gmc11_gart_window != null)
        gpu.mapAmdMesFirmwareIntoGart(gpu_psp_gtt, gpu_mes_firmware_staging, gpu_gmc11_gart_window.?.start) catch
            panic("AMDGPU MES firmware GART mapping failed")
    else
        null;
    const gpu_mes_control_gpu = if (gpu_mes_firmware_gpu != null)
        gpu.mapAmdMesControlIntoGart(
            gpu_psp_gtt,
            gpu_mes_firmware_gpu.?,
            gpu_mes_control_resources,
            gpu_gmc11_gart_window.?.start,
        ) catch panic("AMDGPU MES control GART mapping failed")
    else
        null;
    const gpu_cp_firmware_gpu = if (gpu_mes_control_gpu) |control|
        gpu.mapAmdGfx11CpFirmwareIntoGart(
            gpu_psp_gtt,
            gpu_cp_firmware_staging,
            control.first_gart_page,
            gpu_gmc11_gart_window.?.start,
        ) catch panic("AMDGPU CP/RLC firmware GART mapping failed")
    else
        null;
    const gpu_rlc_gpu = if (gpu_cp_firmware_gpu) |firmware|
        gpu.mapAmdGfx11RlcIntoGart(gpu_psp_gtt, firmware, gpu_rlc_resources, gpu_gmc11_gart_window.?.start) catch
            panic("AMDGPU RLC clear-state GART mapping failed")
    else
        null;
    const gpu_gfx_command_ring = if (gpu_rlc_gpu) |layout|
        gpu.mapAmdGfx11GfxRingIntoGart(
            gpu_psp_gtt,
            layout,
            gpu_gfx_command_ring_resources,
            gpu_gmc11_gart_window.?.start,
            gpu_memory_plan.?.doorbell_bar.size,
        ) catch panic("AMDGPU graphics command ring GART mapping failed")
    else
        null;
    const gpu_rlc_resume_plan = if (gpu_rlc_gpu) |layout|
        gpu.planAmdGfx11RlcResume(gpu_rlc_registers.?, layout) catch panic("AMDGPU RLC resume plan invalid")
    else
        null;
    const gpu_cp_gfx_plan = if (gpu_gfx_command_ring) |layout|
        gpu.planAmdGfx11CpGfxResume(gpu_cp_gfx_registers.?, layout) catch panic("AMDGPU CP graphics resume plan invalid")
    else
        null;
    const gpu_mes_hw_resources = if (gpu_mes_control_gpu) |control|
        gpu.planAmdGfx11MesHwResources(
            &gpu_ip_discovery.?,
            control,
            gpu_memory_plan.?.doorbell_bar.size,
        ) catch panic("AMDGPU MES hardware topology invalid")
    else
        null;
    const gpu_mes_scheduler_load = if (gpu_mes_halted) if (gpu_mes_firmware) |firmware| if (gpu_mes_firmware_gpu) |layout| if (gpu_mes_registers) |registers|
        gpu.planAmdGfx11MesLoad(.scheduler, firmware.scheduler, layout.scheduler_ucode, layout.scheduler_data, registers, true) catch
            panic("AMDGPU MES scheduler load plan invalid")
    else
        null else null else null else null;
    const gpu_mes_kiq_load = if (gpu_mes_halted) if (gpu_mes_firmware) |firmware| if (gpu_mes_firmware_gpu) |layout| if (gpu_mes_registers) |registers|
        gpu.planAmdGfx11MesLoad(.kiq, firmware.kiq, layout.kiq_ucode, layout.kiq_data, registers, true) catch
            panic("AMDGPU MES KIQ load plan invalid")
    else
        null else null else null else null;
    const gpu_mes_kiq_plan = if (gpu_gfx_mes_bootstrap != null) blk: {
        const mqd: *const [512]u32 = @ptrFromInt(gpu_gfx_ring_resources.kiq.mqd);
        break :blk gpu.planAmdGfx11KiqHqd(gpu_mes_registers.?, mqd) catch panic("AMDGPU MES KIQ HQD plan invalid");
    } else null;
    const gpu_gmc11_visible_vram = if (gpu_gmc11_memory) |memory| if (gpu_memory_plan.?.vram_bar) |bar|
        gpu.mapAmdGmc11VisibleVram(memory, bar, info.framebuffer.base, info.framebuffer.size) catch panic("AMDGPU visible VRAM mapping invalid")
    else
        null else null;
    var gpu_vram_allocator = if (gpu_gmc11_visible_vram) |visible| gpu.AmdVramAllocator.init(visible) catch
        panic("AMDGPU VRAM allocator invalid") else null;
    const gpu_firmware_tail_bytes: u64 = if (gpu_atom_firmware_info) |atom| if (atom.reserved_kib != 0)
        @as(u64, atom.reserved_kib) * 1024
    else
        64 * 1024 else 64 * 1024;
    const gpu_memory_training_reserved = if (gpu_atom_firmware_info) |atom| (atom.capability & 0x400) != 0 else false;
    var gpu_gart_table_vram: ?gpu.AmdVramAllocation = null;
    var gpu_gmc11_system_pages: ?gpu.AmdGmc11SystemPages = null;
    var gpu_gmc11_system_aperture: ?gpu.AmdGmc11SystemApertureValues = null;
    var gpu_gart_aperture: ?gpu.AmdGmc11GartApertureValues = null;
    var gpu_gart_rollback_registers: usize = 0;
    var gpu_gart_mmio_transport: ?gpu.AmdGmc11MmioTransport = null;
    if (gpu_vram_allocator) |*allocator| {
        gpu.reserveAmdGmc11BootVram(allocator, gpu_gmc11_memory.?, gpu_firmware_tail_bytes, gpu_memory_training_reserved) catch
            panic("AMDGPU boot VRAM reservations invalid");
        allocator.sealFirmwareMap();
        const allocation = allocator.allocatePinned(4096, 4096) catch panic("AMDGPU GART table VRAM allocation failed");
        mapper.mapIdentityUncached(allocation.cpu_address, allocation.bytes) catch panic("AMDGPU GART table VRAM mapping failed");
        mapper.activate();
        gpu.copyAmdGmc11GartTable(gpu_gart_plan.?, allocation) catch panic("AMDGPU GART table VRAM copy failed");
        gpu_gart_plan = gpu.bindAmdGmc11GartAddressSpace(gpu_gart_plan.?, allocation.mc_address, gpu_gmc11_gart_window.?.start) catch
            panic("AMDGPU GART address space binding failed");
        gpu_gart_aperture = gpu.prepareAmdGmc11GartAperture(gpu_gart_plan.?) catch panic("AMDGPU GART aperture preparation failed");
        const rollback_registers = gpu.amdGmc11GartMutableRegisters(gpu_gart_registers.?) catch
            panic("AMDGPU GART rollback register set invalid");
        gpu.validateAmdGmc11GartRollback(rollback_registers) catch panic("AMDGPU GART rollback validation failed");
        gpu_gart_rollback_registers = rollback_registers.count;
        gpu_gart_table_vram = allocation;
        const system_pages = gpu.prepareAmdGmc11SystemPages(allocator, gpu_gmc11_memory.?, &pages) catch
            panic("AMDGPU system aperture pages failed");
        mapper.mapIdentityUncached(system_pages.scratch.cpu_address, system_pages.scratch.bytes) catch
            panic("AMDGPU scratch VRAM mapping failed");
        mapper.activate();
        gpu.clearAmdGmc11Scratch(system_pages);
        gpu_gmc11_system_pages = system_pages;
        gpu_gmc11_system_aperture = gpu.prepareAmdGmc11SystemAperture(gpu_gmc11_memory.?, system_pages) catch
            panic("AMDGPU system aperture values invalid");
        gpu.validateAmdGmc11BootstrapWrites(gpu_gart_registers.?, gpu_gart_aperture.?, gpu_gmc11_system_aperture.?) catch
            panic("AMDGPU GART bootstrap write-set validation failed");
        gpu_gart_mmio_transport = .{ .adapter = &gpu_adapter, .uncached = true };
    }
    var gpu_psp_mailbox_snapshot: ?gpu.AmdPspMailboxSnapshot = null;
    var gpu_psp_mmio_transport: ?gpu.AmdPspMmioTransport = null;
    var gpu_psp_preflight: ?gpu.AmdPspPreflight = null;
    var gpu_psp_mailbox_waited = false;
    var gpu_psp_ring_control: u32 = 0;
    var gpu_psp_ring_bootstrap: ?gpu.AmdPspRingBootstrap = null;
    if (gpu_psp_mailbox_registers) |registers| {
        const command = gpu_adapter.readRegister(registers.command_offset) catch panic("AMDGPU PSP command read failed");
        const sos = gpu_adapter.readRegister(registers.sos_offset) catch panic("AMDGPU PSP sOS read failed");
        gpu_psp_mailbox_snapshot = gpu.classifyAmdPspMailbox(gpu_psp_mailbox_profile.?, command, sos) catch
            panic("AMDGPU PSP mailbox unavailable");
        gpu_psp_mmio_transport = .{ .adapter = &gpu_adapter, .profile = gpu_psp_mailbox_profile.?, .registers = registers, .uncached = true, .authorized = gpu_selection.?.psp_host_boot };
        if (gpu_psp_mmio_transport) |*transport| {
            if (transport.authorized and gpu_psp_mailbox_snapshot.?.state == .bootloader_busy) {
                gpu_psp_mailbox_waited = true;
                gpu_psp_mailbox_snapshot = gpu.waitAmdPspMailbox(transport.observer(), .{
                    .context = &gpu_psp_handoff,
                    .now = &pspTimerTicks,
                }, 100, 1_000_000_000) catch panic("AMDGPU PSP mailbox readiness failed");
            }
            gpu_psp_preflight = gpu.preflightAmdPspHandoff(&gpu_psp_handoff, transport, gpu_psp_mailbox_snapshot.?) catch
                panic("AMDGPU PSP handoff preflight failed");
            switch (gpu_psp_preflight.?) {
                .ready => {
                    transport.arm(gpu_psp_mailbox_snapshot.?) catch panic("AMDGPU PSP transport arming failed");
                    _ = gpu.runAmdPspHandoff(&gpu_psp_handoff, transport.transport(), .{
                        .context = &gpu_psp_handoff,
                        .now = &pspTimerTicks,
                    }, 100, 1_000_000_000) catch {
                        transport.disarm();
                        panic("AMDGPU PSP host boot failed");
                    };
                    transport.disarm();
                },
                .already_running => {
                    gpu_psp_handoff.current = gpu_psp_handoff.count;
                    gpu_psp_handoff.state = .finished;
                },
                .blocked_uncached, .blocked_unauthorized, .mailbox_busy => {},
            }
        }
    }
    const gpu_psp_ready = (gpu_psp_mailbox_snapshot != null and gpu_psp_mailbox_snapshot.?.state == .sos_alive) or
        gpu_psp_handoff.state == .finished;
    if (gpu_psp_ready and gpu_psp_ring_registers != null and gpu_psp_ring_layout != null) {
        gpu_psp_ring_control = gpu_adapter.readRegister(gpu_psp_ring_registers.?.control) catch
            panic("AMDGPU PSP ring control read failed");
        gpu_psp_ring_bootstrap = gpu.planAmdPsp13RingBootstrap(
            gpu_psp_ring_registers.?,
            gpu_psp_ring_layout.?,
            gpu_psp_ring_control,
        ) catch null;
    }
    var gpu_mes_loads: u8 = 0;
    var gpu_mes_activation: ?gpu.AmdGfx11MesActivation = null;
    var gpu_mes_kiq_active = false;
    var gpu_mes_kiq_test_polls: u32 = 0;
    var gpu_mes_scheduler_map_polls: u32 = 0;
    var gpu_mes_scheduler_init_polls: u32 = 0;
    var gpu_mes_scheduler_resource1_polls: u32 = 0;
    var gpu_mes_scheduler_ready = false;
    var gpu_cp_gfx_ready = false;
    var gpu_cp_gfx_polls: u32 = 0;
    var gpu_cp_gfx_test_polls: u32 = 0;
    var gpu_psp_ring_activation: ?gpu.AmdPspRingActivation = null;
    var gpu_psp_firmware_load: ?gpu.AmdPspFirmwareLoadResult = null;
    var gpu_rlc_resumed = false;
    if (gpu_gart_mmio_transport) |*transport| {
        transport.authorize(.{
            .selected_firmware_entries = gpu_backend_entries,
            .validated_firmware_entries = gpu_validated_entries,
            .security_firmware_entries = gpu_inventory.block(.security).entries,
            .compatible_ip_discovery = gpu_backend_plan.?.gmc == .v11_0,
            .psp_ready = gpu_psp_ready,
            .gart_table_bound = gpu_gart_plan.?.table_mc_address != null,
            .gart_window_bound = gpu_gart_plan.?.window_start != null and gpu_gart_plan.?.window_end != null,
            .rollback_registers = gpu_gart_rollback_registers,
        }) catch panic("AMDGPU GART MMIO authorization rejected");
        if (build_options.amd_gart_mmio) {
            if (build_options.amd_gart_device == 0 or build_options.amd_gart_device != gpu_adapter.device.device)
                panic("AMDGPU GART activation PCI device gate mismatch");
            transport.arm() catch panic("AMDGPU GART MMIO arming failed");
            gpu.prepareAmdGmc11Activation(
                &gpu_gmc11_activation_workspace,
                gpu_gart_registers.?,
                gpu_gart_aperture.?,
                gpu_gmc11_system_aperture.?,
                transport.io(),
            ) catch {
                transport.disarm();
                panic("AMDGPU GART activation preparation failed");
            };
            _ = gpu.commitAmdGmc11Activation(
                &gpu_gmc11_activation_workspace,
                gpu_gart_registers.?,
                100_000,
                transport.io(),
            ) catch {
                transport.disarm();
                panic("AMDGPU GART activation failed and rolled back");
            };
            gpu_gart_plan.?.active = true;
            transport.disarm();
            gpu_vm_runtime = .{ .transport = transport.*, .registers = gpu_gart_registers.?, .active = true };
            syscalls.configureDrmGpuVmHardware(.{
                .context = &gpu_vm_runtime,
                .bind = &bindDrmGpuVm,
                .invalidate = &invalidateDrmGpuVm,
                .unbind = &unbindDrmGpuVm,
            });
        }
        if (build_options.amd_psp_ring) {
            if (!build_options.amd_gart_mmio or !gpu_gmc11_activation_workspace.active or
                build_options.amd_gart_device == 0 or build_options.amd_gart_device != gpu_adapter.device.device)
                panic("AMDGPU PSP ring gate requires matching active GART");
            const bootstrap = gpu_psp_ring_bootstrap orelse panic("AMDGPU PSP ring bootstrap unavailable");
            const firmware = gpu_cp_firmware_gpu orelse panic("AMDGPU CP/RLC GPU firmware layout unavailable");
            transport.arm() catch panic("AMDGPU PSP ring MMIO arming failed");
            gpu_psp_ring_activation = gpu.activateAmdPsp13Ring(bootstrap, transport.io(), 1_000_000) catch {
                transport.disarm();
                panic("AMDGPU PSP KM ring activation failed");
            };
            gpu_psp_firmware_load = gpu.loadAmdPspIpFirmwareSequence(
                firmware,
                gpu_psp_ring_layout.?,
                gpu_psp_gtt,
                gpu_psp_ring_registers.?,
                gpu_psp_ring_activation.?.write_pointer,
                transport.io(),
                2_100_000,
            ) catch {
                transport.disarm();
                gpu_psp_ring_activation = null;
                panic("AMDGPU PSP LOAD_IP_FW sequence failed");
            };
            transport.disarm();
        }
        if (build_options.amd_rlc_resume) {
            if (!build_options.amd_gart_mmio or !build_options.amd_psp_ring or !gpu_gmc11_activation_workspace.active or
                gpu_psp_firmware_load == null or gpu_psp_firmware_load.?.loaded != gpu_cp_firmware_gpu.?.count or
                build_options.amd_gart_device == 0 or build_options.amd_gart_device != gpu_adapter.device.device)
                panic("AMDGPU RLC resume gate requires matching GART and loaded CP/RLC firmware");
            const plan = gpu_rlc_resume_plan orelse panic("AMDGPU RLC resume plan unavailable");
            transport.arm() catch panic("AMDGPU RLC resume MMIO arming failed");
            _ = gpu.executeAmdGfx11RlcResume(plan, transport.io()) catch {
                transport.disarm();
                panic("AMDGPU RLC resume failed and rolled back");
            };
            transport.disarm();
            gpu_rlc_resumed = true;
        }
        if (build_options.amd_mes_mmio) {
            if (!build_options.amd_gart_mmio or !build_options.amd_psp_ring or !build_options.amd_rlc_resume or !gpu_rlc_resumed or
                !gpu_gmc11_activation_workspace.active or
                gpu_psp_firmware_load == null or gpu_psp_firmware_load.?.loaded != gpu_cp_firmware_gpu.?.count or
                build_options.amd_gart_device == 0 or build_options.amd_gart_device != gpu_adapter.device.device)
                panic("AMDGPU MES load gate requires matching GART and loaded CP/RLC firmware");
            const scheduler_plan = gpu_mes_scheduler_load orelse panic("AMDGPU MES scheduler load plan unavailable");
            const kiq_plan = gpu_mes_kiq_load orelse panic("AMDGPU MES KIQ load plan unavailable");
            const current_mes_control = gpu_adapter.readRegister(gpu_mes_registers.?.mes_control) catch
                panic("AMDGPU MES control revalidation failed");
            if (!gpu.amdGfx11MesIsHalted(current_mes_control)) panic("AMDGPU MES left halted state before load");
            transport.arm() catch panic("AMDGPU MES MMIO arming failed");
            const scheduler_transaction = gpu.executeAmdGfx11MesLoad(scheduler_plan, transport.io()) catch {
                transport.disarm();
                panic("AMDGPU MES scheduler load failed and rolled back");
            };
            gpu_mes_loads = 1;
            _ = gpu.executeAmdGfx11MesLoad(kiq_plan, transport.io()) catch {
                gpu.restoreAmdGfx11MesLoad(scheduler_plan, scheduler_transaction, transport.io()) catch {
                    transport.disarm();
                    panic("AMDGPU MES dual-pipe rollback failed");
                };
                gpu_mes_loads = 0;
                transport.disarm();
                panic("AMDGPU MES KIQ load failed and rolled back");
            };
            gpu_mes_loads = 2;
            transport.disarm();
            if (build_options.amd_mes_activate) {
                transport.arm() catch panic("AMDGPU MES activation MMIO arming failed");
                gpu_mes_activation = gpu.activateAmdGfx11Mes(
                    gpu_mes_registers.?,
                    gpu_mes_firmware.?.scheduler.ucode_start,
                    gpu_mes_firmware.?.kiq.ucode_start,
                    100_000,
                    transport.io(),
                ) catch {
                    transport.disarm();
                    panic("AMDGPU MES activation handshake failed and returned to halt");
                };
                transport.disarm();
                if (build_options.amd_mes_kiq) {
                    const kiq_hqd_plan = gpu_mes_kiq_plan orelse panic("AMDGPU MES KIQ HQD plan unavailable");
                    transport.arm() catch panic("AMDGPU MES KIQ MMIO arming failed");
                    const kiq_transaction = gpu.activateAmdGfx11Kiq(kiq_hqd_plan, transport.io()) catch {
                        gpu.haltAmdGfx11Mes(gpu_mes_registers.?, transport.io()) catch {
                            transport.disarm();
                            panic("AMDGPU MES KIQ failure could not halt MES");
                        };
                        gpu_mes_activation = null;
                        transport.disarm();
                        panic("AMDGPU MES KIQ activation failed and rolled back");
                    };
                    gpu_mes_kiq_active = true;
                    if (build_options.amd_mes_kiq_test) {
                        const bootstrap = gpu_gfx_mes_bootstrap orelse panic("AMDGPU MES KIQ bootstrap unavailable");
                        const test_plan = gpu.planAmdGfx11KiqTest(gpu_mes_registers.?, bootstrap.kiq_doorbell) catch
                            panic("AMDGPU MES KIQ test plan invalid");
                        var doorbell_transport = gpu.AmdGfx11DoorbellTransport{
                            .aperture = gpu_memory_plan.?.doorbell_bar,
                            .expected_offset = bootstrap.kiq_doorbell.byte_offset,
                            .uncached = true,
                        };
                        doorbell_transport.authorize(bootstrap.kiq_doorbell) catch
                            panic("AMDGPU MES KIQ doorbell authorization rejected");
                        doorbell_transport.arm() catch panic("AMDGPU MES KIQ doorbell arming failed");
                        const ring: *[1024]u32 = @ptrFromInt(gpu_gfx_ring_resources.kiq.ring);
                        const pointers: *[2]u64 = @ptrFromInt(gpu_gfx_ring_resources.kiq.pointers);
                        gpu_mes_kiq_test_polls = gpu.testAmdGfx11Kiq(
                            test_plan,
                            ring,
                            pointers,
                            100_000,
                            transport.io(),
                            doorbell_transport.io(),
                        ) catch {
                            doorbell_transport.disarm();
                            gpu.restoreAmdGfx11Kiq(kiq_hqd_plan, &kiq_transaction, transport.io()) catch {
                                transport.disarm();
                                panic("AMDGPU MES KIQ test rollback failed");
                            };
                            gpu.haltAmdGfx11Mes(gpu_mes_registers.?, transport.io()) catch {
                                transport.disarm();
                                panic("AMDGPU MES KIQ test failure could not halt MES");
                            };
                            gpu_mes_kiq_active = false;
                            gpu_mes_activation = null;
                            transport.disarm();
                            panic("AMDGPU MES KIQ ring test failed and rolled back");
                        };
                        doorbell_transport.disarm();
                        if (build_options.amd_mes_scheduler_map) {
                            const scheduler_mqd: *const [512]u32 = @ptrFromInt(gpu_gfx_ring_resources.scheduler.mqd);
                            const map_plan = gpu.planAmdGfx11MesSchedulerMap(
                                gpu_mes_registers.?,
                                bootstrap.scheduler,
                                bootstrap.scheduler_doorbell,
                                bootstrap.kiq_doorbell,
                                scheduler_mqd,
                            ) catch panic("AMDGPU MES scheduler map plan invalid");
                            var map_doorbell_transport = gpu.AmdGfx11DoorbellTransport{
                                .aperture = gpu_memory_plan.?.doorbell_bar,
                                .expected_offset = bootstrap.kiq_doorbell.byte_offset,
                                .uncached = true,
                            };
                            map_doorbell_transport.authorize(bootstrap.kiq_doorbell) catch
                                panic("AMDGPU MES scheduler map doorbell authorization rejected");
                            map_doorbell_transport.arm() catch panic("AMDGPU MES scheduler map doorbell arming failed");
                            gpu_mes_scheduler_map_polls = gpu.mapAmdGfx11MesScheduler(
                                map_plan,
                                ring,
                                pointers,
                                100_000,
                                transport.io(),
                                map_doorbell_transport.io(),
                            ) catch {
                                map_doorbell_transport.disarm();
                                gpu.restoreAmdGfx11Kiq(kiq_hqd_plan, &kiq_transaction, transport.io()) catch {
                                    transport.disarm();
                                    panic("AMDGPU MES scheduler map rollback failed");
                                };
                                gpu.haltAmdGfx11Mes(gpu_mes_registers.?, transport.io()) catch {
                                    transport.disarm();
                                    panic("AMDGPU MES scheduler map failure could not halt MES");
                                };
                                gpu_mes_kiq_active = false;
                                gpu_mes_activation = null;
                                transport.disarm();
                                panic("AMDGPU MES scheduler map failed and returned to halt");
                            };
                            map_doorbell_transport.disarm();
                            if (build_options.amd_mes_scheduler_init) {
                                const hw_resources = gpu_mes_hw_resources orelse panic("AMDGPU MES hardware resources unavailable");
                                const control_layout = gpu_mes_control_gpu orelse panic("AMDGPU MES control layout unavailable");
                                const init_plan = gpu.planAmdMesSchedulerInit(
                                    hw_resources,
                                    control_layout,
                                    bootstrap.scheduler_doorbell,
                                ) catch panic("AMDGPU MES scheduler init plan invalid");
                                var scheduler_doorbell_transport = gpu.AmdGfx11DoorbellTransport{
                                    .aperture = gpu_memory_plan.?.doorbell_bar,
                                    .expected_offset = bootstrap.scheduler_doorbell.byte_offset,
                                    .uncached = true,
                                };
                                scheduler_doorbell_transport.authorize(bootstrap.scheduler_doorbell) catch
                                    panic("AMDGPU MES scheduler doorbell authorization rejected");
                                scheduler_doorbell_transport.arm() catch panic("AMDGPU MES scheduler doorbell arming failed");
                                const scheduler_ring: *[1024]u32 = @ptrFromInt(gpu_gfx_ring_resources.scheduler.ring);
                                const scheduler_pointers: *[2]u64 = @ptrFromInt(gpu_gfx_ring_resources.scheduler.pointers);
                                const control_page: *[512]u64 = @ptrFromInt(gpu_mes_control_resources.page);
                                gpu_mes_scheduler_init_polls = gpu.initializeAmdMesScheduler(
                                    init_plan,
                                    scheduler_ring,
                                    scheduler_pointers,
                                    control_page,
                                    2_100_000,
                                    scheduler_doorbell_transport.io(),
                                ) catch {
                                    scheduler_doorbell_transport.disarm();
                                    gpu.restoreAmdGfx11Kiq(kiq_hqd_plan, &kiq_transaction, transport.io()) catch {
                                        transport.disarm();
                                        panic("AMDGPU MES scheduler init rollback failed");
                                    };
                                    gpu.haltAmdGfx11Mes(gpu_mes_registers.?, transport.io()) catch {
                                        transport.disarm();
                                        panic("AMDGPU MES scheduler init failure could not halt MES");
                                    };
                                    gpu_mes_kiq_active = false;
                                    gpu_mes_activation = null;
                                    transport.disarm();
                                    panic("AMDGPU MES scheduler init failed and returned to halt");
                                };
                                scheduler_doorbell_transport.disarm();
                                if (build_options.amd_mes_scheduler_resource1) {
                                    const resource1_plan = gpu.planAmdMesSchedulerResource1(
                                        gpu_mes_activation.?.scheduler_version,
                                        control_layout,
                                        bootstrap.scheduler_doorbell,
                                    ) catch panic("AMDGPU MES scheduler resource1 plan invalid");
                                    if (resource1_plan) |plan| {
                                        var resource1_doorbell_transport = gpu.AmdGfx11DoorbellTransport{
                                            .aperture = gpu_memory_plan.?.doorbell_bar,
                                            .expected_offset = bootstrap.scheduler_doorbell.byte_offset,
                                            .uncached = true,
                                        };
                                        resource1_doorbell_transport.authorize(bootstrap.scheduler_doorbell) catch
                                            panic("AMDGPU MES scheduler resource1 doorbell authorization rejected");
                                        resource1_doorbell_transport.arm() catch panic("AMDGPU MES scheduler resource1 doorbell arming failed");
                                        gpu_mes_scheduler_resource1_polls = gpu.initializeAmdMesSchedulerResource1(
                                            plan,
                                            scheduler_ring,
                                            scheduler_pointers,
                                            control_page,
                                            2_100_000,
                                            resource1_doorbell_transport.io(),
                                        ) catch {
                                            resource1_doorbell_transport.disarm();
                                            gpu.restoreAmdGfx11Kiq(kiq_hqd_plan, &kiq_transaction, transport.io()) catch {
                                                transport.disarm();
                                                panic("AMDGPU MES scheduler resource1 rollback failed");
                                            };
                                            gpu.haltAmdGfx11Mes(gpu_mes_registers.?, transport.io()) catch {
                                                transport.disarm();
                                                panic("AMDGPU MES scheduler resource1 failure could not halt MES");
                                            };
                                            gpu_mes_kiq_active = false;
                                            gpu_mes_activation = null;
                                            transport.disarm();
                                            panic("AMDGPU MES scheduler resource1 failed and returned to halt");
                                        };
                                        resource1_doorbell_transport.disarm();
                                    }
                                    gpu_mes_scheduler_ready = true;
                                }
                            }
                        }
                    }
                    transport.disarm();
                }
            }
        }
        if (build_options.amd_cp_gfx) {
            if (!build_options.amd_gart_mmio or !build_options.amd_psp_ring or !build_options.amd_rlc_resume or
                !build_options.amd_mes_scheduler_resource1 or !gpu_gmc11_activation_workspace.active or !gpu_rlc_resumed or
                !gpu_mes_scheduler_ready or build_options.amd_gart_device == 0 or
                build_options.amd_gart_device != gpu_adapter.device.device)
                panic("AMDGPU CP graphics gate requires matching GART, RLC and MES scheduler");
            const plan = gpu_cp_gfx_plan orelse panic("AMDGPU CP graphics resume plan unavailable");
            var cp_doorbell_transport = gpu.AmdGfx11DoorbellTransport{
                .aperture = gpu_memory_plan.?.doorbell_bar,
                .expected_offset = plan.doorbell.byte_offset,
                .uncached = true,
            };
            cp_doorbell_transport.authorize(plan.doorbell) catch panic("AMDGPU CP graphics doorbell authorization rejected");
            transport.arm() catch panic("AMDGPU CP graphics MMIO arming failed");
            cp_doorbell_transport.arm() catch {
                transport.disarm();
                panic("AMDGPU CP graphics doorbell arming failed");
            };
            const pointers: *[512]u64 = @ptrFromInt(gpu_gfx_command_ring_resources.pointers);
            gpu_cp_gfx_polls = gpu.activateAmdGfx11CpGfx(
                plan,
                pointers,
                2_100_000,
                transport.io(),
                cp_doorbell_transport.io(),
            ) catch {
                cp_doorbell_transport.disarm();
                transport.disarm();
                panic("AMDGPU CP graphics clear-state activation failed and returned to halt");
            };
            const ring_test = gpu.planAmdGfx11CpGfxRingTest(plan) catch {
                cp_doorbell_transport.disarm();
                transport.disarm();
                panic("AMDGPU CP graphics ring test plan invalid");
            };
            const ring: *[1024]u32 = @ptrFromInt(gpu_gfx_command_ring_resources.ring);
            gpu_cp_gfx_test_polls = gpu.testAmdGfx11CpGfxRing(
                plan,
                ring_test,
                ring,
                pointers,
                2_100_000,
                transport.io(),
                cp_doorbell_transport.io(),
            ) catch {
                cp_doorbell_transport.disarm();
                transport.disarm();
                panic("AMDGPU CP graphics PM4 ring test failed and returned to halt");
            };
            cp_doorbell_transport.disarm();
            transport.disarm();
            @atomicStore(u64, &pointers[2], 0, .seq_cst);
            gpu_cs_runtime = .{
                .mmio = transport.*,
                .doorbell = cp_doorbell_transport,
                .plan = plan,
                .ring = ring,
                .pointers = pointers,
                .fence = &pointers[2],
                .fence_gpu = plan.layout.rptr + 16,
                .queue = .{ .committed_wptr = 963 },
                .active = true,
            };
            syscalls.configureAmdGpuCsEndpoint(.{ .context = &gpu_cs_runtime, .submit = &submitDrmAmdGpuCs });
            gpu_cp_gfx_ready = true;
        }
    }
    const gpu_identity = gpu_adapter.identifyChip() catch panic("GPU chipset identification failed");
    const gpu_register_probe = gpu_identity.boot0 orelse gpu_adapter.readRegister(0) catch panic("GPU register MMIO read failed");
    var screen = display.Context.init(info.framebuffer, display_device, &pages) catch panic("display initialization failed");
    screen.drawBaseline(@as(usize, hid.keyboards) + hid.mice, audio_info.playback_endpoints);
    const initial_pixels = screen.present();
    if (initial_pixels == 0) panic("display presentation failed");
    serial.write("GPU PCI vendor: ");
    serial.writeDecimal(screen.adapter.vendor);
    serial.write(" device: ");
    serial.writeDecimal(screen.adapter.device);
    serial.write(" revision: ");
    serial.writeDecimal(display_device.revision);
    serial.write(" bars: ");
    serial.writeDecimal(gpu_adapter.bar_count);
    serial.write(" bytes: ");
    serial.writeDecimal(gpu_adapter.mmio_bytes);
    serial.write(" registers: ");
    serial.writeDecimal(gpu_registers.size);
    serial.write(" rom-bytes: ");
    serial.writeDecimal(if (gpu_adapter.rom_bar) |rom| rom.size else 0);
    serial.write(" rom-enabled: ");
    serial.writeDecimal(if (gpu_adapter.rom_bar) |rom| @intFromBool(rom.enabled) else 0);
    serial.write(" rom-read: ");
    serial.writeDecimal(@intFromBool(gpu_rom_read));
    serial.write(" rom-restored: ");
    serial.writeDecimal(@intFromBool(gpu_rom_restored));
    serial.write(" atom-vram-usage: ");
    serial.writeDecimal(if (gpu_atom_vram_usage) |_| 1 else 0);
    serial.write(" atom-fw-kib: ");
    serial.writeDecimal(if (gpu_atom_vram_usage) |usage| usage.firmware_kib else 0);
    serial.write(" atom-driver-kib: ");
    serial.writeDecimal(if (gpu_atom_vram_usage) |usage| usage.driver_kib else 0);
    serial.write(" atom-firmware-info: ");
    serial.writeDecimal(if (gpu_atom_firmware_info) |_| 1 else 0);
    serial.write(" atom-fw-reserved-kib: ");
    serial.writeDecimal(if (gpu_atom_firmware_info) |atom| atom.reserved_kib else 0);
    serial.write(" atom-vram-type: ");
    serial.writeDecimal(if (gpu_atom_vram_info) |atom| atom.uapi_vram_type else 0);
    serial.write(" atom-vram-width: ");
    serial.writeDecimal(if (gpu_atom_vram_info) |atom| atom.width_bits else 0);
    serial.write(" firmware-tail-bytes: ");
    serial.writeDecimal(if (gpu_gmc11_memory != null) gpu_firmware_tail_bytes else 0);
    serial.write(" memory-training-reserved: ");
    serial.writeDecimal(@intFromBool(gpu_memory_training_reserved));
    serial.write(" probe: ");
    serial.writeDecimal(gpu_register_probe);
    serial.write(" chipset: ");
    serial.writeDecimal(gpu_identity.chipset orelse 0);
    serial.write(" chiprev: ");
    serial.writeDecimal(gpu_identity.chip_revision orelse 0);
    serial.write(" firmware: ");
    serial.writeDecimal(if (gpu_firmware) |firmware| firmware.size else 0);
    serial.write(" entries: ");
    serial.writeDecimal(gpu_firmware_entries);
    serial.write(" catalog: ");
    serial.writeDecimal(gpu_catalog_entries);
    serial.write(" mappings: ");
    serial.writeDecimal(gpu_firmware_mappings);
    serial.write(" selected: ");
    serial.writeDecimal(gpu_backend_entries);
    serial.write(" required-mask: ");
    serial.writeDecimal(gpu_required_blocks);
    serial.write(" validated: ");
    serial.writeDecimal(gpu_validated_entries);
    serial.write(" payloads: ");
    serial.writeDecimal(gpu_inventory.entries);
    serial.write(" payload-bytes: ");
    serial.writeDecimal(gpu_inventory.payload_bytes);
    serial.write(" security: ");
    serial.writeDecimal(gpu_inventory.block(.security).entries);
    serial.write(" graphics: ");
    serial.writeDecimal(gpu_inventory.block(.graphics).entries);
    serial.write(" dma: ");
    serial.writeDecimal(gpu_inventory.block(.dma).entries);
    serial.write(" ip-dies: ");
    serial.writeDecimal(if (gpu_ip_discovery) |discovery| discovery.dies else 0);
    serial.write(" ips: ");
    serial.writeDecimal(if (gpu_ip_discovery) |discovery| discovery.ips else 0);
    serial.write(" psp: ");
    serial.writeDecimal(gpu_psp_major);
    serial.write(" gfx: ");
    serial.writeDecimal(gpu_gfx_major);
    serial.write(" mmhub: ");
    serial.writeDecimal(gpu_mmhub_major);
    serial.write(" sdma: ");
    serial.writeDecimal(gpu_sdma_major);
    serial.write(" plan: ");
    serial.writeDecimal(if (gpu_backend_plan) |_| 1 else 0);
    serial.write(" gmc-plan: ");
    serial.writeDecimal(if (gpu_memory_plan) |_| 1 else 0);
    serial.write(" gmc-snapshot: ");
    serial.writeDecimal(if (gpu_gmc11_memory) |_| 1 else 0);
    serial.write(" vram-mc-base: ");
    serial.writeDecimal(if (gpu_gmc11_memory) |snapshot| snapshot.vram_mc_base else 0);
    serial.write(" vram-mc-offset: ");
    serial.writeDecimal(if (gpu_gmc11_memory) |snapshot| snapshot.vram_mc_offset else 0);
    serial.write(" vram-bytes: ");
    serial.writeDecimal(if (gpu_gmc11_memory) |snapshot| snapshot.vram_bytes else 0);
    serial.write(" vram-visible: ");
    serial.writeDecimal(if (gpu_gmc11_visible_vram) |visible| visible.bytes else 0);
    serial.write(" framebuffer-mc: ");
    serial.writeDecimal(if (gpu_gmc11_visible_vram) |visible| visible.framebuffer_mc_start else 0);
    serial.write(" vram-reservations: ");
    serial.writeDecimal(if (gpu_vram_allocator) |allocator| allocator.reservation_count else 0);
    serial.write(" vram-map-sealed: ");
    serial.writeDecimal(if (gpu_vram_allocator) |allocator| @intFromBool(allocator.firmware_map_sealed) else 0);
    serial.write(" vram-aperture: ");
    serial.writeDecimal(if (gpu_memory_plan) |plan| if (plan.vram_bar) |bar| bar.size else 0 else 0);
    serial.write(" doorbell-aperture: ");
    serial.writeDecimal(if (gpu_memory_plan) |plan| plan.doorbell_bar.size else 0);
    serial.write(" gtt-table: ");
    serial.writeDecimal(gpu_psp_gtt.page_table_address);
    serial.write(" gtt-pages: ");
    serial.writeDecimal(gpu_psp_gtt.buffer_pages);
    serial.write(" gtt-ready: ");
    serial.writeDecimal(@intFromBool(gpu_psp_gtt.active));
    serial.write(" gart-plan: ");
    serial.writeDecimal(if (gpu_gart_plan) |_| 1 else 0);
    serial.write(" gart-bound: ");
    serial.writeDecimal(if (gpu_gart_plan) |plan| @intFromBool(plan.table_mc_address != null) else 0);
    serial.write(" gart-table-mc: ");
    serial.writeDecimal(if (gpu_gart_plan) |plan| plan.table_mc_address orelse 0 else 0);
    serial.write(" gart-table-vram-cpu: ");
    serial.writeDecimal(if (gpu_gart_table_vram) |allocation| allocation.cpu_address else 0);
    serial.write(" gart-aperture-ready: ");
    serial.writeDecimal(if (gpu_gart_aperture) |_| 1 else 0);
    serial.write(" gart-rollback-registers: ");
    serial.writeDecimal(gpu_gart_rollback_registers);
    serial.write(" gart-scratch-mc: ");
    serial.writeDecimal(if (gpu_gmc11_system_pages) |system| system.scratch.mc_address else 0);
    serial.write(" gart-scratch-pa: ");
    serial.writeDecimal(if (gpu_gmc11_system_pages) |system| system.scratch_physical else 0);
    serial.write(" gart-dummy-pa: ");
    serial.writeDecimal(if (gpu_gmc11_system_pages) |system| system.dummy_physical else 0);
    serial.write(" gart-system-aperture-ready: ");
    serial.writeDecimal(if (gpu_gmc11_system_aperture) |_| 1 else 0);
    serial.write(" gart-window: ");
    serial.writeDecimal(if (gpu_gart_plan) |plan| plan.window_bytes else 0);
    serial.write(" gart-window-start: ");
    serial.writeDecimal(if (gpu_gmc11_gart_window) |window| window.start else 0);
    serial.write(" gart-window-end: ");
    serial.writeDecimal(if (gpu_gmc11_gart_window) |window| window.end else 0);
    serial.write(" gart-gfxhub: ");
    serial.writeDecimal(if (gpu_gart_plan) |plan| @intFromBool(plan.gfxhub_base != null) else 0);
    serial.write(" gart-registers: ");
    serial.writeDecimal(if (gpu_gart_registers) |_| 1 else 0);
    serial.write(" gart-context-reg: ");
    serial.writeDecimal(if (gpu_gart_registers) |registers| registers.context_control else 0);
    serial.write(" gart-invalidate-reg: ");
    serial.writeDecimal(if (gpu_gart_registers) |registers| registers.invalidate_request else 0);
    serial.write(" gart-active: ");
    serial.writeDecimal(if (gpu_gart_plan) |plan| @intFromBool(plan.active) else 0);
    serial.write(" gart-mmio-transport: ");
    serial.writeDecimal(if (gpu_gart_mmio_transport) |_| 1 else 0);
    serial.write(" gart-write-authorized: ");
    serial.writeDecimal(if (gpu_gart_mmio_transport) |transport| @intFromBool(transport.authorized) else 0);
    serial.write(" gart-write-armed: ");
    serial.writeDecimal(if (gpu_gart_mmio_transport) |transport| @intFromBool(transport.armed) else 0);
    serial.write(" gart-activation-prepared: ");
    serial.writeDecimal(@intFromBool(gpu_gmc11_activation_workspace.prepared));
    serial.write(" gart-activation-committed: ");
    serial.writeDecimal(@intFromBool(gpu_gmc11_activation_workspace.active));
    serial.write(" gart-snapshot-digest: ");
    serial.writeDecimal(gpu_gmc11_activation_workspace.snapshot_digest);
    serial.write(" gart-write-digest: ");
    serial.writeDecimal(gpu_gmc11_activation_workspace.write_digest);
    serial.write(" gart-invalidate-polls: ");
    serial.writeDecimal(gpu_gmc11_activation_workspace.invalidate_polls);
    serial.write(" psp-version: ");
    serial.writeDecimal(if (gpu_backend_plan) |plan| plan.psp.ip_version else 0);
    serial.write(" psp-autoload: ");
    serial.writeDecimal(if (gpu_backend_plan) |plan| @intFromBool(plan.psp.autoload_supported) else 0);
    serial.write(" psp-boot-tmr: ");
    serial.writeDecimal(if (gpu_backend_plan) |plan| @intFromBool(plan.psp.boot_time_tmr) else 0);
    serial.write(" psp-host-boot: ");
    serial.writeDecimal(if (gpu_backend_plan) |plan| @intFromBool(plan.psp.host_boot_components) else 0);
    serial.write(" psp-mailbox: ");
    serial.writeDecimal(if (gpu_psp_mailbox_registers) |_| 1 else 0);
    serial.write(" psp-command-reg: ");
    serial.writeDecimal(if (gpu_psp_mailbox_registers) |registers| registers.command_offset else 0);
    serial.write(" psp-observed: ");
    serial.writeDecimal(if (gpu_psp_mailbox_snapshot) |_| 1 else 0);
    serial.write(" psp-mailbox-state: ");
    serial.writeDecimal(if (gpu_psp_mailbox_snapshot) |snapshot| @intFromEnum(snapshot.state) else 0);
    serial.write(" psp-mailbox-waited: ");
    serial.writeDecimal(@intFromBool(gpu_psp_mailbox_waited));
    serial.write(" psp-mmio-transport: ");
    serial.writeDecimal(if (gpu_psp_mmio_transport) |_| 1 else 0);
    serial.write(" psp-write-armed: ");
    serial.writeDecimal(if (gpu_psp_mmio_transport) |transport| @intFromBool(transport.armed) else 0);
    serial.write(" psp-write-authorized: ");
    serial.writeDecimal(if (gpu_psp_mmio_transport) |transport| @intFromBool(transport.authorized) else 0);
    serial.write(" psp-preflight: ");
    serial.writeDecimal(if (gpu_psp_preflight) |preflight| @intFromEnum(preflight) + 1 else 0);
    serial.write(" staged: ");
    serial.writeDecimal(gpu_firmware_staging.count);
    serial.write(" staged-bytes: ");
    serial.writeDecimal(gpu_firmware_staging.image_bytes);
    serial.write(" staged-payload: ");
    serial.writeDecimal(gpu_firmware_staging.payload_bytes);
    serial.write(" psp-components: ");
    serial.writeDecimal(gpu_firmware_staging.psp_component_count);
    serial.write(" psp-boot: ");
    serial.writeDecimal(if (gpu_psp_boot_images) |_| 1 else 0);
    serial.write(" psp-aux: ");
    serial.writeDecimal(if (gpu_psp_boot_images) |images| @intFromBool(images.auxiliary) else 0);
    serial.write(" psp-steps: ");
    serial.writeDecimal(gpu_psp_handoff.count);
    serial.write(" psp-transfer: ");
    serial.writeDecimal(gpu_psp_handoff.transfer_address);
    serial.write(" psp-state: ");
    serial.writeDecimal(@intFromEnum(gpu_psp_handoff.state));
    serial.write(" gfx-fw-typed: ");
    serial.writeDecimal(if (gpu_gfx_firmware) |manifest| manifest.entries else 0);
    serial.write(" cp-fw-format: ");
    serial.writeDecimal(if (gpu_cp_firmware) |firmware| @intFromEnum(firmware.pfp.?.format) + 1 else 0);
    serial.write(" cp-fw-psp-payloads: ");
    serial.writeDecimal(gpu_cp_firmware_staging.count);
    serial.write(" cp-fw-gart-pages: ");
    serial.writeDecimal(if (gpu_cp_firmware_gpu) |layout| layout.gart_pages else 0);
    serial.write(" psp-ring-bootstrap: ");
    serial.writeDecimal(@intFromBool(gpu_psp_ring_bootstrap != null));
    serial.write(" psp-ring-active: ");
    serial.writeDecimal(@intFromBool(gpu_psp_ring_activation != null));
    serial.write(" psp-ip-fw-loaded: ");
    serial.writeDecimal(if (gpu_psp_firmware_load) |loaded| loaded.loaded else 0);
    serial.write(" psp-ip-fw-warnings: ");
    serial.writeDecimal(if (gpu_psp_firmware_load) |loaded| loaded.response_warnings else 0);
    serial.write(" gfx-ring-preflight: ");
    serial.writeDecimal(@intFromEnum(gpu.preflightAmdGfx11Ring(.{
        .firmware = gpu_gfx_firmware != null,
        .psp = gpu_psp_handoff.state == .finished,
        .gart = gpu_gmc11_activation_workspace.active,
        .gpuvm = gpu_vm_runtime.active,
        .ring = gpu_gfx_ring_resources.scheduler.ring != 0 and gpu_gfx_ring_resources.kiq.ring != 0,
        .mqd = gpu_gfx_ring_resources.scheduler.mqd != 0 and gpu_gfx_ring_resources.kiq.mqd != 0,
        .eop = gpu_gfx_ring_resources.scheduler.eop != 0 and gpu_gfx_ring_resources.kiq.eop != 0,
        .pointers = gpu_gfx_ring_resources.scheduler.pointers != 0 and gpu_gfx_ring_resources.kiq.pointers != 0,
        .doorbell = gpu_gfx_mes_bootstrap != null,
    })));
    serial.write(" mes-ring0-db: ");
    serial.writeDecimal(if (gpu_gfx_mes_bootstrap) |bootstrap| bootstrap.scheduler_doorbell.register_index else 0);
    serial.write(" mes-ring1-db: ");
    serial.writeDecimal(if (gpu_gfx_mes_bootstrap) |bootstrap| bootstrap.kiq_doorbell.register_index else 0);
    serial.write(" mes-fw-gart-pages: ");
    serial.writeDecimal(if (gpu_mes_firmware_gpu) |layout| layout.gart_pages else 0);
    serial.write(" mes-control-gart-page: ");
    serial.writeDecimal(if (gpu_mes_control_gpu) |layout| layout.first_gart_page else 0);
    serial.write(" mes-hw-resource-plan: ");
    serial.writeDecimal(if (gpu_mes_hw_resources) |_| 1 else 0);
    serial.write(" mes-halted: ");
    serial.writeDecimal(@intFromBool(gpu_mes_halted));
    serial.write(" mes-load-plans: ");
    serial.writeDecimal(@intFromBool(gpu_mes_scheduler_load != null) + @intFromBool(gpu_mes_kiq_load != null));
    serial.write(" mes-loads: ");
    serial.writeDecimal(gpu_mes_loads);
    serial.write(" mes-active: ");
    serial.writeDecimal(if (gpu_mes_activation) |_| 1 else 0);
    serial.write(" mes-sched-version: ");
    serial.writeDecimal(if (gpu_mes_activation) |activation| activation.scheduler_version else 0);
    serial.write(" mes-kiq-version: ");
    serial.writeDecimal(if (gpu_mes_activation) |activation| activation.kiq_version else 0);
    serial.write(" mes-handshake-polls: ");
    serial.writeDecimal(if (gpu_mes_activation) |activation| activation.polls else 0);
    serial.write(" mes-kiq-active: ");
    serial.writeDecimal(@intFromBool(gpu_mes_kiq_active));
    serial.write(" mes-kiq-test-polls: ");
    serial.writeDecimal(gpu_mes_kiq_test_polls);
    serial.write(" mes-scheduler-map-polls: ");
    serial.writeDecimal(gpu_mes_scheduler_map_polls);
    serial.write(" mes-scheduler-init-polls: ");
    serial.writeDecimal(gpu_mes_scheduler_init_polls);
    serial.write(" mes-scheduler-resource1-polls: ");
    serial.writeDecimal(gpu_mes_scheduler_resource1_polls);
    serial.write(" mes-scheduler-ready: ");
    serial.writeDecimal(@intFromBool(gpu_mes_scheduler_ready));
    serial.write(" cp-gfx-ready: ");
    serial.writeDecimal(@intFromBool(gpu_cp_gfx_ready));
    serial.write(" cp-gfx-polls: ");
    serial.writeDecimal(gpu_cp_gfx_polls);
    serial.write(" cp-gfx-test-polls: ");
    serial.writeDecimal(gpu_cp_gfx_test_polls);
    serial.write(" driver: ");
    serial.write(switch (gpu_adapter.driver) {
        .amdgpu => "amdgpu",
        .nouveau => "nouveau",
        .qemu_vga => "qemu-vga",
        .unsupported => "unsupported",
    });
    serial.write("\ndisplay resolution: ");
    serial.writeDecimal(screen.framebuffer.width);
    serial.write("x");
    serial.writeDecimal(screen.framebuffer.height);
    serial.write(" stride: ");
    serial.writeDecimal(screen.framebuffer.stride);
    serial.write("\ndisplay backbuffer bytes: ");
    serial.writeDecimal(screen.buffer_bytes);
    serial.write("\ndisplay initial pixels: ");
    serial.writeDecimal(initial_pixels);
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
        freeze_latency.p50,
        freeze_latency.p95,
        freeze_latency.p99,
        resume_latency.p50,
        resume_latency.p95,
        resume_latency.p99,
        nvme_latency.p50,
        nvme_latency.p95,
        nvme_latency.p99,
        tcp_latency.p50,
        tcp_latency.p95,
        tcp_latency.p99,
    ) catch panic("hardware baseline append failed");
    serial.write("profile scheduler freeze cycles p50: ");
    serial.writeDecimal(freeze_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(freeze_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(freeze_latency.p99);
    serial.write(" resume p50: ");
    serial.writeDecimal(resume_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(resume_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(resume_latency.p99);
    serial.write("\nprofile NVMe read cycles p50: ");
    serial.writeDecimal(nvme_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(nvme_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(nvme_latency.p99);
    serial.write("\nprofile TCP transaction cycles p50: ");
    serial.writeDecimal(tcp_latency.p50);
    serial.write(" p95: ");
    serial.writeDecimal(tcp_latency.p95);
    serial.write(" p99: ");
    serial.writeDecimal(tcp_latency.p99);
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
    serial.write("hardware signature: ");
    serial.writeDecimal(current_profile.signature);
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
        serial.write("profile USB input queue cycles p50: ");
        serial.writeDecimal(input_latency.p50);
        serial.write(" p95: ");
        serial.writeDecimal(input_latency.p95);
        serial.write(" p99: ");
        serial.writeDecimal(input_latency.p99);
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
    serial.write("profile USB audio period cycles p50: ");
    serial.writeDecimal(audio_jitter.p50);
    serial.write(" p95: ");
    serial.writeDecimal(audio_jitter.p95);
    serial.write(" p99: ");
    serial.writeDecimal(audio_jitter.p99);
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

fn pspTimerTicks(_: *anyopaque) u64 {
    return idt.timerTicks();
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
