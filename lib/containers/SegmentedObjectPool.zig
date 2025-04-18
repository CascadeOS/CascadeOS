// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// An object pool using a free list backed by a segmented array.
///
/// Each segment of the array is the same fixed size.
///
/// Unbounded and does not support freeing allocated segments.
///
/// Not thread-safe.
pub fn SegmentedObjectPool(
    comptime T: type,
    comptime segment_size: core.Size,
    /// Must return `segment_size` sized buffers.
    comptime allocateSegmentBackingMemory: fn () error{SegmentAllocationFailed}![]u8,
) type {
    return struct {
        free_list: containers.SinglyLinkedLIFO = .{},

        const Self = @This();

        const objects_per_segment: usize = core.Size.of(Object).amountToCover(segment_size);

        /// Get an object from the pool.
        pub fn get(self: *Self) error{SegmentAllocationFailed}!*T {
            const node = blk: while (true) {
                if (self.free_list.pop()) |node| {
                    @branchHint(.likely);
                    break :blk node;
                }

                try self.allocateNewSegment();
            };

            const obj: *Object = @ptrCast(node);

            if (core.is_debug) obj.* = undefined;

            return @ptrCast(@alignCast(&obj.obj));
        }

        /// Give an object back to the pool.
        ///
        /// **REQUIREMENTS**:
        /// - `object` must be allocated from the pool
        pub fn give(self: *Self, object: *T) void {
            const obj: *Object = @ptrCast(@alignCast(object));
            obj.* = .{ .node = .{} };
            self.free_list.push(&obj.node);
        }

        fn allocateNewSegment(self: *Self) error{SegmentAllocationFailed}!void {
            const bytes = try allocateSegmentBackingMemory();
            std.debug.assert(bytes.len == segment_size.value);

            const objects: [*]Object = @ptrCast(@alignCast(bytes.ptr));

            // build a linked list in the segment
            {
                var i: usize = 0;

                while (i < objects_per_segment) : (i += 1) {
                    const object = &objects[i];

                    if (i == objects_per_segment - 1) {
                        object.* = .{ .node = .{} };
                    } else {
                        object.* = .{ .node = .{ .next = &objects[i + 1].node } };
                    }
                }
            }

            self.free_list.pushList(&objects[0].node, &objects[objects_per_segment - 1].node);
        }

        const Object = extern union {
            node: containers.SingleNode,
            obj: [@sizeOf(T)]u8 align(@alignOf(T)),
        };

        comptime {
            if (@sizeOf(T) == 0) @compileError("zero sized types are unsupported");
            if (segment_size.lessThan(core.Size.of(T))) {
                @compileError("'" ++ @typeName(T) ++ "' is larger than the segment_size");
            }

            if (@sizeOf(T) > @sizeOf(Object) or @alignOf(T) > @alignOf(Object)) {
                @compileError("somehow Object and '" ++ @typeName(T) ++ " have incompatible memory layouts");
            }
        }
    };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const containers = @import("containers");

const builtin = @import("builtin");
