// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Doubly linked FIFO (first in first out).
//!
//! Not thread-safe.

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const DoubleNode = containers.DoubleNode;

const DoublyLinkedLIFO = @This();

start_node: ?*DoubleNode = null,
end_node: ?*DoubleNode = null,

pub fn isEmpty(self: DoublyLinkedLIFO) bool {
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
    std.debug.assert(node.previous == null);
    std.debug.assert(node.next == null);

    if (self.start_node) |start| {
        std.debug.assert(self.end_node != null);
        node.next = start;
        start.previous = node;
        self.start_node = node;
    } else {
        self.start_node = node;
        self.end_node = node;
    }
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
        node.previous = null;
        node.next = null;
    }

    return node;
}

pub fn iterate(self: DoublyLinkedLIFO, direction: core.Direction) DoubleNode.Iterator {
    return .{ .direction = direction, .current_node = self.start_node };
}

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
