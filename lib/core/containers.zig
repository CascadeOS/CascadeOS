// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// A singly linked FIFO (first in first out).
///
/// Uses the node type `std.SinglyLinkedList.Node` to allow the same node to be used in multiple list implementations.
///
/// Any functions on `std.SinglyLinkedList.Node` should not be called on any nodes in the list as they will not
/// correctly update the list.
pub const FIFO = struct {
    first_node: ?*Node = null,
    last_node: ?*Node = null,

    pub fn isEmpty(fifo: *const FIFO) bool {
        return fifo.first_node == null;
    }

    /// Removes the first node from and returns it.
    pub fn pop(fifo: *FIFO) ?*Node {
        const node = fifo.first_node orelse return null;
        std.debug.assert(fifo.last_node != null);

        if (node == fifo.last_node) {
            std.debug.assert(node.next == null);
            fifo.first_node = null;
            fifo.last_node = null;
        } else {
            fifo.first_node = node.next;
            node.next = null;
        }

        return node;
    }

    /// Append a node to the end.
    pub fn append(fifo: *FIFO, node: *Node) void {
        std.debug.assert(node.next == null);

        if (fifo.last_node) |last| {
            std.debug.assert(fifo.first_node != null);
            last.next = node;
        } else {
            fifo.first_node = node;
        }

        fifo.last_node = node;
    }
};

/// An atomic singly linked list.
///
/// Uses the node type `std.SinglyLinkedList.Node` to allow the same node to be used in multiple list implementations.
///
/// Any functions on `std.SinglyLinkedList.Node` should not be called on any nodes in the list as they are not atomic.
pub const AtomicSinglyLinkedList = struct {
    first: std.atomic.Value(?*Node) = .init(null),

    /// Removes the first node from the list and returns it.
    pub fn popFirst(atomic_singly_linked_list: *AtomicSinglyLinkedList) ?*Node {
        var opt_first = atomic_singly_linked_list.first.load(.monotonic);

        while (opt_first) |first| {
            if (atomic_singly_linked_list.first.cmpxchgWeak(
                opt_first,
                first.next,
                .acq_rel,
                .monotonic,
            )) |new_first| {
                opt_first = new_first;
                continue;
            }

            first.next = null;
            return first;
        }

        return null;
    }

    /// Prepend a node to the front of the list.
    pub fn prepend(atomic_singly_linked_list: *AtomicSinglyLinkedList, new_node: *Node) void {
        atomic_singly_linked_list.prependList(new_node, new_node);
    }

    /// Prepend a linked list of nodes to the front of the list.
    ///
    /// The list is expected to be already linked correctly with `first_node` as the first node and `last_node` as the
    /// last node.
    ///
    /// `first_node` and `last_node` can be the same node.
    pub fn prependList(atomic_singly_linked_list: *AtomicSinglyLinkedList, first_node: *Node, last_node: *Node) void {
        var opt_first = atomic_singly_linked_list.first.load(.monotonic);

        while (true) {
            last_node.next = opt_first;

            if (atomic_singly_linked_list.first.cmpxchgWeak(
                opt_first,
                first_node,
                .acq_rel,
                .monotonic,
            )) |new_first| {
                opt_first = new_first;
                continue;
            }

            return;
        }
    }
};

test AtomicSinglyLinkedList {
    const NODE_COUNT = 10;

    var lifo: AtomicSinglyLinkedList = .{};

    // starts empty
    try std.testing.expect(lifo.first.load(.monotonic) == null);

    var nodes: [NODE_COUNT]Node = @splat(.{});

    for (&nodes) |*node| {
        // add node to the front of the list
        lifo.prepend(node);
        try std.testing.expect(lifo.first.load(.monotonic) != null);

        // popping the node should return the node just added
        const first_node = lifo.popFirst() orelse return error.NonEmptyListHasNoNode;
        try std.testing.expect(first_node == node);

        // add the popped node back to the list
        lifo.prepend(node);
    }

    // nodes are popped in the opposite order they were pushed
    var i: usize = NODE_COUNT;
    while (i > 0) {
        i -= 1;

        const node = lifo.popFirst() orelse return error.ExpectedNode;

        try std.testing.expect(node == &nodes[i]);
    }

    // list is empty again
    try std.testing.expect(lifo.first.load(.monotonic) == null);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const Node = std.SinglyLinkedList.Node;
