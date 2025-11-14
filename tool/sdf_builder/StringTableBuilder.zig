// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const StringTableBuilder = @This();

allocator: std.mem.Allocator,

string_table: std.ArrayListUnmanaged(u8) = .{},
string_offsets: std.StringHashMapUnmanaged(u64) = .{},

pub fn addString(string_table_builder: *StringTableBuilder, string: []const u8) !u64 {
    if (string_table_builder.string_offsets.get(string)) |offset| return offset;

    const key = try string_table_builder.allocator.dupe(u8, string);
    errdefer string_table_builder.allocator.free(key);

    const offset = string_table_builder.string_table.items.len;
    errdefer string_table_builder.string_table.shrinkRetainingCapacity(offset);

    try string_table_builder.string_table.appendSlice(string_table_builder.allocator, string);
    try string_table_builder.string_table.append(string_table_builder.allocator, 0);

    try string_table_builder.string_offsets.put(string_table_builder.allocator, key, offset);

    return offset;
}

pub fn output(
    string_table_builder: *const StringTableBuilder,
    output_buffer: *std.Io.Writer.Allocating,
) !struct { u64, u64 } {
    const offset = output_buffer.writer.end;

    try output_buffer.writer.writeAll(string_table_builder.string_table.items);
    try output_buffer.writer.writeByte(0);

    return .{ offset, string_table_builder.string_table.items.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
