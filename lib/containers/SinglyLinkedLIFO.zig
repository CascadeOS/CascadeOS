// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Singly linked LIFO (last in first out).
//!
//! Not thread-safe.

const SinglyLinkedLIFO = @This();

start_node: ?*SingleNode,

pub const empty: SinglyLinkedLIFO = .{ .start_node = null };

/// Returns `true` if the list is empty.
///
/// This operation is O(1).
pub fn isEmpty(self: *const SinglyLinkedLIFO) bool {
    return self.start_node == null;
}

/// Adds a node to the front of the list.
///
/// This operation is O(1).
pub fn push(self: *SinglyLinkedLIFO, node: *SingleNode) void {
    std.debug.assert(node.next == null);

    node.* = .{ .next = self.start_node };
    self.start_node = node;
}

/// Adds a list of nodes to the front of the list.
///
/// The list must be a valid linked list.
///
/// This operation is O(1).
pub fn pushList(self: *SinglyLinkedLIFO, first_node: *SingleNode, last_node: *SingleNode) void {
    std.debug.assert(last_node.next == null);

    if (self.start_node) |start| {
        last_node.* = .{ .next = start };
    }

    self.start_node = first_node;
}

/// Removes a node from the front of the list and returns it.
///
/// This operation is O(1).
pub fn pop(self: *SinglyLinkedLIFO) ?*SingleNode {
    const node = self.start_node orelse return null;
    self.start_node = node.next;
    node.* = .empty;
    return node;
}

/// Returns the number of nodes in the list.
///
/// This operation is O(N).
pub fn len(self: *const SinglyLinkedLIFO) usize {
    var result: usize = 0;

    var opt_node = self.start_node;
    while (opt_node) |node| : (opt_node = node.next) {
        result += 1;
    }

    return result;
}

pub fn iterate(self: *const SinglyLinkedLIFO) SingleNode.Iterator {
    return .{ .current_node = self.start_node };
}

test SinglyLinkedLIFO {
    const NODE_COUNT = 10;

    var lifo: SinglyLinkedLIFO = .empty;

    // starts empty
    try std.testing.expect(lifo.isEmpty());
    try std.testing.expect(lifo.len() == 0);

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

        try std.testing.expect(lifo.len() == i + 1);

        const node = lifo.pop() orelse
            return error.ExpectedNode;

        try std.testing.expect(lifo.len() == i);
        try std.testing.expect(node == &nodes[i]);
    }

    // list is empty again
    try std.testing.expect(lifo.isEmpty());
    try std.testing.expect(lifo.len() == 0);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const SingleNode = containers.SingleNode;
