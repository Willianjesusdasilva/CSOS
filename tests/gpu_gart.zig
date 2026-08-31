const gpu = @import("gpu");

test "GMC 11 bootstrap activation rolls back on invalidate timeout" {
    try gpu.validateAmdGmc11BootstrapWritesSelfTest();
}

test "GMC 11 MMIO transport requires explicit authorization and arming" {
    try gpu.validateAmdGmc11MmioTransportSelfTest();
}

test "GMC 11 VM context bind and unbind invalidate transactionally" {
    try gpu.validateAmdGmc11VmContextSelfTest();
}

test "AMDGPU VMIDs isolate mappings and reject overlap" {
    try gpu.validateAmdGpuVmManagerSelfTest();
}

test "AMDGPU hardware VM session preserves bind state across failures" {
    try gpu.validateAmdGpuVmHardwareSessionSelfTest();
}

test "AMDGPU GPUVM page paths allocate and roll back atomically" {
    try gpu.validateAmdGpuVmPageTablesSelfTest();
}

test "AMDGPU GPUVM branches share directories and prune by reference" {
    try gpu.validateAmdGpuVmBranchPlannerSelfTest();
}
