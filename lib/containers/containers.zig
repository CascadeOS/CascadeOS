// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const AtomicSinglyLinkedLIFO = @import("AtomicSinglyLinkedLIFO.zig");
pub const SinglyLinkedFIFO = @import("SinglyLinkedFIFO.zig");

pub const RedBlack = struct {
    const red_black_tree = @import("red_black_tree.zig");

    pub const RedBlackTree = red_black_tree.RedBlackTree;
    pub const Node = red_black_tree.Node;
    pub const Iterator = red_black_tree.Iterator;
    pub const ComparisonAndMatch = red_black_tree.ComparisonAndMatch;
};

/// A node with a single next pointer.
///
/// Intended to be stored intrusively in a struct to allow `@fieldParentPtr`.
pub const SingleNode = extern struct {
    next: ?*SingleNode,

    pub const empty: SingleNode = .{ .next = null };

    pub const Iterator = struct {
        current_node: ?*SingleNode,

        pub fn next(iterator: *Iterator) ?*SingleNode {
            const current_node = iterator.current_node orelse return null;
            iterator.current_node = current_node.next;
            return current_node;
        }
    };
};

/// A node with a next and previous pointers.
///
/// Intended to be stored intrusively in a struct to allow `@fieldParentPtr`.
pub const DoubleNode = extern struct {
    next: ?*DoubleNode,
    previous: ?*DoubleNode,

    pub const empty: DoubleNode = .{ .next = null, .previous = null };

    pub const Iterator = struct {
        direction: core.Direction,
        current_node: ?*DoubleNode,

        pub fn next(iterator: *Iterator) ?*DoubleNode {
            const current_node = iterator.current_node orelse return null;
            iterator.current_node = switch (iterator.direction) {
                .forward => current_node.next,
                .backward => current_node.previous,
            };
            return current_node;
        }
    };
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
