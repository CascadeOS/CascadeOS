// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

//! Provides a kernel heap.
//!
//! Each allocation is a multiple of the standard page size.

pub fn allocate(len: usize, current_task: *kernel.Task) !core.VirtualRange {
    const allocation = try globals.heap_arena.allocate(
        current_task,
        len,
        .{},
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

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn alloc(
                _: *anyopaque,
                len: usize,
                _: u8,
                _: usize,
            ) ?[*]u8 {
                const allocation = globals.heap_arena.allocate(
                    kernel.Task.getCurrent(),
                    len,
                    .{},
                ) catch return null;
                return @ptrFromInt(allocation.base);
            }
        }.alloc,
        .resize = struct {
            fn resize(
                _: *anyopaque,
                buf: []u8,
                _: u8,
                new_len: usize,
                _: usize,
            ) bool {
                std.debug.assert(new_len != 0);

                // the current `ResourceArena` implementation does support arbitrary shrinking of allocations, but
                // once we add quantum caches it no longer would be possible to peform resizes that change the
                // quantum aligned length of the allocation

                const old_quantum_aligned_len = std.mem.alignForward(
                    usize,
                    buf.len,
                    heap_arena_quantum,
                );
                const new_quantum_aligned_len = std.mem.alignForward(
                    usize,
                    new_len,
                    heap_arena_quantum,
                );

                return new_quantum_aligned_len == old_quantum_aligned_len;
            }
        }.resize,
        .free = struct {
            fn free(
                _: *anyopaque,
                buf: []u8,
                _: u8,
                _: usize,
            ) void {
                // we have to use `deallocateBase` here because the true length of the allocation in `alloc` is not
                // returned to the caller due to the Allocator API
                globals.heap_arena.deallocateBase(kernel.Task.getCurrent(), @intFromPtr(buf.ptr));
            }
        }.free,
    },
};

fn heapArenaImport(
    arena: *ResourceArena,
    current_task: *kernel.Task,
    len: usize,
    options: ResourceArena.AllocateOptions,
) ResourceArena.AllocateError!ResourceArena.Allocation {
    const allocation = try arena.allocate(current_task, len, options);

    log.debug("mapping {} into heap", .{allocation});

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

    return allocation;
}

fn heapArenaRelease(
    arena: *ResourceArena,
    current_task: *kernel.Task,
    allocation: ResourceArena.Allocation,
) void {
    log.debug("unmapping {} from heap", .{allocation});

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

    arena.deallocate(current_task, allocation);
}

pub fn allocateSpecialUse(
    current_task: *kernel.Task,
    size: core.Size,
    physical_range: core.PhysicalRange,
    map_type: kernel.vmm.MapType,
) !core.VirtualRange {
    const allocation = try globals.special_use_arena.allocate(
        current_task,
        size.value,
        .{},
    );
    errdefer globals.special_use_arena.deallocate(current_task, allocation);

    const virtual_range: core.VirtualRange = .{
        .address = .fromInt(allocation.base),
        .size = .from(allocation.len, .byte),
    };

    globals.special_use_mutex.lock(current_task);
    defer globals.special_use_mutex.unlock(current_task);

    try kernel.vmm.mapToPhysicalRange(
        kernel.vmm.globals.core_page_table,
        virtual_range,
        physical_range,
        map_type,
        true,
    );

    return virtual_range;
}

pub fn deallocateSpecialUse(
    current_task: *kernel.Task,
    virtual_range: core.VirtualRange,
) void {
    {
        globals.special_use_mutex.lock(current_task);
        defer globals.special_use_mutex.unlock(current_task);

        kernel.vmm.unmapRange(
            kernel.vmm.globals.core_page_table,
            virtual_range,
            true,
            .kernel,
            true,
        );
    }

    globals.special_use_arena.deallocate(
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
    /// Initialized during `init.initializeResourceArenasAndHeap`.
    var heap_address_space_arena: ResourceArena = undefined;

    /// The heap arena.
    ///
    /// Has a source arena of `heap_address_space_arena`. Backs imported spans with physical memory.
    ///
    /// Initialized during `init.initializeResourceArenasAndHeap`.
    var heap_arena: ResourceArena = undefined;

    /// An arena managing the special use region's virtual address space.
    ///
    /// Has no source arena, provided with a single span representing the entire range.
    ///
    /// Initialized during `init.initializeSpecialUseRegion`.
    var special_use_arena: kernel.ResourceArena = undefined;

    /// Used to protect the special use region while the page mapping is being modified.
    var special_use_mutex: kernel.sync.Mutex = .{};
};

pub const init = struct {
    pub fn initializeHeapAndSpecialUse(current_task: *kernel.Task) !void {
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

        // special use region
        {
            try globals.special_use_arena.create(
                "special_use_arena",
                kernel.arch.paging.standard_page_size.value,
                .{},
            );

            const special_use_range = kernel.vmm.getKernelRegion(.special_use) orelse
                @panic("no special use region");

            globals.special_use_arena.addSpan(
                current_task,
                special_use_range.address.value,
                special_use_range.size.value,
            ) catch |err| {
                std.debug.panic(
                    "failed to add special use range to `special_use_arena`: {s}",
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
