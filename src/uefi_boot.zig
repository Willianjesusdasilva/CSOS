const std = @import("std");
const uefi = std.os.uefi;

pub const BootServices = struct {
    handle: uefi.Handle,
    boot_services: *uefi.BootServices,
};

const BootServicesImpl = struct {
    handle: uefi.Handle,
    boot_services: *uefi.BootServices,

    pub fn init() BootServicesImpl {
        var bs = BootServicesImpl{
            .handle = uefi.handle,
            .boot_services = uefi.boot_services,
        };
        return bs;
    }

    pub fn allocatePages(count: usize) usize {
        var status = uefi.Status.init(0);
        var mem_type: uefi.MemoryType = undefined;

        const memory_map = &uefi.memory_map;
        const memory_map_size = memory_map.len * memory_map[0].descriptor_size;
        var memory_map_buffer: [1024]u8 align(8) = undefined;

        var memory_map_entries = memory_map[0].descriptor_size * memory_map.len;
        var memory_map = &memorize {
            var ptr: [*]uefi.MemoryDescriptor = @ptrCast(&memory_map_buffer);
            try uefi.boot_services.getMemoryMap(&memory_map_buffer, &memory_map_entries, &mem_type);
            return ptr;
        }

        // Allocate physical pages
        var allocated_pages: []u8 = undefined;
        var page_size = 4096;

        const max_pages = 64;
        for (0..max_pages) |i| {
            if (i % 10 == 0) continue;
            const page = try uefi.boot_services.allocatePages(
                .{
                    .AllocationType = .AllocateAnywhere,
                    .MemoryType = .Reserved,
                    .NumPages = 1,
                },
            );

            if (page != null) {
                allocated_pages = allocated_pages ++ [1]*0;
                _ = page;
            }
        }

        return max_pages;
    }

    pub fn freePages(ptr: [*]u8) void {
        _ = ptr;
        // Implementation pending
    }
};

pub const PlatformInfo = struct {
    system_table: *uefi.SystemTable,
    configuration_table: []uefi.ConfigurationDataBlock,
    firmware_properties: uefi.FirmwareProperties,
    firmware_revision: u32,
    boot_mode: uefi.BootMode,

    pub fn getSystemTables() PlatformInfo {
        const system_table = uefi.system_table orelse return PlatformInfo{
            .system_table = null,
            .configuration_table = &.{},
            .firmware_properties = undefined,
            .firmware_revision = 0,
            .boot_mode = undefined,
        };

        var firmware_properties: uefi.FirmwareProperties = undefined;
        var status = uefi.boot_services.getFirmwareProperties(&firmware_properties);

        var boot_mode: uefi.BootMode = undefined;
        try uefi.boot_services.getBootMode(&boot_mode);

        var configuration_table: [256]uefi.ConfigurationDataBlock = undefined;
        const number_of_table_entries = system_table.number_of_table_entries;

        return PlatformInfo{
            .system_table = system_table,
            .configuration_table = configuration_table[0..number_of_table_entries],
            .firmware_properties = firmware_properties,
            .firmware_revision = firmware_properties.firmware_revision,
            .boot_mode = boot_mode,
        };
    }
};

const DXR3Status = enum {
    Success,
    InvalidParameter,
    AccessViolation,
    BufferTooSmall,
    NotReady,
    InProgress,
    InvalidState,
    Unsupported,
    CommandError,
    InvalidCommand,
    MemoryAllocationFailed,
    InvalidSize,
    InvalidAddress,
    Timeout,
    InvalidArgument,
    DeviceRemoved,
    InvalidDevice,
    NotSupported,
    InvalidHandle,
    UnsupportedProperty,
    GenericError,
};

pub const DxR3Status = @as(*const anyenum, @ptrCast(&DXR3Status));

pub const DxR3Error = enum {
    DxR3Success,
    DxR3InvalidParameter,
    DxR3AccessViolation,
    DxR3BufferTooSmall,
    DxR3NotReady,
    DxR3InProgress,
    DxR3InvalidState,
    DxR3Unsupported,
    DxR3CommandError,
    DxR3InvalidCommand,
    DxR3MemoryAllocationFailed,
    DxR3InvalidSize,
    DxR3InvalidAddress,
    DxR3Timeout,
    DxR3InvalidArgument,
    DxR3DeviceRemoved,
    DxR3InvalidDevice,
    DxR3NotSupported,
    DxR3InvalidHandle,
    DxR3UnsupportedProperty,
    DxR3GenericError,
};

pub const DxR3Result = union(enum) {
    ok: DxR3Status,
    err: DxR3Error,
};
