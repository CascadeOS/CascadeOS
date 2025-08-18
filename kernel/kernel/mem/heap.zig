// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.
//!
//! Each allocation is a multiple of the standard page size.

pub fn allocate(len: usize, context: *kernel.Context) !core.VirtualRange {
    const allocation = try globals.heap_arena.allocate(
        context,
        len,
        .instant_fit,
    );

    const virtual_range: core.VirtualRange = .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };

    if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

    return virtual_range;
}

pub fn deallocate(range: core.VirtualRange, context: *kernel.Context) void {
    globals.heap_arena.deallocate(context, .{
        .base = range.address.value,
        .len = range.size.value,
    });
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
    context: *kernel.Context,
    size: core.Size,
    physical_range: core.PhysicalRange,
    map_type: kernel.mem.MapType,
) !core.VirtualRange {
    const allocation = try globals.special_heap_address_space_arena.allocate(
        context,
        size.value,
        .instant_fit,
    );
    errdefer globals.special_heap_address_space_arena.deallocate(context, allocation);

    const virtual_range: core.VirtualRange = .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };

    globals.special_heap_page_table_mutex.lock(context);
    defer globals.special_heap_page_table_mutex.unlock(context);

    try kernel.mem.mapRangeToPhysicalRange(
        context,
        kernel.mem.globals.core_page_table,
        virtual_range,
        physical_range,
        map_type,
        .kernel,
        .keep,
        kernel.mem.phys.allocator,
    );

    return virtual_range;
}

pub fn deallocateSpecial(
    context: *kernel.Context,
    virtual_range: core.VirtualRange,
) void {
    {
        globals.special_heap_page_table_mutex.lock(context);
        defer globals.special_heap_page_table_mutex.unlock(context);

        kernel.mem.unmapRange(
            context,
            kernel.mem.globals.core_page_table,
            virtual_range,
            .kernel,
            .nop,
            .nop,
            kernel.mem.phys.allocator,
        );
    }

    globals.special_heap_address_space_arena.deallocate(
        context,
        .{ .base = virtual_range.address.value, .len = virtual_range.size.value },
    );
}

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
        std.debug.assert(new_len != 0);
        const allocation = getAllocationHeader(memory.ptr);
        return new_len <= allocation.len;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        // TODO: resource arena can support this, find allocation and check if next tag is free

        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
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
};

fn heapPageArenaImport(
    arena_ptr: *anyopaque,
    context: *kernel.Context,
    len: usize,
    policy: resource_arena.Policy,
) resource_arena.AllocateError!resource_arena.Allocation {
    const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

    const allocation = try arena.allocate(
        context,
        len,
        policy,
    );
    errdefer arena.deallocate(context, allocation);

    log.verbose(context, "mapping {f} into heap", .{allocation});

    const virtual_range: core.VirtualRange = .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };

    {
        globals.heap_page_table_mutex.lock(context);
        defer globals.heap_page_table_mutex.unlock(context);

        kernel.mem.mapRangeAndBackWithPhysicalFrames(
            context,
            kernel.mem.globals.core_page_table,
            virtual_range,
            .{ .environment_type = .kernel, .protection = .read_write },
            .kernel,
            .keep,
            kernel.mem.phys.allocator,
        ) catch return resource_arena.AllocateError.RequestedLengthUnavailable;
    }
    errdefer comptime unreachable;

    if (core.is_debug) @memset(virtual_range.toByteSlice(), undefined);

    return allocation;
}

fn heapPageArenaRelease(
    arena_ptr: *anyopaque,
    context: *kernel.Context,
    allocation: resource_arena.Allocation,
) void {
    const arena: *Arena = @ptrCast(@alignCast(arena_ptr));

    log.verbose(context, "unmapping {f} from heap", .{allocation});

    {
        globals.heap_page_table_mutex.lock(context);
        defer globals.heap_page_table_mutex.unlock(context);

        kernel.mem.unmapRange(
            context,
            kernel.mem.globals.core_page_table,
            .{
                .address = .fromInt(allocation.base),
                .size = .from(allocation.len, .byte),
            },
            .kernel,
            .free,
            .keep,
            kernel.mem.phys.allocator,
        );
    }

    arena.deallocate(
        context,
        allocation,
    );
}

const heap_arena_quantum: usize = 16;
const heap_arena_quantum_caches: usize = 512 / heap_arena_quantum; // cache up to 512 bytes

pub const globals = struct {
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
    pub var heap_page_arena: Arena = undefined;

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
    pub fn initializeHeaps(
        context: *kernel.Context,
        heap_range: core.VirtualRange,
        special_heap_range: core.VirtualRange,
    ) !void {
        // heap
        {
            try globals.heap_address_space_arena.init(
                context,
                .{
                    .name = try .fromSlice("heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            try globals.heap_page_arena.init(
                context,
                .{
                    .name = try .fromSlice("heap_page"),
                    .quantum = arch.paging.standard_page_size.value,
                    .source = globals.heap_address_space_arena.createSource(.{
                        .custom_import = heapPageArenaImport,
                        .custom_release = heapPageArenaRelease,
                    }),
                },
            );

            try globals.heap_arena.init(
                context,
                .{
                    .name = try .fromSlice("heap"),
                    .quantum = heap_arena_quantum,
                    .source = globals.heap_page_arena.createSource(.{}),
                },
            );

            globals.heap_address_space_arena.addSpan(
                context,
                heap_range.address.value,
                heap_range.size.value,
            ) catch |err| {
                std.debug.panic("failed to add heap range to `heap_address_space_arena`: {t}", .{err});
            };
        }

        // special heap
        {
            try globals.special_heap_address_space_arena.init(
                context,
                .{
                    .name = try .fromSlice("special_heap_address_space"),
                    .quantum = arch.paging.standard_page_size.value,
                },
            );

            globals.special_heap_address_space_arena.addSpan(
                context,
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

const resource_arena = kernel.mem.resource_arena;
const Arena = resource_arena.Arena(.none);
const HeapArena = resource_arena.Arena(.{ .heap = heap_arena_quantum_caches });

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.heap);
const std = @import("std");
