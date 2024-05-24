// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.paging_x64);

const PageTable = x64.PageTable;
const MapType = kernel.vmm.MapType;
const MapError = kernel.arch.paging.MapError;

pub const higher_half = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

/// Allocates a new page table and returns a pointer to it in the direct map.
pub fn allocatePageTable() kernel.pmm.AllocateError!*PageTable {
    const range = try kernel.pmm.allocatePage();
    core.assert(range.size.greaterThanOrEqual(core.Size.of(x64.PageTable)));

    const page_table = kernel.vmm.directMapFromPhysical(range.address).toPtr(*x64.PageTable);
    page_table.* = .{};

    return page_table;
}

/// Switches to the given page table.
pub fn switchToPageTable(page_table_address: core.PhysicalAddress) void {
    x64.Cr3.writeAddress(page_table_address);
}

/// Maps the `virtual_range` to the `physical_range` with mapping type given by `map_type`.
///
/// Caller must ensure:
///  - the virtual range address and size are aligned to the standard page size
///  - the physical range address and size are aligned to the standard page size
///  - the virtual range size is equal to the physical range size
///  - the virtual range is not already mapped
///
/// This function:
///  - uses only the standard page size for the architecture
///  - does not flush the TLB
///  - on error is not required roll back any modifications to the page tables
pub fn mapToPhysicalRange(
    page_table: *PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: kernel.vmm.MapType,
) MapError!void {
    log.debug("mapToPhysicalRange - {} - {} - {}", .{ virtual_range, physical_range, map_type });

    var current_virtual_address = virtual_range.address;
    const last_virtual_address = virtual_range.last();
    var current_physical_address = physical_range.address;

    var kib_page_mappings: usize = 0;

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        mapTo4KiB(
            page_table,
            current_virtual_address,
            current_physical_address,
            map_type,
        ) catch |err| {
            // TODO: roll back any modifications to the page tables
            log.err("failed to map {} to {} 4KiB", .{ current_virtual_address, current_physical_address });
            return err;
        };

        kib_page_mappings += 1;

        current_virtual_address.moveForwardInPlace(x64.PageTable.small_page_size);
        current_physical_address.moveForwardInPlace(x64.PageTable.small_page_size);
    }

    log.debug("mapToPhysicalRange - satified using {} 4KiB pages", .{kib_page_mappings});
}

/// Unmaps the `virtual_range`.
///
/// Caller must ensure:
///  - the virtual range address and size are aligned to the standard page size
///  - the virtual range is mapped
///  - the virtual range is mapped using only the standard page size for the architecture
///
/// This function:
///  - does not flush the TLB
pub fn unmapRange(
    page_table: *PageTable,
    virtual_range: core.VirtualRange,
) void {
    log.debug("unmapRange - {}", .{virtual_range});

    var current_virtual_address = virtual_range.address;
    const last_virtual_address = virtual_range.last();

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        unmap4KiB(page_table, current_virtual_address);

        current_virtual_address.moveForwardInPlace(x64.PageTable.small_page_size);
    }
}

/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) MapError!void {
    core.debugAssert(virtual_address.isAligned(PageTable.small_page_size));
    core.debugAssert(physical_address.isAligned(PageTable.small_page_size));

    const level4_entry = level4_table.getEntryLevel4(virtual_address);

    const level3_table, const created_level3_table = try ensureNextTable(
        level4_entry,
        map_type,
    );
    errdefer {
        if (created_level3_table) {
            const address = level4_entry.getAddress4kib();
            level4_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level3_entry = level3_table.getEntryLevel3(virtual_address);

    const level2_table, const created_level2_table = try ensureNextTable(
        level3_entry,
        map_type,
    );
    errdefer {
        if (created_level2_table) {
            const address = level3_entry.getAddress4kib();
            level3_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level2_entry = level2_table.getEntryLevel2(virtual_address);

    const level1_table, const created_level1_table = try ensureNextTable(
        level2_entry,
        map_type,
    );
    errdefer {
        if (created_level1_table) {
            const address = level2_entry.getAddress4kib();
            level2_entry.zero();
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const entry = level1_table.getEntryLevel1(virtual_address);
    if (entry.present.read()) return error.AlreadyMapped;

    entry.setAddress4kib(physical_address);

    applyMapType(map_type, entry);

    entry.present.write(true);
}

/// Unmaps a 4 KiB page.
fn unmap4KiB(
    level4_table: *x64.PageTable,
    virtual_address: core.VirtualAddress,
) void {
    core.debugAssert(virtual_address.isAligned(x64.PageTable.small_page_size));

    const level4_entry = level4_table.getEntryLevel4(virtual_address);
    if (!level4_entry.present.read() or level4_entry.huge.read()) return;

    const level3_table = level4_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch unreachable; // checked above

    const level3_entry = level3_table.getEntryLevel3(virtual_address);
    if (!level3_entry.present.read() or level3_entry.huge.read()) return;

    const level2_table = level3_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch unreachable; // checked above

    const level2_entry = level2_table.getEntryLevel2(virtual_address);
    if (!level2_entry.present.read() or level2_entry.huge.read()) return;

    const level1_table = level2_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch unreachable; // checked above

    const level1_entry = level1_table.getEntryLevel1(virtual_address);
    if (!level2_entry.present.read()) return;

    kernel.pmm.deallocatePage(
        core.PhysicalRange.fromAddr(level1_entry.getAddress4kib(), x64.PageTable.small_page_size),
    );

    level1_entry.zero();
}

/// Ensures the next page table level exists.
fn ensureNextTable(
    self: *PageTable.Entry,
    map_type: MapType,
) !struct { *PageTable, bool } {
    var opt_backing_range: ?core.PhysicalRange = null;

    const next_level_phys_address = if (self.present.read()) blk: {
        if (self.huge.read()) return error.MappingNotValid;

        break :blk self.getAddress4kib();
    } else blk: {
        // ensure there are no stray bits set
        self.zero();

        const backing_range = try kernel.pmm.allocatePage();

        opt_backing_range = backing_range;

        break :blk backing_range.address;
    };
    errdefer {
        self.zero();

        if (opt_backing_range) |backing_range| {
            kernel.pmm.deallocatePage(backing_range);
        }
    }

    applyParentMapType(map_type, self);

    const next_level = kernel.vmm.directMapFromPhysical(next_level_phys_address).toPtr(*PageTable);

    if (opt_backing_range) |backing_range| {
        next_level.zero();
        self.setAddress4kib(backing_range.address);
        self.present.write(true);
    }

    return .{ next_level, opt_backing_range != null };
}

fn applyMapType(map_type: MapType, entry: *PageTable.Entry) void {
    if (map_type.user) {
        entry.user_accessible.write(true);
    }

    if (map_type.global) {
        entry.global.write(true);
    }

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

pub const init = struct {
    /// The total size of the virtual address space that one entry in the top level of the page table covers.
    pub inline fn sizeOfTopLevelEntry() core.Size {
        // TODO: Only correct for 4 level paging
        return core.Size.from(0x8000000000, .byte);
    }

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
    ///  - on error is not required roll back any modifications to the page tables
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

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();
        var current_physical_address = physical_range.address;
        var size_remaining = virtual_range.size;

        var gib_page_mappings: usize = 0;
        var mib_page_mappings: usize = 0;
        var kib_page_mappings: usize = 0;

        while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
            const map_1gib = x64.info.cpu_id.gbyte_pages and
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
    ///
    /// Only kernel init maps 1 GiB pages.
    fn mapTo1GiB(
        level4_table: *PageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
    ) MapError!void {
        core.debugAssert(x64.info.cpu_id.gbyte_pages);
        core.debugAssert(virtual_address.isAligned(PageTable.large_page_size));
        core.debugAssert(physical_address.isAligned(PageTable.large_page_size));

        const level4_entry = level4_table.getEntryLevel4(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            level4_entry,
            map_type,
        );
        errdefer {
            if (created_level3_table) {
                const address = level4_entry.getAddress4kib();
                level4_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const entry = level3_table.getEntryLevel3(virtual_address);
        if (entry.present.read()) return error.AlreadyMapped;

        entry.setAddress1gib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, entry);

        entry.present.write(true);
    }

    /// Maps a 2 MiB page.
    ///
    /// Only kernel init maps 2 MiB pages.
    fn mapTo2MiB(
        level4_table: *PageTable,
        virtual_address: core.VirtualAddress,
        physical_address: core.PhysicalAddress,
        map_type: MapType,
    ) MapError!void {
        core.debugAssert(virtual_address.isAligned(PageTable.medium_page_size));
        core.debugAssert(physical_address.isAligned(PageTable.medium_page_size));

        const level4_entry = level4_table.getEntryLevel4(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            level4_entry,
            map_type,
        );
        errdefer {
            if (created_level3_table) {
                const address = level4_entry.getAddress4kib();
                level4_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const level3_entry = level3_table.getEntryLevel3(virtual_address);

        const level2_table, const created_level2_table = try ensureNextTable(
            level3_entry,
            map_type,
        );
        errdefer {
            if (created_level2_table) {
                const address = level3_entry.getAddress4kib();
                level3_entry.zero();
                kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
            }
        }

        const entry = level2_table.getEntryLevel2(virtual_address);
        if (entry.present.read()) return error.AlreadyMapped;

        entry.setAddress2mib(physical_address);

        entry.huge.write(true);
        applyMapType(map_type, entry);

        entry.present.write(true);
    }
};
