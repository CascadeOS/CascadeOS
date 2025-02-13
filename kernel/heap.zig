// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.
//!
//! Each allocation is a multiple of the standard page size.

pub fn allocate(len: usize, current_task: *kernel.Task) !core.VirtualRange {
    const allocation = try globals.heap_arena.allocate(
        current_task,
        len,
        .instant_fit,
    );

    return .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };
}

pub fn deallocate(range: core.VirtualRange, current_task: *kernel.Task) void {
    globals.heap_arena.deallocate(current_task, .{
        .base = range.address.value,
        .len = range.size.value,
    });
}

pub fn deallocateBase(base: core.VirtualAddress, current_task: *kernel.Task) void {
    globals.heap_arena.deallocateBase(current_task, base.value);
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

const allocator_impl = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        // Overallocate to account for alignment padding and store the original pointer before
        // the aligned address.

        const alignment_bytes = alignment.toByteUnits();
        const full_len = len + alignment_bytes - 1 + @sizeOf(usize);

        const allocation = globals.heap_arena.allocate(
            kernel.Task.getCurrent(),
            full_len,
            .instant_fit,
        ) catch return null;

        const aligned_addr = std.mem.alignForward(usize, allocation.base + @sizeOf(usize), alignment_bytes);

        const unaligned_ptr: [*]u8 = @ptrFromInt(allocation.base);
        const aligned_ptr = unaligned_ptr + (aligned_addr - allocation.base);
        getHeader(aligned_ptr).* = unaligned_ptr;

        return aligned_ptr;
    }

    fn resize(
        _: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        _: usize,
    ) bool {
        std.debug.assert(new_len != 0);

        const alignment_bytes = alignment.toByteUnits();
        const full_new_len = memory.len + alignment_bytes - 1 + @sizeOf(usize);

        // the current `ResourceArena` implementation does support arbitrary shrinking of allocations, but
        // once we add quantum caches it no longer would be possible to peform resizes that change the
        // quantum aligned length of the allocation

        const old_quantum_aligned_len = std.mem.alignForward(
            usize,
            memory.len,
            heap_arena_quantum,
        );
        const new_quantum_aligned_len = std.mem.alignForward(
            usize,
            full_new_len,
            heap_arena_quantum,
        );

        return new_quantum_aligned_len == old_quantum_aligned_len;
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
        // we have to use `deallocateBase` here because the true length of the allocation in `alloc` is not
        // returned to the caller due to the Allocator API
        globals.heap_arena.deallocateBase(
            kernel.Task.getCurrent(),
            @intFromPtr(getHeader(memory.ptr).*),
        );
    }

    fn getHeader(ptr: [*]u8) *[*]u8 {
        return @as(*[*]u8, @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize)));
    }
};

fn heapArenaImport(
    arena: *ResourceArena,
    current_task: *kernel.Task,
    len: usize,
    policy: ResourceArena.Policy,
) ResourceArena.AllocateError!ResourceArena.Allocation {
    const allocation = try arena.allocate(
        current_task,
        len,
        policy,
    );
    errdefer arena.deallocate(current_task, allocation);

    log.debug("mapping {} into heap", .{allocation});

    globals.heap_page_table_mutex.lock(current_task);
    defer globals.heap_page_table_mutex.unlock(current_task);

    kernel.vmm.mapRange(
        kernel.vmm.globals.core_page_table,
        .{
            .address = .fromInt(allocation.base),
            .size = .from(allocation.len, .byte),
        },
        .{ .writeable = true, .global = true },
        .kernel,
        true,
    ) catch return ResourceArena.AllocateError.RequestedLengthUnavailable;
    errdefer comptime unreachable;

    return allocation;
}

fn heapArenaRelease(
    arena: *ResourceArena,
    current_task: *kernel.Task,
    allocation: ResourceArena.Allocation,
) void {
    log.debug("unmapping {} from heap", .{allocation});

    {
        globals.heap_page_table_mutex.lock(current_task);
        defer globals.heap_page_table_mutex.unlock(current_task);

        kernel.vmm.unmapRange(
            kernel.vmm.globals.core_page_table,
            .{
                .address = .fromInt(allocation.base),
                .size = .from(allocation.len, .byte),
            },
            true,
            .kernel,
            true,
        );
    }

    arena.deallocate(
        current_task,
        allocation,
    );
}

pub fn allocateSpecial(
    current_task: *kernel.Task,
    size: core.Size,
    physical_range: core.PhysicalRange,
    map_type: kernel.vmm.MapType,
) !core.VirtualRange {
    const allocation = try globals.special_heap_address_space_arena.allocate(
        current_task,
        size.value,
        .instant_fit,
    );
    errdefer globals.special_heap_address_space_arena.deallocate(current_task, allocation);

    const virtual_range: core.VirtualRange = .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };

    globals.special_heap_page_table_mutex.lock(current_task);
    defer globals.special_heap_page_table_mutex.unlock(current_task);

    try kernel.vmm.mapToPhysicalRange(
        kernel.vmm.globals.core_page_table,
        virtual_range,
        physical_range,
        map_type,
        true,
    );

    return virtual_range;
}

pub fn deallocateSpecial(
    current_task: *kernel.Task,
    virtual_range: core.VirtualRange,
) void {
    {
        globals.special_heap_page_table_mutex.lock(current_task);
        defer globals.special_heap_page_table_mutex.unlock(current_task);

        kernel.vmm.unmapRange(
            kernel.vmm.globals.core_page_table,
            virtual_range,
            false,
            .kernel,
            true,
        );
    }

    globals.special_heap_address_space_arena.deallocate(
        current_task,
        .{ .base = virtual_range.address.value, .len = virtual_range.size.value },
    );
}

const heap_arena_quantum: usize = 16;

const globals = struct {
    /// An arena managing the heap's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire heap.
    ///
    /// Initialized during `init.initializeHeaps`.
    var heap_address_space_arena: ResourceArena = undefined;

    /// The heap arena.
    ///
    /// Has a source arena of `heap_address_space_arena`. Backs imported spans with physical memory.
    ///
    /// Initialized during `init.initializeHeaps`.
    var heap_arena: ResourceArena = undefined;

    var heap_page_table_mutex: kernel.sync.Mutex = .{};

    /// An arena managing the special heap region's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire range.
    ///
    /// Initialized during `init.initializeHeaps`.
    var special_heap_address_space_arena: kernel.ResourceArena = undefined;

    var special_heap_page_table_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    pub fn initializeHeaps(current_task: *kernel.Task) !void {
        // heap
        {
            try globals.heap_address_space_arena.create(
                "heap_address_space",
                kernel.arch.paging.standard_page_size.value,
                .{},
            );

            try globals.heap_arena.create(
                "heap",
                heap_arena_quantum,
                .{
                    .source = .{
                        .arena = &globals.heap_address_space_arena,
                        .import = heapArenaImport,
                        .release = heapArenaRelease,
                    },
                },
            );

            const heap_range = kernel.vmm.getKernelRegion(.kernel_heap) orelse
                @panic("no kernel heap");

            globals.heap_address_space_arena.addSpan(
                current_task,
                heap_range.address.value,
                heap_range.size.value,
            ) catch |err| {
                std.debug.panic(
                    "failed to add heap range to `heap_address_space_arena`: {s}",
                    .{@errorName(err)},
                );
            };
        }

        // special heap
        {
            try globals.special_heap_address_space_arena.create(
                "special_heap_address_space",
                kernel.arch.paging.standard_page_size.value,
                .{},
            );

            const special_heap_range = kernel.vmm.getKernelRegion(.special_heap) orelse
                @panic("no special heap region");

            globals.special_heap_address_space_arena.addSpan(
                current_task,
                special_heap_range.address.value,
                special_heap_range.size.value,
            ) catch |err| {
                std.debug.panic(
                    "failed to add special heap range to `special_heap_address_space_arena`: {s}",
                    .{@errorName(err)},
                );
            };
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.heap);
const ResourceArena = kernel.ResourceArena;
