// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Doubly linked FIFO (first in first out).

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

    self.start_node = null;
    self.end_node = null;
}

pub fn push(self: *DoublyLinkedLIFO, node: *DoubleNode) void {
    core.debugAssert(node.previous == null);
    core.debugAssert(node.next == null);

    if (self.start_node) |start| {
        core.debugAssert(self.end_node != null);
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
    core.debugAssert(self.end_node != null);

    if (self.start_node == self.end_node) {
        core.debugAssert(node.previous == null);
        core.debugAssert(node.next == null);
        self.start_node = null;
        self.end_node = null;
    } else {
        if (node.next) |next| {
            core.debugAssert(next.previous == node);
            next.previous = null;
        }
        self.start_node = node.next;
        node.previous = null;
        node.next = null;
    }

    return node;
}

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
