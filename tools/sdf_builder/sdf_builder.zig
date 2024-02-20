// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const libdwarf = @import("libdwarf.zig");

const sdf = @import("sdf");

const FileTableBuilder = @import("FileTableBuilder.zig");
const LocationLookupBuilder = @import("LocationLookupBuilder.zig");
const LocationProgramBuilder = @import("LocationProgramBuilder.zig");
const StringTableBuilder = @import("StringTableBuilder.zig");

const default_chunk_size = 8 * 1024;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const arguments = try getArguments(allocator);

    const line_debug_info = try getDwarfLineDebugInfo(allocator, arguments.input_path);

    var string_table: StringTableBuilder = .{ .allocator = allocator };
    var file_table: FileTableBuilder = .{ .allocator = allocator };
    var location_lookup: LocationLookupBuilder = .{ .allocator = allocator };
    var location_program = LocationProgramBuilder.init(allocator);

    try fillInBuilders(
        line_debug_info,
        default_chunk_size,
        &string_table,
        &file_table,
        &location_lookup,
        &location_program,
        arguments.directory_prefixes_to_strip,
    );

    const created_debug_info = try createSdfDebugInfo(
        allocator,
        &string_table,
        &file_table,
        &location_lookup,
        &location_program,
    );

    const output_file = try std.fs.cwd().createFile(arguments.output_path, .{});
    defer output_file.close();

    try output_file.writeAll(created_debug_info);
}

const Arguments = struct {
    input_path: [:0]const u8,
    output_path: [:0]const u8,
    directory_prefixes_to_strip: []const []const u8,
};

fn getArguments(allocator: std.mem.Allocator) !Arguments {
    const args = try std.process.argsAlloc(allocator);

    // TODO: Improve the argument parsing here

    const input_path = blk: {
        if (args.len < 2) return error.NoInputPath;
        break :blk args[1];
    };

    const output_path = blk: {
        if (args.len < 3) return error.NoOutputPath;
        break :blk args[2];
    };

    var directory_prefixes_to_strip = std.ArrayList([]const u8).init(allocator);
    errdefer directory_prefixes_to_strip.deinit();

    if (args.len > 3) {
        for (args[3..]) |arg| {
            try directory_prefixes_to_strip.append(try allocator.dupe(u8, arg));
        }
    }

    return .{
        .input_path = try allocator.dupeZ(u8, input_path),
        .output_path = try allocator.dupeZ(u8, output_path),
        .directory_prefixes_to_strip = try directory_prefixes_to_strip.toOwnedSlice(),
    };
}

const LineDebugInfo = struct {
    address: u64,
    file: []const u8,
    symbol: []const u8,
    line: u64,
    column: u64,

    pub fn lessThanFn(_: void, lhs: LineDebugInfo, rhs: LineDebugInfo) bool {
        return lhs.address < rhs.address;
    }
};

fn getDwarfLineDebugInfo(allocator: std.mem.Allocator, input_path: [:0]const u8) ![]const LineDebugInfo {
    const dwarf_debug = libdwarf.initPath(input_path);

    var result = std.ArrayList(LineDebugInfo).init(allocator);

    while (dwarf_debug.nextCompileUnit()) |compile_unit| {
        const function_low_highs = try collectFunctionLowHighs(
            allocator,
            dwarf_debug,
            compile_unit,
        );

        const line_context = compile_unit.getLineContext();

        const lines = line_context.getLines();

        try result.ensureUnusedCapacity(lines.len);

        for (lines) |line| {
            const address = line.address();

            const line_number = line.line();
            const column = line.column();

            const symbol = blk: {
                var candidate_stack = std.ArrayList(FunctionLowHigh).init(allocator);
                defer candidate_stack.deinit();

                var opt_best_candidate: ?FunctionLowHigh = null;

                for (function_low_highs) |function_low_high| {
                    if (address >= function_low_high.low_pc and address < function_low_high.high_pc) {
                        opt_best_candidate = function_low_high;
                    }
                }

                if (opt_best_candidate) |best_candidate| break :blk best_candidate.symbol;

                break :blk "UNKNOWN";
            };

            result.appendAssumeCapacity(.{
                .address = address,
                .file = line.file(),
                .symbol = symbol,
                .line = line_number,
                .column = column,
            });
        }
    }

    std.sort.insertion(LineDebugInfo, result.items, {}, LineDebugInfo.lessThanFn);

    return try result.toOwnedSlice();
}

const FunctionLowHigh = struct {
    low_pc: u64,
    high_pc: u64,
    symbol: []const u8,

    fn lessThanFn(_: void, lhs: FunctionLowHigh, rhs: FunctionLowHigh) bool {
        if (lhs.low_pc < rhs.low_pc) return true;
        return false;
    }
};

fn collectFunctionLowHighs(
    allocator: std.mem.Allocator,
    dwarf_debug: libdwarf.DwarfDebug,
    compile_unit: libdwarf.CompileUnit,
) ![]const FunctionLowHigh {
    var result = std.ArrayList(FunctionLowHigh).init(allocator);

    const compile_unit_die = compile_unit.getDie();

    const compile_unit_ranges_base: u64 =
        if (compile_unit_die.getAttribute(.rnglists_base)) |rnglists_base_attribute|
        rnglists_base_attribute.sectionRelativeOffset()
    else
        0;

    try collectFunctionLowHighsRecurse(
        &result,
        dwarf_debug,
        compile_unit_die,
        compile_unit_ranges_base,
    );

    std.sort.insertion(FunctionLowHigh, result.items, {}, FunctionLowHigh.lessThanFn);

    return try result.toOwnedSlice();
}

fn collectFunctionLowHighsRecurse(
    result: *std.ArrayList(FunctionLowHigh),
    dwarf_debug: libdwarf.DwarfDebug,
    die: libdwarf.Die,
    compile_unit_ranges_base: u64,
) !void {
    var opt_current_die: ?libdwarf.Die = die;

    // iterate through the die and its siblings
    while (opt_current_die) |current_die| : ({
        if (current_die.child()) |child| try collectFunctionLowHighsRecurse(
            result,
            dwarf_debug,
            child,
            compile_unit_ranges_base,
        );

        opt_current_die = current_die.nextSibling();
    }) {
        switch (current_die.tag()) {
            .subprogram, .subroutine, .inlined_subroutine => {
                const name = current_die.name(dwarf_debug) orelse "NO_NAME";

                if (current_die.getLowHighPC()) |low_high| {
                    try result.append(.{
                        .low_pc = low_high.low_pc,
                        .high_pc = low_high.high_pc,
                        .symbol = name,
                    });
                    continue;
                }

                const ranges_attribute = current_die.getAttribute(.ranges) orelse continue;
                const ranges_offset = ranges_attribute.sectionRelativeOffset();

                const offset = compile_unit_ranges_base + ranges_offset;
                const ranges = dwarf_debug.getRanges(offset, current_die);

                var base_address = compile_unit_ranges_base;

                for (ranges) |range| {
                    switch (range.getType()) {
                        .ENTRY => {
                            try result.append(.{
                                .low_pc = base_address + range.address1(),
                                .high_pc = base_address + range.address2(),
                                .symbol = name,
                            });
                        },
                        .ADDRESS_SELECTION => base_address = range.address2(),
                        .END => {},
                    }
                }
            },
            else => {},
        }
    }
}

fn fillInBuilders(
    line_debug_info: []const LineDebugInfo,
    maximum_size_of_chunks: u64,
    string_table: *StringTableBuilder,
    file_table: *FileTableBuilder,
    location_lookup: *LocationLookupBuilder,
    location_program: *LocationProgramBuilder,
    directory_prefixes_to_strip: []const []const u8,
) !void {
    var previous_address: u64 = 0;
    var next_chunk_start_address = previous_address + maximum_size_of_chunks;
    var previous_line: i64 = 0;
    var previous_column: i64 = 0;
    var previous_file: ?[]const u8 = null;
    var previous_directory: ?[]const u8 = null;
    var previous_file_index: u64 = undefined; // valid if `previous_file` and `previous_directory` is not null
    var previous_symbol: ?[]const u8 = null;
    var previous_symbol_index: u64 = undefined; // valid if `previous_symbol` is not null

    try location_lookup.addLocationLookup(
        location_program.currentOffset(),
        previous_address,
        previous_file_index,
        previous_symbol_index,
        @intCast(previous_line),
        @intCast(previous_column),
    );

    for (line_debug_info) |line_info| {
        std.debug.assert(line_info.address >= previous_address);

        const new_address = line_info.address;
        const new_line: i64 = @intCast(line_info.line);
        const new_column: i64 = @intCast(line_info.column);

        const directory = blk: {
            const directory = std.fs.path.dirname(line_info.file) orelse {
                core.panicFmt("path with no directory: '{s}'", .{line_info.file});
            };

            for (directory_prefixes_to_strip) |directory_prefix_to_strip| {
                if (std.mem.startsWith(u8, directory, directory_prefix_to_strip)) {
                    break :blk directory[directory_prefix_to_strip.len..];
                }
            }

            break :blk directory;
        };

        const file = std.fs.path.basename(line_info.file);

        const line_changed = new_line != 0 and new_line != previous_line;
        const column_changed = new_column != 0 and new_column != previous_column;
        const file_changed = !std.mem.eql(
            u8,
            previous_file orelse "",
            file,
        ) or !std.mem.eql(
            u8,
            previous_directory orelse "",
            directory,
        );
        const symbol_changed = !std.mem.eql(u8, previous_symbol orelse "", line_info.symbol);

        if (!(line_changed or column_changed or file_changed or symbol_changed)) continue;

        if (new_address >= next_chunk_start_address) {
            try location_lookup.addLocationLookup(
                location_program.currentOffset(),
                previous_address,
                previous_file_index,
                previous_symbol_index,
                @intCast(previous_line),
                @intCast(previous_column),
            );
            next_chunk_start_address = line_info.address + maximum_size_of_chunks;
        }

        // address instruction
        {
            const difference: u64 = new_address - previous_address;

            switch (difference) {
                4 => try location_program.addInstruction(.increment_address_four),
                8 => try location_program.addInstruction(.increment_address_eight),
                12 => try location_program.addInstruction(.increment_address_twelve),
                16 => try location_program.addInstruction(.increment_address_sixteen),
                else => try location_program.addInstruction(.{ .offset_address = difference }),
            }

            previous_address = new_address;
        }

        if (line_changed) {
            const difference = new_line - previous_line;

            switch (difference) {
                1 => try location_program.addInstruction(.increment_line_one),
                2 => try location_program.addInstruction(.increment_line_two),
                3 => try location_program.addInstruction(.increment_line_three),
                4 => try location_program.addInstruction(.increment_line_four),
                5 => try location_program.addInstruction(.increment_line_five),
                -1 => try location_program.addInstruction(.decrement_line_one),
                -2 => try location_program.addInstruction(.decrement_line_two),
                -3 => try location_program.addInstruction(.decrement_line_three),
                -4 => try location_program.addInstruction(.decrement_line_four),
                -5 => try location_program.addInstruction(.decrement_line_five),
                else => try location_program.addInstruction(.{ .offset_line = difference }),
            }

            previous_line = new_line;
        }

        if (column_changed) {
            try location_program.addInstruction(.{ .offset_column = new_column - previous_column });
            previous_column = new_column;
        }

        if (file_changed) {
            const directory_offset = try string_table.addString(directory);
            const file_offset = try string_table.addString(file);

            const file_index = try file_table.addFile(.{
                .directory_offset = directory_offset,
                .file_offset = file_offset,
            });

            try location_program.addInstruction(.{ .set_file_index = file_index });

            previous_file = file;
            previous_directory = directory;
            previous_file_index = file_index;
        }

        if (symbol_changed) {
            const symbol_string_offset = try string_table.addString(line_info.symbol);

            try location_program.addInstruction(.{ .set_symbol_offset = symbol_string_offset });

            previous_symbol = line_info.symbol;
            previous_symbol_index = symbol_string_offset;
        }
    }
}

fn createSdfDebugInfo(
    allocator: std.mem.Allocator,
    string_table: *const StringTableBuilder,
    file_table: *const FileTableBuilder,
    location_lookup: *const LocationLookupBuilder,
    location_program: *const LocationProgramBuilder,
) ![]const u8 {
    var output_buffer = std.ArrayList(u8).init(allocator);

    // save space for the header
    try output_buffer.appendNTimes(0, @sizeOf(sdf.Header));

    const string_table_offset, const string_table_length = try string_table.output(&output_buffer);
    const file_table_offset, const file_table_entries = try file_table.output(&output_buffer);
    const location_lookup_offset, const location_program_states_offset, const location_lookup_entries = try location_lookup.output(&output_buffer);
    const location_program_offset, const location_program_length = try location_program.output(&output_buffer);

    // write out header
    {
        var header_stream = std.io.fixedBufferStream(output_buffer.items[0..@sizeOf(sdf.Header)]);
        const header_writer = header_stream.writer();

        try sdf.Header.write(.{
            .string_table_offset = string_table_offset,
            .string_table_length = string_table_length,
            .file_table_offset = file_table_offset,
            .file_table_entries = file_table_entries,
            .location_lookup_offset = location_lookup_offset,
            .location_program_states_offset = location_program_states_offset,
            .location_lookup_entries = location_lookup_entries,
            .location_program_offset = location_program_offset,
            .location_program_length = location_program_length,
        }, header_writer);
    }

    return try output_buffer.toOwnedSlice();
}

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
