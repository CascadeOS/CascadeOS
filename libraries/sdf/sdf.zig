// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

//! # Simple Debug Format (SDF) Version 1
//!
//! A simple debug format that provides:
//!  - File, symbol, line and column from instruction address.
//!  - Unwind information (PLANNED)
//!
//! Does not support relocatable addresses.
//!
//! ## Versioning
//!
//! SDF is a backwards compatible format, new versions will only add new functionality.
//!
//! This means valid usage can be assured by checking if the header field `version` is _less than or equal_ to the
//! version you require for the functionality you need.
//!
//! In any future versions of this specification added fields or data structures will be clearly marked with the
//! version they are available from.

const std = @import("std");

pub const version: u8 = 1;

/// Magic bytes to identify the data as SDF.
pub const magic: [8]u8 = "SDFSDFSD".*;

/// SDF Header
///
/// The entry point to SDF that provides access to each of the specific data structures.
///
/// Due to the offsets contained in this header being unsigned the header must proceed all other data structures in memory.
pub const Header = extern struct {
    /// Magic bytes to identify the data as SDF.
    magic: [8]u8 = magic,

    /// Version of the SDF format.
    version: u8 = version,

    /// Reserved for future use.
    _reserved: [7]u8 = [_]u8{0} ** 7,

    /// The byte offset from the start of the header to the string table.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    string_table_offset: u64,

    /// The length of the string table in bytes.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    string_table_length: u64,

    /// The byte offset from the start of the header to the file table.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    file_table_offset: u64,

    /// The number of entries in the file table.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    file_table_entries: u64,

    /// The byte offset from the start of the header to the location lookup.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    location_lookup_offset: u64,

    /// The byte offset from the start of the header to the location program states.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    location_program_states_offset: u64,

    /// The number of entries in the location lookup and location program states.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    location_lookup_entries: u64,

    /// The byte offset from the start of the header to the location program.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    location_program_offset: u64,

    /// The length of the location program in bytes.
    ///
    /// Valid from version `1`.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    location_program_length: u64,

    pub fn read(reader: anytype) !Header {
        var header: Header = undefined;

        header.magic = try reader.readBytesNoEof(magic.len);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.InvalidSdfMagic;

        header.version = try reader.readByte();
        header._reserved = try reader.readBytesNoEof(7);
        header.string_table_offset = try reader.readInt(u64, .little);
        header.string_table_length = try reader.readInt(u64, .little);
        header.file_table_offset = try reader.readInt(u64, .little);
        header.file_table_entries = try reader.readInt(u64, .little);
        header.location_lookup_offset = try reader.readInt(u64, .little);
        header.location_program_states_offset = try reader.readInt(u64, .little);
        header.location_lookup_entries = try reader.readInt(u64, .little);
        header.location_program_offset = try reader.readInt(u64, .little);
        header.location_program_length = try reader.readInt(u64, .little);

        return header;
    }

    pub fn write(header: Header, writer: anytype) !void {
        try writer.writeAll(&magic);
        try writer.writeByte(header.version);
        try writer.writeByteNTimes(0, 7);
        try writer.writeInt(u64, header.string_table_offset, .little);
        try writer.writeInt(u64, header.string_table_length, .little);
        try writer.writeInt(u64, header.file_table_offset, .little);
        try writer.writeInt(u64, header.file_table_entries, .little);
        try writer.writeInt(u64, header.location_lookup_offset, .little);
        try writer.writeInt(u64, header.location_program_states_offset, .little);
        try writer.writeInt(u64, header.location_lookup_entries, .little);
        try writer.writeInt(u64, header.location_program_offset, .little);
        try writer.writeInt(u64, header.location_program_length, .little);
    }

    pub fn stringTable(header: Header, memory: []const u8) StringTable {
        return .{
            .bytes = memory[header.string_table_offset..][0..header.string_table_length :0],
        };
    }

    pub fn fileTable(header: Header, memory: []const u8) FileTable {
        return .{
            .bytes = memory[header.file_table_offset..][0..(header.file_table_entries * @sizeOf(FileEntry))],
            .entry_count = header.file_table_entries,
        };
    }

    pub fn locationLookup(header: Header, memory: []const u8) LocationLookup {
        return .{
            .instruction_addresses_bytes = memory[header.location_lookup_offset..][0..(header.location_lookup_entries * @sizeOf(u64))],
            .location_program_states_bytes = memory[header.location_program_states_offset..][0..(header.location_lookup_entries * @sizeOf(LocationProgramState))],
            .entry_count = header.location_lookup_entries,
        };
    }

    pub fn locationProgram(header: Header, memory: []const u8) LocationProgram {
        return .{
            .bytes = memory[header.location_program_offset..][0..header.location_program_length],
        };
    }

    test Header {
        var orig_header: Header = .{
            .string_table_offset = 1234,
            .string_table_length = 1234,
            .file_table_offset = 1234,
            .file_table_entries = 1234,
            .location_lookup_offset = 1234,
            .location_program_states_offset = 1234,
            .location_lookup_entries = 1234,
            .location_program_offset = 1234,
            .location_program_length = 1234,
        };

        var buffer: [@sizeOf(Header)]u8 = undefined;

        var fbs = std.io.fixedBufferStream(&buffer);
        try orig_header.write(fbs.writer());

        fbs.pos = 0;
        const new_header = try Header.read(fbs.reader());

        try std.testing.expectEqual(orig_header, new_header);
    }

    comptime {
        std.debug.assert(@sizeOf(Header) == 88);
        std.debug.assert(@alignOf(Header) == 8);
    }
};

/// A table containing all strings referenced by the SDF data as null-terminated UTF-8 strings.
///
/// Strings are referenced by offset from the start of the string table.
pub const StringTable = struct {
    bytes: [:0]const u8,

    pub fn getString(self: StringTable, offset: u64) [:0]const u8 {
        return std.mem.sliceTo(self.bytes[offset..], 0);
    }
};

/// An array of `FileEntry` structures containing information about each file referenced by the SDF data.
///
/// Files are referenced by index.
pub const FileTable = struct {
    bytes: []const u8,
    entry_count: u64,

    pub fn getFile(self: FileTable, index: u64) ?FileEntry {
        if (index >= self.entry_count) return null;

        var fbs = std.io.fixedBufferStream(
            self.bytes[index * @sizeOf(FileEntry) ..],
        );

        return FileEntry.read(fbs.reader()) catch null;
    }
};

/// A file referenced by the SDF data.
pub const FileEntry = extern struct {
    /// Offset of the directory name in the string table.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    directory_offset: u64,

    /// Offset of the file name in the string table.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    file_offset: u64,

    pub fn read(reader: anytype) !FileEntry {
        var entry: FileEntry = undefined;

        entry.directory_offset = try reader.readInt(u64, .little);
        entry.file_offset = try reader.readInt(u64, .little);

        return entry;
    }

    pub fn write(file_entry: FileEntry, writer: anytype) !void {
        try writer.writeInt(u64, file_entry.directory_offset, .little);
        try writer.writeInt(u64, file_entry.file_offset, .little);
    }

    pub fn directory(self: FileEntry, string_table: StringTable) [:0]const u8 {
        return string_table.getString(self.directory_offset);
    }

    pub fn file(self: FileEntry, string_table: StringTable) [:0]const u8 {
        return string_table.getString(self.file_offset);
    }

    comptime {
        std.debug.assert(@sizeOf(FileEntry) == 16);
        std.debug.assert(@alignOf(FileEntry) == 8);
    }
};

/// Provides a mapping from instruction addresses to a location program state that is the optimal start point for
/// the location program for that address.
pub const LocationLookup = struct {
    instruction_addresses_bytes: []const u8,
    location_program_states_bytes: []const u8,
    entry_count: u64,

    pub fn getStartState(self: LocationLookup, address: u64) !LocationProgramState {
        const index = blk: {
            var instruction_addresses = std.io.fixedBufferStream(self.instruction_addresses_bytes);
            const reader = instruction_addresses.reader();

            var candidate_index: u64 = 0;
            while (reader.readInt(u64, .little) catch null) |candidate_address| : (candidate_index += 1) {
                if (candidate_address > address) break;
            }
            break :blk if (candidate_index != 0) candidate_index - 1 else 0;
        };

        var location_program_states = std.io.fixedBufferStream(
            self.location_program_states_bytes[index * @sizeOf(LocationProgramState) ..],
        );

        return LocationProgramState.read(location_program_states.reader());
    }
};

/// A state of the location program state machine.
pub const LocationProgramState = extern struct {
    /// The byte offset into the location program of the instruction to execute.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    instruction_offset: u64 = 0,

    /// The address register associated with this state.
    ///
    /// If the address is `0` then it is either invalid or not set.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    address: u64 = 0,

    /// The file index register associated with this state.
    ///
    /// If the file index is `std.math.maxInt(u64)` then it is either invalid or not set.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    file_index: u64 = std.math.maxInt(u64),

    /// The symbol offset register associated with this state.
    ///
    /// If the symbol offset is `std.math.maxInt(u64)` then it is either invalid or not set.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    symbol_offset: u64 = std.math.maxInt(u64),

    /// The line register associated with this state.
    ///
    /// If the line is `0` then it is either invalid or not set.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    line: u64 = 0,

    /// The column register associated with this state.
    ///
    /// If the column is `0` then it is either invalid or not set.
    ///
    /// Stored in little endian, `write` and `read` perform the conversion if required.
    column: u64 = 0,

    pub fn read(reader: anytype) !LocationProgramState {
        var result: LocationProgramState = undefined;

        result.instruction_offset = try reader.readInt(u64, .little);
        result.address = try reader.readInt(u64, .little);
        result.file_index = try reader.readInt(u64, .little);
        result.symbol_offset = try reader.readInt(u64, .little);
        result.line = try reader.readInt(u64, .little);
        result.column = try reader.readInt(u64, .little);

        return result;
    }

    pub fn write(location_program_state: LocationProgramState, writer: anytype) !void {
        try writer.writeInt(u64, location_program_state.instruction_offset, .little);
        try writer.writeInt(u64, location_program_state.address, .little);
        try writer.writeInt(u64, location_program_state.file_index, .little);
        try writer.writeInt(u64, location_program_state.symbol_offset, .little);
        try writer.writeInt(u64, location_program_state.line, .little);
        try writer.writeInt(u64, location_program_state.column, .little);
    }

    comptime {
        std.debug.assert(@sizeOf(LocationProgramState) == 48);
        std.debug.assert(@alignOf(LocationProgramState) == 8);
    }
};

/// A bytecode program that determines the file, symbol, line and column for an address.
///
/// The location program can be run from its beginning up to the target address. However, as an address could be a long
/// way into the program, the location lookup and location program states can be used to "jump" into the location
/// program closer to the target address.
pub const LocationProgram = struct {
    bytes: []const u8,

    pub fn getLocation(self: LocationProgram, start_state: LocationProgramState, address: u64) !Location {
        var fbs = std.io.fixedBufferStream(self.bytes[start_state.instruction_offset..]);
        const reader = fbs.reader();

        var state = start_state;

        while (state.address < address) {
            const instruction = try LocationProgramInstruction.read(reader);

            switch (instruction) {
                .offset_address => |offset| state.address += offset,
                .increment_address_four => state.address += 4,
                .increment_address_eight => state.address += 8,
                .increment_address_twelve => state.address += 12,
                .increment_address_sixteen => state.address += 16,
                .set_symbol_offset => |offset| state.symbol_offset = offset,
                .set_file_index => |index| state.file_index = index,
                .offset_column => |offset| if (offset > 0) {
                    state.column += @intCast(offset);
                } else {
                    state.column -= @intCast(-offset);
                },
                .offset_line => |offset| if (offset > 0) {
                    state.line += @intCast(offset);
                } else {
                    state.line -= @intCast(-offset);
                },
                .increment_line_one => state.line += 1,
                .increment_line_two => state.line += 2,
                .increment_line_three => state.line += 3,
                .increment_line_four => state.line += 4,
                .increment_line_five => state.line += 5,
                .decrement_line_one => state.line -= 1,
                .decrement_line_two => state.line -= 2,
                .decrement_line_three => state.line -= 3,
                .decrement_line_four => state.line -= 4,
                .decrement_line_five => state.line -= 5,
            }
        }

        return .{
            .file_index = state.file_index,
            .symbol_offset = state.symbol_offset,
            .line = state.line,
            .column = state.column,
        };
    }

    pub const Location = struct {
        file_index: u64,

        symbol_offset: u64,

        line: u64,

        column: u64,

        pub fn file(self: Location, file_table: FileTable) !FileEntry {
            return file_table.getFile(self.file_index) orelse error.NoSuchFile;
        }

        pub fn symbol(self: Location, string_table: StringTable) [:0]const u8 {
            return string_table.getString(self.symbol_offset);
        }
    };
};

pub const LocationProgramOpcode = enum(u8) {
    /// Add the subsequent ULEB128 encoded number to the `address` register.
    offset_address = 0x1,

    /// Increment the `address` register by four.
    increment_address_four = 0x2,

    /// Increment the `address` register by eight.
    increment_address_eight = 0x3,

    /// Increment the `address` register by twelve.
    increment_address_twelve = 0x4,

    /// Increment the `address` register by sixteen.
    increment_address_sixteen = 0x5,

    /// Set the `symbol_offset` register to the subsequent ULEB128 encoded number.
    set_symbol_offset = 0x6,

    /// Set the `file_index` register to the subsequent ULEB128 encoded number.
    set_file_index = 0x7,

    /// Add the subsequent SLEB128 encoded number to the `column` register using a wrapping operation.
    offset_column = 0x8,

    /// Add the subsequent SLEB128 encoded number to the `line` register using a wrapping operation.
    offset_line = 0x9,

    /// Increment the `line` register by one.
    increment_line_one = 0xa,

    /// Increment the `line` register by two.
    increment_line_two = 0xb,

    /// Increment the `line` register by three.
    increment_line_three = 0xc,

    /// Increment the `line` register by four.
    increment_line_four = 0xd,

    /// Increment the `line` register by five.
    increment_line_five = 0xe,

    /// Decrement the `line` register by one.
    decrement_line_one = 0xf,

    /// Decrement the `line` register by two.
    decrement_line_two = 0x10,

    /// Decrement the `line` register by three.
    decrement_line_three = 0x11,

    /// Decrement the `line` register by four.
    decrement_line_four = 0x12,

    /// Decrement the `line` register by five.
    decrement_line_five = 0x13,
};

pub const LocationProgramInstruction = union(LocationProgramOpcode) {
    offset_address: u64,
    increment_address_four,
    increment_address_eight,
    increment_address_twelve,
    increment_address_sixteen,
    set_symbol_offset: u64,
    set_file_index: u64,
    offset_column: i64,
    offset_line: i64,
    increment_line_one,
    increment_line_two,
    increment_line_three,
    increment_line_four,
    increment_line_five,
    decrement_line_one,
    decrement_line_two,
    decrement_line_three,
    decrement_line_four,
    decrement_line_five,

    pub fn read(reader: anytype) !LocationProgramInstruction {
        const opcode: LocationProgramOpcode = @enumFromInt(try reader.readByte());

        return switch (opcode) {
            .offset_address => .{ .offset_address = try std.leb.readULEB128(u64, reader) },
            .set_symbol_offset => .{ .set_symbol_offset = try std.leb.readULEB128(u64, reader) },
            .set_file_index => .{ .set_file_index = try std.leb.readULEB128(u64, reader) },
            .offset_column => .{ .offset_column = try std.leb.readILEB128(i64, reader) },
            .offset_line => .{ .offset_line = try std.leb.readILEB128(i64, reader) },
            inline else => |op| op,
        };
    }

    pub fn write(location_program_instruction: LocationProgramInstruction, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(location_program_instruction));

        switch (location_program_instruction) {
            .offset_address => |value| try std.leb.writeULEB128(writer, value),
            .set_symbol_offset => |value| try std.leb.writeULEB128(writer, value),
            .set_file_index => |value| try std.leb.writeULEB128(writer, value),
            .offset_column => |value| try std.leb.writeILEB128(writer, value),
            .offset_line => |value| try std.leb.writeILEB128(writer, value),
            .increment_address_four,
            .increment_address_eight,
            .increment_address_twelve,
            .increment_address_sixteen,
            .increment_line_one,
            .increment_line_two,
            .increment_line_three,
            .increment_line_four,
            .increment_line_five,
            .decrement_line_one,
            .decrement_line_two,
            .decrement_line_three,
            .decrement_line_four,
            .decrement_line_five,
            => {},
        }
    }
};

comptime {
    refAllDeclsRecursive(@This());
}

// Copy of `std.testing.refAllDeclsRecursive`, being in the file give access to private decls.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;

    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .Struct, .Enum, .Union, .Opaque => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
