// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// TODO: This file is *very* WIP.

const core = @import("core");
const fs = @import("fs");
const std = @import("std");
const UUID = @import("uuid").UUID;

pub const signature: u16 = 0xef53;

/// The superblock is always 1024 bytes from the beginning of the file system.
pub const superblock_offset: usize = 1024;

pub const Superblock = extern struct {
    // TODO: Check all of the "Only valid if:" in the document comments.

    /// The total number of inodes in the filesystem.
    inode_count: u32 align(1),

    /// Low 32-bits of the number of blocks in the filesystem.
    block_count_low: u32 align(1),

    /// Low 32-bits of the number of blocks reserved for the superuser.
    reserved_block_count_low: u32 align(1),

    /// Low 32-bits of the number of blocks available.
    free_block_count_low: u32 align(1),

    /// The number of free inodes available.
    free_inode_count: u32 align(1),

    /// First data block.
    ///
    /// This must be at least 1 for 1k-block filesystems and is typically 0 for all other block sizes.
    first_data_block: u32 align(1),

    /// Amount to shift 1024 left by to get the block size.
    ///
    /// Equal to `Log2(block size) - 10`
    block_size_shift: u32 align(1),

    /// Amount to shift 1024 left by to get the fragment size.
    ///
    /// Equal to `Log2(fragment size) - 10`
    ///
    /// This is usually equal to `block_size_shift` as fragments are not commonly implemented.
    fragment_size_shift: u32 align(1),

    /// Number of blocks in a block group.
    blocks_per_group: u32 align(1),

    /// Number of fragments in a block group.
    ///
    /// This is usually equal to `blocks_per_group` as fragments are not commonly implemented.
    fragments_per_group: u32 align(1),

    /// Number of inodes in a block group.
    inodes_per_group: u32 align(1),

    /// Last mount time, in UNIX time.
    last_mount_time_low: u32 align(1),

    /// Last write time, in UNIX time.
    last_write_time_low: u32 align(1),

    /// Number of mounts since last consistency check.
    mounts_since_check: u16 align(1),

    /// Max mounts allowed before consistency check is required.
    max_mounts_before_check: u16 align(1),

    /// Filesystem signature.
    signature: u16 align(1) = signature,

    /// Filesystem state.
    state: State align(1),

    /// Behaviour when an error is detected.
    error_behaviour: ErrorBehaviour align(1),

    /// Minor version.
    minor_version: u16 align(1),

    /// Last consistency check time, in UNIX time.
    last_check_time_low: u32 align(1),

    /// Maximum time between consistency checks, in UNIX time.
    forced_check_interval: u32 align(1),

    /// Creator OS ID.
    creator_os: Creator align(1),

    /// Major version.
    major_version: u32 align(1),

    /// User ID allowed to use reserved blocks.
    reserved_user_id: u16 align(1),

    /// Group ID allowed to use reserved blocks.
    reserved_group_id: u16 align(1),

    // FIXME: Below here: Only valid if `major_version` >= 1

    /// First non-reserved inode.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_non_reserved_inode: u32 align(1),

    /// The size of each inode structure in bytes.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    inode_size: u16 align(1),

    /// Block group that this superblock is part of for backup copies.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    superblock_group: u16 align(1),

    /// Compatible feature flags.
    ///
    /// A kernel can still read/write this filesystem even if it doesn't understand a flag; fsck should stop.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    compatible_features: CompatibleFeatures align(1),

    /// Incompatible feature flags.
    ///
    /// If the kernel or fsck doesn't understand one of these flags, it should stop.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    incompatible_features: IncompatibleFeatures align(1),

    /// Readonly compatible feature flags.
    ///
    /// If the kernel doesn't understand one of these flags, it can still mount read-only.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    read_only_features: ReadOnlyFeatures align(1),

    /// Filesystem ID.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    filesystem_id: UUID align(1),

    /// Volume name.
    ///
    /// C-style zero terminated string.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    volume_name: [16]u8 align(1),

    /// Directory path where the filesystem was last mounted.
    ///
    /// C-style zero terminated string.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_mount_path: [64]u8 align(1),

    /// The compression algorithm used by the filesystem.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    compression_algorithm: CompressionAlgorithm align(1),

    /// The number of blocks to preallocate for regular files.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    preallocate_file_blocks: u8 align(1),

    /// The number of blocks to preallocate for directories.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.directory_preallocation` is true
    preallocate_directory_blocks: u8 align(1),

    /// Number of reserved GDT entries for future filesystem expansion.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.resize_inode` is true
    reserved_number_of_gdt_entries: u16 align(1) = 0,

    /// The UUID of the journal superblock.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.journal` is true
    journal_id: UUID align(1),

    /// The inode number of the journal file.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.journal` is true
    journal_inode: u32 align(1),

    /// Device number of journal file.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.journal` is true
    ///  - `incompatible_features.journal_device` is true
    journal_device: u32 align(1),

    /// Start of list of orphaned inodes to delete.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    orphan_inodes_head: u32 align(1),

    /// HTREE hash seed.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    hash_seed: [4]u32 align(1),

    /// Default hash algorithm to use for directory hashes.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    hash_algorithm: HashAlgorithm align(1),

    /// TODO: correct field references
    /// If this value is 0 or 1 then the `journal_inode_backup` field field contains a duplicate copy of the
    /// journal inode's `i_block` array and `i_size`.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.journal` is true
    journal_backup_type: u8 align(1),

    /// Size of group descriptors.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.@"64bit"` is true
    group_descriptor_size: u16 align(1),

    /// Default mount options.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    default_mount_options: MountOptions align(1),

    /// First metablock block group.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.meta_block_groups` is true
    first_metablock_group: u32 align(1),

    /// Filesystem creation time, in UNIX time.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    creation_time_low: u32 align(1),

    /// TODO: correct field references
    /// Backup copy of the journal inode's `i_block` array in the first 15 elements and `i_size_high` and `i_size` in
    /// the 16th and 17th elements, respectively.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.journal` is true
    ///  - `journal_backup_type` is 0 or 1.
    journal_inode_backup: [17]u32 align(1),

    /// High 32-bits of the number of blocks in the filesystem.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.@"64bit"` is true
    block_count_high: u32 align(1),

    /// High 32-bits of the number of blocks reserved for the superuser.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.@"64bit"` is true
    reserved_block_count_high: u32 align(1),

    /// High 32-bits of the number of blocks available.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.@"64bit"` is true
    free_block_count_high: u32 align(1),

    /// All inodes have at least this many bytes.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    minimum_inode_size: u16 align(1),

    /// New inodes should reserve this many bytes.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    inode_reservation_size: u16 align(1),

    /// Miscellaneous flags.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    misc_flags: Flags align(1),

    /// RAID stride.
    ///
    /// This is the number of logical blocks read from or written to the disk before moving to the next disk.
    ///
    /// This affects the placement of filesystem metadata, which will hopefully make RAID storage faster.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    raid_stride: u16 align(1),

    /// Number of seconds to wait in multi-mount prevention (MMP) checking.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.multiple_mount_protection` is true
    mmp_interval: u16 align(1),

    /// Block for multi-mount protection data.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.multiple_mount_protection` is true
    mmp_block: u64 align(1),

    /// RAID stripe width.
    ///
    /// This is the number of logical blocks read from or written to the disk before coming back to the current disk.
    ///
    /// This is used by the block allocator to try to reduce the number of read-modify-write operations in a RAID5/6.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    raid_stripe_width: u32 align(1),

    /// Amount to shift 1024 left by to get the groups per flexible block group.
    ///
    /// Equal to `Log2(groups per flex) - 10`
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.flexible_block_groups` is true
    groups_per_flexible_block_group_shift: u8 align(1),

    /// Metadata checksum algorithm type.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.gdt_checksum` or `read_only_features.metadata_checksum` is true
    checksum_type: ChecksumType align(1),

    /// Versioning level for encryption.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.encypted` is true
    encryption_level: u8 align(1),

    _reserved: u8 align(1) = 0,

    /// Number of KiB written to this filesystem over its lifetime.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    data_written: u64 align(1),

    /// inode of active snapshot.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.has_snapshot` is true
    inode_of_active_snapshot: u32 align(1),

    /// Sequential ID of active snapshot.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.has_snapshot` is true
    sequential_id_of_snapshot: u32 align(1),

    /// Number of blocks reserved for active snapshot's future use.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.has_snapshot` is true
    blocks_reserved_for_active_snapshot: u64 align(1),

    /// inode number of the head of the on-disk snapshot list.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.has_snapshot` is true
    snapshot_list: u32 align(1),

    /// Number of errors seen.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    error_count: u32 align(1),

    /// First time an error happened, in UNIX time.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_time_low: u32 align(1),

    /// inode involved in the first error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_inode: u32 align(1),

    /// Block involved in the first error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_block: u64 align(1),

    /// Name of function where the first error happened.
    ///
    /// C-style zero terminated string.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_function: [32]u8 align(1),

    /// Line where the first error happened.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_line_number: u32 align(1),

    /// Time of the most recent error, in UNIX time.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_time_low: u32 align(1),

    /// inode involved in most recent error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_inode: u32 align(1),

    /// Line where most recent error happened.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_line_number: u32 align(1),

    /// Block involved in most recent error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_block: u64 align(1),

    /// Name of function where the most recent error happened.
    ///
    /// C-style zero terminated string.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_function: [32]u8 align(1),

    /// Mount options.
    ///
    /// C-style zero terminated string.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    mount_options: [64]u8 align(1),

    /// Inode of the user quota file.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    user_quota_inode: u32 align(1),

    /// Inode of the group quota file.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    group_quota_inode: u32 align(1),

    /// Overhead blocks/clusters in fs.
    ///
    /// If this field is zero this must be calulcated at runtime.
    /// TODO: "calulcated at runtime" how, why?
    overhead_blocks: u32 align(1),

    /// Block groups containing superblock backups
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.sparse_superblock_v2` is true
    block_groups_with_backup_superblocks: [2]u32 align(1),

    /// Encryption algorithms in use.
    ///
    /// There can be up to four algorithms in use at any time.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.encypted` is true
    encryption_algorithms: [4]EncyptionAlgorithm align(1),

    /// Salt for the string2key algorithm for encryption.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `incompatible_features.encypted` is true
    salt_for_string2key: u128 align(1),

    /// Inode of lost+found directory.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    lost_and_found_inode: u32 align(1),

    /// Inode that tracks project quotas.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.project_quotas` is true
    project_quota_inode: u32 align(1),

    /// Checksum seed used for metadata_csum calculations.
    ///
    /// This value is crc32c(~0, $orig_fs_uuid).
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.gdt_checksum` or `read_only_features.metadata_checksum` is true
    ///  - `incompatible_features.checksum_seed` is true
    checksum_seed: u32 align(1),

    /// Upper 8 bits of the `last_write_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_write_time_high: u8 align(1),

    /// Upper 8 bits of the `last_mount_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_mount_time_high: u8 align(1),

    /// Upper 8 bits of the `creation_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    creation_time_high: u8 align(1),

    /// Upper 8 bits of the `last_check_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_check_time_high: u8 align(1),

    /// Upper 8 bits of the `first_error_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_time_high: u8 align(1),

    /// Upper 8 bits of the `last_error_time` field.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_time_high: u8 align(1),

    /// Error code of the first error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    first_error_code: u8 align(1),

    /// Error code of the most recent error.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    last_error_code: u8 align(1),

    /// Filename charset encoding.
    ///
    /// Used during casefolding of filenames.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    filename_charset_encoding: u16 align(1),

    /// Filename charset encoding flags.
    ///
    /// Used during casefolding of filenames.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    filename_charset_encoding_flags: u16 align(1),

    /// Inode for tracking orphan inodes
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `compatible_features.orphan_file` is true
    orphan_file_inode: u32 align(1),

    _padding: [94]u32 align(1) = std.mem.zeroes([94]u32),

    /// Superblock checksum.
    ///
    /// Only valid if:
    ///  - `major_version` >= 1
    ///  - `read_only_features.metadata_checksum` is true
    checksum: u32 align(1),

    // TODO: Should this be an enum?
    pub const Flags = packed struct(u32) {
        /// Signed directory hash in use.
        signed_directory_hash: bool = false,

        /// Unsigned directory hash in use.
        unsigned_directory_hash: bool = false,

        test_development_code: bool = false,

        _unused: u29 = 0,
    };

    comptime {
        core.testing.expectSize(@This(), 1024);
    }
};

/// Describes a block group in the ext filesystem.
///
/// It contains metadata like the block bitmap, inode bitmap, free block counts, etc.
/// There is one descriptor per block group.
///
/// The actual size of the descriptor depends on what features are enabled.
/// The size is given by the superblock `group_descriptor_size` field if 64-bit is enabled, its 32 bytes if not.
pub const BlockGroupDescriptor = extern struct {
    /// Low 32-bits of the location of the block bitmap.
    block_bitmap_low: u32 align(1),

    /// Low 32-bits of the location of the inode bitmap.
    inode_bitmap_low: u32 align(1),

    /// Low 32-bits of the location of the inode table.
    inode_table_low: u32 align(1),

    /// Low 16-bits of the free block count.
    free_block_count_low: u16 align(1),

    /// Low 16-bits of the free inode count.
    free_inode_count_low: u16 align(1),

    /// Low 16-bits of the used directory count.
    used_directory_count_low: u16 align(1),

    /// Block group flags.
    flags: Flags align(1),

    /// Low 32-bits of the location of the snapshot exclusion bitmap.
    /// TODO: snapshot feature
    snapshot_exclusion_bitmap_low: u32 align(1),

    /// Low 16-bits of the block bitmap checksum.
    /// TODO: checkum feature
    block_bitmap_checksum_low: u16 align(1),

    /// Low 16-bits of the inode bitmap checksum.
    /// TODO: checkum feature
    inode_bitmap_checksum_low: u16 align(1),

    /// Low 16-bits of the unused inode count.
    unused_inode_count_low: u16 align(1),

    /// Group descriptor checksum.
    /// TODO: checksum feature
    /// TODO:
    /// crc16(sb_uuid+group_num+bg_desc) if the RO_COMPAT_GDT_CSUM feature is set, or crc32c(sb_uuid+group_num+bg_desc) & 0xFFFF if the RO_COMPAT_METADATA_CSUM feature is set. The bg_checksum field in bg_desc is skipped when calculating crc16 checksum, and set to zero if crc32c checksum is used.
    checksum: u16 align(1),

    // TODO: These fields only exist if the 64bit feature is enabled and s_desc_size > 32.

    /// High 32-bits of the location of the block bitmap.
    block_bitmap_high: u32 align(1),

    /// High 32-bits of the location of the inode bitmap.
    inode_bitmap_high: u32 align(1),

    /// High 32-bits of the location of the inode table.
    inode_table_high: u32 align(1),

    /// High 16-bits of the free block count.
    free_block_count_high: u16 align(1),

    /// High 16-bits of the free inode count.
    free_inode_count_high: u16 align(1),

    /// High 16-bits of the used directory count.
    used_directory_count_high: u16 align(1),

    /// High 16-bits of the unused inode count.
    unused_inode_count_high: u16 align(1),

    /// High 32-bits of the location of the snapshot exclusion bitmap.
    /// TODO: snapshot feature
    snapshot_exclusion_bitmap_high: u32 align(1),

    /// High 16-bits of the block bitmap checksum.
    /// TODO: checkum feature
    block_bitmap_checksum_high: u16 align(1),

    /// High 16-bits of the inode bitmap checksum.
    /// TODO: checkum feature
    inode_bitmap_checksum_high: u16 align(1),

    _reserved: u32 = 0,

    pub const Flags = packed struct(u16) {
        /// Inode table and bitmap are not initialized.
        inode_table_and_bitmap_not_initialized: bool = false,

        /// Block bitmap is not initialized.
        block_bitmap_not_initialized: bool = false,

        /// Inode table is zeroed.
        inode_table_zeroed: bool = false,

        _unused: u13 = 0,
    };

    comptime {
        core.testing.expectSize(@This(), 64);
    }
};

pub const EncyptionAlgorithm = enum(u8) {
    invalid = 0,
    aes_256_xts = 1,
    aes_256_gcm = 2,
    aes_256_cbc = 3,

    _,
};

pub const ChecksumType = enum(u8) {
    crc32c = 1,

    _,
};

pub const MountOptions = packed struct(u32) {
    /// Print debug info upon (re)mount.
    debug: bool = false,

    /// New files take the gid of the containing directory (instead of the fsgid of the current process).
    bsd_groups: bool = false,

    /// Support userspace-provided extended attributes.
    user_extended_attributes: bool = false,

    /// Support POSIX access control lists (ACLs).
    acl: bool = false,

    /// Do not support 32-bit UIDs.
    uid16: bool = false,

    /// All data and metadata are commited to the journal.
    jmode_data: bool = false,

    /// All data are flushed to the disk before metadata are committed to the journal.
    jmode_ordered: bool = false,

    /// Data ordering is not preserved; data may be written after the metadata has been written.
    jmode_write_back: bool = false,

    _unused1: bool = false,

    /// Disable write flushes.
    no_barrier: bool = false,

    /// Track which blocks in a filesystem are metadata and therefore should not be used
    /// as data blocks.
    block_validity: bool = false,

    /// Enable DISCARD support, where the storage device is told about blocks becoming unused.
    discard: bool = false,

    /// Disable delayed allocation.
    no_delay_alloc: bool = false,

    _unused: u19 = 0,
};

pub const HashAlgorithm = enum(u8) {
    legacy = 0,
    half_md4 = 1,
    tea = 2,
    legacy_unsigned = 3,
    half_md4_unsigned = 4,
    tea_unsigned = 5,
    siphash = 6,
    _,
};

/// Compatible feature flags.
///
/// A kernel can still read/write this filesystem even if it doesn't understand a flag; fsck should stop.
pub const CompatibleFeatures = packed struct(u32) {
    /// On directory creation preallocate blocks.
    ///
    /// The `preallocate_directory_blocks` field in the `Superblock` contains the number of blocks to preallocate.
    directory_preallocation: bool,

    /// Used by AFS to indicate inodes that are not linked into the directory namespace.
    ///
    /// Inodes marked with this flag will not be added to lost+found by e2fsck.
    imagic_inodes: bool,

    /// Has a journal
    journal: bool,

    /// Supports extended attributes.
    extended_attributes: bool,

    /// Has reserved GDT blocks for filesystem expansion.
    ///
    /// TODO: Requires RO_COMPAT_SPARSE_SUPER.
    resize_inode: bool,

    /// Has indexed directories.
    directory_indices: bool,

    /// Intended for uninitialized block groups.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    lazy_bg: bool,

    /// Intended for filesystem snapshot feature.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    exclude_inode: bool,

    /// Intended for filesystem snapshot feature.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    exclude_bitmap: bool,

    /// If this flag is set then this filesystem only has two backup superblocks.
    ///
    /// The `block_groups_with_backup_superblocks` field in the `Superblock` contains the two block groups that
    /// contain backup superblocks.
    sparse_superblock_v2: bool,

    /// Fast commits supported.
    ///
    /// The file system only becomes incompatible if fast commit blocks are present in the file system.
    ///
    /// Since the journal (and thus the fast commit blocks) are cleared, the filesystem does not need to be
    /// marked as incompatible.
    fast_commit: bool,

    /// inode numbers should not change when the filesystem is resized.
    stable_inodes: bool,

    /// Orphan file allocated.
    ///
    /// This is a special file for more efficient tracking of unlinked but still open inodes.
    ///
    /// TODO: When there may be many entries in the file, we additionally set proper rocompat
    /// feature RO_COMPAT_ORPHAN_PRESENT
    orphan_file: bool,

    _unused: u19 = 0,

    pub fn hasUnknownBits(self: CompatibleFeatures) bool {
        return self._unused != 0;
    }
};

/// Incompatible feature flags.
///
/// If the kernel or fsck doesn't understand one of these flags, it should stop.
pub const IncompatibleFeatures = packed struct(u32) {
    /// Compression.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    compression: bool,

    /// Directory entries record the file type.
    filetype: bool,

    /// Filesystem needs recovery.
    recover: bool,

    /// Filesystem has a separate journal device.
    journal_device: bool,

    /// A meta-block group is a collection of block groups which can be described by a single block group
    /// descriptor block.
    meta_block_groups: bool,

    _unused1: bool = false,

    /// Files in this filesystem use extents.
    extents: bool,

    /// Enable a filesystem size of 2^64 blocks.
    @"64bit": bool,

    /// Multiple mount protection.
    ///
    /// Prevent multiple hosts from mounting the filesystem concurrently by updating a reserved block periodically
    /// while mounted and checking this at mount time to determine if the filesystem is in use on another host.
    multiple_mount_protection: bool,

    /// In a flexible block group, several block groups are tied together as one logical block group;
    /// the bitmap spaces and the inode table space in the first block group of the flex_bg are expanded to include
    /// the bitmaps and inode tables of all other block groups in the flex_bg.
    flexible_block_groups: bool,

    /// Inodes can be used to store large extended attribute values.
    extended_attribute_inode: bool,

    _unused2: bool = false,

    /// Data in directory entry.
    directory_data: bool,

    /// Metadata checksum seed is stored in the superblock.
    checksum_seed: bool,

    /// Large directory >2GB or 3-level htree.
    ///
    /// Prior to this feature, directories could not be larger than 4GiB and could not have an htree more than
    /// 2 levels deep.
    ///
    /// If this feature is enabled, directories can be larger than 4GiB and have a maximum htree depth of 3.
    large_directory: bool,

    /// Data in inode.
    inline_data: bool,

    /// Encrypted inodes are present on the filesystem.
    encypted: bool,

    /// Casefold filenames.
    ///
    /// Case insensitive handling of file names.
    casefold: bool,

    _unused3: u14 = 0,

    pub fn hasUnknownBits(self: IncompatibleFeatures) bool {
        return self._unused1 or self._unused2 or self._unused3 != 0;
    }
};

/// Readonly compatible feature flags.
///
/// If the kernel doesn't understand one of these flags, it can still mount read-only.
pub const ReadOnlyFeatures = packed struct(u32) {
    /// Sparse superblocks.
    ///
    /// Backup copies of the superblock and group descriptors are kept only in the groups whose group number
    /// is either 0 or a power of 3, 5, or 7.
    sparse_superblocks: bool,

    /// This filesystem has been used to store a file greater than 2GiB.
    large_file: bool,

    /// Intended for htrees.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    btree_directory: bool,

    /// This filesystem has files whose sizes are represented in units of logical blocks, not 512-byte sectors.
    ///
    /// TODO: Inodes using this feature will be marked with EXT4_INODE_HUGE_FILE.
    huge_file: bool,

    /// Group descriptors have checksums.
    ///
    /// Cannot be set when `metadata_checksum` is also set.
    gdt_checksum: bool,

    /// Indicates that the old ext3 32,000 subdirectory limit no longer applies.
    ///
    /// TODO: A directory's i_links_count will be set to 1 if it is incremented past 64,999.
    directory_nlink: bool,

    /// TODO
    /// Indicates that large inodes exist on this filesystem, storing extra fields after EXT2_GOOD_OLD_INODE_SIZE.
    extra_isize: bool,

    /// This filesystem has a snapshot.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    has_snapshot: bool,

    /// Quota is handled transactionally with the journal.
    quota: bool,

    /// This filesystem supports "bigalloc", which means that filesystem block allocation bitmaps are tracked
    /// in units of clusters (of blocks) instead of blocks
    bigalloc: bool,

    /// This filesystem supports metadata checksumming.
    ///
    /// `metadata_checksum` also enables `gdt_checksum`.
    ///
    /// When `metadata_checksum` is set, group descriptor checksums use the same algorithm as all other data
    /// structures' checksums.
    ///
    /// However, the `metadata_checksum` and `gdt_checksum` bits are mutually exclusive.
    metadata_checksum: bool,

    /// Filesystem supports replicas.
    ///
    /// Not implemented in Linux at time of writing so unlikely to be found in the wild.
    replica: bool,

    /// Read-only filesystem image; the kernel will not mount this image read-write and most tools will refuse
    /// to write to the image.
    read_only: bool,

    /// Filesystem tracks project quotas.
    project_quotas: bool,

    _unused1: bool = false,

    /// Verity inodes may be present on the filesystem.
    verity_inodes: bool,

    /// Indicates orphan file may have valid orphan entries and thus we need to clean/ them up when mounting
    /// the filesystem.
    orphan_present: bool,

    _unused2: u15 = 0,

    pub fn hasUnknownBits(self: ReadOnlyFeatures) bool {
        return self._unused1 or self._unused2 != 0;
    }
};

pub const CompressionAlgorithm = enum(u32) {
    _,
};

pub const State = enum(u16) {
    clean = 1,
    errors_detected = 2,
    orphans_being_recovered = 3,

    _,
};

pub const ErrorBehaviour = enum(u16) {
    ignore = 1,
    mount_read_only = 2,
    panic = 3,
    _,
};

pub const Creator = enum(u32) {
    linux = 0,
    hurd = 1,
    masix = 2,
    freebsd = 3,
    lites = 4,
    _,
};

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .Struct => |info| info.decls,
        .Enum => |info| info.decls,
        .Union => |info| info.decls,
        .Opaque => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
