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
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (switch (@typeInfo(T)) {
        .@"struct" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => @compileError("Expected struct, enum, union, or opaque type, found '" ++ @typeName(T) ++ "'"),
    }) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");
