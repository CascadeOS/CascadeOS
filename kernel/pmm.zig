// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = kernel.arch;

const log = kernel.log.scoped(.pmm);

// TODO: better data structure https://github.com/CascadeOS/CascadeOS/issues/20

var first_free_physical_page: ?*PhysPageNode = null;
var total_usable_memory: core.Size = core.Size.zero;
var free_memory: core.Size = core.Size.zero;

const indent = "  ";

var initalized: bool = false;

pub fn init() void {
    var memory_map_iterator = kernel.boot.memoryMapIterator(.forwards);

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

    initalized = true;
}

/// Adds a memory map entry to the physical page allocator.
fn addMemoryMapEntryToAllocator(memory_map_entry: kernel.boot.MemoryMapEntry) void {
    if (!memory_map_entry.range.address.isAligned(arch.paging.standard_page_size)) {
        core.panicFmt("memory map entry address is not aligned to page size: {}", .{memory_map_entry});
    }
    if (!memory_map_entry.range.size.isAligned(arch.paging.standard_page_size)) {
        core.panicFmt("memory map entry size is not aligned to page size: {}", .{memory_map_entry});
    }

    const virtual_range = memory_map_entry.range.toDirectMap();

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();

    log.debug(comptime indent ** 2 ++ "marking {} pages available from {} to {}", .{
        memory_map_entry.range.size.divide(arch.paging.standard_page_size),
        current_virtual_address,
        end_virtual_address,
    });

    var first_page_opt: ?*PhysPageNode = null;
    var previous_page_opt: ?*PhysPageNode = null;

    while (current_virtual_address.lessThan(end_virtual_address)) : ({
        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
    }) {
        const page = current_virtual_address.toPtr(*kernel.pmm.PhysPageNode);
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

/// Allocates a physical page.
pub fn allocatePage() ?kernel.PhysicalRange {
    core.debugAssert(initalized);

    var first_free_page_opt = @atomicLoad(?*PhysPageNode, &first_free_physical_page, .Monotonic);

    while (first_free_page_opt) |first_free_page| {
        if (@cmpxchgWeak(
            ?*PhysPageNode,
            &first_free_physical_page,
            first_free_page,
            first_free_page.next,
            .AcqRel,
            .Monotonic,
        )) |new_first_free_page| {
            first_free_page_opt = new_first_free_page;
            continue;
        }

        // Decrement `free_memory`
        _ = @atomicRmw(
            usize,
            &free_memory.bytes,
            .Sub,
            arch.paging.standard_page_size.bytes,
            .Monotonic,
        );

        const physical_address = kernel.VirtualAddress.fromPtr(first_free_page).toPhysicalFromDirectMap() catch unreachable;
        const allocated_range = kernel.PhysicalRange.fromAddr(physical_address, arch.paging.standard_page_size);

        log.debug("found free page: {}", .{allocated_range});

        return allocated_range;
    } else {
        log.warn("STANDARD PAGE ALLOCATION FAILED", .{});
    }

    return null;
}

/// Deallocates a physical page.
pub fn deallocatePage(range: kernel.PhysicalRange) void {
    core.debugAssert(initalized);
    core.debugAssert(range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(range.size.equal(arch.paging.standard_page_size));

    const page_node = range.address.toDirectMap().toPtr(*PhysPageNode);
    _ = page_node;

    core.panic("UNIMPLEMENTED `deallocatePage`"); // TODO: implement deallocatePage https://github.com/CascadeOS/CascadeOS/issues/21
}

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    comptime {
        core.assert(core.Size.of(PhysPageNode).lessThanOrEqual(kernel.arch.paging.standard_page_size));
    }
};
