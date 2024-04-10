// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

pub fn ValueTypeMixin(comptime Self: type) type {
    return struct {
        const FieldT: type = std.meta.fieldInfo(Self, .value).type;

        pub const zero: Self = .{ .value = 0 };
        pub const one: Self = .{ .value = 1 };

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

        pub inline fn add(self: Self, other: Self) Self {
            return .{ .value = self.value + other.value };
        }

        pub inline fn addInPlace(self: *Self, other: Self) void {
            self.value += other.value;
        }

        pub inline fn subtract(self: Self, other: Self) Self {
            return .{ .value = self.value - other.value };
        }

        pub inline fn subtractInPlace(self: *Self, other: Self) void {
            self.value -= other.value;
        }

        pub inline fn multiply(self: Self, other: Self) Self {
            return .{ .value = self.value * other.value };
        }

        pub inline fn multiplyInPlace(self: *Self, other: Self) void {
            self.value *= other.value;
        }

        pub inline fn multiplyScalar(self: Self, value: FieldT) Self {
            return .{ .value = self.value * value };
        }

        pub inline fn multiplyScalarInPlace(self: *Self, value: FieldT) void {
            self.value *= value;
        }

        pub inline fn divide(self: Self, other: Self) Self {
            return .{ .value = self.value / other.value };
        }

        pub inline fn divideInPlace(self: *Self, other: Self) void {
            self.value /= other.value;
        }

        pub inline fn divideScalar(self: Self, value: FieldT) Self {
            return self.value / value;
        }

        pub inline fn divideScalarInPlace(self: *Self, value: FieldT) Self {
            self.value /= value;
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
