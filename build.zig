const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .none,
    });
    const dynamic_user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .none,
        .dynamic_linker = std.Target.DynamicLinker.init("/lib/ld-csos.so"),
    });

    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/hello.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    hello.entry = .{ .symbol_name = "_start" };
    hello.pie = true;

    const interpreter = b.addExecutable(.{
        .name = "ld-csos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/interpreter.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    interpreter.entry = .{ .symbol_name = "_start" };
    interpreter.pie = true;

    const shared = b.addLibrary(.{
        .name = "csos",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/shared.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    shared.bundle_compiler_rt = false;

    const dynamic_hello = b.addExecutable(.{
        .name = "dynamic-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/dynamic_hello.zig"),
            .target = dynamic_user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    dynamic_hello.entry = .{ .symbol_name = "_start" };
    dynamic_hello.pie = true;
    dynamic_hello.bundle_compiler_rt = false;
    dynamic_hello.root_module.linkLibrary(shared);

    const nettest = b.addExecutable(.{
        .name = "nettest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/nettest.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    nettest.entry = .{ .symbol_name = "_start" };
    nettest.image_base = 0x0000008000000000;

    const serial_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/serial.zig") });
    const gdt_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/gdt.zig") });
    const idt_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/idt.zig") });
    idt_module.addImport("serial", serial_module);
    const apic_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/apic.zig") });
    const ioapic_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/ioapic.zig") });
    const acpi_module = b.createModule(.{ .root_source_file = b.path("firmware/acpi.zig") });
    const pci_module = b.createModule(.{ .root_source_file = b.path("drivers/pci.zig") });
    const physical_module = b.createModule(.{ .root_source_file = b.path("memory/physical.zig") });
    const nvme_module = b.createModule(.{ .root_source_file = b.path("drivers/nvme.zig") });
    nvme_module.addImport("pci", pci_module);
    nvme_module.addImport("physical", physical_module);
    const fat16_module = b.createModule(.{ .root_source_file = b.path("drivers/fat16.zig") });
    fat16_module.addImport("nvme", nvme_module);
    fat16_module.addImport("physical", physical_module);
    const xhci_module = b.createModule(.{ .root_source_file = b.path("drivers/xhci.zig") });
    xhci_module.addImport("pci", pci_module);
    xhci_module.addImport("physical", physical_module);
    const gpu_module = b.createModule(.{ .root_source_file = b.path("drivers/gpu.zig") });
    gpu_module.addImport("pci", pci_module);
    const display_module = b.createModule(.{ .root_source_file = b.path("drivers/display.zig") });
    display_module.addImport("pci", pci_module);
    display_module.addImport("physical", physical_module);
    const hardware_profile_module = b.createModule(.{ .root_source_file = b.path("hardware/profile.zig") });
    const installer_state_module = b.createModule(.{ .root_source_file = b.path("installer/state.zig") });
    const e1000_module = b.createModule(.{ .root_source_file = b.path("drivers/e1000.zig") });
    e1000_module.addImport("pci", pci_module);
    e1000_module.addImport("physical", physical_module);
    const net_module = b.createModule(.{ .root_source_file = b.path("net/stack.zig") });
    net_module.addImport("e1000", e1000_module);
    const smp_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/smp.zig") });
    smp_module.addImport("apic", apic_module);
    smp_module.addImport("physical", physical_module);
    const paging_module = b.createModule(.{ .root_source_file = b.path("memory/paging.zig") });
    paging_module.addImport("physical", physical_module);
    const heap_module = b.createModule(.{ .root_source_file = b.path("memory/heap.zig") });
    heap_module.addImport("physical", physical_module);
    const scheduler_module = b.createModule(.{ .root_source_file = b.path("kernel/scheduler.zig") });
    scheduler_module.addImport("physical", physical_module);
    scheduler_module.addImport("idt", idt_module);
    const syscalls_module = b.createModule(.{ .root_source_file = b.path("kernel/syscalls.zig") });
    syscalls_module.addImport("serial", serial_module);
    const vfs_module = b.createModule(.{ .root_source_file = b.path("kernel/vfs.zig") });
    vfs_module.addAnonymousImport("busybox_elf", .{ .root_source_file = b.path("userspace/initramfs/bin/busybox") });
    vfs_module.addImport("fat16", fat16_module);
    syscalls_module.addImport("vfs", vfs_module);
    syscalls_module.addImport("net", net_module);
    const process_module = b.createModule(.{ .root_source_file = b.path("kernel/process.zig") });
    process_module.addImport("paging", paging_module);
    process_module.addImport("physical", physical_module);
    process_module.addImport("syscalls", syscalls_module);
    process_module.addImport("vfs", vfs_module);
    process_module.addAnonymousImport("hello_elf", .{ .root_source_file = hello.getEmittedBin() });
    process_module.addAnonymousImport("interpreter_elf", .{ .root_source_file = interpreter.getEmittedBin() });
    process_module.addAnonymousImport("dynamic_elf", .{ .root_source_file = dynamic_hello.getEmittedBin() });
    process_module.addAnonymousImport("nettest_elf", .{ .root_source_file = nettest.getEmittedBin() });
    process_module.addAnonymousImport("busybox_elf", .{ .root_source_file = b.path("userspace/initramfs/bin/busybox") });
    const kernel_module = b.createModule(.{ .root_source_file = b.path("kernel/main.zig") });
    kernel_module.addImport("serial", serial_module);
    kernel_module.addImport("gdt", gdt_module);
    kernel_module.addImport("idt", idt_module);
    kernel_module.addImport("apic", apic_module);
    kernel_module.addImport("ioapic", ioapic_module);
    kernel_module.addImport("acpi", acpi_module);
    kernel_module.addImport("pci", pci_module);
    kernel_module.addImport("nvme", nvme_module);
    kernel_module.addImport("fat16", fat16_module);
    kernel_module.addImport("xhci", xhci_module);
    kernel_module.addImport("gpu", gpu_module);
    kernel_module.addImport("display", display_module);
    kernel_module.addImport("hardware_profile", hardware_profile_module);
    kernel_module.addImport("installer_state", installer_state_module);
    kernel_module.addImport("e1000", e1000_module);
    kernel_module.addImport("net", net_module);
    kernel_module.addImport("smp", smp_module);
    kernel_module.addImport("physical", physical_module);
    kernel_module.addImport("paging", paging_module);
    kernel_module.addImport("heap", heap_module);
    kernel_module.addImport("scheduler", scheduler_module);
    kernel_module.addImport("process", process_module);
    kernel_module.addImport("syscalls", syscalls_module);
    kernel_module.addImport("vfs", vfs_module);
    const boot_module = b.createModule(.{
        .root_source_file = b.path("boot/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    boot_module.addImport("serial", serial_module);
    boot_module.addImport("kernel", kernel_module);
    boot_module.addAssemblyFile(b.path("arch/x86_64/ap_trampoline.S"));
    boot_module.addAssemblyFile(b.path("arch/x86_64/context_switch.S"));
    boot_module.addAssemblyFile(b.path("arch/x86_64/user_enter.S"));
    boot_module.addAssemblyFile(b.path("arch/x86_64/syscall_entry.S"));
    const boot = b.addExecutable(.{ .name = "BOOTX64", .root_module = boot_module });
    b.installArtifact(boot);

    const run = b.step("run", "Build and boot CSOS in QEMU");
    const qemu = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    qemu.addFileArg(b.path("tools/run.ps1"));
    qemu.addFileArg(boot.getEmittedBin());
    qemu.addFileArg(shared.getEmittedBin());
    run.dependOn(&qemu.step);
}
