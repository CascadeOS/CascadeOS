// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = @import("arch.zig");

pub const PhysAddr = extern struct {
    value: usize,

    pub const zero: PhysAddr = .{ .value = 0 };

    pub fn fromInt(value: usize) PhysAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    comptime {
        std.debug.assert(@sizeOf(PhysAddr) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(PhysAddr) == @bitSizeOf(usize));
    }
};

pub const VirtAddr = extern struct {
    value: usize,

    pub const zero: VirtAddr = .{ .value = 0 };

    pub fn fromInt(value: usize) VirtAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    comptime {
        std.debug.assert(@sizeOf(VirtAddr) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(VirtAddr) == @bitSizeOf(usize));
    }
};

pub const PhysRange = struct {
    addr: PhysAddr,
    size: core.Size,

    pub fn fromAddr(addr: PhysAddr, size: core.Size) PhysRange {
        return .{
            .addr = addr,
            .size = size,
        };
    }

    pub fn format(
        value: PhysRange,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("PhysRange{{ {} {} }}", .{ value.addr, value.size });
    }
};

pub const VirtRange = struct {
    addr: VirtAddr,
    size: core.Size,

    pub fn fromAddr(addr: VirtAddr, size: core.Size) VirtRange {
        return .{
            .addr = addr,
            .size = size,
        };
    }

    pub fn format(
        value: VirtRange,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("VirtRange{{ {} {} }}", .{ value.addr, value.size });
    }
};
