// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const KernelMemoryLayout = @This();

layout: std.BoundedArray(KernelMemoryRegion, std.meta.tags(KernelMemoryRegion.Type).len) = .{},

/// Registers a kernel memory region.
pub fn registerRegion(self: *KernelMemoryLayout, region: KernelMemoryRegion) void {
    self.layout.append(region) catch unreachable;
    self.sortKernelMemoryLayout();
}

/// Sorts the kernel memory layout from lowest to highest address.
fn sortKernelMemoryLayout(self: *KernelMemoryLayout) void {
    std.mem.sort(KernelMemoryRegion, self.layout.slice(), {}, struct {
        fn lessThanFn(context: void, region: KernelMemoryRegion, other_region: KernelMemoryRegion) bool {
            _ = context;
            return region.range.address.lessThan(other_region.range.address);
        }
    }.lessThanFn);
}

pub const KernelMemoryRegion = struct {
    range: kernel.VirtualRange,
    type: Type,

    pub const Type = enum {
        writeable_section,
        readonly_section,
        executable_section,
        direct_map,
        non_cached_direct_map,
        heap,
        stacks,
    };

    pub fn print(region: KernelMemoryRegion, writer: anytype) !void {
        try writer.writeAll("KernelMemoryRegion{ ");
        try region.range.print(writer);
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
        return print(region, writer);
    }
};
