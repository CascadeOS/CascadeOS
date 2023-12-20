// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const arch_info = x86_64.arch_info;
const core = @import("core");
const info = kernel.info;
const kernel = @import("kernel");
const memory = kernel.memory;
const PhysicalAddress = kernel.PhysicalAddress;
const PhysicalRange = kernel.PhysicalRange;
const registers = x86_64.registers;
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;
const VirtualRange = kernel.VirtualRange;
const x86_64 = @import("../x86_64.zig");

const log = kernel.debug.log.scoped(.paging_x86_64);

pub const small_page_size = core.Size.from(4, .kib);
pub const medium_page_size = core.Size.from(2, .mib);
pub const large_page_size = core.Size.from(1, .gib);

/// This is the total size of the virtual address space that one entry in the top level of the page table covers.
///
/// This is only valid for 4-level paging.
const size_of_top_level_entry = core.Size.from(0x8000000000, .byte);

pub const standard_page_size = small_page_size;

pub inline fn largestPageSize() core.Size {
    if (arch_info.has_gib_pages) return large_page_size;
    return medium_page_size;
}

pub const higher_half = VirtualAddress.fromInt(0xffff800000000000);

pub const PageTable = @import("PageTable.zig").PageTable;

/// Allocates a new page table.
pub fn allocatePageTable() error{PageAllocationFailed}!*PageTable {
    const range = memory.physical.allocatePage() orelse return error.PageAllocationFailed;
    core.assert(range.size.greaterThanOrEqual(core.Size.of(PageTable)));

    const page_table = range.toDirectMap().address.toPtr(*PageTable);
    page_table.zero();

    return page_table;
}

/// Switches to the given page table.
pub fn switchToPageTable(page_table: *const PageTable) void {
    registers.Cr3.writeAddress(
        VirtualAddress.fromPtr(page_table).unsafeToPhysicalFromDirectMap(),
    );
}

const MapError = arch.paging.MapError;

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
///
/// This function will only use the architecture's `standard_page_size`.
pub fn mapToPhysicalRange(
    page_table: *PageTable,
    virtual_range: VirtualRange,
    physical_range: PhysicalRange,
    map_type: memory.virtual.MapType,
) MapError!void {
    log.debug("mapStandardRange - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();
    var current_physical_address = physical_range.address;

    var kib_page_mappings: usize = 0;

    while (current_virtual_address.lessThan(end_virtual_address)) {
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

        current_virtual_address.moveForwardInPlace(small_page_size);
        current_physical_address.moveForwardInPlace(small_page_size);
    }

    log.debug("mapStandardRange - satified using {} 4KiB pages", .{kib_page_mappings});
}

/// Unmaps the `virtual_range`.
///
/// This function assumes only the architecture's `standard_page_size` is used for the mapping.
pub fn unmap(
    page_table: *PageTable,
    virtual_range: VirtualRange,
) void {
    log.debug("unmapRange - {}", .{virtual_range});

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();

    while (current_virtual_address.lessThan(end_virtual_address)) {
        unmap4KiB(page_table, current_virtual_address);

        current_virtual_address.moveForwardInPlace(small_page_size);
    }
}

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
///
/// This function is allowed to use all page sizes available to the architecture.
pub fn mapToPhysicalRangeAllPageSizes(
    page_table: *PageTable,
    virtual_range: VirtualRange,
    physical_range: PhysicalRange,
    map_type: memory.virtual.MapType,
) MapError!void {
    log.debug("mapRangeUseAllPageSizes - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual_address = virtual_range.address;
    const end_virtual_address = virtual_range.end();
    var current_physical_address = physical_range.address;
    var size_remaining = virtual_range.size;

    var gib_page_mappings: usize = 0;
    var mib_page_mappings: usize = 0;
    var kib_page_mappings: usize = 0;

    while (current_virtual_address.lessThan(end_virtual_address)) {
        const map_1gib = arch_info.has_gib_pages and
            size_remaining.greaterThanOrEqual(large_page_size) and
            current_virtual_address.isAligned(large_page_size) and
            current_physical_address.isAligned(large_page_size);

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

            current_virtual_address.moveForwardInPlace(large_page_size);
            current_physical_address.moveForwardInPlace(large_page_size);
            size_remaining.subtractInPlace(large_page_size);
            continue;
        }

        const map_2mib = size_remaining.greaterThanOrEqual(medium_page_size) and
            current_virtual_address.isAligned(medium_page_size) and
            current_physical_address.isAligned(medium_page_size);

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

            current_virtual_address.moveForwardInPlace(medium_page_size);
            current_physical_address.moveForwardInPlace(medium_page_size);
            size_remaining.subtractInPlace(medium_page_size);
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

        current_virtual_address.moveForwardInPlace(small_page_size);
        current_physical_address.moveForwardInPlace(small_page_size);
        size_remaining.subtractInPlace(small_page_size);
    }

    log.debug(
        "mapRangeUseAllPageSizes - satified using {} 1GiB pages, {} 2MiB pages, {} 4KiB pages",
        .{ gib_page_mappings, mib_page_mappings, kib_page_mappings },
    );
}

/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    map_type: memory.virtual.MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(small_page_size));

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

/// Maps a 2 MiB page.
fn mapTo2MiB(
    level4_table: *PageTable,
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    map_type: memory.virtual.MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(medium_page_size));
    core.debugAssert(physical_address.isAligned(medium_page_size));

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

/// Maps a 1 GiB page.
fn mapTo1GiB(
    level4_table: *PageTable,
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    map_type: memory.virtual.MapType,
) MapError!void {
    core.debugAssert(arch_info.has_gib_pages); // assert that 1GiB pages are available
    core.debugAssert(virtual_address.isAligned(large_page_size));
    core.debugAssert(physical_address.isAligned(large_page_size));

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

/// Unmaps a 4 KiB page.
fn unmap4KiB(
    level4_table: *PageTable,
    virtual_address: VirtualAddress,
) void {
    core.debugAssert(virtual_address.isAligned(small_page_size));

    const level4_entry = level4_table.getEntryLevel4(virtual_address);
    if (!level4_entry.present.read() or level4_entry.huge.read()) return;

    const level3_table = level4_entry.getNextLevel() catch unreachable; // checked above
    const level3_entry = level3_table.getEntryLevel3(virtual_address);
    if (!level3_entry.present.read() or level3_entry.huge.read()) return;

    const level2_table = level3_entry.getNextLevel() catch unreachable; // checked above
    const level2_entry = level2_table.getEntryLevel2(virtual_address);
    if (!level2_entry.present.read() or level2_entry.huge.read()) return;

    const level1_table = level2_entry.getNextLevel() catch unreachable; // checked above
    const level1_entry = level1_table.getEntryLevel1(virtual_address);
    if (!level2_entry.present.read()) return;

    memory.physical.deallocatePage(
        PhysicalRange.fromAddr(level1_entry.getAddress4kib(), arch.paging.standard_page_size),
    );

    level1_entry.zero();
}

fn applyMapType(map_type: memory.virtual.MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);

    if (map_type.user) {
        entry.user_accessible.write(true);
    }

    if (map_type.global) {
        entry.global.write(true);
    }

    if (!map_type.executable and arch_info.has_execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: memory.virtual.MapType, entry: *PageTable.Entry) void {
    entry.present.write(true);
    entry.writeable.write(true);
    if (map_type.user) entry.user_accessible.write(true);
}

/// Ensures the next page table level exists.
fn ensureNextTable(
    self: *PageTable.Entry,
    map_type: memory.virtual.MapType,
) error{ AllocationFailed, Unexpected }!*PageTable {
    var opt_range: ?PhysicalRange = null;

    if (!self.present.read()) {
        opt_range = memory.physical.allocatePage() orelse return error.AllocationFailed;
        self.setAddress4kib(opt_range.?.address);
    }
    errdefer if (opt_range) |range| {
        self.setAddress4kib(PhysicalAddress.zero);
        memory.physical.deallocatePage(range);
    };

    applyParentMapType(map_type, self);

    const next_level = self.getNextLevel() catch |err| switch (err) {
        error.HugePage => return error.Unexpected,
        error.NotPresent => unreachable, // we ensure it is present above
    };

    if (opt_range != null) next_level.zero();

    return next_level;
}

pub const init = struct {
    /// This function is only called during kernel init, it is required to:
    ///   1. search the high half of the *top level* of the given page table for a free entry
    ///   2. allocate a backing frame for it
    ///   3. map the free entry to the fresh backing frame and ensure it is zeroed
    ///   4. return the `VirtualRange` representing the entire virtual range that entry covers
    pub fn getTopLevelRangeAndFillFirstLevel(page_table: *PageTable) linksection(info.init_code) arch.paging.MapError!VirtualRange {
        var table_index: usize = PageTable.p4Index(higher_half);

        while (table_index < PageTable.number_of_entries) : (table_index += 1) {
            const entry = &page_table.entries[table_index];
            if (entry._backing != 0) continue;

            log.debug("found free top level entry for at table_index {}", .{table_index});

            _ = try ensureNextTable(entry, .{ .global = true, .writeable = true });

            return VirtualRange.fromAddr(
                PageTable.indexToAddr(
                    @truncate(table_index),
                    0,
                    0,
                    0,
                ),
                size_of_top_level_entry,
            );
        }

        core.panic("unable to find unused entry in top level of page table");
    }
};
