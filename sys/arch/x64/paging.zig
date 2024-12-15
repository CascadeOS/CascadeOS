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

pub fn loadPageTable(physical_address: core.PhysicalAddress) void {
    lib_x64.registers.Cr3.writeAddress(physical_address);
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
    allocate_page_context: anytype,
    comptime allocatePage: fn (ctx: @TypeOf(allocate_page_context)) error{OutOfPhysicalMemory}!core.PhysicalRange,
) !*PageTable {
    const next_level_physical_address = blk: {
        var entry: PageTable.Entry = .{ .raw = raw_entry.* };

        if (entry.present.read()) {
            if (entry.huge.read()) return error.MappingNotValid;

            break :blk entry.getAddress4kib();
        }

        std.debug.assert(entry.raw == 0);

        const backing_range = try allocatePage(allocate_page_context);
        errdefer comptime unreachable;

        entry.setAddress4kib(backing_range.address);
        entry.present.write(true);
        applyParentMapType(map_type, &entry);

        raw_entry.* = entry.raw;

        break :blk backing_range.address;
    };

    return kernel.memory_layout
        .directMapFromPhysical(next_level_physical_address)
        .toPtr(*PageTable);
}

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
    /// This function panics on error.
    pub fn fillTopLevel(
        level4_table: *PageTable,
        range: core.VirtualRange,
        map_type: kernel.mem.MapType,
        allocate_page_context: anytype,
        comptime allocatePage: fn (ctx: @TypeOf(allocate_page_context)) error{OutOfPhysicalMemory}!core.PhysicalRange,
    ) void {
        const size_of_top_level_entry = sizeOfTopLevelEntry();
        std.debug.assert(range.size.equal(size_of_top_level_entry));
        std.debug.assert(range.address.isAligned(size_of_top_level_entry));

        const raw_entry = &level4_table.entries[PageTable.p4Index(range.address)];
        const entry: PageTable.Entry = .{ .raw = raw_entry.* };
        if (entry.present.read()) core.panic("already mapped", null);

        _ = core.require(ensureNextTable(
            raw_entry,
            map_type,
            allocate_page_context,
            allocatePage,
        ), "failed to allocate page table");
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
    ///  - panics on error
    pub fn mapToPhysicalRangeAllPageSizes(
        level4_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: kernel.mem.MapType,
        allocate_page_context: anytype,
        comptime allocatePage: fn (ctx: @TypeOf(allocate_page_context)) error{OutOfPhysicalMemory}!core.PhysicalRange,
    ) void {
        std.debug.assert(virtual_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.isAligned(PageTable.small_page_size));
        std.debug.assert(physical_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(physical_range.size.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.equal(physical_range.size));

        const supports_1gib = x64.info.cpu_id.gbyte_pages;

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();
        var current_physical_address = physical_range.address;
        var size_remaining = virtual_range.size;

        var level4_index = PageTable.p4Index(current_virtual_address);
        const last_level4_index = PageTable.p4Index(last_virtual_address);

        while (level4_index <= last_level4_index) : (level4_index += 1) {
            const level3_table = core.require(ensureNextTable(
                &level4_table.entries[level4_index],
                map_type,
                allocate_page_context,
                allocatePage,
            ), "failed to allocate page table");

            var level3_index = PageTable.p3Index(current_virtual_address);
            const last_level3_index = if (size_remaining.greaterThanOrEqual(PageTable.level_4_address_space_size))
                PageTable.number_of_entries - 1
            else
                PageTable.p3Index(last_virtual_address);

            while (level3_index <= last_level3_index) : (level3_index += 1) {
                if (supports_1gib and
                    size_remaining.greaterThanOrEqual(PageTable.large_page_size) and
                    current_virtual_address.isAligned(PageTable.large_page_size) and
                    current_physical_address.isAligned(PageTable.large_page_size))
                {
                    // large 1 GiB page
                    setEntry(
                        level3_table,
                        level3_index,
                        current_physical_address,
                        map_type,
                        .large,
                    );

                    current_virtual_address.moveForwardInPlace(PageTable.large_page_size);
                    current_physical_address.moveForwardInPlace(PageTable.large_page_size);
                    size_remaining.subtractInPlace(PageTable.large_page_size);
                    continue;
                }

                const level2_table = core.require(ensureNextTable(
                    &level3_table.entries[level3_index],
                    map_type,
                    allocate_page_context,
                    allocatePage,
                ), "failed to allocate page table");

                var level2_index = PageTable.p2Index(current_virtual_address);
                const last_level2_index = if (size_remaining.greaterThanOrEqual(PageTable.level_3_address_space_size))
                    PageTable.number_of_entries - 1
                else
                    PageTable.p2Index(last_virtual_address);

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    if (size_remaining.greaterThanOrEqual(PageTable.medium_page_size) and
                        current_virtual_address.isAligned(PageTable.medium_page_size) and
                        current_physical_address.isAligned(PageTable.medium_page_size))
                    {
                        // large 2 MiB page
                        setEntry(
                            level2_table,
                            level2_index,
                            current_physical_address,
                            map_type,
                            .medium,
                        );

                        current_virtual_address.moveForwardInPlace(PageTable.medium_page_size);
                        current_physical_address.moveForwardInPlace(PageTable.medium_page_size);
                        size_remaining.subtractInPlace(PageTable.medium_page_size);
                        continue;
                    }

                    const level1_table = core.require(ensureNextTable(
                        &level2_table.entries[level2_index],
                        map_type,
                        allocate_page_context,
                        allocatePage,
                    ), "failed to allocate page table");

                    var level1_index = PageTable.p1Index(current_virtual_address);
                    const last_level1_index = if (size_remaining.greaterThanOrEqual(PageTable.level_2_address_space_size))
                        PageTable.number_of_entries - 1
                    else
                        PageTable.p1Index(last_virtual_address);

                    while (level1_index <= last_level1_index) : (level1_index += 1) {
                        setEntry(
                            level1_table,
                            level1_index,
                            current_physical_address,
                            map_type,
                            .small,
                        );

                        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
                        current_physical_address.moveForwardInPlace(PageTable.small_page_size);
                        size_remaining.subtractInPlace(PageTable.small_page_size);
                    }
                }
            }
        }
    }

    fn setEntry(
        page_table: *PageTable,
        index: usize,
        physical_address: core.PhysicalAddress,
        map_type: kernel.mem.MapType,
        comptime page_type: enum { small, medium, large },
    ) void {
        var entry = PageTable.Entry{ .raw = page_table.entries[index] };

        if (entry.present.read()) core.panic("already mapped", null);

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
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const arch = @import("arch");
const MapType = kernel.mem.MapType;
const log = kernel.log.scoped(.paging_x64);
const PageTable = lib_x64.PageTable;
