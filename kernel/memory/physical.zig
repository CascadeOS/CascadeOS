// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! A simple intrusive linked list of physical pages.

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.physical);

var first_free_physical_page: ?*PhysPageNode = null;
var total_usable_memory: core.Size = core.Size.zero;
var free_memory: core.Size = core.Size.zero;

/// Allocates a physical page.
pub fn allocatePage() ?core.PhysicalRange {
    var first_free_page_opt = @atomicLoad(?*PhysPageNode, &first_free_physical_page, .acquire);

    while (first_free_page_opt) |first_free_page| {
        if (@cmpxchgWeak(
            ?*PhysPageNode,
            &first_free_physical_page,
            first_free_page,
            first_free_page.next,
            .acq_rel,
            .acquire,
        )) |new_first_free_page| {
            first_free_page_opt = new_first_free_page;
            continue;
        }

        // decrement `free_memory`
        _ = @atomicRmw(
            usize,
            &free_memory.value,
            .Sub,
            kernel.arch.paging.standard_page_size.value,
            .acq_rel,
        );

        const physical_address = kernel.physicalFromDirectMap(core.VirtualAddress.fromPtr(first_free_page)) catch unreachable;
        const allocated_range = core.PhysicalRange.fromAddr(physical_address, kernel.arch.paging.standard_page_size);

        log.debug("allocated page: {}", .{allocated_range});

        return allocated_range;
    }

    log.warn("STANDARD PAGE ALLOCATION FAILED", .{});
    return null;
}

/// Deallocates a physical range.
///
/// **REQUIREMENTS**:
/// - `range.address` must be aligned to `kernel.arch.paging.standard_page_size`
/// - `range.size` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn deallocateRange(range: core.PhysicalRange) void {
    core.debugAssert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(range.size.isAligned(kernel.arch.paging.standard_page_size));

    const first_page_node = kernel.directMapFromPhysical(range.address).toPtr(*PhysPageNode);

    if (range.size.equal(kernel.arch.paging.standard_page_size)) {
        deallocateImpl(first_page_node, first_page_node, kernel.arch.paging.standard_page_size);
        return;
    }

    // build up linked list
    const last_page_node = blk: {
        var current_virtual_address = kernel.directMapFromPhysical(range.address);
        const end_virtual_address: core.VirtualAddress = kernel.directMapFromPhysical(range.end());

        var previous: *PhysPageNode = first_page_node;

        while (current_virtual_address.lessThan(end_virtual_address)) {
            const page_node = current_virtual_address.toPtr(*PhysPageNode);

            previous.next = page_node;
            previous = page_node;

            current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
        }

        break :blk previous;
    };

    deallocateImpl(first_page_node, last_page_node, range.size);
}

/// Deallocates a physical page.
///
/// **REQUIREMENTS**:
/// - `range.address` must be aligned to `kernel.arch.paging.standard_page_size`
/// - `range.size` must be *equal* to `kernel.arch.paging.standard_page_size`
pub fn deallocatePage(range: core.PhysicalRange) void {
    core.debugAssert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(range.size.equal(kernel.arch.paging.standard_page_size));

    const page_node = kernel.directMapFromPhysical(range.address).toPtr(*PhysPageNode);

    deallocateImpl(page_node, page_node, kernel.arch.paging.standard_page_size);
}

fn deallocateImpl(first_page_node: *PhysPageNode, last_page_node: *PhysPageNode, size: core.Size) void {
    var first_free_page_opt = @atomicLoad(?*PhysPageNode, &first_free_physical_page, .acquire);

    while (true) {
        last_page_node.next = first_free_page_opt;

        if (@cmpxchgWeak(
            ?*PhysPageNode,
            &first_free_physical_page,
            first_free_page_opt,
            first_page_node,
            .acq_rel,
            .acquire,
        )) |new_first_free_page| {
            first_free_page_opt = new_first_free_page;
            continue;
        }

        break;
    }

    // increment `free_memory`
    _ = @atomicRmw(
        usize,
        &free_memory.value,
        .Add,
        size.value,
        .acq_rel,
    );
}

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    comptime {
        core.assert(core.Size.of(PhysPageNode).lessThanOrEqual(kernel.arch.paging.standard_page_size));
    }
};

pub const init = struct {
    const indent = "  ";

    pub fn initPhysicalMemory() void {
        var memory_map_iterator = kernel.boot.memoryMap(.forwards);

        while (memory_map_iterator.next()) |memory_map_entry| {
            log.debug(comptime indent ++ "{}", .{memory_map_entry});

            switch (memory_map_entry.type) {
                .free => {
                    total_usable_memory.addInPlace(memory_map_entry.range.size);
                    free_memory.addInPlace(memory_map_entry.range.size);
                    addMemoryMapEntryToAllocator(memory_map_entry);
                },
                .in_use, .reclaimable => total_usable_memory.addInPlace(memory_map_entry.range.size),
                .reserved_or_unusable => {},
            }
        }

        log.debug(
            "total usable memory: {} - free: {} - in use: {}",
            .{ total_usable_memory, free_memory, total_usable_memory.subtract(free_memory) },
        );
    }

    pub fn reclaimBootloaderReclaimableMemory() void {
        var memory_map_iterator = kernel.boot.memoryMap(.forwards);
        while (memory_map_iterator.next()) |memory_map_entry| {
            if (memory_map_entry.type != .reclaimable) continue;

            deallocateRange(memory_map_entry.range);
        }
    }

    /// Adds a memory map entry to the physical page allocator.
    fn addMemoryMapEntryToAllocator(memory_map_entry: kernel.boot.MemoryMapEntry) void {
        if (!memory_map_entry.range.address.isAligned(kernel.arch.paging.standard_page_size)) {
            core.panicFmt("memory map entry address is not aligned to page size: {}", .{memory_map_entry});
        }
        if (!memory_map_entry.range.size.isAligned(kernel.arch.paging.standard_page_size)) {
            core.panicFmt("memory map entry size is not aligned to page size: {}", .{memory_map_entry});
        }

        const virtual_range = kernel.directMapFromPhysicalRange(memory_map_entry.range);

        var current_virtual_address = virtual_range.address;
        const end_virtual_address = virtual_range.end();

        log.debug(comptime indent ** 2 ++ "marking {} pages available from {} to {}", .{
            memory_map_entry.range.size.divide(kernel.arch.paging.standard_page_size).value,
            current_virtual_address,
            end_virtual_address,
        });

        var first_page_opt: ?*PhysPageNode = null;
        var previous_page_opt: ?*PhysPageNode = null;

        while (current_virtual_address.lessThan(end_virtual_address)) : ({
            current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
        }) {
            const page = current_virtual_address.toPtr(*PhysPageNode);
            page.next = null;
            if (first_page_opt == null) {
                first_page_opt = page;
            }
            if (previous_page_opt) |previous_page| {
                previous_page.next = page;
            }
            previous_page_opt = page;
        }

        const first_page = first_page_opt orelse core.panic("no first free page?");
        const previous_page = previous_page_opt orelse core.panic("no previous page?");

        previous_page.next = first_free_physical_page;
        first_free_physical_page = first_page;
    }
};
