// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Size = extern struct {
    bytes: usize,

    pub const Unit = enum(usize) {
        byte = 1,
        kib = 1024,
        mib = 1024 * 1024,
        gib = 1024 * 1024 * 1024,
        tib = 1024 * 1024 * 1024 * 1024,
    };

    const unit_table = .{
        .{ .value = @enumToInt(Unit.tib), .name = "TiB" },
        .{ .value = @enumToInt(Unit.gib), .name = "GiB" },
        .{ .value = @enumToInt(Unit.mib), .name = "MiB" },
        .{ .value = @enumToInt(Unit.kib), .name = "KiB" },
        .{ .value = @enumToInt(Unit.byte), .name = "B" },
    };

    pub const zero: Size = .{ .bytes = 0 };

    pub inline fn of(comptime T: type) Size {
        return .{ .bytes = @sizeOf(T) };
    }

    pub inline fn from(size: usize, unit: Unit) Size {
        return .{
            .bytes = size * @enumToInt(unit),
        };
    }

    pub inline fn isAligned(self: Size, alignment: Size) bool {
        return std.mem.isAligned(self.bytes, alignment.bytes);
    }

    pub inline fn alignForward(self: Size, alignment: Size) Size {
        return .{ .bytes = std.mem.alignForward(self.bytes, alignment.bytes) };
    }

    pub inline fn alignBackward(self: Size, alignment: Size) Size {
        return .{ .bytes = std.mem.alignBackward(self.bytes, alignment.bytes) };
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
    /// Caller must ensure `other` is not zero.
    pub inline fn divide(self: Size, other: Size) usize {
        return self.bytes / other.bytes;
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

    pub fn print(size: Size, writer: anytype) !void {
        if (size.bytes == 0) {
            try writer.writeAll("0 bytes");
            return;
        }

        var value = size.bytes;
        var emitted_anything = false;

        inline for (unit_table) |unit| {
            if (value >= unit.value) {
                const part = value / unit.value;

                if (emitted_anything) try writer.writeAll(", ");

                try std.fmt.formatInt(part, 10, .lower, .{}, writer);
                try writer.writeAll(comptime " " ++ unit.name);

                value -= part * unit.value;
                emitted_anything = true;
            }
        }
    }

    pub fn format(
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
        std.debug.assert(@sizeOf(Size) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(Size) == @bitSizeOf(usize));
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
