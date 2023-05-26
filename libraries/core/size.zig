// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const Size = extern struct {
    bytes: usize,

    comptime {
        std.debug.assert(@sizeOf(Size) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(Size) == @bitSizeOf(usize));
    }
};

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
