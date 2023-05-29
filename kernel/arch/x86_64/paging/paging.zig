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

pub const smallest_page_size = small_page_size;
pub const largest_page_size = large_page_size;

// TODO: This is incorrect for 5-level paging
pub const higher_half = kernel.VirtAddr.fromInt(0xffff800000000000);

pub const PageTable = @import("PageTable.zig").PageTable;

pub fn allocatePageTable() error{PageAllocationFailed}!*PageTable {
    const physical_page = kernel.pmm.allocateSmallestPage() orelse return error.PageAllocationFailed;
    std.debug.assert(physical_page.size.greaterThanOrEqual(core.Size.of(PageTable)));

    const page_table = physical_page.toKernelVirtual().addr.toPtr(*PageTable);
    page_table.zero();

    return page_table;
}

const MapError = arch.paging.MapError;

pub fn mapRegion(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: kernel.vmm.MapType,
) MapError!void {
    var current_virtual = virtual_range.addr;
    const virtual_end = virtual_range.end();
    var current_physical = physical_range.addr;
    var size_left = virtual_range.size;

    while (current_virtual.lessThan(virtual_end)) {
        if (x86_64.info.gib_pages and
            size_left.greaterThanOrEqual(large_page_size) and
            current_virtual.isAligned(large_page_size) and
            current_physical.isAligned(large_page_size))
        {
            mapTo1GiB(
                page_table,
                current_virtual,
                current_physical,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 1GiB", .{ current_virtual, current_physical });
                return err;
            };

            current_virtual.moveForwardInPlace(large_page_size);
            current_physical.moveForwardInPlace(large_page_size);
            size_left.subtractInPlace(large_page_size);
            continue;
        }

        if (size_left.greaterThanOrEqual(medium_page_size) and
            current_virtual.isAligned(medium_page_size) and
            current_physical.isAligned(medium_page_size))
        {
            mapTo2MiB(
                page_table,
                current_virtual,
                current_physical,
                map_type,
            ) catch |err| {
                log.err("failed to map {} to {} 2MiB", .{ current_virtual, current_physical });
                return err;
            };

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

        current_virtual.moveForwardInPlace(small_page_size);
        current_physical.moveForwardInPlace(small_page_size);
        size_left.subtractInPlace(small_page_size);
    }
}

pub fn mapTo4KiB(
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

pub fn mapTo2MiB(
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

pub fn mapTo1GiB(
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

    if (!self.present.read()) {
        const physical_page = kernel.pmm.allocateSmallestPage() orelse return error.AllocationFailed;
        self.setAddress4kib(physical_page.addr);
        created = true;
    }

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
