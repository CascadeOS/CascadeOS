// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Singly linked FIFO (first in first out).

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const SingleNode = containers.SingleNode;

const SinglyLinkedFIFO = @This();

start_node: ?*SingleNode = null,
end_node: ?*SingleNode = null,

pub fn isEmpty(self: SinglyLinkedFIFO) bool {
    return self.start_node == null;
}

pub fn push(self: *SinglyLinkedFIFO, node: *SingleNode) void {
    core.debugAssert(node.next == null);

    if (self.end_node) |end| {
        core.debugAssert(self.start_node != null);

        end.next = node;
        self.end_node = node;
    } else {
        self.start_node = node;
        self.end_node = node;
    }
}

pub fn pop(self: *SinglyLinkedFIFO) ?*SingleNode {
    const node = self.start_node orelse return null;
    core.debugAssert(self.end_node != null);

    if (self.start_node == self.end_node) {
        core.debugAssert(node.next == null);
        self.start_node = null;
        self.end_node = null;
    } else {
        self.start_node = node.next;
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
