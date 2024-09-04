// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// PCI-Express Memory Mapped Configuration Table (MCFG)
pub const MCFG = extern struct {
    header: acpi.SharedHeader align(1),

    _reserved: u64 align(1),

    _base_allocations_start: BaseAllocation align(1),

    pub fn baseAllocations(self: *const MCFG) []const BaseAllocation {
        const base_allocations_ptr: [*]const BaseAllocation = @ptrCast(&self._base_allocations_start);

        const size_of_base_allocations = self.header.length - (@sizeOf(acpi.SharedHeader) + @sizeOf(u64));

        std.debug.assert(size_of_base_allocations % @sizeOf(BaseAllocation) == 0);

        return base_allocations_ptr[0 .. size_of_base_allocations / @sizeOf(BaseAllocation)];
    }

    pub const SIGNATURE_STRING = "MCFG";

    pub const BaseAllocation = extern struct {
        base_address: core.PhysicalAddress align(1),

        segment_group: u16 align(1),

        start_pci_bus: u8,

        end_pci_bus: u8,

        _reserved: u32 align(1),

        comptime {
            core.testing.expectSize(@This(), 16);
        }
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(acpi.SharedHeader) + @sizeOf(BaseAllocation) + @sizeOf(u64));
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

const core = @import("core");
const std = @import("std");

const acpi = @import("acpi");
