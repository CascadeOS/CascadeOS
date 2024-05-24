// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const builtin = @import("builtin");

/// A memory pool that allocates objects from the direct map.
///
/// Used only for objects that are required to implement virtual memory management.
///
/// Never frees the underlying memory.
pub fn DirectMapPool(
    comptime T: type,
    comptime log_scope: @Type(.EnumLiteral),
) type {
    return struct {
        lock: kernel.sync.TicketSpinLock = .{},
        available_items: containers.SinglyLinkedLIFO = .{},

        const log = kernel.log.scoped(log_scope);

        const Self = @This();

        pub const GetError = kernel.pmm.AllocateError;

        pub fn get(self: *Self) GetError!*T {
            const node = blk: {
                const held = self.lock.acquire();
                defer held.release();

                if (self.available_items.pop()) |item| break :blk item;

                try self.allocateMoreObjects();

                break :blk self.available_items.pop() orelse unreachable; // the list is not empty because we just allocated more objects
            };

            const item: *T = blk: {
                const object: *Object = @ptrCast(node);
                break :blk @ptrCast(@alignCast(&object.object_storage));
            };

            item.* = undefined;

            log.debug("provided item: {*}", .{item});

            return item;
        }

        fn allocateMoreObjects(self: *Self) !void {
            log.debug("allocating {d} more objects", .{objects_per_page});

            const objects = blk: {
                const physical_page = try kernel.pmm.allocatePage();
                const byte_slice = kernel.vmm
                    .directMapFromPhysical(physical_page.address)
                    .toPtr(*align(standard_page_size_bytes) [object_bytes_per_page]u8);
                break :blk std.mem.bytesAsSlice(Object, byte_slice);
            };
            core.debugAssert(objects.len == objects_per_page);

            var previous_object: *Object = &objects[0];

            for (objects[1..]) |*current_object| {
                previous_object.node = .{ .next = &current_object.node };
                previous_object = current_object;
            }

            // ensure the last object has a null next pointer
            previous_object.node = .{};

            self.available_items.pushList(
                &objects[0].node,
                &previous_object.node,
            );
        }

        pub fn give(self: *Self, item: *T) void {
            log.debug("received item: {*}", .{item});

            const held = self.lock.acquire();
            defer held.release();

            const object: *Object = @ptrCast(item);
            object.node = .{};
            self.available_items.push(&object.node);
        }

        const Object = extern union {
            object_storage: [@sizeOf(T)]u8 align(@alignOf(T)),
            node: containers.SingleNode,

            comptime {
                core.testing.expectSize(Object, @sizeOf(T));
                core.assert(@alignOf(Object) == @alignOf(T));
            }
        };

        const standard_page_size_bytes = kernel.arch.paging.standard_page_size.value;
        const objects_per_page = standard_page_size_bytes / @sizeOf(Object);
        const object_bytes_per_page = objects_per_page * @sizeOf(Object);

        comptime {
            core.assert(objects_per_page != 0);
            core.assert(@sizeOf(T) <= standard_page_size_bytes);
            core.assert(@alignOf(T) <= standard_page_size_bytes);
        }
    };
}
