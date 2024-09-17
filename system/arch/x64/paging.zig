// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Create a new page table at the given physical range.
///
/// The range must have alignment of `page_table_alignment` and size greater than or equal to
/// `page_table_size`.
pub fn createPageTable(physical_range: core.PhysicalRange) *ArchPageTable {
    std.debug.assert(physical_range.address.isAligned(page_table_alignment));
    std.debug.assert(physical_range.size.greaterThanOrEqual(page_table_size));

    const page_table = kernel.memory_layout.directMapFromPhysical(physical_range.address).toPtr(*ArchPageTable);
    page_table.zero();
    return page_table;
}

pub fn loadPageTable(physical_address: core.PhysicalAddress) void {
    lib_x64.registers.Cr3.writeAddress(physical_address);
}

pub const page_table_alignment = ArchPageTable.small_page_size;
pub const page_table_size = ArchPageTable.small_page_size;

pub const all_page_sizes = &.{
    ArchPageTable.small_page_size,
    ArchPageTable.medium_page_size,
    ArchPageTable.large_page_size,
};

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

pub const ArchPageTable = lib_x64.PageTable;

pub const init = struct {
    /// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///  - the physical range address and size are aligned to the standard page size
    ///  - the virtual range size is equal to the physical range size
    ///  - the virtual range is not already mapped
    ///
    /// This function:
    ///  - uses all page sizes available to the architecture
    ///  - does not flush the TLB
    ///  - on error is not required to roll back any modifications to the page tables
    pub fn mapToPhysicalRangeAllPageSizes(
        page_table: *ArchPageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: MapType,
        comptime allocatePage: fn () error{OutOfPhysicalMemory}!core.PhysicalRange,
        comptime deallocatePage: fn (core.PhysicalRange) void,
    ) arch.paging.MapError!void {
        std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
        std.debug.assert(physical_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
        std.debug.assert(physical_range.size.equal(virtual_range.size));

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();
        var current_physical_address = physical_range.address;
        var size_remaining = virtual_range.size;

        var gib_page_mappings: usize = 0;
        var mib_page_mappings: usize = 0;
        var kib_page_mappings: usize = 0;

        while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
            const map_1gib = x64.info.cpu_id.gbyte_pages and
                size_remaining.greaterThanOrEqual(ArchPageTable.large_page_size) and
                current_virtual_address.isAligned(ArchPageTable.large_page_size) and
                current_physical_address.isAligned(ArchPageTable.large_page_size);

            if (map_1gib) {
                mapTo1GiB(
                    page_table,
                    current_virtual_address,
                    current_physical_address,
                    map_type,
                    allocatePage,
                    deallocatePage,
                ) catch |err| {
                    log.err("failed to map {} to {} 1GiB", .{ current_virtual_address, current_physical_address });
                    return err;
                };

                gib_page_mappings += 1;

                current_virtual_address.moveForwardInPlace(ArchPageTable.large_page_size);
                current_physical_address.moveForwardInPlace(ArchPageTable.large_page_size);
                size_remaining.subtractInPlace(ArchPageTable.large_page_size);
                continue;
            }

            const map_2mib = size_remaining.greaterThanOrEqual(ArchPageTable.medium_page_size) and
                current_virtual_address.isAligned(ArchPageTable.medium_page_size) and
                current_physical_address.isAligned(ArchPageTable.medium_page_size);

            if (map_2mib) {
                mapTo2MiB(
                    page_table,
                    current_virtual_address,
                    current_physical_address,
                    map_type,
                    allocatePage,
                    deallocatePage,
                ) catch |err| {
                    log.err("failed to map {} to {} 2MiB", .{ current_virtual_address, current_physical_address });
                    return err;
                };

                mib_page_mappings += 1;

                current_virtual_address.moveForwardInPlace(ArchPageTable.medium_page_size);
                current_physical_address.moveForwardInPlace(ArchPageTable.medium_page_size);
                size_remaining.subtractInPlace(ArchPageTable.medium_page_size);
                continue;
            }

            mapTo4KiB(
                page_table,
                current_virtual_address,
                current_physical_address,
                map_type,
                allocatePage,
                deallocatePage,
            ) catch |err| {
                log.err("failed to map {} to {} 4KiB", .{ current_virtual_address, current_physical_address });
                return err;
            };

            kib_page_mappings += 1;

            current_virtual_address.moveForwardInPlace(ArchPageTable.small_page_size);
            current_physical_address.moveForwardInPlace(ArchPageTable.small_page_size);
            size_remaining.subtractInPlace(ArchPageTable.small_page_size);
        }

        log.debug(
            "mapToPhysicalRangeAllPageSizes - satified using {} 1GiB pages, {} 2MiB pages, {} 4KiB pages",
            .{ gib_page_mappings, mib_page_mappings, kib_page_mappings },
        );
    }

    /// Maps a 1 GiB page.
    ///
    /// Only kernel init maps 1 GiB pages.
    fn mapTo1GiB(
        level4_table: *ArchPageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
        comptime allocatePage: fn () error{OutOfPhysicalMemory}!core.PhysicalRange,
        comptime deallocatePage: fn (core.PhysicalRange) void,
    ) arch.paging.MapError!void {
        std.debug.assert(x64.info.cpu_id.gbyte_pages);
        std.debug.assert(virtual_address.isAligned(ArchPageTable.large_page_size));
        std.debug.assert(physical_address.isAligned(ArchPageTable.large_page_size));

        const raw_level4_entry = level4_table.getEntry(.four, virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            raw_level4_entry,
            map_type,
            allocatePage,
        );
        errdefer {
            if (created_level3_table) {
                var level_4_entry = raw_level4_entry.load();

                const address = level_4_entry.getAddress4kib();
                level_4_entry.zero();
                raw_level4_entry.store(level_4_entry);

                deallocatePage(address.toRange(ArchPageTable.small_page_size));
            }
        }

        const raw_entry = level3_table.getEntry(.three, virtual_address);
        var entry = raw_entry.load();

        if (entry.present.read()) return error.AlreadyMapped;
        errdefer comptime unreachable;

        entry.setAddress1gib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, &entry);

        entry.present.write(true);

        raw_entry.store(entry);
    }

    /// Maps a 2 MiB page.
    ///
    /// Only kernel init maps 2 MiB pages.
    fn mapTo2MiB(
        level4_table: *ArchPageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
        comptime allocatePage: fn () error{OutOfPhysicalMemory}!core.PhysicalRange,
        comptime deallocatePage: fn (core.PhysicalRange) void,
    ) arch.paging.MapError!void {
        std.debug.assert(virtual_address.isAligned(ArchPageTable.medium_page_size));
        std.debug.assert(physical_address.isAligned(ArchPageTable.medium_page_size));

        const raw_level4_entry = level4_table.getEntry(.four, virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            raw_level4_entry,
            map_type,
            allocatePage,
        );
        errdefer {
            if (created_level3_table) {
                var level_4_entry = raw_level4_entry.load();

                const address = level_4_entry.getAddress4kib();
                level_4_entry.zero();
                raw_level4_entry.store(level_4_entry);

                deallocatePage(address.toRange(ArchPageTable.small_page_size));
            }
        }

        const raw_level3_entry = level3_table.getEntry(.three, virtual_address);

        const level2_table, const created_level2_table = try ensureNextTable(
            raw_level3_entry,
            map_type,
            allocatePage,
        );
        errdefer {
            if (created_level2_table) {
                var level_3_entry = raw_level3_entry.load();

                const address = level_3_entry.getAddress4kib();
                level_3_entry.zero();
                raw_level4_entry.store(level_3_entry);

                deallocatePage(address.toRange(ArchPageTable.small_page_size));
            }
        }

        const raw_entry = level2_table.getEntry(.two, virtual_address);
        var entry = raw_entry.load();

        if (entry.present.read()) return error.AlreadyMapped;
        errdefer comptime unreachable;

        entry.setAddress2mib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, &entry);

        entry.present.write(true);

        raw_entry.store(entry);
    }
};

/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *ArchPageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
    comptime allocatePage: fn () error{OutOfPhysicalMemory}!core.PhysicalRange,
    comptime deallocatePage: fn (core.PhysicalRange) void,
) arch.paging.MapError!void {
    std.debug.assert(virtual_address.isAligned(ArchPageTable.small_page_size));
    std.debug.assert(physical_address.isAligned(ArchPageTable.small_page_size));

    const raw_level4_entry = level4_table.getEntry(.four, virtual_address);

    const level3_table, const created_level3_table = try ensureNextTable(
        raw_level4_entry,
        map_type,
        allocatePage,
    );
    errdefer {
        if (created_level3_table) {
            var level_4_entry = raw_level4_entry.load();

            const address = level_4_entry.getAddress4kib();
            level_4_entry.zero();
            raw_level4_entry.store(level_4_entry);

            deallocatePage(address.toRange(ArchPageTable.small_page_size));
        }
    }

    const raw_level3_entry = level3_table.getEntry(.three, virtual_address);

    const level2_table, const created_level2_table = try ensureNextTable(
        raw_level3_entry,
        map_type,
        allocatePage,
    );
    errdefer {
        if (created_level2_table) {
            var level_3_entry = raw_level3_entry.load();

            const address = level_3_entry.getAddress4kib();
            level_3_entry.zero();
            raw_level4_entry.store(level_3_entry);

            deallocatePage(address.toRange(ArchPageTable.small_page_size));
        }
    }

    const raw_level2_entry = level2_table.getEntry(.two, virtual_address);

    const level1_table, const created_level1_table = try ensureNextTable(
        raw_level2_entry,
        map_type,
        allocatePage,
    );
    errdefer {
        if (created_level1_table) {
            var level_2_entry = raw_level2_entry.load();

            const address = level_2_entry.getAddress4kib();
            level_2_entry.zero();
            raw_level4_entry.store(level_2_entry);

            deallocatePage(address.toRange(ArchPageTable.small_page_size));
        }
    }

    const raw_entry = level1_table.getEntry(.one, virtual_address);
    var entry = raw_entry.load();

    if (entry.present.read()) return error.AlreadyMapped;
    errdefer comptime unreachable;

    entry.setAddress4kib(physical_address);

    applyMapType(map_type, &entry);

    entry.present.write(true);

    raw_entry.store(entry);
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
    if (map_type.user) entry.user_accessible.write(true);

    if (map_type.global) entry.global.write(true);

    if (!map_type.executable and x64.info.cpu_id.execute_disable) entry.no_execute.write(true);

    if (map_type.writeable) entry.writeable.write(true);

    if (map_type.no_cache) {
        entry.no_cache.write(true);
        entry.write_through.write(true);
    }
}

fn applyParentMapType(map_type: MapType, entry: *ArchPageTable.Entry) void {
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
