// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x86_64 = @import("x86_64.zig");

const log = kernel.log.scoped(.paging_x86_64);

const PageTable = x86_64.PageTable;
const MapType = kernel.vmm.MapType;
const MapError = kernel.arch.paging.MapError;

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
///
/// Caller must ensure:
///  - the virtual range address and size are aligned to the standard page size
///  - the physical range address and size are aligned to the standard page size
///  - the virtual range size is equal to the physical range size
///
/// This function is allowed to use all page sizes available to the architecture.
pub fn mapToPhysicalRangeAllPageSizes(
    page_table: *PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
) MapError!void {
    core.debugAssert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(physical_range.address.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(physical_range.size.isAligned(kernel.arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.equal(virtual_range.size));

    log.debug("mapToPhysicalRangeAllPageSizes - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();
    var current_physical_address = physical_range.address;
    var size_remaining = virtual_range.size;

    var gib_page_mappings: usize = 0;
    var mib_page_mappings: usize = 0;
    var kib_page_mappings: usize = 0;

    while (current_virtual_address.lessThan(end_virtual_address)) {
        const map_1gib = x86_64.info.cpu_id.gbyte_pages and
            size_remaining.greaterThanOrEqual(PageTable.large_page_size) and
            current_virtual_address.isAligned(PageTable.large_page_size) and
            current_physical_address.isAligned(PageTable.large_page_size);

        if (map_1gib) {
            mapTo1GiB(
                page_table,
                current_virtual_address,
                current_physical_address,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 1GiB", .{ current_virtual_address, current_physical_address });
                return err;
            };

            gib_page_mappings += 1;

            current_virtual_address.moveForwardInPlace(PageTable.large_page_size);
            current_physical_address.moveForwardInPlace(PageTable.large_page_size);
            size_remaining.subtractInPlace(PageTable.large_page_size);
            continue;
        }

        const map_2mib = size_remaining.greaterThanOrEqual(PageTable.medium_page_size) and
            current_virtual_address.isAligned(PageTable.medium_page_size) and
            current_physical_address.isAligned(PageTable.medium_page_size);

        if (map_2mib) {
            mapTo2MiB(
                page_table,
                current_virtual_address,
                current_physical_address,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 2MiB", .{ current_virtual_address, current_physical_address });
                return err;
            };

            mib_page_mappings += 1;

            current_virtual_address.moveForwardInPlace(PageTable.medium_page_size);
            current_physical_address.moveForwardInPlace(PageTable.medium_page_size);
            size_remaining.subtractInPlace(PageTable.medium_page_size);
            continue;
        }

        mapTo4KiB(
            page_table,
            current_virtual_address,
            current_physical_address,
            map_type,
        ) catch |err| {
            log.err("failed to map {} to {} 4KiB", .{ current_virtual_address, current_physical_address });
            return err;
        };

        kib_page_mappings += 1;

        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
        current_physical_address.moveForwardInPlace(PageTable.small_page_size);
        size_remaining.subtractInPlace(PageTable.small_page_size);
    }

    log.debug(
        "mapToPhysicalRangeAllPageSizes - satified using {} 1GiB pages, {} 2MiB pages, {} 4KiB pages",
        .{ gib_page_mappings, mib_page_mappings, kib_page_mappings },
    );
}

/// Maps a 1 GiB page.
fn mapTo1GiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) MapError!void {
    core.debugAssert(x86_64.info.cpu_id.gbyte_pages);
    core.debugAssert(virtual_address.isAligned(PageTable.large_page_size));
    core.debugAssert(physical_address.isAligned(PageTable.large_page_size));

    const level3_table = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_address),
        map_type,
    );

    const entry = level3_table.getEntryLevel3(virtual_address);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress1gib(physical_address);

    entry.huge.write(true);
    applyMapType(map_type, entry);
}

/// Maps a 2 MiB page.
fn mapTo2MiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(PageTable.medium_page_size));
    core.debugAssert(physical_address.isAligned(PageTable.medium_page_size));

    const level3_table = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_address),
        map_type,
    );

    const level2_table = try ensureNextTable(
        level3_table.getEntryLevel3(virtual_address),
        map_type,
    );

    const entry = level2_table.getEntryLevel2(virtual_address);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress2mib(physical_address);

    entry.huge.write(true);
    applyMapType(map_type, entry);
}

/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(PageTable.small_page_size));

    const level3_table = try ensureNextTable(
        level4_table.getEntryLevel4(virtual_address),
        map_type,
    );

    const level2_table = try ensureNextTable(
        level3_table.getEntryLevel3(virtual_address),
        map_type,
    );

    const level1_table = try ensureNextTable(
        level2_table.getEntryLevel2(virtual_address),
        map_type,
    );

    const entry = level1_table.getEntryLevel1(virtual_address);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress4kib(physical_address);

    applyMapType(map_type, entry);
}

/// Ensures the next page table level exists.
fn ensureNextTable(
    self: *PageTable.Entry,
    map_type: MapType,
) error{ OutOfMemory, Unexpected }!*PageTable {
    var opt_range: ?core.PhysicalRange = null;

    if (!self.present.read()) {
        opt_range = try kernel.pmm.allocatePage();
        self.setAddress4kib(opt_range.?.address);
    }
    errdefer if (opt_range) |range| {
        self.setAddress4kib(core.PhysicalAddress.zero);
        kernel.pmm.deallocatePage(range);
    };

    applyParentMapType(map_type, self);

    const next_level = self.getNextLevel(kernel.directMapFromPhysical) catch |err| switch (err) {
        error.HugePage => return error.Unexpected,
        error.NotPresent => unreachable, // we ensure it is present above
    };

    if (opt_range != null) next_level.zero();

    return next_level;
}

fn applyMapType(map_type: MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);

    if (map_type.user) {
        entry.user_accessible.write(true);
    }

    if (map_type.global) {
        entry.global.write(true);
    }

    if (!map_type.executable and x86_64.info.cpu_id.execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);
    entry.writeable.write(true);
    if (map_type.user) entry.user_accessible.write(true);
}
