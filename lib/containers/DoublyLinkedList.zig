// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Doubly linked list.
//!
//! Not thread-safe.

// TODO: add tests

const DoublyLinkedList = @This();

first: ?*DoubleNode,
last: ?*DoubleNode,

pub const empty: DoublyLinkedList = .{
    .first = null,
    .last = null,
};

/// Insert a node at the beginning of the list.
pub fn prepend(doubly_linked_list: *DoublyLinkedList, node: *DoubleNode) void {
    if (doubly_linked_list.first) |first| {
        doubly_linked_list.insertBefore(first, node);
    } else {
        doubly_linked_list.first = node;
        doubly_linked_list.last = node;
        node.* = .empty;
    }
}

/// Insert a node at the end of the list.
pub fn append(doubly_linked_list: *DoublyLinkedList, node: *DoubleNode) void {
    if (doubly_linked_list.last) |last| {
        doubly_linked_list.insertAfter(last, node);
    } else {
        doubly_linked_list.prepend(node);
    }
}

pub fn insertAfter(doubly_linked_list: *DoublyLinkedList, existing_node: *DoubleNode, new_node: *DoubleNode) void {
    new_node.previous.next = &existing_node.previous;
    if (existing_node.next.next) |next_node| {
        new_node.next.next = next_node;
        const next_double: *DoubleNode = .fromNextNode(next_node);
        next_double.previous.next = &new_node.previous;
    } else {
        new_node.next.next = null;
        doubly_linked_list.last = new_node;
    }
    existing_node.next.next = &new_node.next;
}

pub fn insertBefore(doubly_linked_list: *DoublyLinkedList, existing_node: *DoubleNode, new_node: *DoubleNode) void {
    new_node.next.next = &existing_node.next;
    if (existing_node.previous.next) |previous_node| {
        new_node.previous.next = previous_node;
        const previous_double: *DoubleNode = .fromPreviousNode(previous_node);
        previous_double.next.next = &new_node.next;
    } else {
        new_node.previous.next = null;
        doubly_linked_list.first = new_node;
    }
    existing_node.previous.next = &new_node.previous;
}

/// Remove the last node from the list and return it.
pub fn pop(doubly_linked_list: *DoublyLinkedList) ?*DoubleNode {
    const last = doubly_linked_list.last orelse return null;
    doubly_linked_list.remove(last);
    return last;
}

/// Remove the first node from the list and return it.
pub fn popFirst(doubly_linked_list: *DoublyLinkedList) ?*DoubleNode {
    const first = doubly_linked_list.first orelse return null;
    doubly_linked_list.remove(first);
    return first;
}

/// Remove a node from the list.
pub fn remove(doubly_linked_list: *DoublyLinkedList, node: *DoubleNode) void {
    if (node.previous.next) |previous_node| {
        const previous_double: *DoubleNode = .fromPreviousNode(previous_node);
        previous_double.next = node.next;
    } else {
        if (node.next.next) |next_node| {
            doubly_linked_list.first = .fromNextNode(next_node);
        } else {
            doubly_linked_list.first = null;
            doubly_linked_list.last = null;
            return;
        }
    }

    if (node.next.next) |next_node| {
        const next_double: *DoubleNode = .fromNextNode(next_node);
        next_double.previous = node.previous;
    } else {
        if (node.previous.next) |previous_node| {
            doubly_linked_list.last = .fromPreviousNode(previous_node);
        } else {
            doubly_linked_list.first = null;
            doubly_linked_list.last = null;
            return;
        }
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const DoubleNode = containers.DoubleNode;
