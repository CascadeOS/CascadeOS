// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
///
/// If the table is not valid, returns `null`.
pub fn getTable(comptime T: type, n: usize) ?*const T {
    var iter = acpi.tableIterator(
        globals.sdt_header,
        kernel.memory_layout.directMapFromPhysical,
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

pub const globals = struct {
    /// Initialized during `init.initializeACPITables`.
    pub var sdt_header: *const acpi.SharedHeader = undefined;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const acpi = @import("acpi");
const log = kernel.log.scoped(.acpi);
