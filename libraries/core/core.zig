// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();

const size = @import("size.zig");
pub const Size = size.Size;

pub const testing = @import("testing.zig");

/// This function is the same as `std.builtin.panic` except it passes `@returnAddress()`
/// meaning the stack trace will not include any panic functions.
pub fn panic(comptime msg: []const u8) noreturn {
    @setCold(true);
    std.builtin.panic(msg, null, @returnAddress());
}

/// This function is the same as `std.debug.panicExtra` except it passes `@returnAddress()`
/// meaning the stack trace will not include any panic functions.
pub fn panicFmt(comptime format: []const u8, args: anytype) noreturn {
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

/// Converts an integer which has host endianness to the desired endianness.
///
/// Copied from `std.mem`, changed to be inline and `desired_endianness` has been marked as comptime.
pub inline fn nativeTo(comptime T: type, x: T, comptime desired_endianness: std.builtin.Endian) T {
    return switch (desired_endianness) {
        .Little => nativeToLittle(T, x),
        .Big => nativeToBig(T, x),
    };
}

/// Converts an integer which has host endianness to little endian.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn nativeToLittle(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(x),
    };
}

/// Converts an integer which has host endianness to big endian.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn nativeToBig(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(x),
        .Big => x,
    };
}

/// Converts an integer from specified endianness to host endianness.
///
/// Copied from `std.mem`, changed to be inline and `desired_endianness` has been marked as comptime.
pub inline fn toNative(comptime T: type, x: T, comptime endianness_of_x: std.builtin.Endian) T {
    return switch (endianness_of_x) {
        .Little => littleToNative(T, x),
        .Big => bigToNative(T, x),
    };
}

/// Converts a little-endian integer to host endianness.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn littleToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => x,
        .Big => @byteSwap(x),
    };
}

/// Converts a big-endian integer to host endianness.
///
/// Copied from `std.mem`, changed to be inline.
pub inline fn bigToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .Little => @byteSwap(x),
        .Big => x,
    };
}

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first and !decl.is_pub) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
