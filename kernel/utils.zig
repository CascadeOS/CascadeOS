// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

// TODO: This file should not exist, eventually all functionality should be moved to where it belongs,
//       even if that means making a new library to house it.

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
