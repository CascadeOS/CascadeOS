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

    switch (arguments) {
        .generate => |generate_arguments| try generate(allocator, generate_arguments),
        .embed => |embed_arguments| try embed(allocator, embed_arguments),
    }
}

fn generate(allocator: std.mem.Allocator, generate_arguments: Arguments.GenerateArguments) !void {
    const line_debug_info = try getDwarfLineDebugInfo(allocator, generate_arguments.binary_input_path);

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
        generate_arguments.directory_prefixes_to_strip,
    );

    const created_debug_info = try createSdfDebugInfo(
        allocator,
        &string_table,
        &file_table,
        &location_lookup,
        &location_program,
    );

    const output_file = try std.fs.cwd().createFile(generate_arguments.binary_output_path, .{});
    defer output_file.close();

    try output_file.writeAll(created_debug_info);
}

fn embed(allocator: std.mem.Allocator, embed_arguments: Arguments.EmbedArguments) !void {
    var atomic_output_file = blk: {
        const binary_input_file = try std.fs.cwd().openFile(embed_arguments.binary_input_path, .{});
        defer binary_input_file.close();

        const binary_input_file_stat = try binary_input_file.stat();

        const atomic_output_file = try custom_atomic_file.atomicFileReadAndWrite(
            std.fs.cwd(),
            embed_arguments.binary_output_path,
            .{ .mode = binary_input_file_stat.mode },
        );

        try atomic_output_file.file.writeFileAll(binary_input_file, .{});

        break :blk atomic_output_file;
    };
    defer atomic_output_file.deinit();

    const output_file = atomic_output_file.file;

    // ensure sdf data is 8 byte aligned
    const sdf_pos = blk: {
        const end_pos = try output_file.getEndPos();
        const aligned_end_pos = std.mem.alignForward(u64, end_pos, 8);
        if (end_pos != aligned_end_pos) try output_file.setEndPos(aligned_end_pos);
        break :blk aligned_end_pos;
    };

    // append sdf data to the end of the elf file
    const sdf_size = blk: {
        const sdf_input_file = try std.fs.cwd().openFile(embed_arguments.sdf_input_path, .{});
        defer sdf_input_file.close();

        const sdf_stat = try sdf_input_file.stat();

        _ = try sdf_input_file.copyRangeAll(0, output_file, sdf_pos, sdf_stat.size);

        break :blk sdf_stat.size;
    };

    // add new section to the elf file
    {
        // read the elf header into a buffer
        var elf_header_backing_buffer: [@sizeOf(std.elf.Elf64_Ehdr)]u8 align(@alignOf(std.elf.Elf64_Ehdr)) = undefined;
        try output_file.seekTo(0);
        const elf_header_buffer = elf_header_backing_buffer[0..try output_file.readAll(&elf_header_backing_buffer)];

        const elf_header_elf32: *std.elf.Elf32_Ehdr = std.mem.bytesAsValue(std.elf.Elf32_Ehdr, elf_header_buffer);

        if (!std.mem.eql(u8, elf_header_elf32.e_ident[0..4], std.elf.MAGIC)) return error.InvalidElfMagic;
        if (elf_header_elf32.e_ident[std.elf.EI_VERSION] != 1) return error.InvalidElfVersion;

        if (elf_header_elf32.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.BigEndianElf; // TODO: Support big endian

        const is_64: bool = switch (elf_header_elf32.e_ident[std.elf.EI_CLASS]) {
            std.elf.ELFCLASS32 => false,
            std.elf.ELFCLASS64 => true,
            else => return error.InvalidElfClass,
        };

        const elf_header_elf64: *std.elf.Elf64_Ehdr = std.mem.bytesAsValue(std.elf.Elf64_Ehdr, elf_header_buffer);

        const old_section_table_offset: u64, const old_number_of_sections, const section_entry_size, const section_string_index =
            if (is_64)
            .{ elf_header_elf64.e_shoff, elf_header_elf64.e_shnum, elf_header_elf64.e_shentsize, elf_header_elf64.e_shstrndx }
        else
            .{ elf_header_elf32.e_shoff, elf_header_elf32.e_shnum, elf_header_elf32.e_shentsize, elf_header_elf32.e_shstrndx };
        std.debug.assert(section_entry_size == @as(u16, if (is_64) @sizeOf(std.elf.Elf64_Shdr) else @sizeOf(std.elf.Elf32_Shdr)));

        const old_section_table_size = old_number_of_sections * section_entry_size;

        // allocate a buffer for building the new section table with enough space for one extra entry
        const section_table_buffer = try allocator.alloc(u8, old_section_table_size + section_entry_size);
        defer allocator.free(section_table_buffer);

        // read the old section table into `section_table_buffer`
        try output_file.seekTo(old_section_table_offset);
        std.debug.assert(try output_file.readAll(section_table_buffer[0..old_section_table_size]) == old_section_table_size);

        const section_string_entry_buffer = section_table_buffer[section_entry_size * section_string_index ..][0..section_entry_size];

        const old_section_string_offset: u64, const old_section_string_size: u64 =
            if (is_64)
        blk: {
            const section_header = std.mem.bytesAsValue(std.elf.Elf64_Shdr, section_string_entry_buffer);
            break :blk .{ section_header.sh_offset, section_header.sh_size };
        } else blk: {
            const section_header = std.mem.bytesAsValue(std.elf.Elf32_Shdr, section_string_entry_buffer);
            break :blk .{ section_header.sh_offset, section_header.sh_size };
        };

        // copy the old section header string section to the end of the elf file
        const section_string_offset = try output_file.getEndPos();
        std.debug.assert(try output_file.copyRangeAll(
            old_section_string_offset,
            output_file,
            section_string_offset,
            old_section_string_size,
        ) == old_section_string_size);

        const sdf_section_name = ".sdf\x00";

        // add the string for the sdf section's header to end of the new section header name section
        const sdf_section_name_file_offset = try output_file.getEndPos();
        const sdf_section_name_offset: u32 = @intCast(sdf_section_name_file_offset - section_string_offset);

        try output_file.seekTo(sdf_section_name_file_offset);
        try output_file.writeAll(sdf_section_name);

        // update the section header string section's offset and size
        if (is_64) {
            const section_header = std.mem.bytesAsValue(std.elf.Elf64_Shdr, section_string_entry_buffer);
            section_header.sh_offset = section_string_offset;
            section_header.sh_size = old_section_string_size + sdf_section_name.len;
        } else {
            const section_header = std.mem.bytesAsValue(std.elf.Elf32_Shdr, section_string_entry_buffer);
            section_header.sh_offset = @intCast(section_string_offset);
            section_header.sh_size = @intCast(old_section_string_size + sdf_section_name.len);
        }

        // fill in the new section header entry (last entry in the table) with the sdf section's data
        if (is_64) {
            const sdf_section_header = std.mem.bytesAsValue(std.elf.Elf64_Shdr, section_table_buffer[old_section_table_size..]);
            sdf_section_header.* = .{
                .sh_name = sdf_section_name_offset,
                .sh_type = std.elf.SHT_LOUSER,
                .sh_flags = std.elf.SHF_ALLOC,
                .sh_addr = 0,
                .sh_offset = sdf_pos,
                .sh_size = sdf_size,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 8,
                .sh_entsize = 0,
            };
        } else {
            const sdf_section_header = std.mem.bytesAsValue(std.elf.Elf32_Shdr, section_table_buffer[old_section_table_size..]);
            sdf_section_header.* = .{
                .sh_name = sdf_section_name_offset,
                .sh_type = std.elf.SHT_LOUSER,
                .sh_flags = std.elf.SHF_ALLOC,
                .sh_addr = 0,
                .sh_offset = @intCast(sdf_pos),
                .sh_size = @intCast(sdf_size),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 8,
                .sh_entsize = 0,
            };
        }

        // write the new section table to the end of the elf file
        const section_table_offset = try output_file.getEndPos();
        try output_file.seekTo(section_table_offset);
        try output_file.writeAll(section_table_buffer);

        // update the in memory elf header
        if (is_64) {
            elf_header_elf64.e_shoff = section_table_offset;
            elf_header_elf64.e_shnum = old_number_of_sections + 1;
        } else {
            elf_header_elf32.e_shoff = @intCast(section_table_offset);
            elf_header_elf32.e_shnum = old_number_of_sections + 1;
        }

        // overwrite the file's elf header with the in memory one
        try output_file.seekTo(0);
        try output_file.writeAll(elf_header_buffer);
    }

    std.fs.cwd().deleteFile(embed_arguments.binary_output_path) catch {};
    try atomic_output_file.finish();
}

const Action = enum {
    generate,
    embed,
};

const Arguments = union(Action) {
    generate: GenerateArguments,
    embed: EmbedArguments,

    pub const GenerateArguments = struct {
        binary_input_path: [:0]const u8,
        binary_output_path: [:0]const u8,
        directory_prefixes_to_strip: []const []const u8,
    };

    pub const EmbedArguments = struct {
        binary_input_path: [:0]const u8,
        binary_output_path: [:0]const u8,
        sdf_input_path: [:0]const u8,
    };
};

const usage =
    \\
    \\
;

fn argumentError(comptime msg: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();

    if (msg.len == 0) @compileError("no message given");

    blk: {
        stderr.writeAll("error: ") catch break :blk;

        stderr.print(msg, args) catch break :blk;

        if (msg[msg.len - 1] != '\n') {
            stderr.writeAll("\n\n") catch break :blk;
        } else {
            stderr.writeByte('\n') catch break :blk;
        }

        stderr.writeAll(usage) catch break :blk;
    }

    std.process.exit(1);
}

fn getArguments(allocator: std.mem.Allocator) !Arguments {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    if (!args_iter.skip()) argumentError("no self path argument?", .{});

    const action = blk: {
        const action_string = args_iter.next() orelse
            argumentError("no action given", .{});

        break :blk std.meta.stringToEnum(Action, action_string) orelse
            argumentError("'{s}' is not a valid action", .{action_string});
    };

    const binary_input_path: [:0]const u8 = try allocator.dupeZ(u8, args_iter.next() orelse
        argumentError("no binary_input_path given", .{}));
    errdefer allocator.free(binary_input_path);

    const binary_output_path: [:0]const u8 = try allocator.dupeZ(u8, args_iter.next() orelse
        argumentError("no binary_output_path given", .{}));
    errdefer allocator.free(binary_output_path);

    switch (action) {
        .generate => {
            var directory_prefixes_to_strip = std.ArrayList([]const u8).init(allocator);
            errdefer directory_prefixes_to_strip.deinit();

            while (args_iter.next()) |arg| {
                try directory_prefixes_to_strip.append(try allocator.dupe(u8, arg));
            }

            return .{
                .generate = .{
                    .binary_input_path = binary_input_path,
                    .binary_output_path = binary_output_path,
                    .directory_prefixes_to_strip = try directory_prefixes_to_strip.toOwnedSlice(),
                },
            };
        },
        .embed => {
            const sdf_input_path: [:0]const u8 = try allocator.dupeZ(u8, args_iter.next() orelse
                argumentError("no sdf_input_path given", .{}));
            errdefer allocator.free(sdf_input_path);

            return .{
                .embed = .{
                    .binary_input_path = binary_input_path,
                    .binary_output_path = binary_output_path,
                    .sdf_input_path = sdf_input_path,
                },
            };
        },
    }
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
            .total_size_of_sdf_data = output_buffer.items.len,
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

const custom_atomic_file = struct {
    /// The same as `std.fs.Dir.atomicFile` but it opens the file as read and write
    fn atomicFileReadAndWrite(
        self: std.fs.Dir,
        dest_path: []const u8,
        options: std.fs.Dir.AtomicFileOptions,
    ) !std.fs.AtomicFile {
        if (std.fs.path.dirname(dest_path)) |dirname| {
            const dir = if (options.make_path)
                try self.makeOpenPath(dirname, .{})
            else
                try self.openDir(dirname, .{});

            return atomicFileInitReadAndWrite(std.fs.path.basename(dest_path), options.mode, dir, true);
        } else {
            return atomicFileInitReadAndWrite(dest_path, options.mode, self, false);
        }
    }

    const random_bytes_len = 12;
    const tmp_path_len = std.fs.base64_encoder.calcSize(random_bytes_len);

    /// The same as `std.fs.AtomicFile.init` but it opens the file as read and write
    fn atomicFileInitReadAndWrite(
        dest_basename: []const u8,
        mode: std.fs.File.Mode,
        dir: std.fs.Dir,
        close_dir_on_deinit: bool,
    ) std.fs.AtomicFile.InitError!std.fs.AtomicFile {
        var rand_buf: [random_bytes_len]u8 = undefined;
        var tmp_path_buf: [tmp_path_len:0]u8 = undefined;

        while (true) {
            std.crypto.random.bytes(rand_buf[0..]);
            const tmp_path = std.fs.base64_encoder.encode(&tmp_path_buf, &rand_buf);
            tmp_path_buf[tmp_path.len] = 0;

            const file = dir.createFile(
                tmp_path,
                .{ .mode = mode, .exclusive = true, .read = true },
            ) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };

            return std.fs.AtomicFile{
                .file = file,
                .tmp_path_buf = tmp_path_buf,
                .dest_basename = dest_basename,
                .file_open = true,
                .file_exists = true,
                .close_dir_on_deinit = close_dir_on_deinit,
                .dir = dir,
            };
        }
    }
};

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
