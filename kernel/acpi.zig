// SPDX-License-Identifier: MIT AND BSD-2-Clause
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>
// SPDX-FileCopyrightText: 2019-2024 mintsuki and contributors (https://github.com/lowlevelmemes/acpi-shutdown-hack/blob/115c66d097e9d52015907a4ff27cd1ba34aee0d9/LICENSE)

/// Get the `n`th matching ACPI table if present.
///
/// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
///
/// If the table is not valid, returns `null`.
pub fn getTable(comptime T: type, n: usize) ?*const T {
    var iter = acpi.tableIterator(
        globals.sdt_header,
        kernel.vmm.nonCachedDirectMapFromPhysical,
    );

    var i: usize = 0;

    while (iter.next()) |header| {
        if (!header.signatureIs(T.SIGNATURE_STRING)) {
            continue;
        }

        if (i != n) {
            i += 1;
            continue;
        }

        if (!header.isValid()) {
            log.warn("invalid table: {s}", .{header.signatureAsString()});
            return null;
        }

        return @ptrCast(header);
    }

    return null;
}

const globals = struct {
    /// Initialized during `init.initializeACPITables`.
    var sdt_header: *const acpi.SharedHeader = undefined;
};

pub const init = struct {
    pub fn initializeACPITables() !void {
        const rsdp_address = kernel.boot.rsdp() orelse return error.RSDPNotProvided;

        const rsdp = switch (rsdp_address) {
            .physical => |addr| kernel.vmm.nonCachedDirectMapFromPhysical(addr).toPtr(*const acpi.RSDP),
            .virtual => |addr| addr.toPtr(*const acpi.RSDP),
        };
        if (!rsdp.isValid()) return error.InvalidRSDP;

        const sdt_header = kernel.vmm.nonCachedDirectMapFromPhysical(rsdp.sdtAddress()).toPtr(*const acpi.SharedHeader);

        if (!sdt_header.isValid()) return error.InvalidSDT;

        if (init_log.levelEnabled(.debug)) {
            var iter = acpi.tableIterator(
                sdt_header,
                kernel.vmm.nonCachedDirectMapFromPhysical,
            );

            init_log.debug("ACPI tables:", .{});

            while (iter.next()) |table| {
                if (table.isValid()) {
                    init_log.debug("  {s}", .{table.signatureAsString()});
                } else {
                    init_log.debug("  {s} - INVALID", .{table.signatureAsString()});
                }
            }
        }

        globals.sdt_header = sdt_header;
    }

    const init_log = kernel.log.scoped(.init_acpi);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = @import("acpi");
const log = kernel.log.scoped(.acpi);
