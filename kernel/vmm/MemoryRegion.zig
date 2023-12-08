// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const VirtualRange = kernel.VirtualRange;
const vmm = kernel.vmm;

const MemoryRegion = @This();

/// The virtual range of this region.
range: VirtualRange,

/// The type of mapping.
map_type: vmm.MapType,

pub fn print(region: MemoryRegion, writer: anytype) !void {
    try writer.writeAll("MemoryRegion{ 0x");
    try std.fmt.formatInt(region.range.address.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
    try writer.writeAll(" - 0x");
    try std.fmt.formatInt(region.range.end().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

    try writer.writeAll(" ");
    try region.map_type.print(writer);
    try writer.writeAll(" }");
}

pub inline fn format(
    region: MemoryRegion,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;
    return print(region, writer);
}
