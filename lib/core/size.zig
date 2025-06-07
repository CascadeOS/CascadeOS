// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Represents a size in bytes.
pub const Size = extern struct {
    value: u64,

    pub const zero: Size = .{ .value = 0 };
    pub const one: Size = .{ .value = 1 };

    pub const Unit = enum(u64) {
        byte = 1,
        kib = 1024,
        mib = 1024 * 1024,
        gib = 1024 * 1024 * 1024,
        tib = 1024 * 1024 * 1024 * 1024,
    };

    pub inline fn of(comptime T: type) Size {
        return .{ .value = @sizeOf(T) };
    }

    pub fn from(amount: u64, unit: Unit) Size {
        return .{
            .value = amount * @intFromEnum(unit),
        };
    }

    /// Checks if the `Size` is aligned to the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub inline fn isAligned(size: Size, alignment: Size) bool {
        return std.mem.isAligned(size.value, alignment.value);
    }

    /// Aligns the `Size` forward to the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForward(size: Size, alignment: Size) Size {
        return .{ .value = std.mem.alignForward(u64, size.value, alignment.value) };
    }

    /// Aligns the `Size` forward to the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignForwardInPlace(size: *Size, alignment: Size) void {
        size.value = std.mem.alignForward(u64, size.value, alignment.value);
    }

    /// Aligns the `Size` backward to the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackward(size: Size, alignment: Size) Size {
        return .{ .value = std.mem.alignBackward(u64, size.value, alignment.value) };
    }

    /// Aligns the `Size` backward to the given alignment.
    ///
    /// `alignment` must be a power of two.
    pub fn alignBackwardInPlace(size: *Size, alignment: core.Size) void {
        size.value = std.mem.alignBackward(u64, size.value, alignment.value);
    }

    /// Returns the amount of `size` sizes needed to cover `target`.
    ///
    /// Caller must ensure `size` is not zero.
    pub fn amountToCover(size: Size, target: Size) u64 {
        const one_byte = core.Size{ .value = 1 };
        return target.add(size.subtract(one_byte)).divide(size).value;
    }

    test amountToCover {
        {
            const size = Size{ .value = 10 };
            const target = Size{ .value = 25 };
            const expected: u64 = 3;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 1 };
            const target = Size{ .value = 30 };
            const expected: u64 = 30;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 100 };
            const target = Size{ .value = 100 };
            const expected: u64 = 1;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .value = 512 };
            const target = core.Size.from(64, .mib);
            const expected: u64 = 131072;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }
    }

    pub inline fn equal(size: Size, other: Size) bool {
        return size.value == other.value;
    }

    pub inline fn lessThan(size: Size, other: Size) bool {
        return size.value < other.value;
    }

    pub inline fn lessThanOrEqual(size: Size, other: Size) bool {
        return size.value <= other.value;
    }

    pub inline fn greaterThan(size: Size, other: Size) bool {
        return size.value > other.value;
    }

    pub inline fn greaterThanOrEqual(size: Size, other: Size) bool {
        return size.value >= other.value;
    }

    pub fn compare(size: Size, other: Size) std.math.Order {
        if (size.lessThan(other)) return .lt;
        if (size.greaterThan(other)) return .gt;
        return .eq;
    }

    pub fn add(size: Size, other: Size) Size {
        return .{ .value = size.value + other.value };
    }

    pub fn addInPlace(size: *Size, other: Size) void {
        size.value += other.value;
    }

    pub fn subtract(size: Size, other: Size) Size {
        return .{ .value = size.value - other.value };
    }

    pub fn subtractInPlace(size: *Size, other: Size) void {
        size.value -= other.value;
    }

    pub fn multiply(size: Size, other: Size) Size {
        return .{ .value = size.value * other.value };
    }

    pub fn multiplyInPlace(size: *Size, other: Size) void {
        size.value *= other.value;
    }

    pub fn multiplyScalar(size: Size, value: u64) Size {
        return .{ .value = size.value * value };
    }

    pub fn multiplyScalarInPlace(size: *Size, value: u64) void {
        size.value *= value;
    }

    pub fn divide(size: Size, other: Size) Size {
        return .{ .value = size.value / other.value };
    }

    pub fn divideInPlace(size: *Size, other: Size) void {
        size.value /= other.value;
    }

    pub fn divideScalar(size: Size, value: u64) Size {
        return .{ .value = size.value / value };
    }

    pub fn divideScalarInPlace(size: *Size, value: u64) void {
        size.value /= value;
    }

    // Must be kept in descending size order due to the logic in `print`
    const unit_table = .{
        .{ .value = @intFromEnum(Unit.tib), .name = "TiB" },
        .{ .value = @intFromEnum(Unit.gib), .name = "GiB" },
        .{ .value = @intFromEnum(Unit.mib), .name = "MiB" },
        .{ .value = @intFromEnum(Unit.kib), .name = "KiB" },
        .{ .value = @intFromEnum(Unit.byte), .name = "B" },
    };

    pub fn print(size: Size, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        var value = size.value;

        if (value == 0) {
            try writer.writeAll("0 bytes");
            return;
        }

        var emitted_anything = false;

        inline for (unit_table) |unit| blk: {
            if (value < unit.value) break :blk; // continue loop

            const part = value / unit.value;

            if (emitted_anything) try writer.writeAll(", ");

            try std.fmt.formatInt(part, 10, .lower, .{}, writer);
            try writer.writeAll(comptime " " ++ unit.name);

            value -= part * unit.value;
            emitted_anything = true;
        }
    }

    pub inline fn format(
        size: Size,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            print(size, writer, 0)
        else
            print(size, writer.any(), 0);
    }

    comptime {
        core.testing.expectSize(Size, @sizeOf(u64));
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
