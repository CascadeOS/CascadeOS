// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const FileTableBuilder = @This();

allocator: std.mem.Allocator,

file_table: std.ArrayListUnmanaged(sdf.FileEntry) = .{},
file_indexes: std.AutoHashMapUnmanaged(sdf.FileEntry, u64) = .{},

pub fn addFile(file_table_builder: *FileTableBuilder, file_entry: sdf.FileEntry) !u64 {
    if (file_table_builder.file_indexes.get(file_entry)) |index| return index;

    const index = file_table_builder.file_table.items.len;

    try file_table_builder.file_table.append(file_table_builder.allocator, file_entry);
    errdefer _ = file_table_builder.file_table.pop();

    try file_table_builder.file_indexes.put(file_table_builder.allocator, file_entry, index);

    return index;
}

pub fn output(file_table_builder: *const FileTableBuilder, output_buffer: *std.ArrayList(u8)) !struct { u64, u64 } {
    const file_table_offset = output_buffer.items.len;

    var adapter = output_buffer.writer().adaptToNewApi();
    const writer = &adapter.new_interface;

    for (file_table_builder.file_table.items) |file_entry| {
        try file_entry.write(writer);
    }

    return .{ file_table_offset, file_table_builder.file_table.items.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");
