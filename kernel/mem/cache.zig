// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A slab based cache.
//!
//! Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
//!

// TODO: use `core.Size`

pub const ConstructorError = error{ObjectConstructionFailed};
pub const Name = std.BoundedArray(u8, kernel.config.cache_name_length);

pub fn Cache(
    comptime T: type,
    comptime constructor: ?fn (object: *T, current_task: *kernel.Task) ConstructorError!void,
    comptime destructor: ?fn (object: *T, current_task: *kernel.Task) void,
) type {
    return struct {
        raw_cache: RawCache,

        const CacheT = @This();

        pub const InitOptions = struct {
            name: Name,

            /// Should the last available slab be deallocated when it is unused?
            deallocate_last_available_slab: bool = false,

            /// Should slabs be allocated from the heap?
            ///
            /// This should only be false for caches used as part of `ResourceArena`/`RawCache` implementation.
            ///
            /// Only valid for small object caches.
            allocate_slabs_from_heap: bool = true,
        };

        /// Initialize the cache.
        pub fn init(
            cache: *CacheT,
            options: InitOptions,
        ) void {
            cache.* = .{
                .raw_cache = undefined,
            };

            cache.raw_cache.init(.{
                .name = options.name,
                .size = @sizeOf(T),
                .alignment = .fromByteUnits(@alignOf(T)),
                .constructor = if (constructor) |con|
                    struct {
                        fn innerConstructor(object: []u8, current_task: *kernel.Task) ConstructorError!void {
                            try con(@ptrCast(@alignCast(object)), current_task);
                        }
                    }.innerConstructor
                else
                    null,
                .destructor = if (destructor) |des|
                    struct {
                        fn innerDestructor(object: []u8, current_task: *kernel.Task) void {
                            des(@ptrCast(@alignCast(object)), current_task);
                        }
                    }.innerDestructor
                else
                    null,
                .deallocate_last_available_slab = options.deallocate_last_available_slab,
                .allocate_slabs_from_heap = options.allocate_slabs_from_heap,
            });
        }

        /// Deinitialize the cache.
        ///
        /// All objects must have been freed before calling this.
        pub fn deinit(cache: *CacheT, current_task: *kernel.Task) void {
            cache.raw_cache.deinit(current_task);
            cache.* = undefined;
        }

        pub fn name(cache: *const CacheT) []const u8 {
            return cache.raw_cache.name();
        }

        /// Allocate an object from the cache.
        pub fn allocate(cache: *CacheT, current_task: *kernel.Task) RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try cache.raw_cache.allocate(current_task)));
        }

        /// Allocate multiple objects from the cache.
        ///
        /// The length of `object_buffer` must be less than or equal to `max_count`.
        pub fn allocateMany(
            cache: *CacheT,
            current_task: *kernel.Task,
            comptime max_count: usize, // TODO: is there a better way than this?
            objects: []*T,
        ) RawCache.AllocateError!void {
            std.debug.assert(objects.len > 0);
            std.debug.assert(objects.len <= max_count);

            var raw_object_buffer: [max_count][]u8 = undefined;
            const raw_objects = raw_object_buffer[0..objects.len];

            try cache.raw_cache.allocateMany(current_task, raw_objects);

            for (objects, raw_objects) |*object, raw_object| {
                object.* = @ptrCast(@alignCast(raw_object));
            }
        }

        /// Free an object back to the cache.
        pub fn free(cache: *CacheT, current_task: *kernel.Task, object: *T) void {
            cache.raw_cache.free(current_task, std.mem.asBytes(object));
        }

        /// Free multiple objects back to the cache.
        ///
        /// The length of `objects` must be less than or equal to `max_count`.
        pub fn freeMany(
            cache: *CacheT,
            current_task: *kernel.Task,
            comptime max_count: usize, // TODO: is there a better way than this?
            objects: []const *T,
        ) void {
            std.debug.assert(objects.len > 0);
            std.debug.assert(objects.len <= max_count);

            var raw_object_buffer: [max_count][]u8 = undefined;
            const raw_objects = raw_object_buffer[0..objects.len];

            for (raw_objects, objects) |*raw_object, object| {
                raw_object.* = std.mem.asBytes(object);
            }

            cache.raw_cache.freeMany(current_task, raw_objects);
        }
    };
}

pub const RawCache = struct {
    _name: Name,

    lock: kernel.sync.TicketSpinLock,

    size_class: Size,

    object_size: usize,

    /// The size of the object with sufficient padding to ensure alignment.
    ///
    /// If the object is small additional space for the free list node is added.
    effective_object_size: usize,

    objects_per_slab: usize,

    /// Should the last available slab be deallocated when it is unused?
    deallocate_last_available_slab: bool,

    /// Should slabs be allocated from the heap?
    ///
    /// This should only be false for caches used as part of `ResourceArena`/`RawCache` implementation.
    ///
    /// `false` is only valid for small object caches.
    allocate_slabs_from_heap: bool,

    constructor: ?*const fn (object: []u8, current_task: *kernel.Task) ConstructorError!void,
    destructor: ?*const fn (object: []u8, current_task: *kernel.Task) void,

    available_slabs: DoublyLinkedList,
    full_slabs: DoublyLinkedList,

    /// Used to ensure that only one thread allocates a new slab at a time.
    allocate_mutex: kernel.sync.Mutex,

    const Size = union(enum) {
        small,
        large: Large,

        const Large = struct {
            object_lookup: std.AutoHashMap(usize, *LargeObject),
        };
    };

    pub const InitOptions = struct {
        name: Name,

        size: usize,
        alignment: std.mem.Alignment,

        constructor: ?*const fn (object: []u8, current_task: *kernel.Task) ConstructorError!void = null,
        destructor: ?*const fn (object: []u8, current_task: *kernel.Task) void = null,

        /// Should the last available slab be deallocated when it is unused?
        deallocate_last_available_slab: bool = false,

        /// Should slabs be allocated from the heap?
        ///
        /// This should only be false for caches used as part of `ResourceArena`/`RawCache` implementation.
        ///
        /// `false` is only valid for small object caches.
        allocate_slabs_from_heap: bool = true,
    };

    /// Initialize the cache.
    pub fn init(
        raw_cache: *RawCache,
        options: InitOptions,
    ) void {
        log.debug("{s}: init with size {} and alignment {}", .{
            options.name.constSlice(),
            core.Size.from(options.size, .byte),
            options.alignment.toByteUnits(),
        });

        const is_small = isSmallObject(options.size, options.alignment);

        if (!options.allocate_slabs_from_heap and !is_small) {
            @panic("only small object caches can have `allocate_slabs_from_heap` set to false");
        }

        const effective_object_size = if (is_small)
            options.alignment.forward(single_node_alignment.forward(options.size) + @sizeOf(SinglyLinkedList.Node))
        else
            options.alignment.forward(options.size);

        const objects_per_slab = if (is_small)
            (kernel.arch.paging.standard_page_size.value - @sizeOf(Slab)) / effective_object_size
        else blk: {
            var candidate_large_objects_per_slab: usize = default_large_objects_per_slab;

            const initial_pages_for_allocation = kernel.arch.paging.standard_page_size.amountToCover(
                .from(candidate_large_objects_per_slab * effective_object_size, .byte),
            );

            while (true) {
                const next_pages_for_allocation = kernel.arch.paging.standard_page_size.amountToCover(
                    .from((candidate_large_objects_per_slab + 1) * effective_object_size, .byte),
                );

                if (next_pages_for_allocation != initial_pages_for_allocation) break;

                candidate_large_objects_per_slab += 1;
            }

            break :blk candidate_large_objects_per_slab;
        };

        raw_cache.* = .{
            ._name = options.name,
            .allocate_mutex = .{},
            .lock = .{},
            .object_size = options.size,
            .effective_object_size = effective_object_size,
            .constructor = options.constructor,
            .destructor = options.destructor,
            .available_slabs = .{},
            .full_slabs = .{},
            .objects_per_slab = objects_per_slab,
            .deallocate_last_available_slab = options.deallocate_last_available_slab,
            .allocate_slabs_from_heap = options.allocate_slabs_from_heap,
            .size_class = if (is_small)
                .small
            else
                .{
                    .large = .{
                        .object_lookup = .init(kernel.mem.heap.allocator),
                    },
                },
        };
    }

    /// Deinitialize the cache.
    ///
    /// All objects must have been freed before calling this.
    pub fn deinit(raw_cache: *RawCache, current_task: *kernel.Task) void {
        log.debug("{s}: deinit", .{raw_cache.name()});

        if (raw_cache.full_slabs.first != null) @panic("full slabs not empty");

        switch (raw_cache.size_class) {
            .small => {},
            .large => |large| {
                if (large.object_lookup.count() != 0) @panic("large object lookup not empty");
            },
        }

        while (raw_cache.available_slabs.pop()) |node| {
            const slab: *Slab = @fieldParentPtr("linkage", node);
            if (slab.allocated_objects != 0) @panic("slab not empty");

            raw_cache.deallocateSlab(current_task, slab);
        }

        raw_cache.* = undefined;
    }

    pub fn name(raw_cache: *const RawCache) []const u8 {
        return raw_cache._name.constSlice();
    }

    pub const AllocateError = error{
        ObjectConstructionFailed,

        SlabAllocationFailed,

        /// Failed to allocate a large object.
        ///
        /// Only possible if adding the object to the large object lookup failed.
        LargeObjectAllocationFailed,
    };

    /// Allocate an object from the cache.
    pub fn allocate(raw_cache: *RawCache, current_task: *kernel.Task) AllocateError![]u8 {
        var object_buffer: [1][]u8 = undefined;
        try raw_cache.allocateMany(current_task, &object_buffer);
        return object_buffer[0];
    }

    /// Allocate multiple objects from the cache.
    pub fn allocateMany(raw_cache: *RawCache, current_task: *kernel.Task, objects: [][]u8) AllocateError!void {
        std.debug.assert(objects.len > 0);

        log.verbose("{s}: allocating {} objects", .{ raw_cache.name(), objects.len });

        var allocated_objects: std.ArrayListUnmanaged([]u8) = .initBuffer(objects);
        errdefer raw_cache.freeMany(current_task, allocated_objects.items);

        raw_cache.lock.lock(current_task);

        var objects_left = objects.len;

        while (objects_left > 0) {
            const slab: *Slab = if (raw_cache.available_slabs.first) |slab_node|
                @fieldParentPtr("linkage", slab_node)
            else blk: {
                @branchHint(.unlikely);
                break :blk try raw_cache.allocateSlab(current_task);
            };

            while (objects_left > 0) {
                defer objects_left -= 1;

                const object_node = slab.objects.popFirst() orelse
                    @panic("empty slab on available list");
                slab.allocated_objects += 1;

                switch (raw_cache.size_class) {
                    .small => {
                        const object_node_ptr: [*]u8 = @ptrCast(object_node);
                        const object_ptr = object_node_ptr - single_node_alignment.forward(raw_cache.object_size);
                        allocated_objects.appendAssumeCapacity(object_ptr[0..raw_cache.object_size]);
                    },
                    .large => |*large| {
                        const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                        large.object_lookup.putNoClobber(@intFromPtr(large_object.object.ptr), large_object) catch {
                            @branchHint(.cold);

                            slab.objects.prepend(object_node);
                            slab.allocated_objects -= 1;

                            log.warn("{s}: failed to add large object to lookup table", .{raw_cache.name()});

                            return error.LargeObjectAllocationFailed;
                        };

                        allocated_objects.appendAssumeCapacity(large_object.object);
                    },
                }

                if (slab.allocated_objects == raw_cache.objects_per_slab) {
                    @branchHint(.unlikely);
                    raw_cache.available_slabs.remove(&slab.linkage);
                    raw_cache.full_slabs.append(&slab.linkage);

                    break;
                }
            }
        }

        raw_cache.lock.unlock(current_task);
    }

    /// Allocates a new slab.
    ///
    /// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
    fn allocateSlab(raw_cache: *RawCache, current_task: *kernel.Task) AllocateError!*Slab {
        errdefer log.warn("{s}: failed to allocate slab", .{raw_cache.name()});

        raw_cache.lock.unlock(current_task);

        raw_cache.allocate_mutex.lock(current_task);
        defer raw_cache.allocate_mutex.unlock(current_task);

        // optimistically check for an available slab without locking, if there is one lock and check again
        if (raw_cache.available_slabs.first != null) {
            raw_cache.lock.lock(current_task);

            if (raw_cache.available_slabs.first) |slab_node| {
                // there is an available slab now, use it without allocating a new one
                return @fieldParentPtr("linkage", slab_node);
            }

            raw_cache.lock.unlock(current_task);
        }

        log.debug("{s}: allocating slab", .{raw_cache.name()});

        const slab = switch (raw_cache.size_class) {
            .small => slab: {
                const slab_base_ptr: [*]u8 = if (raw_cache.allocate_slabs_from_heap) slab_base_ptr: {
                    const slab_allocation = kernel.mem.heap.globals.heap_page_arena.allocate(
                        current_task,
                        kernel.arch.paging.standard_page_size.value,
                        .instant_fit,
                    ) catch return AllocateError.SlabAllocationFailed;
                    std.debug.assert(slab_allocation.len == kernel.arch.paging.standard_page_size.value);
                    break :slab_base_ptr @ptrFromInt(slab_allocation.base);
                } else slab_base_ptr: {
                    const frame = kernel.mem.phys.allocator.allocate() catch
                        return AllocateError.SlabAllocationFailed;
                    break :slab_base_ptr kernel.mem.directMapFromPhysical(frame.baseAddress()).toPtr([*]u8);
                };
                errdefer if (raw_cache.allocate_slabs_from_heap)
                    kernel.mem.heap.globals.heap_page_arena.deallocate(current_task, .{
                        .base = @intFromPtr(slab_base_ptr),
                        .len = kernel.arch.paging.standard_page_size.value,
                    })
                else {
                    var deallocate_frame_list: kernel.mem.phys.FrameList = .{};
                    deallocate_frame_list.push(.fromAddress(
                        kernel.mem.physicalFromDirectMap(.fromPtr(slab_base_ptr)) catch unreachable,
                    ));
                    kernel.mem.phys.allocator.deallocate(deallocate_frame_list);
                };

                const slab: *Slab = @alignCast(@ptrCast(
                    slab_base_ptr + kernel.arch.paging.standard_page_size.value - @sizeOf(Slab),
                ));
                slab.* = .{
                    .large_object_allocation = undefined,
                };

                for (0..raw_cache.objects_per_slab) |i| {
                    const object_ptr = slab_base_ptr + (i * raw_cache.effective_object_size);

                    if (raw_cache.constructor) |constructor| {
                        try constructor(object_ptr[0..raw_cache.object_size], current_task);
                    }

                    const object_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                        object_ptr + single_node_alignment.forward(raw_cache.object_size),
                    ));

                    slab.objects.prepend(object_node);
                }

                break :slab slab;
            },
            .large => slab: {
                const large_object_allocation = kernel.mem.heap.globals.heap_page_arena.allocate(
                    current_task,
                    raw_cache.effective_object_size * raw_cache.objects_per_slab,
                    .instant_fit,
                ) catch return AllocateError.SlabAllocationFailed;
                errdefer kernel.mem.heap.globals.heap_page_arena.deallocate(current_task, large_object_allocation);

                const slab = try globals.slab_cache.allocate(current_task);
                slab.* = .{
                    .large_object_allocation = large_object_allocation,
                };

                errdefer {
                    while (slab.objects.popFirst()) |object_node| {
                        const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                        if (raw_cache.destructor) |destructor| {
                            destructor(large_object.object, current_task);
                        }

                        globals.large_object_cache.free(current_task, large_object);
                    }

                    globals.slab_cache.free(current_task, slab);
                }

                const objects_base: [*]u8 = @ptrFromInt(large_object_allocation.base);

                for (0..raw_cache.objects_per_slab) |i| {
                    const large_object = try globals.large_object_cache.allocate(current_task);
                    errdefer globals.large_object_cache.free(current_task, large_object);

                    const object: []u8 = (objects_base + (i * raw_cache.effective_object_size))[0..raw_cache.object_size];

                    large_object.* = .{
                        .object = object,
                        .slab = slab,
                        .node = .{},
                    };

                    if (raw_cache.constructor) |constructor| {
                        try constructor(object, current_task);
                    }

                    slab.objects.prepend(&large_object.node);
                }

                break :slab slab;
            },
        };

        raw_cache.lock.lock(current_task);

        raw_cache.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Free an object back to the cache.
    pub fn free(raw_cache: *RawCache, current_task: *kernel.Task, object: []u8) void {
        raw_cache.freeMany(current_task, &.{object});
    }

    /// Free many objects back to the cache.
    pub fn freeMany(raw_cache: *RawCache, current_task: *kernel.Task, objects: []const []u8) void {
        std.debug.assert(objects.len > 0);

        log.verbose("{s}: freeing {} objects", .{ raw_cache.name(), objects.len });

        raw_cache.lock.lock(current_task);
        defer raw_cache.lock.unlock(current_task);

        for (objects) |object| {
            const slab, const object_node = switch (raw_cache.size_class) {
                .small => blk: {
                    const page_start = std.mem.alignBackward(
                        usize,
                        @intFromPtr(object.ptr),
                        kernel.arch.paging.standard_page_size.value,
                    );

                    const slab: *Slab = @ptrFromInt(page_start + kernel.arch.paging.standard_page_size.value - @sizeOf(Slab));

                    const object_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                        object.ptr + single_node_alignment.forward(raw_cache.object_size),
                    ));

                    break :blk .{ slab, object_node };
                },
                .large => |*large| blk: {
                    const large_object = large.object_lookup.get(@intFromPtr(object.ptr)) orelse {
                        @panic("large object not found in object lookup");
                    };

                    _ = large.object_lookup.remove(@intFromPtr(object.ptr));

                    break :blk .{ large_object.slab, &large_object.node };
                },
            };

            if (slab.allocated_objects == raw_cache.objects_per_slab) {
                // slab was previously full, move it to available list
                @branchHint(.unlikely);
                raw_cache.full_slabs.remove(&slab.linkage);
                raw_cache.available_slabs.append(&slab.linkage);
            }

            slab.objects.prepend(object_node);
            slab.allocated_objects -= 1;

            if (slab.allocated_objects != 0) {
                // slab is still in use
                @branchHint(.likely);
                continue;
            }

            // slab is unused

            if (!raw_cache.deallocate_last_available_slab) {
                if (raw_cache.available_slabs.first == raw_cache.available_slabs.last) {
                    @branchHint(.unlikely);

                    std.debug.assert(raw_cache.available_slabs.first == &slab.linkage);

                    // this is the last available slab so we leave it in the available list and don't deallocate it

                    continue;
                }
            }

            // slab is unused remove it from available list and deallocate it
            raw_cache.available_slabs.remove(&slab.linkage);

            raw_cache.deallocateSlab(current_task, slab);
        }
    }

    /// Deallocate a slab.
    ///
    /// The cache's lock must *not* be held when this is called.
    fn deallocateSlab(raw_cache: *RawCache, current_task: *kernel.Task, slab: *Slab) void {
        log.debug("{s}: deallocating slab", .{raw_cache.name()});

        switch (raw_cache.size_class) {
            .small => {
                const slab_base_ptr: [*]u8 =
                    @as([*]u8, @ptrCast(slab)) + @sizeOf(Slab) - kernel.arch.paging.standard_page_size.value;

                if (raw_cache.destructor) |destructor| {
                    for (0..raw_cache.objects_per_slab) |i| {
                        const object_ptr = slab_base_ptr + (i * raw_cache.effective_object_size);
                        destructor(object_ptr[0..raw_cache.object_size], current_task);
                    }
                }

                if (raw_cache.allocate_slabs_from_heap) {
                    kernel.mem.heap.globals.heap_page_arena.deallocate(
                        current_task,
                        .{
                            .base = @intFromPtr(slab_base_ptr),
                            .len = kernel.arch.paging.standard_page_size.value,
                        },
                    );
                } else {
                    var deallocate_frame_list: kernel.mem.phys.FrameList = .{};
                    deallocate_frame_list.push(.fromAddress(
                        kernel.mem.physicalFromDirectMap(.fromPtr(slab_base_ptr)) catch unreachable,
                    ));
                    kernel.mem.phys.allocator.deallocate(deallocate_frame_list);
                }

                return;
            },
            .large => {
                while (slab.objects.popFirst()) |object_node| {
                    const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                    if (raw_cache.destructor) |destructor| {
                        destructor(large_object.object, current_task);
                    }

                    globals.large_object_cache.free(current_task, large_object);
                }

                kernel.mem.heap.globals.heap_page_arena.deallocate(current_task, slab.large_object_allocation);

                globals.slab_cache.free(current_task, slab);
            },
        }
    }

    const Slab = struct {
        linkage: DoublyLinkedList.Node = .{},
        objects: SinglyLinkedList = .{},
        allocated_objects: usize = 0,

        /// The allocation containing this slabs objects.
        ///
        /// Only set for large object slabs.
        large_object_allocation: kernel.mem.ResourceArena.Allocation,

        fn constructor(slab: *Slab) void {
            slab.* = .{};
        }
    };

    const LargeObject = struct {
        object: []u8,
        slab: *Slab,
        node: SinglyLinkedList.Node = .{},
    };

    const single_node_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(SinglyLinkedList.Node));
    const default_large_objects_per_slab = 16;
};

const small_object_size = kernel.arch.paging.standard_page_size.divideScalar(8);

pub fn isSmallObject(size: usize, alignment: std.mem.Alignment) bool {
    return alignment.forward(size) <= small_object_size.value;
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var slab_cache: Cache(RawCache.Slab, null, null) = undefined;

    /// Initialized during `init.initializeCaches`.
    var large_object_cache: Cache(RawCache.LargeObject, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches() !void {
        globals.slab_cache.init(.{
            .name = try .fromSlice("slab"),
            .allocate_slabs_from_heap = false,
        });

        globals.large_object_cache.init(.{
            .name = try .fromSlice("large object"),
            .allocate_slabs_from_heap = false,
        });
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;
const log = kernel.debug.log.scoped(.cache);
