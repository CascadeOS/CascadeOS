// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");

const LocationProgramBuilder = @This();

location_table: std.ArrayList(u8),

pub fn init(allocator: std.mem.Allocator) LocationProgramBuilder {
    return .{
        .location_table = std.ArrayList(u8).init(allocator),
    };
}

pub fn currentOffset(self: *const LocationProgramBuilder) u64 {
    return self.location_table.items.len;
}

pub fn addInstruction(self: *LocationProgramBuilder, instruction: sdf.LocationProgramInstruction) !void {
    const writer = self.location_table.writer();
    try instruction.write(writer);
}

pub fn output(self: *const LocationProgramBuilder, output_buffer: *std.ArrayList(u8)) !struct { u64, u64 } {
    const offset = output_buffer.items.len;

    try output_buffer.appendSlice(self.location_table.items);

    return .{ offset, self.location_table.items.len };
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
