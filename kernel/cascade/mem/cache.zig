// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A slab based cache.
//!
//! Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
//!

// TODO: use `core.Size`

pub const ConstructorError = error{ObjectConstructionFailed};
pub const Name = core.containers.BoundedArray(u8, cascade.config.cache_name_length);

pub fn Cache(
    comptime T: type,
    comptime constructor: ?fn (object: *T, context: *cascade.Context) ConstructorError!void,
    comptime destructor: ?fn (object: *T, context: *cascade.Context) void,
) type {
    return struct {
        raw_cache: RawCache,

        const CacheT = @This();

        pub const InitOptions = struct {
            name: Name,

            /// What should happen to the last available slab when it is unused?
            last_slab: core.CleanupDecision = .keep,

            /// The source of slabs.
            ///
            /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
            ///
            /// `.pmm` is only valid for small object caches.
            slab_source: RawCache.InitOptions.SlabSource = .heap,
        };

        /// Initialize the cache.
        pub fn init(
            cache: *CacheT,
            context: *cascade.Context,
            options: InitOptions,
        ) void {
            cache.* = .{
                .raw_cache = undefined,
            };

            cache.raw_cache.init(context, .{
                .name = options.name,
                .size = @sizeOf(T),
                .alignment = .fromByteUnits(@alignOf(T)),
                .constructor = if (constructor) |con|
                    struct {
                        fn innerConstructor(object: []u8, inner_context: *cascade.Context) ConstructorError!void {
                            try con(@ptrCast(@alignCast(object)), inner_context);
                        }
                    }.innerConstructor
                else
                    null,
                .destructor = if (destructor) |des|
                    struct {
                        fn innerDestructor(object: []u8, inner_context: *cascade.Context) void {
                            des(@ptrCast(@alignCast(object)), inner_context);
                        }
                    }.innerDestructor
                else
                    null,
                .last_slab = options.last_slab,
                .slab_source = options.slab_source,
            });
        }

        /// Deinitialize the cache.
        ///
        /// All objects must have been deallocated before calling this.
        pub fn deinit(cache: *CacheT, context: *cascade.Context) void {
            cache.raw_cache.deinit(context);
            cache.* = undefined;
        }

        pub fn name(cache: *const CacheT) []const u8 {
            return cache.raw_cache.name();
        }

        /// Allocate an object from the cache.
        pub fn allocate(cache: *CacheT, context: *cascade.Context) RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try cache.raw_cache.allocate(context)));
        }

        /// Allocate multiple objects from the cache.
        ///
        /// The length of `object_buffer` must be less than or equal to `max_count`.
        pub fn allocateMany(
            cache: *CacheT,
            context: *cascade.Context,
            comptime max_count: usize, // TODO: is there a better way than this?
            objects: []*T,
        ) RawCache.AllocateError!void {
            std.debug.assert(objects.len > 0);
            std.debug.assert(objects.len <= max_count);

            var raw_object_buffer: [max_count][]u8 = undefined;
            const raw_objects = raw_object_buffer[0..objects.len];

            try cache.raw_cache.allocateMany(context, raw_objects);

            for (objects, raw_objects) |*object, raw_object| {
                object.* = @ptrCast(@alignCast(raw_object));
            }
        }

        /// Deallocate an object back to the cache.
        pub fn deallocate(cache: *CacheT, context: *cascade.Context, object: *T) void {
            cache.raw_cache.deallocate(context, std.mem.asBytes(object));
        }

        /// Deallocate multiple objects back to the cache.
        ///
        /// The length of `objects` must be less than or equal to `max_count`.
        pub fn deallocateMany(
            cache: *CacheT,
            context: *cascade.Context,
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

            cache.raw_cache.deallocateMany(context, raw_objects);
        }
    };
}

pub const RawCache = struct {
    _name: Name,

    lock: cascade.sync.Mutex,

    size_class: Size,

    object_size: usize,

    /// The size of the object with sufficient padding to ensure alignment.
    ///
    /// If the object is small additional space for the free list node is added.
    effective_object_size: usize,

    objects_per_slab: usize,

    /// What should happen to the last available slab when it is unused?
    last_slab: core.CleanupDecision = .keep,

    /// The source of slabs.
    ///
    /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
    ///
    /// `.pmm` is only valid for small object caches.
    slab_source: InitOptions.SlabSource = .heap,

    constructor: ?*const fn (object: []u8, context: *cascade.Context) ConstructorError!void,
    destructor: ?*const fn (object: []u8, context: *cascade.Context) void,

    available_slabs: std.DoublyLinkedList,
    full_slabs: std.DoublyLinkedList,

    /// Used to ensure that only one thread allocates a new slab at a time.
    allocate_mutex: cascade.sync.Mutex,

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

        constructor: ?*const fn (object: []u8, context: *cascade.Context) ConstructorError!void = null,
        destructor: ?*const fn (object: []u8, context: *cascade.Context) void = null,

        /// What should happen to the last available slab when it is unused?
        last_slab: core.CleanupDecision = .keep,

        /// The source of slabs.
        ///
        /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
        ///
        /// `.pmm` is only valid for small object caches.
        slab_source: SlabSource = .heap,

        pub const SlabSource = enum {
            heap,
            pmm,
        };
    };

    /// Initialize the cache.
    pub fn init(
        raw_cache: *RawCache,
        context: *cascade.Context,
        options: InitOptions,
    ) void {
        const is_small = isSmallObject(options.size, options.alignment);

        if (!is_small and options.slab_source == .pmm) {
            @panic("only small object caches can have `slab_source` set to `.pmm`");
        }

        const effective_object_size = if (is_small)
            sizeOfObjectWithNodeAppended(options.size, options.alignment)
        else
            options.alignment.forward(options.size);

        const objects_per_slab = if (is_small)
            (arch.paging.standard_page_size.value - @sizeOf(Slab)) / effective_object_size
        else blk: {
            var candidate_large_objects_per_slab: usize = default_large_objects_per_slab;

            const initial_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                .from(candidate_large_objects_per_slab * effective_object_size, .byte),
            );

            while (true) {
                const next_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                    .from((candidate_large_objects_per_slab + 1) * effective_object_size, .byte),
                );

                if (next_pages_for_allocation != initial_pages_for_allocation) break;

                candidate_large_objects_per_slab += 1;
            }

            break :blk candidate_large_objects_per_slab;
        };

        if (is_small) {
            log.debug(
                context,
                "{s}: init small object cache with effective size {f} (requested size {f} alignment {}) objects per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    core.Size.from(effective_object_size, .byte),
                    core.Size.from(options.size, .byte),
                    options.alignment.toByteUnits(),
                    objects_per_slab,
                    core.Size.from(effective_object_size * objects_per_slab, .byte),
                },
            );
        } else {
            log.debug(
                context,
                "{s}: init large object cache with effective size {f} (requested size {f} alignment {}) objects per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    core.Size.from(effective_object_size, .byte),
                    core.Size.from(options.size, .byte),
                    options.alignment.toByteUnits(),
                    objects_per_slab,
                    core.Size.from(effective_object_size * objects_per_slab, .byte),
                },
            );
        }

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
            .last_slab = options.last_slab,
            .slab_source = options.slab_source,
            .size_class = if (is_small)
                .small
            else
                .{
                    .large = .{
                        .object_lookup = .init(cascade.mem.heap.allocator),
                    },
                },
        };
    }

    /// Deinitialize the cache.
    ///
    /// All objects must have been deallocated before calling this.
    pub fn deinit(raw_cache: *RawCache, context: *cascade.Context) void {
        log.debug(context, "{s}: deinit", .{raw_cache.name()});

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

            raw_cache.deallocateSlab(context, slab);
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
    pub fn allocate(raw_cache: *RawCache, context: *cascade.Context) AllocateError![]u8 {
        var object_buffer: [1][]u8 = undefined;
        try raw_cache.allocateMany(context, &object_buffer);
        return object_buffer[0];
    }

    /// Allocate multiple objects from the cache.
    pub fn allocateMany(raw_cache: *RawCache, context: *cascade.Context, objects: [][]u8) AllocateError!void {
        std.debug.assert(objects.len > 0);

        log.verbose(context, "{s}: allocating {} objects", .{ raw_cache.name(), objects.len });

        var allocated_objects: std.ArrayListUnmanaged([]u8) = .initBuffer(objects);
        errdefer raw_cache.deallocateMany(context, allocated_objects.items);

        raw_cache.lock.lock(context);

        var objects_left = objects.len;

        while (objects_left > 0) {
            const slab: *Slab = if (raw_cache.available_slabs.first) |slab_node|
                @fieldParentPtr("linkage", slab_node)
            else blk: {
                @branchHint(.unlikely);
                break :blk try raw_cache.allocateSlab(context);
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

                            log.warn(context, "{s}: failed to add large object to lookup table", .{raw_cache.name()});

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

        raw_cache.lock.unlock(context);
    }

    /// Allocates a new slab.
    ///
    /// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
    fn allocateSlab(raw_cache: *RawCache, context: *cascade.Context) AllocateError!*Slab {
        errdefer log.warn(context, "{s}: failed to allocate slab", .{raw_cache.name()});

        raw_cache.lock.unlock(context);

        raw_cache.allocate_mutex.lock(context);
        defer raw_cache.allocate_mutex.unlock(context);

        // optimistically check for an available slab without locking, if there is one lock and check again
        if (raw_cache.available_slabs.first != null) {
            raw_cache.lock.lock(context);

            if (raw_cache.available_slabs.first) |slab_node| {
                // there is an available slab now, use it without allocating a new one
                return @fieldParentPtr("linkage", slab_node);
            }

            raw_cache.lock.unlock(context);
        }

        log.debug(context, "{s}: allocating slab", .{raw_cache.name()});

        const slab = switch (raw_cache.size_class) {
            .small => slab: {
                const slab_base_ptr: [*]u8 = switch (raw_cache.slab_source) {
                    .heap => slab_base_ptr: {
                        const slab_allocation = cascade.mem.heap.globals.heap_page_arena.allocate(
                            context,
                            arch.paging.standard_page_size.value,
                            .instant_fit,
                        ) catch return AllocateError.SlabAllocationFailed;
                        std.debug.assert(slab_allocation.len == arch.paging.standard_page_size.value);
                        break :slab_base_ptr @ptrFromInt(slab_allocation.base);
                    },
                    .pmm => slab_base_ptr: {
                        const frame = cascade.mem.phys.allocator.allocate(context) catch
                            return AllocateError.SlabAllocationFailed;

                        const slab_base_ptr = cascade.mem.directMapFromPhysical(frame.baseAddress()).toPtr([*]u8);

                        if (core.is_debug) @memset(slab_base_ptr[0..arch.paging.standard_page_size.value], undefined);

                        break :slab_base_ptr slab_base_ptr;
                    },
                };

                errdefer switch (raw_cache.slab_source) {
                    .heap => cascade.mem.heap.globals.heap_page_arena.deallocate(context, .{
                        .base = @intFromPtr(slab_base_ptr),
                        .len = arch.paging.standard_page_size.value,
                    }),
                    .pmm => {
                        var deallocate_frame_list: cascade.mem.phys.FrameList = .{};
                        deallocate_frame_list.push(.fromAddress(
                            cascade.mem.physicalFromDirectMap(.fromPtr(slab_base_ptr)) catch unreachable,
                        ));
                        cascade.mem.phys.allocator.deallocate(context, deallocate_frame_list);
                    },
                };

                const slab: *Slab = @ptrCast(@alignCast(
                    slab_base_ptr + arch.paging.standard_page_size.value - @sizeOf(Slab),
                ));
                slab.* = .{
                    .large_object_allocation = undefined,
                };

                var i: usize = 0;
                errdefer if (raw_cache.destructor) |destructor| {
                    // call the destructor for any objects that the constructor was called on
                    for (0..i) |y| {
                        const object_ptr = slab_base_ptr + (y * raw_cache.effective_object_size);
                        destructor(object_ptr[0..raw_cache.object_size], context);
                    }
                };

                while (i < raw_cache.objects_per_slab) : (i += 1) {
                    const object_ptr = slab_base_ptr + (i * raw_cache.effective_object_size);

                    if (raw_cache.constructor) |constructor| {
                        try constructor(object_ptr[0..raw_cache.object_size], context);
                    }

                    const object_node: *std.SinglyLinkedList.Node = @ptrCast(@alignCast(
                        object_ptr + single_node_alignment.forward(raw_cache.object_size),
                    ));

                    slab.objects.prepend(object_node);
                }

                break :slab slab;
            },
            .large => slab: {
                const large_object_allocation = cascade.mem.heap.globals.heap_page_arena.allocate(
                    context,
                    raw_cache.effective_object_size * raw_cache.objects_per_slab,
                    .instant_fit,
                ) catch return AllocateError.SlabAllocationFailed;
                errdefer cascade.mem.heap.globals.heap_page_arena.deallocate(context, large_object_allocation);

                const slab = try globals.slab_cache.allocate(context);
                slab.* = .{
                    .large_object_allocation = large_object_allocation,
                };

                if (core.is_debug) {
                    const virtual_range: core.VirtualRange = .{
                        .address = .fromInt(slab.large_object_allocation.base),
                        .size = .from(slab.large_object_allocation.len, .byte),
                    };
                    @memset(virtual_range.toByteSlice(), undefined);
                }

                errdefer {
                    while (slab.objects.popFirst()) |object_node| {
                        const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                        if (raw_cache.destructor) |destructor| {
                            destructor(large_object.object, context);
                        }

                        globals.large_object_cache.deallocate(context, large_object);
                    }

                    globals.slab_cache.deallocate(context, slab);
                }

                const objects_base: [*]u8 = @ptrFromInt(large_object_allocation.base);

                for (0..raw_cache.objects_per_slab) |i| {
                    const large_object = try globals.large_object_cache.allocate(context);
                    errdefer globals.large_object_cache.deallocate(context, large_object);

                    const object: []u8 = (objects_base + (i * raw_cache.effective_object_size))[0..raw_cache.object_size];

                    large_object.* = .{
                        .object = object,
                        .slab = slab,
                        .node = .{},
                    };

                    if (raw_cache.constructor) |constructor| {
                        try constructor(object, context);
                    }

                    slab.objects.prepend(&large_object.node);
                }

                break :slab slab;
            },
        };

        raw_cache.lock.lock(context);

        raw_cache.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Deallocate an object back to the cache.
    pub fn deallocate(raw_cache: *RawCache, context: *cascade.Context, object: []u8) void {
        raw_cache.deallocateMany(context, &.{object});
    }

    /// Deallocate many objects back to the cache.
    pub fn deallocateMany(raw_cache: *RawCache, context: *cascade.Context, objects: []const []u8) void {
        std.debug.assert(objects.len > 0);

        log.verbose(context, "{s}: deallocating {} objects", .{ raw_cache.name(), objects.len });

        raw_cache.lock.lock(context);
        defer raw_cache.lock.unlock(context);

        for (objects) |object| {
            const slab, const object_node = switch (raw_cache.size_class) {
                .small => blk: {
                    const page_start = std.mem.alignBackward(
                        usize,
                        @intFromPtr(object.ptr),
                        arch.paging.standard_page_size.value,
                    );

                    const slab: *Slab = @ptrFromInt(page_start + arch.paging.standard_page_size.value - @sizeOf(Slab));

                    const object_node: *std.SinglyLinkedList.Node = @ptrCast(@alignCast(
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

            switch (raw_cache.last_slab) {
                .keep => if (raw_cache.available_slabs.first == raw_cache.available_slabs.last) {
                    @branchHint(.unlikely);

                    std.debug.assert(raw_cache.available_slabs.first == &slab.linkage);

                    // this is the last available slab so we leave it in the available list and don't deallocate it

                    continue;
                },
                .free => {},
            }

            // slab is unused remove it from available list and deallocate it
            raw_cache.available_slabs.remove(&slab.linkage);

            raw_cache.deallocateSlab(context, slab);
        }
    }

    /// Deallocate a slab.
    ///
    /// The cache's lock must *not* be held when this is called.
    fn deallocateSlab(raw_cache: *RawCache, context: *cascade.Context, slab: *Slab) void {
        log.debug(context, "{s}: deallocating slab", .{raw_cache.name()});

        switch (raw_cache.size_class) {
            .small => {
                const slab_info_ptr: [*]u8 = @ptrCast(slab);
                const slab_base_ptr: [*]u8 = slab_info_ptr + @sizeOf(Slab) - arch.paging.standard_page_size.value;

                if (raw_cache.destructor) |destructor| {
                    for (0..raw_cache.objects_per_slab) |i| {
                        const object_ptr = slab_base_ptr + (i * raw_cache.effective_object_size);
                        destructor(object_ptr[0..raw_cache.object_size], context);
                    }
                }

                switch (raw_cache.slab_source) {
                    .heap => cascade.mem.heap.globals.heap_page_arena.deallocate(
                        context,
                        .{
                            .base = @intFromPtr(slab_base_ptr),
                            .len = arch.paging.standard_page_size.value,
                        },
                    ),
                    .pmm => {
                        var deallocate_frame_list: cascade.mem.phys.FrameList = .{};
                        deallocate_frame_list.push(.fromAddress(
                            cascade.mem.physicalFromDirectMap(.fromPtr(slab_base_ptr)) catch unreachable,
                        ));
                        cascade.mem.phys.allocator.deallocate(context, deallocate_frame_list);
                    },
                }

                return;
            },
            .large => {
                while (slab.objects.popFirst()) |object_node| {
                    const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                    if (raw_cache.destructor) |destructor| {
                        destructor(large_object.object, context);
                    }

                    globals.large_object_cache.deallocate(context, large_object);
                }

                cascade.mem.heap.globals.heap_page_arena.deallocate(context, slab.large_object_allocation);

                globals.slab_cache.deallocate(context, slab);
            },
        }
    }

    const Slab = struct {
        linkage: std.DoublyLinkedList.Node = .{},
        objects: std.SinglyLinkedList = .{},
        allocated_objects: usize = 0,

        /// The allocation containing this slabs objects.
        ///
        /// Only set for large object slabs.
        large_object_allocation: cascade.mem.resource_arena.Allocation,

        fn constructor(slab: *Slab) void {
            slab.* = .{};
        }
    };

    const LargeObject = struct {
        object: []u8,
        slab: *Slab,
        node: std.SinglyLinkedList.Node = .{},
    };

    const default_large_objects_per_slab = 16;
};

const maximum_small_object_size = arch.paging.standard_page_size.subtract(.of(RawCache.Slab)).divideScalar(8);
const single_node_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(std.SinglyLinkedList.Node));

pub fn isSmallObject(size: usize, alignment: std.mem.Alignment) bool {
    return sizeOfObjectWithNodeAppended(size, alignment) <= maximum_small_object_size.value;
}

fn sizeOfObjectWithNodeAppended(size: usize, alignment: std.mem.Alignment) usize {
    return alignment.forward(single_node_alignment.forward(size) + @sizeOf(std.SinglyLinkedList.Node));
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var slab_cache: Cache(RawCache.Slab, null, null) = undefined;

    /// Initialized during `init.initializeCaches`.
    var large_object_cache: Cache(RawCache.LargeObject, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches(context: *cascade.Context) !void {
        globals.slab_cache.init(context, .{
            .name = try .fromSlice("slab"),
            .slab_source = .pmm,
        });

        globals.large_object_cache.init(context, .{
            .name = try .fromSlice("large object"),
            .slab_source = .pmm,
        });
    }
};

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.cache);
const std = @import("std");
