// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// TODO: Support u32 sized addresses

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

    const name = "PhysicalAddress";

    pub inline fn fromInt(value: u64) PhysicalAddress {
        return .{ .value = value };
    }

    pub inline fn toRange(self: PhysicalAddress, size: core.Size) PhysicalRange {
        return .{ .address = self, .size = size };
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

    pub inline fn toRange(self: VirtualAddress, size: core.Size) VirtualRange {
        return .{ .address = self, .size = size };
    }

    pub usingnamespace AddrMixin(@This());

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

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
    /// The range is asserted to have the exact size of the slice.
    ///
    /// It is the caller's responsibility to ensure that the range is valid in the current address space.
    pub fn toSliceExact(self: VirtualRange, comptime T: type) ![]T {
        const size_of_t = core.Size.of(T);
        const count = size_of_t.amountToCover(self.size);
        if (size_of_t.multiplyScalar(count) != self.size) return error.NotExact;
        return self.address.toPtr([*]T)[0..count];
    }

    /// Returns a slice of type `T` corresponding to this virtual range.
    ///
    /// The range is allowed to be longer that the the slice needs.
    ///
    /// It is the caller's responsibility to ensure that the range is valid in the current address space.
    pub fn toSliceRelaxed(self: VirtualRange, comptime T: type) []T {
        const size_of_t = core.Size.of(T);
        const count = size_of_t.amountToCover(self.size);
        return self.address.toPtr([*]T)[0..count];
    }

    /// Returns a byte slice of the memory corresponding to this virtual range.
    ///
    /// It is the caller's responsibility to ensure:
    ///   - the range is valid in the current address space
    ///   - no writes are performed if the range is read-only
    pub inline fn toByteSlice(self: VirtualRange) []u8 {
        return self.address.toPtr([*]u8)[0..self.size.value];
    }

    pub usingnamespace RangeMixin(@This());
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

        /// Rounds up the address to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignForwardInPlace(self: *Self, alignment: core.Size) void {
            self.value = std.mem.alignForward(u64, self.value, alignment.value);
        }

        /// Returns the address rounded down to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignBackward(self: Self, alignment: core.Size) Self {
            return .{ .value = std.mem.alignBackward(u64, self.value, alignment.value) };
        }

        /// Rounds down the address to the nearest multiple of the given alignment.
        ///
        /// `alignment` must be a power of two.
        pub inline fn alignBackwardInPlace(self: *Self, alignment: core.Size) void {
            self.value = std.mem.alignBackward(u64, self.value, alignment.value);
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

        pub fn print(self: Self, writer: std.io.AnyWriter, indent: usize) !void {
            _ = indent;

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
            _ = options;
            _ = fmt;
            return if (@TypeOf(writer) == std.io.AnyWriter)
                print(self, writer, 0)
            else
                print(self, writer.any(), 0);
        }

        fn __helpZls() void {
            Self.print(undefined, @as(std.fs.File.Writer, undefined), 0);
        }
    };
}

fn RangeMixin(comptime Self: type) type {
    return struct {
        pub const AddrType = std.meta.fieldInfo(Self, .address).type;

        pub inline fn fromAddr(address: AddrType, size: core.Size) Self {
            return .{
                .address = address,
                .size = size,
            };
        }

        /// Returns the address of the first byte __after__ the range.
        pub inline fn endBound(self: Self) AddrType {
            return self.address.moveForward(self.size);
        }

        /// Returns the last address in this range.
        ///
        /// If the ranges size is zero, returns the start address of the range.
        pub fn last(self: Self) AddrType {
            if (self.size.value == 0) return self.address;
            return self.address.moveForward(self.size.subtract(core.Size.one));
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
            if (!self.last().greaterThanOrEqual(other.last())) return false;

            return true;
        }

        pub fn contains(self: Self, address: AddrType) bool {
            return address.greaterThanOrEqual(self.address) and address.lessThanOrEqual(self.last());
        }

        pub fn print(value: Self, writer: std.io.AnyWriter, indent: usize) !void {
            try writer.writeAll(comptime Self.name ++ "{ 0x");
            try std.fmt.formatInt(value.address.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

            try writer.writeAll(" - 0x");
            try std.fmt.formatInt(value.last().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
            try writer.writeAll(" - ");

            try value.size.print(writer, indent);
            try writer.writeAll(" }");
        }

        pub inline fn format(
            value: Self,
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

        fn __helpZls() void {
            Self.print(undefined, @as(std.fs.File.Writer, undefined), 0);
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
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

const core = @import("core");
const std = @import("std");
