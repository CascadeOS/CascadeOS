// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");

pub const RedBlack = struct {
    const red_black_tree = @import("red_black_tree.zig");

    pub const Tree = red_black_tree.Tree;
    pub const Node = red_black_tree.Node;
    pub const Iterator = red_black_tree.Iterator;
    pub const ComparisonAndMatch = red_black_tree.ComparisonAndMatch;
};

comptime {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
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
