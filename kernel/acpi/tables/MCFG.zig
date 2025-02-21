// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// PCI-Express Memory Mapped Configuration Table (MCFG)
pub const MCFG = extern struct {
    header: acpi.tables.SharedHeader align(1),

    _reserved: u64 align(1),

    _base_allocations_start: BaseAllocation align(1),

    pub fn baseAllocations(self: *const MCFG) []const BaseAllocation {
        const base_allocations_ptr: [*]const BaseAllocation = @ptrCast(&self._base_allocations_start);

        const size_of_base_allocations = self.header.length - (@sizeOf(acpi.tables.SharedHeader) + @sizeOf(u64));

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
        core.testing.expectSize(
            @This(),
            @sizeOf(acpi.tables.SharedHeader) + @sizeOf(BaseAllocation) + @sizeOf(u64),
        );
    }
};

const core = @import("core");
const std = @import("std");
const kernel = @import("kernel");
const acpi = kernel.acpi;
