// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const acpi = cascade.acpi;

/// PCI-Express Memory Mapped Configuration Table (MCFG)
pub const MCFG = extern struct {
    header: acpi.tables.SharedHeader align(1),

    _reserved: u64 align(1),

    _base_allocations_start: BaseAllocation align(1),

    pub fn baseAllocations(mcfg: *const MCFG) []const BaseAllocation {
        const base_allocations_ptr: [*]const BaseAllocation = @ptrCast(&mcfg._base_allocations_start);

        const size_of_base_allocations = mcfg.header.length - (@sizeOf(acpi.tables.SharedHeader) + @sizeOf(u64));

        if (core.is_debug) std.debug.assert(size_of_base_allocations % @sizeOf(BaseAllocation) == 0);

        return base_allocations_ptr[0 .. size_of_base_allocations / @sizeOf(BaseAllocation)];
    }

    pub const SIGNATURE_STRING = "MCFG";

    pub const BaseAllocation = extern struct {
        base_address: cascade.PhysicalAddress align(1),

        segment_group: u16 align(1),

        start_pci_bus: u8,

        end_pci_bus: u8,

        _reserved: u32 align(1),

        comptime {
            core.testing.expectSize(BaseAllocation, .from(16, .byte));
        }
    };

    comptime {
        core.testing.expectSize(
            MCFG,
            core.Size.of(acpi.tables.SharedHeader)
                .add(.of(BaseAllocation))
                .add(.of(u64)),
        );
    }
};
