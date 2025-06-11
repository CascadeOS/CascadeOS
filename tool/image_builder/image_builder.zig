// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const disk_block_size: core.Size = .from(512, .byte);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const arguments = try getArguments(allocator);
    defer arguments.deinit(allocator);

    var rand = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const random = rand.random();

    try createDiskImage(allocator, arguments, random);
}

const Arguments = struct {
    output_path: []const u8,
    image_description: *ImageDescription.Parsed,

    pub fn deinit(arguments: Arguments, allocator: std.mem.Allocator) void {
        allocator.free(arguments.output_path);
        arguments.image_description.deinit();
        allocator.destroy(arguments.image_description);
    }
};

fn usageError(err_msg: []const u8) noreturn {
    const usage =
        \\Usage: image_builder [image_description_path|-] output_path
        \\
    ;

    std.debug.print(comptime "{s}\n\n" ++ usage, .{err_msg});
    std.process.exit(1);
}

fn getArguments(allocator: std.mem.Allocator) !Arguments {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) { // first argument is the executable name
        usageError("incorrect number of arguments given");
    }

    const output_path = try allocator.dupe(u8, args[2]);
    errdefer allocator.free(output_path);

    const image_description_contents = blk: {
        if (std.mem.eql(u8, args[1], "-")) {
            break :blk try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        }

        const image_description_file = try std.fs.cwd().openFile(args[1], .{});
        defer image_description_file.close();

        break :blk try image_description_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(image_description_contents);

    const image_description = try allocator.create(ImageDescription.Parsed);
    errdefer allocator.destroy(image_description);
    image_description.* = try ImageDescription.parse(allocator, image_description_contents);

    return .{
        .output_path = output_path,
        .image_description = image_description,
    };
}

fn createDiskImage(allocator: std.mem.Allocator, arguments: Arguments, random: std.Random) !void {
    const image_description = arguments.image_description.image_description;

    const disk_size = blk: {
        if (!std.mem.isAligned(image_description.size, disk_block_size.value)) {
            @panic("image size is not a multiple of 512 bytes");
        }
        break :blk core.Size.from(image_description.size, .byte);
    };

    const disk_image = try createAndMapDiskImage(arguments.output_path, disk_size);
    defer std.posix.munmap(disk_image);

    const gpt_partitions = try allocator.alloc(GptPartition, image_description.partitions.len);
    defer allocator.free(gpt_partitions);

    try createGpt(allocator, image_description, disk_image, random, gpt_partitions);

    for (image_description.partitions, gpt_partitions) |partition, gpt_partition| {
        const partition_slice = disk_image[gpt_partition.start_block * disk_block_size.value ..][0 .. gpt_partition.block_count * disk_block_size.value];

        switch (partition.filesystem) {
            .fat32 => try buildFATPartition(allocator, partition, partition_slice),
        }
    }
}

fn buildFATPartition(allocator: std.mem.Allocator, partition: ImageDescription.Partition, slice: []u8) !void {
    const sector_size = disk_block_size;

    const root_cluster = 2;
    const number_of_fat = 2;
    const sectors_per_fat = 0x3f1; // TODO: Why 1009?
    const sectors_per_cluster = 1;
    const sectors_per_track = 32;
    const number_of_heads = 16;
    const fsinfo_sector = 1;
    const reserved_sectors = sectors_per_track; // TODO: Is it always one track reserved?

    const number_of_sectors = core.Size.from(slice.len, .byte).divide(sector_size).value;
    const number_of_clusters: u32 = @intCast(number_of_sectors / sectors_per_cluster);

    const bpb = asPtr(*fat.BPB, slice, 0, sector_size);
    bpb.* = fat.BPB{
        .oem_identifier = [_]u8{ 'C', 'A', 'S', 'C', 'A', 'D', 'E', 0 },
        .bytes_per_sector = @intCast(sector_size.value),
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
        .volume_id = 0xa96b2625, // TODO
        .volume_label = [_]u8{ 'N', 'O', ' ', 'N', 'A', 'M', 'E', ' ', ' ', ' ', ' ' }, // TODO
    };
    const boot_code_ptr: *@TypeOf(ebpb_boot_code) = @ptrCast(&ebpb.boot_code);
    boot_code_ptr.* = ebpb_boot_code;

    const fsinfo = asPtr(*fat.FSInfo, slice, fsinfo_sector, sector_size);
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
        slice[padding_before_backup_info.value..][0..size_of_info.value],
        slice[0..size_of_info.value],
    );

    const fat_begin = reserved_sectors;
    const number_of_fat_entries = (sectors_per_fat * sector_size.value) / 4;

    const cluster_begin_sector = reserved_sectors + (number_of_fat * sectors_per_fat);

    var context = FATContext.init(
        slice,
        fat_begin,
        number_of_fat_entries,
        sector_size,
        root_cluster,
        sectors_per_cluster,
        cluster_begin_sector,
        number_of_clusters,
    );

    // BPB media in lower byte and all ones elsewhere
    context.setFAT(0, @enumFromInt(0xfffff00 | @as(u32, @intFromEnum(bpb.media_descriptor_type))));

    // Reserved entry
    context.setFAT(1, @enumFromInt(0xfffffff));

    // Root directory end of chain
    context.setFAT(root_cluster, fat.FAT32Entry.end_of_chain);

    try addFilesAndDirectoriesToFAT(&context, allocator, partition);

    const backup_fat_table: []fat.FAT32Entry = asPtr(
        [*]fat.FAT32Entry,
        slice,
        fat_begin + sectors_per_fat,
        sector_size,
    )[0..number_of_fat_entries];

    @memcpy(backup_fat_table, context.fat_table);
}

fn addFilesAndDirectoriesToFAT(context: *FATContext, allocator: std.mem.Allocator, partition: ImageDescription.Partition) !void {
    for (partition.entries) |entry| {
        switch (entry) {
            .file => |file| {
                const parent_dir_path = std.fs.path.dirname(file.destination_path) orelse {
                    std.debug.panic("file entry with invalid destination path: '{s}'", .{file.destination_path});
                };
                const parent_directory = try ensureFATDirectory(context, allocator, parent_dir_path);

                const file_name = std.fs.path.basename(file.destination_path);

                const name = try makeFATName(allocator, file_name);
                defer name.deinit();

                try parent_directory.addFile(name, file.source_path);

                // std.debug.print("FILE: {s} -> {s}\n", .{ file.source_path, file.destination_path });
            },
            .dir => |dir| {
                _ = try ensureFATDirectory(context, allocator, dir.path);
                // std.debug.print("DIR: {s}\n", .{dir.path});
            },
        }
    }
}

fn ensureFATDirectory(context: *FATContext, allocator: std.mem.Allocator, path: []const u8) !FATContext.FATDirectory {
    var parent_directory = context.getRootDirectory();

    std.debug.assert(path[0] == '/'); // paths are expected to be absolute

    // Root directory is the parent.
    if (path.len == 1) return parent_directory;

    var section_iter = std.mem.splitScalar(u8, path[1..], '/');
    while (section_iter.next()) |section| {
        const name = try makeFATName(allocator, section);
        parent_directory = try parent_directory.getOrAddDirectory(name);
    }

    return parent_directory;
}

const FATName = struct {
    allocator: std.mem.Allocator,

    short_name: fat.ShortFileName,

    /// Is guarenteed to have a trailing zero
    long_name: ?[]const u8,

    fn deinit(fat_name: FATName) void {
        if (fat_name.long_name) |long_name| fat_name.allocator.free(long_name);
    }
};

fn makeFATName(allocator: std.mem.Allocator, name: []const u8) !FATName {
    const filename = std.fs.path.stem(name);
    const extension = std.fs.path.extension(name);

    var needs_long_name = false;

    var short_name: fat.ShortFileName = .{};

    if (extension.len != 0) {
        std.debug.assert(extension[0] == '.');
        const trimmed_extension = extension[1..];

        for (trimmed_extension, 0..) |char, i| {
            if (i >= fat.ShortFileName.extension_max_length) {
                needs_long_name = true;
                break;
            }

            if (std.ascii.isLower(char)) {
                needs_long_name = true;
                short_name.extension[i] = std.ascii.toUpper(char);
            } else {
                short_name.extension[i] = char;
            }
        }
    }

    var filename_truncated = false;

    for (filename, 0..) |char, i| {
        if (i >= fat.ShortFileName.file_name_max_length) {
            filename_truncated = true;
            needs_long_name = true;
            break;
        }

        if (std.ascii.isLower(char)) {
            needs_long_name = true;
            short_name.name[i] = std.ascii.toUpper(char);
        } else {
            short_name.name[i] = char;
        }
    }

    if (filename_truncated) {
        short_name.name[short_name.name.len - 2] = '~';
        // TODO: Always using 1 is incorrect as duplicates are possible.
        short_name.name[short_name.name.len - 1] = '1';
    }

    return .{
        .allocator = allocator,
        .short_name = short_name,
        .long_name = if (needs_long_name) try std.mem.concat(allocator, u8, &.{ name, "\x00" }) else null,
    };
}

const FATContext = struct {
    fat_partition: []u8,

    fat_table: []FAT32Entry,
    next_cluster: u32,
    number_of_clusters: u32,

    root_cluster: u32,

    sector_size: core.Size,
    sectors_per_cluster: u32,
    cluster_size: core.Size,

    cluster_begin_sector: u32,
    directory_entries_per_cluster: usize,

    date_time: FATDateTime,

    pub fn init(
        fat_partition: []u8,
        fat_begin: u32,
        number_of_fat_entries: u32,
        sector_size: core.Size,
        root_cluster: u32,
        sectors_per_cluster: u32,
        cluster_begin_sector: u32,
        number_of_clusters: u32,
    ) FATContext {
        std.debug.assert(root_cluster == 2); // TODO: Remove this requirement

        const cluster_size = sector_size.multiplyScalar(sectors_per_cluster);
        return FATContext{
            .fat_partition = fat_partition,
            .fat_table = asPtr(
                [*]fat.FAT32Entry,
                fat_partition,
                fat_begin,
                sector_size,
            )[0..number_of_fat_entries],
            .next_cluster = 3,
            .root_cluster = root_cluster,
            .sector_size = sector_size,
            .sectors_per_cluster = sectors_per_cluster,
            .cluster_size = cluster_size,
            .cluster_begin_sector = cluster_begin_sector,
            .directory_entries_per_cluster = cluster_size.divide(core.Size.of(fat.DirectoryEntry)).value,
            .date_time = getFATDateAndTime(),
            .number_of_clusters = number_of_clusters,
        };
    }

    const FAT32Entry = fat.FAT32Entry;

    pub fn setFAT(fat_context: *FATContext, index: u32, entry: FAT32Entry) void {
        fat_context.fat_table[index] = entry;
    }

    pub fn nextCluster(fat_context: *FATContext) !u32 {
        const cluster = fat_context.next_cluster;

        if (cluster >= fat_context.number_of_clusters) return error.NoFreeClusters;

        fat_context.next_cluster += 1;
        return cluster;
    }

    pub fn clusterSlice(
        fat_context: FATContext,
        cluster_index: u32,
        number_of_clusters: usize,
    ) []u8 {
        const start = fat_context.cluster_begin_sector + (cluster_index - 2) * fat_context.sectors_per_cluster;
        const size = fat_context.sector_size.multiplyScalar(fat_context.sectors_per_cluster * number_of_clusters);
        return asPtr(
            [*]u8,
            fat_context.fat_partition,
            start,
            fat_context.sector_size,
        )[0..size.value];
    }

    fn getRootDirectory(fat_context: *FATContext) FATDirectory {
        return .{
            .context = fat_context,
            .cluster = fat_context.root_cluster,
            .directory_entries = blk: {
                const root_directory_ptr: [*]fat.DirectoryEntry =
                    @ptrCast(fat_context.clusterSlice(fat_context.root_cluster, 1).ptr);
                break :blk root_directory_ptr[0..fat_context.directory_entries_per_cluster];
            },
        };
    }

    fn copyFile(
        fat_context: *FATContext,
        entry: *fat.DirectoryEntry.StandardDirectoryEntry,
        path: []const u8,
    ) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();

        const file_size = core.Size.from(stat.size, .byte);
        const clusters_required = fat_context.cluster_size.amountToCover(file_size);
        std.debug.assert(clusters_required != 0);

        var current_cluster = try fat_context.nextCluster();

        entry.high_cluster_number = @truncate(current_cluster >> 16);
        entry.low_cluster_number = @truncate(current_cluster);
        entry.size = @intCast(stat.size);

        var i: usize = 0;

        while (i < clusters_required) : (i += 1) {
            const cluster_ptr = fat_context.clusterSlice(current_cluster, 1);
            const read = try file.readAll(cluster_ptr);

            const is_last_cluster = i == clusters_required - 1;

            // only for the last cluster will the amount read be less than a full cluster
            std.debug.assert(read == cluster_ptr.len or is_last_cluster);

            if (is_last_cluster) {
                fat_context.setFAT(current_cluster, fat.FAT32Entry.end_of_chain);
            } else {
                const next_cluster = try fat_context.nextCluster();
                fat_context.setFAT(current_cluster, @enumFromInt(next_cluster));
                current_cluster = next_cluster;
            }
        }
    }

    const FATDirectory = struct {
        context: *FATContext,
        cluster: u32,
        directory_entries: []fat.DirectoryEntry,

        fn getOrAddDirectory(fat_directory: FATDirectory, name: FATName) !FATDirectory {
            std.debug.assert(name.long_name == null); // TODO: support long names

            if (fat_directory.findEntry(name)) |entry| {
                std.debug.assert(entry.standard.attributes.directory); // pre-existing entry is not a directory

                const cluster: u32 = @as(u32, entry.standard.high_cluster_number) << 16 | entry.standard.low_cluster_number;

                // TODO: length is assumed to be one cluster
                const directory_ptr: [*]fat.DirectoryEntry = @ptrCast(
                    fat_directory.context.clusterSlice(cluster, 1).ptr,
                );
                const directory_entries: []fat.DirectoryEntry = directory_ptr[0..fat_directory.context.directory_entries_per_cluster];

                return .{
                    .context = fat_directory.context,
                    .cluster = cluster,
                    .directory_entries = directory_entries,
                };
            }

            return fat_directory.addDirectory(name);
        }

        fn findEntry(fat_directory: FATDirectory, name: FATName) ?*fat.DirectoryEntry {
            std.debug.assert(name.long_name == null); // TODO: support long names

            for (fat_directory.directory_entries) |*entry| {
                if (entry.isUnusedEntry()) continue;
                if (entry.isLastEntry()) break;

                if (entry.isLongFileNameEntry()) {
                    continue; // TODO: long names
                }

                if (entry.standard.short_file_name.equal(name.short_name)) return entry;
            }

            return null;
        }

        fn addDirectory(fat_directory: FATDirectory, name: FATName) !FATDirectory {
            if (name.long_name) |long_name| {
                try fat_directory.addLongFileName(name.short_name, long_name);
            }

            const entry = fat_directory.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

            const new_cluster = try fat_directory.context.nextCluster();

            entry.* = .{
                .standard = .{
                    .short_file_name = name.short_name,
                    .attributes = .{
                        .directory = true,
                    },
                    .creation_datetime_subsecond = fat_directory.context.date_time.subsecond,
                    .creation_time = fat_directory.context.date_time.time,
                    .creation_date = fat_directory.context.date_time.date,
                    .last_accessed_date = fat_directory.context.date_time.date,
                    .high_cluster_number = @truncate(new_cluster >> 16),
                    .last_modification_time = fat_directory.context.date_time.time,
                    .last_modification_date = fat_directory.context.date_time.date,
                    .low_cluster_number = @truncate(new_cluster),
                    .size = 0,
                },
            };

            // TODO: We assume that no directories exceed a single cluster
            fat_directory.context.setFAT(new_cluster, fat.FAT32Entry.end_of_chain);

            // TODO: length is assumed to be one cluster
            const directory_ptr: [*]fat.DirectoryEntry = @ptrCast(fat_directory.context.clusterSlice(new_cluster, 1).ptr);
            const directory_entries: []fat.DirectoryEntry = directory_ptr[0..fat_directory.context.directory_entries_per_cluster];

            // '.' directory
            directory_entries[0] = fat.DirectoryEntry{
                .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                    .short_file_name = .{
                        .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
                    },
                    .attributes = .{
                        .directory = true,
                    },
                    .creation_datetime_subsecond = fat_directory.context.date_time.subsecond,
                    .creation_time = fat_directory.context.date_time.time,
                    .creation_date = fat_directory.context.date_time.date,
                    .last_accessed_date = fat_directory.context.date_time.date,
                    .high_cluster_number = @truncate(new_cluster >> 16),
                    .last_modification_time = fat_directory.context.date_time.time,
                    .last_modification_date = fat_directory.context.date_time.date,
                    .low_cluster_number = @truncate(new_cluster),
                    .size = 0,
                },
            };

            // '..' directory
            directory_entries[1] = fat.DirectoryEntry{
                .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                    .short_file_name = .{
                        .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
                    },
                    .attributes = .{
                        .directory = true,
                    },
                    .creation_datetime_subsecond = fat_directory.context.date_time.subsecond,
                    .creation_time = fat_directory.context.date_time.time,
                    .creation_date = fat_directory.context.date_time.date,
                    .last_accessed_date = fat_directory.context.date_time.date,
                    .high_cluster_number = @truncate(fat_directory.cluster >> 16),
                    .last_modification_time = fat_directory.context.date_time.time,
                    .last_modification_date = fat_directory.context.date_time.date,
                    .low_cluster_number = @truncate(fat_directory.cluster),
                    .size = 0,
                },
            };

            return FATDirectory{
                .context = fat_directory.context,
                .cluster = new_cluster,
                .directory_entries = directory_entries,
            };
        }

        fn addFile(fat_directory: FATDirectory, name: FATName, source_path: []const u8) !void {
            if (name.long_name) |long_name| {
                try fat_directory.addLongFileName(name.short_name, long_name);
            }

            const entry = fat_directory.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

            entry.* = fat.DirectoryEntry{
                .standard = fat.DirectoryEntry.StandardDirectoryEntry{
                    .short_file_name = name.short_name,
                    .attributes = .{
                        .archive = true,
                    },
                    .creation_datetime_subsecond = fat_directory.context.date_time.subsecond,
                    .creation_time = fat_directory.context.date_time.time,
                    .creation_date = fat_directory.context.date_time.date,
                    .last_accessed_date = fat_directory.context.date_time.date,
                    .high_cluster_number = 0, // set by `copyFile`
                    .last_modification_time = fat_directory.context.date_time.time,
                    .last_modification_date = fat_directory.context.date_time.date,
                    .low_cluster_number = 0, // set by `copyFile`
                    .size = 0, // set by `copyFile`
                },
            };
            try fat_directory.context.copyFile(
                &entry.standard,
                source_path,
            );
        }

        fn addLongFileName(fat_directory: FATDirectory, short_name: fat.ShortFileName, long_name: []const u8) !void {
            std.debug.assert(long_name[long_name.len - 1] == 0);

            const number_of_long_name_entries_required = (long_name.len / fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters) + 1;

            std.debug.assert(number_of_long_name_entries_required <= fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_long_name_entries);

            const short_name_checksum = short_name.checksum();

            var sequence_number_counter: u8 = @intCast(number_of_long_name_entries_required);

            var start_index = std.mem.alignBackwardAnyAlign(usize, long_name.len, fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters);

            while (sequence_number_counter >= 1) : (sequence_number_counter -= 1) {
                const entry = fat_directory.firstUnusedEntry() orelse return error.NoFreeDirectoryEntries;

                const sequence_number = if (sequence_number_counter == number_of_long_name_entries_required)
                    sequence_number_counter | fat.DirectoryEntry.LongFileNameEntry.last_entry
                else
                    sequence_number_counter;

                entry.* = fat.DirectoryEntry{
                    .long_file_name = fat.DirectoryEntry.LongFileNameEntry{
                        .sequence_number = sequence_number,
                        .checksum_of_short_name = short_name_checksum,
                    },
                };

                const distance_from_end_of_buffer = long_name.len - start_index;
                const window_length = if (distance_from_end_of_buffer < fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters)
                    distance_from_end_of_buffer
                else
                    fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters;

                const window = long_name[start_index..][0..window_length];

                for (window, 0..) |char, i| {
                    switch (i) {
                        0...4 => entry.long_file_name.first_characters[i] = char,
                        5...10 => entry.long_file_name.middle_characters[i - 5] = char,
                        11...12 => entry.long_file_name.final_characters[i - 11] = char,
                        else => return error.InvalidLongFileName,
                    }
                }

                if (start_index != 0) start_index -= fat.DirectoryEntry.LongFileNameEntry.maximum_number_of_characters;
            }
        }

        fn firstUnusedEntry(fat_directory: FATDirectory) ?*fat.DirectoryEntry {
            for (fat_directory.directory_entries) |*entry| {
                std.debug.assert(!entry.isUnusedEntry()); // we only add more entries, never remove them
                if (entry.isLastEntry()) return entry;
            }
            return null;
        }
    };
};

fn createAndMapDiskImage(disk_image_path: []const u8, disk_size: core.Size) ![]align(std.heap.page_size_min) u8 {
    var parent_directory = try std.fs.cwd().makeOpenPath(std.fs.path.dirname(disk_image_path).?, .{});
    defer parent_directory.close();

    const file = try parent_directory.createFile(std.fs.path.basename(disk_image_path), .{ .truncate = true, .read = true });
    defer file.close();

    try file.setEndPos(disk_size.value);

    return std.posix.mmap(
        null,
        disk_size.value,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
}

const GptPartition = struct {
    start_block: u64,
    block_count: u64,
};

fn createGpt(allocator: std.mem.Allocator, image_description: ImageDescription, disk_image: []u8, random: std.Random, gpt_partitions: []GptPartition) !void {
    std.debug.assert(std.mem.isAligned(disk_image.len, disk_block_size.value));

    const number_of_blocks = disk_image.len / disk_block_size.value;

    const number_of_partition_entries: u32 = if (image_description.partitions.len < gpt.minimum_number_of_partition_entries)
        gpt.minimum_number_of_partition_entries
    else
        @intCast(image_description.partitions.len);

    const partition_array_size_in_blocks: u64 = disk_block_size.amountToCover(
        gpt.PartitionEntry.size.multiplyScalar(number_of_partition_entries),
    );

    const first_usable_block = 2 + partition_array_size_in_blocks;

    const last_usable_block = number_of_blocks - 2 - partition_array_size_in_blocks;

    std.debug.assert(last_usable_block - first_usable_block > 0);

    // Block 0 = Protective MBR
    protectiveMBR(disk_image, number_of_blocks);

    // Block 2 = Primary Partition Entry Array
    const entries: []gpt.PartitionEntry = asPtr(
        [*]gpt.PartitionEntry,
        disk_image,
        2,
        disk_block_size,
    )[0..number_of_partition_entries];

    const partition_table_crc = partition_table_crc: {
        const partition_alignment = gpt.recommended_alignment_of_partitions.divide(disk_block_size).value;

        var next_free_block = first_usable_block;

        for (image_description.partitions, 0..) |partition, i| {
            const starting_block = std.mem.alignForward(usize, next_free_block, partition_alignment);

            if (starting_block > last_usable_block) {
                @panic("exceeded disk image size");
            }

            const desired_blocks_in_partition = blk: {
                if (partition.size == 0) {
                    if (i != image_description.partitions.len - 1) {
                        @panic("partition with zero size that is not the last partition");
                    }
                    break :blk last_usable_block - starting_block;
                }

                break :blk disk_block_size.amountToCover(core.Size.from(partition.size, .byte));
            };

            const type_guid = switch (partition.partition_type) {
                .efi => gpt.partition_types.efi_system_partition,
                .data => gpt.partition_types.linux_filesystem_data,
            };

            const ending_block = blk: {
                const ending_block = starting_block + desired_blocks_in_partition - 1;

                const aligned_ending_block = std.mem.alignBackward(usize, ending_block, partition_alignment) - 1;

                if (aligned_ending_block <= last_usable_block) break :blk aligned_ending_block;

                // TODO: Should we really truncate the partition here?
                //       Should we panic?
                break :blk last_usable_block;
            };

            if (ending_block < starting_block) @panic("ending block is less than starting block");

            const blocks_in_partition = (ending_block - starting_block) + 1;

            entries[i] = gpt.PartitionEntry{
                .partition_type_guid = type_guid,
                .unique_partition_guid = UUID.generateV4(random),
                .starting_lba = starting_block,
                .ending_lba = ending_block,
            };

            const encoded_name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, partition.name);
            defer allocator.free(encoded_name);

            @memcpy(entries[i].partition_name[0..encoded_name.len], encoded_name);

            gpt_partitions[i] = .{
                .start_block = starting_block,
                .block_count = blocks_in_partition,
            };

            next_free_block = ending_block + 1;
        }

        const entry_bytes = std.mem.sliceAsBytes(entries);
        break :partition_table_crc gpt.Crc32.hash(entry_bytes);
    };

    const disk_guid = UUID.generateV4(random);

    // Block 1 = Primary GPT Header
    const primary_header = fillInPrimaryGptHeader(
        disk_image,
        number_of_blocks,
        first_usable_block,
        last_usable_block,
        disk_guid,
        number_of_partition_entries,
        partition_table_crc,
    );

    // Block (NUM - 1) = Backup GPT Header
    const backup_header = asPtr(
        *gpt.Header,
        disk_image,
        number_of_blocks - 1,
        disk_block_size,
    );
    primary_header.copyToOtherHeader(backup_header, partition_array_size_in_blocks);

    // Block (NUM - 1 - number of partition entries) = Backup Partition Entry Array
    const backup_partition_entry_array: []gpt.PartitionEntry = asPtr(
        [*]gpt.PartitionEntry,
        disk_image,
        backup_header.partition_entry_lba,
        disk_block_size,
    )[0..number_of_partition_entries];
    @memcpy(backup_partition_entry_array, entries);
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
        .size_of_partition_entry = @intCast(gpt.PartitionEntry.size.value),
        .partition_entry_array_crc32 = partition_table_crc,
    };
    primary_header.updateHash();
    return primary_header;
}

inline fn asPtr(comptime T: type, file_contents: []u8, index: usize, item_size: core.Size) T {
    return @ptrCast(@alignCast(file_contents.ptr + (index * item_size.value)));
}

const FATDateTime = struct {
    date: fat.Date,
    time: fat.Time,

    // Units of 10 milliseconds
    subsecond: u8,
};

fn getFATDateAndTime() FATDateTime {
    const unix_timestamp_ms = std.time.milliTimestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(unix_timestamp_ms, std.time.ms_per_s)) };

    const epoch_days = epoch_seconds.getEpochDay();
    const year_day = epoch_days.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return .{
        .date = .{
            .year = @intCast(year_day.year - 1980), // -10 to account for unix epoch vs dos epoch
            .month = @intCast(@intFromEnum(month_day.month)),
            .day = @intCast(month_day.day_index),
        },

        .time = .{
            .hour = @intCast(day_seconds.getHoursIntoDay()),
            .minute = @intCast(day_seconds.getMinutesIntoHour()),
            .second_2s = @intCast(day_seconds.getSecondsIntoMinute() / 2),
        },

        .subsecond = @intCast(
            @divFloor(
                @mod(unix_timestamp_ms, std.time.ms_per_s),
                10,
            ),
        ),
    };
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

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const UUID = @import("uuid").UUID;
const fs = @import("fs");

const gpt = fs.gpt;
const fat = fs.fat;
const mbr = fs.mbr;

const ImageDescription = @import("ImageDescription.zig");
