// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

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
};

pub const RegionMapInfo = union(enum) {
    top_level,
    full: struct { physical_range: core.PhysicalRange, map_type: MapType },
};

pub fn mapInfo(self: KernelMemoryRegion) RegionMapInfo {
    switch (self.type) {
        .direct_map, .non_cached_direct_map => {
            const physical_range = core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, self.range.size);

            const map_type: MapType = switch (self.type) {
                .direct_map => .{ .writeable = true, .global = true },
                .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
                else => unreachable,
            };

            return .{ .full = .{ .physical_range = physical_range, .map_type = map_type } };
        },

        .writeable_section, .readonly_section, .executable_section, .sdf_section => {
            const physical_range = core.PhysicalRange.fromAddr(
                core.PhysicalAddress.fromInt(
                    self.range.address.value - kernel.vmm.globals.physical_to_virtual_offset.value,
                ),
                self.range.size,
            );

            const map_type: MapType = switch (self.type) {
                .executable_section => .{ .executable = true, .global = true },
                .readonly_section, .sdf_section => .{ .global = true },
                .writeable_section => .{ .writeable = true, .global = true },
                else => unreachable,
            };

            return .{ .full = .{ .physical_range = physical_range, .map_type = map_type } };
        },

        .kernel_heap, .kernel_stacks, .special_heap => return .{ .top_level = {} },
    }
}

pub fn print(region: KernelMemoryRegion, writer: std.io.AnyWriter, indent: usize) !void {
    try writer.writeAll("Region{ ");
    try region.range.print(writer, indent);
    try writer.writeAll(" - ");
    try writer.writeAll(@tagName(region.type));
    try writer.writeAll(" }");
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

fn __helpZls() void {
    KernelMemoryRegion.print(undefined, @as(std.fs.File.Writer, undefined), 0);
}

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const MapType = kernel.vmm.MapType;
