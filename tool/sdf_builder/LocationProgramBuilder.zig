// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

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
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");

const LocationProgramBuilder = @This();
