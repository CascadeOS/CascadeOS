// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple physical memory manager that supports contiguous allocations.

const PMM = @This();

free_ranges: Ranges,
total_memory: core.Size,
free_memory: core.Size,
reserved_memory: core.Size,
reclaimable_memory: core.Size,
unavailable_memory: core.Size,

pub const Ranges = std.BoundedArray(core.PhysicalRange, 16);

pub fn allocateContiguousSlice(
    self: *PMM,
    comptime T: type,
    count: usize,
) ![]T {
    const size = core.Size.of(T).multiplyScalar(count);
    const physical_range = try self.allocateContiguousPages(size);
    const virtual_range = kernel.memory_layout.directMapFromPhysicalRange(physical_range);
    return virtual_range.toSliceRelaxed(T)[0..count];
}

/// Allocate contiguous physical pages.
///
/// The allocation is rounded up to the next page.
pub fn allocateContiguousPages(
    self: *PMM,
    requested_size: core.Size,
) error{InsufficentContiguousPhysicalMemory}!core.PhysicalRange {
    if (requested_size.value == 0) core.panic("non-zero size required", null);

    const size = requested_size.alignForward(arch.paging.standard_page_size);

    const ranges: []core.PhysicalRange = self.free_ranges.slice();

    for (ranges, 0..) |*range, i| {
        if (range.size.lessThan(size)) continue;

        // found a range with enough space for the allocation

        const allocated_range = core.PhysicalRange.fromAddr(range.address, size);

        range.size.subtractInPlace(size);

        if (range.size.value == 0) {
            // the range is now empty, so remove it from `free_ranges`
            _ = self.free_ranges.swapRemove(i);
        } else {
            range.address.moveForwardInPlace(size);
        }

        return allocated_range;
    }

    return error.InsufficentContiguousPhysicalMemory;
}

pub fn usedMemory(self: *const PMM) core.Size {
    return self.total_memory
        .subtract(self.free_memory)
        .subtract(self.reserved_memory)
        .subtract(self.reclaimable_memory)
        .subtract(self.unavailable_memory);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const log = kernel.log.scoped(.pmm);
const arch = @import("arch");
