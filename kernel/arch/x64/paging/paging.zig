// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const MapType = cascade.mem.MapType;
const core = @import("core");

const x64 = @import("../x64.zig");
pub const PageFaultErrorCode = @import("PageFaultErrorCode.zig").PageFaultErrorCode;
pub const PageTable = @import("PageTable.zig").PageTable;

const log = cascade.debug.log.scoped(.paging);

/// Create a page table in the given physical frame.
pub fn createPageTable(physical_frame: cascade.mem.phys.Frame) *PageTable {
    const page_table = cascade.mem.directMapFromPhysical(physical_frame.baseAddress()).toPtr(*PageTable);
    page_table.zero();
    return page_table;
}

/// Flushes the cache for the given virtual range on the current executor.
///
/// The `virtual_range` address and size must be aligned to the standard page size.
pub fn flushCache(virtual_range: core.VirtualRange) void {
    if (core.is_debug) {
        std.debug.assert(virtual_range.address.isAligned(PageTable.small_page_size));
        std.debug.assert(virtual_range.size.isAligned(PageTable.small_page_size));
    }

    var current_virtual_address = virtual_range.address;
    const last_virtual_address = virtual_range.last();

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        x64.instructions.invlpg(current_virtual_address);

        current_virtual_address.moveForwardInPlace(PageTable.small_page_size);
    }
}

/// Maps a 4 KiB page.
pub fn map4KiB(
    current_task: *Task,
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    physical_frame: cascade.mem.phys.Frame,
    map_type: MapType,
    physical_frame_allocator: cascade.mem.phys.FrameAllocator,
) cascade.mem.MapError!void {
    if (core.is_debug) std.debug.assert(virtual_address.isAligned(PageTable.small_page_size));

    var deallocate_frame_list: cascade.mem.phys.FrameList = .{};
    errdefer physical_frame_allocator.deallocate(current_task, deallocate_frame_list);

    const level4_index = PageTable.p4Index(virtual_address);

    const level3_table, const created_level3_table = try ensureNextTable(
        current_task,
        &level4_table.entries[level4_index],
        physical_frame_allocator,
    );
    errdefer {
        if (created_level3_table) {
            var level4_entry = level4_table.entries[level4_index].load();
            const address = level4_entry.getAddress4kib();
            level4_table.entries[level4_index].zero();
            deallocate_frame_list.push(.fromAddress(address));
        }
    }

    const level3_index = PageTable.p3Index(virtual_address);

    const level2_table, const created_level2_table = try ensureNextTable(
        current_task,
        &level3_table.entries[level3_index],
        physical_frame_allocator,
    );
    errdefer {
        if (created_level2_table) {
            var level3_entry = level3_table.entries[level3_index].load();
            const address = level3_entry.getAddress4kib();
            level3_table.entries[level3_index].zero();
            deallocate_frame_list.push(.fromAddress(address));
        }
    }

    const level2_index = PageTable.p2Index(virtual_address);

    const level1_table, const created_level1_table = try ensureNextTable(
        current_task,
        &level2_table.entries[level2_index],
        physical_frame_allocator,
    );
    errdefer {
        if (created_level1_table) {
            var level2_entry = level2_table.entries[level2_index].load();
            const address = level2_entry.getAddress4kib();
            level2_table.entries[level2_index].zero();
            deallocate_frame_list.push(.fromAddress(address));
        }
    }

    try setEntry(
        level1_table,
        PageTable.p1Index(virtual_address),
        physical_frame.baseAddress(),
        map_type,
        .small,
    );
}

/// Unmaps a 4 KiB page.
///
/// NOP if the page is not mapped.
///
/// Panics if the page is not present or is a huge page.
pub fn unmap4KiB(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    backing_page_decision: core.CleanupDecision,
    top_level_decision: core.CleanupDecision,
    deallocate_frame_list: *cascade.mem.phys.FrameList,
) void {
    if (core.is_debug) std.debug.assert(virtual_address.isAligned(PageTable.small_page_size));

    const level4_index = PageTable.p4Index(virtual_address);
    const level4_entry = level4_table.entries[level4_index].load();

    const level3_table = level4_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    defer if (top_level_decision == .free and level3_table.isEmpty()) {
        level4_table.entries[level4_index].zero();
        deallocate_frame_list.push(.fromAddress(level4_entry.getAddress4kib()));
    };

    const level3_index = PageTable.p3Index(virtual_address);
    const level3_entry = level3_table.entries[level3_index].load();

    const level2_table = level3_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    defer if (level2_table.isEmpty()) {
        level3_table.entries[level3_index].zero();
        deallocate_frame_list.push(.fromAddress(level3_entry.getAddress4kib()));
    };

    const level2_index = PageTable.p2Index(virtual_address);
    const level2_entry = level2_table.entries[level2_index].load();

    const level1_table = level2_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    defer if (level1_table.isEmpty()) {
        level2_table.entries[level2_index].zero();
        deallocate_frame_list.push(.fromAddress(level2_entry.getAddress4kib()));
    };

    const level1_index = PageTable.p1Index(virtual_address);
    const level1_entry = level1_table.entries[level1_index].load();

    if (!level1_entry.present.read()) return;

    level1_table.entries[level1_index].zero();

    if (backing_page_decision == .free) {
        deallocate_frame_list.push(.fromAddress(level1_entry.getAddress4kib()));
    }
}

/// Changes the protection of a 4 KiB page.
///
/// NOP if the page is not mapped.
///
/// Panics if the page is a huge page.
pub fn change4KiBProtection(
    level4_table: *PageTable,
    virtual_address: core.VirtualAddress,
    map_type: MapType,
) void {
    if (core.is_debug) std.debug.assert(virtual_address.isAligned(PageTable.small_page_size));

    const level4_index = PageTable.p4Index(virtual_address);
    const level4_entry = level4_table.entries[level4_index].load();

    const level3_table = level4_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    const level3_index = PageTable.p3Index(virtual_address);
    const level3_entry = level3_table.entries[level3_index].load();

    const level2_table = level3_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    const level2_index = PageTable.p2Index(virtual_address);
    const level2_entry = level2_table.entries[level2_index].load();

    const level1_table = level2_entry.getNextLevel(
        cascade.mem.directMapFromPhysical,
    ) catch |err| switch (err) {
        error.NotPresent => return,
        error.HugePage => @panic("page table entry is huge"),
    };

    const level1_index = PageTable.p1Index(virtual_address);
    var level1_entry = level1_table.entries[level1_index].load();

    applyMapType(map_type, .small, &level1_entry);

    level1_table.entries[level1_index].store(level1_entry);
}

fn applyMapType(map_type: MapType, page_type: PageType, entry: *PageTable.Entry) void {
    switch (map_type.protection) {
        .none => {
            entry.present.write(false);
            return; // entry is not present so no need to set other fields
        },
        .read, .execute => {
            entry.present.write(true);
            entry.writeable.write(false);
        },
        .read_write => {
            entry.present.write(true);
            entry.writeable.write(true);
        },
    }

    if (x64.info.cpu_id.execute_disable) {
        @branchHint(.likely); // modern CPUs support NX
        entry.no_execute.write(map_type.protection != .execute);
    }

    switch (map_type.environment_type) {
        .user => {
            entry.user_accessible.write(true);
            entry.global.write(false);
        },
        .kernel => {
            entry.user_accessible.write(false);
            entry.global.write(true);
        },
    }

    switch (map_type.cache) {
        .write_back => {
            entry.write_through.write(false);
            entry.no_cache.write(false);

            switch (page_type) {
                .small => entry.pat.write(false),
                .medium, .large => entry.pat_huge.write(false),
            }
        },
        .write_combining => {
            entry.no_cache.write(true);

            // PAT entry 6 is the one set to write combining
            // to select entry 6 `pat[_huge]` and `no_cache` (pcd) must be set to `true`

            switch (page_type) {
                .small => entry.pat.write(true),
                .medium, .large => entry.pat_huge.write(true),
            }
        },
        .uncached => {
            entry.no_cache.write(true);

            switch (page_type) {
                .small => entry.pat.write(false),
                .medium, .large => entry.pat_huge.write(false),
            }
        },
    }
}

/// Ensures that the next table is present in the page table.
///
/// Returns the next table and whether it had to be created by this function or not.
fn ensureNextTable(
    current_task: *Task,
    raw_entry: *PageTable.Entry.Raw,
    physical_frame_allocator: cascade.mem.phys.FrameAllocator,
) !struct { *PageTable, bool } {
    var created_table = false;

    const next_level_physical_address = blk: {
        var entry = raw_entry.load();

        if (entry.present.read()) {
            if (entry.huge.read()) return error.MappingNotValid;

            break :blk entry.getAddress4kib();
        }
        if (core.is_debug) std.debug.assert(entry.isZero());
        created_table = true;

        const physical_frame = try physical_frame_allocator.allocate(current_task);
        errdefer comptime unreachable;

        const physical_address = physical_frame.baseAddress();
        cascade.mem.directMapFromPhysical(physical_address).toPtr(*PageTable).zero();

        entry.setAddress4kib(physical_address);
        entry.present.write(true);

        // always set intermediate levels to writeable and user accessible, leaving the leaf node to determine the
        // actual permissions
        entry.writeable.write(true);
        entry.user_accessible.write(true);

        raw_entry.store(entry);

        break :blk physical_address;
    };

    return .{
        cascade.mem
            .directMapFromPhysical(next_level_physical_address)
            .toPtr(*PageTable),
        created_table,
    };
}

const PageType = enum { small, medium, large };

fn setEntry(
    page_table: *PageTable,
    index: usize,
    physical_address: core.PhysicalAddress,
    map_type: MapType,
    page_type: PageType,
) error{AlreadyMapped}!void {
    var entry = page_table.entries[index].load();

    if (entry.present.read()) return error.AlreadyMapped;

    entry.zero();

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

    applyMapType(map_type, page_type, &entry);

    page_table.entries[index].store(entry);
}

pub const init = struct {
    /// This function fills in the top level of the page table for the given range.
    ///
    /// The range is expected to have both size and alignment of `sizeOfTopLevelEntry()`.
    ///
    /// This function:
    ///  - does not flush the TLB
    ///  - does not rollback on error
    pub fn fillTopLevel(
        current_task: *Task,
        page_table: *PageTable,
        range: core.VirtualRange,
        physical_frame_allocator: cascade.mem.phys.FrameAllocator,
    ) !void {
        const size_of_top_level_entry = arch.paging.init.sizeOfTopLevelEntry();
        if (core.is_debug) {
            std.debug.assert(range.size.equal(size_of_top_level_entry));
            std.debug.assert(range.address.isAligned(size_of_top_level_entry));
        }

        const raw_entry = &page_table.entries[PageTable.p4Index(range.address)];

        const entry = raw_entry.load();
        if (entry.present.read()) return error.AlreadyMapped;

        _ = try ensureNextTable(current_task, raw_entry, physical_frame_allocator);
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
        current_task: *Task,
        level4_table: *PageTable,
        virtual_range: core.VirtualRange,
        physical_range: core.PhysicalRange,
        map_type: MapType,
        physical_frame_allocator: cascade.mem.phys.FrameAllocator,
    ) !void {
        if (core.is_debug) {
            std.debug.assert(virtual_range.address.isAligned(PageTable.small_page_size));
            std.debug.assert(virtual_range.size.isAligned(PageTable.small_page_size));
            std.debug.assert(physical_range.address.isAligned(PageTable.small_page_size));
            std.debug.assert(physical_range.size.isAligned(PageTable.small_page_size));
            std.debug.assert(virtual_range.size.equal(physical_range.size));
        }

        init_log.verbose(
            current_task,
            "mapToPhysicalRangeAllPageSizes - virtual_range: {f} - physical_range: {f} - map_type: {f}",
            .{ virtual_range, physical_range, map_type },
        );

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
                current_task,
                &level4_table.entries[level4_index],
                physical_frame_allocator,
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
                    current_task,
                    &level3_table.entries[level3_index],
                    physical_frame_allocator,
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
                        current_task,
                        &level2_table.entries[level2_index],
                        physical_frame_allocator,
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

        init_log.verbose(
            current_task,
            "satified using {} large pages, {} medium pages, {} small pages",
            .{ large_pages_mapped, medium_pages_mapped, small_pages_mapped },
        );
    }

    const init_log = cascade.debug.log.scoped(.paging_init);
};
