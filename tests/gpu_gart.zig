const gpu = @import("gpu");

test "GMC 11 bootstrap activation rolls back on invalidate timeout" {
    try gpu.validateAmdGmc11BootstrapWritesSelfTest();
}
