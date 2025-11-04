// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const resource_arena = cascade.mem.resource_arena;
const core = @import("core");

const log = cascade.debug.log.scoped(.heap);

pub fn allocate(len: usize, current_task: Task.Current) !core.VirtualRange {
    const allocation = try globals.heap_arena.allocate(
        current_task,
        len,
        .instant_fit,
    );

    const virtual_range = allocation.toVirtualRange();

    if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

    return virtual_range;
}

pub inline fn deallocate(range: core.VirtualRange, current_task: Task.Current) void {
    globals.heap_arena.deallocate(current_task, .fromVirtualRange(range));
}

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
    globals.heap_arena.deallocate(.current(), allocator_impl.getAllocationHeader(ptr).*);
}

pub fn allocateSpecial(
    current_task: Task.Current,
    size: core.Size,
    physical_range: core.PhysicalRange,
    map_type: cascade.mem.MapType,
) !core.VirtualRange {
    const allocation = try globals.special_heap_address_space_arena.allocate(
        current_task,
        size.value,
        .instant_fit,
    );
    errdefer globals.special_heap_address_space_arena.deallocate(current_task, allocation);

    const virtual_range = allocation.toVirtualRange();

    globals.special_heap_page_table_mutex.lock(current_task);
    defer globals.special_heap_page_table_mutex.unlock(current_task);

    try cascade.mem.mapRangeToPhysicalRange(
        current_task,
        cascade.mem.kernelPageTable(),
        virtual_range,
        physical_range,
        map_type,
        .kernel,
        .keep,
        cascade.mem.phys.allocator,
    );

    return virtual_range;
}

pub fn deallocateSpecial(
    current_task: Task.Current,
    virtual_range: core.VirtualRange,
) void {
    {
        globals.special_heap_page_table_mutex.lock(current_task);
        defer globals.special_heap_page_table_mutex.unlock(current_task);

        cascade.mem.unmapRange(
            current_task,
            cascade.mem.globals.core_page_table,
            virtual_range,
            .kernel,
            .nop,
            .nop,
            cascade.mem.phys.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(current_task, .fromVirtualRange(virtual_range));
}

pub const heap_page_arena = &globals.heap_page_arena;

const allocator_impl = struct {
    const Allocation = cascade.mem.resource_arena.Allocation;
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        const alignment_bytes = alignment.toByteUnits();
        const full_len = len + alignment_bytes - 1 + @sizeOf(Allocation);

        const allocation = globals.heap_arena.allocate(
            .current(),
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
        globals.heap_arena.deallocate(.current(), getAllocationHeader(memory.ptr).*);
    }

    inline fn getAllocationHeader(ptr: [*]u8) *align(1) Allocation {
        return @ptrCast(ptr - @sizeOf(Allocation));
    }

    fn heapPageArenaImport(
        arena_ptr: *anyopaque,
        current_task: Task.Current,
        len: usize,
        policy: resource_arena.Policy,
    ) resource_arena.AllocateError!resource_arena.Allocation {
        const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

        const allocation = try arena.allocate(
            current_task,
            len,
            policy,
        );
        errdefer arena.deallocate(current_task, allocation);

        log.verbose(current_task, "mapping {f} into heap", .{allocation});

        const virtual_range = allocation.toVirtualRange();

        {
            globals.heap_page_table_mutex.lock(current_task);
            defer globals.heap_page_table_mutex.unlock(current_task);

            cascade.mem.mapRangeAndBackWithPhysicalFrames(
                current_task,
                cascade.mem.kernelPageTable(),
                virtual_range,
                .{ .type = .kernel, .protection = .read_write },
                .kernel,
                .keep,
                cascade.mem.phys.allocator,
            ) catch return resource_arena.AllocateError.RequestedLengthUnavailable;
        }
        errdefer comptime unreachable;

        if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

        return allocation;
    }

    fn heapPageArenaRelease(
        arena_ptr: *anyopaque,
        current_task: Task.Current,
        allocation: resource_arena.Allocation,
    ) void {
        const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

        log.verbose(current_task, "unmapping {f} from heap", .{allocation});

        {
            globals.heap_page_table_mutex.lock(current_task);
            defer globals.heap_page_table_mutex.unlock(current_task);

            cascade.mem.unmapRange(
                current_task,
                cascade.mem.kernelPageTable(),
                allocation.toVirtualRange(),
                .kernel,
                .free,
                .keep,
                cascade.mem.phys.allocator,
            );
        }

        arena.deallocate(
            current_task,
            allocation,
        );
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
        current_task: Task.Current,
        kernel_regions: *const cascade.mem.KernelMemoryRegion.List,
    ) !void {
        // heap
        {
            init_log.debug(current_task, "initializing heap address space arena", .{});
            try globals.heap_address_space_arena.init(
                current_task,
                .{
                    .name = try .fromSlice("heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            init_log.debug(current_task, "initializing heap page arena", .{});
            try globals.heap_page_arena.init(
                current_task,
                .{
                    .name = try .fromSlice("heap_page"),
                    .quantum = arch.paging.standard_page_size.value,
                    .source = globals.heap_address_space_arena.createSource(.{
                        .custom_import = allocator_impl.heapPageArenaImport,
                        .custom_release = allocator_impl.heapPageArenaRelease,
                    }),
                },
            );

            init_log.debug(current_task, "initializing heap arena", .{});
            try globals.heap_arena.init(
                current_task,
                .{
                    .name = try .fromSlice("heap"),
                    .quantum = allocator_impl.heap_arena_quantum,
                    .source = globals.heap_page_arena.createSource(.{}),
                },
            );

            const heap_range = kernel_regions.find(.kernel_heap).?.range;

            globals.heap_address_space_arena.addSpan(
                current_task,
                heap_range.address.value,
                heap_range.size.value,
            ) catch |err| {
                std.debug.panic("failed to add heap range to `heap_address_space_arena`: {t}", .{err});
            };
        }

        // special heap
        {
            init_log.debug(current_task, "initializing special heap address space arena", .{});
            try globals.special_heap_address_space_arena.init(
                current_task,
                .{
                    .name = try .fromSlice("special_heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            const special_heap_range = kernel_regions.find(.special_heap).?.range;

            init_log.debug(current_task, "adding special heap range to special heap address space arena", .{});
            globals.special_heap_address_space_arena.addSpan(
                current_task,
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
