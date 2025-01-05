// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const AtomicSinglyLinkedLIFO = @import("AtomicSinglyLinkedLIFO.zig");
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

/// A node with a single next pointer.
///
/// Intended to be stored intrusively in a struct to allow `@fieldParentPtr`.
pub const SingleNode = extern struct {
    next: ?*SingleNode,

    pub const empty: SingleNode = .{ .next = null };

    pub const Iterator = struct {
        current_node: ?*SingleNode,

        pub fn next(self: *Iterator) ?*SingleNode {
            const current_node = self.current_node orelse return null;
            self.current_node = current_node.next;
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

        pub fn next(self: *Iterator) ?*DoubleNode {
            const current_node = self.current_node orelse return null;
            self.current_node = switch (self.direction) {
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
