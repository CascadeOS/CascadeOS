// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const LocationLookupBuilder = @This();

allocator: std.mem.Allocator,

location_lookup: std.ArrayListUnmanaged(u64) = .{},
location_program_states: std.ArrayListUnmanaged(sdf.LocationProgramState) = .{},

pub fn addLocationLookup(
    location_lookup_builder: *LocationLookupBuilder,
    instruction_offset: u64,
    address: u64,
    file_index: u64,
    symbol_offset: u64,
    line: u64,
    column: u64,
) !void {
    try location_lookup_builder.location_lookup.append(location_lookup_builder.allocator, address);
    try location_lookup_builder.location_program_states.append(location_lookup_builder.allocator, .{
        .instruction_offset = instruction_offset,
        .address = address,
        .file_index = file_index,
        .symbol_offset = symbol_offset,
        .line = line,
        .column = column,
    });
}

pub fn output(
    location_lookup_builder: *const LocationLookupBuilder,
    output_buffer: *std.ArrayList(u8),
) !struct { u64, u64, u64 } {
    std.debug.assert(location_lookup_builder.location_lookup.items.len == location_lookup_builder.location_program_states.items.len);

    const location_lookup_offset = output_buffer.items.len;

    var adapter = output_buffer.writer().adaptToNewApi();
    const writer = &adapter.new_interface;

    for (location_lookup_builder.location_lookup.items) |address| {
        try writer.writeInt(u64, address, .little); // address
    }

    const location_program_states_offset = std.mem.alignForward(
        u64,
        output_buffer.items.len,
        @alignOf(sdf.LocationProgramState),
    );
    if (location_program_states_offset != output_buffer.items.len) {
        try output_buffer.appendNTimes(0, location_program_states_offset - output_buffer.items.len);
    }

    for (location_lookup_builder.location_program_states.items) |location_program_state| {
        try location_program_state.write(writer);
    }

    return .{ location_lookup_offset, location_program_states_offset, location_lookup_builder.location_lookup.items.len };
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");
