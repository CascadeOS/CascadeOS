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

    pub fn isAligned(self: PhysAddr, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.bytes);
    }

    pub fn moveForward(self: PhysAddr, size: core.Size) PhysAddr {
        return .{ .value = self.value + size.bytes };
    }

    pub fn moveForwardInPlace(self: *PhysAddr, size: core.Size) void {
        self.value += size.bytes;
    }

    pub fn moveBackward(self: PhysAddr, size: core.Size) PhysAddr {
        return .{ .value = self.value - size.bytes };
    }

    pub fn moveBackwardInPlace(self: *PhysAddr, size: core.Size) void {
        self.value -= size.bytes;
    }

    pub fn lessThan(self: PhysAddr, other: PhysAddr) bool {
        return self.value < other.value;
    }

    pub fn lessThanOrEqual(self: PhysAddr, other: PhysAddr) bool {
        return self.value <= other.value;
    }

    pub fn greaterThan(self: PhysAddr, other: PhysAddr) bool {
        return self.value > other.value;
    }

    pub fn greaterThanOrEqual(self: PhysAddr, other: PhysAddr) bool {
        return self.value >= other.value;
    }

    pub fn equal(self: PhysAddr, other: PhysAddr) bool {
        return self.value == other.value;
    }

    pub fn format(
        self: PhysAddr,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("PhysAddr{ 0x");
        try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" }");
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

    pub fn isAligned(self: VirtAddr, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.bytes);
    }

    pub fn moveForward(self: VirtAddr, size: core.Size) VirtAddr {
        return .{ .value = self.value + size.bytes };
    }

    pub fn moveForwardInPlace(self: *VirtAddr, size: core.Size) void {
        self.value += size.bytes;
    }

    pub fn moveBackward(self: VirtAddr, size: core.Size) VirtAddr {
        return .{ .value = self.value - size.bytes };
    }

    pub fn moveBackwardInPlace(self: *VirtAddr, size: core.Size) void {
        self.value -= size.bytes;
    }

    pub fn lessThan(self: VirtAddr, other: VirtAddr) bool {
        return self.value < other.value;
    }

    pub fn lessThanOrEqual(self: VirtAddr, other: VirtAddr) bool {
        return self.value <= other.value;
    }

    pub fn greaterThan(self: VirtAddr, other: VirtAddr) bool {
        return self.value > other.value;
    }

    pub fn greaterThanOrEqual(self: VirtAddr, other: VirtAddr) bool {
        return self.value >= other.value;
    }

    pub fn equal(self: VirtAddr, other: VirtAddr) bool {
        return self.value == other.value;
    }

    pub fn format(
        self: VirtAddr,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("VirtAddr{ 0x");
        try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" }");
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
