// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A slab based cache.
//!
//! Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
//!

pub const ConstructorError = error{ObjectConstructionFailed};
pub const Name = std.BoundedArray(u8, kernel.config.cache_name_length);

pub fn Cache(
    comptime T: type,
    comptime constructor: ?fn (object: *T, current_task: *kernel.Task) ConstructorError!void,
    comptime destructor: ?fn (object: *T, current_task: *kernel.Task) void,
) type {
    return struct {
        raw_cache: RawCache,

        const Self = @This();

        pub const InitOptions = struct {
            cache_name: Name,

            /// Whether the last slab should be held in memory even if it is unused.
            hold_last_slab: bool = true,
        };

        /// Initialize the cache.
        pub fn init(
            self: *Self,
            options: InitOptions,
        ) void {
            self.* = .{
                .raw_cache = undefined,
            };

            self.raw_cache.init(.{
                .cache_name = options.cache_name,
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
                .hold_last_slab = options.hold_last_slab,
            });
        }

        /// Deinitialize the cache.
        ///
        /// All objects must have been freed before calling this.
        pub fn deinit(self: *Self, current_task: *kernel.Task) void {
            self.raw_cache.deinit(current_task);
            self.* = undefined;
        }

        pub fn name(self: *const Self) []const u8 {
            return self.raw_cache.name();
        }

        /// Allocate an object from the cache.
        pub fn allocate(self: *Self, current_task: *kernel.Task) RawCache.AllocateError!*T {
            return @ptrCast(@alignCast(try self.raw_cache.allocate(current_task)));
        }

        /// Free an object back to the cache.
        pub fn free(self: *Self, current_task: *kernel.Task, object: *T) void {
            self.raw_cache.free(current_task, std.mem.asBytes(object));
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

    /// Whether the last slab should be held in memory even if it is unused.
    hold_last_slab: bool,

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
        cache_name: Name,

        size: usize,
        alignment: std.mem.Alignment,

        constructor: ?*const fn (object: []u8, current_task: *kernel.Task) ConstructorError!void = null,
        destructor: ?*const fn (object: []u8, current_task: *kernel.Task) void = null,

        /// Whether the last slab should be held in memory even if it is unused.
        hold_last_slab: bool = true,
    };

    /// Initialize the cache.
    pub fn init(
        self: *RawCache,
        options: InitOptions,
    ) void {
        const is_small = options.alignment.forward(options.size) <= small_object_size.value;

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

        self.* = .{
            ._name = options.cache_name,
            .allocate_mutex = .{},
            .lock = .{},
            .object_size = options.size,
            .effective_object_size = effective_object_size,
            .constructor = options.constructor,
            .destructor = options.destructor,
            .available_slabs = .{},
            .full_slabs = .{},
            .objects_per_slab = objects_per_slab,
            .hold_last_slab = options.hold_last_slab,
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
    pub fn deinit(self: *RawCache, current_task: *kernel.Task) void {
        if (self.full_slabs.first != null) @panic("full slabs not empty");

        switch (self.size_class) {
            .small => {},
            .large => |large| {
                if (large.object_lookup.count() != 0) @panic("large object lookup not empty");
            },
        }

        while (self.available_slabs.pop()) |node| {
            const slab: *Slab = @fieldParentPtr("linkage", node);
            if (slab.allocated_objects != 0) @panic("slab not empty");

            self.deallocateSlab(current_task, slab);
        }

        self.* = undefined;
    }

    pub fn name(self: *const RawCache) []const u8 {
        return self._name.constSlice();
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
    pub fn allocate(self: *RawCache, current_task: *kernel.Task) AllocateError![]u8 {
        self.lock.lock(current_task);

        const slab: *Slab = if (self.available_slabs.first) |slab_node|
            @fieldParentPtr("linkage", slab_node)
        else blk: {
            @branchHint(.unlikely);
            break :blk try self.allocateSlab(current_task);
        };

        const object_node = slab.objects.popFirst() orelse
            @panic("empty slab on available list");
        slab.allocated_objects += 1;

        if (slab.allocated_objects == self.objects_per_slab) {
            @branchHint(.unlikely);
            self.available_slabs.remove(&slab.linkage);
            self.full_slabs.append(&slab.linkage);
        }

        self.lock.unlock(current_task);

        switch (self.size_class) {
            .small => {
                const object_node_ptr: [*]u8 = @ptrCast(object_node);
                const object_ptr = object_node_ptr - single_node_alignment.forward(self.object_size);
                return object_ptr[0..self.object_size];
            },
            .large => |*large| {
                const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                large.object_lookup.putNoClobber(@intFromPtr(large_object.object.ptr), large_object) catch {
                    @branchHint(.cold);

                    self.lock.lock(current_task);
                    defer self.lock.unlock(current_task);

                    slab.objects.prepend(object_node);
                    slab.allocated_objects -= 1;

                    return AllocateError.LargeObjectAllocationFailed;
                };

                return large_object.object;
            },
        }
    }

    /// Allocates a new slab.
    ///
    /// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
    fn allocateSlab(self: *RawCache, current_task: *kernel.Task) AllocateError!*Slab {
        self.lock.unlock(current_task);

        self.allocate_mutex.lock(current_task);
        defer self.allocate_mutex.unlock(current_task);

        // optimistically check for an available slab without locking, if there is one lock and check again
        if (self.available_slabs.first != null) {
            self.lock.lock(current_task);

            if (self.available_slabs.first) |slab_node| {
                // there is an available slab now, use it without allocating a new one
                return @fieldParentPtr("linkage", slab_node);
            }

            self.lock.unlock(current_task);
        }

        const slab = switch (self.size_class) {
            .small => blk: {
                const slab_allocation = kernel.mem.heap.globals.heap_page_arena.allocate(
                    current_task,
                    kernel.arch.paging.standard_page_size.value,
                    .instant_fit,
                ) catch return AllocateError.SlabAllocationFailed;
                errdefer kernel.mem.heap.globals.heap_page_arena.deallocate(current_task, slab_allocation);
                std.debug.assert(slab_allocation.len == kernel.arch.paging.standard_page_size.value);

                const slab_base_ptr: [*]u8 = @ptrFromInt(slab_allocation.base);

                const slab: *Slab = @ptrFromInt(
                    slab_allocation.base + kernel.arch.paging.standard_page_size.value - @sizeOf(Slab),
                );
                slab.* = .{
                    .large_object_allocation = undefined,
                };

                for (0..self.objects_per_slab) |i| {
                    const object_ptr = slab_base_ptr + (i * self.effective_object_size);

                    if (self.constructor) |constructor| {
                        try constructor(object_ptr[0..self.object_size], current_task);
                    }

                    const object_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                        object_ptr + single_node_alignment.forward(self.object_size),
                    ));

                    slab.objects.prepend(object_node);
                }

                break :blk slab;
            },
            .large => blk: {
                const large_object_allocation = kernel.mem.heap.globals.heap_page_arena.allocate(
                    current_task,
                    self.effective_object_size * self.objects_per_slab,
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

                        if (self.destructor) |destructor| {
                            destructor(large_object.object, current_task);
                        }

                        globals.large_object_cache.free(current_task, large_object);
                    }

                    globals.slab_cache.free(current_task, slab);
                }

                const objects_base: [*]u8 = @ptrFromInt(large_object_allocation.base);

                for (0..self.objects_per_slab) |i| {
                    const large_object = try globals.large_object_cache.allocate(current_task);
                    errdefer globals.large_object_cache.free(current_task, large_object);

                    const object: []u8 = (objects_base + (i * self.effective_object_size))[0..self.object_size];

                    large_object.* = .{
                        .object = object,
                        .slab = slab,
                        .node = .{},
                    };

                    if (self.constructor) |constructor| {
                        try constructor(object, current_task);
                    }

                    slab.objects.prepend(&large_object.node);
                }

                break :blk slab;
            },
        };

        self.lock.lock(current_task);

        self.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Free an object back to the cache.
    pub fn free(self: *RawCache, current_task: *kernel.Task, object: []u8) void {
        const slab, const object_node = switch (self.size_class) {
            .small => blk: {
                const page_start = std.mem.alignBackward(
                    usize,
                    @intFromPtr(object.ptr),
                    kernel.arch.paging.standard_page_size.value,
                );

                const slab: *Slab = @ptrFromInt(page_start + kernel.arch.paging.standard_page_size.value - @sizeOf(Slab));

                const object_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                    object.ptr + single_node_alignment.forward(self.object_size),
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

        self.lock.lock(current_task);

        if (slab.allocated_objects == self.objects_per_slab) {
            // slab was full, move it to available list
            self.full_slabs.remove(&slab.linkage);
            self.available_slabs.append(&slab.linkage);
        }

        slab.objects.prepend(object_node);
        slab.allocated_objects -= 1;

        if (slab.allocated_objects == 0) deallocate: {
            @branchHint(.unlikely);

            if (self.hold_last_slab) {
                if (self.full_slabs.first == null and self.available_slabs.first == self.available_slabs.last) {
                    std.debug.assert(self.available_slabs.first == &slab.linkage);

                    // this is the last slab so we leave it in the available list and don't deallocate it
                    break :deallocate;
                }
            }

            // slab is unused remove it from available list and deallocate it
            self.available_slabs.remove(&slab.linkage);

            self.lock.unlock(current_task);

            self.deallocateSlab(current_task, slab);

            return;
        }

        self.lock.unlock(current_task);
    }

    /// Deallocate a slab.
    ///
    /// The cache's lock must *not* be held when this is called.
    fn deallocateSlab(self: *RawCache, current_task: *kernel.Task, slab: *Slab) void {
        switch (self.size_class) {
            .small => {
                const slab_base_ptr: [*]u8 =
                    @as([*]u8, @ptrCast(slab)) + @sizeOf(Slab) - kernel.arch.paging.standard_page_size.value;

                if (self.destructor) |destructor| {
                    for (0..self.objects_per_slab) |i| {
                        const object_ptr = slab_base_ptr + (i * self.effective_object_size);
                        destructor(object_ptr[0..self.object_size], current_task);
                    }
                }

                kernel.mem.heap.globals.heap_page_arena.deallocate(
                    current_task,
                    .{
                        .base = @intFromPtr(slab_base_ptr),
                        .len = kernel.arch.paging.standard_page_size.value,
                    },
                );

                return;
            },
            .large => {
                while (slab.objects.popFirst()) |object_node| {
                    const large_object: *LargeObject = @fieldParentPtr("node", object_node);

                    if (self.destructor) |destructor| {
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

        fn constructor(self: *Slab) void {
            self.* = .{};
        }
    };

    const LargeObject = struct {
        object: []u8,
        slab: *Slab,
        node: SinglyLinkedList.Node = .{},
    };

    const small_object_size = kernel.arch.paging.standard_page_size.divideScalar(8);
    const single_node_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(SinglyLinkedList.Node));

    const default_large_objects_per_slab = 16;
};

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var slab_cache: Cache(RawCache.Slab, null, null) = undefined;

    /// Initialized during `init.initializeCaches`.
    var large_object_cache: Cache(RawCache.LargeObject, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches() !void {
        globals.slab_cache.init(
            .{ .cache_name = try .fromSlice("slab") },
        );

        globals.large_object_cache.init(
            .{ .cache_name = try .fromSlice("large object") },
        );
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;
