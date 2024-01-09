// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const acpi = @import("acpi.zig");

pub const MCFG = extern struct {
    header: acpi.SharedHeader align(1),

    _reserved: u64 align(1),

    _base_allocations_start: BaseAllocation align(1),

    pub fn baseAllocations(self: *const MCFG) []const BaseAllocation {
        const base_allocations_ptr: [*]const BaseAllocation = @ptrCast(&self._base_allocations_start);

        const size_of_base_allocations = self.header.length - (@sizeOf(acpi.SharedHeader) + @sizeOf(u64));

        core.debugAssert(size_of_base_allocations % @sizeOf(BaseAllocation) == 0);

        return base_allocations_ptr[0 .. size_of_base_allocations / @sizeOf(BaseAllocation)];
    }

    pub const SIGNATURE_STRING = "MCFG";

    pub const BaseAllocation = extern struct {
        base_address: kernel.PhysicalAddress align(1),

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
