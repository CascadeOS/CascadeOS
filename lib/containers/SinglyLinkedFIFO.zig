// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Singly linked FIFO (first in first out).
//!
//! Not thread-safe.

const SinglyLinkedFIFO = @This();

start_node: ?*SingleNode,
end_node: ?*SingleNode,

pub const empty: SinglyLinkedFIFO = .{
    .start_node = null,
    .end_node = null,
};

/// Returns `true` if the list is empty.
///
/// This operation is O(1).
pub fn isEmpty(singly_linked_lifo: *const SinglyLinkedFIFO) bool {
    return singly_linked_lifo.start_node == null;
}

/// Adds a node to the end of the list.
///
/// This operation is O(1).
pub fn push(singly_linked_lifo: *SinglyLinkedFIFO, node: *SingleNode) void {
    std.debug.assert(node.next == null);

    if (singly_linked_lifo.end_node) |end| {
        std.debug.assert(singly_linked_lifo.start_node != null);
        end.next = node;
    } else {
        node.* = .empty;
        singly_linked_lifo.start_node = node;
    }

    singly_linked_lifo.end_node = node;
}

/// Removes a node from the front of the list and returns it.
pub fn pop(singly_linked_lifo: *SinglyLinkedFIFO) ?*SingleNode {
    const node = singly_linked_lifo.start_node orelse return null;
    std.debug.assert(singly_linked_lifo.end_node != null);

    if (singly_linked_lifo.start_node == singly_linked_lifo.end_node) {
        std.debug.assert(node.next == null);
        singly_linked_lifo.end_node = null;
    }

    singly_linked_lifo.start_node = node.next;
    node.* = .empty;
    return node;
}

/// Returns the number of nodes in the list.
///
/// This operation is O(N).
pub fn len(singly_linked_lifo: *const SinglyLinkedFIFO) usize {
    var result: usize = 0;

    var opt_node = singly_linked_lifo.start_node;
    while (opt_node) |node| : (opt_node = node.next) {
        result += 1;
    }

    return result;
}

pub fn iterate(singly_linked_lifo: *const SinglyLinkedFIFO) SingleNode.Iterator {
    return .{ .current_node = singly_linked_lifo.start_node };
}

test SinglyLinkedFIFO {
    const NODE_COUNT = 10;

    var fifo: SinglyLinkedFIFO = .empty;

    // starts empty
    try std.testing.expect(fifo.isEmpty());
    try std.testing.expect(fifo.len() == 0);

    var nodes = [_]SingleNode{.empty} ** NODE_COUNT;

    for (&nodes) |*node| {
        // add node to the end of the list
        fifo.push(node);
        try std.testing.expect(!fifo.isEmpty());
    }

    // nodes are popped in the order they were pushed
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        try std.testing.expect(fifo.len() == NODE_COUNT - i);

        const node = fifo.pop() orelse
            return error.ExpectedNode;

        try std.testing.expect(fifo.len() == NODE_COUNT - i - 1);
        try std.testing.expect(node == &nodes[i]);
    }

    // list is empty again
    try std.testing.expect(fifo.isEmpty());
    try std.testing.expect(fifo.len() == 0);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const SingleNode = containers.SingleNode;
