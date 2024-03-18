// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! Physical memory management.

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.pmm);

var first_free_physical_page: ?*PhysPageNode = null;

/// Allocates a physical page.
pub fn allocatePage() error{PhysicalMemoryExhausted}!core.PhysicalRange {
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

        const physical_address = kernel.physicalFromDirectMap(
            core.VirtualAddress.fromPtr(first_free_page),
        ) catch unreachable;

        const allocated_range = core.PhysicalRange.fromAddr(
            physical_address,
            kernel.arch.paging.standard_page_size,
        );

        log.debug("allocated page: {}", .{allocated_range});

        return allocated_range;
    }

    log.warn("PAGE ALLOCATION FAILED", .{});
    return error.PhysicalMemoryExhausted;
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

    var first_free_page_opt = @atomicLoad(?*PhysPageNode, &first_free_physical_page, .acquire);

    while (true) {
        page_node.next = first_free_page_opt;

        if (@cmpxchgWeak(
            ?*PhysPageNode,
            &first_free_physical_page,
            first_free_page_opt,
            page_node,
            .acq_rel,
            .acquire,
        )) |new_first_free_page| {
            first_free_page_opt = new_first_free_page;
            continue;
        }

        log.debug("deallocated page: {}", .{range});

        return;
    }
}

const PhysPageNode = extern struct {
    next: ?*PhysPageNode = null,

    comptime {
        core.assert(core.Size.of(PhysPageNode).lessThanOrEqual(kernel.arch.paging.standard_page_size));
    }
};

pub const init = struct {
    pub fn addRange(physical_range: core.PhysicalRange) !void {
        if (!physical_range.address.isAligned(kernel.arch.paging.standard_page_size)) {
            log.err("range address {} is not aligned to page size", .{physical_range.address});
            return error.InvalidRange;
        }
        if (!physical_range.size.isAligned(kernel.arch.paging.standard_page_size)) {
            log.err("range size {} is not aligned to page size", .{physical_range.size});
            return error.InvalidRange;
        }

        const virtual_range = kernel.directMapFromPhysicalRange(physical_range);

        var current_virtual_address = virtual_range.address;
        const end_virtual_address = virtual_range.end();

        log.debug(comptime indent ** 2 ++ "marking {} pages available from {} to {}", .{
            physical_range.size.divide(kernel.arch.paging.standard_page_size).value,
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

        const first_page = first_page_opt orelse return error.InvalidPages;
        const previous_page = previous_page_opt orelse return error.InvalidPages;

        previous_page.next = first_free_physical_page;
        first_free_physical_page = first_page;
    }
};

const indent = "  ";
