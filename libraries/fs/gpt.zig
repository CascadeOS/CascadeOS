// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const UUID = @import("uuid").UUID;

const fs = @import("fs.zig");
const MBR = fs.mbr.MBR;

pub const Crc32 = std.hash.crc.Crc32IsoHdlc;

/// The minimum size that must be reserved for the GPT partition entry array.
pub const minimum_size_of_partition_entry_array = core.Size.from(16, .kib);

/// The minimum number of partition entries due to the minimum size reserved for the partition array.
pub const minimum_number_of_partition_entries = @intCast(
    u32,
    minimum_size_of_partition_entry_array.divide(PartitionEntry.size),
);

/// Almost every tool generates partitions with this alignment.
/// https://en.wikipedia.org/wiki/Logical_Disk_Manager#Advantages_of_using_a_1-MB_alignment_boundary
pub const recommended_alignment_of_partitions: core.Size = core.Size.from(1, .mib);

/// Creates a protective MBR partition table with a single partition covering the entire disk.
///
/// This function does the following:
///
/// - Sets the MBR signature to 0xAA55.
/// - Sets the first partition record to:
///   - Boot indicator: `0x00` (non-bootable)
///   - Starting CHS: `0x200`
///   - OS type: `0xEE` (GPT Protective)
///   - Ending CHS: CHS address calulated from the `number_of_lba`
///   - Starting LBA: `0x1`
///   - Size in LBA: Which ever is smaller between `size_in_lba - 1` and `0xFFFFFFFF`.
/// - Sets the remaining partition records and fields to 0.
///
/// This MBR partition table is used to protect GPT disks from tools that do not understand GPT partition structures.
///
/// Parameters:
/// - `mbr`: The MBR struct to populate.
/// - `number_of_lba`: The total number of LBAs on the disk.
pub fn protectiveMBR(mbr: *MBR, number_of_lba: usize) void {
    const size_in_lba_clamped: u32 = if (number_of_lba > 0xFFFFFFFF)
        0xFFFFFFFF
    else
        @truncate(u32, number_of_lba - 1);

    // TODO: calulate this from the `number_of_lba`
    const ending_chs: u24 = 0xFFFFFF;

    mbr.* = MBR{
        // `boot_code` unused by UEFI systems.
        .boot_code = [_]u8{0} ** 440,

        // Unused. Set to zero.
        .mbr_disk_signature = 0,

        // Unused. Set to zero.
        .unknown = 0,

        // partition record as defined in the GPT spec
        .record1 = MBR.PartitonRecord{
            // Set to 0x00 to indicate a non-bootable partition.
            // If set to any value other than 0x00 the behavior of this flag on non-UEFI systems is undefined.
            // Must be ignored by UEFI implementations.
            .boot_indicator = 0x0,

            // Set to 0x000200, corresponding to the Starting LBA field.
            .starting_chs = 0x200,

            // Set to 0xEE (i.e., GPT Protective)
            .os_type = 0xEE,

            // Set to the CHS address of the last logical block on the disk.
            // Set to 0xFFFFFF if it is not possible to represent the value in this field.
            .ending_chs = ending_chs,

            // Set to 0x00000001 (i.e., the LBA of the GPT Partition Header).
            .starting_lba = 0x1,

            // Set to the size of the disk minus one.
            // Set to 0xFFFFFFFF if the size of the disk is too large to be represented in this field.
            .size_in_lba = size_in_lba_clamped,
        },

        // three partition records each set to zero.
        .record2 = .{},
        .record3 = .{},
        .record4 = .{},

        // Set to 0xAA55 (i.e., byte 510 contains 0x55 and byte 511 contains 0xAA).
        .signature = MBR.signature,
    };
}

/// Defines a GUID Partition Table (GPT) header.
///
/// This structure contains metadata about the GPT partition table like the number of entries, entry size, CRCs, etc.
pub const Header = extern struct {
    /// Identifies EFI-compatible partition table header.
    /// This value must contain the ASCII string “EFI PART”, encoded as the 64-bit constant 0x5452415020494645.
    signature: u64 align(1) = 0x5452415020494645,

    /// The revision number for this header.
    /// This revision value is not related to the UEFI Specification version.
    revision: Revision align(1) = .@"1.0",

    /// Size in bytes of the GPT Header.
    /// The `header_size` must be greater than or equal to 92 and must be less than or equal to the logical block size.
    header_size: u32 align(1) = @sizeOf(Header),

    /// CRC32 checksum for the GPT Header structure.
    /// This value is computed by setting this field to 0, and computing the 32-bit CRC for `header_size` bytes.
    header_crc_32: u32 align(1) = 0,

    /// Must be zero.
    _reserved: u32 align(1) = 0,

    /// The LBA that contains this data structure.
    my_lba: u64 align(1),

    /// LBA address of the alternate GPT Header.
    alternate_lba: u64 align(1),

    /// The first usable logical block that may be used by a partition described by a GUID Partition Entry.
    first_usable_lba: u64 align(1),

    /// The last usable logical block that may be used by a partition described by a GUID Partition Entry.
    last_usable_lba: u64 align(1),

    /// GUID that can be used to uniquely identify the disk.
    disk_guid: UUID align(1),

    /// The starting LBA of the GUID Partition Entry array.
    partition_entry_lba: u64 align(1),

    /// The number of Partition Entries in the GUID Partition Entry array.
    number_of_partition_entries: u32 align(1),

    /// The size, in bytes, of each the GUID Partition Entry structures in the GUID Partition Entry array.
    /// This field shall be set to a value of 128 x 2 n where n is an integer greater than or equal to zero (e.g., 128, 256, 512, etc.).
    /// NOTE: Previous versions of this specification allowed any multiple of 8.
    size_of_partition_entry: u32 align(1),

    /// The CRC32 of the GUID Partition Entry array.
    /// Starts at `partition_entry_lba` and is computed over a byte length of `number_of_partition_entries * size_of_partition_entry`.
    partition_entry_array_crc32: u32 align(1),

    pub const Revision = enum(u32) {
        @"1.0" = 0x10000,
        _,
    };

    /// Updates the `header_crc_32`field with the CRC32 checksum.
    ///
    /// Anytime a field in this structure is modified, the CRC should be recomputed.
    /// This includes any changes to the partition entry array as it's checksum is stored in the header as well.
    pub fn updateHash(self: *Header) void {
        const header_bytes = @ptrCast([*]u8, self)[0..self.header_size];
        self.header_crc_32 = 0;
        self.header_crc_32 = Crc32.hash(header_bytes);
    }

    /// Copies the contents of one GPT header to another, handling the differences between primary and backup headers.
    ///
    /// This function does the following:
    ///
    /// - Makes an exact copy of the source header into the destination header.
    /// - Swaps the my_lba and alternate_lba fields between the primary and backup headers.
    /// - Recalculates the partition_entry_lba to maintain the correct offset from my_lba.
    /// - Updates the header hash.
    ///
    /// This allows copying a primary GPT header to a backup header and vice versa while keeping all the header values correct.
    ///
    /// Parameters:
    /// - `self`: The source GPT header.
    /// - `other_header`: The destination GPT header.
    /// - `partition_array_size_in_lba`: The size of the partition entry array in units of logical blocks.
    pub fn copyToOtherHeader(
        source_header: *const Header,
        destination_header: *Header,
        partition_array_size_in_lba: u64,
    ) void {
        // start with an exact copy
        destination_header.* = source_header.*;

        // swap the `my_lba` and `alternate_lba` field
        destination_header.my_lba = source_header.alternate_lba;
        destination_header.alternate_lba = source_header.my_lba;

        // calculate the new `partition_entry_lba` by maintaining the correct offset from `my_lba`
        if (source_header.my_lba < source_header.partition_entry_lba) {
            // we are copying from the primary header `source_header` to the backup header `destination_header`
            const primary_to_partition_array_offset = source_header.partition_entry_lba - source_header.my_lba;

            destination_header.partition_entry_lba = 1 +
                destination_header.my_lba -
                primary_to_partition_array_offset -
                partition_array_size_in_lba;
        } else {
            // we are copying from the backup header `source_header` to the primary header `destination_header`
            const backup_to_partition_array_offset = source_header.my_lba - source_header.partition_entry_lba;

            destination_header.partition_entry_lba = 1 +
                destination_header.my_lba +
                backup_to_partition_array_offset -
                partition_array_size_in_lba;
        }

        // update the header hash
        destination_header.updateHash();
    }

    comptime {
        core.testing.expectSize(@This(), 92);
    }
};

/// Defines a GUID Partition Table (GPT) partition entry.
///
/// This structure contains metadata about a single partition like type, name, starting/ending LBA, attributes, etc.
pub const PartitionEntry = extern struct {
    /// Unique ID that defines the purpose and type of this Partition.
    /// A value of zero defines that this partition entry is not being used.
    partition_type_guid: UUID,

    /// GUID that is unique for every partition entry. Every partition ever created will have a unique GUID.
    /// This GUID must be assigned when the GPT Partition Entry is created.
    /// The GPT Partition Entry is created whenever the `number_of_partition_entries` in the GPT `Header` is increased
    /// to include a larger range of addresses.
    unique_partition_guid: UUID,

    /// Starting LBA of the partition defined by this entry.
    starting_lba: u64,

    /// Ending LBA of the partition defined by this entry.
    ending_lba: u64,

    /// Attribute bits
    attributes: Attribute = .{},

    /// Null-terminated string containing a human-readable name of the partition.
    /// UNICODE16-LE encoded.
    partition_name: [36]u16 = [_]u16{0} ** 36,

    pub const Attribute = packed struct(u64) {
        /// If this bit is set, the partition is required for the platform to function.
        /// The owner/creator of the partition indicates that deletion or modification of the contents can result in
        /// loss of platform features or failure for the platform to boot or operate.
        /// The system cannot function normally if this partition is removed, and it should be considered part of the
        /// hardware of the system. Actions such as running diagnostics, system recovery, or even OS install or boot
        /// could potentially stop working if this partition is removed.
        /// Unless OS software or firmware recognizes this partition, it should never be removed or modified as the UEFI
        ///  firmware or platform hardware may become non-functional.
        required: bool = false,

        /// If this bit is set, then firmware must not produce an EFI_BLOCK_IO_PROTOCOL device for this partition.
        /// See Partition Discovery for more details.
        /// By not producing an EFI_BLOCK_IO_PROTOCOL partition, file system mappings will not be created for this
        /// partition in UEFI.
        no_block_io: bool = false,

        /// This bit is set aside by this specification to let systems with traditional PC-AT BIOS firmware implementations
        /// inform certain limited, special-purpose software running on these systems that a GPT partition may be bootable.
        /// For systems with firmware implementations conforming to this specification, the UEFI boot manager (see chapter 3)
        /// must ignore this bit when selecting a UEFI-compliant application, e.g., an OS loader (see 2.1.3).
        /// Therefore there is no need for this specification to define the exact meaning of this bit.
        legacy_bios_bootable: bool = false,

        /// Undefined and must be zero. Reserved for expansion by future versions of the UEFI specification.
        _undefined: u45 = 0,

        /// Reserved for GUID specific use.
        /// The use of these bits will vary depending on the `partition_type_guid`.
        /// Only the owner of the `partition_type_guid` is allowed to modify these bits.
        /// They must be preserved if Bits 0-47 are modified.
        _reserved: u16 = 0,
    };

    pub const size: core.Size = core.Size.of(PartitionEntry);

    comptime {
        core.testing.expectSize(@This(), 128);
    }
};

/// Partition Type GUIDs
///
/// List available: https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_type_GUIDs
pub const partition_types = struct {
    /// Unused Entry
    /// Defined by the UEFI specification.
    pub const unused: UUID = UUID.nil;

    /// EFI System Partition
    /// Defined by the UEFI specification.
    pub const efi_system_partition: UUID = UUID.parse("C12A7328-F81F-11D2-BA4B-00A0C93EC93B") catch unreachable;

    /// Partition containing a legacy MBR
    /// Defined by the UEFI specification.
    pub const partition_containing_legacy_mbr: UUID = UUID.parse("024DEE41-33E7-11D3-9D69-0008C781F39F") catch unreachable;

    /// Microsoft Basic Data Partition
    /// https://en.wikipedia.org/wiki/Microsoft_basic_data_partition
    ///
    /// According to Microsoft, the basic data partition is the equivalent to master boot record (MBR) partition types
    /// 0x06 (FAT16B), 0x07 (NTFS or exFAT), and 0x0B (FAT32).
    /// In practice, it is also equivalent to 0x01 (FAT12), 0x04 (FAT16), 0x0C (FAT32 with logical block addressing),
    /// and 0x0E (FAT16 with logical block addressing) types as well.
    pub const microsoft_basic_data_partition: UUID = UUID.parse("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7") catch unreachable;

    pub const linux_filesystem_data: UUID = UUID.parse("0FC63DAF-8483-4772-8E79-3D69D8477DE4") catch unreachable;
};

comptime {
    refAllDeclsRecursive(@This(), true);
}

fn refAllDeclsRecursive(comptime T: type, comptime first: bool) void {
    comptime {
        if (!@import("builtin").is_test) return;

        inline for (std.meta.declarations(T)) |decl| {
            // don't analyze if the decl is not pub unless we are the first level of this call chain
            if (!first and !decl.is_pub) continue;

            if (std.mem.eql(u8, decl.name, "std")) continue;

            if (!@hasDecl(T, decl.name)) continue;

            defer _ = @field(T, decl.name);

            if (@TypeOf(@field(T, decl.name)) != type) continue;

            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name), false),
                else => {},
            }
        }
        return;
    }
}
