const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const serial_module = b.createModule(.{ .root_source_file = b.path("arch/x86_64/serial.zig") });
    const physical_module = b.createModule(.{ .root_source_file = b.path("memory/physical.zig") });
    const kernel_module = b.createModule(.{ .root_source_file = b.path("kernel/main.zig") });
    kernel_module.addImport("serial", serial_module);
    kernel_module.addImport("physical", physical_module);
    const boot_module = b.createModule(.{
        .root_source_file = b.path("boot/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    boot_module.addImport("serial", serial_module);
    boot_module.addImport("kernel", kernel_module);
    const boot = b.addExecutable(.{ .name = "BOOTX64", .root_module = boot_module });
    b.installArtifact(boot);

    const run = b.step("run", "Build and boot CSOS in QEMU");
    const qemu = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    qemu.addFileArg(b.path("tools/run.ps1"));
    qemu.addFileArg(boot.getEmittedBin());
    run.dependOn(&qemu.step);
}
