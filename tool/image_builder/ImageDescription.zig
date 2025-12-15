// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

// NOTE: This file is imported in build.zig so cannot import any modules.

const ImageDescription = @This();

/// Total size of the image.
///
/// Must be a multiple of 512 bytes.
size: u64,

partitions: []const Partition,

pub const Partition = struct {
    name: []const u8,

    /// Total size of the partition.
    ///
    /// Must be a multiple of 512 bytes.
    ///
    /// If this is the last partition then a size of zero is accepted and
    /// means to fill the rest of the image.
    size: u64,

    filesystem: Filesystem,

    partition_type: PartitionType,

    entries: []const Entry,
};

pub const Filesystem = enum {
    fat32,
};

pub const PartitionType = enum {
    efi,
    bios_boot,
    data,
};

pub const Entry = union(enum) {
    file: File,
    dir: Dir,

    pub const Dir = struct {
        /// The path of the directory to create.
        path: []const u8,
    };

    pub const File = struct {
        /// Must be absolute.
        source_path: []const u8,
        destination_path: []const u8,
    };
};

pub const Parsed = struct {
    area_allocator: std.heap.ArenaAllocator,

    image_description: ImageDescription,

    pub fn deinit(parsed: Parsed) void {
        parsed.area_allocator.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, slice: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const dup_slice = try arena.allocator().dupe(u8, slice);

    const description = try std.json.parseFromSliceLeaky(
        ImageDescription,
        arena.allocator(),
        dup_slice,
        .{},
    );

    return .{
        .area_allocator = arena,
        .image_description = description,
    };
}

pub const Builder = struct {
    allocator: std.mem.Allocator,

    size: u64,

    used_size: u64 = 0,

    partition_builders: std.ArrayListUnmanaged(*PartitionBuilder) = .{},

    pub fn create(allocator: std.mem.Allocator, size: u64) Builder {
        return .{
            .allocator = allocator,
            .size = size,
        };
    }

    pub fn deinit(builder: *Builder) void {
        for (builder.partition_builders.items) |partition_builder| {
            partition_builder.deinit();
            builder.allocator.destroy(partition_builder);
        }
        builder.partition_builders.deinit(builder.allocator);
    }

    pub fn addPartition(
        builder: *Builder,
        /// Assumed to outlive the `Builder`
        name: []const u8,
        size: u64,
        filesystem: Filesystem,
        partition_type: PartitionType,
    ) !*PartitionBuilder {
        const new_used_size = builder.used_size + size;
        if (new_used_size > builder.size) return error.ImageSizeExceeded;

        const partition_builder = try builder.allocator.create(PartitionBuilder);
        errdefer builder.allocator.destroy(partition_builder);

        partition_builder.* = .{
            .allocator = builder.allocator,
            .name = name,
            .size = size,
            .filesystem = filesystem,
            .partition_type = partition_type,
        };

        try builder.partition_builders.append(builder.allocator, partition_builder);
        builder.used_size = new_used_size;

        return partition_builder;
    }

    pub fn serialize(builder: Builder, writer: *std.Io.Writer) !void {
        const partitions = blk: {
            var partitions = try std.ArrayListUnmanaged(Partition).initCapacity(
                builder.allocator,
                builder.partition_builders.items.len,
            );
            defer partitions.deinit(builder.allocator);

            for (builder.partition_builders.items) |partition_builder| {
                partitions.appendAssumeCapacity(.{
                    .name = partition_builder.name,
                    .size = partition_builder.size,
                    .filesystem = partition_builder.filesystem,
                    .partition_type = partition_builder.partition_type,

                    .entries = partition_builder.entries.items,
                });
            }

            break :blk try partitions.toOwnedSlice(builder.allocator);
        };
        defer builder.allocator.free(partitions);

        const image_description = ImageDescription{
            .size = builder.size,
            .partitions = partitions,
        };

        var j: std.json.Stringify = .{
            .writer = writer,
            .options = .{ .whitespace = .indent_1 },
        };
        try j.write(image_description);
    }
};

pub const PartitionBuilder = struct {
    allocator: std.mem.Allocator,

    name: []const u8,
    size: u64,
    filesystem: Filesystem,
    partition_type: PartitionType,

    entries: std.ArrayListUnmanaged(Entry) = .{},

    fn deinit(partition_builder: *PartitionBuilder) void {
        partition_builder.entries.deinit(partition_builder.allocator);
    }

    /// The slices in `dir` are assumed to outlive the `Builder`
    pub fn addDir(partition_builder: *PartitionBuilder, dir: Entry.Dir) !void {
        try partition_builder.entries.append(partition_builder.allocator, .{ .dir = dir });
    }

    /// The slices in `file` are assumed to outlive the `Builder`
    pub fn addFile(partition_builder: *PartitionBuilder, file: Entry.File) !void {
        try partition_builder.entries.append(partition_builder.allocator, .{ .file = file });
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
