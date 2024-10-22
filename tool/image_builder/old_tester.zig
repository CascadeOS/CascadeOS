// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// !WARNING: This file was used to stumble through building a simple image, it is not used.
//           It has not been deleted as some of the ext2 code will need to be migrated out into image_builder eventually.

const std = @import("std");
const core = @import("core");
const UUID = @import("uuid").UUID;
const fs = @import("fs");

const ext = fs.ext;
const fat = fs.fat;
const gpt = fs.gpt;
const mbr = fs.mbr;

const disk_block_size = core.Size.from(512, .byte);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    try createDiskImage(
        gpa.allocator(),
        "disk_image.hdd",
        core.Size.from(256, .mib),
    );
}

fn createDiskImage(
    allocator: std.mem.Allocator,
    disk_image_path: []const u8,
    disk_size: core.Size,
) !void {
    _ = allocator;
    const disk_image = try createAndMapDiskImage(disk_image_path, disk_size);
    defer std.os.munmap(disk_image);

    var rand = std.rand.DefaultPrng.init(std.crypto.random.int(u64));
    const random = rand.random();
    _ = random;

    const partitions = try createGpt(disk_image, disk_size);

    const efi_partition = disk_image[partitions.efi_start_block * disk_block_size.bytes ..][0 .. partitions.efi_block_count * disk_block_size.bytes];
    const efi_partition_size = core.Size.from(efi_partition.len, .byte);

    try createEfiPartition(efi_partition, efi_partition_size);

    const root_partition = disk_image[partitions.root_start_block * disk_block_size.bytes ..][0 .. partitions.root_block_count * disk_block_size.bytes];
    const root_partition_size = core.Size.from(root_partition.len, .byte);
    _ = root_partition_size;

    //try createRootPartition(allocator, root_partition, root_partition_size);
}

fn createEfiPartition(efi_partition: []u8, efi_partition_size: core.Size) !void {
    const sector_size = disk_block_size;

    const root_cluster = 0x2;
    const number_of_fat = 2;
    const sectors_per_fat = 0x3f1; // TODO: Why 1009?
    const sectors_per_cluster = 1;
    const sectors_per_track = 32;
    const number_of_heads = 16;
    const fsinfo_sector = 1;
    const reserved_sectors = sectors_per_track; // TODO: Is it always one track reserved?

    const number_of_sectors = efi_partition_size.divide(sector_size);

    const bpb = asPtr(*fat.BPB, efi_partition, 0, sector_size);
    bpb.* = fat.BPB{
        // .oem_identifier = [_]u8{ 'C', 'A', 'S', 'C', 'A', 'D', 'E', 0 },
        .oem_identifier = [_]u8{ 'm', 'k', 'f', 's', '.', 'f', 'a', 't' },
        .bytes_per_sector = @intCast(sector_size.bytes),
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .number_of_fats = number_of_fat,
        .number_of_root_directory_entries = 0,
        .number_of_sectors = 0,
        .media_descriptor_type = .fixed_disk,
        .sectors_per_fat = 0,
        .sectors_per_track = sectors_per_track,
        .number_of_heads = number_of_heads,
        .number_of_hidden_sectors = 0x800,
        .large_sector_count = @intCast(number_of_sectors),
    };

    const ebpb: *fat.ExtendedBPB_32 = @ptrFromInt(@intFromPtr(bpb) + @sizeOf(fat.BPB));
    ebpb.* = fat.ExtendedBPB_32{
        .sectors_per_fat = sectors_per_fat,
        .flags = .{
            .active_fat = 0,
            .mode = .each_fat_active_and_mirrored,
        },
        .version = 0,
        .root_cluster = root_cluster,
        .fsinfo_sector = fsinfo_sector,
        .backup_boot_sector = 0x6,
        .drive_number = 0x80,
        .extended_boot_signature = 0x29,
        .volume_id = 0xa96b2625,
        .volume_label = [_]u8{ 'N', 'O', ' ', 'N', 'A', 'M', 'E', ' ', ' ', ' ', ' ' },
    };
    @as(*@TypeOf(ebpb_boot_code), @ptrCast(&ebpb.boot_code)).* = ebpb_boot_code;

    const fsinfo = asPtr(*fat.FSInfo, efi_partition, fsinfo_sector, sector_size);
    fsinfo.* = .{
        .last_known_number_of_free_clusters = 0xFFFFFFFF,
        .most_recently_allocated_cluster = 0xFFFFFFFF,
    };

    const size_of_info = core.Size.from(
        @sizeOf(fat.BPB) + @sizeOf(fat.ExtendedBPB_32) + @sizeOf(fat.FSInfo),
        .byte,
    );

    const four_kib = core.Size.from(4, .kib);

    const padding_before_backup_info = size_of_info
        .alignForward(four_kib)
        .subtract(size_of_info);

    @memcpy(
        efi_partition[padding_before_backup_info.bytes..][0..size_of_info.bytes],
        efi_partition[0..size_of_info.bytes],
    );

    const fat_begin = reserved_sectors;
    const number_of_fat_entries = (sectors_per_fat * sector_size.bytes) / 4;

    const cluster_begin_sector = reserved_sectors + (number_of_fat * sectors_per_fat);

    var context = EFIContext{
        .efi_partition = efi_partition,
        .fat_table = asPtr(
            [*]fat.FAT32Entry,
            efi_partition,
            fat_begin,
            sector_size,
        )[0..number_of_fat_entries],
        .next_cluster = 2,
        .root_cluster = root_cluster,
        .sector_size = sector_size,
        .sectors_per_cluster = sectors_per_cluster,
        .cluster_size = sector_size.multiply(sectors_per_cluster),
        .cluster_begin_sector = cluster_begin_sector,
    };

    // BPB media in lower byte and all ones elsewhere
    context.setFAT(0, @enumFromInt(0xfffff00 | @as(u32, @intFromEnum(bpb.media_descriptor_type))));

    // Reserved entry
    context.setFAT(1, @enumFromInt(0xfffffff));

    try addFilesAndDirectoriesToEfi(&context);

    const backup_fat_table: []fat.FAT32Entry = asPtr(
        [*]fat.FAT32Entry,
        efi_partition,
        fat_begin + sectors_per_fat,
        sector_size,
    )[0..number_of_fat_entries];

    @memcpy(backup_fat_table, context.fat_table);
}

fn addFilesAndDirectoriesToEfi(context: *EFIContext) !void {
    const number_of_directory_entries_per_cluster = context.cluster_size.divide(core.Size.of(fat.DirectoryEntry));

    const creation_date: fat.Date = .{
        .year = 43,
        .month = 7,
        .day = 8,
    };
    const creation_time: fat.Time = .{
        .hour = 14,
        .minute = 58,
        .second_2s = 28,
    };
    const creation_datetime_subsecond: u8 = 0x38;

    const root_cluster = context.nextCluster();
    std.debug.assert(root_cluster == context.root_cluster);

    const root_directory_ptr: [*]fat.DirectoryEntry = @ptrCast(context.clusterSlice(root_cluster, 1).ptr);
    const root_directory: []fat.DirectoryEntry = root_directory_ptr[0..number_of_directory_entries_per_cluster];
    var root_directory_index: usize = 0;

    var efi_directory_cluster: u32 = 0;
    var cascade_directory_cluster: u32 = 0;

    // root directory
    {
        context.setFAT(root_cluster, fat.FAT32Entry.end_of_chain);

        efi_directory_cluster = context.nextCluster();

        root_directory[root_directory_index] = .{
            .standard = .{
                .short_file_name = .{
                    .name = [_]u8{ 'E', 'F', 'I', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(efi_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(efi_directory_cluster),
                .size = 0,
            },
        };
        root_directory_index += 1;

        cascade_directory_cluster = context.nextCluster();

        root_directory[root_directory_index] = .{
            .standard = .{
                .short_file_name = .{
                    .name = [_]u8{ 'C', 'A', 'S', 'C', 'A', 'D', 'E', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(cascade_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(cascade_directory_cluster),
                .size = 0,
            },
        };
        root_directory_index += 1;
    }

    const cascade_directory_ptr: [*]fat.DirectoryEntry = @ptrCast(
        context.clusterSlice(cascade_directory_cluster, 1).ptr,
    );
    const cascade_directory = cascade_directory_ptr[0..number_of_directory_entries_per_cluster];
    var cascade_directory_index: usize = 0;

    // cascade directory
    {
        context.setFAT(cascade_directory_cluster, fat.FAT32Entry.end_of_chain);

        // '.' directory
        cascade_directory[cascade_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(cascade_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(cascade_directory_cluster),
                .size = 0,
            },
        };
        cascade_directory_index += 1;

        // '..' directory
        cascade_directory[cascade_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(root_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(root_cluster),
                .size = 0,
            },
        };
        cascade_directory_index += 1;
    }

    // kernel
    {
        const short_file_name: fat.ShortFileName = .{
            .name = [_]u8{ 'K', 'E', 'R', 'N', 'E', 'L', ' ', ' ' },
            .extension = [_]u8{ ' ', ' ', ' ' },
        };

        cascade_directory[cascade_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = short_file_name,
                .attributes = .{
                    .archive = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = 0, // initialized by `copyFile`
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = 0, // initialized by `copyFile`
                .size = 0, // initialized by `copyFile`
            },
        };
        try context.copyFile(
            &cascade_directory[cascade_directory_index].standard,
            "/home/lee/src/CascadeOS/zig-cache/limine/BOOTX64.EFI",
        );
        cascade_directory_index += 1;
    }

    const efi_directory_ptr: [*]fat.DirectoryEntry = @ptrCast(
        context.clusterSlice(efi_directory_cluster, 1).ptr,
    );
    const efi_directory = efi_directory_ptr[0..number_of_directory_entries_per_cluster];
    var efi_directory_index: usize = 0;

    var efi_boot_directory_cluster: u32 = 0;

    // EFI directory
    {
        context.setFAT(efi_directory_cluster, fat.FAT32Entry.end_of_chain);

        // '.' directory
        efi_directory[efi_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(efi_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(efi_directory_cluster),
                .size = 0,
            },
        };
        efi_directory_index += 1;

        // '..' directory
        efi_directory[efi_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(root_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(root_cluster),
                .size = 0,
            },
        };
        efi_directory_index += 1;

        // "/EFI/BOOT" directory
        efi_boot_directory_cluster = context.nextCluster();
        efi_directory[efi_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ 'B', 'O', 'O', 'T', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(efi_boot_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(efi_boot_directory_cluster),
                .size = 0,
            },
        };
        efi_directory_index += 1;
    }

    const efi_boot_directory_ptr: [*]fat.DirectoryEntry = @ptrCast(
        context.clusterSlice(efi_boot_directory_cluster, 1).ptr,
    );
    const efi_boot_directory = efi_boot_directory_ptr[0..number_of_directory_entries_per_cluster];
    var efi_boot_directory_index: usize = 0;

    // EFI Boot directory
    {
        context.setFAT(efi_boot_directory_cluster, fat.FAT32Entry.end_of_chain);

        // '.' directory
        efi_boot_directory[efi_boot_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(efi_boot_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(efi_boot_directory_cluster),
                .size = 0,
            },
        };
        efi_boot_directory_index += 1;

        // '..' directory
        efi_boot_directory[efi_boot_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = .{
                    .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
                },
                .attributes = .{
                    .directory = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = @truncate(efi_directory_cluster >> 16),
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = @truncate(efi_directory_cluster),
                .size = 0,
            },
        };
        efi_boot_directory_index += 1;
    }

    // limine.conf
    {
        const short_file_name: fat.ShortFileName = .{
            .name = [_]u8{ 'L', 'I', 'M', 'I', 'N', 'E', ' ', ' ' },
            .extension = [_]u8{ 'C', 'O', 'N' },
        };

        root_directory[root_directory_index] = fat.DirectoryEntry{
            .long_file_name = fat.DirectoryEntry.LongFileNameEntry{
                .sequence_number = 1 | fat.DirectoryEntry.LongFileNameEntry.last_entry,
                .first_characters = [_]u16{ 'l', 'i', 'm', 'i', 'n' },
                .checksum_of_short_name = short_file_name.checksum(),
                .middle_characters = [_]u16{ 'e', '.', 'c', 'o', 'n', 'f' },
            },
        };
        root_directory_index += 1;

        root_directory[root_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = short_file_name,
                .attributes = .{
                    .archive = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = 0, // initialized by `copyFile`
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = 0, // initialized by `copyFile`
                .size = 0, // initialized by `copyFile`
            },
        };
        try context.copyFile(
            &root_directory[root_directory_index].standard,
            "/home/lee/src/CascadeOS/build/limine.cfg",
        );
        root_directory_index += 1;
    }

    // BOOTX64.EFI
    {
        const short_file_name: fat.ShortFileName = .{
            .name = [_]u8{ 'B', 'O', 'O', 'T', 'X', '6', '4', ' ' },
            .extension = [_]u8{ 'E', 'F', 'I' },
        };

        efi_boot_directory[efi_boot_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = short_file_name,
                .attributes = .{
                    .archive = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = 0, // initialized by `copyFile`
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = 0, // initialized by `copyFile`
                .size = 0, // initialized by `copyFile`
            },
        };
        try context.copyFile(
            &efi_boot_directory[efi_boot_directory_index].standard,
            "/home/lee/src/CascadeOS/zig-cache/limine/BOOTX64.EFI",
        );
        efi_boot_directory_index += 1;
    }

    // limine-bios.sys
    {
        const short_file_name: fat.ShortFileName = .{
            .name = [_]u8{ 'L', 'I', 'M', 'I', 'N', 'E', '~', '1' },
            .extension = [_]u8{ 'S', 'Y', 'S' },
        };

        root_directory[root_directory_index] = fat.DirectoryEntry{
            .long_file_name = fat.DirectoryEntry.LongFileNameEntry{
                .sequence_number = 2 | fat.DirectoryEntry.LongFileNameEntry.last_entry,
                .first_characters = [_]u16{ 'y', 's', 0, 0xFFFF, 0xFFFF },
                .checksum_of_short_name = short_file_name.checksum(),
            },
        };
        root_directory_index += 1;

        root_directory[root_directory_index] = fat.DirectoryEntry{
            .long_file_name = fat.DirectoryEntry.LongFileNameEntry{
                .sequence_number = 1,
                .first_characters = [_]u16{ 'l', 'i', 'm', 'i', 'n' },
                .checksum_of_short_name = short_file_name.checksum(),
                .middle_characters = [_]u16{ 'e', '-', 'b', 'i', 'o', 's' },
                .final_characters = [_]u16{ '.', 's' },
            },
        };
        root_directory_index += 1;

        root_directory[root_directory_index] = fat.DirectoryEntry{
            .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                .short_file_name = short_file_name,
                .attributes = .{
                    .archive = true,
                },
                .creation_datetime_subsecond = creation_datetime_subsecond,
                .creation_time = creation_time,
                .creation_date = creation_date,
                .last_accessed_date = creation_date,
                .high_cluster_number = 0, // initialized by `copyFile`
                .last_modification_time = creation_time,
                .last_modification_date = creation_date,
                .low_cluster_number = 0, // initialized by `copyFile`
                .size = 0, // initialized by `copyFile`
            },
        };
        try context.copyFile(
            &root_directory[root_directory_index].standard,
            "/home/lee/src/CascadeOS/zig-cache/limine/limine-bios.sys",
        );
        root_directory_index += 1;
    }
}

const EFIContext = struct {
    efi_partition: []u8,

    fat_table: []FAT32Entry,
    next_cluster: u32,

    root_cluster: u32,

    sector_size: core.Size,
    sectors_per_cluster: u32,
    cluster_size: core.Size,

    cluster_begin_sector: u32,

    pub const FAT32Entry = fat.FAT32Entry;

    pub fn copyFile(
        self: *EFIContext,
        entry: *fat.DirectoryEntry.StandardDirectoryEntry,
        path: []const u8,
    ) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        const file_size = core.Size.from(stat.size, .byte);
        const clusters_required = self.cluster_size.amountToCover(file_size);
        std.debug.assert(clusters_required != 0);

        var current_cluster = self.nextCluster();

        entry.high_cluster_number = @truncate(current_cluster >> 16);
        entry.low_cluster_number = @truncate(current_cluster);
        entry.size = @intCast(stat.size);

        var i: usize = 0;

        while (i < clusters_required) : (i += 1) {
            const cluster_ptr = self.clusterSlice(current_cluster, 1);
            const read = try file.readAll(cluster_ptr);

            const is_last_cluster = i == clusters_required - 1;

            // only for the last cluster will the amount read be less than a full cluster
            std.debug.assert(read == cluster_ptr.len or is_last_cluster);

            if (is_last_cluster) {
                self.setFAT(current_cluster, fat.FAT32Entry.end_of_chain);
            } else {
                const next_cluster = self.nextCluster();
                self.setFAT(current_cluster, @enumFromInt(next_cluster));
                current_cluster = next_cluster;
            }
        }
    }

    pub fn clusterSlice(
        self: EFIContext,
        cluster_index: u32,
        number_of_clusters: usize,
    ) []u8 {
        const start = self.cluster_begin_sector + (cluster_index - 2) * self.sectors_per_cluster;
        const size = self.sector_size.multiply(self.sectors_per_cluster * number_of_clusters);
        return asPtr([*]u8, self.efi_partition, start, self.sector_size)[0..size.bytes];
    }

    pub fn nextCluster(self: *EFIContext) u32 {
        const cluster = self.next_cluster;
        self.next_cluster += 1;
        return cluster;
    }

    pub fn setFAT(self: *EFIContext, index: u32, entry: FAT32Entry) void {
        self.fat_table[index] = entry;
    }

    pub fn getFAT(self: EFIContext, index: u32) FAT32Entry {
        return self.fat_table[index];
    }
};

const ExtContext = struct {
    allocator: std.mem.Allocator,

    ext_partition: []u8,
    block_size: core.Size,

    block_groups: std.ArrayListUnmanaged(BlockGroup) = .{},

    pub fn extBlockSlice(
        self: ExtContext,
        block_index: u32,
        number_of_blocks: usize,
    ) []u8 {
        const size = self.block_size.multiply(number_of_blocks);
        return asPtr([*]u8, self.ext_partition, block_index, self.block_size)[0..size.bytes];
    }

    pub const BlockGroup = struct {
        descriptor: *align(1) ext.BlockGroupDescriptor,

        block_bitmap: []u8,
        total_blocks: u64,
        free_blocks: u64,
        first_block: u64,

        inode_table: []u8,
        inode_bitmap: []u8,
        total_inodes: u64,
        free_inodes: u64,
        first_inode: u64,

        used_directory_count: u64,

        pub fn markInodeInUse(self: *BlockGroup, inode: u64) void {
            const last_inode = self.first_inode + self.total_inodes - 1;
            if (inode < self.first_inode or inode > last_inode) @panic("inode is out of bounds of this block group");

            const inode_index = inode - self.first_inode;
            const bitmap_index = inode_index / 8;
            const bit_index: u3 = @intCast(inode_index % 8);
            const mask = @as(u8, 1) << bit_index;
            const bitmap = &self.inode_bitmap[bitmap_index];
            std.debug.assert(bitmap.* & mask == 0); // inode should not already be allocated
            bitmap.* |= mask;
        }

        pub fn markBlockInUse(self: *BlockGroup, block: u64) void {
            const last_block = self.first_block + self.total_blocks - 1;
            if (block < self.first_block or block > last_block) @panic("block is out of bounds of this block group");

            const block_index = block - self.first_block;
            const bitmap_index = block_index / 8;
            const bit_index: u3 = @intCast(block_index % 8);
            const mask = @as(u8, 1) << bit_index;
            const bitmap = &self.block_bitmap[bitmap_index];
            std.debug.assert(bitmap.* & mask == 0); // block should not already be allocated
            bitmap.* |= mask;
        }
    };
};

fn createRootPartition(allocator: std.mem.Allocator, root_partition: []u8, root_partition_size: core.Size) !void {
    const block_size = core.Size.from(4096, .byte); // TODO
    const block_count: u64 = block_size.amountToCover(root_partition_size);

    const size_of_block_group_descriptor = core.Size.from(32, .byte); // TODO

    const first_non_reserved_inode: u32 = 11;
    const blocks_per_group: u32 = 0x8000; // TODO: Calculate
    const inodes_per_group: u32 = 0x5f00; // TODO: Calculate, 8 * bytes in block

    const reserved_block_count: u64 = 0x980; // TODO: Calculate

    var ext_context: ExtContext = .{
        .allocator = allocator,
        .ext_partition = root_partition,
        .block_size = block_size,
    };

    const block_containing_superblock: u32 = @intCast(ext.superblock_offset / block_size.bytes);
    const block_containing_block_group_descriptor_table = block_containing_superblock + 1;
    const first_block_group_block = block_containing_superblock + 2;

    const raw_block_group_descriptor_table = ext_context.extBlockSlice(
        block_containing_block_group_descriptor_table,
        1,
    );

    {
        // block bitmap, inode bitmap, inode table, one data block.
        const minimum_blocks_for_block_group = 4;

        var blocks_left_to_cover: u64 = block_count - first_block_group_block;
        var block_number: u32 = 0;

        while (blocks_left_to_cover > minimum_blocks_for_block_group) {
            const first_block_of_block_group = first_block_group_block + (block_number * blocks_per_group);
            const first_inode = 1 + (block_number * inodes_per_group);

            const block_bitmap_block = first_block_of_block_group;
            const inode_bitmap_block = first_block_of_block_group + 1;
            const inode_table_block = first_block_of_block_group + 2;

            const descriptor: *align(1) ext.BlockGroupDescriptor =
                @ptrCast(&raw_block_group_descriptor_table[block_number * size_of_block_group_descriptor.bytes]);

            descriptor.block_bitmap_low = @intCast(block_bitmap_block);
            descriptor.inode_bitmap_low = @intCast(inode_bitmap_block);
            descriptor.inode_table_low = @intCast(inode_table_block);

            const number_of_blocks = if (blocks_left_to_cover > blocks_per_group)
                blocks_per_group
            else
                blocks_left_to_cover;

            try ext_context.block_groups.append(ext_context.allocator, ExtContext.BlockGroup{
                .descriptor = descriptor,

                .block_bitmap = ext_context.extBlockSlice(block_bitmap_block, 1),
                .total_blocks = number_of_blocks,
                .free_blocks = number_of_blocks,
                .first_block = first_block_of_block_group,

                .inode_table = ext_context.extBlockSlice(inode_table_block, 1),
                .inode_bitmap = ext_context.extBlockSlice(inode_bitmap_block, 1),
                .total_inodes = inodes_per_group,
                .free_inodes = inodes_per_group,
                .first_inode = first_inode,

                .used_directory_count = 0,
            });

            block_number += 1;
            blocks_left_to_cover -= number_of_blocks;
        }
    }

    // Mark reserved inodes as in use
    {
        // The reserved inodes should all fit in the first block group
        std.debug.assert(first_non_reserved_inode < inodes_per_group);

        const first_block_group = &ext_context.block_groups.items[0];

        var inode: u32 = 1;
        while (inode < first_non_reserved_inode) : (inode += 1) {
            first_block_group.markInodeInUse(inode);
        }
    }

    // Mark reserved blocks as in use
    {
        // The reserved blocks should all fit in the first block group
        std.debug.assert(reserved_block_count < blocks_per_group);

        const first_block_group = &ext_context.block_groups.items[0];

        const start_block = first_block_group.first_block;

        var i: u64 = 0;
        while (i < reserved_block_count) : (i += 1) {
            first_block_group.markBlockInUse(start_block + i);
        }
    }

    // TODO: Fill the block groups

    for (ext_context.block_groups.items) |block_group| {
        const descriptor: *align(1) ext.BlockGroupDescriptor = block_group.descriptor;
        descriptor.free_block_count_low = @intCast(block_group.free_blocks);
        descriptor.free_inode_count_low = @intCast(block_group.free_inodes);
        descriptor.used_directory_count_low = @intCast(block_group.used_directory_count);
    }

    const block_size_shift: u32 = @intCast(std.math.log2(block_size.bytes) - 10);

    // ext seems to use a different UUID output in debugfs?
    const filesystem_uuid = try UUID.parse("0f48c0eb-e12c-1749-8b51-d4961c65b80e");

    const creation_time: u64 = 0x64b2d011; // TODO: Calculate

    const hash_seed = [_]u32{
        0x53bab856,
        0xd84fd88f,
        0xf7af09a1,
        0x2a41a276,
    };

    const inode_count: u32 = 0xbe00; // TODO: Calculate

    const free_block_count: u64 = 0xb213; // TODO: Calculate
    const free_inode_count: u32 = 0xbdf5; // TODO: Calculate
    const first_data_block: u32 = 0; // TODO: Calculate

    const overhead_blocks: u32 = 0xbe8;

    const minimum_inode_size: u16 = 0x20;
    const inode_reservation_size: u16 = 0x20;
    const inode_size: u16 = 0x100;

    const default_mount_options: ext.MountOptions = .{
        .user_extended_attributes = true,
        .acl = true,
    };

    const superblock = asPtr(*ext.Superblock, root_partition, 1, core.Size.of(ext.Superblock));

    // The memory of `root_partition` is assumed to be zeroed.
    // If any `@intCast` below are tripped then the 64-bit feature needs to be implemented.

    superblock.inode_count = inode_count;
    superblock.block_count_low = @intCast(block_count);
    superblock.reserved_block_count_low = @intCast(reserved_block_count);
    superblock.free_block_count_low = @intCast(free_block_count);
    superblock.free_inode_count = free_inode_count;
    superblock.first_data_block = first_data_block;
    superblock.block_size_shift = block_size_shift;
    superblock.fragment_size_shift = block_size_shift; // Same as blocks
    superblock.blocks_per_group = blocks_per_group;
    superblock.fragments_per_group = blocks_per_group; // Same as blocks
    superblock.inodes_per_group = inodes_per_group;
    superblock.last_write_time_low = @intCast(creation_time);
    superblock.max_mounts_before_check = 0xFFFF;
    superblock.signature = ext.signature;
    superblock.state = .clean;
    superblock.error_behaviour = .ignore;
    superblock.last_check_time_low = @intCast(creation_time);
    superblock.major_version = 1;
    superblock.first_non_reserved_inode = first_non_reserved_inode;
    superblock.inode_size = inode_size;
    superblock.superblock_group = @intCast(block_containing_superblock);
    superblock.read_only_features.sparse_superblocks = true;
    superblock.filesystem_id = filesystem_uuid;
    superblock.hash_seed = hash_seed;
    superblock.hash_algorithm = .half_md4;
    superblock.default_mount_options = default_mount_options;
    superblock.creation_time_low = @intCast(creation_time);
    superblock.minimum_inode_size = minimum_inode_size;
    superblock.inode_reservation_size = inode_reservation_size;
    superblock.misc_flags.signed_directory_hash = true;
    superblock.overhead_blocks = overhead_blocks;

    // TODO: Backup copies of superblock and block group descriptors
}

const Partitions = struct {
    partition_table_crc: u32,

    efi_start_block: u64,
    efi_block_count: u64,

    root_start_block: u64,
    root_block_count: u64,
};

fn createGpt(
    disk_image: []u8,
    disk_size: core.Size,
) !Partitions {
    std.debug.assert(disk_size.isAligned(disk_block_size));

    const number_of_blocks = disk_size.divide(disk_block_size);

    const number_of_partition_entries = gpt.minimum_number_of_partition_entries;

    const partition_array_size_in_blocks: u64 = disk_block_size.amountToCover(
        gpt.PartitionEntry.size.multiply(number_of_partition_entries),
    );

    const first_usable_block = 2 + partition_array_size_in_blocks;

    const last_usable_block = number_of_blocks - 2 - partition_array_size_in_blocks;

    // Block 0 = Protective MBR
    protectiveMBR(disk_image, number_of_blocks);

    // Block 2 = Primary Partition Entry Array
    const entries: []gpt.PartitionEntry = asPtr(
        [*]gpt.PartitionEntry,
        disk_image,
        2,
        disk_block_size,
    )[0..number_of_partition_entries];

    const partitions = try fillInPartitionEntryArray(
        entries,
        first_usable_block,
        last_usable_block,
    );

    const disk_guid = try UUID.parse("F3621130-EAB9-4BB5-9398-409BE1E8EC3E");
    // const disk_guid = UUID.generateV4(random);

    // Block 1 = Primary GPT Header
    const primary_header = fillInPrimaryGptHeader(
        disk_image,
        number_of_blocks,
        first_usable_block,
        last_usable_block,
        disk_guid,
        number_of_partition_entries,
        partitions.partition_table_crc,
    );

    // Block (NUM - 1) = Backup GPT Header
    const backup_header = asPtr(
        *gpt.Header,
        disk_image,
        number_of_blocks - 1,
        disk_block_size,
    );
    primary_header.copyToOtherHeader(backup_header, partition_array_size_in_blocks);

    // Block (NUM - 1 - number of partition entries) =Backup Partition Entry Array
    const backup_partition_entry_array: []gpt.PartitionEntry = asPtr(
        [*]gpt.PartitionEntry,
        disk_image,
        backup_header.partition_entry_lba,
        disk_block_size,
    )[0..number_of_partition_entries];
    @memcpy(backup_partition_entry_array, entries);

    return partitions;
}

fn protectiveMBR(disk_image: []u8, number_of_blocks: usize) void {
    const mbr_ptr = asPtr(
        *mbr.MBR,
        disk_image,
        0,
        disk_block_size,
    );
    gpt.protectiveMBR(mbr_ptr, number_of_blocks);
}

fn fillInPrimaryGptHeader(
    disk_image: []u8,
    number_of_blocks: usize,
    first_usable_block: usize,
    last_usable_block: usize,
    guid: UUID,
    number_of_partition_entries: u32,
    partition_table_crc: u32,
) *gpt.Header {
    const primary_header: *gpt.Header = asPtr(
        *gpt.Header,
        disk_image,
        1,
        disk_block_size,
    );
    primary_header.* = gpt.Header{
        .my_lba = 1,
        .alternate_lba = number_of_blocks - 1,
        .first_usable_lba = first_usable_block,
        .last_usable_lba = last_usable_block,
        .disk_guid = guid,
        .partition_entry_lba = 2,
        .number_of_partition_entries = number_of_partition_entries,
        .size_of_partition_entry = @intCast(gpt.PartitionEntry.size.bytes),
        .partition_entry_array_crc32 = partition_table_crc,
    };
    primary_header.updateHash();
    return primary_header;
}

fn fillInPartitionEntryArray(
    entries: []gpt.PartitionEntry,
    first_usable_block: usize,
    last_usable_block: usize,
) !Partitions {
    // EFI Partition
    fillInPartitionEntry(
        &entries[0],
        gpt.partition_types.efi_system_partition,
        try UUID.parse("025DB01E-1C6D-4F3A-B83C-7DE130198E51"),
        disk_block_size.amountToCover(core.Size.from(64, .mib)),
        first_usable_block,
        last_usable_block,
        "ESP",
    );

    const block_after_efi = entries[0].ending_lba + 1;

    // Root Partition
    fillInPartitionEntry(
        &entries[1],
        gpt.partition_types.linux_filesystem_data,
        try UUID.parse("D7B29C2A-A857-41F7-9E44-C5C4BC690BA5"),
        last_usable_block - block_after_efi + 1,
        block_after_efi,
        last_usable_block,
        "ROOT",
    );

    const entry_bytes = std.mem.sliceAsBytes(entries);

    return Partitions{
        .partition_table_crc = gpt.Crc32.hash(entry_bytes),
        .efi_start_block = entries[0].starting_lba,
        .efi_block_count = (entries[0].ending_lba - entries[0].starting_lba) + 1,
        .root_start_block = entries[1].starting_lba,
        .root_block_count = (entries[1].ending_lba - entries[1].starting_lba) + 1,
    };
}

fn fillInPartitionEntry(
    entry: *gpt.PartitionEntry,
    type_guid: UUID,
    partition_guid: UUID,
    requested_partition_size_in_blocks: usize,
    first_usable_block: usize,
    last_usable_block: usize,
    comptime partition_name: []const u8,
) void {
    const partition_alignment = gpt.recommended_alignment_of_partitions.divide(disk_block_size);

    const starting_block = std.mem.alignForward(usize, first_usable_block, partition_alignment);

    const ending_block = blk: {
        const naive_ending_block = starting_block + requested_partition_size_in_blocks - 1;

        if (naive_ending_block < last_usable_block) break :blk naive_ending_block;

        const align_backward_ending_block = std.mem.alignBackward(usize, naive_ending_block, partition_alignment) - 1;
        if (align_backward_ending_block < last_usable_block) break :blk align_backward_ending_block;

        break :blk last_usable_block;
    };

    if (ending_block < starting_block) @panic("ending block is less than starting block");

    entry.* = gpt.PartitionEntry{
        .partition_type_guid = type_guid,
        .unique_partition_guid = partition_guid,
        .starting_lba = starting_block,
        .ending_lba = ending_block,
    };

    const encoded_name = comptime blk: {
        const name = if (partition_name.len == 0 or partition_name[partition_name.len - 1] != '\x00')
            partition_name ++ "\x00"
        else
            partition_name;

        break :blk std.unicode.utf8ToUtf16LeStringLiteral(name);
    };
    @memcpy(entry.partition_name[0..encoded_name.len], encoded_name);
}

fn createAndMapDiskImage(disk_image_path: []const u8, disk_size: core.Size) ![]align(std.mem.page_size) u8 {
    const file = try std.fs.cwd().createFile(disk_image_path, .{ .truncate = true, .read = true });
    defer file.close();

    try file.setEndPos(disk_size.bytes);

    return try std.os.mmap(
        null,
        disk_size.bytes,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.SHARED,
        file.handle,
        0,
    );
}

inline fn asPtr(comptime T: type, file_contents: []u8, index: usize, item_size: core.Size) T {
    return @ptrCast(@alignCast(file_contents.ptr + (index * item_size.bytes)));
}

const ebpb_boot_code = [_]u8{
    0x0e, 0x1f, 0xbe, 0x77,
    0x7c, 0xac, 0x22, 0xc0,
    0x74, 0x0b, 0x56, 0xb4,
    0x0e, 0xbb, 0x07, 0x00,
    0xcd, 0x10, 0x5e, 0xeb,
    0xf0, 0x32, 0xe4, 0xcd,
    0x16, 0xcd, 0x19, 0xeb,
    0xfe, 0x54, 0x68, 0x69,
    0x73, 0x20, 0x69, 0x73,
    0x20, 0x6e, 0x6f, 0x74,
    0x20, 0x61, 0x20, 0x62,
    0x6f, 0x6f, 0x74, 0x61,
    0x62, 0x6c, 0x65, 0x20,
    0x64, 0x69, 0x73, 0x6b,
    0x2e, 0x20, 0x20, 0x50,
    0x6c, 0x65, 0x61, 0x73,
    0x65, 0x20, 0x69, 0x6e,
    0x73, 0x65, 0x72, 0x74,
    0x20, 0x61, 0x20, 0x62,
    0x6f, 0x6f, 0x74, 0x61,
    0x62, 0x6c, 0x65, 0x20,
    0x66, 0x6c, 0x6f, 0x70,
    0x70, 0x79, 0x20, 0x61,
    0x6e, 0x64, 0x0d, 0x0a,
    0x70, 0x72, 0x65, 0x73,
    0x73, 0x20, 0x61, 0x6e,
    0x79, 0x20, 0x6b, 0x65,
    0x79, 0x20, 0x74, 0x6f,
    0x20, 0x74, 0x72, 0x79,
    0x20, 0x61, 0x67, 0x61,
    0x69, 0x6e, 0x20, 0x2e,
    0x2e, 0x2e, 0x20, 0x0d,
    0x0a,
};
