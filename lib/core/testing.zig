// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

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
