// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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

    pub fn deinit(self: Parsed) void {
        self.area_allocator.deinit();
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

    pub fn deinit(self: *Builder) void {
        for (self.partition_builders.items) |partition_builder| {
            partition_builder.deinit();
            self.allocator.destroy(partition_builder);
        }
        self.partition_builders.deinit(self.allocator);
    }

    pub fn addPartition(
        self: *Builder,
        /// Assumed to outlive the `Builder`
        name: []const u8,
        size: u64,
        filesystem: Filesystem,
        partition_type: PartitionType,
    ) !*PartitionBuilder {
        const new_used_size = self.used_size + size;
        if (new_used_size > self.size) return error.ImageSizeExceeded;

        const partition_builder = try self.allocator.create(PartitionBuilder);
        errdefer self.allocator.destroy(partition_builder);

        partition_builder.* = .{
            .allocator = self.allocator,
            .name = name,
            .size = size,
            .filesystem = filesystem,
            .partition_type = partition_type,
        };

        try self.partition_builders.append(self.allocator, partition_builder);
        self.used_size = new_used_size;

        return partition_builder;
    }

    pub fn serialize(self: Builder, writer: anytype) !void {
        const partitions = blk: {
            var partitions = try std.ArrayListUnmanaged(Partition).initCapacity(self.allocator, self.partition_builders.items.len);
            defer partitions.deinit(self.allocator);

            for (self.partition_builders.items) |partition_builder| {
                partitions.appendAssumeCapacity(.{
                    .name = partition_builder.name,
                    .size = partition_builder.size,
                    .filesystem = partition_builder.filesystem,
                    .partition_type = partition_builder.partition_type,

                    .entries = partition_builder.entries.items,
                });
            }

            break :blk try partitions.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(partitions);

        const image_description = ImageDescription{
            .size = self.size,
            .partitions = partitions,
        };

        try std.json.stringify(
            image_description,
            std.json.StringifyOptions{
                .whitespace = .indent_1,
            },
            writer,
        );
    }
};

pub const PartitionBuilder = struct {
    allocator: std.mem.Allocator,

    name: []const u8,
    size: u64,
    filesystem: Filesystem,
    partition_type: PartitionType,

    entries: std.ArrayListUnmanaged(Entry) = .{},

    fn deinit(self: *PartitionBuilder) void {
        self.entries.deinit(self.allocator);
    }

    /// The slices in `dir` are assumed to outlive the `Builder`
    pub fn addDir(self: *PartitionBuilder, dir: Entry.Dir) !void {
        try self.entries.append(self.allocator, .{ .dir = dir });
    }

    /// The slices in `file` are assumed to outlive the `Builder`
    pub fn addFile(self: *PartitionBuilder, file: Entry.File) !void {
        try self.entries.append(self.allocator, .{ .file = file });
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
