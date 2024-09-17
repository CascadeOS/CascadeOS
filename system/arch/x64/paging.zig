// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Create a new page table at the given physical range.
///
/// The range must have alignment of `page_table_alignment` and size greater than or equal to
/// `page_table_size`.
pub fn createPageTable(physical_range: core.PhysicalRange) *ArchPageTable {
    std.debug.assert(physical_range.address.isAligned(page_table_alignment));
    std.debug.assert(physical_range.size.greaterThanOrEqual(page_table_size));

    const page_table = kernel.memory_layout.directMapFromPhysical(physical_range.address).toPtr(*ArchPageTable);
    page_table.zero();
    return page_table;
}

pub fn loadPageTable(physical_address: core.PhysicalAddress) void {
    lib_x64.registers.Cr3.writeAddress(physical_address);
}

pub const page_table_alignment = ArchPageTable.small_page_size;
pub const page_table_size = ArchPageTable.small_page_size;

pub const all_page_sizes = &.{
    ArchPageTable.small_page_size,
    ArchPageTable.medium_page_size,
    ArchPageTable.large_page_size,
};

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

pub const ArchPageTable = lib_x64.PageTable;

pub const init = struct {
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const arch = @import("arch");
