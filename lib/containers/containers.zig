// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");

/// A node with a single next pointer.
///
/// Intended to be stored intrusively in a struct to allow `@fieldParentPtr`.
pub const SingleNode = extern struct {
    next: ?*SingleNode = null,
};

/// A node with a next and previous pointers.
///
/// Intended to be stored intrusively in a struct to allow `@fieldParentPtr`.
pub const DoubleNode = extern struct {
    next: ?*DoubleNode = null,
    previous: ?*DoubleNode = null,
};

pub const DoublyLinkedLIFO = @import("DoublyLinkedLIFO.zig");
pub const SinglyLinkedFIFO = @import("SinglyLinkedFIFO.zig");
pub const SinglyLinkedLIFO = @import("SinglyLinkedLIFO.zig");

pub const SegmentedObjectPool = @import("SegmentedObjectPool.zig").SegmentedObjectPool;

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
