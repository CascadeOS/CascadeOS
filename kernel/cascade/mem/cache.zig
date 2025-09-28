// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: use `core.Size`

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const log = cascade.debug.log.scoped(.cache);

pub const ConstructorError = error{ItemConstructionFailed};
pub const Name = core.containers.BoundedArray(u8, cascade.config.cache_name_length);

/// A slab based cache of T.
///
/// Wrapper around `RawCache` that provides a `T`-specifc API.
pub fn Cache(
    comptime T: type,
    comptime constructor: ?fn (item: *T, context: *cascade.Context) ConstructorError!void,
    comptime destructor: ?fn (item: *T, context: *cascade.Context) void,
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
            /// `.pmm` is only valid for small item caches.
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
                        fn innerConstructor(item: []u8, inner_context: *cascade.Context) ConstructorError!void {
                            try con(@ptrCast(@alignCast(item)), inner_context);
                        }
                    }.innerConstructor
                else
                    null,
                .destructor = if (destructor) |des|
                    struct {
                        fn innerDestructor(item: []u8, inner_context: *cascade.Context) void {
                            des(@ptrCast(@alignCast(item)), inner_context);
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
        /// All items must have been deallocated before calling this.
        pub fn deinit(cache: *CacheT, context: *cascade.Context) void {
            cache.raw_cache.deinit(context);
            cache.* = undefined;
        }

        pub fn name(cache: *const CacheT) []const u8 {
            return cache.raw_cache.name();
        }

        /// Allocate an item from the cache.
        pub fn allocate(cache: *CacheT, context: *cascade.Context) RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try cache.raw_cache.allocate(context)));
        }

        /// Allocate multiple items from the cache.
        ///
        /// The length of `item_buffer` must be less than or equal to `max_count`.
        pub fn allocateMany(
            cache: *CacheT,
            context: *cascade.Context,
            comptime max_count: usize, // TODO: is there a better way than this?
            items: []*T,
        ) RawCache.AllocateError!void {
            std.debug.assert(items.len > 0);
            std.debug.assert(items.len <= max_count);

            var raw_item_buffer: [max_count][]u8 = undefined;
            const raw_items = raw_item_buffer[0..items.len];

            try cache.raw_cache.allocateMany(context, raw_items);

            for (items, raw_items) |*item, raw_item| {
                item.* = @ptrCast(@alignCast(raw_item));
            }
        }

        /// Deallocate an item back to the cache.
        pub fn deallocate(cache: *CacheT, context: *cascade.Context, item: *T) void {
            cache.raw_cache.deallocate(context, std.mem.asBytes(item));
        }

        /// Deallocate multiple items back to the cache.
        ///
        /// The length of `items` must be less than or equal to `max_count`.
        pub fn deallocateMany(
            cache: *CacheT,
            context: *cascade.Context,
            comptime max_count: usize, // TODO: is there a better way than this?
            items: []const *T,
        ) void {
            std.debug.assert(items.len > 0);
            std.debug.assert(items.len <= max_count);

            var raw_item_buffer: [max_count][]u8 = undefined;
            const raw_items = raw_item_buffer[0..items.len];

            for (raw_items, items) |*raw_item, item| {
                raw_item.* = std.mem.asBytes(item);
            }

            cache.raw_cache.deallocateMany(context, raw_items);
        }
    };
}

/// A slab based cache.
///
/// Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
pub const RawCache = struct {
    _name: Name,

    lock: cascade.sync.Mutex,

    size_class: Size,

    item_size: usize,

    /// The size of the item with sufficient padding to ensure alignment.
    ///
    /// If the item is small additional space for the free list node is added.
    effective_item_size: usize,

    items_per_slab: usize,

    /// What should happen to the last available slab when it is unused?
    last_slab: core.CleanupDecision = .keep,

    /// The source of slabs.
    ///
    /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
    ///
    /// `.pmm` is only valid for small item caches.
    slab_source: InitOptions.SlabSource = .heap,

    constructor: ?*const fn (item: []u8, context: *cascade.Context) ConstructorError!void,
    destructor: ?*const fn (item: []u8, context: *cascade.Context) void,

    available_slabs: std.DoublyLinkedList,
    full_slabs: std.DoublyLinkedList,

    /// Used to ensure that only one thread allocates a new slab at a time.
    allocate_mutex: cascade.sync.Mutex,

    const Size = union(enum) {
        small,
        large: Large,

        const Large = struct {
            item_lookup: std.AutoHashMap(usize, *LargeItem),
        };
    };

    pub const InitOptions = struct {
        name: Name,

        size: usize,
        alignment: std.mem.Alignment,

        constructor: ?*const fn (item: []u8, context: *cascade.Context) ConstructorError!void = null,
        destructor: ?*const fn (item: []u8, context: *cascade.Context) void = null,

        /// What should happen to the last available slab when it is unused?
        last_slab: core.CleanupDecision = .keep,

        /// The source of slabs.
        ///
        /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
        ///
        /// `.pmm` is only valid for small item caches.
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
        const is_small = isSmallItem(options.size, options.alignment);

        if (!is_small and options.slab_source == .pmm) {
            @panic("only small item caches can have `slab_source` set to `.pmm`");
        }

        const effective_item_size = if (is_small)
            sizeOfItemWithNodeAppended(options.size, options.alignment)
        else
            options.alignment.forward(options.size);

        const items_per_slab = if (is_small)
            (arch.paging.standard_page_size.value - @sizeOf(Slab)) / effective_item_size
        else blk: {
            var candidate_large_items_per_slab: usize = default_large_items_per_slab;

            const initial_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                .from(candidate_large_items_per_slab * effective_item_size, .byte),
            );

            while (true) {
                const next_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                    .from((candidate_large_items_per_slab + 1) * effective_item_size, .byte),
                );

                if (next_pages_for_allocation != initial_pages_for_allocation) break;

                candidate_large_items_per_slab += 1;
            }

            break :blk candidate_large_items_per_slab;
        };

        if (is_small) {
            log.debug(
                context,
                "{s}: init small item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    core.Size.from(effective_item_size, .byte),
                    core.Size.from(options.size, .byte),
                    options.alignment.toByteUnits(),
                    items_per_slab,
                    core.Size.from(effective_item_size * items_per_slab, .byte),
                },
            );
        } else {
            log.debug(
                context,
                "{s}: init large item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    core.Size.from(effective_item_size, .byte),
                    core.Size.from(options.size, .byte),
                    options.alignment.toByteUnits(),
                    items_per_slab,
                    core.Size.from(effective_item_size * items_per_slab, .byte),
                },
            );
        }

        raw_cache.* = .{
            ._name = options.name,
            .allocate_mutex = .{},
            .lock = .{},
            .item_size = options.size,
            .effective_item_size = effective_item_size,
            .constructor = options.constructor,
            .destructor = options.destructor,
            .available_slabs = .{},
            .full_slabs = .{},
            .items_per_slab = items_per_slab,
            .last_slab = options.last_slab,
            .slab_source = options.slab_source,
            .size_class = if (is_small)
                .small
            else
                .{
                    .large = .{
                        .item_lookup = .init(cascade.mem.heap.allocator),
                    },
                },
        };
    }

    /// Deinitialize the cache.
    ///
    /// All items must have been deallocated before calling this.
    pub fn deinit(raw_cache: *RawCache, context: *cascade.Context) void {
        log.debug(context, "{s}: deinit", .{raw_cache.name()});

        if (raw_cache.full_slabs.first != null) @panic("full slabs not empty");

        switch (raw_cache.size_class) {
            .small => {},
            .large => |large| {
                if (large.item_lookup.count() != 0) @panic("large item lookup not empty");
            },
        }

        while (raw_cache.available_slabs.pop()) |node| {
            const slab: *Slab = @fieldParentPtr("linkage", node);
            if (slab.allocated_items != 0) @panic("slab not empty");

            raw_cache.deallocateSlab(context, slab);
        }

        raw_cache.* = undefined;
    }

    pub fn name(raw_cache: *const RawCache) []const u8 {
        return raw_cache._name.constSlice();
    }

    pub const AllocateError = error{
        ItemConstructionFailed,

        SlabAllocationFailed,

        /// Failed to allocate a large item.
        ///
        /// Only possible if adding the item to the large item lookup failed.
        LargeItemAllocationFailed,
    };

    /// Allocate an item from the cache.
    pub fn allocate(raw_cache: *RawCache, context: *cascade.Context) AllocateError![]u8 {
        var item_buffer: [1][]u8 = undefined;
        try raw_cache.allocateMany(context, &item_buffer);
        return item_buffer[0];
    }

    /// Allocate multiple items from the cache.
    pub fn allocateMany(raw_cache: *RawCache, context: *cascade.Context, items: [][]u8) AllocateError!void {
        std.debug.assert(items.len > 0);

        log.verbose(context, "{s}: allocating {} items", .{ raw_cache.name(), items.len });

        var allocated_items: std.ArrayListUnmanaged([]u8) = .initBuffer(items);
        errdefer raw_cache.deallocateMany(context, allocated_items.items);

        raw_cache.lock.lock(context);

        var items_left = items.len;

        while (items_left > 0) {
            const slab: *Slab = if (raw_cache.available_slabs.first) |slab_node|
                @fieldParentPtr("linkage", slab_node)
            else blk: {
                @branchHint(.unlikely);
                break :blk try raw_cache.allocateSlab(context);
            };

            while (items_left > 0) {
                defer items_left -= 1;

                const item_node = slab.items.popFirst() orelse
                    @panic("empty slab on available list");
                slab.allocated_items += 1;

                switch (raw_cache.size_class) {
                    .small => {
                        const item_node_ptr: [*]u8 = @ptrCast(item_node);
                        const item_ptr = item_node_ptr - single_node_alignment.forward(raw_cache.item_size);
                        allocated_items.appendAssumeCapacity(item_ptr[0..raw_cache.item_size]);
                    },
                    .large => |*large| {
                        const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                        large.item_lookup.putNoClobber(@intFromPtr(large_item.item.ptr), large_item) catch {
                            @branchHint(.cold);

                            slab.items.prepend(item_node);
                            slab.allocated_items -= 1;

                            log.warn(context, "{s}: failed to add large item to lookup table", .{raw_cache.name()});

                            return error.LargeItemAllocationFailed;
                        };

                        allocated_items.appendAssumeCapacity(large_item.item);
                    },
                }

                if (slab.allocated_items == raw_cache.items_per_slab) {
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
                    .large_item_allocation = undefined,
                };

                var i: usize = 0;
                errdefer if (raw_cache.destructor) |destructor| {
                    // call the destructor for any items that the constructor was called on
                    for (0..i) |y| {
                        const item_ptr = slab_base_ptr + (y * raw_cache.effective_item_size);
                        destructor(item_ptr[0..raw_cache.item_size], context);
                    }
                };

                while (i < raw_cache.items_per_slab) : (i += 1) {
                    const item_ptr = slab_base_ptr + (i * raw_cache.effective_item_size);

                    if (raw_cache.constructor) |constructor| {
                        try constructor(item_ptr[0..raw_cache.item_size], context);
                    }

                    const item_node: *std.SinglyLinkedList.Node = @ptrCast(@alignCast(
                        item_ptr + single_node_alignment.forward(raw_cache.item_size),
                    ));

                    slab.items.prepend(item_node);
                }

                break :slab slab;
            },
            .large => slab: {
                const large_item_allocation = cascade.mem.heap.globals.heap_page_arena.allocate(
                    context,
                    raw_cache.effective_item_size * raw_cache.items_per_slab,
                    .instant_fit,
                ) catch return AllocateError.SlabAllocationFailed;
                errdefer cascade.mem.heap.globals.heap_page_arena.deallocate(context, large_item_allocation);

                const slab = try globals.slab_cache.allocate(context);
                slab.* = .{
                    .large_item_allocation = large_item_allocation,
                };

                if (core.is_debug) {
                    const virtual_range: core.VirtualRange = .{
                        .address = .fromInt(slab.large_item_allocation.base),
                        .size = .from(slab.large_item_allocation.len, .byte),
                    };
                    @memset(virtual_range.toByteSlice(), undefined);
                }

                errdefer {
                    while (slab.items.popFirst()) |item_node| {
                        const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                        if (raw_cache.destructor) |destructor| {
                            destructor(large_item.item, context);
                        }

                        globals.large_item_cache.deallocate(context, large_item);
                    }

                    globals.slab_cache.deallocate(context, slab);
                }

                const items_base: [*]u8 = @ptrFromInt(large_item_allocation.base);

                for (0..raw_cache.items_per_slab) |i| {
                    const large_item = try globals.large_item_cache.allocate(context);
                    errdefer globals.large_item_cache.deallocate(context, large_item);

                    const item: []u8 = (items_base + (i * raw_cache.effective_item_size))[0..raw_cache.item_size];

                    large_item.* = .{
                        .item = item,
                        .slab = slab,
                        .node = .{},
                    };

                    if (raw_cache.constructor) |constructor| {
                        try constructor(item, context);
                    }

                    slab.items.prepend(&large_item.node);
                }

                break :slab slab;
            },
        };

        raw_cache.lock.lock(context);

        raw_cache.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Deallocate an item back to the cache.
    pub fn deallocate(raw_cache: *RawCache, context: *cascade.Context, item: []u8) void {
        raw_cache.deallocateMany(context, &.{item});
    }

    /// Deallocate many items back to the cache.
    pub fn deallocateMany(raw_cache: *RawCache, context: *cascade.Context, items: []const []u8) void {
        std.debug.assert(items.len > 0);

        log.verbose(context, "{s}: deallocating {} items", .{ raw_cache.name(), items.len });

        raw_cache.lock.lock(context);
        defer raw_cache.lock.unlock(context);

        for (items) |item| {
            const slab, const item_node = switch (raw_cache.size_class) {
                .small => blk: {
                    const page_start = std.mem.alignBackward(
                        usize,
                        @intFromPtr(item.ptr),
                        arch.paging.standard_page_size.value,
                    );

                    const slab: *Slab = @ptrFromInt(page_start + arch.paging.standard_page_size.value - @sizeOf(Slab));

                    const item_node: *std.SinglyLinkedList.Node = @ptrCast(@alignCast(
                        item.ptr + single_node_alignment.forward(raw_cache.item_size),
                    ));

                    break :blk .{ slab, item_node };
                },
                .large => |*large| blk: {
                    const large_item = large.item_lookup.get(@intFromPtr(item.ptr)) orelse {
                        @panic("large item not found in item lookup");
                    };

                    _ = large.item_lookup.remove(@intFromPtr(item.ptr));

                    break :blk .{ large_item.slab, &large_item.node };
                },
            };

            if (slab.allocated_items == raw_cache.items_per_slab) {
                // slab was previously full, move it to available list
                @branchHint(.unlikely);
                raw_cache.full_slabs.remove(&slab.linkage);
                raw_cache.available_slabs.append(&slab.linkage);
            }

            slab.items.prepend(item_node);
            slab.allocated_items -= 1;

            if (slab.allocated_items != 0) {
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
                    for (0..raw_cache.items_per_slab) |i| {
                        const item_ptr = slab_base_ptr + (i * raw_cache.effective_item_size);
                        destructor(item_ptr[0..raw_cache.item_size], context);
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
                while (slab.items.popFirst()) |item_node| {
                    const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                    if (raw_cache.destructor) |destructor| {
                        destructor(large_item.item, context);
                    }

                    globals.large_item_cache.deallocate(context, large_item);
                }

                cascade.mem.heap.globals.heap_page_arena.deallocate(context, slab.large_item_allocation);

                globals.slab_cache.deallocate(context, slab);
            },
        }
    }

    const Slab = struct {
        linkage: std.DoublyLinkedList.Node = .{},
        items: std.SinglyLinkedList = .{},
        allocated_items: usize = 0,

        /// The allocation containing this slabs items.
        ///
        /// Only set for large item slabs.
        large_item_allocation: cascade.mem.resource_arena.Allocation,

        fn constructor(slab: *Slab) void {
            slab.* = .{};
        }
    };

    const LargeItem = struct {
        item: []u8,
        slab: *Slab,
        node: std.SinglyLinkedList.Node = .{},
    };

    const default_large_items_per_slab = 16;
};

const minimum_small_items_per_slab = 8;
const maximum_small_item_size = arch.paging.standard_page_size
    .subtract(.of(RawCache.Slab))
    .divideScalar(minimum_small_items_per_slab);
const single_node_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(std.SinglyLinkedList.Node));

pub inline fn isSmallItem(size: usize, alignment: std.mem.Alignment) bool {
    return sizeOfItemWithNodeAppended(size, alignment) <= maximum_small_item_size.value;
}

fn sizeOfItemWithNodeAppended(size: usize, alignment: std.mem.Alignment) usize {
    return alignment.forward(single_node_alignment.forward(size) + @sizeOf(std.SinglyLinkedList.Node));
}

pub const globals = struct {
    /// Initialized during `init.mem.initializeCaches`.
    pub var slab_cache: Cache(RawCache.Slab, null, null) = undefined;

    /// Initialized during `init.mem.initializeCaches`.
    pub var large_item_cache: Cache(RawCache.LargeItem, null, null) = undefined;
};
