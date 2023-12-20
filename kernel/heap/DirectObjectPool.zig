// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

/// A pool of objects that are allocated within the direct map.
///
/// Due to using the direct map this pool requires no virtual address space management.
pub fn DirectObjectPool(
    comptime T: type,
    comptime log_scope: @Type(.EnumLiteral),
) type {
    return struct {
        first_free: ?*Object = null,

        /// `true` when more objects are being allocated
        ///
        /// **REQUIREMENTS**:
        ///  - All accesses to this field must be atomic
        acquire_in_progress: bool = false,

        number_of_free_objects: usize = 0,

        const Self = @This();

        const objects_per_page: usize = core.Size.of(T).amountToCover(kernel.arch.paging.standard_page_size);
        const log = kernel.debug.log.scoped(log_scope);

        /// Get an object from the pool.
        pub fn get(self: *Self) error{OutOfMemory}!*T {
            var opt_first_free = @atomicLoad(?*Object, &self.first_free, .Acquire);

            while (true) {
                const first_free: *Object = opt_first_free orelse {
                    // TODO: per branch cold

                    // we are out of objects
                    const interrupt_guard = kernel.arch.interrupts.interruptGuard();
                    defer interrupt_guard.release();

                    if (@cmpxchgStrong(
                        bool,
                        &self.acquire_in_progress,
                        false,
                        true,
                        .AcqRel,
                        .Acquire,
                    ) != null) {
                        opt_first_free = @atomicLoad(?*Object, &self.first_free, .Acquire);
                        if (opt_first_free != null) continue;

                        // we are responsible for allocating more objects
                        log.debug("no objects, acquiring more", .{});
                        _ = try self.getMoreObjects();
                    }

                    opt_first_free = @atomicLoad(?*Object, &self.first_free, .Acquire);
                    continue;
                };

                const next_free = first_free.chunk.ptr;

                if (@cmpxchgStrong(
                    ?*Object,
                    &self.first_free,
                    opt_first_free,
                    next_free,
                    .AcqRel,
                    .Acquire,
                )) |new_first_free| {
                    opt_first_free = new_first_free;
                    continue;
                }

                // Decrement `number_of_free_objects`
                const number_free = @atomicRmw(usize, &self.number_of_free_objects, .Sub, 1, .AcqRel) - 1;

                log.debug("given object - amount free: {}", .{number_free});
                return @as(*T, @ptrCast(first_free));
            }
        }

        /// Give an object back to the pool.
        ///
        /// **REQUIREMENTS**:
        /// - `object` must be allocated from the pool
        pub inline fn give(self: *Self, object: *T) void {
            const ptr: *Object = @ptrCast(object);
            self.giveImpl(ptr, ptr, 1);
        }

        fn giveImpl(self: *Self, first_obj: *Object, last_obj: *Object, count: usize) void {
            var first_free = @atomicLoad(?*Object, &self.first_free, .Acquire);

            while (true) {
                last_obj.chunk = .{ .ptr = first_free };

                if (@cmpxchgStrong(
                    ?*Object,
                    &self.first_free,
                    first_free,
                    first_obj,
                    .AcqRel,
                    .Acquire,
                )) |new_first_free| {
                    first_free = new_first_free;
                    continue;
                }

                // Increment `number_of_free_objects`
                const number_free = @atomicRmw(
                    usize,
                    &self.number_of_free_objects,
                    .Add,
                    count,
                    .AcqRel,
                ) + count;

                if (count > 1) {
                    log.debug("received {} objects - amount free: {}", .{ count, number_free });
                } else {
                    log.debug("received object - amount free: {}", .{number_free});
                }

                return;
            }
        }

        fn getMoreObjects(self: *Self) error{OutOfMemory}!void {
            const page = kernel.memory.physical.allocatePage() orelse return error.OutOfMemory;
            const direct_map_range = page.toDirectMap();

            const objects = direct_map_range.address.toPtr([*]Object)[0..objects_per_page];

            // build up the linked list
            {
                var previous: ?*Object = null;
                var i: usize = objects.len - 1;

                while (true) : (i -= 1) {
                    objects[i] = .{
                        .chunk = .{ .ptr = previous },
                    };
                    previous = &objects[i];
                    if (i == 0) break;
                }
            }

            self.giveImpl(&objects[0], &objects[objects.len - 1], objects.len);
        }

        const Object = extern struct {
            const TUnion = extern union {
                ptr: ?*Object,
                obj: [@sizeOf(T)]u8 align(@alignOf(T)),
            };

            chunk: TUnion,
        };

        comptime {
            if (@sizeOf(T) == 0) @compileError("zero sized types are unsupported");
            if (kernel.arch.paging.standard_page_size.lessThan(core.Size.of(T))) {
                @compileError("'" ++ @typeName(T) ++ "' is larger than a standard page size");
            }

            if (@sizeOf(T) != @sizeOf(Object) or @alignOf(T) != @alignOf(Object)) {
                @compileError("somehow Object and '" ++ @typeName(T) ++ " have different memory layouts");
            }
        }
    };
}
