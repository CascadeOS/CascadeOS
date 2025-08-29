// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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

    cascade.acpi.init.setRsdp(rsdp);

    try uacpi.setupEarlyTableAccess(&static.buffer);
    globals.acpi_present = true;
}

/// Initialize the ACPI subsystem.
///
/// NOP if ACPI is not present.
pub fn initialize(context: *cascade.Context) !void {
    if (!globals.acpi_present) {
        log.debug(context, "ACPI not present", .{});
        return;
    }

    try cascade.acpi.init.initialize(context);
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
            if (!globals.acpi_present) return null;

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

pub fn logAcpiTables(context: *cascade.Context) !void {
    if (!log.levelEnabled(.debug) or !globals.acpi_present) return;

    // `directMapFromPhysical` is used as the non-cached direct map is not yet initialized
    const sdt_header = cascade.mem.directMapFromPhysical(cascade.acpi.globals.rsdp.sdtAddress())
        .toPtr(*const tables.SharedHeader);

    if (!sdt_header.isValid()) return error.InvalidSDT;

    var iter = tableIterator(sdt_header);

    log.debug(context, "ACPI tables:", .{});

    while (iter.next()) |table| {
        if (table.isValid()) {
            log.debug(context, "  {s}", .{table.signatureAsString()});
        } else {
            log.debug(context, "  {s} - INVALID", .{table.signatureAsString()});
        }
    }
}

fn tableIterator(
    sdt_header: *const tables.SharedHeader,
) TableIterator {
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

const globals = struct {
    /// If this is true, the ACPI tables have been initialized and the RSDP pointer is valid.
    var acpi_present: bool = false;
};

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");

const tables = cascade.acpi.tables;
const uacpi = cascade.acpi.exports.uacpi;

const core = @import("core");
const log = cascade.debug.log.scoped(.init_acpi);
const std = @import("std");
