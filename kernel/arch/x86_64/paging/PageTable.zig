// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x86_64 = @import("../x86_64.zig");

const paging = @import("paging.zig");

const bitjuggle = @import("bitjuggle");
const Boolean = bitjuggle.Boolean;
const Bitfield = bitjuggle.Bitfield;

// Only supports 4-level paging

pub const PageTable = extern struct {
    entries: [number_of_entries]Entry align(paging.small_page_size.bytes),

    pub const number_of_entries = 512;

    pub fn zero(self: *PageTable) void {
        const bytes = std.mem.asBytes(self);
        @memset(bytes, 0);
    }

    pub fn getEntryLevel4(self: *PageTable, virtual_addr: kernel.VirtAddr) *Entry {
        return &self.entries[p4Index(virtual_addr)];
    }

    pub fn getEntryLevel3(self: *PageTable, virtual_addr: kernel.VirtAddr) *Entry {
        return &self.entries[p3Index(virtual_addr)];
    }

    pub fn getEntryLevel2(self: *PageTable, virtual_addr: kernel.VirtAddr) *Entry {
        return &self.entries[p2Index(virtual_addr)];
    }

    pub fn getEntryLevel1(self: *PageTable, virtual_addr: kernel.VirtAddr) *Entry {
        return &self.entries[p1Index(virtual_addr)];
    }

    pub fn p1Index(addr: kernel.VirtAddr) u9 {
        return @truncate(addr.value >> level_1_shift);
    }

    pub fn p2Index(addr: kernel.VirtAddr) u9 {
        return @truncate(addr.value >> level_2_shift);
    }

    pub fn p3Index(addr: kernel.VirtAddr) u9 {
        return @truncate(addr.value >> level_3_shift);
    }

    pub fn p4Index(addr: kernel.VirtAddr) u9 {
        return @truncate(addr.value >> level_4_shift);
    }

    pub fn indexToAddr(level_4_index: u9, level_3_index: u9, level_2_index: u9, level_1_index: u9) kernel.VirtAddr {
        return kernel.VirtAddr.fromInt(
            signExtendAddress(
                @as(u64, level_4_index) << level_4_shift |
                    @as(u64, level_3_index) << level_3_shift |
                    @as(u64, level_2_index) << level_2_shift |
                    @as(u64, level_1_index) << level_1_shift,
            ),
        );
    }

    pub fn printPageTable(
        self: *const PageTable,
        writer: anytype,
        comptime print_detailed_level1: bool,
    ) !void {
        for (self.entries, 0..) |level4_entry, level4_i| {
            if (!level4_entry.present.read()) continue;

            std.debug.assert(!level4_entry.huge.read());

            const sign_extended_level4_part = signExtendAddress(level4_i << level_4_shift);

            try writer.print("level 4 [{}] {}    Flags: ", .{ level4_i, kernel.VirtAddr.fromInt(sign_extended_level4_part) });
            try level4_entry.printDirectoryEntryFlags(writer);
            try writer.writeByte('\n');

            const level3 = try level4_entry.getNextLevel();
            for (level3.entries, 0..) |level3_entry, level3_i| {
                if (!level3_entry.present.read()) continue;

                const level3_part = level3_i << level_3_shift;

                if (level3_entry.huge.read()) {
                    const virtual = kernel.VirtAddr.fromInt(sign_extended_level4_part | level3_part);
                    const physical = level3_entry.getAddress1gib();
                    try writer.print("  [{}] 1GIB {} -> {}    Flags: ", .{ level3_i, virtual, physical });
                    try level3_entry.printHugeEntryFlags(writer);
                    try writer.writeByte('\n');
                    continue;
                }

                try writer.print("  level 3 [{}] {}    Flags: ", .{ level3_i, kernel.VirtAddr.fromInt(sign_extended_level4_part | level3_part) });
                try level3_entry.printDirectoryEntryFlags(writer);
                try writer.writeByte('\n');

                const level2 = try level3_entry.getNextLevel();
                for (level2.entries, 0..) |level2_entry, level2_i| {
                    if (!level2_entry.present.read()) continue;

                    const level2_part = level2_i << level_2_shift;

                    if (level2_entry.huge.read()) {
                        const virtual = kernel.VirtAddr.fromInt(sign_extended_level4_part | level3_part | level2_part);
                        const physical = level2_entry.getAddress2mib();
                        try writer.print("    [{}] 2MIB {} -> {}    Flags: ", .{ virtual, physical, level2_i });
                        try level2_entry.printHugeEntryFlags(writer);
                        try writer.writeByte('\n');
                        continue;
                    }

                    try writer.print("    level 2 [{}] {}    Flags: ", .{ level2_i, kernel.VirtAddr.fromInt(sign_extended_level4_part | level3_part | level2_part) });
                    try level2_entry.printDirectoryEntryFlags(writer);
                    try writer.writeByte('\n');

                    // use only when `print_detailed_level1` is false
                    var number_of_level1_present_entries: usize = 0;

                    const level1 = try level2_entry.getNextLevel();
                    for (level1.entries, 0..) |level1_entry, level1_i| {
                        if (!level1_entry.present.read()) continue;

                        if (!print_detailed_level1) {
                            number_of_level1_present_entries += 1;
                            continue;
                        }

                        std.debug.assert(!level1_entry.huge.read());

                        const level1_part = level1_i << level_1_shift;

                        const virtual = kernel.VirtAddr.fromInt(sign_extended_level4_part | level3_part | level2_part | level1_part);
                        const physical = level1_entry.getAddress4kib();
                        try writer.print("      [{}] 4KIB {} -> {}    Flags: ", .{ virtual, physical, level1_i });
                        try level1_entry.printSmallEntryFlags(writer);
                        try writer.writeByte('\n');
                    }

                    if (!print_detailed_level1) {
                        try writer.print("      {} 4KIB mappings\n", .{number_of_level1_present_entries});
                    }
                }
            }
        }
    }

    pub const Entry = extern union {
        /// Specifies whether the mapped physical page or page table is loaded in memory.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        present: Boolean(u64, 0),

        /// Controls whether writes to the mapped physical pages are allowed.
        ///
        /// If this bit is unset in a level 1 page table entry, the mapped physical page is read-only.
        /// If this bit is unset in a higher level page table entry the complete range of mapped pages is read-only.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        writeable: Boolean(u64, 1),

        /// Controls whether accesses from userspace (i.e. ring 3) are permitted.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        user_accessible: Boolean(u64, 2),

        /// If this bit is set, a "write-through" policy is used for the cache, else a "write-back" policy is used.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        write_through: Boolean(u64, 3),

        /// Disables caching for the pointed entry is cacheable.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        no_cache: Boolean(u64, 4),

        /// Set by the CPU when the mapped physical page or page table is accessed.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        accessed: Boolean(u64, 5),

        /// Set by the CPU on a write to the mapped physical page.
        ///
        /// Valid for: 1GiB, 2MiB, 4KiB
        dirty: Boolean(u64, 6),

        /// Specifies that the entry maps a huge physical page instead of a page table.
        ///
        /// Valid for: 1GiB, 2MiB
        huge: Boolean(u64, 7),

        /// Determines the memory types used
        ///
        /// Valid for: 4KiB
        pat: Boolean(u64, 7),

        /// Indicates that the mapping is present in all address spaces, so it isn't flushed from the TLB on an address space switch.
        ///
        /// Valid for: 1GiB, 2MiB, 4KiB
        global: Boolean(u64, 8),

        /// Determines the memory types used
        ///
        /// Valid for: 1GiB, 2MiB
        pat_huge: Boolean(u64, 12),

        /// The page aligned physical address
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 4KiB
        address_4kib_aligned: Bitfield(u64, level_1_shift, length_of_4kib_aligned_address),

        /// The 2MiB aligned physical address
        ///
        /// Valid for: 2MiB
        address_2mib_aligned: Bitfield(u64, level_2_shift, length_of_2mib_aligned_address),

        /// The 1GiB aligned physical address
        ///
        /// Valid for: 1GiB
        address_1gib_aligned: Bitfield(u64, level_3_shift, length_of_1gib_aligned_address),

        /// Forbid code execution from the mapped physical pages.
        ///
        /// Valid for: PML5, PML4, PDPTE, PDE, 1GiB, 2MiB, 4KiB
        no_execute: Boolean(u64, 63),

        _backing: u64,

        const ADDRESS_MASK: u64 = 0x000f_ffff_ffff_f000;

        pub fn getAddress4kib(self: Entry) kernel.PhysAddr {
            return .{
                .value = @as(usize, self.address_4kib_aligned.read()) << level_1_shift,
            };
        }

        pub fn setAddress4kib(self: *Entry, addr: kernel.PhysAddr) void {
            std.debug.assert(addr.isAligned(paging.small_page_size));
            self.address_4kib_aligned.write(
                @as(type_of_4kib, @truncate(addr.value >> level_1_shift)),
            );
        }

        pub fn getAddress2mib(self: Entry) kernel.PhysAddr {
            return .{
                .value = @as(usize, self.address_2mib_aligned.read()) << level_2_shift,
            };
        }

        pub fn setAddress2mib(self: *Entry, addr: kernel.PhysAddr) void {
            std.debug.assert(addr.isAligned(paging.medium_page_size));
            self.address_2mib_aligned.write(@truncate(addr.value >> level_2_shift));
        }

        pub fn getAddress1gib(self: Entry) kernel.PhysAddr {
            return .{ .value = @as(usize, self.address_1gib_aligned.read()) << level_3_shift };
        }

        pub fn setAddress1gib(self: *Entry, addr: kernel.PhysAddr) void {
            std.debug.assert(addr.isAligned(paging.large_page_size));
            self.address_1gib_aligned.write(@truncate(addr.value >> level_3_shift));
        }

        pub fn getNextLevel(self: Entry) !*PageTable {
            if (!self.present.read()) return error.NotPresent;
            if (self.huge.read()) return error.HugePage;
            return self.getAddress4kib().toDirectMap().toPtr(*PageTable);
        }

        pub fn printSmallEntryFlags(self: Entry, writer: anytype) !void {
            std.debug.assert(!self.huge.read());

            if (self.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (self.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (self.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (self.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (self.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (self.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (self.dirty.read()) {
                try writer.writeAll("- Dirty ");
            }

            if (self.pat.read()) {
                try writer.writeAll("- PAT ");
            }

            if (self.global.read()) {
                try writer.writeAll("- Global ");
            }

            if (self.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }

        pub fn printHugeEntryFlags(self: Entry, writer: anytype) !void {
            std.debug.assert(self.huge.read());

            if (self.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (self.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (self.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (self.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (self.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (self.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (self.dirty.read()) {
                try writer.writeAll("- Dirty ");
            }

            if (self.pat_huge.read()) {
                try writer.writeAll("- PAT ");
            }

            if (self.global.read()) {
                try writer.writeAll("- Global ");
            }

            if (self.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }

        pub fn printDirectoryEntryFlags(self: Entry, writer: anytype) !void {
            if (self.present.read()) {
                try writer.writeAll("Present ");
            } else {
                try writer.writeAll("Not Present ");
            }

            if (self.writeable.read()) {
                try writer.writeAll("- Writeable ");
            }

            if (self.user_accessible.read()) {
                try writer.writeAll("- User ");
            }

            if (self.write_through.read()) {
                try writer.writeAll("- Write Through ");
            }

            if (self.no_cache.read()) {
                try writer.writeAll("- No Cache ");
            }

            if (self.accessed.read()) {
                try writer.writeAll("- Accessed ");
            }

            if (self.no_execute.read()) {
                try writer.writeAll("- No Execute ");
            }
        }
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf([number_of_entries]Entry));
    }
};

fn signExtendAddress(addr: u64) u64 {
    return @bitCast(@as(i64, @bitCast(addr << 16)) >> 16);
}

const level_1_shift = 12;
const level_2_shift = 21;
const level_3_shift = 30;
const level_4_shift = 39;

const maximum_physical_address_bit = 39;

const length_of_4kib_aligned_address = maximum_physical_address_bit - level_1_shift;
const length_of_2mib_aligned_address = maximum_physical_address_bit - level_2_shift;
const length_of_1gib_aligned_address = maximum_physical_address_bit - level_3_shift;

const type_of_4kib = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_1_shift,
);
const type_of_2mib = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_2_shift,
);
const type_of_1gib = std.meta.Int(
    .unsigned,
    maximum_physical_address_bit - level_3_shift,
);
