// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");
const arch = @import("../../arch.zig");

const log = kernel.log.scoped(.paging_x86_64);

pub const small_page_size = core.Size.from(4, .kib);
pub const medium_page_size = core.Size.from(2, .mib);
pub const large_page_size = core.Size.from(1, .gib);

/// This is the total size of the virtual address space that one entry in the top level of the page table covers.
/// This is only valid for 4-level paging.
const size_of_top_level_entry = core.Size.from(0x8000000000, .byte);

pub const standard_page_size = small_page_size;

pub inline fn largestPageSize() core.Size {
    if (x86_64.info.gib_pages) return large_page_size;
    return medium_page_size;
}

pub const higher_half = kernel.VirtAddr.fromInt(0xffff800000000000);

pub const PageTable = @import("PageTable.zig").PageTable;

pub fn allocatePageTable() error{PageAllocationFailed}!*PageTable {
    const physical_page = kernel.pmm.allocatePage() orelse return error.PageAllocationFailed;
    std.debug.assert(physical_page.size.greaterThanOrEqual(core.Size.of(PageTable)));

    const page_table = physical_page.toDirectMap().addr.toPtr(*PageTable);
    page_table.zero();

    return page_table;
}

pub fn switchToPageTable(page_table: *const PageTable) void {
    x86_64.registers.Cr3.writeAddress(
        kernel.VirtAddr.fromPtr(page_table).unsafeToPhysicalFromDirectMap(),
    );
}

/// This function is only called once during system setup, it is required to:
///   1. search the high half of the *top level* of the given page table for a free entry
///   2. allocate a backing frame for it
///   3. map the free entry to the fresh backing frame and ensure it is zeroed
///   4. return the `VirtRange` representing the entire virtual range that entry covers
pub fn getHeapRangeAndFillFirstLevel(page_table: *PageTable) arch.paging.MapError!kernel.VirtRange {
    var index: usize = PageTable.p4Index(higher_half);
    while (index < PageTable.number_of_entries) : (index += 1) {
        const entry = &page_table.entries[index];
        if (entry._backing != 0) continue;

        log.debug("found free top level entry for heap at index {}", .{index});

        _ = try ensureNextTable(entry, .{ .global = true, .writeable = true });

        return kernel.VirtRange.fromAddr(
            PageTable.indexToAddr(
                @truncate(index),
                0,
                0,
                0,
            ),
            size_of_top_level_entry,
        );
    }

    core.panic("unable to find unused entry in top level of page table");
}

const MapError = arch.paging.MapError;

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
/// This function will only use the architecture's `standard_page_size`.
pub fn mapRange(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: kernel.vmm.MapType,
) MapError!void {
    log.debug("mapRange - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual = virtual_range.addr;
    const virtual_end = virtual_range.end();
    var current_physical = physical_range.addr;
    var size_left = virtual_range.size;

    var kib_mappings: usize = 0;

    while (current_virtual.lessThan(virtual_end)) {
        mapTo4KiB(
            page_table,
            current_virtual,
            current_physical,
            map_type,
        ) catch |err| {
            log.err("failed to map {} to {} 4KiB", .{ current_virtual, current_physical });
            return err;
        };

        kib_mappings += 1;

        current_virtual.moveForwardInPlace(small_page_size);
        current_physical.moveForwardInPlace(small_page_size);
        size_left.subtractInPlace(small_page_size);
    }

    log.debug("mapRange - satified using {} 4KiB pages", .{kib_mappings});
}

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
/// This function is allowed to use all page sizes available to the architecture.
pub fn mapRangeUseAllPageSizes(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: kernel.vmm.MapType,
) MapError!void {
    log.debug("mapRangeUseAllPageSizes - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual = virtual_range.addr;
    const virtual_end = virtual_range.end();
    var current_physical = physical_range.addr;
    var size_left = virtual_range.size;

    var gib_mappings: usize = 0;
    var mib_mappings: usize = 0;
    var kib_mappings: usize = 0;

    while (current_virtual.lessThan(virtual_end)) {
        const map_1gib = x86_64.info.gib_pages and
            size_left.greaterThanOrEqual(large_page_size) and
            current_virtual.isAligned(large_page_size) and
            current_physical.isAligned(large_page_size);

        if (map_1gib) {
            mapTo1GiB(
                page_table,
                current_virtual,
                current_physical,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 1GiB", .{ current_virtual, current_physical });
                return err;
            };

            gib_mappings += 1;

            current_virtual.moveForwardInPlace(large_page_size);
            current_physical.moveForwardInPlace(large_page_size);
            size_left.subtractInPlace(large_page_size);
            continue;
        }

        const map_2mib = size_left.greaterThanOrEqual(medium_page_size) and
            current_virtual.isAligned(medium_page_size) and
            current_physical.isAligned(medium_page_size);

        if (map_2mib) {
            mapTo2MiB(
                page_table,
                current_virtual,
                current_physical,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 2MiB", .{ current_virtual, current_physical });
                return err;
            };

            mib_mappings += 1;

            current_virtual.moveForwardInPlace(medium_page_size);
            current_physical.moveForwardInPlace(medium_page_size);
            size_left.subtractInPlace(medium_page_size);
            continue;
        }

        mapTo4KiB(
            page_table,
            current_virtual,
            current_physical,
            map_type,
        ) catch |err| {
            log.err("failed to map {} to {} 4KiB", .{ current_virtual, current_physical });
            return err;
        };

        kib_mappings += 1;

        current_virtual.moveForwardInPlace(small_page_size);
        current_physical.moveForwardInPlace(small_page_size);
        size_left.subtractInPlace(small_page_size);
    }

    log.debug(
        "mapRangeUseAllPageSizes - satified using {} 1GiB pages, {} 2MiB pages, {} 4KiB pages",
        .{ gib_mappings, mib_mappings, kib_mappings },
    );
}

fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_addr: kernel.VirtAddr,
    physical_addr: kernel.PhysAddr,
    map_type: kernel.vmm.MapType,
) MapError!void {
    std.debug.assert(virtual_addr.isAligned(small_page_size));

    const p3 = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_addr),
        map_type,
    );

    const p2 = try ensureNextTable(
        p3.getEntryLevel3(virtual_addr),
        map_type,
    );

    const p1 = try ensureNextTable(
        p2.getEntryLevel2(virtual_addr),
        map_type,
    );

    const entry = p1.getEntryLevel1(virtual_addr);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress4kib(physical_addr);

    applyMapType(map_type, entry);
}

fn mapTo2MiB(
    level4_table: *PageTable,
    virtual_addr: kernel.VirtAddr,
    physical_addr: kernel.PhysAddr,
    map_type: kernel.vmm.MapType,
) MapError!void {
    std.debug.assert(virtual_addr.isAligned(medium_page_size));
    std.debug.assert(physical_addr.isAligned(medium_page_size));

    const p3 = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_addr),
        map_type,
    );

    const p2 = try ensureNextTable(
        p3.getEntryLevel3(virtual_addr),
        map_type,
    );

    const entry = p2.getEntryLevel2(virtual_addr);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress2mib(physical_addr);

    entry.huge.write(true);
    applyMapType(map_type, entry);
}

fn mapTo1GiB(
    level4_table: *PageTable,
    virtual_addr: kernel.VirtAddr,
    physical_addr: kernel.PhysAddr,
    map_type: kernel.vmm.MapType,
) MapError!void {
    std.debug.assert(x86_64.info.gib_pages); // assert that 1GiB pages are available
    std.debug.assert(virtual_addr.isAligned(large_page_size));
    std.debug.assert(physical_addr.isAligned(large_page_size));

    const p3 = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_addr),
        map_type,
    );

    const entry = p3.getEntryLevel3(virtual_addr);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress1gib(physical_addr);

    entry.huge.write(true);
    applyMapType(map_type, entry);
}

fn applyMapType(map_type: kernel.vmm.MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);

    if (map_type.user) {
        entry.user_accessible.write(true);
    }

    if (map_type.global) {
        entry.global.write(true);
    }

    if (!map_type.executable and x86_64.info.execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: kernel.vmm.MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);
    entry.writeable.write(true);
    if (map_type.user) entry.user_accessible.write(true);
}

fn ensureNextTable(
    self: *PageTable.Entry,
    map_type: kernel.vmm.MapType,
) error{ AllocationFailed, Unexpected }!*PageTable {
    var created = false;

    var physical_page: ?kernel.PhysRange = null;

    if (!self.present.read()) {
        physical_page = kernel.pmm.allocatePage() orelse return error.AllocationFailed;
        self.setAddress4kib(physical_page.?.addr);
        created = true;
    }
    errdefer if (physical_page) |page| {
        self.setAddress4kib(kernel.PhysAddr.zero);
        kernel.pmm.deallocatePage(page);
    };

    applyParentMapType(map_type, self);

    const page_table = self.getNextLevel() catch |err| switch (err) {
        error.HugePage => return error.Unexpected,
        error.NotPresent => unreachable, // we ensure it is present above
    };

    if (created) {
        page_table.zero();
    }

    return page_table;
}
