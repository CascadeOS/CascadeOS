// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

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
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

const std = @import("std");
const core = @import("core");

const acpi = @import("acpi");
