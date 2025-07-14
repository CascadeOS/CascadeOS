// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const is_debug = builtin.mode == .Debug;

pub const Duration = @import("duration.zig").Duration;

pub const Size = @import("size.zig").Size;

const address = @import("address.zig");
pub const Address = address.Address;
pub const PhysicalAddress = address.PhysicalAddress;
pub const PhysicalRange = address.PhysicalRange;
pub const VirtualAddress = address.VirtualAddress;
pub const VirtualRange = address.VirtualRange;

pub const testing = @import("testing.zig");

pub inline fn require(value: anytype, comptime msg: []const u8) @TypeOf(value catch unreachable) {
    return value catch |err| {
        std.debug.panic(comptime msg ++ ": {t}", .{err});
    };
}

pub const Direction = enum {
    forward,
    backward,
};

pub const endian = struct {
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
};

/// A calling convention that is `Inline` in non-debug builds, and `Unspecified` in debug builds.
///
/// This allows the effect of inlining for release builds but does result in missing debug information during
/// debug builds.
pub const inline_in_non_debug: std.builtin.CallingConvention = if (builtin.mode == .Debug) .auto else .@"inline";

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");
const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();
