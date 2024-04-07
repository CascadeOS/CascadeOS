// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Singly linked LIFO (last in first out).

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const SingleNode = containers.SingleNode;

const SinglyLinkedLIFO = @This();

start_node: ?*SingleNode = null,

pub fn isEmpty(self: SinglyLinkedLIFO) bool {
    return self.start_node == null;
}

pub fn push(self: *SinglyLinkedLIFO, node: *SingleNode) void {
    core.debugAssert(node.next == null);

    if (self.start_node) |start| {
        node.next = start;
        self.start_node = node;
    } else {
        self.start_node = node;
    }
}

pub fn pop(self: *SinglyLinkedLIFO) ?*SingleNode {
    const node = self.start_node orelse return null;

    self.start_node = node.next;

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
