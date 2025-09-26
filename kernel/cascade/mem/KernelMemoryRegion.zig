// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const MapType = cascade.mem.MapType;
const core = @import("core");

const KernelMemoryRegion = @This();

range: core.VirtualRange,
type: Type,

pub const Type = enum {
    writeable_section,
    readonly_section,
    executable_section,
    sdf_section,

    direct_map,
    non_cached_direct_map,

    special_heap,

    kernel_heap,
    kernel_stacks,

    pages,

    pageable_kernel_address_space,
};

pub const RegionMapInfo = union(enum) {
    top_level,
    full: struct { physical_range: core.PhysicalRange, map_type: MapType },
    back_with_frames: MapType,
};

pub fn mapInfo(kernel_memory_region: KernelMemoryRegion) RegionMapInfo {
    switch (kernel_memory_region.type) {
        .direct_map, .non_cached_direct_map => {
            const physical_range = core.PhysicalRange.fromAddr(
                core.PhysicalAddress.zero,
                kernel_memory_region.range.size,
            );

            const map_type: MapType = switch (kernel_memory_region.type) {
                .direct_map => .{ .environment_type = .kernel, .protection = .read_write },
                .non_cached_direct_map => .{
                    .environment_type = .kernel,
                    .protection = .read_write,
                    .cache = .uncached,
                },
                else => unreachable,
            };

            return .{ .full = .{
                .physical_range = physical_range,
                .map_type = map_type,
            } };
        },

        .writeable_section, .readonly_section, .executable_section, .sdf_section => {
            const physical_range = core.PhysicalRange.fromAddr(
                core.PhysicalAddress.fromInt(
                    kernel_memory_region.range.address.value - cascade.mem.globals.physical_to_virtual_offset.value,
                ),
                kernel_memory_region.range.size,
            );

            const map_type: MapType = switch (kernel_memory_region.type) {
                .executable_section => .{ .environment_type = .kernel, .protection = .execute },
                .readonly_section, .sdf_section => .{ .environment_type = .kernel, .protection = .read },
                .writeable_section => .{ .environment_type = .kernel, .protection = .read_write },
                else => unreachable,
            };

            return .{ .full = .{ .physical_range = physical_range, .map_type = map_type } };
        },

        .kernel_heap, .kernel_stacks, .special_heap, .pageable_kernel_address_space => return .top_level,

        .pages => return .{ .back_with_frames = .{
            .environment_type = .kernel,
            .protection = .read_write,
        } },
    }
}

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
    pub fn containingAddress(list: *const List, address: core.VirtualAddress) ?KernelMemoryRegion.Type {
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
        std.mem.sort(cascade.mem.KernelMemoryRegion, list.values.slice(), {}, struct {
            fn lessThanFn(
                context: void,
                region: cascade.mem.KernelMemoryRegion,
                other_region: cascade.mem.KernelMemoryRegion,
            ) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    pub fn findFreeRange(
        list: *List,
        size: core.Size,
        alignment: core.Size,
    ) ?core.VirtualRange {
        // needs the regions to be sorted
        list.sort();

        const regions = list.constSlice();

        var current_address = arch.paging.higher_half_start;
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    std.math.maxInt(u64) - current_address.value,
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
};
