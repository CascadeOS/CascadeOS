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
                    .instant_fit,
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

                const quantum_aligned_len = std.mem.alignForward(
                    usize,
                    buf.len,
                    heap_arena_quantum,
                );

                if (new_len < quantum_aligned_len) return true;

                return false;
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
    policy: ResourceArena.Policy,
) ResourceArena.AllocateError!ResourceArena.Allocation {
    const allocation = try arena.allocate(current_task, len, policy);

    log.debug("mapping {} into heap", .{allocation});

    kernel.vmm.mapRange(
        kernel.vmm.globals.core_page_table,
        .{
            .address = .fromInt(allocation.base),
            .size = .from(allocation.len, .byte),
        },
        .{ .writeable = true, .global = true },
        .kernel,
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
    );

    arena.deallocate(current_task, allocation);
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
};

pub const init = struct {
    pub fn initializeHeap() !void {
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
            core.panic("no kernel heap", null);

        globals.heap_address_space_arena.addSpan(
            kernel.Task.getCurrent(),
            heap_range.address.value,
            heap_range.size.value,
        ) catch |err| {
            core.panicFmt(
                "failed to add heap range to `heap_address_space_arena`: {s}",
                .{@errorName(err)},
                @errorReturnTrace(),
            );
        };
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.heap);
const ResourceArena = kernel.ResourceArena;
