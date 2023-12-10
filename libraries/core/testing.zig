// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core.zig");

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

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        for (std.meta.declarations(T)) |decl| {
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
