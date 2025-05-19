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
};

pub const RegionMapInfo = union(enum) {
    top_level,
    full: struct { physical_range: core.PhysicalRange, map_type: MapType },
    back_with_frames: MapType,
};

pub fn mapInfo(self: KernelMemoryRegion) RegionMapInfo {
    switch (self.type) {
        .direct_map, .non_cached_direct_map => {
            const physical_range = core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, self.range.size);

            const map_type: MapType = switch (self.type) {
                .direct_map => .{ .mode = .kernel, .writeable = true },
                .non_cached_direct_map => .{ .mode = .kernel, .writeable = true, .no_cache = true },
                else => unreachable,
            };

            return .{ .full = .{ .physical_range = physical_range, .map_type = map_type } };
        },

        .writeable_section, .readonly_section, .executable_section, .sdf_section => {
            const physical_range = core.PhysicalRange.fromAddr(
                core.PhysicalAddress.fromInt(
                    self.range.address.value - kernel.mem.globals.physical_to_virtual_offset.value,
                ),
                self.range.size,
            );

            const map_type: MapType = switch (self.type) {
                .executable_section => .{ .mode = .kernel, .executable = true },
                .readonly_section, .sdf_section => .{
                    .mode = .kernel,
                },
                .writeable_section => .{ .mode = .kernel, .writeable = true },
                else => unreachable,
            };

            return .{ .full = .{ .physical_range = physical_range, .map_type = map_type } };
        },

        .kernel_heap, .kernel_stacks, .special_heap => return .top_level,

        .pages => return .{ .back_with_frames = .{ .mode = .kernel, .writeable = true } },
    }
}

pub fn print(region: KernelMemoryRegion, writer: std.io.AnyWriter, indent: usize) !void {
    _ = indent;
    try writer.print("Region{{ {} - {s} }}", .{
        region.range,
        @tagName(region.type),
    });
}

pub inline fn format(
    region: KernelMemoryRegion,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return if (@TypeOf(writer) == std.io.AnyWriter)
        print(region, writer, 0)
    else
        print(region, writer.any(), 0);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const MapType = kernel.mem.MapType;
