// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub inline fn expectEqual(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

/// Asserts that the size and bit size of the given type matches the expected size.
pub inline fn expectSize(comptime T: type, comptime bytes: comptime_int) void {
    if (@sizeOf(T) != bytes) {
        @compileError(std.fmt.comptimePrint(
            "{s} has size {} but is expected to have {}",
            .{ @typeName(T), @sizeOf(T), bytes },
        ));
    }
    if (@bitSizeOf(T) != 8 * bytes) {
        @compileError(std.fmt.comptimePrint(
            "{s} has bit size {} but is expected to have {}",
            .{ @typeName(T), @bitSizeOf(T), 8 * bytes },
        ));
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
