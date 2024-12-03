// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const FileTableBuilder = @This();

allocator: std.mem.Allocator,

file_table: std.ArrayListUnmanaged(sdf.FileEntry) = .{},
file_indexes: std.AutoHashMapUnmanaged(sdf.FileEntry, u64) = .{},

pub fn addFile(self: *FileTableBuilder, file_entry: sdf.FileEntry) !u64 {
    if (self.file_indexes.get(file_entry)) |index| return index;

    const index = self.file_table.items.len;

    try self.file_table.append(self.allocator, file_entry);
    errdefer _ = self.file_table.pop();

    try self.file_indexes.put(self.allocator, file_entry, index);

    return index;
}

pub fn output(self: *const FileTableBuilder, output_buffer: *std.ArrayList(u8)) !struct { u64, u64 } {
    const file_table_offset = output_buffer.items.len;

    const writer = output_buffer.writer();

    for (self.file_table.items) |file_entry| {
        try file_entry.write(writer);
    }

    return .{ file_table_offset, self.file_table.items.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");
