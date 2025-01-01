// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Create a new page table at the given physical range.
///
/// The range must have alignment of `page_table_alignment` and size greater than or equal to
/// `page_table_size`.
pub fn createPageTable(physical_range: core.PhysicalRange) *PageTable {
    std.debug.assert(physical_range.address.isAligned(page_table_alignment));
    std.debug.assert(physical_range.size.greaterThanOrEqual(page_table_size));

    const page_table = kernel.vmm.directMapFromPhysical(physical_range.address).toPtr(*PageTable);
    page_table.zero();
    return page_table;
}

pub fn loadPageTable(physical_address: core.PhysicalAddress) void {
    lib_x64.registers.Cr3.writeAddress(physical_address);
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
) kernel.vmm.MapError!void {
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

        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
        current_physical_address.moveForwardInPlace(PageTable.small_page_size);
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
    free_backing_pages: bool,
) void {
    log.debug("unmapRange - {}", .{virtual_range});

    var current_virtual_address = virtual_range.address;
    const last_virtual_address = virtual_range.last();

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        unmap4KiB(page_table, current_virtual_address, free_backing_pages);

        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
    }
}

/// Maps a 4 KiB page.
fn mapTo4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
) kernel.vmm.MapError!void {
    std.debug.assert(virtual_address.isAligned(PageTable.small_page_size));
    std.debug.assert(physical_address.isAligned(PageTable.small_page_size));

    const level4_index = PageTable.p4Index(virtual_address);

    const level3_table, const created_level3_table = try ensureNextTable(
        &level4_table.entries[level4_index],
        map_type,
    );
    errdefer {
        if (created_level3_table) {
            var level4_entry: PageTable.Entry = .{ .raw = level4_table.entries[level4_index] };
            const address = level4_entry.getAddress4kib();
            level4_table.entries[level4_index] = 0;
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level3_index = PageTable.p3Index(virtual_address);

    const level2_table, const created_level2_table = try ensureNextTable(
        &level3_table.entries[level3_index],
        map_type,
    );
    errdefer {
        if (created_level2_table) {
            var level3_entry: PageTable.Entry = .{ .raw = level3_table.entries[level3_index] };
            const address = level3_entry.getAddress4kib();
            level3_table.entries[level3_index] = 0;
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    const level2_index = PageTable.p2Index(virtual_address);

    const level1_table, const created_level1_table = try ensureNextTable(
        &level2_table.entries[level2_index],
        map_type,
    );
    errdefer {
        if (created_level1_table) {
            var level2_entry: PageTable.Entry = .{ .raw = level2_table.entries[level2_index] };
            const address = level2_entry.getAddress4kib();
            level2_table.entries[level2_index] = 0;
            kernel.pmm.deallocatePage(address.toRange(PageTable.small_page_size));
        }
    }

    try setEntry(
        level1_table,
        PageTable.p1Index(virtual_address),
        physical_address,
        map_type,
        .small,
    );
}

/// Unmaps a 4 KiB page.
///
/// Panics if the page is not present or is a huge page.
fn unmap4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    free_backing_pages: bool,
) void {
    // TODO: tables are not freed when empty, could be done on defer
    //       but this would break things like the kernel heap

    std.debug.assert(virtual_address.isAligned(PageTable.small_page_size));

    const level4_index = PageTable.p4Index(virtual_address);
    const level4_entry: PageTable.Entry = .{ .raw = level4_table.entries[level4_index] };

    const level3_table = level4_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => core.panic("page table entry is not present", null),
        error.HugePage => core.panic("page table entry is huge", null),
    };

    const level3_index = PageTable.p3Index(virtual_address);
    const level3_entry: PageTable.Entry = .{ .raw = level3_table.entries[level3_index] };

    const level2_table = level3_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => core.panic("page table entry is not present", null),
        error.HugePage => core.panic("page table entry is huge", null),
    };

    const level2_index = PageTable.p2Index(virtual_address);
    const level2_entry: PageTable.Entry = .{ .raw = level2_table.entries[level2_index] };

    const level1_table = level2_entry.getNextLevel(
        kernel.vmm.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => core.panic("page table entry is not present", null),
        error.HugePage => core.panic("page table entry is huge", null),
    };

    const level1_index = PageTable.p1Index(virtual_address);
    const level1_entry: PageTable.Entry = .{ .raw = level1_table.entries[level1_index] };

    if (!level1_entry.present.read()) {
        core.panic("page table entry is not present", null);
    }

    if (free_backing_pages) {
        kernel.pmm.deallocatePage(
            core.PhysicalRange.fromAddr(
                level1_entry.getAddress4kib(),
                PageTable.small_page_size,
            ),
        );
    }

    level1_table.entries[level1_index] = 0;
}

fn applyMapType(map_type: MapType, entry: *PageTable.Entry) void {
    if (map_type.user) entry.user_accessible.write(true);

    if (map_type.global) entry.global.write(true);

    if (x64.info.cpu_id.execute_disable) {
        @branchHint(.likely); // modern CPUs support NX

        if (!map_type.executable) entry.no_execute.write(true);
    }

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

fn ensureNextTable(
    raw_entry: *u64,
    map_type: MapType,
) !struct { *PageTable, bool } {
    var created_table = false;

    const next_level_physical_address = blk: {
        var entry: PageTable.Entry = .{ .raw = raw_entry.* };

        if (entry.present.read()) {
            if (entry.huge.read()) return error.MappingNotValid;

            break :blk entry.getAddress4kib();
        }
        std.debug.assert(entry.raw == 0);
        created_table = true;

        const backing_range = try kernel.pmm.allocatePage();
        errdefer comptime unreachable;

        @memset(kernel.vmm.directMapFromPhysicalRange(backing_range).toByteSlice(), 0);

        entry.setAddress4kib(backing_range.address);
        entry.present.write(true);
        applyParentMapType(map_type, &entry);

        raw_entry.* = entry.raw;

        break :blk backing_range.address;
    };

    return .{
        kernel.vmm
            .directMapFromPhysical(next_level_physical_address)
            .toPtr(*PageTable),
        created_table,
    };
}

fn setEntry(
    page_table: *PageTable,
    index: usize,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
    comptime page_type: enum { small, medium, large },
) error{AlreadyMapped}!void {
    var entry = PageTable.Entry{ .raw = page_table.entries[index] };

    if (entry.present.read()) return error.AlreadyMapped;

    switch (page_type) {
        .small => entry.setAddress4kib(physical_address),
        .medium => {
            entry.huge.write(true);
            entry.setAddress2mib(physical_address);
        },
        .large => {
            entry.huge.write(true);
            entry.setAddress1gib(physical_address);
        },
    }

    applyMapType(map_type, &entry);

    entry.present.write(true);

    page_table.entries[index] = entry.raw;
}

pub const all_page_sizes: []const core.Size = &.{
    small_page_size,
    medium_page_size,
    large_page_size,
};

pub const higher_half_start = core.VirtualAddress.fromInt(0xffff800000000000);

/// The largest possible higher half virtual address.
pub const largest_higher_half_virtual_address: core.VirtualAddress = core.VirtualAddress.fromInt(0xffffffffffffffff);

pub const ArchPageTable = PageTable;
pub const page_table_alignment = PageTable.small_page_size;
pub const page_table_size = PageTable.small_page_size;

pub const init = struct {
    /// The total size of the virtual address space that one entry in the top level of the page table covers.
    pub inline fn sizeOfTopLevelEntry() core.Size {
        // TODO: Only correct for 4 level paging
        return core.Size.from(0x8000000000, .byte);
    }

    /// This function fills in the top level of the page table for the given range.
    ///
    /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
    ///
    /// This function:
    ///  - does not flush the TLB
    ///  - does not rollback on error
    pub fn fillTopLevel(
        page_table: *PageTable,
        range: core.VirtualRange,
        map_type: kernel.vmm.MapType,
    ) !void {
        const size_of_top_level_entry = sizeOfTopLevelEntry();
        std.debug.assert(range.size.equal(size_of_top_level_entry));
        std.debug.assert(range.address.isAligned(size_of_top_level_entry));

        const raw_entry = &page_table.entries[PageTable.p4Index(range.address)];

        const entry: PageTable.Entry = .{ .raw = raw_entry.* };
        if (entry.present.read()) core.panic("already mapped", null);

        _ = try ensureNextTable(raw_entry, map_type);
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
    ///  - does not rollback on error
    pub fn mapToPhysicalRangeAllPageSizes(
        level4_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: MapType,
    ) !void {
        std.debug.assert(virtual_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.isAligned(PageTable.small_page_size));
        std.debug.assert(physical_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(physical_range.size.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.equal(physical_range.size));

        init_log.debug("mapToPhysicalRangeAllPageSizes - virtual_range: {} - physical_range: {} - map_type: {}", .{
            virtual_range,
            physical_range,
            map_type,
        });

        var large_pages_mapped: usize = 0;
        var medium_pages_mapped: usize = 0;
        var small_pages_mapped: usize = 0;

        const supports_1gib = x64.info.cpu_id.gbyte_pages;

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();
        var current_physical_address = physical_range.address;
        var size_remaining = virtual_range.size;

        const last_virtual_address_p4_index = PageTable.p4Index(last_virtual_address);
        const last_virtual_address_p3_index = PageTable.p3Index(last_virtual_address);
        const last_virtual_address_p2_index = PageTable.p2Index(last_virtual_address);

        var level4_index = PageTable.p4Index(current_virtual_address);

        while (level4_index <= last_virtual_address_p4_index) : (level4_index += 1) {
            const level3_table, _ = try ensureNextTable(
                &level4_table.entries[level4_index],
                map_type,
            );

            var level3_index = PageTable.p3Index(current_virtual_address);
            const last_level3_index = if (last_virtual_address_p4_index == level4_index)
                PageTable.p3Index(last_virtual_address)
            else
                PageTable.number_of_entries - 1;

            while (level3_index <= last_level3_index) : (level3_index += 1) {
                if (supports_1gib and
                    size_remaining.greaterThanOrEqual(PageTable.large_page_size) and
                    current_virtual_address.isAligned(PageTable.large_page_size) and
                    current_physical_address.isAligned(PageTable.large_page_size))
                {
                    // large 1 GiB page
                    try setEntry(
                        level3_table,
                        level3_index,
                        current_physical_address,
                        map_type,
                        .large,
                    );

                    large_pages_mapped += 1;

                    current_virtual_address.moveForwardInPlace(PageTable.large_page_size);
                    current_physical_address.moveForwardInPlace(PageTable.large_page_size);
                    size_remaining.subtractInPlace(PageTable.large_page_size);
                    continue;
                }

                const level2_table, _ = try ensureNextTable(
                    &level3_table.entries[level3_index],
                    map_type,
                );

                var level2_index = PageTable.p2Index(current_virtual_address);
                const last_level2_index = if (last_virtual_address_p3_index == level3_index)
                    PageTable.p2Index(last_virtual_address)
                else
                    PageTable.number_of_entries - 1;

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    if (size_remaining.greaterThanOrEqual(PageTable.medium_page_size) and
                        current_virtual_address.isAligned(PageTable.medium_page_size) and
                        current_physical_address.isAligned(PageTable.medium_page_size))
                    {
                        // large 2 MiB page
                        try setEntry(
                            level2_table,
                            level2_index,
                            current_physical_address,
                            map_type,
                            .medium,
                        );

                        medium_pages_mapped += 1;

                        current_virtual_address.moveForwardInPlace(PageTable.medium_page_size);
                        current_physical_address.moveForwardInPlace(PageTable.medium_page_size);
                        size_remaining.subtractInPlace(PageTable.medium_page_size);
                        continue;
                    }

                    const level1_table, _ = try ensureNextTable(
                        &level2_table.entries[level2_index],
                        map_type,
                    );

                    var level1_index = PageTable.p1Index(current_virtual_address);
                    const last_level1_index = if (last_virtual_address_p2_index == level2_index)
                        PageTable.p1Index(last_virtual_address)
                    else
                        PageTable.number_of_entries - 1;

                    while (level1_index <= last_level1_index) : (level1_index += 1) {
                        try setEntry(
                            level1_table,
                            level1_index,
                            current_physical_address,
                            map_type,
                            .small,
                        );

                        small_pages_mapped += 1;

                        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
                        current_physical_address.moveForwardInPlace(PageTable.small_page_size);
                        size_remaining.subtractInPlace(PageTable.small_page_size);
                    }
                }
            }
        }

        init_log.debug(
            "satified using {} large pages, {} medium pages, {} small pages",
            .{ large_pages_mapped, medium_pages_mapped, small_pages_mapped },
        );
    }

    const init_log = kernel.debug.log.scoped(.init_x64_paging);
};

const small_page_size = PageTable.small_page_size;
const medium_page_size = PageTable.medium_page_size;
const large_page_size = PageTable.large_page_size;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const PageTable = lib_x64.PageTable;
const MapType = kernel.vmm.MapType;
const log = kernel.debug.log.scoped(.x64_paging);
