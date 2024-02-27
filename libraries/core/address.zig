// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const std = @import("std");

pub const PhysicalAddress = extern struct {
    value: u64,

    const name = "PhysicalAddress";

    pub inline fn fromInt(value: u64) PhysicalAddress {
        return .{ .value = value };
    }

    pub usingnamespace AddrMixin(@This());

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

pub const VirtualAddress = extern struct {
    value: u64,

    const name = "VirtualAddress";

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

    pub usingnamespace AddrMixin(@This());

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

fn AddrMixin(comptime Self: type) type {
    return struct {
        pub const zero: Self = .{ .value = 0 };

        pub inline fn isAligned(self: Self, alignment: core.Size) bool {
            return std.mem.isAligned(self.value, alignment.value);
        }

        /// Returns the address rounded up to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignForward(self: Self, alignment: core.Size) Self {
            return .{ .value = std.mem.alignForward(u64, self.value, alignment.value) };
        }

        /// Returns the address rounded down to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignBackward(self: Self, alignment: core.Size) Self {
            return .{ .value = std.mem.alignBackward(u64, self.value, alignment.value) };
        }

        pub inline fn moveForward(self: Self, size: core.Size) Self {
            return .{ .value = self.value + size.value };
        }

        pub inline fn moveForwardInPlace(self: *Self, size: core.Size) void {
            self.value += size.value;
        }

        pub inline fn moveBackward(self: Self, size: core.Size) Self {
            return .{ .value = self.value - size.value };
        }

        pub inline fn moveBackwardInPlace(self: *Self, size: core.Size) void {
            self.value -= size.value;
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
    ///
    /// It is the caller's responsibility to ensure that the range is valid in the current address space.
    pub fn toSlice(self: VirtualRange, comptime T: type) ![]T {
        const len = try std.math.divExact(u64, self.size.value, @sizeOf(T));
        return self.address.toPtr([*]T)[0..len];
    }

    /// Returns a byte slice of the memory corresponding to this virtual range.
    ///
    /// It is the caller's responsibility to ensure that the range is valid in the current address space.
    pub inline fn toByteSlice(self: VirtualRange) []u8 {
        return self.address.toPtr([*]u8)[0..self.size.value];
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

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
