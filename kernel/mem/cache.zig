// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! A slab based cache.
//!
//! Based on [The slab allocator: an object-caching kernel memory allocator](https://dl.acm.org/doi/10.5555/1267257.1267263) by Jeff Bonwick.
//!

pub fn Cache(
    comptime T: type,
    comptime constructor: ?fn (object: *T) void,
    comptime destructor: ?fn (object: *T) void,
) type {
    return struct {
        raw_cache: RawCache,

        const Self = @This();

        pub const Name = CacheName;

        pub const InitOptions = struct {
            source: *kernel.mem.ResourceArena,

            /// Whether the last slab should be held in memory even if it is unused.
            hold_last_slab: bool = true,
        };

        /// Initialize the cache.
        pub fn init(
            self: *Self,
            cache_name: Name,
            options: InitOptions,
        ) void {
            self.* = .{
                .raw_cache = undefined,
            };

            self.raw_cache.init(cache_name, .{
                .size = @sizeOf(T),
                .alignment = .fromByteUnits(@alignOf(T)),
                .constructor = if (constructor) |con|
                    struct {
                        fn innerConstructor(buffer: []u8) void {
                            con(@ptrCast(@alignCast(buffer)));
                        }
                    }.innerConstructor
                else
                    null,
                .destructor = if (destructor) |des|
                    struct {
                        fn innerDestructor(buffer: []u8) void {
                            des(@ptrCast(@alignCast(buffer)));
                        }
                    }.innerDestructor
                else
                    null,
                .source = options.source,
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

    size: usize,

    /// The size of the object with sufficient padding to ensure alignment.
    ///
    /// If the object is small additional space for the free list node is added.
    effective_size: usize,

    buffers_per_slab: usize,

    /// Used to ensure that only one thread allocates a new slab at a time.
    allocate_mutex: kernel.sync.Mutex,
    source: *kernel.mem.ResourceArena,

    constructor: ?*const fn ([]u8) void,
    destructor: ?*const fn ([]u8) void,

    available_slabs: DoublyLinkedList,
    full_slabs: DoublyLinkedList,

    /// Whether the last slab should be held in memory even if it is unused.
    hold_last_slab: bool,

    large_object_hashmap: std.AutoHashMap(usize, *LargeBuffer),

    pub const Name = CacheName;

    pub const InitOptions = struct {
        size: usize,
        alignment: std.mem.Alignment,

        source: *kernel.mem.ResourceArena,

        constructor: ?*const fn ([]u8) void = null,
        destructor: ?*const fn ([]u8) void = null,

        /// Whether the last slab should be held in memory even if it is unused.
        hold_last_slab: bool = true,
    };

    /// Initialize the cache.
    pub fn init(
        self: *RawCache,
        cache_name: Name,
        options: InitOptions,
    ) void {
        const effective_size = if (isSmallObject(options.size))
            options.alignment.forward(single_node_alignment.forward(options.size) + @sizeOf(SinglyLinkedList.Node))
        else
            options.alignment.forward(options.size);

        const buffers_per_slab = if (isSmallObject(options.size))
            (kernel.arch.paging.standard_page_size.value - @sizeOf(Slab)) / effective_size
        else
            large_objects_per_slab;

        self.* = .{
            ._name = cache_name,
            .source = options.source,
            .allocate_mutex = .{},
            .lock = .{},
            .size = options.size,
            .effective_size = effective_size,
            .constructor = options.constructor,
            .destructor = options.destructor,
            .available_slabs = .{},
            .full_slabs = .{},
            .buffers_per_slab = buffers_per_slab,
            .hold_last_slab = options.hold_last_slab,
            .large_object_hashmap = if (!isSmallObject(options.size))
                .init(kernel.mem.heap.allocator)
            else
                undefined,
        };
    }

    /// Deinitialize the cache.
    ///
    /// All objects must have been freed before calling this.
    pub fn deinit(self: *RawCache, current_task: *kernel.Task) void {
        self.lock.lock(current_task);

        std.debug.assert(self.full_slabs.first == null);

        while (self.available_slabs.pop()) |node| {
            const slab: *Slab = @fieldParentPtr("linkage", node);
            if (slab.allocated_buffers != 0) @panic("slab not empty");

            self.deallocateSlab(current_task, slab);
        }

        self.large_object_hashmap.deinit();

        self.lock.unlock(current_task);

        self.* = undefined;
    }

    pub fn name(self: *const RawCache) []const u8 {
        return self._name.constSlice();
    }

    pub const AllocateError = error{
        SlabAllocationFailed,
    };

    /// Allocate a buffer from the cache.
    pub fn allocate(self: *RawCache, current_task: *kernel.Task) AllocateError![]u8 {
        self.lock.lock(current_task);

        const slab: *Slab = if (self.available_slabs.first) |slab_node|
            @fieldParentPtr("linkage", slab_node)
        else blk: {
            @branchHint(.unlikely);
            break :blk try self.allocateSlab(current_task);
        };

        const buffer_node = slab.buffers.popFirst() orelse
            @panic("empty slab on available list");
        slab.allocated_buffers += 1;

        if (slab.allocated_buffers == self.buffers_per_slab) {
            @branchHint(.unlikely);
            self.available_slabs.remove(&slab.linkage);
            self.full_slabs.append(&slab.linkage);
        }

        self.lock.unlock(current_task);

        if (isSmallObject(self.size)) {
            const buffer_node_ptr: [*]u8 = @ptrCast(buffer_node);
            const buffer_ptr: [*]u8 = buffer_node_ptr - single_node_alignment.forward(self.size);
            return buffer_ptr[0..self.size];
        }

        const large_buffer: *LargeBuffer = @fieldParentPtr("node", buffer_node);
        return large_buffer.buffer;
    }

    /// Allocates a new slab.
    ///
    /// The cache's lock must be held when this is called, the lock is held on success and unlocked on failure.
    fn allocateSlab(self: *RawCache, current_task: *kernel.Task) AllocateError!*Slab {
        self.lock.unlock(current_task);

        self.allocate_mutex.lock(current_task);
        defer self.allocate_mutex.unlock(current_task);

        self.lock.lock(current_task);

        if (self.available_slabs.first) |slab_node| {
            // there is an available slab now, use it without allocating a new one
            return @fieldParentPtr("linkage", slab_node);
        }

        self.lock.unlock(current_task);

        if (isSmallObject(self.size)) {
            // small object slab

            const page_buffer_allocation = self.source.allocate(
                current_task,
                kernel.arch.paging.standard_page_size.value,
                .instant_fit,
            ) catch return AllocateError.SlabAllocationFailed;
            errdefer comptime unreachable;
            std.debug.assert(page_buffer_allocation.len == kernel.arch.paging.standard_page_size.value);

            const page_buffer_base_ptr: [*]u8 = @ptrFromInt(page_buffer_allocation.base);

            const slab: *Slab = @ptrFromInt(page_buffer_allocation.base + page_buffer_allocation.len - @sizeOf(Slab));
            slab.* = .{
                .large_object_allocation = undefined,
            };

            for (0..self.buffers_per_slab) |i| {
                const buffer_ptr = page_buffer_base_ptr + (i * self.effective_size);

                if (self.constructor) |constructor| {
                    constructor(buffer_ptr[0..self.size]);
                }

                const buffer_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                    buffer_ptr + single_node_alignment.forward(self.size),
                ));
                slab.buffers.prepend(buffer_node);
            }

            self.lock.lock(current_task);

            self.available_slabs.append(&slab.linkage);

            return slab;
        }

        // large object slab

        const large_buffer_size = self.effective_size * self.buffers_per_slab;

        const buffer_allocation = self.source.allocate(
            current_task,
            large_buffer_size,
            .instant_fit,
        ) catch return AllocateError.SlabAllocationFailed;
        errdefer self.source.deallocate(current_task, buffer_allocation);

        const buffer_base_ptr: [*]u8 = @ptrFromInt(buffer_allocation.base);

        const slab = try globals.slab_cache.allocate(current_task);
        slab.* = .{
            .large_object_allocation = buffer_allocation,
        };

        errdefer {
            while (slab.buffers.popFirst()) |large_buffer_node| {
                globals.large_buffer_cache.free(
                    current_task,
                    @fieldParentPtr("node", large_buffer_node),
                );
            }

            globals.slab_cache.free(current_task, slab);
        }

        for (0..self.buffers_per_slab) |i| {
            const large_buffer = try globals.large_buffer_cache.allocate(current_task);

            const buffer: []u8 = (buffer_base_ptr + (i * self.effective_size))[0..self.size];

            large_buffer.* = .{
                .buffer = buffer,
                .slab = slab,
                .node = .{},
            };

            slab.buffers.prepend(&large_buffer.node);

            if (self.constructor) |constructor| {
                constructor(buffer);
            }
        }

        self.lock.lock(current_task);

        errdefer {
            var opt_node = slab.buffers.first;
            while (opt_node) |node| : (opt_node = node.next) {
                const large_buffer: *LargeBuffer = @fieldParentPtr("node", node);

                if (!self.large_object_hashmap.remove(@intFromPtr(large_buffer.buffer.ptr))) {
                    break;
                }
            }

            self.lock.unlock(current_task);
        }

        var opt_node = slab.buffers.first;
        while (opt_node) |node| : (opt_node = node.next) {
            const large_buffer: *LargeBuffer = @fieldParentPtr("node", node);
            self.large_object_hashmap.putNoClobber(@intFromPtr(large_buffer.buffer.ptr), large_buffer) catch
                return AllocateError.SlabAllocationFailed;
        }

        self.available_slabs.append(&slab.linkage);

        return slab;
    }

    /// Free a buffer back to the cache.
    pub fn free(self: *RawCache, current_task: *kernel.Task, buffer: []u8) void {
        const slab, const buffer_node = if (isSmallObject(self.size)) blk: {
            const page_start = std.mem.alignBackward(
                usize,
                @intFromPtr(buffer.ptr),
                kernel.arch.paging.standard_page_size.value,
            );

            const slab: *Slab = @ptrFromInt(page_start + kernel.arch.paging.standard_page_size.value - @sizeOf(Slab));

            const buffer_node: *SinglyLinkedList.Node = @ptrCast(@alignCast(
                buffer.ptr + single_node_alignment.forward(self.size),
            ));

            break :blk .{ slab, buffer_node };
        } else blk: {
            const large_buffer = self.large_object_hashmap.get(@intFromPtr(buffer.ptr)) orelse {
                @panic("large object not found in hashmap");
            };

            _ = self.large_object_hashmap.remove(@intFromPtr(buffer.ptr));

            break :blk .{ large_buffer.slab, &large_buffer.node };
        };

        self.lock.lock(current_task);

        if (slab.allocated_buffers == self.buffers_per_slab) {
            // slab was full, move it to available list
            self.full_slabs.remove(&slab.linkage);
            self.available_slabs.append(&slab.linkage);
        }

        slab.buffers.prepend(buffer_node);
        slab.allocated_buffers -= 1;

        if (slab.allocated_buffers == 0) deallocate: {
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
        if (isSmallObject(self.size)) {
            // small object slab

            const page_buffer_base = @intFromPtr(slab) + @sizeOf(Slab) - kernel.arch.paging.standard_page_size.value;

            const page_buffer_base_ptr: [*]u8 = @ptrFromInt(page_buffer_base);

            if (self.destructor) |destructor| {
                for (0..self.buffers_per_slab) |i| {
                    const buffer_ptr = page_buffer_base_ptr + (i * self.effective_size);

                    destructor(buffer_ptr[0..self.size]);
                }
            }

            const allocation: kernel.mem.ResourceArena.Allocation = .{
                .base = page_buffer_base,
                .len = kernel.arch.paging.standard_page_size.value,
            };

            self.source.deallocate(
                current_task,
                allocation,
            );

            return;
        }

        // large object slab

        while (slab.buffers.popFirst()) |large_buffer_node| {
            const large_buffer: *LargeBuffer = @fieldParentPtr("node", large_buffer_node);

            if (self.destructor) |destructor| {
                destructor(large_buffer.buffer);
            }

            globals.large_buffer_cache.free(current_task, large_buffer);
        }

        self.source.deallocate(current_task, slab.large_object_allocation);

        globals.slab_cache.free(current_task, slab);
    }

    const Slab = struct {
        linkage: DoublyLinkedList.Node = .{},
        buffers: SinglyLinkedList = .{},
        allocated_buffers: usize = 0,

        /// The full allocated buffer for large object slabs.
        ///
        /// Only set for large object slabs.
        large_object_allocation: kernel.mem.ResourceArena.Allocation,

        fn constructor(self: *Slab) void {
            self.* = .{};
        }
    };

    const LargeBuffer = struct {
        buffer: []u8,
        slab: *Slab,
        node: SinglyLinkedList.Node = .{},
    };

    inline fn isSmallObject(size: usize) bool {
        return size <= small_object_size.value;
    }
    const small_object_size = kernel.arch.paging.standard_page_size.divideScalar(8);
    const single_node_alignment: std.mem.Alignment = .fromByteUnits(@alignOf(SinglyLinkedList.Node));

    // TODO: this needs to be dynamically determined based on size of the object to minimize fragmentation
    const large_objects_per_slab = 16;
};

const CacheName = std.BoundedArray(u8, kernel.config.cache_name_length);

const globals = struct {
    /// Initialized during `init.initializeCaches`.
    var slab_cache: Cache(RawCache.Slab, null, null) = undefined;

    /// Initialized during `init.initializeCaches`.
    var large_buffer_cache: Cache(RawCache.LargeBuffer, null, null) = undefined;
};

pub const init = struct {
    pub fn initializeCaches() !void {
        globals.slab_cache.init(
            try .fromSlice("slab"),
            .{ .source = &kernel.mem.heap.globals.heap_arena },
        );

        globals.large_buffer_cache.init(
            try .fromSlice("large buffer ctl"),
            .{ .source = &kernel.mem.heap.globals.heap_arena },
        );
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const SinglyLinkedList = std.SinglyLinkedList;
const DoublyLinkedList = std.DoublyLinkedList;
