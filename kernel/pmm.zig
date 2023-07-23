// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = kernel.arch;

const log = kernel.log.scoped(.pmm);

// TODO: better data structure https://github.com/CascadeOS/CascadeOS/issues/20

var first_free_physical_page: ?*PhysPageNode = null;
var total_memory: core.Size = core.Size.zero;
var total_usable_memory: core.Size = core.Size.zero;
var free_memory: core.Size = core.Size.zero;

const indent = "  ";

pub fn init() void {
    var memory_map_iterator = kernel.boot.memoryMapIterator(.forwards);

    while (memory_map_iterator.next()) |memory_map_entry| {
        log.debug(indent ++ "{}", .{memory_map_entry});

        total_memory.addInPlace(memory_map_entry.range.size);

        switch (memory_map_entry.type) {
            .free => processFreeMemoryMapEntry(memory_map_entry),
            .in_use, .reclaimable => total_usable_memory.addInPlace(memory_map_entry.range.size),
            .reserved_or_unusable => {},
        }
    }

    log.debug("pmm total memory: {}", .{total_memory});
    log.debug("|--usable: {}", .{total_usable_memory});
    log.debug("|  |--free: {}", .{free_memory});
    log.debug("|  |--in use: {}", .{total_usable_memory.subtract(free_memory)});
    log.debug("|--unusable: {}", .{total_memory.subtract(total_usable_memory)});
}

fn processFreeMemoryMapEntry(memory_map_entry: kernel.boot.MemoryMapEntry) void {
    total_usable_memory.addInPlace(memory_map_entry.range.size);
    free_memory.addInPlace(memory_map_entry.range.size);
    addMemoryMapEntryToAllocator(memory_map_entry);
}

/// Adds a memory map entry to the physical page allocator.
fn addMemoryMapEntryToAllocator(memory_map_entry: kernel.boot.MemoryMapEntry) void {
    std.debug.assert(memory_map_entry.range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(memory_map_entry.range.size.isAligned(arch.paging.standard_page_size));

    const virtual_range = memory_map_entry.range.toDirectMap();

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();

    log.debug(indent ** 2 ++ "marking {} pages available from {} to {}", .{
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

pub const PhysicalAllocation = struct {
    range: kernel.PhysicalRange,

    /// This is only set to true when the kernel itself has zeroed the memory.
    zeroed: bool = false,
};

/// Allocates a physical page.
pub fn allocatePage() ?PhysicalAllocation {
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

        const zeroed = first_free_page.zeroed;
        const physical_address = kernel.VirtualAddress.fromPtr(first_free_page).toPhysicalFromDirectMap() catch unreachable;

        const allocated_range = kernel.PhysicalRange.fromAddr(physical_address, arch.paging.standard_page_size);

        log.debug("found free page: {}{s}", .{ allocated_range, if (zeroed) " (zeroed)" else "" });

        return PhysicalAllocation{
            .range = allocated_range,
            .zeroed = zeroed,
        };
    } else {
        log.warn("STANDARD PAGE ALLOCATION FAILED", .{});
    }

    return null;
}

/// Deallocates a physical page.
pub fn deallocatePage(allocation: PhysicalAllocation) void {
    std.debug.assert(allocation.range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(allocation.range.size.equal(arch.paging.standard_page_size));

    const page_node = allocation.range.address.toDirectMap().toPtr(*PhysPageNode);
    _ = page_node;

    core.panic("UNIMPLEMENTED `deallocatePage`"); // TODO: implement deallocatePage https://github.com/CascadeOS/CascadeOS/issues/21
}

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    /// This is only set to true when the kernel itself has zeroed the memory.
    ///
    /// NOTE: Due to the current design of the PMM no pages will be zeroed, as the pages themselves are used to store
    /// the free page link list.
    /// This deficency would be removed with https://github.com/CascadeOS/CascadeOS/issues/20
    zeroed: bool = false,

    comptime {
        std.debug.assert(core.Size.of(PhysPageNode).lessThanOrEqual(kernel.arch.paging.standard_page_size));
    }
};
