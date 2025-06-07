// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

location_table: std.ArrayList(u8),

pub fn init(allocator: std.mem.Allocator) LocationProgramBuilder {
    return .{
        .location_table = std.ArrayList(u8).init(allocator),
    };
}

pub fn currentOffset(location_program_builder: *const LocationProgramBuilder) u64 {
    return location_program_builder.location_table.items.len;
}

pub fn addInstruction(
    location_program_builder: *LocationProgramBuilder,
    instruction: sdf.LocationProgramInstruction,
) !void {
    const writer = location_program_builder.location_table.writer();
    try instruction.write(writer);
}

pub fn output(
    location_program_builder: *const LocationProgramBuilder,
    output_buffer: *std.ArrayList(u8),
) !struct { u64, u64 } {
    const offset = output_buffer.items.len;

    try output_buffer.appendSlice(location_program_builder.location_table.items);

    return .{ offset, location_program_builder.location_table.items.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");

const LocationProgramBuilder = @This();
