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
pub fn isEmpty(self: *const SinglyLinkedFIFO) bool {
    return self.start_node == null;
}

/// Adds a node to the end of the list.
///
/// This operation is O(1).
pub fn push(self: *SinglyLinkedFIFO, node: *SingleNode) void {
    std.debug.assert(node.next == null);

    if (self.end_node) |end| {
        std.debug.assert(self.start_node != null);
        end.next = node;
    } else {
        node.* = .empty;
        self.start_node = node;
    }

    self.end_node = node;
}

/// Removes a node from the front of the list and returns it.
pub fn pop(self: *SinglyLinkedFIFO) ?*SingleNode {
    const node = self.start_node orelse return null;
    std.debug.assert(self.end_node != null);

    if (self.start_node == self.end_node) {
        std.debug.assert(node.next == null);
        self.end_node = null;
    }

    self.start_node = node.next;
    node.* = .empty;
    return node;
}

/// Returns the number of nodes in the list.
///
/// This operation is O(N).
pub fn len(self: *const SinglyLinkedFIFO) usize {
    var result: usize = 0;

    var opt_node = self.start_node;
    while (opt_node) |node| : (opt_node = node.next) {
        result += 1;
    }

    return result;
}

pub fn iterate(self: *const SinglyLinkedFIFO) SingleNode.Iterator {
    return .{ .current_node = self.start_node };
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
