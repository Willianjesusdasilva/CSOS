const syscalls = @import("syscalls");

test "AMDGPU ioctl ABI validates state before dispatch and signals after fence" {
    try syscalls.validateAmdGpuDrmAbiSelfTest();
}
