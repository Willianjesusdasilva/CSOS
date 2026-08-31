const gpu = @import("gpu");

test "GMC 11 bootstrap activation rolls back on invalidate timeout" {
    try gpu.validateAmdGmc11BootstrapWritesSelfTest();
}

test "GMC 11 MMIO transport requires explicit authorization and arming" {
    try gpu.validateAmdGmc11MmioTransportSelfTest();
}

test "AMDGPU VMIDs isolate mappings and reject overlap" {
    try gpu.validateAmdGpuVmManagerSelfTest();
}

test "AMDGPU GPUVM page paths allocate and roll back atomically" {
    try gpu.validateAmdGpuVmPageTablesSelfTest();
}
