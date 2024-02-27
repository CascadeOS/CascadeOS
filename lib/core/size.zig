// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

/// Represents a size in bytes.
pub const Size = extern struct {
    value: u64,

    pub usingnamespace core.ValueTypeMixin(@This());

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

    pub inline fn from(amount: u64, unit: Unit) Size {
        return .{
            .value = amount * @intFromEnum(unit),
        };
    }

    /// Checks if the `Size` is aligned to the given alignment.
    pub inline fn isAligned(self: Size, alignment: Size) bool {
        return std.mem.isAligned(self.value, alignment.value);
    }

    /// Aligns the `Size` forward to the given alignment.
    pub inline fn alignForward(self: Size, alignment: Size) Size {
        return .{ .value = std.mem.alignForward(u64, self.value, alignment.value) };
    }

    /// Aligns the `Size` backward to the given alignment.
    pub inline fn alignBackward(self: Size, alignment: Size) Size {
        return .{ .value = std.mem.alignBackward(u64, self.value, alignment.value) };
    }

    /// Returns the amount of `self` sizes needed to cover `target`.
    ///
    /// Caller must ensure `self` is not zero.
    pub fn amountToCover(self: Size, target: Size) u64 {
        const one_byte = core.Size{ .value = 1 };
        return target.add(self.subtract(one_byte)).divide(self).value;
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

    // Must be kept in descending size order due to the logic in `print`
    const unit_table = .{
        .{ .value = @intFromEnum(Unit.tib), .name = "TiB" },
        .{ .value = @intFromEnum(Unit.gib), .name = "GiB" },
        .{ .value = @intFromEnum(Unit.mib), .name = "MiB" },
        .{ .value = @intFromEnum(Unit.kib), .name = "KiB" },
        .{ .value = @intFromEnum(Unit.byte), .name = "B" },
    };

    pub fn print(size: Size, writer: anytype) !void {
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
        _ = fmt;
        _ = options;
        return print(size, writer);
    }

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64));
    }
};

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
