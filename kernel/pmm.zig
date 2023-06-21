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

pub fn init() void {
    const indent = "  ";

    var memory_map_iterator = kernel.boot.memoryMapIterator(.forwards);

    while (memory_map_iterator.next()) |entry| {
        log.debug(indent ++ "{}", .{entry});

        total_memory.addInPlace(entry.range.size);

        switch (entry.type) {
            .free => {
                total_usable_memory.addInPlace(entry.range.size);
                free_memory.addInPlace(entry.range.size);

                std.debug.assert(entry.range.addr.isAligned(arch.paging.standard_page_size));
                std.debug.assert(entry.range.size.isAligned(arch.paging.standard_page_size));

                const range_in_direct_map = entry.range.toDirectMap();

                var current_virtual_addr = range_in_direct_map.addr;
                const virtual_end_addr = range_in_direct_map.end();

                log.debug(indent ** 2 ++ "marking {} pages available from {} to {}", .{
                    entry.range.size.divide(arch.paging.standard_page_size),
                    current_virtual_addr,
                    virtual_end_addr,
                });

                var opt_first_page: ?*PhysPageNode = null;
                var opt_previous_page: ?*PhysPageNode = null;

                while (current_virtual_addr.lessThan(virtual_end_addr)) : ({
                    current_virtual_addr.moveForwardInPlace(arch.paging.standard_page_size);
                }) {
                    const page = current_virtual_addr.toPtr(*kernel.pmm.PhysPageNode);
                    page.next = null;
                    if (opt_first_page == null) {
                        opt_first_page = page;
                    }
                    if (opt_previous_page) |previous_page| {
                        previous_page.next = page;
                    }
                    opt_previous_page = page;
                }

                const first_page = opt_first_page orelse core.panic("no first free page?");
                const previous_page = opt_previous_page orelse core.panic("no previous page?");

                previous_page.next = first_free_physical_page;
                first_free_physical_page = first_page;
            },
            .in_use, .reclaimable => {
                total_usable_memory.addInPlace(entry.range.size);
            },
            .reserved_or_unusable => {},
        }
    }

    log.debug("pmm total memory: {}", .{total_memory});
    log.debug("|--usable: {}", .{total_usable_memory});
    log.debug("|  |--free: {}", .{free_memory});
    log.debug("|  |--in use: {}", .{total_usable_memory.subtract(free_memory)});
    log.debug("|--unusable: {}", .{total_memory.subtract(total_usable_memory)});
}

pub fn allocatePage() ?kernel.PhysRange {
    var opt_first_free = @atomicLoad(?*PhysPageNode, &first_free_physical_page, .Monotonic);

    while (opt_first_free) |first_free| {
        if (@cmpxchgWeak(
            ?*PhysPageNode,
            &first_free_physical_page,
            first_free,
            first_free.next,
            .AcqRel,
            .Monotonic,
        )) |new_first_free| {
            opt_first_free = new_first_free;
            continue;
        }

        // Decrement `free_memory`
        _ = @atomicRmw(usize, &free_memory.bytes, .Sub, arch.paging.standard_page_size.bytes, .Monotonic);

        const addr = kernel.VirtAddr.fromPtr(first_free).toPhysicalFromDirectMap() catch unreachable;

        const range = kernel.PhysRange.fromAddr(addr, arch.paging.standard_page_size);

        log.debug("found free page: {}", .{range});

        return range;
    } else {
        log.warn("STANDARD PAGE ALLOCATION FAILED", .{});
    }

    return null;
}

pub fn deallocatePage(range: kernel.PhysRange) void {
    std.debug.assert(range.addr.isAligned(arch.paging.standard_page_size));
    std.debug.assert(range.size.equal(arch.paging.standard_page_size));

    const page_node = range.addr.toDirectMap().toPtr(*PhysPageNode);
    _ = page_node;
    core.panic("UNIMPLEMENTED `deallocatePage`"); // TODO: implement deallocatePage https://github.com/CascadeOS/CascadeOS/issues/21
}

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    comptime {
        core.testing.expectSize(@This(), @sizeOf(usize));
    }
};
