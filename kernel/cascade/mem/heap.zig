// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const resource_arena = cascade.mem.resource_arena;
const core = @import("core");

const log = cascade.debug.log.scoped(.heap);

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = allocator_impl.alloc,
        .resize = allocator_impl.resize,
        .remap = allocator_impl.remap,
        .free = allocator_impl.free,
    },
};

pub const AllocateError = error{
    ZeroLength,
    OutOfMemory,
};

pub fn allocate(size: core.Size) AllocateError!cascade.KernelVirtualRange {
    const allocation = globals.heap_arena.allocate(size.value, .instant_fit) catch |err| {
        @branchHint(.unlikely);
        return switch (err) {
            error.ZeroLength => error.ZeroLength,
            else => error.OutOfMemory,
        };
    };

    var virtual_range = allocation.toVirtualRange();

    if (core.is_debug) @memset(virtual_range.byteSlice(), undefined);

    // the range returned by the heap arena will be aligned to the quantum size, but we want to return the size requested
    virtual_range.size = size;

    return virtual_range;
}

pub fn deallocate(range: cascade.KernelVirtualRange) void {
    globals.heap_arena.deallocate(
        .fromVirtualRange(.from(
            range.address,
            range.size.alignForward(allocator_impl.heap_arena_quantum_size_alignment),
        )),
    );
}

/// Allocate a range of memory that is mapped to a specific physical range with the given map type.
///
/// **REQUIREMENTS**:
/// - `size` must be equal to `physical_range.size`.
/// - `size` must be aligned to `arch.paging.standard_page_size`.
/// - `physical_range.address` must be aligned to `arch.paging.standard_page_size`.
pub fn allocateSpecial(
    size: core.Size,
    physical_range: cascade.PhysicalRange,
    map_type: cascade.mem.MapType,
) AllocateError!cascade.KernelVirtualRange {
    if (core.is_debug) {
        std.debug.assert(size.equal(physical_range.size));
        std.debug.assert(size.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(physical_range.address.aligned(arch.paging.standard_page_size_alignment));
    }

    const allocation = globals.special_heap_address_space_arena.allocate(
        size.value,
        .instant_fit,
    ) catch |err| {
        @branchHint(.unlikely);
        return switch (err) {
            error.ZeroLength => error.ZeroLength,
            else => error.OutOfMemory,
        };
    };
    errdefer globals.special_heap_address_space_arena.deallocate(allocation);

    const virtual_range = allocation.toVirtualRange();

    globals.special_heap_page_table_mutex.lock();
    defer globals.special_heap_page_table_mutex.unlock();

    cascade.mem.mapRangeToPhysicalRange(
        cascade.mem.kernelPageTable(),
        virtual_range.toVirtualRange(),
        physical_range,
        map_type,
        .kernel,
        .keep,
        cascade.mem.PhysicalPage.allocator,
    ) catch |err| {
        @branchHint(.unlikely);
        switch (err) {
            error.AlreadyMapped, error.MappingNotValid => std.debug.panic("allocate special failed: {s}", .{@errorName(err)}),
            error.PagesExhausted => return error.OutOfMemory,
        }
    };

    return virtual_range;
}

/// Deallocate a range of memory that was allocated by `allocateSpecial`.
///
/// **REQUIREMENTS**:
/// - `virtual_range` must be a range that was previously allocated by `allocateSpecial`.
pub fn deallocateSpecial(virtual_range: cascade.KernelVirtualRange) void {
    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        var unmap_batch: cascade.mem.VirtualRangeBatch = .{};
        std.debug.assert(unmap_batch.append(virtual_range.toVirtualRange()));

        cascade.mem.unmap(
            cascade.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .keep,
            .keep,
            cascade.mem.PhysicalPage.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(.fromVirtualRange(virtual_range));
}

// pub to allow access by `cascade.mem.cache`
pub const heap_page_arena = &globals.heap_page_arena;

/// These functions are provided to allow C code to use the heap allocator and should not be used by zig code.
pub const c = struct {
    /// Allocate a block of memory of 'size' bytes.
    ///
    /// Freeing the memory must be done with 'sizedFree'.
    pub fn mallocWithSizedFree(size: usize) ?[*]u8 {
        if (size == 0) {
            @branchHint(.unlikely);
            return null;
        }
        const virtual_range = allocate(.from(size, .byte)) catch {
            @branchHint(.unlikely);
            return null;
        };
        return virtual_range.address.ptr([*]u8);
    }

    /// Free a block of memory allocated with 'mallocWithSizedFree'.
    pub fn sizedFree(opt_ptr: ?[*]u8, size: usize) void {
        const ptr = opt_ptr orelse {
            @branchHint(.unlikely);
            return;
        };
        if (core.is_debug) std.debug.assert(size != 0);
        deallocate(.fromSlice(u8, ptr[0..size]));
    }

    /// Allocate a block of memory of 'size' bytes.
    ///
    /// Freeing the memory must be done with 'nonSizedFree'.
    pub fn mallocWithNonSizedFree(size: usize) ?[*]u8 {
        // this function assumes that the C code expects an alignment of 16 bytes or less
        comptime {
            std.debug.assert(allocator_impl.heap_arena_quantum >= 16);
            std.debug.assert(allocator_impl.heap_arena_quantum_size.equal(.of(Allocation)));
        }

        const allocation = globals.heap_arena.allocate(
            size + @sizeOf(Allocation),
            .instant_fit,
        ) catch {
            @branchHint(.unlikely);
            return null;
        };

        if (core.is_debug) @memset(allocation.toVirtualRange().byteSlice(), undefined);

        const base_ptr: [*]u8 = @ptrFromInt(allocation.base);
        const result_ptr = base_ptr + @sizeOf(Allocation);

        getAllocationHeader(result_ptr).* = allocation;

        return result_ptr;
    }

    /// Free a block of memory allocated with 'mallocWithNonSizedFree'.
    pub fn nonSizedFree(opt_ptr: ?[*]u8) void {
        const ptr = opt_ptr orelse {
            @branchHint(.unlikely);
            return;
        };
        globals.heap_arena.deallocate(getAllocationHeader(ptr).*);
    }

    inline fn getAllocationHeader(ptr: [*]u8) *Allocation {
        return @ptrCast(@alignCast(ptr - @sizeOf(Allocation)));
    }

    const Allocation = cascade.mem.resource_arena.Allocation;
};

const allocator_impl = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        if (core.is_debug) std.debug.assert(len != 0);

        const alignment_bytes = alignment.toByteUnits();
        if (alignment_bytes > heap_arena_quantum) @panic("alignment greater than heap quantum");

        const allocation = globals.heap_arena.allocate(len, .instant_fit) catch {
            @branchHint(.unlikely);
            return null;
        };

        // no need to set to `undefined` as the allocator interface will do it for us
        return allocation.toVirtualRange().address.ptr([*]u8);
    }

    fn resize(
        _: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        if (core.is_debug) {
            std.debug.assert(memory.len != 0);
            std.debug.assert(new_len != 0);
            std.debug.assert(alignment.toByteUnits() <= heap_arena_quantum);
        }

        const max_allowed_size = std.mem.alignForward(
            usize,
            memory.len,
            heap_arena_quantum,
        );

        return new_len <= max_allowed_size;
    }

    fn remap(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        // TODO: resource arena can support this, find allocation and check if next tag is free
        return if (resize(ptr, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    fn free(
        _: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        _: usize,
    ) void {
        if (core.is_debug) {
            std.debug.assert(memory.len != 0);
            std.debug.assert(alignment.toByteUnits() <= heap_arena_quantum);
        }

        globals.heap_arena.deallocate(
            .fromVirtualRange(
                .{
                    .address = .from(@intFromPtr(memory.ptr)),
                    .size = core.Size.from(memory.len, .byte).alignForward(heap_arena_quantum_size_alignment),
                },
            ),
        );
    }

    fn heapPageArenaImport(
        arena_ptr: *anyopaque,
        len: usize,
        policy: resource_arena.Policy,
    ) resource_arena.AllocateError!resource_arena.Allocation {
        const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

        const allocation = try arena.allocate(
            len,
            policy,
        );
        errdefer arena.deallocate(allocation);

        log.verbose("mapping {f} into heap", .{allocation});

        const virtual_range = allocation.toVirtualRange();

        {
            globals.heap_page_table_mutex.lock();
            defer globals.heap_page_table_mutex.unlock();

            cascade.mem.mapRangeAndBackWithPhysicalPages(
                cascade.mem.kernelPageTable(),
                virtual_range.toVirtualRange(),
                .{ .type = .kernel, .protection = .read_write },
                .kernel,
                .keep,
                cascade.mem.PhysicalPage.allocator,
            ) catch {
                @branchHint(.unlikely);
                return resource_arena.AllocateError.RequestedLengthUnavailable;
            };
        }
        errdefer comptime unreachable;

        if (core.is_debug) @memset(virtual_range.byteSlice(), undefined);

        return allocation;
    }

    fn heapPageArenaRelease(
        arena_ptr: *anyopaque,
        allocation: resource_arena.Allocation,
    ) void {
        const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

        log.verbose("unmapping {f} from heap", .{allocation});

        {
            var unmap_batch: cascade.mem.VirtualRangeBatch = .{};
            unmap_batch.appendMergeIfFull(allocation.toVirtualRange().toVirtualRange());

            globals.heap_page_table_mutex.lock();
            defer globals.heap_page_table_mutex.unlock();

            cascade.mem.unmap(
                cascade.mem.kernelPageTable(),
                &unmap_batch,
                .kernel,
                .free,
                .keep,
                cascade.mem.PhysicalPage.allocator,
            );
        }

        arena.deallocate(allocation);
    }

    const heap_arena_quantum: usize = 16;
    const heap_arena_quantum_caches: usize = 512 / heap_arena_quantum; // cache up to 512 bytes

    const heap_arena_quantum_size: core.Size = .from(heap_arena_quantum, .byte);
    const heap_arena_quantum_size_alignment = heap_arena_quantum_size.toAlignment();
};

const globals = struct {
    /// An arena managing the heap's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire heap.
    ///
    /// Initialized during `init.initializeHeaps`.
    var heap_address_space_arena: Arena = undefined;

    /// The heap page arena, has a quantum of the standard page size.
    ///
    /// Has a source arena of `heap_address_space_arena`. Backs imported spans with physical memory.
    ///
    /// Initialized during `init.initializeHeaps`.
    var heap_page_arena: Arena = undefined;

    /// The heap arena.
    ///
    /// Has a source arena of `heap_page_arena`.
    ///
    /// Initialized during `init.initializeHeaps`.
    var heap_arena: HeapArena = undefined;

    var heap_page_table_mutex: cascade.sync.Mutex = .{};

    /// An arena managing the special heap region's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire range.
    ///
    /// Initialized during `init.initializeHeaps`.
    var special_heap_address_space_arena: cascade.mem.resource_arena.Arena(.none) = undefined;

    var special_heap_page_table_mutex: cascade.sync.Mutex = .{};
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.heap_init);

    pub fn initializeHeaps(
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        // heap
        {
            init_log.debug("initializing heap address space arena", .{});
            try globals.heap_address_space_arena.init(
                .{
                    .name = try .fromSlice("heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            init_log.debug("initializing heap page arena", .{});
            try globals.heap_page_arena.init(
                .{
                    .name = try .fromSlice("heap_page"),
                    .quantum = arch.paging.standard_page_size.value,
                    .source = globals.heap_address_space_arena.createSource(.{
                        .custom_import = allocator_impl.heapPageArenaImport,
                        .custom_release = allocator_impl.heapPageArenaRelease,
                    }),
                },
            );

            init_log.debug("initializing heap arena", .{});
            try globals.heap_arena.init(
                .{
                    .name = try .fromSlice("heap"),
                    .quantum = allocator_impl.heap_arena_quantum,
                    .source = globals.heap_page_arena.createSource(.{}),
                },
            );

            const heap_range = kernel_regions.find(.kernel_heap).?.range;

            globals.heap_address_space_arena.addSpan(
                heap_range.address.value,
                heap_range.size.value,
            ) catch |err| {
                std.debug.panic("failed to add heap range to `heap_address_space_arena`: {t}", .{err});
            };
        }

        // special heap
        {
            init_log.debug("initializing special heap address space arena", .{});
            try globals.special_heap_address_space_arena.init(
                .{
                    .name = try .fromSlice("special_heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            const special_heap_range = kernel_regions.find(.special_heap).?.range;

            init_log.debug("adding special heap range to special heap address space arena", .{});
            globals.special_heap_address_space_arena.addSpan(
                special_heap_range.address.value,
                special_heap_range.size.value,
            ) catch |err| {
                std.debug.panic(
                    "failed to add special heap range to `special_heap_address_space_arena`: {t}",
                    .{err},
                );
            };
        }
    }
};

const Arena = resource_arena.Arena(.none);
const HeapArena = resource_arena.Arena(.{ .heap = allocator_impl.heap_arena_quantum_caches });
