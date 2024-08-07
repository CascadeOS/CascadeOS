// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const acpi = @import("acpi");

const log = kernel.log.scoped(.acpi);

pub const init = struct {
    /// Initialized during `initializeACPITables`.
    var sdt_header: *const acpi.SharedHeader = undefined;

    /// Initializes access to the ACPI tables.
    pub fn initializeACPITables() void {
        const rsdp_address = kernel.boot.rsdp() orelse core.panic("RSDP not provided by bootloader", null);
        const rsdp = rsdp_address.toPtr(*const acpi.RSDP);

        log.debug("ACPI revision: {d}", .{rsdp.revision});

        log.debug("validating rsdp", .{});
        if (!rsdp.isValid()) core.panic("invalid RSDP", null);

        sdt_header = kernel.vmm.directMapFromPhysical(rsdp.sdtAddress()).toPtr(*const acpi.SharedHeader);

        log.debug("validating sdt", .{});
        if (!sdt_header.isValid()) core.panic("invalid SDT", null);

        if (log.levelEnabled(.debug)) {
            var iter = acpi.tableIterator(
                sdt_header,
                kernel.vmm.directMapFromPhysical,
            );

            log.debug("ACPI tables:", .{});

            while (iter.next()) |table| {
                if (table.isValid()) {
                    log.debug("  {s}", .{table.signatureAsString()});
                } else {
                    log.debug("  {s} - INVALID", .{table.signatureAsString()});
                }
            }
        }
    }

    /// Get the `n`th matching ACPI table if present.
    ///
    /// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
    ///
    /// If the table is not valid, returns `null`.
    pub fn getTable(comptime T: type, n: usize) ?*const T {
        var iter = acpi.tableIterator(
            sdt_header,
            kernel.vmm.directMapFromPhysical,
        );

        var i: usize = 0;

        while (iter.next()) |header| {
            if (!header.signatureIs(T.SIGNATURE_STRING)) continue;

            if (i != n) continue;
            i += 1;

            if (!header.isValid()) {
                log.warn("invalid table: {s}", .{header.signatureAsString()});
                return null;
            }

            return @ptrCast(header);
        }

        return null;
    }
};
