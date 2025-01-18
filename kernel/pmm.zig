// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

//! Physical memory management.

pub const AllocatePageError = error{OutOfPhysicalMemory};

/// Allocates a physical page.
pub fn allocatePage() AllocatePageError!core.PhysicalRange {
    const free_page_node = globals.free_pages.pop() orelse {
        log.warn("PHYSCIAL PAGE ALLOCATION FAILED", .{});
        return error.OutOfPhysicalMemory;
    };
    errdefer comptime unreachable;

    _ = globals.free_memory.fetchSub(kernel.arch.paging.standard_page_size.value, .release);

    const virtual_range = core.VirtualRange.fromAddr(
        core.VirtualAddress.fromPtr(free_page_node),
        kernel.arch.paging.standard_page_size,
    );

    if (core.is_debug) {
        @memset(virtual_range.toByteSlice(), undefined);
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
    std.debug.assert(range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(range.size.equal(kernel.arch.paging.standard_page_size));

    const page_node = kernel.vmm.directMapFromPhysical(range.address)
        .toPtr(*containers.SingleNode);
    page_node.* = .empty;
    globals.free_pages.push(page_node);

    _ = globals.free_memory.fetchAdd(kernel.arch.paging.standard_page_size.value, .release);

    log.debug("deallocated: {}", .{range});
}

const globals = struct {
    /// The list of free pages.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_pages: containers.AtomicSinglyLinkedLIFO = .empty;

    /// The free physical memory.
    ///
    /// Updates to this value are eventually consistent.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var free_memory: std.atomic.Value(u64) = undefined;

    /// The total physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var total_memory: core.Size = undefined;

    /// The reserved physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reserved_memory: core.Size = undefined;

    /// The reclaimable physical memory.
    ///
    /// Will be reduced when the memory is reclaimed. // TODO: reclaim memory
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var reclaimable_memory: core.Size = undefined;

    /// The unavailable physical memory.
    ///
    /// Does not change during the lifetime of the system.
    ///
    /// Initialized during `init.initializePhysicalMemory`.
    var unavailable_memory: core.Size = undefined;
};

pub const init = struct {
    pub fn initializePhysicalMemory() !void {
        var iter = kernel.boot.memoryMap(.forward) orelse return error.NoMemoryMap;

        var total_memory: core.Size = .zero;
        var free_memory: core.Size = .zero;
        var reserved_memory: core.Size = .zero;
        var reclaimable_memory: core.Size = .zero;
        var unavailable_memory: core.Size = .zero;

        init_log.debug("bootloader provided memory map:", .{});

        while (iter.next()) |entry| {
            init_log.debug("\t{}", .{entry});

            total_memory.addInPlace(entry.range.size);

            switch (entry.type) {
                .free => {
                    free_memory.addInPlace(entry.range.size);

                    std.debug.assert(entry.range.address.isAligned(kernel.arch.paging.standard_page_size));
                    std.debug.assert(entry.range.size.isAligned(kernel.arch.paging.standard_page_size));

                    const virtual_range = kernel.vmm.directMapFromPhysicalRange(entry.range);

                    var current_virtual_address = virtual_range.address;
                    const last_virtual_address = virtual_range.last();

                    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) : ({
                        current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
                    }) {
                        const node = current_virtual_address.toPtr(*containers.SingleNode);
                        node.* = .empty;
                        globals.free_pages.push(node);
                    }
                },
                .in_use => {},
                .reserved => reserved_memory.addInPlace(entry.range.size),
                .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
                .unusable, .unknown => unavailable_memory.addInPlace(entry.range.size),
            }
        }

        const used_memory = total_memory
            .subtract(free_memory)
            .subtract(reserved_memory)
            .subtract(reclaimable_memory)
            .subtract(unavailable_memory);

        init_log.debug("total memory:         {}", .{total_memory});
        init_log.debug("  free memory:        {}", .{free_memory});
        init_log.debug("  used memory:        {}", .{used_memory});
        init_log.debug("  reserved memory:    {}", .{reserved_memory});
        init_log.debug("  reclaimable memory: {}", .{reclaimable_memory});
        init_log.debug("  unavailable memory: {}", .{unavailable_memory});

        globals.total_memory = total_memory;
        globals.free_memory.store(free_memory.value, .release);
        globals.reserved_memory = reserved_memory;
        globals.reclaimable_memory = reclaimable_memory;
        globals.unavailable_memory = unavailable_memory;
    }

    const init_log = kernel.debug.log.scoped(.init_pmm);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const containers = @import("containers");
const log = kernel.debug.log.scoped(.pmm);
