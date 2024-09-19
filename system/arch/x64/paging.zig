// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const ArchPageTable = PageTable;

pub const all_page_sizes = &.{
    PageTable.small_page_size,
    PageTable.medium_page_size,
    PageTable.large_page_size,
};

pub const page_table_alignment = PageTable.small_page_size;
pub const page_table_size = PageTable.small_page_size;

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

/// Create a new page table at the given physical range.
///
/// The range must have alignment of `page_table_alignment` and size greater than or equal to
/// `page_table_size`.
pub fn createPageTable(physical_range: core.PhysicalRange) *PageTable {
    std.debug.assert(physical_range.address.isAligned(page_table_alignment));
    std.debug.assert(physical_range.size.greaterThanOrEqual(page_table_size));

    const page_table = kernel.memory_layout.directMapFromPhysical(physical_range.address).toPtr(*PageTable);
    page_table.zero();
    return page_table;
}

/// Ensures the next page table level exists.
fn ensureNextTable(
    raw_entry: *ArchPageTable.RawEntry,
    map_type: MapType,
    comptime allocatePage: fn () error{OutOfPhysicalMemory}!core.PhysicalRange,
) !struct { *ArchPageTable, bool } {
    var opt_backing_range: ?core.PhysicalRange = null;

    var entry = raw_entry.load();

    const next_level_phys_address = if (entry.present.read()) blk: {
        if (entry.huge.read()) return error.MappingNotValid;

        break :blk entry.getAddress4kib();
    } else blk: {
        const backing_range = try allocatePage();

        opt_backing_range = backing_range;

        break :blk backing_range.address;
    };
    errdefer comptime unreachable;

    const next_level = kernel.memory_layout.directMapFromPhysical(next_level_phys_address).toPtr(*ArchPageTable);

    if (opt_backing_range) |backing_range| {
        next_level.zero();

        entry.zero();
        applyParentMapType(map_type, &entry);
        entry.setAddress4kib(backing_range.address);
        entry.present.write(true);

        raw_entry.store(entry);
    }

    return .{ next_level, opt_backing_range != null };
}

fn applyMapType(map_type: MapType, entry: *ArchPageTable.Entry) void {
fn applyMapType(map_type: MapType, entry: *PageTable.Entry) void {
    if (map_type.user) entry.user_accessible.write(true);

    if (map_type.global) entry.global.write(true);

    if (!map_type.executable and x64.info.cpu_id.execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: MapType, entry: *PageTable.Entry) void {
    entry.writeable.write(true);
    if (map_type.user) entry.user_accessible.write(true);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const arch = @import("arch");
const MapType = kernel.vmm.MapType;
const log = kernel.log.scoped(.paging_x64);
const PageTable = lib_x64.PageTable;
