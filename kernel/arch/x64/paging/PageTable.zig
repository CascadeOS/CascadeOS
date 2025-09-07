// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const bitjuggle = @import("bitjuggle");
const core = @import("core");

/// A page table for x64.
pub const PageTable = extern struct {
    entries: [number_of_entries]Entry.Raw align(small_page_size.value),

    pub const number_of_entries = 512;
    pub const small_page_size: core.Size = .from(4, .kib);
    pub const medium_page_size: core.Size = .from(2, .mib);
    pub const large_page_size: core.Size = .from(1, .gib);

    pub const level_1_address_space_size = small_page_size;
    pub const level_2_address_space_size = medium_page_size;
    pub const level_3_address_space_size = large_page_size;
    pub const level_4_address_space_size = core.Size.from(512, .gib);

    pub fn zero(page_table: *PageTable) void {
        @memset(std.mem.asBytes(page_table), 0);
    }

    pub fn isEmpty(page_table: *const PageTable) bool {
        for (page_table.entries) |entry| {
            if (!entry.isZero()) return false;
        }
        return true;
    }

    pub const Entry = extern union {
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

        pub const Raw = extern struct {
            value: u64,

            pub fn zero(raw: *Raw) void {
                raw.value = 0;
            }

            pub fn isZero(raw: Raw) bool {
                return raw.value == 0;
            }

            pub fn load(raw: Raw) Entry {
                return .{ ._raw = raw };
            }

            pub fn store(raw: *Raw, entry: Entry) void {
                raw.* = entry._raw;
            }

            comptime {
                core.testing.expectSize(Raw, @sizeOf(u64));
            }
        };

        pub fn zero(entry: *Entry) void {
            entry._raw.zero();
        }

        pub fn isZero(entry: Entry) bool {
            return entry._raw.isZero();
        }

        pub fn getAddress4kib(entry: Entry) core.PhysicalAddress {
            return .{ .value = entry._address_4kib_aligned.readNoShiftFullSize() };
        }

        pub fn setAddress4kib(entry: *Entry, address: core.PhysicalAddress) void {
            std.debug.assert(address.isAligned(small_page_size));
            entry._address_4kib_aligned.writeNoShiftFullSize(address.value);
        }

        pub fn getAddress2mib(entry: Entry) core.PhysicalAddress {
            return .{ .value = entry._address_2mib_aligned.readNoShiftFullSize() };
        }

        pub fn setAddress2mib(entry: *Entry, address: core.PhysicalAddress) void {
            std.debug.assert(address.isAligned(medium_page_size));
            entry._address_2mib_aligned.writeNoShiftFullSize(address.value);
        }

        pub fn getAddress1gib(entry: Entry) core.PhysicalAddress {
            return .{ .value = entry._address_1gib_aligned.readNoShiftFullSize() };
        }

        pub fn setAddress1gib(entry: *Entry, address: core.PhysicalAddress) void {
            std.debug.assert(address.isAligned(large_page_size));
            entry._address_1gib_aligned.writeNoShiftFullSize(address.value);
        }

        /// Gets the next page table level.
        ///
        /// Returns an error if:
        /// - The entry is not present.
        /// - The entry points to a huge page.
        ///
        /// Otherwise returns a pointer to the next page table level.
        pub fn getNextLevel(
            entry: Entry,
            comptime virtualFromPhysical: fn (core.PhysicalAddress) core.VirtualAddress,
        ) error{ NotPresent, HugePage }!*PageTable {
            if (!entry.present.read()) return error.NotPresent;
            if (entry.huge.read()) return error.HugePage;
            return virtualFromPhysical(entry.getAddress4kib()).toPtr(*PageTable);
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
        comptime virtualFromPhysical: fn (core.PhysicalAddress) core.VirtualAddress,
    ) !void {
        for (entry.entries, 0..) |raw_level4_entry, level4_index| {
            const level4_entry: Entry = .{ .raw = raw_level4_entry };

            if (!level4_entry.present.read()) continue;

            std.debug.assert(!level4_entry.huge.read());

            // The level 4 part is sign extended to ensure the address is cannonical.
            const level4_part = signExtendAddress(level4_index << level_4_shift);

            try writer.print("level 4 [{}] {}    Flags: ", .{ level4_index, core.VirtualAddress.fromInt(level4_part) });
            try level4_entry.printDirectoryEntryFlags(writer);
            try writer.writeByte('\n');

            const level3_table = try level4_entry.getNextLevel(virtualFromPhysical);
            for (level3_table.entries, 0..) |raw_level3_entry, level3_index| {
                const level3_entry: Entry = .{ .raw = raw_level3_entry };

                if (!level3_entry.present.read()) continue;

                const level3_part = level3_index << level_3_shift;

                if (level3_entry.huge.read()) {
                    const virtual = core.VirtualAddress.fromInt(level4_part | level3_part);
                    const physical = level3_entry.getAddress1gib();
                    try writer.print("  [{}] 1GIB {} -> {}    Flags: ", .{ level3_index, virtual, physical });
                    try level3_entry.printHugeEntryFlags(writer);
                    try writer.writeByte('\n');
                    continue;
                }

                try writer.print("  level 3 [{}] {}    Flags: ", .{ level3_index, core.VirtualAddress.fromInt(level4_part | level3_part) });
                try level3_entry.printDirectoryEntryFlags(writer);
                try writer.writeByte('\n');

                const level2_table = try level3_entry.getNextLevel(virtualFromPhysical);
                for (level2_table.entries, 0..) |raw_level2_entry, level2_index| {
                    const level2_entry: Entry = .{ .raw = raw_level2_entry };

                    if (!level2_entry.present.read()) continue;

                    const level2_part = level2_index << level_2_shift;

                    if (level2_entry.huge.read()) {
                        const virtual = core.VirtualAddress.fromInt(level4_part | level3_part | level2_part);
                        const physical = level2_entry.getAddress2mib();
                        try writer.print("    [{}] 2MIB {} -> {}    Flags: ", .{ level2_index, virtual, physical });
                        try level2_entry.printHugeEntryFlags(writer);
                        try writer.writeByte('\n');
                        continue;
                    }

                    try writer.print("    level 2 [{}] {}    Flags: ", .{ level2_index, core.VirtualAddress.fromInt(level4_part | level3_part | level2_part) });
                    try level2_entry.printDirectoryEntryFlags(writer);
                    try writer.writeByte('\n');

                    // use only when `print_detailed_level1` is false
                    var level1_present_entries: usize = 0;

                    const level1_table = try level2_entry.getNextLevel(virtualFromPhysical);
                    for (level1_table.entries, 0..) |raw_level1_entry, level1_index| {
                        const level1_entry: Entry = .{ .raw = raw_level1_entry };

                        if (!level1_entry.present.read()) continue;

                        if (!print_detailed_level1) {
                            level1_present_entries += 1;
                            continue;
                        }

                        std.debug.assert(!level1_entry.huge.read());

                        const level1_part = level1_index << level_1_shift;

                        const virtual = core.VirtualAddress.fromInt(level4_part | level3_part | level2_part | level1_part);
                        const physical = level1_entry.getAddress4kib();
                        try writer.print("      [{}] 4KIB {} -> {}    Flags: ", .{ level1_index, virtual, physical });
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

    pub const Level = enum {
        one,
        two,
        three,
        four,
    };

    pub inline fn p1Index(address: core.VirtualAddress) usize {
        return @as(u9, @truncate(address.value >> level_1_shift));
    }

    pub inline fn p2Index(address: core.VirtualAddress) usize {
        return @as(u9, @truncate(address.value >> level_2_shift));
    }

    pub inline fn p3Index(address: core.VirtualAddress) usize {
        return @as(u9, @truncate(address.value >> level_3_shift));
    }

    pub inline fn p4Index(address: core.VirtualAddress) usize {
        return @as(u9, @truncate(address.value >> level_4_shift));
    }

    comptime {
        core.testing.expectSize(PageTable, small_page_size.value);
    }
};

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

const type_of_4kib: type = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_1_shift,
);
const type_of_2mib: type = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_2_shift,
);
const type_of_1gib: type = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_3_shift,
);
