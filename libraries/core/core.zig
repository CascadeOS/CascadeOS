// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");
const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();

pub const debug = builtin.mode == .Debug;
pub const safety = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const ValueTypeMixin = @import("value_type_mixin.zig").ValueTypeMixin;

pub const Size = @import("size.zig").Size;

pub const testing = @import("testing.zig");

/// Using `.Unspecified` prevents stack frames being lost due to inlining in debug mode.
const assert_calling_convention = if (debug) .Unspecified else .Inline;

pub fn assert(ok: bool) callconv(assert_calling_convention) void {
    if (comptime @inComptime() or safety)
        if (!ok) unreachable;
}

pub fn debugAssert(ok: bool) callconv(assert_calling_convention) void {
    if (comptime @inComptime() or debug)
        if (!ok) unreachable;
}

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

pub const OrderedComparison = enum {
    less,
    match,
    greater,
};

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
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
