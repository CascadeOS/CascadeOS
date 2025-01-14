// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// [ACPI 6.5 Specification Link](https://uefi.org/specs/ACPI/6.5/05_ACPI_Software_Programming_Model.html#differentiated-system-description-table-dsdt)
pub const DSDT = extern struct {
    header: acpi.SharedHeader align(1),

    _definition_block: u8,

    pub const SIGNATURE_STRING = "DSDT";

    pub fn definitionBlock(self: *const DSDT) []const u8 {
        const ptr: [*]const u8 = @ptrCast(&self._definition_block);
        return ptr[0..(self.header.length - @sizeOf(acpi.SharedHeader))];
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(acpi.SharedHeader) + 1);
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = kernel.acpi;
