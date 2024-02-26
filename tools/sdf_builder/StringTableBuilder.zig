// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");

const StringTableBuilder = @This();

allocator: std.mem.Allocator,

string_table: std.ArrayListUnmanaged(u8) = .{},
string_offsets: std.StringHashMapUnmanaged(u64) = .{},

pub fn addString(self: *StringTableBuilder, string: []const u8) !u64 {
    if (self.string_offsets.get(string)) |offset| return offset;

    const key = try self.allocator.dupe(u8, string);
    errdefer self.allocator.free(key);

    const offset = self.string_table.items.len;
    errdefer self.string_table.shrinkRetainingCapacity(offset);

    try self.string_table.appendSlice(self.allocator, string);
    try self.string_table.append(self.allocator, 0);

    try self.string_offsets.put(self.allocator, key, offset);

    return offset;
}

pub fn output(self: *const StringTableBuilder, output_buffer: *std.ArrayList(u8)) !struct { u64, u64 } {
    const offset = output_buffer.items.len;

    try output_buffer.appendSlice(self.string_table.items);
    try output_buffer.append(0);

    return .{ offset, self.string_table.items.len };
}

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
