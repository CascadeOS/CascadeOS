// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const MemoryLayout = @This();

regions: *Regions,

pub fn append(self: *MemoryLayout, region: Region) !void {
    try self.regions.append(region);
    self.sortMemoryLayout();
}

pub fn findFreeRange(self: *MemoryLayout, size: core.Size, alignment: core.Size) ?core.VirtualRange {
    const regions = self.regions.constSlice();

    var current_address = arch.paging.higher_half_start;
    current_address.alignForwardInPlace(alignment);

    var i: usize = 0;

    while (true) {
        const region = if (i < regions.len) regions[i] else {
            const size_of_free_range = core.Size.from(
                (arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) return null;

            return core.VirtualRange.fromAddr(current_address, size);
        };

        const region_address = region.range.address;

        if (region_address.lessThanOrEqual(current_address)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        const size_of_free_range = core.Size.from(
            (region_address.value - 1) - current_address.value,
            .byte,
        );

        if (size_of_free_range.lessThan(size)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        return core.VirtualRange.fromAddr(current_address, size);
    }
}

/// Sorts the kernel memory layout from lowest to highest address.
fn sortMemoryLayout(self: *MemoryLayout) void {
    std.mem.sort(Region, self.regions.slice(), {}, struct {
        fn lessThanFn(context: void, region: Region, other_region: Region) bool {
            _ = context;
            return region.range.address.lessThan(other_region.range.address);
        }
    }.lessThanFn);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const log = kernel.log.scoped(.init_memory_layout);
const arch = @import("arch");
const Regions = kernel.memory_layout.Regions;
const Region = kernel.memory_layout.Region;
