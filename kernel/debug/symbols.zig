// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const sdf = @import("sdf");

var symbols_loaded: bool = false;

/// Valid if `symbols_loaded` is true.
var sdf_string_table: sdf.StringTable = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_file_table: sdf.FileTable = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_location_lookup: sdf.LocationLookup = undefined;

/// Valid if `symbols_loaded` is true.
var sdf_location_program: sdf.LocationProgram = undefined;

pub fn loadSymbols() void {
    if (@atomicLoad(bool, &symbols_loaded, .Acquire)) return;

    const sdf_slice = kernel.info.sdfSlice();

    var sdf_fbs = std.io.fixedBufferStream(sdf_slice);

    const header = sdf.Header.read(sdf_fbs.reader()) catch core.panic("SDF data is invalid");

    sdf_string_table = header.stringTable(sdf_slice);
    sdf_file_table = header.fileTable(sdf_slice);
    sdf_location_lookup = header.locationLookup(sdf_slice);
    sdf_location_program = header.locationProgram(sdf_slice);

    @atomicStore(bool, &symbols_loaded, true, .Release);
}

pub fn getSymbol(address: usize) ?Symbol {
    if (!symbols_loaded) return null;

    const start_state = sdf_location_lookup.getStartState(address) catch return null;

    const location = sdf_location_program.getLocation(start_state, address) catch return null;

    const file = sdf_file_table.getFile(location.file_index) orelse return null;

    return .{
        .name = sdf_string_table.getString(location.symbol_offset),
        .directory = sdf_string_table.getString(file.directory_offset),
        .file = sdf_string_table.getString(file.file_offset),
        .line = location.line,
        .column = location.column,
    };
}

pub const Symbol = struct {
    name: []const u8,
    directory: []const u8,
    file: []const u8,
    line: u64,
    column: u64,
};
