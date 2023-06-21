// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core.zig");

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
