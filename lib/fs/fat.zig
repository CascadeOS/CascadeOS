// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// FAT12 file allocation table entry.
pub const FAT12Entry = enum(u12) {
    /// Free cluster.
    free = 0,

    /// MS-DOS/PC DOS use this cluster value as a temporary non-free cluster indicator while constructing cluster
    /// chains during file allocation (only seen on disk if there is a crash or power failure in the middle of this process).
    ///
    /// If this value occurs in on-disk cluster chains, file system implementations should treat this like an
    /// end-of-chain marker.
    reserved_temporary_non_free_cluster_indicator = 0x1,

    /// Bad sector.
    bad_sector = 0xff7,

    /// If the value is greater or equal to this, then this is the last cluster in chain.
    end_of_chain = 0xff8,

    _,
};

/// FAT16 file allocation table entry.
pub const FAT16Entry = enum(u16) {
    /// Free cluster.
    free = 0,

    /// MS-DOS/PC DOS use this cluster value as a temporary non-free cluster indicator while constructing cluster
    /// chains during file allocation (only seen on disk if there is a crash or power failure in the middle of this process).
    ///
    /// If this value occurs in on-disk cluster chains, file system implementations should treat this like an
    /// end-of-chain marker.
    reserved_temporary_non_free_cluster_indicator = 0x1,

    /// Bad sector.
    bad_sector = 0xfff7,

    /// If the value is greater or equal to this, then this is the last cluster in chain.
    end_of_chain = 0xfff8,

    _,
};

/// FAT32 file allocation table entry.
pub const FAT32Entry = enum(u32) {
    /// Free cluster.
    free = 0,

    /// MS-DOS/PC DOS use this cluster value as a temporary non-free cluster indicator while constructing cluster
    /// chains during file allocation (only seen on disk if there is a crash or power failure in the middle of this process).
    ///
    /// If this value occurs in on-disk cluster chains, file system implementations should treat this like an
    /// end-of-chain marker.
    reserved_temporary_non_free_cluster_indicator = 0x1,

    /// Bad sector.
    bad_sector = 0x0ffffff7,

    /// If the value is greater or equal to this, then this is the last cluster in chain.
    end_of_chain = 0x0ffffff8,

    _,
};

/// EXFAT file allocation table entry.
pub const EXFATEntry = enum(u32) {
    /// Free cluster.
    free = 0,

    /// MS-DOS/PC DOS use this cluster value as a temporary non-free cluster indicator while constructing cluster
    /// chains during file allocation (only seen on disk if there is a crash or power failure in the middle of this process).
    ///
    /// If this value occurs in on-disk cluster chains, file system implementations should treat this like an
    /// end-of-chain marker.
    reserved_temporary_non_free_cluster_indicator = 0x1,

    /// Bad sector.
    bad_sector = 0xfffffff7,

    /// If the value is greater or equal to this, then this is the last cluster in chain.
    end_of_chain = 0xfffffff8,

    _,
};

/// BIOS Parameter Block.
///
/// Contains filesystem geometry and layout information.
pub const BPB = extern struct {
    /// Jump instruction.
    jump: [3]u8 align(1) = [_]u8{ 0xEB, 0x58, 0x90 },

    /// OEM identifier.
    oem_identifier: [8]u8 align(1),

    /// Number of bytes per sector.
    bytes_per_sector: u16 align(1),

    /// Number of sectors per cluster.
    sectors_per_cluster: u8,

    /// Number of reserved sectors.
    ///
    /// The boot record sectors are included in this value.
    reserved_sectors: u16 align(1),

    /// Number of File Allocation Tables (FAT's) on the storage media.
    ///
    /// Often this value is 2.
    number_of_fats: u8,

    /// Number of root directory entries (must be set so that the root directory occupies entire sectors).
    ///
    /// For FAT32, this field must be 0.
    number_of_root_directory_entries: u16 align(1),

    /// The total sectors in the logical volume.
    ///
    /// If this value is 0, it means there are more than 65535 sectors in the volume, and the actual count is stored
    /// in `large_sector_count`.
    ///
    /// For FAT32, this field must be 0.
    number_of_sectors: u16 align(1),

    /// Media descriptor type.
    media_descriptor_type: MediaDescriptor,

    /// Number of sectors per FAT.
    ///
    /// For FAT32, this field must be 0.
    sectors_per_fat: u16 align(1),

    /// Number of sectors per track.
    sectors_per_track: u16 align(1),

    /// Number of heads or sides on the storage media.
    number_of_heads: u16 align(1),

    /// Count of hidden sectors preceding the partition that contains this FAT partition.
    number_of_hidden_sectors: u32 align(1),

    /// Large sector count.
    ///
    /// For FAT32, this field must be non-zero.
    ///
    /// For FAT12/FAT16, this field contains the sector count if `number_of_sectors` is 0.
    large_sector_count: u32 align(1),

    comptime {
        core.testing.expectSize(@This(), 36);
    }
};

/// In FAT32 the BPB is immediately followed by this structure.
pub const ExtendedBPB_32 = extern struct {
    /// Number of sectors per FAT.
    sectors_per_fat: u32 align(1),

    flags: Flags align(1),

    /// FAT version number.
    version: u16 align(1),

    /// The cluster number of the root directory.
    ///
    /// Often this field is set to 2.
    root_cluster: u32 align(1),

    /// The sector number of the FSInfo structure.
    fsinfo_sector: u16 align(1),

    /// The sector number of the backup boot sector.
    backup_boot_sector: u16 align(1),

    _reserved1: u64 align(1) = 0,
    _reserved2: u32 align(1) = 0,

    /// Drive number.
    ///
    /// 0x00 for a floppy disk and 0x80 for hard disks.
    drive_number: u8 align(1),

    _reserved3: u8 = 0,

    /// Signature (must be 0x28 or 0x29).
    extended_boot_signature: u8,

    /// Volume ID 'Serial' number.
    volume_id: u32 align(1),

    /// Volume label string.
    ///
    /// This field is padded with spaces.
    volume_label: [11]u8,

    /// System identifier string. Always "FAT32   ".
    file_system_type: [8]u8 = [_]u8{ 'F', 'A', 'T', '3', '2', ' ', ' ', ' ' },

    boot_code: [420]u8 = [_]u8{0} ** 420,

    signature: u16 align(1) = fs.mbr.MBR.mbr_signature,

    pub const Flags = packed struct(u16) {
        active_fat: u4,

        _reserved1: u3 = 0,

        mode: Mode,

        _reserved2: u8 = 0,

        pub const Mode = enum(u1) {
            each_fat_active_and_mirrored = 0,
            one_fat_active = 1,
        };
    };

    comptime {
        core.testing.expectSize(@This(), 512 - @sizeOf(BPB));
    }
};

pub const Time = packed struct(u16) {
    /// In units of 2 seconds.
    second_2s: u5,

    minute: u6,

    hour: u5,
};

pub const Date = packed struct(u16) {
    day: u5,

    month: u4,

    /// Number of years after 1980.
    year: u7,
};

pub const ShortFileName = extern struct {
    /// File name (padded with spaces)
    name: [8]u8 align(1) = [_]u8{' '} ** 8,

    /// File extension (padded with spaces)
    extension: [3]u8 align(1) = [_]u8{' '} ** 3,

    /// Calculates the checksum for a short file name.
    ///
    /// See `LongFileNameEntry.checksum_of_short_name`
    pub fn checksum(self: *const ShortFileName) u8 {
        const ptr = std.mem.asBytes(self);

        var sum: u8 = 0;

        for (ptr) |byte| {
            sum = ((sum & 1) << 7) +% (sum >> 1) +% byte;
        }

        return sum;
    }

    pub fn equal(self: ShortFileName, other: ShortFileName) bool {
        return std.mem.eql(u8, &self.name, &other.name) and std.mem.eql(u8, &self.extension, &other.extension);
    }

    pub const file_name_max_length = 8;
    pub const extension_max_length = 3;

    comptime {
        core.testing.expectSize(@This(), 11);
    }
};

pub const DirectoryEntry = extern union {
    standard: StandardDirectoryEntry align(1),

    long_file_name: LongFileNameEntry align(1),

    pub fn isLastEntry(self: *const DirectoryEntry) bool {
        const bytes = std.mem.asBytes(self);
        return bytes[0] == 0;
    }

    pub fn setLastEntry(self: *DirectoryEntry) void {
        const bytes = std.mem.asBytes(self);
        bytes[0] = 0;
    }

    pub fn isUnusedEntry(self: *const DirectoryEntry) bool {
        const bytes = std.mem.asBytes(self);
        return bytes[0] == unused_value;
    }

    pub fn setUnused(self: *DirectoryEntry) void {
        const bytes = std.mem.asBytes(self);
        bytes[0] = unused_value;
    }

    pub inline fn isLongFileNameEntry(self: DirectoryEntry) bool {
        return self.standard.attributes.isLongFileNameEntry();
    }

    const long_file_name_value: u8 = 0x0f;

    const unused_value: u8 = 0xE5;

    pub const StandardDirectoryEntry = extern struct {
        /// 8.3 file name.
        short_file_name: ShortFileName align(1),

        attributes: Attributes align(1),

        _reserved: u8 align(1) = 0,

        /// Optional sub-second creation time information, in units of 10 miliseconds.
        ///
        /// The resolution of `creation_date` + `creation_time` is 2 seconds, using this field as well gives a
        /// resolution of 10 milliseconds.
        ///
        /// If not supported, set to zero.
        creation_datetime_subsecond: u8 align(1),

        creation_time: Time align(1),
        creation_date: Date align(1),

        last_accessed_date: Date align(1),

        high_cluster_number: u16 align(1),

        last_modification_time: Time align(1),
        last_modification_date: Date align(1),

        low_cluster_number: u16 align(1),

        size: u32 align(1),

        pub const Attributes = packed struct(u8) {
            /// Should not allow writing
            read_only: bool = false,

            /// Should not show in directory listing
            hidden: bool = false,

            /// Operating system file
            system: bool = false,

            /// Filename is Volume ID
            volume_label: bool = false,

            /// Is a subdirectory
            directory: bool = false,

            /// Typically set by the operating system as soon as the file is created or modified to mark the file as
            /// "dirty", and reset by backup software once the file has been backed up to indicate "pure" state.
            archive: bool = false,

            _reserved: u2 = 0,

            pub fn isLongFileNameEntry(self: Attributes) bool {
                const raw: u8 = @bitCast(self);
                const truncated: u4 = @truncate(raw);
                return truncated == long_file_name_value;
            }
        };

        comptime {
            core.testing.expectSize(@This(), 32);
        }
    };

    pub const LongFileNameEntry = extern struct {
        /// Sequence number (1-20) to identify where this entry is in the sequence of LFN entries.
        ///
        /// Bitwise Or the value with `last_entry` if it is the last part of the LFN.
        ///
        /// If there are multiple LFN entries required to represent a file name, the entry representing the end of the
        /// filename comes first.
        ///
        /// The sequence number of that entry has bit 6 (0x40 / `last_entry`) set to represent that it is the last
        /// logical LFN entry, and it has the highest sequence number.
        sequence_number: u8 align(1),

        /// 1st character to 5th character of the name, UCS-2 encoded.
        ///
        /// After the last character of the name, a 0x0000 is added.
        ///
        /// The remaining unused characters are filled with 0xFFFF.
        first_characters: [5]u16 align(1) = [_]u16{0xFFFF} ** 5,

        /// Always equal to 0x0f if this is a long file name entry.
        ///
        /// Analogous to the `attributes` field of `StandardDirectoryEntry`
        long_file_name_attribute: u8 align(1) = long_file_name_value,

        /// Must be zero
        long_entry_type: u8 align(1) = 0,

        /// Checksum of the short file name, see `ShortFileName.checksum`
        checksum_of_short_name: u8 align(1),

        /// 6th character to 11th character of the name, UCS-2 encoded.
        ///
        /// After the last character of the name, a 0x0000 is added.
        ///
        /// The remaining unused characters are filled with 0xFFFF.
        middle_characters: [6]u16 align(1) = [_]u16{0xFFFF} ** 6,

        _reserved: u16 align(1) = 0,

        /// 12th character to 13th character of the name, UCS-2 encoded.
        ///
        /// After the last character of the name, a 0x0000 is added.
        ///
        /// The remaining unused characters are filled with 0xFFFF.
        final_characters: [2]u16 align(1) = [_]u16{0xFFFF} ** 2,

        pub const last_entry: u8 = 0x40;
        pub const maximum_number_of_characters = 13;
        pub const maximum_number_of_long_name_entries = 20;

        comptime {
            core.testing.expectSize(@This(), 32);
        }
    };

    comptime {
        core.testing.expectSize(@This(), 32);
    }
};

pub const MediaDescriptor = enum(u8) {
    // List available https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system#BPB20_OFS_0Ah

    fixed_disk = 0xF8,

    _,
};

pub const FSInfo = extern struct {
    lead_signature: u32 align(1) = 0x41615252,

    _reserved1: [480]u8 align(1) = [_]u8{0} ** 480,

    signature: u32 align(1) = 0x61417272,

    /// Last known number of free data clusters on the volume, or 0xFFFFFFFF if unknown.
    ///
    /// Should be set to 0xFFFFFFFF during format and updated by the operating system later on.
    ///
    /// Must not be absolutely relied upon to be correct in all scenarios.
    ///
    /// Before using this value, the operating system should sanity check this value to be less than or equal to the
    /// volume's count of clusters.
    last_known_number_of_free_clusters: u32 align(1),

    /// Number of the most recently known to be allocated data cluster.
    ///
    /// Should be set to 0xFFFFFFFF during format and updated by the operating system later on.
    ///
    /// With 0xFFFFFFFF the system should start at cluster 0x00000002.
    ///
    /// Must not be absolutely relied upon to be correct in all scenarios.
    ///
    /// Before using this value, the operating system should sanity check this value to be a valid cluster number on
    /// the volume.
    most_recently_allocated_cluster: u32 align(1),

    _reserved2: [12]u8 align(1) = [_]u8{0} ** 12,

    trial_signature: u32 align(1) = 0xAA550000,
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const core = @import("core");
const fs = @import("fs");
const std = @import("std");
