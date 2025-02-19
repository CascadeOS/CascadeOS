// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const Address = union(enum) {
    physical: core.PhysicalAddress,
    virtual: core.VirtualAddress,

    pub const Raw = extern union {
        physical: core.PhysicalAddress,
        virtual: core.VirtualAddress,
    };
};

pub const PhysicalAddress = extern struct {
    value: u64,

    pub const zero: PhysicalAddress = .{ .value = 0 };

    pub inline fn fromInt(value: u64) PhysicalAddress {
        return .{ .value = value };
    }

    pub inline fn toRange(self: PhysicalAddress, size: core.Size) PhysicalRange {
        return .{ .address = self, .size = size };
    }

    pub inline fn isAligned(self: PhysicalAddress, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.value);
    }

    /// Returns the address rounded up to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForward(self: PhysicalAddress, alignment: core.Size) PhysicalAddress {
        return .{ .value = std.mem.alignForward(u64, self.value, alignment.value) };
    }

    /// Rounds up the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForwardInPlace(self: *PhysicalAddress, alignment: core.Size) void {
        self.value = std.mem.alignForward(u64, self.value, alignment.value);
    }

    /// Returns the address rounded down to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackward(self: PhysicalAddress, alignment: core.Size) PhysicalAddress {
        return .{ .value = std.mem.alignBackward(u64, self.value, alignment.value) };
    }

    /// Rounds down the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackwardInPlace(self: *PhysicalAddress, alignment: core.Size) void {
        self.value = std.mem.alignBackward(u64, self.value, alignment.value);
    }

    pub fn moveForward(self: PhysicalAddress, size: core.Size) PhysicalAddress {
        return .{ .value = self.value + size.value };
    }

    pub fn moveForwardInPlace(self: *PhysicalAddress, size: core.Size) void {
        self.value += size.value;
    }

    pub fn moveBackward(self: PhysicalAddress, size: core.Size) PhysicalAddress {
        return .{ .value = self.value - size.value };
    }

    pub fn moveBackwardInPlace(self: *PhysicalAddress, size: core.Size) void {
        self.value -= size.value;
    }

    pub inline fn equal(self: PhysicalAddress, other: PhysicalAddress) bool {
        return self.value == other.value;
    }

    pub inline fn lessThan(self: PhysicalAddress, other: PhysicalAddress) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: PhysicalAddress, other: PhysicalAddress) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: PhysicalAddress, other: PhysicalAddress) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: PhysicalAddress, other: PhysicalAddress) bool {
        return self.value >= other.value;
    }

    pub fn compare(self: PhysicalAddress, other: PhysicalAddress) core.OrderedComparison {
        if (self.lessThan(other)) return .less;
        if (self.greaterThan(other)) return .greater;
        return .match;
    }

    pub fn print(self: PhysicalAddress, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("PhysicalAddress{ 0x");
        try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        self: PhysicalAddress,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

pub const VirtualAddress = extern struct {
    value: u64,

    pub const zero: VirtualAddress = .{ .value = 0 };

    pub inline fn fromInt(value: u64) VirtualAddress {
        return .{ .value = value };
    }

    pub inline fn fromPtr(ptr: *const anyopaque) VirtualAddress {
        return fromInt(@intFromPtr(ptr));
    }

    /// Interprets the address as a pointer.
    ///
    /// It is the caller's responsibility to ensure that the address is valid in the current address space.
    pub inline fn toPtr(self: VirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(self.value);
    }

    pub inline fn toRange(self: VirtualAddress, size: core.Size) VirtualRange {
        return .{ .address = self, .size = size };
    }

    pub inline fn isAligned(self: VirtualAddress, alignment: core.Size) bool {
        return std.mem.isAligned(self.value, alignment.value);
    }

    /// Returns the address rounded up to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForward(self: VirtualAddress, alignment: core.Size) VirtualAddress {
        return .{ .value = std.mem.alignForward(u64, self.value, alignment.value) };
    }

    /// Rounds up the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForwardInPlace(self: *VirtualAddress, alignment: core.Size) void {
        self.value = std.mem.alignForward(u64, self.value, alignment.value);
    }

    /// Returns the address rounded down to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackward(self: VirtualAddress, alignment: core.Size) VirtualAddress {
        return .{ .value = std.mem.alignBackward(u64, self.value, alignment.value) };
    }

    /// Rounds down the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackwardInPlace(self: *VirtualAddress, alignment: core.Size) void {
        self.value = std.mem.alignBackward(u64, self.value, alignment.value);
    }

    pub fn moveForward(self: VirtualAddress, size: core.Size) VirtualAddress {
        return .{ .value = self.value + size.value };
    }

    pub fn moveForwardInPlace(self: *VirtualAddress, size: core.Size) void {
        self.value += size.value;
    }

    pub fn moveBackward(self: VirtualAddress, size: core.Size) VirtualAddress {
        return .{ .value = self.value - size.value };
    }

    pub fn moveBackwardInPlace(self: *VirtualAddress, size: core.Size) void {
        self.value -= size.value;
    }

    pub inline fn equal(self: VirtualAddress, other: VirtualAddress) bool {
        return self.value == other.value;
    }

    pub inline fn lessThan(self: VirtualAddress, other: VirtualAddress) bool {
        return self.value < other.value;
    }

    pub inline fn lessThanOrEqual(self: VirtualAddress, other: VirtualAddress) bool {
        return self.value <= other.value;
    }

    pub inline fn greaterThan(self: VirtualAddress, other: VirtualAddress) bool {
        return self.value > other.value;
    }

    pub inline fn greaterThanOrEqual(self: VirtualAddress, other: VirtualAddress) bool {
        return self.value >= other.value;
    }

    pub fn compare(self: VirtualAddress, other: VirtualAddress) core.OrderedComparison {
        if (self.lessThan(other)) return .less;
        if (self.greaterThan(other)) return .greater;
        return .match;
    }

    pub fn print(self: VirtualAddress, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.writeAll("VirtualAddress{ 0x");
        try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        self: VirtualAddress,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(self, writer, 0)
        else
            print(self, writer.any(), 0);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

pub const PhysicalRange = extern struct {
    address: PhysicalAddress,
    size: core.Size,

    pub inline fn fromAddr(address: PhysicalAddress, size: core.Size) PhysicalRange {
        return .{
            .address = address,
            .size = size,
        };
    }

    /// Returns the address of the first byte __after__ the range.
    pub fn endBound(self: PhysicalRange) PhysicalAddress {
        return self.address.moveForward(self.size);
    }

    /// Returns the last address in this range.
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn last(self: PhysicalRange) PhysicalAddress {
        if (self.size.value == 0) return self.address;
        return self.address.moveForward(self.size.subtract(core.Size.one));
    }

    pub fn equal(self: PhysicalRange, other: PhysicalRange) bool {
        return self.address.equal(other.address) and self.size.equal(other.size);
    }

    pub fn moveForward(self: PhysicalRange, size: core.Size) PhysicalRange {
        return .{
            .address = self.address.moveForward(size),
            .size = self.size,
        };
    }

    pub fn moveForwardInPlace(self: *PhysicalRange, size: core.Size) void {
        self.address.moveForwardInPlace(size);
    }

    pub fn moveBackward(self: PhysicalRange, size: core.Size) PhysicalRange {
        return .{
            .address = self.address.moveBackward(size),
            .size = self.size,
        };
    }

    pub fn moveBackwardInPlace(self: *PhysicalRange, size: core.Size) void {
        self.address.moveBackwardInPlace(size);
    }

    pub fn containsRange(self: PhysicalRange, other: PhysicalRange) bool {
        if (!self.address.lessThanOrEqual(other.address)) return false;
        if (!self.last().greaterThanOrEqual(other.last())) return false;

        return true;
    }

    pub fn contains(self: PhysicalRange, address: PhysicalAddress) bool {
        return address.greaterThanOrEqual(self.address) and address.lessThanOrEqual(self.last());
    }

    pub fn print(value: PhysicalRange, writer: std.io.AnyWriter, indent: usize) !void {
        try writer.writeAll("PhysicalRange{ 0x");
        try std.fmt.formatInt(value.address.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

        try writer.writeAll(" - 0x");
        try std.fmt.formatInt(value.last().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" - ");

        try value.size.print(writer, indent);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        value: PhysicalRange,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(value, writer, 0)
        else
            print(value, writer.any(), 0);
    }
};

pub const VirtualRange = extern struct {
    address: VirtualAddress,
    size: core.Size,

    /// Returns a virtual range corresponding to the given slice.
    pub fn fromSlice(comptime T: type, slice: []const T) VirtualRange {
        return .{
            .address = VirtualAddress.fromPtr(slice.ptr),
            .size = core.Size.from(@sizeOf(T) * slice.len, .byte),
        };
    }

    /// Returns a byte slice of the memory corresponding to this virtual range.
    ///
    /// It is the caller's responsibility to ensure:
    ///   - the range is valid in the current address space
    ///   - no writes are performed if the range is read-only
    pub inline fn toByteSlice(self: VirtualRange) []u8 {
        return self.address.toPtr([*]u8)[0..self.size.value];
    }

    pub inline fn fromAddr(address: VirtualAddress, size: core.Size) VirtualRange {
        return .{
            .address = address,
            .size = size,
        };
    }

    /// Returns a virtual range between the given addresses exclusive of the end address.
    pub fn between(start: VirtualAddress, end: VirtualAddress) VirtualRange {
        std.debug.assert(start.lessThan(end));

        return .{
            .address = start,
            .size = .from(end.value - start.value, .byte),
        };
    }

    /// Returns the address of the first byte __after__ the range.
    pub fn endBound(self: VirtualRange) VirtualAddress {
        return self.address.moveForward(self.size);
    }

    /// Returns the last address in this range.
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn last(self: VirtualRange) VirtualAddress {
        if (self.size.value == 0) return self.address;
        return self.address.moveForward(self.size.subtract(core.Size.one));
    }

    pub fn equal(self: VirtualRange, other: VirtualRange) bool {
        return self.address.equal(other.address) and self.size.equal(other.size);
    }

    pub fn moveForward(self: VirtualRange, size: core.Size) VirtualRange {
        return .{
            .address = self.address.moveForward(size),
            .size = self.size,
        };
    }

    pub fn moveForwardInPlace(self: *VirtualRange, size: core.Size) void {
        self.address.moveForwardInPlace(size);
    }

    pub fn moveBackward(self: VirtualRange, size: core.Size) VirtualRange {
        return .{
            .address = self.address.moveBackward(size),
            .size = self.size,
        };
    }

    pub fn moveBackwardInPlace(self: *VirtualRange, size: core.Size) void {
        self.address.moveBackwardInPlace(size);
    }

    pub fn containsRange(self: VirtualRange, other: VirtualRange) bool {
        if (!self.address.lessThanOrEqual(other.address)) return false;
        if (!self.last().greaterThanOrEqual(other.last())) return false;

        return true;
    }

    pub fn contains(self: VirtualRange, address: VirtualAddress) bool {
        return address.greaterThanOrEqual(self.address) and address.lessThanOrEqual(self.last());
    }

    pub fn print(value: VirtualRange, writer: std.io.AnyWriter, indent: usize) !void {
        try writer.writeAll("VirtualRange{ 0x");
        try std.fmt.formatInt(value.address.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

        try writer.writeAll(" - 0x");
        try std.fmt.formatInt(value.last().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" - ");

        try value.size.print(writer, indent);
        try writer.writeAll(" }");
    }

    pub inline fn format(
        value: VirtualRange,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(value, writer, 0)
        else
            print(value, writer.any(), 0);
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const std = @import("std");
