// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = @import("arch.zig");

pub const PhysAddr = extern struct {
    value: usize,

    pub const zero: PhysAddr = .{ .value = 0 };

    pub inline fn fromInt(value: usize) PhysAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    pub inline fn toKernelVirtual(self: PhysAddr) VirtAddr {
        return .{ .value = self.value + kernel.info.hhdm.addr.value };
    }

    pub inline fn isAligned(self: PhysAddr, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.bytes);
    }

    pub inline fn moveForward(self: PhysAddr, size: core.Size) PhysAddr {
        return .{ .value = self.value + size.bytes };
    }

    pub inline fn moveForwardInPlace(self: *PhysAddr, size: core.Size) void {
        self.value += size.bytes;
    }

    pub inline fn moveBackward(self: PhysAddr, size: core.Size) PhysAddr {
        return .{ .value = self.value - size.bytes };
    }

    pub inline fn moveBackwardInPlace(self: *PhysAddr, size: core.Size) void {
        self.value -= size.bytes;
    }

    pub inline fn lessThan(self: PhysAddr, other: PhysAddr) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: PhysAddr, other: PhysAddr) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: PhysAddr, other: PhysAddr) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: PhysAddr, other: PhysAddr) bool {
        return self.value >= other.value;
    }

    pub inline fn equal(self: PhysAddr, other: PhysAddr) bool {
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

    pub inline fn fromInt(value: usize) VirtAddr {
        // TODO: check that the address is valid (cannoical)
        return .{ .value = value };
    }

    pub inline fn fromPtr(ptr: *const anyopaque) VirtAddr {
        return fromInt(@ptrToInt(ptr));
    }

    pub inline fn toPtr(self: VirtAddr, comptime PtrT: type) PtrT {
        return @intToPtr(PtrT, self.value);
    }

    pub fn toPhysicalFromKernelVirtual(self: VirtAddr) !PhysAddr {
        if (kernel.info.hhdm.contains(self)) {
            return .{ .value = self.value - kernel.info.hhdm.addr.value };
        }
        if (kernel.info.non_cached_hhdm.contains(self)) {
            return .{ .value = self.value - kernel.info.non_cached_hhdm.addr.value };
        }
        return error.AddressNotInAnyHHDM;
    }

    pub inline fn isAligned(self: VirtAddr, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.bytes);
    }

    pub inline fn moveForward(self: VirtAddr, size: core.Size) VirtAddr {
        return .{ .value = self.value + size.bytes };
    }

    pub inline fn moveForwardInPlace(self: *VirtAddr, size: core.Size) void {
        self.value += size.bytes;
    }

    pub inline fn moveBackward(self: VirtAddr, size: core.Size) VirtAddr {
        return .{ .value = self.value - size.bytes };
    }

    pub inline fn moveBackwardInPlace(self: *VirtAddr, size: core.Size) void {
        self.value -= size.bytes;
    }

    pub inline fn lessThan(self: VirtAddr, other: VirtAddr) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: VirtAddr, other: VirtAddr) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: VirtAddr, other: VirtAddr) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: VirtAddr, other: VirtAddr) bool {
        return self.value >= other.value;
    }

    pub inline fn equal(self: VirtAddr, other: VirtAddr) bool {
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

    pub inline fn fromAddr(addr: PhysAddr, size: core.Size) PhysRange {
        return .{
            .addr = addr,
            .size = size,
        };
    }

    pub inline fn toKernelVirtual(self: PhysRange) VirtRange {
        return .{
            .addr = self.addr.toKernelVirtual(),
            .size = self.size,
        };
    }

    pub inline fn end(self: PhysRange) PhysAddr {
        return self.addr.moveForward(self.size);
    }

    pub inline fn moveForward(self: PhysRange, size: core.Size) PhysRange {
        return .{
            .addr = self.addr.moveForward(size),
            .size = self.size,
        };
    }

    pub inline fn moveForwardInPlace(self: *PhysRange, size: core.Size) void {
        self.addr.moveForwardInPlace(size);
    }

    pub inline fn moveBackward(self: PhysRange, size: core.Size) PhysRange {
        return .{
            .addr = self.addr.moveBackward(size),
            .size = self.size,
        };
    }

    pub inline fn moveBackwardInPlace(self: *PhysRange, size: core.Size) void {
        self.addr.moveBackwardInPlace(size);
    }

    pub fn contains(self: PhysRange, addr: PhysAddr) bool {
        return addr.greaterThanOrEqual(self.addr) and addr.lessThan(self.end());
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

    pub inline fn fromAddr(addr: VirtAddr, size: core.Size) VirtRange {
        return .{
            .addr = addr,
            .size = size,
        };
    }

    pub inline fn end(self: VirtRange) VirtAddr {
        return self.addr.moveForward(self.size);
    }

    pub inline fn moveForward(self: VirtRange, size: core.Size) VirtRange {
        return .{
            .addr = self.addr.moveForward(size),
            .size = self.size,
        };
    }

    pub inline fn moveForwardInPlace(self: *VirtRange, size: core.Size) void {
        self.addr.moveForwardInPlace(size);
    }

    pub inline fn moveBackward(self: VirtRange, size: core.Size) VirtRange {
        return .{
            .addr = self.addr.moveBackward(size),
            .size = self.size,
        };
    }

    pub inline fn moveBackwardInPlace(self: *VirtRange, size: core.Size) void {
        self.addr.moveBackwardInPlace(size);
    }

    pub fn contains(self: VirtRange, addr: VirtAddr) bool {
        return addr.greaterThanOrEqual(self.addr) and addr.lessThan(self.end());
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
