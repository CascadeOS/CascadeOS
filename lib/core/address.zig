// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const core = @import("core");

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

    pub inline fn toRange(physical_address: PhysicalAddress, size: core.Size) PhysicalRange {
        return .{ .address = physical_address, .size = size };
    }

    pub inline fn isAligned(physical_address: PhysicalAddress, alignment: core.Size) bool {
        return std.mem.isAligned(physical_address.value, alignment.value);
    }

    /// Returns the address rounded up to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForward(physical_address: PhysicalAddress, alignment: core.Size) PhysicalAddress {
        return .{ .value = std.mem.alignForward(u64, physical_address.value, alignment.value) };
    }

    /// Rounds up the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForwardInPlace(physical_address: *PhysicalAddress, alignment: core.Size) void {
        physical_address.value = std.mem.alignForward(u64, physical_address.value, alignment.value);
    }

    /// Returns the address rounded down to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackward(physical_address: PhysicalAddress, alignment: core.Size) PhysicalAddress {
        return .{ .value = std.mem.alignBackward(u64, physical_address.value, alignment.value) };
    }

    /// Rounds down the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackwardInPlace(physical_address: *PhysicalAddress, alignment: core.Size) void {
        physical_address.value = std.mem.alignBackward(u64, physical_address.value, alignment.value);
    }

    pub fn moveForward(physical_address: PhysicalAddress, size: core.Size) PhysicalAddress {
        return .{ .value = physical_address.value + size.value };
    }

    pub fn moveForwardInPlace(physical_address: *PhysicalAddress, size: core.Size) void {
        physical_address.value += size.value;
    }

    pub fn moveBackward(physical_address: PhysicalAddress, size: core.Size) PhysicalAddress {
        return .{ .value = physical_address.value - size.value };
    }

    pub fn moveBackwardInPlace(physical_address: *PhysicalAddress, size: core.Size) void {
        physical_address.value -= size.value;
    }

    pub inline fn equal(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value == other.value;
    }

    pub inline fn notEqual(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value != other.value;
    }

    pub inline fn lessThan(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value < other.value;
    }

    pub inline fn lessThanOrEqual(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value <= other.value;
    }

    pub inline fn greaterThan(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value > other.value;
    }

    pub inline fn greaterThanOrEqual(physical_address: PhysicalAddress, other: PhysicalAddress) bool {
        return physical_address.value >= other.value;
    }

    pub fn compare(physical_address: PhysicalAddress, other: PhysicalAddress) std.math.Order {
        if (physical_address.lessThan(other)) return .lt;
        if (physical_address.greaterThan(other)) return .gt;
        return .eq;
    }

    pub inline fn format(physical_address: PhysicalAddress, writer: *std.Io.Writer) !void {
        try writer.print("PhysicalAddress{{ 0x{x:0>16} }}", .{physical_address.value});
    }

    comptime {
        core.testing.expectSize(PhysicalAddress, @sizeOf(u64));
    }
};

pub const VirtualAddress = extern struct {
    value: u64,

    pub const zero: VirtualAddress = .{ .value = 0 };
    pub const undefined_address: core.VirtualAddress = .fromInt(0xAAAAAAAAAAAAAAAA);

    pub inline fn fromInt(value: u64) VirtualAddress {
        return .{ .value = value };
    }

    pub inline fn fromPtr(ptr: *const anyopaque) VirtualAddress {
        return fromInt(@intFromPtr(ptr));
    }

    /// Interprets the address as a pointer.
    ///
    /// It is the caller's responsibility to ensure that the address is valid in the current address space.
    pub inline fn toPtr(virtual_address: VirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(virtual_address.value);
    }

    pub inline fn toRange(virtual_address: VirtualAddress, size: core.Size) VirtualRange {
        return .{ .address = virtual_address, .size = size };
    }

    pub inline fn isAligned(virtual_address: VirtualAddress, alignment: core.Size) bool {
        return std.mem.isAligned(virtual_address.value, alignment.value);
    }

    /// Returns the difference between two addresses.
    ///
    /// `virtual_address` must be greater than or equal to `other`.
    pub fn subtract(virtual_address: VirtualAddress, other: VirtualAddress) core.Size {
        if (core.is_debug) std.debug.assert(virtual_address.greaterThanOrEqual(other));
        return .from(virtual_address.value - other.value, .byte);
    }

    /// Returns the address rounded up to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForward(virtual_address: VirtualAddress, alignment: core.Size) VirtualAddress {
        return .{ .value = std.mem.alignForward(u64, virtual_address.value, alignment.value) };
    }

    /// Rounds up the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForwardInPlace(virtual_address: *VirtualAddress, alignment: core.Size) void {
        virtual_address.value = std.mem.alignForward(u64, virtual_address.value, alignment.value);
    }

    /// Returns the address rounded down to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackward(virtual_address: VirtualAddress, alignment: core.Size) VirtualAddress {
        return .{ .value = std.mem.alignBackward(u64, virtual_address.value, alignment.value) };
    }

    /// Rounds down the address to the nearest multiple of the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackwardInPlace(virtual_address: *VirtualAddress, alignment: core.Size) void {
        virtual_address.value = std.mem.alignBackward(u64, virtual_address.value, alignment.value);
    }

    pub fn moveForward(virtual_address: VirtualAddress, size: core.Size) VirtualAddress {
        return .{ .value = virtual_address.value + size.value };
    }

    pub fn moveForwardInPlace(virtual_address: *VirtualAddress, size: core.Size) void {
        virtual_address.value += size.value;
    }

    pub fn moveBackward(virtual_address: VirtualAddress, size: core.Size) VirtualAddress {
        return .{ .value = virtual_address.value - size.value };
    }

    pub fn moveBackwardInPlace(virtual_address: *VirtualAddress, size: core.Size) void {
        virtual_address.value -= size.value;
    }

    pub inline fn equal(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value == other.value;
    }

    pub inline fn notEqual(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value != other.value;
    }

    pub inline fn lessThan(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value < other.value;
    }

    pub inline fn lessThanOrEqual(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value <= other.value;
    }

    pub inline fn greaterThan(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value > other.value;
    }

    pub inline fn greaterThanOrEqual(virtual_address: VirtualAddress, other: VirtualAddress) bool {
        return virtual_address.value >= other.value;
    }

    pub fn compare(virtual_address: VirtualAddress, other: VirtualAddress) std.math.Order {
        if (virtual_address.lessThan(other)) return .lt;
        if (virtual_address.greaterThan(other)) return .gt;
        return .eq;
    }

    pub inline fn format(virtual_address: VirtualAddress, writer: *std.Io.Writer) !void {
        try writer.print("VirtualAddress{{ 0x{x:0>16} }}", .{virtual_address.value});
    }

    comptime {
        core.testing.expectSize(VirtualAddress, @sizeOf(u64));
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
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn endBound(physical_range: PhysicalRange) PhysicalAddress {
        return physical_range.address.moveForward(physical_range.size);
    }

    /// Returns the last address in this range.
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn last(physical_range: PhysicalRange) PhysicalAddress {
        if (physical_range.size.value == 0) return physical_range.address;
        return physical_range.address.moveForward(physical_range.size.subtract(core.Size.one));
    }

    pub fn equal(physical_range: PhysicalRange, other: PhysicalRange) bool {
        return physical_range.address.equal(other.address) and physical_range.size.equal(other.size);
    }

    pub fn moveForward(physical_range: PhysicalRange, size: core.Size) PhysicalRange {
        return .{
            .address = physical_range.address.moveForward(size),
            .size = physical_range.size,
        };
    }

    pub fn moveForwardInPlace(physical_range: *PhysicalRange, size: core.Size) void {
        physical_range.address.moveForwardInPlace(size);
    }

    pub fn moveBackward(physical_range: PhysicalRange, size: core.Size) PhysicalRange {
        return .{
            .address = physical_range.address.moveBackward(size),
            .size = physical_range.size,
        };
    }

    pub fn moveBackwardInPlace(physical_range: *PhysicalRange, size: core.Size) void {
        physical_range.address.moveBackwardInPlace(size);
    }

    pub fn fullyContainsRange(physical_range: PhysicalRange, other: PhysicalRange) bool {
        if (physical_range.address.greaterThan(other.address)) return false;
        if (physical_range.endBound().lessThan(other.endBound())) return false;

        return true;
    }

    pub fn containsAddressOrder(physical_range: PhysicalRange, address: PhysicalAddress) std.math.Order {
        if (physical_range.address.greaterThan(address)) return .lt;
        if (physical_range.endBound().lessThanOrEqual(address)) return .gt;
        return .eq;
    }

    pub fn containsAddress(physical_range: PhysicalRange, address: PhysicalAddress) bool {
        return physical_range.containsAddressOrder(address) == .eq;
    }

    pub inline fn format(
        value: PhysicalRange,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("PhysicalRange{{ 0x{x:0>16} - 0x{x:0>16} - {f} }}", .{
            value.address.value,
            value.last().value,
            value.size,
        });
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
    pub inline fn toByteSlice(virtual_range: VirtualRange) []u8 {
        return virtual_range.address.toPtr([*]u8)[0..virtual_range.size.value];
    }

    pub inline fn fromAddr(address: VirtualAddress, size: core.Size) VirtualRange {
        return .{
            .address = address,
            .size = size,
        };
    }

    /// Returns a virtual range between the given addresses exclusive of the end address.
    pub fn between(start: VirtualAddress, end: VirtualAddress) VirtualRange {
        if (core.is_debug) std.debug.assert(start.lessThan(end));

        return .{
            .address = start,
            .size = .from(end.value - start.value, .byte),
        };
    }

    /// Returns the address of the first byte __after__ the range.
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn endBound(virtual_range: VirtualRange) VirtualAddress {
        return virtual_range.address.moveForward(virtual_range.size);
    }

    /// Returns the last address in this range.
    ///
    /// If the ranges size is zero, returns the start address of the range.
    pub fn last(virtual_range: VirtualRange) VirtualAddress {
        if (virtual_range.size.value == 0) return virtual_range.address;
        return virtual_range.address.moveForward(virtual_range.size.subtract(core.Size.one));
    }

    pub fn equal(virtual_range: VirtualRange, other: VirtualRange) bool {
        return virtual_range.address.equal(other.address) and virtual_range.size.equal(other.size);
    }

    pub fn moveForward(virtual_range: VirtualRange, size: core.Size) VirtualRange {
        return .{
            .address = virtual_range.address.moveForward(size),
            .size = virtual_range.size,
        };
    }

    pub fn moveForwardInPlace(virtual_range: *VirtualRange, size: core.Size) void {
        virtual_range.address.moveForwardInPlace(size);
    }

    pub fn moveBackward(virtual_range: VirtualRange, size: core.Size) VirtualRange {
        return .{
            .address = virtual_range.address.moveBackward(size),
            .size = virtual_range.size,
        };
    }

    pub fn moveBackwardInPlace(virtual_range: *VirtualRange, size: core.Size) void {
        virtual_range.address.moveBackwardInPlace(size);
    }

    pub fn anyOverlap(virtual_range: VirtualRange, other: VirtualRange) bool {
        if (virtual_range.address.lessThan(other.endBound()) and
            virtual_range.endBound().greaterThan(other.address))
            return true;

        return false;
    }

    pub fn fullyContainsRange(virtual_range: VirtualRange, other: VirtualRange) bool {
        if (virtual_range.address.greaterThan(other.address)) return false;
        if (virtual_range.endBound().lessThan(other.endBound())) return false;

        return true;
    }

    pub fn compareAddressOrder(virtual_range: VirtualRange, address: VirtualAddress) std.math.Order {
        if (virtual_range.address.greaterThan(address)) return .lt;
        if (virtual_range.endBound().lessThanOrEqual(address)) return .gt;
        return .eq;
    }

    pub fn containsAddress(virtual_range: VirtualRange, address: VirtualAddress) bool {
        return virtual_range.compareAddressOrder(address) == .eq;
    }

    pub inline fn format(
        value: VirtualRange,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("VirtualRange{{ 0x{x:0>16} - 0x{x:0>16} - {f} }}", .{
            value.address.value,
            value.last().value,
            value.size,
        });
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
