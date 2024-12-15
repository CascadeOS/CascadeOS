// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Singly linked LIFO (last in first out).
//!
//! Provides thread-saftey using atomic operations.

const AtomicSinglyLinkedLIFO = @This();

start_node: std.atomic.Value(?*SingleNode),

pub const empty: AtomicSinglyLinkedLIFO = .{ .start_node = .init(null) };

/// Returns `true` if the list is empty.
pub fn isEmpty(self: *const AtomicSinglyLinkedLIFO) bool {
    return self.start_node.load(.acquire) == null;
}

/// Adds a node to the front of the list.
pub fn push(self: *AtomicSinglyLinkedLIFO, node: *SingleNode) void {
    var opt_start_node = self.start_node.load(.monotonic);

    while (true) {
        node.next = opt_start_node;

        if (self.start_node.cmpxchgWeak(
            opt_start_node,
            node,
            .acq_rel,
            .monotonic,
        )) |new_value| {
            opt_start_node = new_value;
            continue;
        }

        return;
    }
}

/// Removes a node from the front of the list and returns it.
pub fn pop(self: *AtomicSinglyLinkedLIFO) ?*SingleNode {
    var opt_start_node = self.start_node.load(.monotonic);

    while (opt_start_node) |start_node| {
        if (self.start_node.cmpxchgWeak(
            opt_start_node,
            start_node.next,
            .acq_rel,
            .monotonic,
        )) |new_value| {
            opt_start_node = new_value;
            continue;
        }

        start_node.* = .empty;

        break;
    }

    return opt_start_node;
}

test AtomicSinglyLinkedLIFO {
    const NODE_COUNT = 10;

    var lifo: AtomicSinglyLinkedLIFO = .empty;

    // starts empty
    try std.testing.expect(lifo.isEmpty());

    var nodes = [_]SingleNode{.empty} ** NODE_COUNT;

    for (&nodes) |*node| {
        // add node to the front of the list
        lifo.push(node);
        try std.testing.expect(!lifo.isEmpty());
        try std.testing.expect(!lifo.isEmpty());

        // popping the node should return the node just added
        const first_node = lifo.pop() orelse return error.NonEmptyListHasNoNode;
        try std.testing.expect(first_node == node);

        // add the popped node back to the list
        lifo.push(node);
    }

    // nodes are popped in the opposite order they were pushed
    var i: usize = NODE_COUNT;
    while (i > 0) {
        i -= 1;

        const node = lifo.pop() orelse
            return error.ExpectedNode;

        try std.testing.expect(node == &nodes[i]);
    }

    // list is empty again
    try std.testing.expect(lifo.isEmpty());
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const SingleNode = containers.SingleNode;
