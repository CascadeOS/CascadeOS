// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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

    /// The total size of the SDF data in bytes from the start of the header.
    total_size_of_sdf_data: u64,

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

    pub fn read(reader: *std.Io.Reader) !Header {
        var header: Header = undefined;
        try reader.readSliceEndian(Header, @ptrCast(&header), .little);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.InvalidSdfMagic;
        return header;
    }

    pub fn write(header: Header, writer: *std.Io.Writer) !void {
        try writer.writeSliceEndian(Header, @ptrCast(&header), .little);
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
            .total_size_of_sdf_data = 1,
            .string_table_offset = 12,
            .string_table_length = 23,
            .file_table_offset = 34,
            .file_table_entries = 45,
            .location_lookup_offset = 56,
            .location_program_states_offset = 67,
            .location_lookup_entries = 78,
            .location_program_offset = 89,
            .location_program_length = 90,
        };

        var buffer: [@sizeOf(Header)]u8 = undefined;

        {
            var writer = std.Io.Writer.fixed(&buffer);
            try orig_header.write(&writer);
        }

        const new_header = blk: {
            var reader = std.Io.Reader.fixed(&buffer);
            break :blk try Header.read(&reader);
        };

        try std.testing.expectEqual(orig_header, new_header);
    }

    comptime {
        std.debug.assert(@sizeOf(Header) == 96);
        std.debug.assert(@alignOf(Header) == 8);
    }
};

/// A table containing all strings referenced by the SDF data as null-terminated UTF-8 strings.
///
/// Strings are referenced by offset from the start of the string table.
pub const StringTable = struct {
    bytes: [:0]const u8,

    pub fn getString(string_table: StringTable, offset: u64) [:0]const u8 {
        return std.mem.sliceTo(string_table.bytes[offset..], 0);
    }
};

/// An array of `FileEntry` structures containing information about each file referenced by the SDF data.
///
/// Files are referenced by index.
pub const FileTable = struct {
    bytes: []const u8,
    entry_count: u64,

    pub fn getFile(file_table: FileTable, index: u64) ?FileEntry {
        if (index >= file_table.entry_count) return null;
        var reader: std.Io.Reader = .fixed(file_table.bytes[index * @sizeOf(FileEntry) ..]);
        return FileEntry.read(&reader) catch null;
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

    pub fn read(reader: *std.Io.Reader) !FileEntry {
        var file_entry: FileEntry = undefined;
        try reader.readSliceEndian(FileEntry, @ptrCast(&file_entry), .little);
        return file_entry;
    }

    pub fn write(file_entry: FileEntry, writer: *std.Io.Writer) !void {
        try writer.writeSliceEndian(FileEntry, @ptrCast(&file_entry), .little);
    }

    pub fn directory(file_entry: FileEntry, string_table: StringTable) [:0]const u8 {
        return string_table.getString(file_entry.directory_offset);
    }

    pub fn file(file_entry: FileEntry, string_table: StringTable) [:0]const u8 {
        return string_table.getString(file_entry.file_offset);
    }

    test FileEntry {
        var orig_file_entry: FileEntry = .{
            .directory_offset = 12,
            .file_offset = 32,
        };

        var buffer: [@sizeOf(FileEntry)]u8 = undefined;

        {
            var writer: std.Io.Writer = .fixed(&buffer);
            try orig_file_entry.write(&writer);
        }

        const new_file_entry = blk: {
            var reader: std.Io.Reader = .fixed(&buffer);
            break :blk try FileEntry.read(&reader);
        };

        try std.testing.expectEqual(orig_file_entry, new_file_entry);
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

    pub fn getStartState(location_lookup: LocationLookup, address: u64) !LocationProgramState {
        const index = blk: {
            var reader: std.Io.Reader = .fixed(location_lookup.instruction_addresses_bytes);

            var candidate_index: u64 = 0;
            while (reader.takeInt(u64, .little) catch null) |candidate_address| : (candidate_index += 1) {
                if (candidate_address > address) break;
            }
            break :blk if (candidate_index != 0) candidate_index - 1 else 0;
        };

        var reader: std.Io.Reader = .fixed(
            location_lookup.location_program_states_bytes[index * @sizeOf(LocationProgramState) ..],
        );
        return LocationProgramState.read(&reader);
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

    pub fn read(reader: *std.Io.Reader) !LocationProgramState {
        var location_program_state: LocationProgramState = undefined;
        try reader.readSliceEndian(LocationProgramState, @ptrCast(&location_program_state), .little);
        return location_program_state;
    }

    pub fn write(location_program_state: LocationProgramState, writer: *std.Io.Writer) !void {
        try writer.writeSliceEndian(LocationProgramState, @ptrCast(&location_program_state), .little);
    }

    test LocationProgramState {
        var orig_location_program_state: LocationProgramState = .{
            .instruction_offset = 12,
            .address = 23,
            .file_index = 34,
            .symbol_offset = 45,
            .line = 56,
            .column = 67,
        };

        var buffer: [@sizeOf(LocationProgramState)]u8 = undefined;

        {
            var writer: std.Io.Writer = .fixed(&buffer);
            try orig_location_program_state.write(&writer);
        }

        const new_location_program_state = blk: {
            var reader: std.Io.Reader = .fixed(&buffer);
            break :blk try LocationProgramState.read(&reader);
        };

        try std.testing.expectEqual(orig_location_program_state, new_location_program_state);
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

    pub fn getLocation(location_program: LocationProgram, start_state: LocationProgramState, address: u64) !Location {
        var reader: std.Io.Reader = .fixed(location_program.bytes[start_state.instruction_offset..]);

        var state = start_state;

        while (state.address < address) {
            const instruction = try LocationProgramInstruction.read(&reader);

            switch (instruction) {
                .offset_address => |offset| state.address += offset,
                .increment_address_two => state.address += 2,
                .increment_address_three => state.address += 3,
                .increment_address_four => state.address += 4,
                .increment_address_five => state.address += 5,
                .increment_address_six => state.address += 6,
                .increment_address_seven => state.address += 7,
                .increment_address_eight => state.address += 8,
                .increment_address_nine => state.address += 9,
                .increment_address_ten => state.address += 10,
                .increment_address_eleven => state.address += 11,
                .increment_address_twelve => state.address += 12,
                .increment_address_thirteen => state.address += 13,
                .increment_address_fourteen => state.address += 14,
                .increment_address_fifteen => state.address += 15,
                .increment_address_sixteen => state.address += 16,
                .increment_address_seventeen => state.address += 17,
                .increment_address_eighteen => state.address += 18,
                .increment_address_nineteen => state.address += 19,
                .increment_address_twenty => state.address += 20,
                .increment_address_twenty_one => state.address += 21,
                .increment_address_twenty_two => state.address += 22,
                .increment_address_twenty_three => state.address += 23,
                .increment_address_twenty_four => state.address += 24,
                .increment_address_twenty_five => state.address += 25,
                .increment_address_twenty_six => state.address += 26,
                .increment_address_twenty_seven => state.address += 27,
                .increment_address_twenty_eight => state.address += 28,
                .increment_address_twenty_nine => state.address += 29,
                .increment_address_thirty => state.address += 30,
                .increment_address_thirty_one => state.address += 31,
                .increment_address_thirty_two => state.address += 32,
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
                .increment_line_six => state.line += 6,
                .increment_line_seven => state.line += 7,
                .increment_line_eight => state.line += 8,
                .increment_line_nine => state.line += 9,
                .increment_line_ten => state.line += 10,
                .increment_line_eleven => state.line += 11,
                .increment_line_twelve => state.line += 12,
                .decrement_line_one => state.line -= 1,
                .decrement_line_two => state.line -= 2,
                .decrement_line_three => state.line -= 3,
                .decrement_line_four => state.line -= 4,
                .decrement_line_five => state.line -= 5,
                .decrement_line_six => state.line -= 6,
                .decrement_line_seven => state.line -= 7,
                .decrement_line_eight => state.line -= 8,
                .decrement_line_nine => state.line -= 9,
                .decrement_line_ten => state.line -= 10,
                .decrement_line_eleven => state.line -= 11,
                .decrement_line_twelve => state.line -= 12,
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

        pub fn file(location: Location, file_table: FileTable) !FileEntry {
            return file_table.getFile(location.file_index) orelse error.NoSuchFile;
        }

        pub fn symbol(location: Location, string_table: StringTable) [:0]const u8 {
            return string_table.getString(location.symbol_offset);
        }
    };
};

pub const LocationProgramOpcode = enum(u8) {
    /// Add the subsequent ULEB128 encoded number to the `address` register.
    offset_address = 0x1,

    /// Increment the `address` register by two.
    increment_address_two = 0x2,

    /// Increment the `address` register by three.
    increment_address_three = 0x3,

    /// Increment the `address` register by four.
    increment_address_four = 0x4,

    /// Increment the `address` register by five.
    increment_address_five = 0x5,

    /// Increment the `address` register by six.
    increment_address_six = 0x6,

    /// Increment the `address` register by seven.
    increment_address_seven = 0x7,

    /// Increment the `address` register by eight.
    increment_address_eight = 0x8,

    /// Increment the `address` register by nine.
    increment_address_nine = 0x9,

    /// Increment the `address` register by ten.
    increment_address_ten = 0xA,

    /// Increment the `address` register by eleven.
    increment_address_eleven = 0xB,

    /// Increment the `address` register by twelve.
    increment_address_twelve = 0xC,

    /// Increment the `address` register by thirteen.
    increment_address_thirteen = 0xD,

    /// Increment the `address` register by fourteen.
    increment_address_fourteen = 0xE,

    /// Increment the `address` register by fifteen.
    increment_address_fifteen = 0xF,

    /// Increment the `address` register by sixteen.
    increment_address_sixteen = 0x10,

    /// Increment the `address` register by seventeen.
    increment_address_seventeen = 0x11,

    /// Increment the `address` register by eighteen.
    increment_address_eighteen = 0x12,

    /// Increment the `address` register by nineteen.
    increment_address_nineteen = 0x13,

    /// Increment the `address` register by twenty.
    increment_address_twenty = 0x14,

    /// Increment the `address` register by twenty one.
    increment_address_twenty_one = 0x15,

    /// Increment the `address` register by twenty two.
    increment_address_twenty_two = 0x16,

    /// Increment the `address` register by twenty three.
    increment_address_twenty_three = 0x17,

    /// Increment the `address` register by twenty four.
    increment_address_twenty_four = 0x18,

    /// Increment the `address` register by twenty five.
    increment_address_twenty_five = 0x19,

    /// Increment the `address` register by twenty six.
    increment_address_twenty_six = 0x1A,

    /// Increment the `address` register by twenty seven.
    increment_address_twenty_seven = 0x1B,

    /// Increment the `address` register by twenty eight.
    increment_address_twenty_eight = 0x1C,

    /// Increment the `address` register by twenty nine.
    increment_address_twenty_nine = 0x1D,

    /// Increment the `address` register by thirty.
    increment_address_thirty = 0x1E,

    /// Increment the `address` register by thirty one.
    increment_address_thirty_one = 0x1F,

    /// Increment the `address` register by thirty two.
    increment_address_thirty_two = 0x20,

    /// Set the `symbol_offset` register to the subsequent ULEB128 encoded number.
    set_symbol_offset = 0x21,

    /// Set the `file_index` register to the subsequent ULEB128 encoded number.
    set_file_index = 0x22,

    /// Add the subsequent SLEB128 encoded number to the `column` register using a wrapping operation.
    offset_column = 0x23,

    /// Add the subsequent SLEB128 encoded number to the `line` register using a wrapping operation.
    offset_line = 0x24,

    /// Increment the `line` register by one.
    increment_line_one = 0x25,

    /// Increment the `line` register by two.
    increment_line_two = 0x26,

    /// Increment the `line` register by three.
    increment_line_three = 0x27,

    /// Increment the `line` register by four.
    increment_line_four = 0x28,

    /// Increment the `line` register by five.
    increment_line_five = 0x29,

    /// Increment the `line` register by six.
    increment_line_six = 0x2A,

    /// Increment the `line` register by seven.
    increment_line_seven = 0x2B,

    /// Increment the `line` register by eight.
    increment_line_eight = 0x2C,

    /// Increment the `line` register by nine.
    increment_line_nine = 0x2D,

    /// Increment the `line` register by ten.
    increment_line_ten = 0x2E,

    /// Increment the `line` register by eleven.
    increment_line_eleven = 0x2F,

    /// Increment the `line` register by twelve.
    increment_line_twelve = 0x30,

    /// Decrement the `line` register by one.
    decrement_line_one = 0x31,

    /// Decrement the `line` register by two.
    decrement_line_two = 0x32,

    /// Decrement the `line` register by three.
    decrement_line_three = 0x33,

    /// Decrement the `line` register by four.
    decrement_line_four = 0x34,

    /// Decrement the `line` register by five.
    decrement_line_five = 0x35,

    /// Decrement the `line` register by six.
    decrement_line_six = 0x36,

    /// Decrement the `line` register by seven.
    decrement_line_seven = 0x37,

    /// Decrement the `line` register by eight.
    decrement_line_eight = 0x38,

    /// Decrement the `line` register by nine.
    decrement_line_nine = 0x39,

    /// Decrement the `line` register by ten.
    decrement_line_ten = 0x3A,

    /// Decrement the `line` register by eleven.
    decrement_line_eleven = 0x3B,

    /// Decrement the `line` register by twelve.
    decrement_line_twelve = 0x3C,
};

pub const LocationProgramInstruction = union(LocationProgramOpcode) {
    offset_address: u64,
    increment_address_two,
    increment_address_three,
    increment_address_four,
    increment_address_five,
    increment_address_six,
    increment_address_seven,
    increment_address_eight,
    increment_address_nine,
    increment_address_ten,
    increment_address_eleven,
    increment_address_twelve,
    increment_address_thirteen,
    increment_address_fourteen,
    increment_address_fifteen,
    increment_address_sixteen,
    increment_address_seventeen,
    increment_address_eighteen,
    increment_address_nineteen,
    increment_address_twenty,
    increment_address_twenty_one,
    increment_address_twenty_two,
    increment_address_twenty_three,
    increment_address_twenty_four,
    increment_address_twenty_five,
    increment_address_twenty_six,
    increment_address_twenty_seven,
    increment_address_twenty_eight,
    increment_address_twenty_nine,
    increment_address_thirty,
    increment_address_thirty_one,
    increment_address_thirty_two,
    set_symbol_offset: u64,
    set_file_index: u64,
    offset_column: i64,
    offset_line: i64,
    increment_line_one,
    increment_line_two,
    increment_line_three,
    increment_line_four,
    increment_line_five,
    increment_line_six,
    increment_line_seven,
    increment_line_eight,
    increment_line_nine,
    increment_line_ten,
    increment_line_eleven,
    increment_line_twelve,
    decrement_line_one,
    decrement_line_two,
    decrement_line_three,
    decrement_line_four,
    decrement_line_five,
    decrement_line_six,
    decrement_line_seven,
    decrement_line_eight,
    decrement_line_nine,
    decrement_line_ten,
    decrement_line_eleven,
    decrement_line_twelve,

    pub fn read(reader: *std.Io.Reader) !LocationProgramInstruction {
        const opcode: LocationProgramOpcode = @enumFromInt(try reader.takeByte());

        return switch (opcode) {
            .offset_address => .{ .offset_address = try reader.takeLeb128(u64) },
            .set_symbol_offset => .{ .set_symbol_offset = try reader.takeLeb128(u64) },
            .set_file_index => .{ .set_file_index = try reader.takeLeb128(u64) },
            .offset_column => .{ .offset_column = try reader.takeLeb128(i64) },
            .offset_line => .{ .offset_line = try reader.takeLeb128(i64) },
            inline else => |op| op,
        };
    }

    pub fn write(location_program_instruction: LocationProgramInstruction, writer: *std.Io.Writer) !void {
        try writer.writeByte(@intFromEnum(location_program_instruction));

        switch (location_program_instruction) {
            .offset_address => |value| try writer.writeLeb128(value),
            .set_symbol_offset => |value| try writer.writeLeb128(value),
            .set_file_index => |value| try writer.writeLeb128(value),
            .offset_column => |value| try writer.writeLeb128(value),
            .offset_line => |value| try writer.writeLeb128(value),
            .increment_address_two,
            .increment_address_three,
            .increment_address_four,
            .increment_address_five,
            .increment_address_six,
            .increment_address_seven,
            .increment_address_eight,
            .increment_address_nine,
            .increment_address_ten,
            .increment_address_eleven,
            .increment_address_twelve,
            .increment_address_thirteen,
            .increment_address_fourteen,
            .increment_address_fifteen,
            .increment_address_sixteen,
            .increment_address_seventeen,
            .increment_address_eighteen,
            .increment_address_nineteen,
            .increment_address_twenty,
            .increment_address_twenty_one,
            .increment_address_twenty_two,
            .increment_address_twenty_three,
            .increment_address_twenty_four,
            .increment_address_twenty_five,
            .increment_address_twenty_six,
            .increment_address_twenty_seven,
            .increment_address_twenty_eight,
            .increment_address_twenty_nine,
            .increment_address_thirty,
            .increment_address_thirty_one,
            .increment_address_thirty_two,
            .increment_line_one,
            .increment_line_two,
            .increment_line_three,
            .increment_line_four,
            .increment_line_five,
            .increment_line_six,
            .increment_line_seven,
            .increment_line_eight,
            .increment_line_nine,
            .increment_line_ten,
            .increment_line_eleven,
            .increment_line_twelve,
            .decrement_line_one,
            .decrement_line_two,
            .decrement_line_three,
            .decrement_line_four,
            .decrement_line_five,
            .decrement_line_six,
            .decrement_line_seven,
            .decrement_line_eight,
            .decrement_line_nine,
            .decrement_line_ten,
            .decrement_line_eleven,
            .decrement_line_twelve,
            => {},
        }
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
