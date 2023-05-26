// SPDX-License-Identifier: MIT

const std = @import("std");

const size = @import("size.zig");
pub const Size = size.Size;

/// This function is the same as `std.builtin.panic` except it passes `@returnAddress()`
/// meaning the stack trace will not include any panic functions.
pub inline fn panic(comptime msg: []const u8) noreturn {
    @setCold(true);
    std.builtin.panic(msg, null, @returnAddress());
}

/// This function is the same as `std.debug.panicExtra` except it passes `@returnAddress()`
/// meaning the stack trace will not include any panic functions.
pub inline fn panicFmt(comptime format: []const u8, args: anytype) noreturn {
    @setCold(true);
    std.debug.panicExtra(null, @returnAddress(), format, args);
}

/// This function formats structs but skips fields containing "reserved" in their name.
pub fn formatStructIgnoreReserved(
    self: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = fmt;

    const BaseType: type = switch (@typeInfo(@TypeOf(self))) {
        .Pointer => |ptr| switch (ptr.size) {
            .One => ptr.child,
            inline else => |x| @compileError("Unsupported type of pointer " ++ @typeName(@TypeOf(x))),
        },
        .Struct => self,
        inline else => |x| @compileError("Unsupported type " ++ @typeName(@TypeOf(x))),
    };

    const struct_info: std.builtin.Type.Struct = @typeInfo(BaseType).Struct;

    try writer.writeAll(comptime @typeName(BaseType) ++ "{");

    comptime var first: bool = true;

    inline for (struct_info.fields) |field| {
        if (comptime std.mem.indexOf(u8, field.name, "reserved") != null) continue;

        try writer.writeAll(comptime (if (first) "" else ",") ++ " ." ++ field.name ++ " = ");

        const field_type_info: std.builtin.Type = @typeInfo(field.type);

        switch (field_type_info) {
            .Bool => try (if (@field(self, field.name)) writer.writeAll("true") else writer.writeAll("false")),
            .Int => try std.fmt.formatInt(@field(self, field.name), 10, .lower, .{}, writer),
            else => @compileError("unsupported type: " ++ @typeName(field.type)),
        }

        first = false;
    }

    try writer.writeAll(" }");
}

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            if (!decl.is_pub) continue;

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
