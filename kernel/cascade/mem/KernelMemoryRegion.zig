// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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
                .executable_section => .{ .environment_type = .kernel, .protection = .executable },
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

const cascade = @import("cascade");

const core = @import("core");
const MapType = cascade.mem.MapType;
const std = @import("std");
