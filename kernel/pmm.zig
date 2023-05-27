// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.pmm);

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

                std.debug.assert(entry.range.addr.isAligned(kernel.arch.smallest_page_size));
                std.debug.assert(entry.range.size.isAligned(kernel.arch.smallest_page_size));

                const range_in_hhdm = entry.range.toKernelVirtual();

                var current_virtual_addr = range_in_hhdm.addr;
                const virtual_end_addr = range_in_hhdm.end();

                log.debug(indent ** 2 ++ "marking {} pages available from {} to {}", .{
                    entry.range.size.divide(kernel.arch.smallest_page_size),
                    current_virtual_addr,
                    virtual_end_addr,
                });

                var opt_first_page: ?*PhysPageNode = null;
                var opt_previous_page: ?*PhysPageNode = null;

                while (current_virtual_addr.lessThan(virtual_end_addr)) : ({
                    current_virtual_addr.moveForwardInPlace(kernel.arch.smallest_page_size);
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

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    comptime {
        std.debug.assert(@sizeOf(PhysPageNode) == @sizeOf(usize));
        std.debug.assert(@bitSizeOf(PhysPageNode) == @bitSizeOf(usize));
    }
};
