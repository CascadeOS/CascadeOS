// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

//! Provides a kernel heap.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
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

/// Allocate a range of memory that is mapped to a specific physical range with the given map type.
pub fn allocateSpecial(
    physical_range: cascade.PhysicalRange,
    map_type: AllocatorSpecialMapType,
) AllocateError!cascade.KernelVirtualRange {
    const page_aligned_physical_range = physical_range.pageAlign();

    const allocation = globals.special_heap_address_space_arena.allocate(
        page_aligned_physical_range.size.value,
        .instant_fit,
    ) catch |err| {
        @branchHint(.unlikely);
        return switch (err) {
            error.ZeroLength => error.ZeroLength,
            error.RequestedLengthUnavailable, error.OutOfBoundaryTags => error.OutOfMemory,
        };
    };
    errdefer globals.special_heap_address_space_arena.deallocate(allocation);

    const page_aligned_virtual_range = allocation.toVirtualRange();

    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        cascade.mem.mapRangeToPhysicalRange(
            cascade.mem.kernelPageTable(),
            page_aligned_virtual_range.toVirtualRange(),
            page_aligned_physical_range,
            .{
                .type = .kernel,
                .protection = map_type.protection,
                .cache = map_type.cache,
            },
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
    }

    return .from(
        page_aligned_virtual_range.address.moveForward(page_aligned_physical_range.address.difference(physical_range.address)),
        physical_range.size,
    );
}

/// Deallocate a range of memory that was allocated by `allocateSpecial`.
///
/// **REQUIREMENTS**:
/// - `virtual_range` must be a range that was previously allocated by `allocateSpecial`.
pub fn deallocateSpecial(virtual_range: cascade.KernelVirtualRange) void {
    const page_aligned_virtual_range = virtual_range.pageAlign();

    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        var unmap_batch: cascade.mem.VirtualRangeBatch = .{};
        std.debug.assert(unmap_batch.append(page_aligned_virtual_range.toVirtualRange()));

        cascade.mem.unmap(
            cascade.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .keep,
            .keep,
            cascade.mem.PhysicalPage.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(.fromVirtualRange(page_aligned_virtual_range));
}

pub const AllocateError = error{
    ZeroLength,
    OutOfMemory,
};

pub const AllocatorSpecialMapType = struct {
    protection: cascade.mem.MapType.Protection,
    cache: cascade.mem.MapType.Cache,
};

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

        const mem = allocator.alignedAlloc(u8, .@"16", size) catch {
            @branchHint(.unlikely);
            return null;
        };

        return mem.ptr;
    }

    /// Free a block of memory allocated with 'mallocWithSizedFree'.
    pub fn sizedFree(opt_ptr: ?[*]u8, size: usize) void {
        const ptr = opt_ptr orelse {
            @branchHint(.unlikely);
            return;
        };
        allocator.rawFree(ptr[0..size], .@"16", @returnAddress());
    }

    /// Allocate a block of memory of 'size' bytes.
    ///
    /// Freeing the memory must be done with 'nonSizedFree'.
    pub fn mallocWithNonSizedFree(size: usize) ?[*]u8 {
        const full_size = core.Size.from(size, .byte).add(.of(cascade.KernelVirtualRange));

        const mem = allocator.alignedAlloc(u8, .@"16", full_size) catch {
            @branchHint(.unlikely);
            return null;
        };

        const result_ptr = mem.ptr + @sizeOf(cascade.KernelVirtualRange);

        getAllocationHeader(result_ptr).* = .fromSlice(u8, mem);

        return result_ptr;
    }

    /// Free a block of memory allocated with 'mallocWithNonSizedFree'.
    pub fn nonSizedFree(opt_ptr: ?[*]u8) void {
        const ptr = opt_ptr orelse {
            @branchHint(.unlikely);
            return;
        };
        allocator.rawFree(
            getAllocationHeader(ptr).byteSlice(),
            .@"16",
            @returnAddress(),
        );
    }

    inline fn getAllocationHeader(ptr: [*]align(heap_arena_quantum) u8) *cascade.KernelVirtualRange {
        return @ptrCast(@alignCast(ptr - @sizeOf(cascade.KernelVirtualRange)));
    }
};

const allocator_impl = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        if (core.is_debug) std.debug.assert(len != 0);

        if (alignment.toByteUnits() <= heap_arena_quantum) {
            // no need to overallocate to ensure alignment
            const allocation = globals.heap_arena.allocate(len, .instant_fit) catch {
                @branchHint(.unlikely);
                return null;
            };
            return allocation.toVirtualRange().address.toPtr([*]u8);
        }

        const unaligned_allocation = globals.heap_arena.allocate(
            len + alignment.toByteUnits() - 1,
            .instant_fit,
        ) catch {
            @branchHint(.unlikely);
            return null;
        };
        return unaligned_allocation.toVirtualRange().address.alignForward(alignment).toPtr([*]u8);
    }

    fn resize(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        if (core.is_debug) {
            std.debug.assert(memory.len != 0);
            std.debug.assert(new_len != 0);
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
        if (core.is_debug) std.debug.assert(memory.len != 0);

        const unaligned_range: cascade.KernelVirtualRange = .fromSlice(u8, memory);

        const aligned_range: cascade.KernelVirtualRange = if (alignment.toByteUnits() <= heap_arena_quantum)
            .from(
                unaligned_range.address,
                unaligned_range.size.alignForward(heap_arena_quantum_size_alignment),
            )
        else
            .from(
                unaligned_range.address
                    .moveBackward(.one)
                    .alignBackward(alignment),
                unaligned_range.size
                    .add(.from(alignment.toByteUnits(), .byte))
                    .subtract(.one)
                    .alignForward(heap_arena_quantum_size_alignment),
            );

        globals.heap_arena.deallocate(.fromVirtualRange(aligned_range));
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
                .{ .type = .kernel, .protection = .{ .read = true, .write = true } },
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
};

const heap_arena_quantum: usize = 16;
const heap_arena_quantum_caches: usize = 512 / heap_arena_quantum; // cache up to 512 bytes

const heap_arena_quantum_size: core.Size = .from(heap_arena_quantum, .byte);
const heap_arena_quantum_size_alignment = heap_arena_quantum_size.toAlignment();

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
                    .quantum = heap_arena_quantum,
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
const HeapArena = resource_arena.Arena(.{ .heap = heap_arena_quantum_caches });
