// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const MapType = kernel.mem.MapType;
const core = @import("core");
const addr = kernel.addr;

const KernelMemoryRegion = @This();

range: addr.Virtual.Range.Kernel,
type: Type,

pub const Type = enum {
    writeable_section,
    readonly_section,
    executable_section,
    sdf_section,

    direct_map,

    special_heap,

    kernel_heap,
    kernel_stacks,

    pages,

    kernel_address_space,
};

pub inline fn format(
    region: KernelMemoryRegion,
    writer: *std.Io.Writer,
) !void {
    try writer.print("Region{{ {f} - {t} }}", .{
        region.range,
        region.type,
    });
}

pub const List = struct {
    values: core.containers.BoundedArray(
        KernelMemoryRegion,
        std.meta.tags(Type).len,
    ) = .{},

    /// Find the region of the given type.
    pub fn find(list: *const List, region_type: Type) ?KernelMemoryRegion {
        for (list.values.constSlice()) |region| {
            if (region.type == region_type) return region;
        }
        return null;
    }

    /// Find the region containing the given address.
    pub fn containingAddress(list: *const List, address: addr.Virtual.Kernel) ?KernelMemoryRegion.Type {
        for (list.values.constSlice()) |region| {
            if (region.range.containsAddress(address)) return region.type;
        }
        return null;
    }

    pub fn append(list: *List, region: KernelMemoryRegion) void {
        list.values.appendAssumeCapacity(region);
    }

    pub fn constSlice(list: *const List) []const KernelMemoryRegion {
        return list.values.constSlice();
    }

    pub fn sort(list: *List) void {
        std.mem.sortUnstable(kernel.mem.KernelMemoryRegion, list.values.slice(), {}, struct {
            fn lessThanFn(
                context: void,
                region: kernel.mem.KernelMemoryRegion,
                other_region: kernel.mem.KernelMemoryRegion,
            ) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    pub fn findFreeRange(
        list: *List,
        size: core.Size,
        alignment: std.mem.Alignment,
    ) ?addr.Virtual.Range.Kernel {
        // needs the regions to be sorted
        list.sort();

        const regions = list.constSlice();

        var current_address = arch.paging.higher_half_range.address.toKernel();
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    std.math.maxInt(u64) - current_address.value,
                    .byte,
                );

                if (size_of_free_range.lessThan(size)) return null;

                return .from(current_address, size);
            };

            const region_address = region.range.address;

            if (region_address.lessThanOrEqual(current_address)) {
                current_address = region.range.after();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            const size_of_free_range = core.Size.from(
                (region_address.value - 1) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) {
                current_address = region.range.after();
                current_address.alignForwardInPlace(alignment);
                i += 1;
                continue;
            }

            return .from(current_address, size);
        }
    }
};
