const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const libdrm_probe = b.option([]const u8, "libdrm-probe", "Path to the static upstream libdrm probe ELF (opt-in Ring 3 validation)");
    const libdrm_probe_after_gpu = b.option(bool, "libdrm-probe-after-gpu", "Run the supplied probe after GPU initialization; does not enable hardware gates") orelse false;
    if (libdrm_probe_after_gpu and libdrm_probe == null) @panic("-Dlibdrm-probe-after-gpu requires -Dlibdrm-probe");
    const gpu_firmware = b.option([]const u8, "gpu-firmware", "Firmware archive copied to GPUFW.BIN on the CSOS disk");
    const radv_runtime = b.option([]const u8, "radv-runtime", "Stripped RADV ELF copied to the CSOS disk");
    const libdrm_amdgpu_runtime = b.option([]const u8, "libdrm-amdgpu-runtime", "libdrm_amdgpu ELF copied to the CSOS disk");
    const libdrm_runtime = b.option([]const u8, "libdrm-runtime", "libdrm ELF copied to the CSOS disk");
    const zlib_runtime = b.option([]const u8, "zlib-runtime", "zlib ELF copied to the CSOS disk");
    const libc_runtime = b.option([]const u8, "libc-runtime", "musl libc ELF copied to the CSOS disk");
    const radv_loader_probe = b.option([]const u8, "radv-loader-probe", "Dynamic RADV loader probe ELF (requires -Dradv-runtime)");
    const radv_probe_after_gpu = b.option(bool, "radv-probe-after-gpu", "Run RADV probe after GPU preparation; does not enable hardware activation") orelse false;
    if (radv_probe_after_gpu and radv_loader_probe == null) @panic("-Dradv-probe-after-gpu requires -Dradv-loader-probe");
    if (radv_loader_probe != null and radv_runtime == null) @panic("-Dradv-loader-probe requires -Dradv-runtime");
    const amd_gart_mmio = b.option(bool, "amd-gart-mmio", "Explicitly arm and commit the validated GMC 11 GART transaction") orelse false;
    const amd_psp_ring = b.option(bool, "amd-psp-ring", "Explicitly create the PSP KM ring and load validated GFX11 CP/RLC firmware") orelse false;
    const amd_rlc_resume = b.option(bool, "amd-rlc-resume", "Explicitly install the GFX11 clear-state block and enable RLC save/restore") orelse false;
    const amd_mes_mmio = b.option(bool, "amd-mes-mmio", "Explicitly load validated GFX11 MES firmware while MES remains halted") orelse false;
    const amd_mes_activate = b.option(bool, "amd-mes-activate", "Explicitly unhalt validated GFX11 MES and require both firmware handshakes") orelse false;
    const amd_mes_kiq = b.option(bool, "amd-mes-kiq", "Explicitly activate the validated GFX11 MES KIQ HQD") orelse false;
    const amd_mes_kiq_test = b.option(bool, "amd-mes-kiq-test", "Explicitly submit and verify the private GFX11 KIQ ring test") orelse false;
    const amd_mes_scheduler_map = b.option(bool, "amd-mes-scheduler-map", "Explicitly map and verify the GFX11 MES scheduler queue through KIQ") orelse false;
    const amd_mes_scheduler_init = b.option(bool, "amd-mes-scheduler-init", "Explicitly submit and verify GFX11 MES SET_HW_RSRC") orelse false;
    const amd_mes_scheduler_resource1 = b.option(bool, "amd-mes-scheduler-resource1", "Explicitly submit revision-required GFX11 MES SET_HW_RSRC_1") orelse false;
    const amd_cp_gfx = b.option(bool, "amd-cp-gfx", "Explicitly activate GFX11 CP graphics ring0 and verify the clear-state preamble") orelse false;
    const drm_amdgpu_abi_test = b.option(bool, "drm-amdgpu-abi-test", "Exercise AMDGPU memory ioctls in Ring 3 without GPU hardware activation") orelse false;
    const amd_gart_device_text = b.option([]const u8, "amd-gart-device", "Required AMD PCI device ID for real GART MMIO activation (for example 0x744c)") orelse "0";
    const amd_gart_device = std.fmt.parseInt(u16, amd_gart_device_text, 0) catch @panic("invalid -Damd-gart-device PCI ID");
    const build_options = b.addOptions();
    build_options.addOption(bool, "libdrm_probe", libdrm_probe != null);
    build_options.addOption(bool, "radv_runtime", radv_runtime != null);
    build_options.addOption(bool, "radv_loader_probe", radv_loader_probe != null);
    build_options.addOption(bool, "radv_probe_after_gpu", radv_probe_after_gpu);
    build_options.addOption(bool, "libdrm_probe_after_gpu", libdrm_probe_after_gpu);
    build_options.addOption(bool, "amd_gart_mmio", amd_gart_mmio);
    build_options.addOption(bool, "amd_psp_ring", amd_psp_ring);
    build_options.addOption(bool, "amd_rlc_resume", amd_rlc_resume);
    build_options.addOption(bool, "amd_mes_mmio", amd_mes_mmio);
    build_options.addOption(bool, "amd_mes_activate", amd_mes_activate);
    build_options.addOption(bool, "amd_mes_kiq", amd_mes_kiq);
    build_options.addOption(bool, "amd_mes_kiq_test", amd_mes_kiq_test);
    build_options.addOption(bool, "amd_mes_scheduler_map", amd_mes_scheduler_map);
    build_options.addOption(bool, "amd_mes_scheduler_init", amd_mes_scheduler_init);
    build_options.addOption(bool, "amd_mes_scheduler_resource1", amd_mes_scheduler_resource1);
    build_options.addOption(bool, "amd_cp_gfx", amd_cp_gfx);
    build_options.addOption(bool, "drm_amdgpu_abi_test", drm_amdgpu_abi_test);
    build_options.addOption(u16, "amd_gart_device", amd_gart_device);
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
    shared.setVersionScript(b.path("userspace/csos.map"));

    const extra = b.addLibrary(.{
        .name = "extra",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/extra.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    extra.bundle_compiler_rt = false;
    extra.root_module.linkLibrary(shared);

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
    dynamic_hello.root_module.linkLibrary(extra);

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

    const fbtest = b.addExecutable(.{
        .name = "fbtest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/fbtest.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    fbtest.entry = .{ .symbol_name = "_start" };
    fbtest.image_base = 0x0000008100000000;

    const drmtest = b.addExecutable(.{
        .name = "drmtest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("userspace/drmtest.zig"),
            .target = user_target,
            .optimize = .ReleaseSmall,
        }),
    });
    drmtest.entry = .{ .symbol_name = "_start" };
    drmtest.image_base = 0x0000008200000000;

    const serial_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/serial.zig") });
    const gdt_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/gdt.zig") });
    const idt_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/idt.zig") });
    idt_module.addImport("serial", serial_module);
    const apic_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/apic.zig") });
    const ioapic_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/ioapic.zig") });
    const acpi_module = b.createModule(.{ .root_source_file = b.path("firmware/acpi.zig") });
    const pci_module = b.createModule(.{ .root_source_file = b.path("drivers/pci.zig") });
    const physical_module = b.createModule(.{ .root_source_file = b.path("memory/physical.zig") });
    const metrics_module = b.createModule(.{ .root_source_file = b.path("gaming/metrics.zig") });
    const nvme_module = b.createModule(.{ .root_source_file = b.path("drivers/nvme.zig") });
    nvme_module.addImport("pci", pci_module);
    nvme_module.addImport("physical", physical_module);
    const fat16_module = b.createModule(.{ .root_source_file = b.path("drivers/fat16.zig") });
    fat16_module.addImport("nvme", nvme_module);
    fat16_module.addImport("physical", physical_module);
    const xhci_module = b.createModule(.{ .root_source_file = b.path("drivers/xhci.zig") });
    xhci_module.addImport("pci", pci_module);
    xhci_module.addImport("physical", physical_module);
    xhci_module.addImport("apic", apic_module);
    xhci_module.addImport("metrics", metrics_module);
    const audio_module = b.createModule(.{ .root_source_file = b.path("drivers/audio.zig") });
    const gpu_module = b.createModule(.{ .root_source_file = b.path("drivers/gpu.zig") });
    gpu_module.addImport("pci", pci_module);
    gpu_module.addImport("fat16", fat16_module);
    gpu_module.addImport("physical", physical_module);
    const gpu_test_module = b.createModule(.{
        .root_source_file = b.path("tests/gpu_gart.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    gpu_test_module.addImport("gpu", gpu_module);
    const gpu_tests = b.addTest(.{ .root_module = gpu_test_module });
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    const test_step = b.step("test", "Run CSOS host-side tests");
    test_step.dependOn(&run_gpu_tests.step);
    const display_module = b.createModule(.{ .root_source_file = b.path("drivers/display.zig") });
    display_module.addImport("pci", pci_module);
    display_module.addImport("physical", physical_module);
    const hardware_profile_module = b.createModule(.{ .root_source_file = b.path("hardware/profile.zig") });
    const installer_state_module = b.createModule(.{ .root_source_file = b.path("installer/state.zig") });
    const e1000_module = b.createModule(.{ .root_source_file = b.path("drivers/e1000.zig") });
    e1000_module.addImport("pci", pci_module);
    e1000_module.addImport("physical", physical_module);
    e1000_module.addImport("apic", apic_module);
    e1000_module.addImport("metrics", metrics_module);
    const net_module = b.createModule(.{ .root_source_file = b.path("net/stack.zig") });
    net_module.addImport("e1000", e1000_module);
    const smp_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/smp.zig") });
    smp_module.addImport("apic", apic_module);
    smp_module.addImport("idt", idt_module);
    smp_module.addImport("physical", physical_module);
    const paging_module = b.createModule(.{ .root_source_file = b.path("memory/paging.zig") });
    paging_module.addImport("physical", physical_module);
    const heap_module = b.createModule(.{ .root_source_file = b.path("memory/heap.zig") });
    heap_module.addImport("physical", physical_module);
    const scheduler_module = b.createModule(.{ .root_source_file = b.path("kernel/scheduler.zig") });
    scheduler_module.addImport("physical", physical_module);
    scheduler_module.addImport("idt", idt_module);
    scheduler_module.addImport("apic", apic_module);
    scheduler_module.addImport("metrics", metrics_module);
    const syscalls_module = b.createModule(.{ .root_source_file = b.path("kernel/syscalls.zig") });
    syscalls_module.addImport("serial", serial_module);
    const vfs_module = b.createModule(.{ .root_source_file = b.path("kernel/vfs.zig") });
    vfs_module.addAnonymousImport("busybox_elf", .{ .root_source_file = b.path("userspace/initramfs/bin/busybox") });
    vfs_module.addImport("fat16", fat16_module);
    syscalls_module.addImport("vfs", vfs_module);
    syscalls_module.addImport("net", net_module);
    syscalls_module.addImport("physical", physical_module);
    syscalls_module.addImport("gpu", gpu_module);
    const drm_abi_test_module = b.createModule(.{
        .root_source_file = b.path("tests/drm_abi.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    drm_abi_test_module.addImport("syscalls", syscalls_module);
    const drm_abi_tests = b.addTest(.{ .root_module = drm_abi_test_module });
    const run_drm_abi_tests = b.addRunArtifact(drm_abi_tests);
    test_step.dependOn(&run_drm_abi_tests.step);
    const process_module = b.createModule(.{ .root_source_file = b.path("kernel/process.zig") });
    process_module.addImport("paging", paging_module);
    process_module.addImport("physical", physical_module);
    process_module.addImport("syscalls", syscalls_module);
    process_module.addImport("vfs", vfs_module);
    process_module.addImport("serial", serial_module);
    process_module.addAnonymousImport("hello_elf", .{ .root_source_file = hello.getEmittedBin() });
    process_module.addAnonymousImport("interpreter_elf", .{ .root_source_file = interpreter.getEmittedBin() });
    process_module.addAnonymousImport("dynamic_elf", .{ .root_source_file = dynamic_hello.getEmittedBin() });
    process_module.addAnonymousImport("nettest_elf", .{ .root_source_file = nettest.getEmittedBin() });
    process_module.addAnonymousImport("fbtest_elf", .{ .root_source_file = fbtest.getEmittedBin() });
    process_module.addAnonymousImport("drmtest_elf", .{ .root_source_file = drmtest.getEmittedBin() });
    if (libdrm_probe) |path| process_module.addAnonymousImport("libdrm_probe_elf", .{ .root_source_file = b.path(path) });
    if (radv_loader_probe) |path|
        process_module.addAnonymousImport("radv_loader_probe_elf", .{ .root_source_file = b.path(path) })
    else
        process_module.addAnonymousImport("radv_loader_probe_elf", .{ .root_source_file = dynamic_hello.getEmittedBin() });
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
    kernel_module.addImport("audio", audio_module);
    kernel_module.addImport("gpu", gpu_module);
    kernel_module.addImport("display", display_module);
    kernel_module.addImport("hardware_profile", hardware_profile_module);
    kernel_module.addImport("metrics", metrics_module);
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
    kernel_module.addOptions("build_options", build_options);
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
    qemu.addFileArg(extra.getEmittedBin());
    if (gpu_firmware) |path| {
        qemu.addArg("-GpuFirmware");
        qemu.addArg(path);
    }
    if (radv_runtime) |path| {
        qemu.addArg("-RadvRuntime"); qemu.addArg(path);
        qemu.addArg("-LibdrmAmdgpu"); qemu.addArg(libdrm_amdgpu_runtime orelse "zig-out/mesa-sysroot/usr/lib/libdrm_amdgpu.so.1");
        qemu.addArg("-Libdrm"); qemu.addArg(libdrm_runtime orelse "zig-out/mesa-sysroot/usr/lib/libdrm.so.2");
        qemu.addArg("-Zlib"); qemu.addArg(zlib_runtime orelse "zig-out/mesa-sysroot/usr/lib/libz.so.1");
        qemu.addArg("-Libc"); qemu.addArg(libc_runtime orelse "zig-out/mesa-sysroot/usr/lib/libc.so");
    }
    if (b.args) |args| qemu.addArgs(args);
    run.dependOn(&qemu.step);
}
