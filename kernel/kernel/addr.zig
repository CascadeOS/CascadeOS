// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// This file is really misses `usingnamespace`.
// The "mixins" in this file have signatures where they are exposed only to help ZLS realize they are "methods".

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const kernel = @import("kernel");
const Task = kernel.Task;

pub const Virtual = extern union {
    kernel: Kernel,
    user: User,
    value: usize,

    pub const zero: Virtual = .from(0);
    pub const undefined_address: Virtual = .from(0xAAAAAAAAAAAAAAAA);

    pub inline fn from(value: usize) Virtual {
        return .{ .value = value };
    }

    pub const Type = enum {
        kernel,
        user,
        invalid,
    };

    pub fn getType(address: Virtual) Type {
        if (arch.paging.higher_half_range.containsAddress(address))
            return .kernel
        else if (arch.paging.lower_half_range.containsAddress(address))
            return .user
        else {
            @branchHint(.cold);
            return .invalid;
        }
    }

    pub inline fn toKernel(address: Virtual) Kernel {
        if (core.is_debug) std.debug.assert(arch.paging.higher_half_range.containsAddress(address));
        return address.kernel;
    }

    pub inline fn toUser(address: Virtual) User {
        if (core.is_debug) std.debug.assert(arch.paging.lower_half_range.containsAddress(address));
        return address.user;
    }

    pub const aligned: fn (@This(), std.mem.Alignment) callconv(.@"inline") bool = AddressImpl(@This()).aligned;
    pub const alignForward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignForward;
    pub const alignForwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignForwardInPlace;
    pub const alignBackward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignBackward;
    pub const alignBackwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignBackwardInPlace;

    pub const moveForward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveForward;
    pub const moveForwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveForwardInPlace;
    pub const moveBackward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveBackward;
    pub const moveBackwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveBackwardInPlace;

    pub const equal: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).equal;
    pub const lessThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThan;
    pub const lessThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThanOrEqual;
    pub const greaterThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThan;
    pub const greaterThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThanOrEqual;

    pub const format = addressFormat(@This(), "Virtual");

    /// Returns the size from  `address` to `other`.
    ///
    /// `address + address.difference(other) == other`
    ///
    /// **REQUIREMENTS**:
    /// - `other` must be greater than or equal to `address`
    pub const difference: fn (@This(), @This()) callconv(.@"inline") core.Size = AddressImpl(@This()).difference;

    pub const Kernel = extern struct {
        value: usize,

        pub inline fn from(value: usize) Kernel {
            return .{ .value = value };
        }

        pub inline fn ptr(address: Kernel, comptime PtrT: type) PtrT {
            return @ptrFromInt(address.value);
        }

        pub inline fn toVirtual(address: Kernel) Virtual {
            return .{ .kernel = address };
        }

        /// Shifts an address to account for any applied virtual offset applied to the kernel (KASLR).
        ///
        /// The resulting address might no longer be a vaild kernel address, use `getType` to check.
        pub inline fn applyKernelOffset(address: Kernel) Virtual {
            return address.moveBackward(kernel.mem.globals.kernel_virtual_offset).toVirtual();
        }

        pub const aligned: fn (@This(), std.mem.Alignment) callconv(.@"inline") bool = AddressImpl(@This()).aligned;
        pub const alignForward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignForward;
        pub const alignForwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignForwardInPlace;
        pub const alignBackward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignBackward;
        pub const alignBackwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignBackwardInPlace;

        pub const moveForward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveForward;
        pub const moveForwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveForwardInPlace;
        pub const moveBackward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveBackward;
        pub const moveBackwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveBackwardInPlace;

        pub const equal: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).equal;
        pub const lessThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThan;
        pub const lessThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThanOrEqual;
        pub const greaterThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThan;
        pub const greaterThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThanOrEqual;

        /// Returns the size from  `address` to `other`.
        ///
        /// `address + address.difference(other) == other`
        ///
        /// **REQUIREMENTS**:
        /// - `other` must be greater than or equal to `address`
        pub const difference: fn (@This(), @This()) callconv(.@"inline") core.Size = AddressImpl(@This()).difference;

        pub const format = addressFormat(@This(), "Virtual.Kernel");

        comptime {
            core.testing.expectSize(Kernel, .of(usize));
        }
    };

    pub const User = extern struct {
        value: usize,

        pub const zero: User = .{ .value = 0 };

        pub inline fn from(value: usize) User {
            return .{ .value = value };
        }

        pub inline fn ptr(address: User, comptime PtrT: type) PtrT {
            return @ptrFromInt(address.value);
        }

        pub inline fn toVirtual(address: User) Virtual {
            return .{ .user = address };
        }

        pub const aligned: fn (@This(), std.mem.Alignment) callconv(.@"inline") bool = AddressImpl(@This()).aligned;
        pub const alignForward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignForward;
        pub const alignForwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignForwardInPlace;
        pub const alignBackward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignBackward;
        pub const alignBackwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignBackwardInPlace;

        pub const moveForward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveForward;
        pub const moveForwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveForwardInPlace;
        pub const moveBackward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveBackward;
        pub const moveBackwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveBackwardInPlace;

        pub const equal: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).equal;
        pub const lessThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThan;
        pub const lessThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThanOrEqual;
        pub const greaterThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThan;
        pub const greaterThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThanOrEqual;

        /// Returns the size from  `address` to `other`.
        ///
        /// `address + address.difference(other) == other`
        ///
        /// **REQUIREMENTS**:
        /// - `other` must be greater than or equal to `address`
        pub const difference: fn (@This(), @This()) callconv(.@"inline") core.Size = AddressImpl(@This()).difference;

        pub const format = addressFormat(@This(), "Virtual.User");

        comptime {
            core.testing.expectSize(User, .of(usize));
        }
    };

    pub const Range = struct {
        address: Virtual,
        size: core.Size,

        pub inline fn from(address: Virtual, size: core.Size) Range {
            return .{ .address = address, .size = size };
        }

        pub fn getType(range: Range) Virtual.Type {
            if (arch.paging.higher_half_range.fullyContains(range))
                return .kernel
            else if (arch.paging.lower_half_range.fullyContains(range))
                return .user
            else {
                @branchHint(.cold);
                return .invalid;
            }
        }

        pub inline fn toKernel(range: Range) Range.Kernel {
            return .from(range.address.toKernel(), range.size);
        }

        pub inline fn toUser(range: Range) Range.User {
            return .from(range.address.toUser(), range.size);
        }

        /// Returns the last address in this range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub const last: fn (@This()) Virtual = RangeImpl(@This(), Virtual).last;

        /// Returns the address of the first byte after the range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub const after: fn (@This()) callconv(.@"inline") Virtual = RangeImpl(@This(), Virtual).after;

        pub const anyOverlap: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual).anyOverlap;
        pub const fullyContains: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual).fullyContains;
        pub const containsAddress: fn (@This(), Virtual) bool = RangeImpl(@This(), Virtual).containsAddress;
        pub const containsAddressOrder: fn (@This(), Virtual) std.math.Order = RangeImpl(@This(), Virtual).containsAddressOrder;

        pub const format = rangeFormat(@This(), "Virtual.Range");

        pub const Kernel = struct {
            address: Virtual.Kernel,
            size: core.Size,

            pub inline fn from(address: Virtual.Kernel, size: core.Size) Range.Kernel {
                return .{ .address = address, .size = size };
            }

            pub inline fn fromSlice(comptime T: type, slice: []const T) Range.Kernel {
                return .from(
                    .from(@intFromPtr(slice.ptr)),
                    core.Size.of(T).multiplyScalar(slice.len),
                );
            }

            pub inline fn toVirtualRange(range: Range.Kernel) Virtual.Range {
                return .from(.from(range.address.value), range.size);
            }

            pub inline fn byteSlice(range: Range.Kernel) []u8 {
                return range.address.ptr([*]u8)[0..range.size.value];
            }

            /// Returns the last address in this range.
            ///
            /// If the range's size is zero, returns the start address of the range.
            pub const last: fn (@This()) Virtual.Kernel = RangeImpl(@This(), Virtual.Kernel).last;

            /// Returns the address of the first byte after the range.
            ///
            /// If the range's size is zero, returns the start address of the range.
            pub const after: fn (@This()) callconv(.@"inline") Virtual.Kernel = RangeImpl(@This(), Virtual.Kernel).after;

            pub const anyOverlap: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual.Kernel).anyOverlap;
            pub const fullyContains: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual.Kernel).fullyContains;
            pub const containsAddress: fn (@This(), Virtual.Kernel) bool = RangeImpl(@This(), Virtual.Kernel).containsAddress;
            pub const containsAddressOrder: fn (@This(), Virtual.Kernel) std.math.Order = RangeImpl(@This(), Virtual.Kernel).containsAddressOrder;

            pub const format = rangeFormat(@This(), "Virtual.Range.Kernel");
        };

        pub const User = struct {
            address: Virtual.User,
            size: core.Size,

            pub fn from(address: Virtual.User, size: core.Size) Range.User {
                return .{ .address = address, .size = size };
            }

            pub inline fn toVirtualRange(range: Range.User) Virtual.Range {
                return .from(.from(range.address.value), range.size);
            }

            pub inline fn byteSlice(range: Range.User) []u8 {
                if (core.is_debug) std.debug.assert(Task.Current.get().task.enable_access_to_user_memory_count != 0);
                return range.address.ptr([*]u8)[0..range.size.value];
            }

            /// Returns the last address in this range.
            ///
            /// If the range's size is zero, returns the start address of the range.
            pub const last: fn (@This()) Virtual.User = RangeImpl(@This(), Virtual.User).last;

            /// Returns the address of the first byte after the range.
            ///
            /// If the range's size is zero, returns the start address of the range.
            pub const after: fn (@This()) callconv(.@"inline") Virtual.User = RangeImpl(@This(), Virtual.User).after;

            pub const anyOverlap: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual.User).anyOverlap;
            pub const fullyContains: fn (@This(), @This()) bool = RangeImpl(@This(), Virtual.User).fullyContains;
            pub const containsAddress: fn (@This(), Virtual.User) bool = RangeImpl(@This(), Virtual.User).containsAddress;
            pub const containsAddressOrder: fn (@This(), Virtual.User) std.math.Order = RangeImpl(@This(), Virtual.User).containsAddressOrder;

            pub const format = rangeFormat(@This(), "Virtual.Range.User");
        };
    };
};

pub const Physical = extern struct {
    value: usize,

    pub const zero: Physical = .from(0);

    pub inline fn from(value: usize) Physical {
        return .{ .value = value };
    }

    /// Returns the physical address of this virtual address if it is in the direct map.
    pub fn fromDirectMap(address: Virtual.Kernel) error{AddressNotInDirectMap}!Physical {
        if (!kernel.mem.globals.direct_map.containsAddress(address)) {
            @branchHint(.cold);
            return error.AddressNotInDirectMap;
        }
        return .{ .value = address.value - kernel.mem.globals.direct_map.address.value };
    }

    /// Returns the virtual address corresponding to this physical address in the direct map.
    pub fn toDirectMap(physical_address: Physical) Virtual.Kernel {
        return .{ .value = physical_address.value + kernel.mem.globals.direct_map.address.value };
    }

    pub const aligned: fn (@This(), std.mem.Alignment) callconv(.@"inline") bool = AddressImpl(@This()).aligned;
    pub const alignForward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignForward;
    pub const alignForwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignForwardInPlace;
    pub const alignBackward: fn (@This(), std.mem.Alignment) callconv(.@"inline") @This() = AddressImpl(@This()).alignBackward;
    pub const alignBackwardInPlace: fn (*@This(), std.mem.Alignment) callconv(.@"inline") void = AddressImpl(@This()).alignBackwardInPlace;

    pub const moveForward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveForward;
    pub const moveForwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveForwardInPlace;
    pub const moveBackward: fn (@This(), core.Size) callconv(.@"inline") @This() = AddressImpl(@This()).moveBackward;
    pub const moveBackwardInPlace: fn (*@This(), core.Size) callconv(.@"inline") void = AddressImpl(@This()).moveBackwardInPlace;

    pub const equal: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).equal;
    pub const lessThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThan;
    pub const lessThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).lessThanOrEqual;
    pub const greaterThan: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThan;
    pub const greaterThanOrEqual: fn (@This(), @This()) callconv(.@"inline") bool = AddressImpl(@This()).greaterThanOrEqual;

    /// Returns the size from  `address` to `other`.
    ///
    /// `address + address.difference(other) == other`
    ///
    /// **REQUIREMENTS**:
    /// - `other` must be greater than or equal to `address`
    pub const difference: fn (@This(), @This()) callconv(.@"inline") core.Size = AddressImpl(@This()).difference;

    pub const format = addressFormat(@This(), "Physical");

    comptime {
        core.testing.expectSize(Physical, .of(usize));
    }

    pub const Range = struct {
        address: Physical,
        size: core.Size,

        pub inline fn from(address: Physical, size: core.Size) Range {
            return .{ .address = address, .size = size };
        }

        /// Returns a virtual range corresponding to this physical range in the direct map.
        pub fn toDirectMap(range: Range) Virtual.Range.Kernel {
            return .{
                .address = range.address.toDirectMap(),
                .size = range.size,
            };
        }

        // Returns the last address in this range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub const last: fn (@This()) Physical = RangeImpl(@This(), Physical).last;

        /// Returns the address of the first byte after the range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        pub const after: fn (@This()) callconv(.@"inline") Physical = RangeImpl(@This(), Physical).after;

        pub const anyOverlap: fn (@This(), @This()) bool = RangeImpl(@This(), Physical).anyOverlap;
        pub const fullyContains: fn (@This(), @This()) bool = RangeImpl(@This(), Physical).fullyContains;
        pub const containsAddress: fn (@This(), Physical) bool = RangeImpl(@This(), Physical).containsAddress;
        pub const containsAddressOrder: fn (@This(), Physical) std.math.Order = RangeImpl(@This(), Physical).containsAddressOrder;

        pub const format = rangeFormat(@This(), "Physical.Range");
    };
};

fn AddressImpl(comptime Address: type) type {
    return struct {
        inline fn aligned(address: Address, alignment: std.mem.Alignment) bool {
            return alignment.check(address.value);
        }

        inline fn alignForward(address: Address, alignment: std.mem.Alignment) Address {
            return .from(alignment.forward(address.value));
        }

        inline fn alignForwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.value = alignment.forward(address.value);
        }

        inline fn alignBackward(address: Address, alignment: std.mem.Alignment) Address {
            return .from(alignment.backward(address.value));
        }

        inline fn alignBackwardInPlace(address: *Address, alignment: std.mem.Alignment) void {
            address.value = alignment.backward(address.value);
        }

        inline fn moveForward(address: Address, size: core.Size) Address {
            return .from(address.value + size.value);
        }

        inline fn moveForwardInPlace(address: *Address, size: core.Size) void {
            address.value += size.value;
        }

        inline fn moveBackward(address: Address, size: core.Size) Address {
            return .from(address.value - size.value);
        }

        inline fn moveBackwardInPlace(address: *Address, size: core.Size) void {
            address.value -= size.value;
        }

        inline fn equal(address: Address, other: Address) bool {
            return address.value == other.value;
        }

        inline fn lessThan(address: Address, other: Address) bool {
            return address.value < other.value;
        }

        inline fn lessThanOrEqual(address: Address, other: Address) bool {
            return address.value <= other.value;
        }

        inline fn greaterThan(address: Address, other: Address) bool {
            return address.value > other.value;
        }

        inline fn greaterThanOrEqual(address: Address, other: Address) bool {
            return address.value >= other.value;
        }

        /// Returns the size from  `address` to `other`.
        ///
        /// `address + address.difference(other) == other`
        ///
        /// **REQUIREMENTS**:
        /// - `other` must be greater than or equal to `address`
        inline fn difference(address: Address, other: Address) core.Size {
            if (core.is_debug) std.debug.assert(greaterThanOrEqual(other, address));
            return .from(other.value - address.value, .byte);
        }
    };
}

fn addressFormat(comptime Address: type, comptime name: []const u8) fn (Address, *std.Io.Writer) std.Io.Writer.Error!void {
    return struct {
        pub fn format(address: Address, writer: *std.Io.Writer) !void {
            try writer.writeAll(comptime name ++ "{ 0x");
            try writer.printInt(
                address.value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" }");
        }
    }.format;
}

fn RangeImpl(comptime Range: type, comptime Address: type) type {
    return struct {
        /// Returns the last address in this range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        fn last(range: Range) Address {
            if (range.size.equal(.zero)) {
                @branchHint(.unlikely);
                return range.address;
            }
            return range.address.moveForward(range.size.subtract(.one));
        }

        /// Returns the address of the first byte after the range.
        ///
        /// If the range's size is zero, returns the start address of the range.
        inline fn after(range: Range) Address {
            return range.address.moveForward(range.size);
        }

        fn anyOverlap(range: Range, other: Range) bool {
            return range.address.lessThanOrEqual(last(other)) and last(range).greaterThanOrEqual(other.address);
        }

        fn fullyContains(range: Range, other: Range) bool {
            return range.address.lessThanOrEqual(other.address) and last(range).greaterThanOrEqual(last(other));
        }

        fn containsAddress(range: Range, address: Address) bool {
            return address.greaterThanOrEqual(range.address) and address.lessThanOrEqual(last(range));
        }

        fn containsAddressOrder(range: Range, address: Address) std.math.Order {
            if (range.address.greaterThan(address)) return .lt;
            if (last(range).lessThan(address)) return .gt;
            return .eq;
        }
    };
}

fn rangeFormat(comptime Range: type, comptime name: []const u8) fn (Range, *std.Io.Writer) std.Io.Writer.Error!void {
    return struct {
        fn format(range: Range, writer: *std.Io.Writer) !void {
            try writer.writeAll(comptime name ++ "{ 0x");
            try writer.printInt(
                range.address.value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" - 0x");
            try writer.printInt(
                range.last().value,
                16,
                .lower,
                .{
                    .fill = '0',
                    .width = 16,
                },
            );
            try writer.writeAll(" - ");
            try range.size.format(writer);
            try writer.writeAll(" }");
        }
    }.format;
}
