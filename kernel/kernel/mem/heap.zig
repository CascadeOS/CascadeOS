// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const resource_arena = kernel.mem.resource_arena;
const core = @import("core");

const log = kernel.debug.log.scoped(.heap);

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = allocator_impl.alloc,
        .resize = allocator_impl.resize,
        .remap = allocator_impl.remap,
        .free = allocator_impl.free,
    },
};

/// This should only be called by uACPI.
pub fn freeWithNoSize(ptr: [*]u8) void {
    globals.heap_arena.deallocate(allocator_impl.getAllocationHeader(ptr).*);
}

pub const AllocateError = error{
    ZeroLength,

    OutOfMemory,
};

pub fn allocate(size: core.Size) AllocateError!core.VirtualRange {
    const allocation = globals.heap_arena.allocate(size.value, .instant_fit) catch |err|
        return switch (err) {
            error.ZeroLength => error.ZeroLength,
            else => error.OutOfMemory,
        };

    const virtual_range = allocation.toVirtualRange();

    if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

    return virtual_range;
}

/// The `range` provided must be exactly the same as the one returned by `allocate`.
pub inline fn deallocate(range: core.VirtualRange) void {
    globals.heap_arena.deallocate(.fromVirtualRange(range));
}

pub fn allocateSpecial(
    size: core.Size,
    physical_range: core.PhysicalRange,
    map_type: kernel.mem.MapType,
) AllocateError!core.VirtualRange {
    const allocation = globals.special_heap_address_space_arena.allocate(
        size.value,
        .instant_fit,
    ) catch |err| return switch (err) {
        error.ZeroLength => error.ZeroLength,
        else => error.OutOfMemory,
    };
    errdefer globals.special_heap_address_space_arena.deallocate(allocation);

    const virtual_range = allocation.toVirtualRange();

    globals.special_heap_page_table_mutex.lock();
    defer globals.special_heap_page_table_mutex.unlock();

    kernel.mem.mapRangeToPhysicalRange(
        kernel.mem.kernelPageTable(),
        virtual_range,
        physical_range,
        map_type,
        .kernel,
        .keep,
        kernel.mem.PhysicalPage.allocator,
    ) catch |err| switch (err) {
        error.AlreadyMapped, error.MappingNotValid => std.debug.panic("allocate special failed: {s}", .{@errorName(err)}),
        error.PagesExhausted => return error.OutOfMemory,
    };

    return virtual_range;
}

/// The `virtual_range` provided must be exactly the same as the one returned by `allocateSpecial`.
pub fn deallocateSpecial(virtual_range: core.VirtualRange) void {
    {
        globals.special_heap_page_table_mutex.lock();
        defer globals.special_heap_page_table_mutex.unlock();

        var unmap_batch: kernel.mem.VirtualRangeBatch = .{};
        std.debug.assert(unmap_batch.append(virtual_range));

        kernel.mem.unmap(
            kernel.mem.kernelPageTable(),
            &unmap_batch,
            .kernel,
            .keep,
            .keep,
            kernel.mem.PhysicalPage.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(.fromVirtualRange(virtual_range));
}

pub const heap_page_arena = &globals.heap_page_arena;

const allocator_impl = struct {
    const Allocation = kernel.mem.resource_arena.Allocation;
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const alignment_bytes = alignment.toByteUnits();
        const full_len = len + alignment_bytes - 1 + @sizeOf(Allocation);

        const allocation = globals.heap_arena.allocate(
            full_len,
            .instant_fit,
        ) catch return null;

        const unaligned_ptr: [*]u8 = @ptrFromInt(allocation.base);
        const unaligned_addr = @intFromPtr(unaligned_ptr);
        const aligned_addr = alignment.forward(unaligned_addr + @sizeOf(Allocation));
        const aligned_ptr = unaligned_ptr + (aligned_addr - unaligned_addr);

        getAllocationHeader(aligned_ptr).* = allocation;

        return aligned_ptr;
    }

    fn resize(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        if (core.is_debug) std.debug.assert(new_len != 0);
        const allocation = getAllocationHeader(memory.ptr);
        return new_len <= allocation.len;
    }

    fn remap(
        current_task: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        // TODO: resource arena can support this, find allocation and check if next tag is free

        return if (resize(current_task, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    fn free(
        _: *anyopaque,
        memory: []u8,
        _: std.mem.Alignment,
        _: usize,
    ) void {
        globals.heap_arena.deallocate(getAllocationHeader(memory.ptr).*);
    }

    inline fn getAllocationHeader(ptr: [*]u8) *align(1) Allocation {
        return @ptrCast(ptr - @sizeOf(Allocation));
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

            kernel.mem.mapRangeAndBackWithPhysicalPages(
                kernel.mem.kernelPageTable(),
                virtual_range,
                .{ .type = .kernel, .protection = .read_write },
                .kernel,
                .keep,
                kernel.mem.PhysicalPage.allocator,
            ) catch return resource_arena.AllocateError.RequestedLengthUnavailable;
        }
        errdefer comptime unreachable;

        if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

        return allocation;
    }

    fn heapPageArenaRelease(
        arena_ptr: *anyopaque,
        allocation: resource_arena.Allocation,
    ) void {
        const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

        log.verbose("unmapping {f} from heap", .{allocation});

        {
            var unmap_batch: kernel.mem.VirtualRangeBatch = .{};
            unmap_batch.appendMergeIfFull(allocation.toVirtualRange());

            globals.heap_page_table_mutex.lock();
            defer globals.heap_page_table_mutex.unlock();

            kernel.mem.unmap(
                kernel.mem.kernelPageTable(),
                &unmap_batch,
                .kernel,
                .free,
                .keep,
                kernel.mem.PhysicalPage.allocator,
            );
        }

        arena.deallocate(allocation);
    }

    const heap_arena_quantum: usize = 16;
    const heap_arena_quantum_caches: usize = 512 / heap_arena_quantum; // cache up to 512 bytes
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

    var heap_page_table_mutex: kernel.sync.Mutex = .{};

    /// An arena managing the special heap region's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire range.
    ///
    /// Initialized during `init.initializeHeaps`.
    var special_heap_address_space_arena: kernel.mem.resource_arena.Arena(.none) = undefined;

    var special_heap_page_table_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    const init_log = kernel.debug.log.scoped(.heap_init);

    pub fn initializeHeaps(
        kernel_regions: *const kernel.mem.KernelMemoryRegion.List,
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
