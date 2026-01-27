// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const core = @import("core");

pub inline fn expectEqual(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

/// Asserts that the size *and* bit size of the given type matches the expected size.
pub inline fn expectSize(comptime T: type, comptime size: core.Size) void {
    if (@sizeOf(T) != size.value) {
        @compileError(std.fmt.comptimePrint(
            "{s} has size {f} but is expected to have {f}",
            .{ @typeName(T), core.Size.of(size), size },
        ));
    }
    if (@bitSizeOf(T) != 8 * size.value) {
        @compileError(std.fmt.comptimePrint(
            "{s} has bit size {} but is expected to have {}",
            .{ @typeName(T), @bitSizeOf(T), 8 * size.value },
        ));
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
