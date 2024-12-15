// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const KernelMemoryRegion = @This();

range: core.VirtualRange,
type: Type,

operation: Operation,

pub const Type = enum {
    writeable_section,
    readonly_section,
    executable_section,
    sdf_section,

    direct_map,
    non_cached_direct_map,

    kernel_stacks,
};

pub const Operation = enum {
    full_map,
    top_level_map,
};

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
const arch = @import("arch");
