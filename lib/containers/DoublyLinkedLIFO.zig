// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Doubly linked LIFO (last in first out).
//!
//! Not thread-safe.

const DoublyLinkedLIFO = @This();

start_node: ?*DoubleNode,
end_node: ?*DoubleNode,

pub const empty: DoublyLinkedLIFO = .{
    .start_node = null,
    .end_node = null,
};

pub fn isEmpty(self: *const DoublyLinkedLIFO) bool {
    return self.start_node == null;
}

pub fn peek(self: *const DoublyLinkedLIFO) ?*DoubleNode {
    return self.start_node;
}

pub fn remove(self: *DoublyLinkedLIFO, node: *DoubleNode) void {
    if (node.next) |next| next.previous = node.previous;
    if (node.previous) |previous| previous.next = node.next;
    if (self.start_node == node) self.start_node = node.next;
    if (self.end_node == node) self.end_node = node.previous;
}

pub fn push(self: *DoublyLinkedLIFO, node: *DoubleNode) void {
    if (self.start_node) |start| {
        std.debug.assert(self.end_node != null);
        node.next = start;
        start.previous = node;
    } else {
        self.end_node = node;
    }

    self.start_node = node;
}

pub fn pop(self: *DoublyLinkedLIFO) ?*DoubleNode {
    const node = self.start_node orelse return null;
    std.debug.assert(self.end_node != null);

    if (self.start_node == self.end_node) {
        std.debug.assert(node.previous == null);
        std.debug.assert(node.next == null);
        self.start_node = null;
        self.end_node = null;
    } else {
        if (node.next) |next| {
            std.debug.assert(next.previous == node);
            next.previous = null;
        }
        self.start_node = node.next;
        node.* = .empty;
    }

    return node;
}

pub fn iterate(self: DoublyLinkedLIFO, direction: core.Direction) DoubleNode.Iterator {
    return .{ .direction = direction, .current_node = self.start_node };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const DoubleNode = containers.DoubleNode;
