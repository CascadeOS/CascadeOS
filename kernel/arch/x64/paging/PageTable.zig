// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const bitjuggle = @import("bitjuggle");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const MapType = cascade.mem.MapType;

const x64 = @import("../x64.zig");

/// A page table for x64.
pub const PageTable = extern struct {
    entries: [number_of_entries]Entry.Raw align(small_page_size.value),

    pub const number_of_entries = 512;

    pub const small_page_size: core.Size = .from(4, .kib);
    pub const small_page_size_alignment = small_page_size.toAlignment();

    pub const medium_page_size: core.Size = .from(2, .mib);
    const medium_page_size_alignment = medium_page_size.toAlignment();

    pub const large_page_size: core.Size = .from(1, .gib);
    const large_page_size_alignment = large_page_size.toAlignment();

    pub const level_1_address_space_size = small_page_size;
    pub const level_2_address_space_size = medium_page_size;
    pub const level_3_address_space_size = large_page_size;

    pub const level_4_address_space_size = core.Size.from(512, .gib);
    const level_4_address_space_size_alignment = level_4_address_space_size.toAlignment();

    pub const half_address_space_size: core.Size = .from(128, .tib);

    pub fn sizeOfTopLevelEntry() core.Size {
        // TODO: Only correct for 4 level paging
        return level_4_address_space_size;
    }

    fn zero(page_table: *PageTable) void {
        @memset(std.mem.asBytes(page_table), 0);
    }

    fn isEmpty(page_table: *const PageTable) bool {
        for (page_table.entries) |entry| {
            if (!entry.isZero()) return false;
        }
        return true;
    }

    /// Create a page table in the given physical page.
    ///
    /// **REQUIREMENTS**:
    /// - The provided physical page must be accessible in the direct map.
    pub fn create(physical_page: cascade.mem.PhysicalPage.Index) *PageTable {
        const page_table = physical_page.baseAddress().toDirectMap().toPtr(*PageTable);
        page_table.zero();
        return page_table;
    }

    /// Maps a 4 KiB page.
    pub fn map4KiB(
        level4_table: *PageTable,
        virtual_address: cascade.VirtualAddress,
        phys_page: cascade.mem.PhysicalPage.Index,
        map_type: MapType,
        physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
    ) cascade.mem.MapError!void {
        if (core.is_debug) std.debug.assert(virtual_address.pageAligned());

        var deallocate_page_list: cascade.mem.PhysicalPage.List = .{};
        errdefer physical_page_allocator.deallocate(deallocate_page_list);

        const level4_index = p4Index(virtual_address);

        const level3_table, const created_level3_table = try ensureNextTable(
            &level4_table.entries[level4_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level3_table) {
                var level4_entry = level4_table.entries[level4_index].load();
                const address = level4_entry.getAddress4kib();
                level4_table.entries[level4_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        const level3_index = p3Index(virtual_address);

        const level2_table, const created_level2_table = try ensureNextTable(
            &level3_table.entries[level3_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level2_table) {
                var level3_entry = level3_table.entries[level3_index].load();
                const address = level3_entry.getAddress4kib();
                level3_table.entries[level3_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        const level2_index = p2Index(virtual_address);

        const level1_table, const created_level1_table = try ensureNextTable(
            &level2_table.entries[level2_index],
            physical_page_allocator,
        );
        errdefer {
            if (created_level1_table) {
                var level2_entry = level2_table.entries[level2_index].load();
                const address = level2_entry.getAddress4kib();
                level2_table.entries[level2_index].zero();
                deallocate_page_list.prepend(.fromAddress(address));
            }
        }

        try level1_table.setEntry(
            p1Index(virtual_address),
            phys_page.baseAddress(),
            map_type,
            .small,
        );
    }

    /// Unmaps the given virtual range.
    ///
    /// Caller must ensure:
    ///  - the virtual range address and size are aligned to the standard page size
    ///
    /// This function:
    ///  - only supports the standard page size for the architecture
    ///  - does not flush the TLB
    pub fn unmap(
        level4_table: *PageTable,
        virtual_range: cascade.VirtualRange,
        backing_page_decision: core.CleanupDecision,
        top_level_decision: core.CleanupDecision,
        flush_batch: *cascade.mem.VirtualRangeBatch,
        deallocate_page_list: *cascade.mem.PhysicalPage.List,
    ) void {
        if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();

        const last_virtual_address_p4_index = p4Index(last_virtual_address);
        const last_virtual_address_p3_index = p3Index(last_virtual_address);
        const last_virtual_address_p2_index = p2Index(last_virtual_address);
        const last_virtual_address_p1_index = p1Index(last_virtual_address);

        var level4_index = p4Index(current_virtual_address);

        var opt_in_progress_range: ?cascade.VirtualRange = null;

        while (level4_index <= last_virtual_address_p4_index) : (level4_index += 1) {
            const level4_entry = level4_table.entries[level4_index].load();

            const level3_table = level4_entry.getNextLevel() catch |err| switch (err) {
                error.NotPresent => {
                    if (opt_in_progress_range) |in_progress_range| {
                        flush_batch.appendMergeIfFull(in_progress_range);
                        opt_in_progress_range = null;
                    }

                    current_virtual_address.moveForwardInPlace(level_4_address_space_size);
                    current_virtual_address.alignBackwardInPlace(level_4_address_space_size_alignment);
                    continue;
                },
                error.HugePage => @panic("page table entry is huge"),
            };

            defer if (top_level_decision == .free and level3_table.isEmpty()) {
                level4_table.entries[level4_index].zero();
                deallocate_page_list.prepend(.fromAddress(level4_entry.getAddress4kib()));
            };

            var level3_index = p3Index(current_virtual_address);
            const last_level3_index = if (last_virtual_address_p4_index == level4_index)
                last_virtual_address_p3_index
            else
                number_of_entries - 1;

            while (level3_index <= last_level3_index) : (level3_index += 1) {
                const level3_entry = level3_table.entries[level3_index].load();

                const level2_table = level3_entry.getNextLevel() catch |err| switch (err) {
                    error.NotPresent => {
                        if (opt_in_progress_range) |in_progress_range| {
                            flush_batch.appendMergeIfFull(in_progress_range);
                            opt_in_progress_range = null;
                        }

                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_virtual_address.alignBackwardInPlace(large_page_size_alignment);
                        continue;
                    },
                    error.HugePage => @panic("page table entry is huge"),
                };

                defer if (level2_table.isEmpty()) {
                    level3_table.entries[level3_index].zero();
                    deallocate_page_list.prepend(.fromAddress(level3_entry.getAddress4kib()));
                };

                var level2_index = p2Index(current_virtual_address);
                const last_level2_index = if (last_virtual_address_p3_index == level3_index)
                    last_virtual_address_p2_index
                else
                    number_of_entries - 1;

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    const level2_entry = level2_table.entries[level2_index].load();

                    const level1_table = level2_entry.getNextLevel() catch |err| switch (err) {
                        error.NotPresent => {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }

                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_virtual_address.alignBackwardInPlace(medium_page_size_alignment);
                            continue;
                        },
                        error.HugePage => @panic("page table entry is huge"),
                    };

                    defer if (level1_table.isEmpty()) {
                        level2_table.entries[level2_index].zero();
                        deallocate_page_list.prepend(.fromAddress(level2_entry.getAddress4kib()));
                    };

                    var level1_index = p1Index(current_virtual_address);
                    const last_level1_index = if (last_virtual_address_p2_index == level2_index)
                        last_virtual_address_p1_index
                    else
                        number_of_entries - 1;

                    while (level1_index <= last_level1_index) : (level1_index += 1) {
                        defer current_virtual_address.moveForwardPageInPlace();

                        const level1_entry = level1_table.entries[level1_index].load();

                        if (!level1_entry.present.read()) {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }

                            continue;
                        }

                        level1_table.entries[level1_index].zero();

                        if (backing_page_decision == .free) {
                            deallocate_page_list.prepend(.fromAddress(level1_entry.getAddress4kib()));
                        }

                        if (opt_in_progress_range) |*in_progress_range| {
                            in_progress_range.size.addInPlace(small_page_size);
                        } else {
                            opt_in_progress_range = .from(
                                current_virtual_address,
                                small_page_size,
                            );
                        }
                    }
                }
            }
        }

        if (opt_in_progress_range) |in_progress_range| {
            flush_batch.appendMergeIfFull(in_progress_range);
        }
    }

    pub fn changeProtection(
        level4_table: *PageTable,
        virtual_range: cascade.VirtualRange,
        previous_map_type: MapType,
        new_map_type: MapType,
        flush_batch: *cascade.mem.VirtualRangeBatch,
    ) void {
        if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

        const need_to_flush = needToFlush(previous_map_type, new_map_type);

        var current_virtual_address = virtual_range.address;
        const last_virtual_address = virtual_range.last();

        const last_virtual_address_p4_index = p4Index(last_virtual_address);
        const last_virtual_address_p3_index = p3Index(last_virtual_address);
        const last_virtual_address_p2_index = p2Index(last_virtual_address);
        const last_virtual_address_p1_index = p1Index(last_virtual_address);

        var level4_index = p4Index(current_virtual_address);

        // if `need_to_flush` is false then this will never be non-null
        var opt_in_progress_range: ?cascade.VirtualRange = null;

        while (level4_index <= last_virtual_address_p4_index) : (level4_index += 1) {
            const level4_entry = level4_table.entries[level4_index].load();

            const level3_table = level4_entry.getNextLevel() catch |err| switch (err) {
                error.NotPresent => {
                    if (opt_in_progress_range) |in_progress_range| {
                        flush_batch.appendMergeIfFull(in_progress_range);
                        opt_in_progress_range = null;
                    }

                    current_virtual_address.moveForwardInPlace(level_4_address_space_size);
                    current_virtual_address.alignBackwardInPlace(level_4_address_space_size_alignment);
                    continue;
                },
                error.HugePage => @panic("page table entry is huge"),
            };

            var level3_index = p3Index(current_virtual_address);
            const last_level3_index = if (last_virtual_address_p4_index == level4_index)
                last_virtual_address_p3_index
            else
                number_of_entries - 1;

            while (level3_index <= last_level3_index) : (level3_index += 1) {
                const level3_entry = level3_table.entries[level3_index].load();

                const level2_table = level3_entry.getNextLevel() catch |err| switch (err) {
                    error.NotPresent => {
                        if (opt_in_progress_range) |in_progress_range| {
                            flush_batch.appendMergeIfFull(in_progress_range);
                            opt_in_progress_range = null;
                        }

                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_virtual_address.alignBackwardInPlace(large_page_size_alignment);
                        continue;
                    },
                    error.HugePage => @panic("page table entry is huge"),
                };

                var level2_index = p2Index(current_virtual_address);
                const last_level2_index = if (last_virtual_address_p3_index == level3_index)
                    last_virtual_address_p2_index
                else
                    number_of_entries - 1;

                while (level2_index <= last_level2_index) : (level2_index += 1) {
                    const level2_entry = level2_table.entries[level2_index].load();

                    const level1_table = level2_entry.getNextLevel() catch |err| switch (err) {
                        error.NotPresent => {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }

                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_virtual_address.alignBackwardInPlace(medium_page_size_alignment);
                            continue;
                        },
                        error.HugePage => @panic("page table entry is huge"),
                    };

                    var level1_index = p1Index(current_virtual_address);
                    const last_level1_index = if (last_virtual_address_p2_index == level2_index)
                        last_virtual_address_p1_index
                    else
                        number_of_entries - 1;

                    while (level1_index <= last_level1_index) : (level1_index += 1) {
                        defer current_virtual_address.moveForwardPageInPlace();

                        var level1_entry = level1_table.entries[level1_index].load();

                        if (!level1_entry.present.read()) {
                            if (opt_in_progress_range) |in_progress_range| {
                                flush_batch.appendMergeIfFull(in_progress_range);
                                opt_in_progress_range = null;
                            }

                            continue;
                        }

                        level1_entry.applyMapType(new_map_type, .small);
                        level1_table.entries[level1_index].store(level1_entry);

                        if (opt_in_progress_range) |*in_progress_range| {
                            in_progress_range.size.addInPlace(small_page_size);
                        } else if (need_to_flush) {
                            opt_in_progress_range = .from(
                                current_virtual_address,
                                small_page_size,
                            );
                        }
                    }
                }
            }
        }

        if (opt_in_progress_range) |in_progress_range| {
            flush_batch.appendMergeIfFull(in_progress_range);
        }
    }

    /// Returns true if the TLB needs to be flushed when changing from `previous_map_type` to `new_map_type`.
    fn needToFlush(previous_map_type: MapType, new_map_type: MapType) bool {
        if (previous_map_type.type != new_map_type.type) {
            @branchHint(.unlikely); // only occurs when mixing kernel and user memory
            return true;
        }
        if (previous_map_type.cache != new_map_type.cache) {
            @branchHint(.unlikely); // only occurs when mixing normal and device memory
            return true;
        }

        return switch (previous_map_type.protection) {
            .none => false,
            else => |previous_protection| @intFromEnum(new_map_type.protection) < @intFromEnum(previous_protection),
        };
    }

    fn setEntry(
        page_table: *PageTable,
        index: usize,
        physical_address: cascade.PhysicalAddress,
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

        entry.applyMapType(map_type, page_type);

        page_table.entries[index].store(entry);
    }

    const Entry = extern union {
        /// Specifies whether the mapped physical page or page table is loaded in memory.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        present: bitjuggle.Boolean(u64, 0),

        /// Controls whether writes to the mapped physical pages are allowed.
        ///
        /// If this bit is unset in a level 1 page table entry, the mapped physical page is read-only.
        ///
        /// If this bit is unset in a higher level page table entry the complete range of mapped pages is read-only.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        writeable: bitjuggle.Boolean(u64, 1),

        /// Controls whether accesses from userspace (i.e. ring 3) are permitted.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        user_accessible: bitjuggle.Boolean(u64, 2),

        /// If this bit is set, a "write-through" policy is used for the cache, else a "write-back" policy is used.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        write_through: bitjuggle.Boolean(u64, 3),

        /// Disables caching for the entry.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        no_cache: bitjuggle.Boolean(u64, 4),

        /// Set by the CPU when the mapped physical page or page table is accessed.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        accessed: bitjuggle.Boolean(u64, 5),

        /// Set by the CPU on a write to the mapped physical page.
        ///
        /// Valid for:
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        dirty: bitjuggle.Boolean(u64, 6),

        /// Specifies that the entry maps a huge physical page instead of a page table.
        ///
        /// Valid for:
        ///  - 1GiB
        ///  - 2MiB
        huge: bitjuggle.Boolean(u64, 7),

        /// Determines the memory types used
        ///
        /// Valid for:
        ///  - 4KiB
        pat: bitjuggle.Boolean(u64, 7),

        /// Indicates that the mapping is present in all address spaces, so it isn't flushed from the TLB on an address space switch.
        ///
        /// Valid for:
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        global: bitjuggle.Boolean(u64, 8),

        /// Determines the memory types used
        ///
        /// Valid for:
        ///  - 1GiB
        ///  - 2MiB
        pat_huge: bitjuggle.Boolean(u64, 12),

        /// The page aligned physical address
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 4KiB
        _address_4kib_aligned: bitjuggle.Bitfield(u64, level_1_shift, length_of_4kib_aligned_address),

        /// The 2MiB aligned physical address
        ///
        /// Valid for:
        ///  - 2MiB
        _address_2mib_aligned: bitjuggle.Bitfield(u64, level_2_shift, length_of_2mib_aligned_address),

        /// The 1GiB aligned physical address
        ///
        /// Valid for:
        ///  - 1GiB
        _address_1gib_aligned: bitjuggle.Bitfield(u64, level_3_shift, length_of_1gib_aligned_address),

        /// Forbid code execution from the mapped physical pages.
        ///
        /// Valid for:
        ///  - PML5
        ///  - PML4
        ///  - PDPTE
        ///  - PDE
        ///  - 1GiB
        ///  - 2MiB
        ///  - 4KiB
        no_execute: bitjuggle.Boolean(u64, 63),

        _raw: Raw,

        const Raw = extern struct {
            value: u64,

            fn zero(raw: *Raw) void {
                raw.value = 0;
            }

            fn isZero(raw: Raw) bool {
                return raw.value == 0;
            }

            fn load(raw: Raw) Entry {
                return .{ ._raw = raw };
            }

            fn store(raw: *Raw, entry: Entry) void {
                raw.* = entry._raw;
            }

            comptime {
                core.testing.expectSize(Raw, .of(u64));
            }
        };

        fn zero(entry: *Entry) void {
            entry._raw.zero();
        }

        fn isZero(entry: Entry) bool {
            return entry._raw.isZero();
        }

        fn getAddress4kib(entry: Entry) cascade.PhysicalAddress {
            return .{ .value = entry._address_4kib_aligned.readNoShiftFullSize() };
        }

        fn setAddress4kib(entry: *Entry, address: cascade.PhysicalAddress) void {
            if (core.is_debug) std.debug.assert(address.pageAligned());
            entry._address_4kib_aligned.writeNoShiftFullSize(address.value);
        }

        fn getAddress2mib(entry: Entry) cascade.PhysicalAddress {
            return .{ .value = entry._address_2mib_aligned.readNoShiftFullSize() };
        }

        fn setAddress2mib(entry: *Entry, address: cascade.PhysicalAddress) void {
            if (core.is_debug) std.debug.assert(address.aligned(medium_page_size_alignment));
            entry._address_2mib_aligned.writeNoShiftFullSize(address.value);
        }

        fn getAddress1gib(entry: Entry) cascade.PhysicalAddress {
            return .{ .value = entry._address_1gib_aligned.readNoShiftFullSize() };
        }

        fn setAddress1gib(entry: *Entry, address: cascade.PhysicalAddress) void {
            if (core.is_debug) std.debug.assert(address.aligned(large_page_size_alignment));
            entry._address_1gib_aligned.writeNoShiftFullSize(address.value);
        }

        /// Gets the next page table level.
        ///
        /// Returns an error if:
        /// - The entry is not present.
        /// - The entry points to a huge page.
        ///
        /// Otherwise returns a pointer to the next page table level.
        fn getNextLevel(
            entry: Entry,
            // comptime virtualFromPhysical: fn (cascade.PhysicalAddress) cascade.KernelVirtualAddress,
        ) error{ NotPresent, HugePage }!*PageTable {
            if (!entry.present.read()) return error.NotPresent;
            if (entry.huge.read()) return error.HugePage;
            return entry.getAddress4kib().toDirectMap().toPtr(*PageTable);
        }

        fn applyMapType(
            entry: *PageTable.Entry,
            map_type: MapType,
            page_type: PageType,
        ) void {
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

            switch (map_type.type) {
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

        fn printSmallEntryFlags(entry: Entry, writer: *std.Io.Writer) !void {
            std.debug.assert(!entry.huge.read());

            if (entry.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (entry.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (entry.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (entry.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (entry.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (entry.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (entry.dirty.read()) {
                try writer.writeAll("- Dirty ");
            }

            if (entry.pat.read()) {
                try writer.writeAll("- PAT ");
            }

            if (entry.global.read()) {
                try writer.writeAll("- Global ");
            }

            if (entry.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }

        fn printHugeEntryFlags(entry: Entry, writer: *std.Io.Writer) !void {
            std.debug.assert(entry.huge.read());

            if (entry.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (entry.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (entry.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (entry.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (entry.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (entry.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (entry.dirty.read()) {
                try writer.writeAll("- Dirty ");
            }

            if (entry.pat_huge.read()) {
                try writer.writeAll("- PAT ");
            }

            if (entry.global.read()) {
                try writer.writeAll("- Global ");
            }

            if (entry.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }

        fn printDirectoryEntryFlags(entry: Entry, writer: *std.Io.Writer) !void {
            if (entry.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (entry.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (entry.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (entry.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (entry.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (entry.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (entry.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }
    };

    /// Print the page table.
    ///
    /// Assumes the page table is not modified during printing.
    pub fn printPageTable(
        entry: *const PageTable,
        writer: *std.Io.Writer,
        comptime print_detailed_level1: bool,
    ) !void {
        for (entry.entries, 0..) |raw_level4_entry, level4_index| {
            const level4_entry: Entry = raw_level4_entry.load();

            if (!level4_entry.present.read()) continue;

            std.debug.assert(!level4_entry.huge.read());

            // The level 4 part is sign extended to ensure the address is cannonical.
            const level4_part = signExtendAddress(level4_index << level_4_shift);

            try writer.print("level 4 [{}] {f}    Flags: ", .{ level4_index, cascade.VirtualAddress.from(level4_part) });
            try level4_entry.printDirectoryEntryFlags(writer);
            try writer.writeByte('\n');

            const level3_table = try level4_entry.getNextLevel();
            for (level3_table.entries, 0..) |raw_level3_entry, level3_index| {
                const level3_entry: Entry = raw_level3_entry.load();

                if (!level3_entry.present.read()) continue;

                const level3_part = level3_index << level_3_shift;

                if (level3_entry.huge.read()) {
                    const virtual = cascade.VirtualAddress.from(level4_part | level3_part);
                    const physical = level3_entry.getAddress1gib();
                    try writer.print("  [{}] 1GIB {f} -> {f}    Flags: ", .{ level3_index, virtual, physical });
                    try level3_entry.printHugeEntryFlags(writer);
                    try writer.writeByte('\n');
                    continue;
                }

                try writer.print("  level 3 [{}] {f}    Flags: ", .{ level3_index, cascade.VirtualAddress.from(level4_part | level3_part) });
                try level3_entry.printDirectoryEntryFlags(writer);
                try writer.writeByte('\n');

                const level2_table = try level3_entry.getNextLevel();
                for (level2_table.entries, 0..) |raw_level2_entry, level2_index| {
                    const level2_entry: Entry = raw_level2_entry.load();

                    if (!level2_entry.present.read()) continue;

                    const level2_part = level2_index << level_2_shift;

                    if (level2_entry.huge.read()) {
                        const virtual = cascade.VirtualAddress.from(level4_part | level3_part | level2_part);
                        const physical = level2_entry.getAddress2mib();
                        try writer.print("    [{}] 2MIB {f} -> {f}    Flags: ", .{ level2_index, virtual, physical });
                        try level2_entry.printHugeEntryFlags(writer);
                        try writer.writeByte('\n');
                        continue;
                    }

                    try writer.print("    level 2 [{}] {f}    Flags: ", .{ level2_index, cascade.VirtualAddress.from(level4_part | level3_part | level2_part) });
                    try level2_entry.printDirectoryEntryFlags(writer);
                    try writer.writeByte('\n');

                    // use only when `print_detailed_level1` is false
                    var level1_present_entries: usize = 0;

                    const level1_table = try level2_entry.getNextLevel();
                    for (level1_table.entries, 0..) |raw_level1_entry, level1_index| {
                        const level1_entry: Entry = raw_level1_entry.load();

                        if (!level1_entry.present.read()) continue;

                        if (!print_detailed_level1) {
                            level1_present_entries += 1;
                            continue;
                        }

                        std.debug.assert(!level1_entry.huge.read());

                        const level1_part = level1_index << level_1_shift;

                        const virtual = cascade.VirtualAddress.from(level4_part | level3_part | level2_part | level1_part);
                        const physical = level1_entry.getAddress4kib();
                        try writer.print("      [{}] 4KIB {f} -> {f}    Flags: ", .{ level1_index, virtual, physical });
                        try level1_entry.printSmallEntryFlags(writer);
                        try writer.writeByte('\n');
                    }

                    if (!print_detailed_level1) {
                        try writer.print("      {} 4KIB mappings\n", .{level1_present_entries});
                    }
                }
            }
        }
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
            page_table: *PageTable,
            range: cascade.VirtualRange,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) !void {
            const size_of_top_level_entry = arch.paging.init.sizeOfTopLevelEntry();
            if (core.is_debug) {
                std.debug.assert(range.size.equal(size_of_top_level_entry));
                std.debug.assert(range.address.aligned(size_of_top_level_entry.toAlignment()));
            }

            const raw_entry = &page_table.entries[p4Index(range.address)];

            const entry = raw_entry.load();
            if (entry.present.read()) return error.AlreadyMapped;

            _ = try ensureNextTable(raw_entry, physical_page_allocator);
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
            virtual_range: cascade.VirtualRange,
            physical_range: cascade.PhysicalRange,
            map_type: MapType,
            physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
        ) !void {
            if (core.is_debug) {
                std.debug.assert(virtual_range.pageAligned());
                std.debug.assert(physical_range.pageAligned());
                std.debug.assert(virtual_range.size.equal(physical_range.size));
            }

            init_log.verbose(
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

            const last_virtual_address_p4_index = p4Index(last_virtual_address);
            const last_virtual_address_p3_index = p3Index(last_virtual_address);
            const last_virtual_address_p2_index = p2Index(last_virtual_address);

            var level4_index = p4Index(current_virtual_address);

            while (level4_index <= last_virtual_address_p4_index) : (level4_index += 1) {
                const level3_table, _ = try ensureNextTable(
                    &level4_table.entries[level4_index],
                    physical_page_allocator,
                );

                var level3_index = p3Index(current_virtual_address);
                const last_level3_index = if (last_virtual_address_p4_index == level4_index)
                    p3Index(last_virtual_address)
                else
                    number_of_entries - 1;

                while (level3_index <= last_level3_index) : (level3_index += 1) {
                    if (supports_1gib and
                        size_remaining.greaterThanOrEqual(large_page_size) and
                        current_virtual_address.aligned(large_page_size_alignment) and
                        current_physical_address.aligned(large_page_size_alignment))
                    {
                        // large 1 GiB page
                        try level3_table.setEntry(
                            level3_index,
                            current_physical_address,
                            map_type,
                            .large,
                        );

                        large_pages_mapped += 1;

                        current_virtual_address.moveForwardInPlace(large_page_size);
                        current_physical_address.moveForwardInPlace(large_page_size);
                        size_remaining.subtractInPlace(large_page_size);
                        continue;
                    }

                    const level2_table, _ = try ensureNextTable(
                        &level3_table.entries[level3_index],
                        physical_page_allocator,
                    );

                    var level2_index = p2Index(current_virtual_address);
                    const last_level2_index = if (last_virtual_address_p3_index == level3_index)
                        p2Index(last_virtual_address)
                    else
                        number_of_entries - 1;

                    while (level2_index <= last_level2_index) : (level2_index += 1) {
                        if (size_remaining.greaterThanOrEqual(medium_page_size) and
                            current_virtual_address.aligned(medium_page_size_alignment) and
                            current_physical_address.aligned(medium_page_size_alignment))
                        {
                            // large 2 MiB page
                            try level2_table.setEntry(
                                level2_index,
                                current_physical_address,
                                map_type,
                                .medium,
                            );

                            medium_pages_mapped += 1;

                            current_virtual_address.moveForwardInPlace(medium_page_size);
                            current_physical_address.moveForwardInPlace(medium_page_size);
                            size_remaining.subtractInPlace(medium_page_size);
                            continue;
                        }

                        const level1_table, _ = try ensureNextTable(
                            &level2_table.entries[level2_index],
                            physical_page_allocator,
                        );

                        var level1_index = p1Index(current_virtual_address);
                        const last_level1_index = if (last_virtual_address_p2_index == level2_index)
                            p1Index(last_virtual_address)
                        else
                            number_of_entries - 1;

                        while (level1_index <= last_level1_index) : (level1_index += 1) {
                            try level1_table.setEntry(
                                level1_index,
                                current_physical_address,
                                map_type,
                                .small,
                            );

                            small_pages_mapped += 1;

                            current_virtual_address.moveForwardPageInPlace();
                            current_physical_address.moveForwardPageInPlace();
                            size_remaining.subtractInPlace(small_page_size);
                        }
                    }
                }
            }

            init_log.verbose(
                "satified using {} large pages, {} medium pages, {} small pages",
                .{ large_pages_mapped, medium_pages_mapped, small_pages_mapped },
            );
        }

        const init_log = cascade.debug.log.scoped(.paging_init);
    };

    comptime {
        core.testing.expectSize(PageTable, small_page_size);
    }
};

/// Ensures that the next table is present in the page table.
///
/// Returns the next table and whether it had to be created by this function or not.
fn ensureNextTable(
    raw_entry: *PageTable.Entry.Raw,
    physical_page_allocator: cascade.mem.PhysicalPage.Allocator,
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

        const physical_page = try physical_page_allocator.allocate();
        errdefer comptime unreachable;

        const physical_address = physical_page.baseAddress();
        physical_address.toDirectMap().toPtr(*PageTable).zero();

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
        next_level_physical_address.toDirectMap().toPtr(*PageTable),
        created_table,
    };
}

const PageType = enum { small, medium, large };

inline fn p1Index(address: cascade.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_1_shift));
}

inline fn p2Index(address: cascade.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_2_shift));
}

inline fn p3Index(address: cascade.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_3_shift));
}

inline fn p4Index(address: cascade.VirtualAddress) usize {
    return @as(u9, @truncate(address.value >> level_4_shift));
}

fn signExtendAddress(address: u64) u64 {
    return @bitCast(@as(i64, @bitCast(address << 16)) >> 16);
}

const level_1_shift = 12;
const level_2_shift = 21;
const level_3_shift = 30;
const level_4_shift = 39;

const maximum_physical_address_bit = 39;

const length_of_4kib_aligned_address = maximum_physical_address_bit - level_1_shift;
const length_of_2mib_aligned_address = maximum_physical_address_bit - level_2_shift;
const length_of_1gib_aligned_address = maximum_physical_address_bit - level_3_shift;
