// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// This file is really missing `usingnamespace`.
// The "mixins" in this file have signatures only to help ZLS realize they are "methods".

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;

pub const VirtualAddress = extern union {
    kernel: KernelVirtualAddress,
    user: UserVirtualAddress,
    value: usize,

    pub const zero: VirtualAddress = .from(0);
    pub const undefined_address: VirtualAddress = .from(0xAAAAAAAAAAAAAAAA);

    pub const Type = enum {
        kernel,
        user,
        invalid,
    };

    pub fn getType(address: VirtualAddress) Type {
        if (arch.paging.kernel_memory_range.containsAddress(address))
            return .kernel
        else if (arch.user.user_memory_range.containsAddress(address))
            return .user
        else {
            @branchHint(.cold);
            return .invalid;
        }
    }

    pub inline fn toKernel(address: VirtualAddress) KernelVirtualAddress {
        if (core.is_debug) std.debug.assert(arch.paging.kernel_memory_range.containsAddress(address));
        return address.kernel;
    }

    pub inline fn toUser(address: VirtualAddress) UserVirtualAddress {
        if (core.is_debug) std.debug.assert(arch.user.user_memory_range.containsAddress(address));
        return address.user;
    }

    pub const from: fn (value: usize) callconv(.@"inline") @This() = Mixin.from;
    pub const aligned: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") bool = Mixin.aligned;
    pub const alignForward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignForward;
    pub const alignForwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignForwardInPlace;
    pub const alignBackward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignBackward;
    pub const alignBackwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignBackwardInPlace;
    pub const moveForward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveForward;
    pub const moveForwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveForwardInPlace;
    pub const moveBackward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveBackward;
    pub const moveBackwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveBackwardInPlace;
    pub const equal: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.equal;
    pub const lessThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThan;
    pub const lessThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThanOrEqual;
    pub const greaterThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThan;
    pub const greaterThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThanOrEqual;
    pub const difference: fn (address: @This(), other: @This()) callconv(.@"inline") core.Size = Mixin.difference;
    pub const format: fn (address: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Mixin = AddressMixin(@This());
};

pub const KernelVirtualAddress = extern struct {
    value: usize,

    pub inline fn ptr(address: KernelVirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(address.value);
    }

    pub inline fn toVirtual(address: KernelVirtualAddress) VirtualAddress {
        return .{ .kernel = address };
    }

    /// Shifts an address to account for any applied virtual offset applied to the kernel (KASLR).
    ///
    /// The resulting address might no longer be a vaild kernel address, use `getType` to check.
    pub inline fn applyKernelOffset(address: KernelVirtualAddress) VirtualAddress {
        return address.moveBackward(cascade.mem.globals.kernel_virtual_offset).toVirtual();
    }

    pub const from: fn (value: usize) callconv(.@"inline") @This() = Mixin.from;
    pub const aligned: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") bool = Mixin.aligned;
    pub const alignForward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignForward;
    pub const alignForwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignForwardInPlace;
    pub const alignBackward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignBackward;
    pub const alignBackwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignBackwardInPlace;
    pub const moveForward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveForward;
    pub const moveForwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveForwardInPlace;
    pub const moveBackward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveBackward;
    pub const moveBackwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveBackwardInPlace;
    pub const equal: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.equal;
    pub const lessThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThan;
    pub const lessThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThanOrEqual;
    pub const greaterThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThan;
    pub const greaterThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThanOrEqual;
    pub const difference: fn (address: @This(), other: @This()) callconv(.@"inline") core.Size = Mixin.difference;
    pub const format: fn (address: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Mixin = AddressMixin(@This());

    comptime {
        core.testing.expectSize(KernelVirtualAddress, .of(usize));
    }
};

pub const UserVirtualAddress = extern struct {
    value: usize,

    pub const zero: UserVirtualAddress = .{ .value = 0 };

    pub inline fn ptr(address: UserVirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(address.value);
    }

    pub inline fn toVirtual(address: UserVirtualAddress) VirtualAddress {
        return .{ .user = address };
    }

    pub const from: fn (value: usize) callconv(.@"inline") @This() = Mixin.from;
    pub const aligned: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") bool = Mixin.aligned;
    pub const alignForward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignForward;
    pub const alignForwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignForwardInPlace;
    pub const alignBackward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignBackward;
    pub const alignBackwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignBackwardInPlace;
    pub const moveForward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveForward;
    pub const moveForwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveForwardInPlace;
    pub const moveBackward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveBackward;
    pub const moveBackwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveBackwardInPlace;
    pub const equal: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.equal;
    pub const lessThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThan;
    pub const lessThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThanOrEqual;
    pub const greaterThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThan;
    pub const greaterThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThanOrEqual;
    pub const difference: fn (address: @This(), other: @This()) callconv(.@"inline") core.Size = Mixin.difference;
    pub const format: fn (address: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Mixin = AddressMixin(@This());

    comptime {
        core.testing.expectSize(UserVirtualAddress, .of(usize));
    }
};

pub const PhysicalAddress = extern struct {
    value: usize,

    pub const zero: PhysicalAddress = .from(0);

    /// Returns the physical address of this virtual address if it is in the direct map.
    pub fn fromDirectMap(address: KernelVirtualAddress) error{AddressNotInDirectMap}!PhysicalAddress {
        if (!cascade.mem.globals.direct_map.containsAddress(address)) {
            @branchHint(.cold);
            return error.AddressNotInDirectMap;
        }
        return .{ .value = address.value - cascade.mem.globals.direct_map.address.value };
    }

    /// Returns the virtual address corresponding to this physical address in the direct map.
    pub fn toDirectMap(physical_address: PhysicalAddress) KernelVirtualAddress {
        return .{ .value = physical_address.value + cascade.mem.globals.direct_map.address.value };
    }

    pub const from: fn (value: usize) callconv(.@"inline") @This() = Mixin.from;
    pub const aligned: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") bool = Mixin.aligned;
    pub const alignForward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignForward;
    pub const alignForwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignForwardInPlace;
    pub const alignBackward: fn (address: @This(), alignment: std.mem.Alignment) callconv(.@"inline") @This() = Mixin.alignBackward;
    pub const alignBackwardInPlace: fn (address: *@This(), alignment: std.mem.Alignment) callconv(.@"inline") void = Mixin.alignBackwardInPlace;
    pub const moveForward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveForward;
    pub const moveForwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveForwardInPlace;
    pub const moveBackward: fn (address: @This(), size: core.Size) callconv(.@"inline") @This() = Mixin.moveBackward;
    pub const moveBackwardInPlace: fn (address: *@This(), size: core.Size) callconv(.@"inline") void = Mixin.moveBackwardInPlace;
    pub const equal: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.equal;
    pub const lessThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThan;
    pub const lessThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.lessThanOrEqual;
    pub const greaterThan: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThan;
    pub const greaterThanOrEqual: fn (address: @This(), other: @This()) callconv(.@"inline") bool = Mixin.greaterThanOrEqual;
    pub const difference: fn (address: @This(), other: @This()) callconv(.@"inline") core.Size = Mixin.difference;
    pub const format: fn (address: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Mixin = AddressMixin(@This());

    comptime {
        core.testing.expectSize(PhysicalAddress, .of(usize));
    }
};

pub const VirtualRange = struct {
    address: Address,
    size: core.Size,

    pub fn getType(range: VirtualRange) VirtualAddress.Type {
        if (arch.paging.kernel_memory_range.fullyContains(range))
            return .kernel
        else if (arch.user.user_memory_range.fullyContains(range))
            return .user
        else {
            @branchHint(.cold);
            return .invalid;
        }
    }

    pub inline fn toKernel(range: VirtualRange) KernelVirtualRange {
        return .from(range.address.toKernel(), range.size);
    }

    pub inline fn toUser(range: VirtualRange) UserVirtualRange {
        return .from(range.address.toUser(), range.size);
    }

    pub const from: fn (address: Address, size: core.Size) callconv(.@"inline") @This() = Mixin.from;
    pub const last: fn (range: @This()) Address = Mixin.last;
    pub const after: fn (range: @This()) callconv(.@"inline") Address = Mixin.after;
    pub const anyOverlap: fn (range: @This(), other: @This()) bool = Mixin.anyOverlap;
    pub const fullyContains: fn (range: @This(), other: @This()) bool = Mixin.fullyContains;
    pub const containsAddress: fn (range: @This(), address: Address) bool = Mixin.containsAddress;
    pub const containsAddressOrder: fn (range: @This(), address: Address) std.math.Order = Mixin.containsAddressOrder;
    pub const format: fn (range: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Address = VirtualAddress;
    const Mixin = RangeMixin(@This());
};

pub const KernelVirtualRange = struct {
    address: Address,
    size: core.Size,

    pub inline fn fromSlice(comptime T: type, slice: []const T) KernelVirtualRange {
        return .from(
            .from(@intFromPtr(slice.ptr)),
            core.Size.of(T).multiplyScalar(slice.len),
        );
    }

    pub inline fn toVirtualRange(range: KernelVirtualRange) VirtualRange {
        return .from(.from(range.address.value), range.size);
    }

    pub inline fn byteSlice(range: KernelVirtualRange) []u8 {
        return range.address.ptr([*]u8)[0..range.size.value];
    }

    pub const from: fn (address: Address, size: core.Size) callconv(.@"inline") @This() = Mixin.from;
    pub const last: fn (range: @This()) Address = Mixin.last;
    pub const after: fn (range: @This()) callconv(.@"inline") Address = Mixin.after;
    pub const anyOverlap: fn (range: @This(), other: @This()) bool = Mixin.anyOverlap;
    pub const fullyContains: fn (range: @This(), other: @This()) bool = Mixin.fullyContains;
    pub const containsAddress: fn (range: @This(), address: Address) bool = Mixin.containsAddress;
    pub const containsAddressOrder: fn (range: @This(), address: Address) std.math.Order = Mixin.containsAddressOrder;
    pub const format: fn (range: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Address = KernelVirtualAddress;
    const Mixin = RangeMixin(@This());
};

pub const UserVirtualRange = struct {
    address: Address,
    size: core.Size,

    pub inline fn toVirtualRange(range: UserVirtualRange) VirtualRange {
        return .from(.from(range.address.value), range.size);
    }

    pub inline fn byteSlice(range: UserVirtualRange) []u8 {
        if (core.is_debug) std.debug.assert(Task.Current.get().task.enable_access_to_user_memory_count != 0);
        return range.address.ptr([*]u8)[0..range.size.value];
    }

    pub const from: fn (address: Address, size: core.Size) callconv(.@"inline") @This() = Mixin.from;
    pub const last: fn (range: @This()) Address = Mixin.last;
    pub const after: fn (range: @This()) callconv(.@"inline") Address = Mixin.after;
    pub const anyOverlap: fn (range: @This(), other: @This()) bool = Mixin.anyOverlap;
    pub const fullyContains: fn (range: @This(), other: @This()) bool = Mixin.fullyContains;
    pub const containsAddress: fn (range: @This(), address: Address) bool = Mixin.containsAddress;
    pub const containsAddressOrder: fn (range: @This(), address: Address) std.math.Order = Mixin.containsAddressOrder;
    pub const format: fn (range: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Address = UserVirtualAddress;
    const Mixin = RangeMixin(@This());
};

pub const PhysicalRange = struct {
    address: Address,
    size: core.Size,

    /// Returns a virtual range corresponding to this physical range in the direct map.
    pub fn toDirectMap(range: PhysicalRange) VirtualRange {
        return .{
            .address = range.address.toDirectMap(),
            .size = range.size,
        };
    }

    pub const from: fn (address: Address, size: core.Size) callconv(.@"inline") @This() = Mixin.from;
    pub const last: fn (range: @This()) Address = Mixin.last;
    pub const after: fn (range: @This()) callconv(.@"inline") Address = Mixin.after;
    pub const anyOverlap: fn (range: @This(), other: @This()) bool = Mixin.anyOverlap;
    pub const fullyContains: fn (range: @This(), other: @This()) bool = Mixin.fullyContains;
    pub const containsAddress: fn (range: @This(), address: Address) bool = Mixin.containsAddress;
    pub const containsAddressOrder: fn (range: @This(), address: Address) std.math.Order = Mixin.containsAddressOrder;
    pub const format: fn (range: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void = Mixin.format;

    const Address = PhysicalAddress;
    const Mixin = RangeMixin(@This());
};

fn AddressMixin(comptime Address: type) type {
    return struct {
        inline fn from(value: usize) Address {
            return .{ .value = value };
        }

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

        fn format(address: Address, writer: *std.Io.Writer) !void {
            const name = comptime switch (Address) {
                VirtualAddress => "VirtualAddress",
                KernelVirtualAddress => "KernelVirtualAddress",
                UserVirtualAddress => "UserVirtualAddress",
                PhysicalAddress => "PhysicalAddress",
                else => unreachable,
            };

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
    };
}

fn RangeMixin(comptime Range: type) type {
    return struct {
        inline fn from(address: Address, size: core.Size) Range {
            return .{ .address = address, .size = size };
        }

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

        fn format(range: Range, writer: *std.Io.Writer) !void {
            const name = comptime switch (Range) {
                VirtualRange => "VirtualRange",
                KernelVirtualRange => "KernelVirtualRange",
                UserVirtualRange => "UserVirtualRange",
                PhysicalRange => "PhysicalRange",
                else => unreachable,
            };

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

        const Address = switch (Range) {
            VirtualRange => VirtualAddress,
            KernelVirtualRange => KernelVirtualAddress,
            UserVirtualRange => UserVirtualAddress,
            PhysicalRange => PhysicalAddress,
            else => unreachable,
        };
    };
}
