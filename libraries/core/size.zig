// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core.zig");

/// Represents a size in bytes.
pub const Size = extern struct {
    bytes: usize,

    pub const Unit = enum(usize) {
        byte = 1,
        kib = 1024,
        mib = 1024 * 1024,
        gib = 1024 * 1024 * 1024,
        tib = 1024 * 1024 * 1024 * 1024,
    };

    pub const zero: Size = .{ .bytes = 0 };

    pub inline fn of(comptime T: type) Size {
        return .{ .bytes = @sizeOf(T) };
    }

    pub inline fn from(amount: usize, unit: Unit) Size {
        return .{
            .bytes = amount * @intFromEnum(unit),
        };
    }

    /// Checks if the `Size` is aligned to the given alignment.
    pub inline fn isAligned(self: Size, alignment: Size) bool {
        return std.mem.isAligned(self.bytes, alignment.bytes);
    }

    /// Aligns the `Size` forward to the given alignment.
    pub inline fn alignForward(self: Size, alignment: Size) Size {
        return .{ .bytes = std.mem.alignForward(usize, self.bytes, alignment.bytes) };
    }

    /// Aligns the `Size` backward to the given alignment.
    pub inline fn alignBackward(self: Size, alignment: Size) Size {
        return .{ .bytes = std.mem.alignBackward(usize, self.bytes, alignment.bytes) };
    }

    pub inline fn add(self: Size, other: Size) Size {
        return .{ .bytes = self.bytes + other.bytes };
    }

    pub inline fn addInPlace(self: *Size, other: Size) void {
        self.bytes += other.bytes;
    }

    pub inline fn subtract(self: Size, other: Size) Size {
        return .{ .bytes = self.bytes - other.bytes };
    }

    pub inline fn subtractInPlace(self: *Size, other: Size) void {
        self.bytes -= other.bytes;
    }

    pub inline fn multiply(self: Size, value: usize) Size {
        return .{ .bytes = self.bytes * value };
    }

    pub inline fn multiplyInPlace(self: *Size, value: usize) void {
        self.bytes *= value;
    }

    /// Division is performed on integers, so the result is rounded down.
    ///
    /// Caller must ensure `other` is not zero.
    pub inline fn divide(self: Size, other: Size) usize {
        return self.bytes / other.bytes;
    }

    /// Returns the amount of `self` sizes needed to cover `target`.
    ///
    /// Caller must ensure `self` is not zero.
    pub fn amountToCover(self: Size, target: Size) usize {
        const one_byte = core.Size{ .bytes = 1 };
        return target.add(self.subtract(one_byte)).divide(self);
    }

    test amountToCover {
        {
            const size = Size{ .bytes = 10 };
            const target = Size{ .bytes = 25 };
            const expected: usize = 3;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .bytes = 1 };
            const target = Size{ .bytes = 30 };
            const expected: usize = 30;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .bytes = 100 };
            const target = Size{ .bytes = 100 };
            const expected: usize = 1;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }

        {
            const size = Size{ .bytes = 512 };
            const target = core.Size.from(64, .mib);
            const expected: usize = 131072;

            try std.testing.expectEqual(expected, size.amountToCover(target));
        }
    }

    pub inline fn lessThan(self: Size, other: Size) bool {
        return self.bytes < other.bytes;
    }

    pub inline fn lessThanOrEqual(self: Size, other: Size) bool {
        return self.bytes <= other.bytes;
    }

    pub inline fn greaterThan(self: Size, other: Size) bool {
        return self.bytes > other.bytes;
    }

    pub inline fn greaterThanOrEqual(self: Size, other: Size) bool {
        return self.bytes >= other.bytes;
    }

    pub inline fn equal(self: Size, other: Size) bool {
        return self.bytes == other.bytes;
    }

    pub fn compare(self: Size, other: Size) core.OrderedComparison {
        if (self.lessThan(other)) return .less;
        if (self.greaterThan(other)) return .greater;
        return .match;
    }

    // Must be kept in descending size order due to the logic in `print`
    const unit_table = .{
        .{ .value = @intFromEnum(Unit.tib), .name = "TiB" },
        .{ .value = @intFromEnum(Unit.gib), .name = "GiB" },
        .{ .value = @intFromEnum(Unit.mib), .name = "MiB" },
        .{ .value = @intFromEnum(Unit.kib), .name = "KiB" },
        .{ .value = @intFromEnum(Unit.byte), .name = "B" },
    };

    pub fn print(size: Size, writer: anytype) !void {
        if (size.bytes == 0) {
            try writer.writeAll("0 bytes");
            return;
        }

        var value = size.bytes;
        var emitted_anything = false;

        // TODO: use `continue` instead of `break :blk` https://github.com/CascadeOS/CascadeOS/issues/55
        inline for (unit_table) |unit| blk: {
            if (value < unit.value) break :blk;

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
        _ = fmt;
        _ = options;
        return print(size, writer);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(usize));
    }
};

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        return;
    }
}
