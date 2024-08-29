// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");

const sdf = @import("sdf");

const LocationLookupBuilder = @This();

allocator: std.mem.Allocator,

location_lookup: std.ArrayListUnmanaged(u64) = .{},
location_program_states: std.ArrayListUnmanaged(sdf.LocationProgramState) = .{},

pub fn addLocationLookup(
    self: *LocationLookupBuilder,
    instruction_offset: u64,
    address: u64,
    file_index: u64,
    symbol_offset: u64,
    line: u64,
    column: u64,
) !void {
    try self.location_lookup.append(self.allocator, address);
    try self.location_program_states.append(self.allocator, .{
        .instruction_offset = instruction_offset,
        .address = address,
        .file_index = file_index,
        .symbol_offset = symbol_offset,
        .line = line,
        .column = column,
    });
}

pub fn output(self: *const LocationLookupBuilder, output_buffer: *std.ArrayList(u8)) !struct { u64, u64, u64 } {
    std.debug.assert(self.location_lookup.items.len == self.location_program_states.items.len);

    const location_lookup_offset = output_buffer.items.len;

    const writer = output_buffer.writer();

    for (self.location_lookup.items) |address| {
        try writer.writeInt(u64, address, .little); // address
    }

    const location_program_states_offset = std.mem.alignForward(u64, output_buffer.items.len, @alignOf(sdf.LocationProgramState));
    if (location_program_states_offset != output_buffer.items.len) {
        try output_buffer.appendNTimes(0, location_program_states_offset - output_buffer.items.len);
    }

    for (self.location_program_states.items) |location_program_state| {
        try location_program_state.write(writer);
    }

    return .{ location_lookup_offset, location_program_states_offset, self.location_lookup.items.len };
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
