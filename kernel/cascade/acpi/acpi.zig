// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

pub const Address = @import("Address.zig").Address;
pub const tables = @import("tables/tables.zig");
const uacpi = @import("uacpi.zig");

const log = cascade.debug.log.scoped(.acpi);

pub fn tryShutdown(current_task: *cascade.Task) !void {
    if (!globals.acpi_initialized) return;

    try uacpi.prepareForSleep(.S5);

    current_task.context.incrementInterruptDisable();
    defer current_task.context.decrementInterruptDisable();

    try uacpi.sleep(.S5);
}

pub const globals = struct {
    /// Pointer to the RSDP table.
    ///
    /// Set by `init.earlyInitialize`.
    pub var rsdp: *const tables.RSDP = undefined;

    /// Set by `init.initialize`.
    var acpi_initialized: bool = false;
};

pub const init = struct {
    const boot = @import("boot");
    const init_log = cascade.debug.log.scoped(.acpi_init);

    /// Initializes ACPI table access early.
    ///
    /// NOP if ACPI is not present.
    pub fn earlyInitialize() !void {
        const static = struct {
            var buffer: [arch.paging.standard_page_size.value]u8 = undefined;
        };

        const rsdp = switch (boot.rsdp() orelse return) {
            // using `directMapFromPhysical` as the non-cached direct map is not yet initialized
            .physical => |addr| cascade.mem.directMapFromPhysical(addr).toPtr(*const tables.RSDP),
            .virtual => |addr| addr.toPtr(*const tables.RSDP),
        };
        if (!rsdp.isValid()) return error.InvalidRSDP;
        globals.rsdp = rsdp;

        try uacpi.setupEarlyTableAccess(&static.buffer);
        init_globals.acpi_present = true;
    }

    pub fn logAcpiTables(current_task: *cascade.Task) !void {
        if (!init_log.levelEnabled(.debug) or !init_globals.acpi_present) return;

        // `directMapFromPhysical` is used as the non-cached direct map is not yet initialized
        const sdt_header = cascade.mem.directMapFromPhysical(globals.rsdp.sdtAddress())
            .toPtr(*const tables.SharedHeader);

        if (!sdt_header.isValid()) return error.InvalidSDT;

        var iter = tableIterator(sdt_header);

        init_log.debug(current_task, "ACPI tables:", .{});

        while (iter.next()) |table| {
            if (table.isValid()) {
                init_log.debug(current_task, "  {s}", .{table.signatureAsString()});
            } else {
                init_log.debug(current_task, "  {s} - INVALID", .{table.signatureAsString()});
            }
        }
    }

    /// Initialize the ACPI subsystem.
    ///
    /// NOP if ACPI is not present.
    pub fn initialize(current_task: *cascade.Task) !void {
        if (!init_globals.acpi_present) {
            init_log.debug(current_task, "ACPI not present", .{});
            return;
        }

        init_log.debug(current_task, "entering ACPI mode", .{});
        try uacpi.initialize(.{});

        try uacpi.FixedEvent.power_button.installHandler(
            void,
            earlyPowerButtonHandler,
            null,
        );

        init_log.debug(current_task, "loading namespace", .{});
        try uacpi.namespaceLoad();

        if (arch.current_arch == .x64) {
            try uacpi.setInterruptModel(.ioapic);
        }

        init_log.debug(current_task, "initializing namespace", .{});
        try uacpi.namespaceInitialize();

        init_log.debug(current_task, "finializing GPEs", .{});
        try uacpi.finializeGpeInitialization();

        globals.acpi_initialized = true;
    }

    fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
        const current_task: *cascade.Task = cascade.Task.Context.current().task();
        log.warn(current_task, "power button pressed", .{});
        tryShutdown(current_task) catch |err| {
            std.debug.panic("failed to shutdown: {t}", .{err});
        };
        @panic("shutdown failed");
    }

    pub fn AcpiTable(comptime T: type) type {
        return struct {
            table: *const T,

            handle: uacpi.Table,

            const AcpiTableT = @This();

            /// Get the `n`th matching ACPI table if present.
            ///
            /// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
            pub fn get(n: usize) ?AcpiTable(T) {
                if (!init_globals.acpi_present) return null;

                var table = uacpi.Table.findBySignature(T.SIGNATURE_STRING) catch null orelse return null;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const found_next = table.nextWithSameSignature() catch return null;
                    if (!found_next) return null;
                }

                return .{
                    .table = @ptrCast(@alignCast(table.table.ptr)),
                    .handle = table,
                };
            }

            pub fn deinit(acpi_table: AcpiTableT) void {
                acpi_table.handle.unref() catch unreachable;
            }

            pub inline fn format(acpi_table: AcpiTableT, writer: *std.Io.Writer) !void {
                try writer.print(
                    "AcpiTable{{ signature: {s}, revision: {d} }}",
                    .{ acpi_table.table.header.signatureAsString(), acpi_table.table.header.revision },
                );
            }
        };
    }

    fn tableIterator(sdt_header: *const tables.SharedHeader) TableIterator {
        const sdt_ptr: [*]const u8 = @ptrCast(sdt_header);

        const is_xsdt = sdt_header.signatureIs("XSDT");
        std.debug.assert(is_xsdt or sdt_header.signatureIs("RSDT")); // Invalid SDT signature.

        return .{
            .ptr = sdt_ptr + @sizeOf(tables.SharedHeader),
            .end_ptr = sdt_ptr + sdt_header.length,
            .is_xsdt = is_xsdt,
        };
    }

    const TableIterator = struct {
        ptr: [*]const u8,
        end_ptr: [*]const u8,

        is_xsdt: bool,

        pub fn next(table_iterator: *TableIterator) ?*const tables.SharedHeader {
            const opt_phys_addr = if (table_iterator.is_xsdt)
                table_iterator.nextTablePhysicalAddressImpl(u64)
            else
                table_iterator.nextTablePhysicalAddressImpl(u32);

            // `directMapFromPhysical` is used as the non-cached direct map is not yet initialized
            return cascade.mem
                .directMapFromPhysical(opt_phys_addr orelse return null)
                .toPtr(*const tables.SharedHeader);
        }

        fn nextTablePhysicalAddressImpl(table_iterator: *TableIterator, comptime T: type) ?core.PhysicalAddress {
            if (@intFromPtr(table_iterator.ptr) + @sizeOf(T) >= @intFromPtr(table_iterator.end_ptr)) return null;

            const physical_address = std.mem.readInt(T, @ptrCast(table_iterator.ptr), .little);

            table_iterator.ptr += @sizeOf(T);

            return core.PhysicalAddress.fromInt(physical_address);
        }
    };

    const init_globals = struct {
        /// If this is true, the ACPI tables have been initialized and the RSDP pointer is valid.
        var acpi_present: bool = false;
    };
};

comptime {
    _ = @import("uacpi_kernel_api.zig"); // ensure kernel api is exported
}
