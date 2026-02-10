// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

// TODO: use `addr.Virtual.Kernel`, search for `.value`

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const kernel = @import("kernel");
const Task = kernel.Task;
const addr = kernel.addr;

const log = kernel.debug.log.scoped(.cache);

/// A slab based cache of T.
///
/// Wrapper around `RawCache` that provides a `T`-specifc API.
pub fn Cache(
    comptime T: type,
    comptime construct_destruct: ?ConstructDestruct(T),
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
            options: InitOptions,
        ) void {
            cache.* = .{
                .raw_cache = undefined,
            };

            cache.raw_cache.init(.{
                .name = options.name,
                .size = .of(T),
                .alignment = .fromByteUnits(@alignOf(T)),
                .construct_destruct = if (construct_destruct) |con_des| .{
                    .constructor = struct {
                        fn innerConstructor(item: []u8) ConstructorError!void {
                            try con_des.constructor(@ptrCast(@alignCast(item)));
                        }
                    }.innerConstructor,
                    .destructor = struct {
                        fn innerDestructor(item: []u8) void {
                            con_des.destructor(@ptrCast(@alignCast(item)));
                        }
                    }.innerDestructor,
                } else null,
                .last_slab = options.last_slab,
                .slab_source = options.slab_source,
            });
        }

        /// Deinitialize the cache.
        ///
        /// All items must have been deallocated before calling this.
        pub fn deinit(cache: *CacheT) void {
            cache.raw_cache.deinit();
            cache.* = undefined;
        }

        pub fn name(cache: *const CacheT) []const u8 {
            return cache.raw_cache.name();
        }

        /// Allocate an item from the cache.
        pub fn allocate(cache: *CacheT) RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try cache.raw_cache.allocate()));
        }

        /// Allocate multiple items from the cache.
        pub fn allocateMany(cache: *CacheT, items: []*T) RawCache.AllocateError!void {
            var raw_item_buffer: [16][]u8 = undefined;

            var item_index: usize = 0;
            while (item_index < items.len) {
                const raw_items = raw_item_buffer[0..@min(raw_item_buffer.len, items.len - item_index)];

                try cache.raw_cache.allocateMany(raw_items);

                for (items[item_index..][0..raw_items.len], raw_items) |*item, raw_item| {
                    item.* = @ptrCast(@alignCast(raw_item));
                }

                item_index += raw_items.len;
            }
        }

        /// Deallocate an item back to the cache.
        pub fn deallocate(cache: *CacheT, item: *T) void {
            cache.raw_cache.deallocate(std.mem.asBytes(item));
        }

        /// Deallocate multiple items back to the cache.
        pub fn deallocateMany(cache: *CacheT, items: []const *T) void {
            var raw_item_buffer: [16][]u8 = undefined;

            var item_index: usize = 0;
            while (item_index < items.len) {
                const raw_items = raw_item_buffer[0..@min(raw_item_buffer.len, items.len - item_index)];

                for (raw_items, items[item_index..][0..raw_items.len]) |*raw_item, item| {
                    raw_item.* = @ptrCast(@alignCast(item));
                }

                cache.raw_cache.deallocateMany(raw_items);

                item_index += raw_items.len;
            }
        }
    };
}

/// A slab based cache.
///
/// Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
pub const RawCache = struct {
    _name: Name,

    lock: kernel.sync.Mutex,

    size_class: SizeClass,

    item_size: core.Size,

    /// The size of the item with sufficient padding to ensure alignment.
    ///
    /// If the item is small additional space for the free list node is added.
    effective_item_size: core.Size,

    items_per_slab: usize,

    /// What should happen to the last available slab when it is unused?
    last_slab: core.CleanupDecision = .keep,

    /// The source of slabs.
    ///
    /// This should only be `.pmm` for caches used as part of `ResourceArena`/`RawCache` implementation.
    ///
    /// `.pmm` is only valid for small item caches.
    slab_source: InitOptions.SlabSource = .heap,

    construct_destruct: ?RawConstructDestruct,

    available_slabs: std.DoublyLinkedList,
    full_slabs: std.DoublyLinkedList,

    /// Used to ensure that only one thread allocates a new slab at a time.
    allocate_mutex: kernel.sync.Mutex,

    const SizeClass = union(enum) {
        small,
        large: Large,

        const Large = struct {
            item_lookup: std.AutoHashMap(usize, *LargeItem),
        };
    };

    pub const InitOptions = struct {
        name: Name,

        size: core.Size,
        alignment: std.mem.Alignment,

        construct_destruct: ?RawConstructDestruct = null,

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
        options: InitOptions,
    ) void {
        const item_size: ItemSize = .determine(options.size, options.alignment);

        if (!item_size.is_small and options.slab_source == .pmm) {
            @panic("only small item caches can have `slab_source` set to `.pmm`");
        }

        if (item_size.is_small) {
            log.debug(
                "{s}: init small item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    item_size.effective_item_size,
                    options.size,
                    options.alignment.toByteUnits(),
                    item_size.items_per_slab,
                    item_size.effective_item_size.multiplyScalar(item_size.items_per_slab),
                },
            );
        } else {
            log.debug(
                "{s}: init large item cache with effective size {f} (requested size {f} alignment {}) items per slab {} ({f})",
                .{
                    options.name.constSlice(),
                    item_size.effective_item_size,
                    options.size,
                    options.alignment.toByteUnits(),
                    item_size.items_per_slab,
                    item_size.effective_item_size.multiplyScalar(item_size.items_per_slab),
                },
            );
        }

        raw_cache.* = .{
            ._name = options.name,
            .allocate_mutex = .{},
            .lock = .{},
            .item_size = options.size,
            .effective_item_size = item_size.effective_item_size,
            .construct_destruct = options.construct_destruct,
            .available_slabs = .{},
            .full_slabs = .{},
            .items_per_slab = item_size.items_per_slab,
            .last_slab = options.last_slab,
            .slab_source = options.slab_source,
            .size_class = if (item_size.is_small)
                .small
            else
                .{
                    .large = .{
                        .item_lookup = .init(kernel.mem.heap.allocator),
                    },
                },
        };
    }

    /// Deinitialize the cache.
    ///
    /// All items must have been deallocated before calling this.
    pub fn deinit(raw_cache: *RawCache) void {
        log.debug("{s}: deinit", .{raw_cache.name()});

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

            raw_cache.deallocateSlab(slab);
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
    pub fn allocate(
        raw_cache: *RawCache,
    ) AllocateError![]u8 {
        var item_buffer: [1][]u8 = undefined;
        try raw_cache.allocateMany(&item_buffer);
        return item_buffer[0];
    }

    /// Allocate multiple items from the cache.
    pub fn allocateMany(raw_cache: *RawCache, items: [][]u8) AllocateError!void {
        if (items.len == 0) return;

        log.verbose("{s}: allocating {} items", .{ raw_cache.name(), items.len });

        var allocated_items: std.ArrayListUnmanaged([]u8) = .initBuffer(items);
        errdefer raw_cache.deallocateMany(allocated_items.items);

        raw_cache.lock.lock();

        var items_left = items.len;

        while (items_left > 0) {
            const slab: *Slab = if (raw_cache.available_slabs.first) |slab_node|
                @fieldParentPtr("linkage", slab_node)
            else blk: {
                @branchHint(.unlikely);
                break :blk try raw_cache.allocateSlab();
            };

            while (items_left > 0) {
                defer items_left -= 1;

                const item_node = slab.items.popFirst() orelse
                    @panic("empty slab on available list");
                slab.allocated_items += 1;

                switch (raw_cache.size_class) {
                    .small => {
                        const item_node_ptr: [*]u8 = @ptrCast(item_node);
                        const item_ptr = item_node_ptr - raw_cache.item_size.alignForward(single_node_alignment).value;
                        allocated_items.appendAssumeCapacity(item_ptr[0..raw_cache.item_size.value]);
                    },
                    .large => |*large| {
                        const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                        large.item_lookup.putNoClobber(@intFromPtr(large_item.item.ptr), large_item) catch {
                            @branchHint(.cold);

                            slab.items.prepend(item_node);
                            slab.allocated_items -= 1;

                            log.warn("{s}: failed to add large item to lookup table", .{raw_cache.name()});

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

        raw_cache.lock.unlock();
    }

    /// Allocates a new slab.
    ///
    /// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
    fn allocateSlab(raw_cache: *RawCache) AllocateError!*Slab {
        errdefer log.warn("{s}: failed to allocate slab", .{raw_cache.name()});

        raw_cache.lock.unlock();

        raw_cache.allocate_mutex.lock();
        defer raw_cache.allocate_mutex.unlock();

        // optimistically check for an available slab without locking, if there is one lock and check again
        if (raw_cache.available_slabs.first != null) {
            raw_cache.lock.lock();

            if (raw_cache.available_slabs.first) |slab_node| {
                // there is an available slab now, use it without allocating a new one
                return @fieldParentPtr("linkage", slab_node);
            }

            raw_cache.lock.unlock();
        }

        log.debug("{s}: allocating slab", .{raw_cache.name()});

        const slab = switch (raw_cache.size_class) {
            .small => slab: {
                const slab_base_ptr: [*]u8 = switch (raw_cache.slab_source) {
                    .heap => slab_base_ptr: {
                        const slab_allocation = kernel.mem.heap.heap_page_arena.allocate(
                            arch.paging.standard_page_size.value,
                            .instant_fit,
                        ) catch return AllocateError.SlabAllocationFailed;
                        break :slab_base_ptr @ptrFromInt(slab_allocation.base);
                    },
                    .pmm => slab_base_ptr: {
                        const physical_page = kernel.mem.PhysicalPage.allocator.allocate() catch
                            return AllocateError.SlabAllocationFailed;

                        const slab_base_ptr = physical_page.baseAddress().toDirectMap().ptr([*]u8);

                        if (core.is_debug) @memset(slab_base_ptr[0..arch.paging.standard_page_size.value], undefined);

                        break :slab_base_ptr slab_base_ptr;
                    },
                };

                errdefer switch (raw_cache.slab_source) {
                    .heap => kernel.mem.heap.heap_page_arena.deallocate(.{
                        .base = @intFromPtr(slab_base_ptr),
                        .len = arch.paging.standard_page_size.value,
                    }),
                    .pmm => {
                        var deallocate_page_list: kernel.mem.PhysicalPage.List = .{};
                        deallocate_page_list.prepend(.fromAddress(
                            addr.Physical.fromDirectMap(.from(@intFromPtr(slab_base_ptr))) catch unreachable,
                        ));
                        kernel.mem.PhysicalPage.allocator.deallocate(deallocate_page_list);
                    },
                };

                const slab: *Slab = @ptrCast(@alignCast(
                    slab_base_ptr + arch.paging.standard_page_size.value - @sizeOf(Slab),
                ));
                slab.* = .{
                    .large_item_allocation = undefined,
                };

                if (raw_cache.construct_destruct) |con_des| {
                    var i: usize = 0;

                    errdefer { // call the destructor for any items that the constructor was called on
                        const destructor = con_des.destructor;
                        for (0..i) |y| {
                            const item_ptr = slab_base_ptr + raw_cache.effective_item_size.multiplyScalar(y).value;
                            destructor(item_ptr[0..raw_cache.item_size.value]);
                        }
                    }

                    const constructor = con_des.constructor;

                    while (i < raw_cache.items_per_slab) : (i += 1) {
                        const item_ptr = slab_base_ptr + raw_cache.effective_item_size.multiplyScalar(i).value;

                        try constructor(item_ptr[0..raw_cache.item_size.value]);

                        slab.items.prepend(@ptrCast(@alignCast(
                            item_ptr + raw_cache.item_size.alignForward(single_node_alignment).value,
                        )));
                    }
                } else {
                    for (0..raw_cache.items_per_slab) |i| {
                        const item_ptr = slab_base_ptr + raw_cache.effective_item_size.multiplyScalar(i).value;
                        slab.items.prepend(@ptrCast(@alignCast(
                            item_ptr + raw_cache.item_size.alignForward(single_node_alignment).value,
                        )));
                    }
                }

                break :slab slab;
            },
            .large => slab: {
                const large_item_allocation = kernel.mem.heap.heap_page_arena.allocate(
                    raw_cache.effective_item_size.multiplyScalar(raw_cache.items_per_slab).value,
                    .instant_fit,
                ) catch return AllocateError.SlabAllocationFailed;
                errdefer kernel.mem.heap.heap_page_arena.deallocate(large_item_allocation);

                const slab = try globals.slab_cache.allocate();
                slab.* = .{ .large_item_allocation = large_item_allocation };
                errdefer globals.slab_cache.deallocate(slab);

                if (core.is_debug) {
                    const virtual_range: addr.Virtual.Range.Kernel = .{
                        .address = .from(slab.large_item_allocation.base),
                        .size = .from(slab.large_item_allocation.len, .byte),
                    };
                    @memset(virtual_range.byteSlice(), undefined);
                }

                const items_base: [*]u8 = @ptrFromInt(large_item_allocation.base);

                if (raw_cache.construct_destruct) |con_des| {
                    errdefer {
                        const destructor = con_des.destructor;
                        while (slab.items.popFirst()) |item_node| {
                            const large_item: *LargeItem = @fieldParentPtr("node", item_node);
                            destructor(large_item.item);
                            globals.large_item_cache.deallocate(large_item);
                        }
                    }

                    const constructor = con_des.constructor;

                    for (0..raw_cache.items_per_slab) |i| {
                        const large_item = try globals.large_item_cache.allocate();
                        errdefer globals.large_item_cache.deallocate(large_item);

                        const item_ptr: [*]u8 = items_base + raw_cache.effective_item_size.multiplyScalar(i).value;
                        const item: []u8 = item_ptr[0..raw_cache.item_size.value];

                        large_item.* = .{
                            .item = item,
                            .slab = slab,
                            .node = .{},
                        };

                        try constructor(item);

                        slab.items.prepend(&large_item.node);
                    }
                } else {
                    errdefer while (slab.items.popFirst()) |item_node| {
                        globals.large_item_cache.deallocate(@fieldParentPtr("node", item_node));
                    };

                    for (0..raw_cache.items_per_slab) |i| {
                        const large_item = try globals.large_item_cache.allocate();

                        const item_ptr: [*]u8 = items_base + raw_cache.effective_item_size.multiplyScalar(i).value;
                        const item: []u8 = item_ptr[0..raw_cache.item_size.value];

                        large_item.* = .{
                            .item = item,
                            .slab = slab,
                            .node = .{},
                        };

                        slab.items.prepend(&large_item.node);
                    }
                }

                break :slab slab;
            },
        };

        raw_cache.lock.lock();

        raw_cache.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Deallocate an item back to the cache.
    pub fn deallocate(raw_cache: *RawCache, item: []u8) void {
        raw_cache.deallocateMany(&.{item});
    }

    /// Deallocate many items back to the cache.
    pub fn deallocateMany(raw_cache: *RawCache, items: []const []u8) void {
        if (items.len == 0) return;

        log.verbose("{s}: deallocating {} items", .{ raw_cache.name(), items.len });

        raw_cache.lock.lock();
        defer raw_cache.lock.unlock();

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
                        item.ptr + raw_cache.item_size.alignForward(single_node_alignment).value,
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

                    if (core.is_debug) std.debug.assert(raw_cache.available_slabs.first == &slab.linkage);

                    // this is the last available slab so we leave it in the available list and don't deallocate it

                    continue;
                },
                .free => {},
            }

            // slab is unused remove it from available list and deallocate it
            raw_cache.available_slabs.remove(&slab.linkage);

            raw_cache.deallocateSlab(slab);
        }
    }

    /// Deallocate a slab.
    ///
    /// The cache's lock must *not* be held when this is called.
    fn deallocateSlab(raw_cache: *RawCache, slab: *Slab) void {
        log.debug("{s}: deallocating slab", .{raw_cache.name()});

        switch (raw_cache.size_class) {
            .small => {
                const slab_info_ptr: [*]u8 = @ptrCast(slab);
                const slab_base_ptr: [*]u8 = slab_info_ptr + @sizeOf(Slab) - arch.paging.standard_page_size.value;

                if (raw_cache.construct_destruct) |con_des| {
                    const destructor = con_des.destructor;
                    for (0..raw_cache.items_per_slab) |i| {
                        const item_ptr = slab_base_ptr + raw_cache.effective_item_size.multiplyScalar(i).value;
                        destructor(item_ptr[0..raw_cache.item_size.value]);
                    }
                }

                switch (raw_cache.slab_source) {
                    .heap => kernel.mem.heap.heap_page_arena.deallocate(
                        .{
                            .base = @intFromPtr(slab_base_ptr),
                            .len = arch.paging.standard_page_size.value,
                        },
                    ),
                    .pmm => {
                        var deallocate_page_list: kernel.mem.PhysicalPage.List = .{};
                        deallocate_page_list.prepend(.fromAddress(
                            addr.Physical.fromDirectMap(.from(@intFromPtr(slab_base_ptr))) catch unreachable,
                        ));
                        kernel.mem.PhysicalPage.allocator.deallocate(deallocate_page_list);
                    },
                }

                return;
            },
            .large => {
                if (raw_cache.construct_destruct) |con_des| {
                    const destructor = con_des.destructor;
                    while (slab.items.popFirst()) |item_node| {
                        const large_item: *LargeItem = @fieldParentPtr("node", item_node);

                        destructor(large_item.item);

                        globals.large_item_cache.deallocate(large_item);
                    }
                } else {
                    while (slab.items.popFirst()) |item_node| {
                        globals.large_item_cache.deallocate(@fieldParentPtr("node", item_node));
                    }
                }

                kernel.mem.heap.heap_page_arena.deallocate(slab.large_item_allocation);

                globals.slab_cache.deallocate(slab);
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
        large_item_allocation: kernel.mem.resource_arena.Allocation,

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

    const ItemSize = struct {
        is_small: bool,
        effective_item_size: core.Size,
        items_per_slab: usize,

        fn determine(size: core.Size, alignment: std.mem.Alignment) ItemSize {
            const is_small = isSmallItem(size, alignment);

            const effective_item_size = if (is_small)
                sizeOfItemWithNodeAppended(size, alignment)
            else
                size.alignForward(alignment);

            const items_per_slab = if (is_small)
                arch.paging.standard_page_size.subtract(.of(Slab)).divide(effective_item_size)
            else blk: {
                // TODO: why search when we can calculate?

                var candidate_large_items_per_slab: usize = default_large_items_per_slab;

                const initial_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                    effective_item_size.multiplyScalar(candidate_large_items_per_slab),
                );

                while (true) {
                    const next_pages_for_allocation = arch.paging.standard_page_size.amountToCover(
                        effective_item_size.multiplyScalar(candidate_large_items_per_slab + 1),
                    );

                    if (next_pages_for_allocation != initial_pages_for_allocation) break;

                    candidate_large_items_per_slab += 1;
                }

                break :blk candidate_large_items_per_slab;
            };

            return .{
                .is_small = is_small,
                .effective_item_size = effective_item_size,
                .items_per_slab = items_per_slab,
            };
        }
    };
};

pub const RawConstructDestruct = struct {
    constructor: *const fn (item: []u8) ConstructorError!void,
    destructor: *const fn (item: []u8) void,
};

pub fn ConstructDestruct(comptime T: type) type {
    return struct {
        constructor: fn (item: *T) ConstructorError!void,
        destructor: fn (item: *T) void,
    };
}

pub const ConstructorError = error{ItemConstructionFailed};
pub const Name = core.containers.BoundedArray(u8, kernel.config.mem.cache_name_length);

const minimum_small_items_per_slab = 8;
const maximum_small_item_size = arch.paging.standard_page_size
    .subtract(.of(RawCache.Slab))
    .divideScalar(minimum_small_items_per_slab);
const single_node_alignment: std.mem.Alignment = .of(std.SinglyLinkedList.Node);

pub inline fn isSmallItem(size: core.Size, alignment: std.mem.Alignment) bool {
    return sizeOfItemWithNodeAppended(size, alignment).lessThanOrEqual(maximum_small_item_size);
}

fn sizeOfItemWithNodeAppended(size: core.Size, alignment: std.mem.Alignment) core.Size {
    return size.alignForward(single_node_alignment)
        .add(.of(std.SinglyLinkedList.Node))
        .alignForward(alignment);
}

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var slab_cache: Cache(RawCache.Slab, null) = undefined;

    /// Initialized during `init.initializeCaches`.
    var large_item_cache: Cache(RawCache.LargeItem, null) = undefined;
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.cache_init);

    pub fn initializeCaches() !void {
        init_log.debug("initializing slab cache", .{});
        globals.slab_cache.init(.{
            .name = try .fromSlice("slab"),
            .slab_source = .pmm,
        });

        init_log.debug("initializing large item cache", .{});
        globals.large_item_cache.init(.{
            .name = try .fromSlice("large item"),
            .slab_source = .pmm,
        });
    }
};
