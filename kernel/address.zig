// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const PhysicalAddress = extern struct {
    value: usize,

    const name = "PhysicalAddress";

    pub inline fn fromInt(value: usize) PhysicalAddress {
        // TODO: check that the address is valid (cannoical) https://github.com/CascadeOS/CascadeOS/issues/15
        return .{ .value = value };
    }

    /// Returns the virtual address corresponding to this physical address in the direct map.
    pub inline fn toDirectMap(self: PhysicalAddress) VirtualAddress {
        return .{ .value = self.value + kernel.info.direct_map.address.value };
    }

    /// Returns the virtual address corresponding to this physical address in the non-cached direct map.
    pub inline fn toNonCachedDirectMap(self: PhysicalAddress) VirtualAddress {
        return .{ .value = self.value + kernel.info.non_cached_direct_map.address.value };
    }

    pub usingnamespace AddrMixin(@This());

    comptime {
        core.testing.expectSize(@This(), @sizeOf(usize));
    }
};

pub const VirtualAddress = extern struct {
    value: usize,

    const name = "VirtualAddress";

    pub inline fn fromInt(value: usize) VirtualAddress {
        // TODO: check that the address is valid (cannoical) https://github.com/CascadeOS/CascadeOS/issues/15
        return .{ .value = value };
    }

    pub inline fn fromPtr(ptr: *const anyopaque) VirtualAddress {
        return fromInt(@intFromPtr(ptr));
    }

    pub inline fn toPtr(self: VirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(self.value);
    }

    /// Returns the physical address of the given diret map virtual address.
    ///
    /// ## Safety
    /// It is the caller's responsibility to ensure that the given virtual address is in the direct map.
    pub fn unsafeToPhysicalFromDirectMap(self: VirtualAddress) PhysicalAddress {
        return .{ .value = self.value - kernel.info.direct_map.address.value };
    }

    /// Returns the physical address of the given virtual address if it is in one of the direct maps.
    pub fn toPhysicalFromDirectMap(self: VirtualAddress) error{AddressNotInAnyDirectMap}!PhysicalAddress {
        if (kernel.info.direct_map.contains(self)) {
            return .{ .value = self.value - kernel.info.direct_map.address.value };
        }
        if (kernel.info.non_cached_direct_map.contains(self)) {
            return .{ .value = self.value - kernel.info.non_cached_direct_map.address.value };
        }
        return error.AddressNotInAnyDirectMap;
    }

    pub usingnamespace AddrMixin(@This());

    comptime {
        core.testing.expectSize(@This(), @sizeOf(usize));
    }
};

fn AddrMixin(comptime Self: type) type {
    return struct {
        pub const zero: Self = .{ .value = 0 };

        pub inline fn isAligned(self: Self, alignment: core.Size) bool {
            return std.mem.isAligned(self.value, alignment.bytes);
        }

        pub inline fn moveForward(self: Self, size: core.Size) Self {
            return .{ .value = self.value + size.bytes };
        }

        pub inline fn moveForwardInPlace(self: *Self, size: core.Size) void {
            self.value += size.bytes;
        }

        pub inline fn moveBackward(self: Self, size: core.Size) Self {
            return .{ .value = self.value - size.bytes };
        }

        pub inline fn moveBackwardInPlace(self: *Self, size: core.Size) void {
            self.value -= size.bytes;
        }

        pub inline fn equal(self: Self, other: Self) bool {
            return self.value == other.value;
        }

        pub inline fn lessThan(self: Self, other: Self) bool {
            return self.value < other.value;
        }

        pub inline fn lessThanOrEqual(self: Self, other: Self) bool {
            return self.value <= other.value;
        }

        pub inline fn greaterThan(self: Self, other: Self) bool {
            return self.value > other.value;
        }

        pub inline fn greaterThanOrEqual(self: Self, other: Self) bool {
            return self.value >= other.value;
        }

        pub fn print(self: Self, writer: anytype) !void {
            try writer.writeAll(comptime Self.name ++ "{ 0x");
            try std.fmt.formatInt(self.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
            try writer.writeAll(" }");
        }

        pub inline fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            return print(self, writer);
        }
    };
}

pub const PhysicalRange = struct {
    address: PhysicalAddress,
    size: core.Size,

    const name = "PhysicalRange";

    /// Returns a virtual range corresponding to this physical range in the direct map.
    pub inline fn toDirectMap(self: PhysicalRange) VirtualRange {
        return .{
            .address = self.address.toDirectMap(),
            .size = self.size,
        };
    }

    pub usingnamespace RangeMixin(@This(), PhysicalAddress);
};

pub const VirtualRange = struct {
    address: VirtualAddress,
    size: core.Size,

    const name = "VirtualRange";

    /// Returns a virtual range corresponding to the given slice.
    pub fn fromSlice(slice: anytype) VirtualRange {
        const info: std.builtin.Type = @typeInfo(@TypeOf(slice));
        if (info != .Pointer) @compileError("Type of `slice` is not a pointer: " ++ @typeName(@TypeOf(slice)));
        const pointer_info: std.builtin.Type.Pointer = info.Pointer;
        if (pointer_info.size != .Slice) @compileError("`slice` is not a slice: " ++ @typeName(@TypeOf(slice)));
        return .{
            .address = VirtualAddress.fromPtr(slice.ptr),
            .size = core.Size.from(@sizeOf(pointer_info.child) * slice.len, .byte),
        };
    }

    /// Returns a slice of type `T` corresponding to this virtual range.
    pub fn toSlice(self: VirtualRange, comptime T: type) ![]T {
        const len = try std.math.divExact(usize, self.size.bytes, @sizeOf(T));
        return self.address.toPtr([*]T)[0..len];
    }

    pub usingnamespace RangeMixin(@This(), VirtualAddress);
};

fn RangeMixin(comptime Self: type, comptime AddrType: type) type {
    return struct {
        pub inline fn fromAddr(address: AddrType, size: core.Size) Self {
            return .{
                .address = address,
                .size = size,
            };
        }

        pub inline fn end(self: Self) AddrType {
            return self.address.moveForward(self.size);
        }

        pub inline fn moveForward(self: Self, size: core.Size) Self {
            return .{
                .address = self.address.moveForward(size),
                .size = self.size,
            };
        }

        pub inline fn moveForwardInPlace(self: *Self, size: core.Size) void {
            self.address.moveForwardInPlace(size);
        }

        pub inline fn moveBackward(self: Self, size: core.Size) Self {
            return .{
                .address = self.address.moveBackward(size),
                .size = self.size,
            };
        }

        pub inline fn moveBackwardInPlace(self: *Self, size: core.Size) void {
            self.address.moveBackwardInPlace(size);
        }

        pub fn contains(self: Self, address: AddrType) bool {
            return address.greaterThanOrEqual(self.address) and address.lessThan(self.end());
        }

        pub fn print(value: Self, writer: anytype) !void {
            try writer.writeAll(Self.name ++ "{ 0x");
            try std.fmt.formatInt(value.address.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

            try writer.writeAll(" - 0x");
            try std.fmt.formatInt(value.end().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
            try writer.writeAll(" - ");

            try value.size.print(writer);
            try writer.writeAll(" }");
        }

        pub inline fn format(
            value: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            return print(value, writer);
        }
    };
}
