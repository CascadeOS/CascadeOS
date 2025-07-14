// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

location_table: std.Io.Writer.Allocating,

pub fn init(allocator: std.mem.Allocator) LocationProgramBuilder {
    return .{
        .location_table = .init(allocator),
    };
}

pub fn currentOffset(location_program_builder: *LocationProgramBuilder) u64 {
    return location_program_builder.location_table.getWritten().len;
}

pub fn addInstruction(
    location_program_builder: *LocationProgramBuilder,
    instruction: sdf.LocationProgramInstruction,
) !void {
    try instruction.write(&location_program_builder.location_table.writer);
}

pub fn output(
    location_program_builder: *LocationProgramBuilder,
    output_buffer: *std.ArrayList(u8),
) !struct { u64, u64 } {
    const offset = output_buffer.items.len;
    const written = location_program_builder.location_table.getWritten();
    try output_buffer.appendSlice(written);
    return .{ offset, written.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");

const LocationProgramBuilder = @This();
