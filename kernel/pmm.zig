// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Physical memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const builtin = @import("builtin");

const PageNode = containers.SingleNode;

const log = kernel.log.scoped(.pmm);

var lock: kernel.sync.TicketSpinLock = .{};
var free_pages: containers.SinglyLinkedLIFO = .{};

comptime {
    core.assert(core.Size.of(PageNode).lessThanOrEqual(kernel.arch.paging.standard_page_size));
}

pub const AllocateError = error{OutOfPhysicalMemory};

/// Allocates a physical page.
pub fn allocatePage() AllocateError!core.PhysicalRange {
    const free_page_node: *PageNode = blk: {
        const held = lock.acquire();

        const free_page_node = free_pages.pop() orelse {
            held.release();

            log.warn("PAGE ALLOCATION FAILED", .{});
            return error.OutOfPhysicalMemory;
        };

        held.release();

        break :blk free_page_node;
    };

    const virtual_range = core.VirtualRange.fromAddr(
        core.VirtualAddress.fromPtr(free_page_node),
        kernel.arch.paging.standard_page_size,
    );

    if (core.is_debug) {
        const slice = virtual_range.toSlice(usize) catch unreachable;
        @memset(slice, undefined);
    }

    const physical_range = kernel.vmm.physicalRangeFromDirectMap(virtual_range) catch unreachable;

    log.debug("allocated: {}", .{physical_range});

    return physical_range;
}

/// Deallocates a physical page.
///
/// **REQUIREMENTS**:
/// - `range.address` must be aligned to `kernel.arch.paging.standard_page_size`
/// - `range.size` must be *equal* to `kernel.arch.paging.standard_page_size`
pub fn deallocatePage(range: core.PhysicalRange) void {
    core.debugAssert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(range.size.equal(kernel.arch.paging.standard_page_size));

    const page_node = kernel.vmm.directMapFromPhysical(range.address).toPtr(*PageNode);
    page_node.* = .{};

    {
        const held = lock.acquire();
        defer held.release();

        free_pages.push(page_node);
    }

    log.debug("deallocated: {}", .{range});
}

pub const init = struct {
    pub fn initPmm() !void {
        log.debug("adding free memory to pmm", .{});
        try addFreeMemoryToPmm();
    }

    fn addFreeMemoryToPmm() !void {
        var size = core.Size.zero;

        var memory_map_iterator = kernel.boot.memoryMap(.forward);

        while (memory_map_iterator.next()) |memory_map_entry| {
            if (memory_map_entry.type != .free) continue;

            kernel.pmm.init.addRange(memory_map_entry.range) catch |err| {
                log.err("failed to add {} to pmm", .{memory_map_entry});
                return err;
            };

            size.addInPlace(memory_map_entry.range.size);
        }

        log.debug("added {} of memory to pmm", .{size});
    }

    fn addRange(physical_range: core.PhysicalRange) !void {
        if (!physical_range.address.isAligned(kernel.arch.paging.standard_page_size)) {
            log.err("range address {} is not aligned to page size", .{physical_range.address});
            return error.InvalidRange;
        }
        if (!physical_range.size.isAligned(kernel.arch.paging.standard_page_size)) {
            log.err("range size {} is not aligned to page size", .{physical_range.size});
            return error.InvalidRange;
        }

        const virtual_range = kernel.vmm.directMapFromPhysicalRange(physical_range);

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();

        log.debug("adding {} available pages from {} to {}", .{
            physical_range.size.divide(kernel.arch.paging.standard_page_size).value,
            current_virtual_address,
            last_virtual_address,
        });

        while (current_virtual_address.lessThanOrEqual(last_virtual_address)) : ({
            current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
        }) {
            const page_node = current_virtual_address.toPtr(*PageNode);
            page_node.* = .{};
            free_pages.push(page_node);
        }
    }
};
