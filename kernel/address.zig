// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

pub const PhysicalAddress = extern struct {
    value: usize,

    const name = "PhysicalAddress";

    pub inline fn fromInt(value: usize) PhysicalAddress {
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
        return .{ .value = value };
    }

    pub inline fn fromPtr(ptr: *const anyopaque) VirtualAddress {
        return fromInt(@intFromPtr(ptr));
    }

    pub inline fn toPtr(self: VirtualAddress, comptime PtrT: type) PtrT {
        return @ptrFromInt(self.value);
    }

    /// Returns the physical address of the given direct map virtual address.
    ///
    /// It is the caller's responsibility to ensure that the given virtual address is in the direct map.
    pub fn unsafeToPhysicalFromDirectMap(self: VirtualAddress) PhysicalAddress {
        return .{ .value = self.value -% kernel.info.direct_map.address.value };
    }

    /// Returns the physical address of the given virtual address if it is in one of the direct maps.
    pub fn toPhysicalFromDirectMap(self: VirtualAddress) error{AddressNotInAnyDirectMap}!PhysicalAddress {
        if (kernel.info.direct_map.contains(self)) {
            return .{ .value = self.value -% kernel.info.direct_map.address.value };
        }
        if (kernel.info.non_cached_direct_map.contains(self)) {
            return .{ .value = self.value -% kernel.info.non_cached_direct_map.address.value };
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

        /// Returns the address rounded up to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignForward(self: Self, alignment: core.Size) Self {
            return .{ .value = std.mem.alignForward(usize, self.value, alignment.bytes) };
        }

        /// Returns the address rounded down to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignBackward(self: Self, alignment: core.Size) Self {
            return .{ .value = std.mem.alignBackward(usize, self.value, alignment.bytes) };
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

        pub fn compare(self: Self, other: Self) core.OrderedComparison {
            if (self.lessThan(other)) return .less;
            if (self.greaterThan(other)) return .greater;
            return .match;
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

pub const PhysicalRange = extern struct {
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

    pub usingnamespace RangeMixin(@This());
};

pub const VirtualRange = extern struct {
    address: VirtualAddress,
    size: core.Size,

    const name = "VirtualRange";

    /// Returns a virtual range corresponding to the given slice.
    pub fn fromSlice(comptime T: type, slice: []const T) VirtualRange {
        return .{
            .address = VirtualAddress.fromPtr(slice.ptr),
            .size = core.Size.from(@sizeOf(T) * slice.len, .byte),
        };
    }

    /// Returns a slice of type `T` corresponding to this virtual range.
    pub fn toSlice(self: VirtualRange, comptime T: type) ![]T {
        const len = try std.math.divExact(usize, self.size.bytes, @sizeOf(T));
        return self.address.toPtr([*]T)[0..len];
    }

    pub inline fn toByteSlice(self: VirtualRange) []u8 {
        return self.address.toPtr([*]u8)[0..self.size.bytes];
    }

    pub usingnamespace RangeMixin(@This());
};

fn RangeMixin(comptime Self: type) type {
    return struct {
        pub const AddrType = std.meta.fieldInfo(Self, .address).type;

        pub inline fn fromAddr(address: anytype, size: core.Size) Self {
            return .{
                .address = address,
                .size = size,
            };
        }

        pub inline fn end(self: Self) AddrType {
            return self.address.moveForward(self.size);
        }

        pub fn equal(self: Self, other: Self) bool {
            return self.address.equal(other.address) and self.size.equal(other.size);
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

        pub fn containsRange(self: Self, other: Self) bool {
            if (!self.address.lessThanOrEqual(other.address)) return false;
            if (!self.end().greaterThanOrEqual(other.end())) return false;

            return true;
        }

        pub fn contains(self: Self, address: anytype) bool {
            return address.greaterThanOrEqual(self.address) and address.lessThan(self.end());
        }

        pub fn print(value: Self, writer: anytype) !void {
            try writer.writeAll(comptime Self.name ++ "{ 0x");
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
