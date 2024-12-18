// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// This is the runtime selected panic implementation.
pub var panic_impl: *const fn (
    context: *kernel.Context,
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void = struct {
    fn noOpPanic(
        context: *kernel.Context,
        msg: []const u8,
        error_return_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        _ = context;
        _ = msg;
        _ = error_return_trace;
        _ = return_address;
    }
}.noOpPanic;

/// Entry point from the Zig language upon a panic.
fn zigPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @branchHint(.cold);

    const context = kernel.Context.getCurrent();
    context.incrementInterruptDisable();

    panic_impl(
        context,
        msg,
        error_return_trace,
        return_address_opt orelse @returnAddress(),
    );

    while (true) {
        arch.interrupts.disableInterruptsAndHalt();
    }
}

pub const formatting = struct {
    pub fn printPanic(
        writer: anytype,
        msg: []const u8,
        error_return_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) !void {
        try printUserPanicMessage(writer, msg);
        try printErrorAndCurrentStackTrace(writer, error_return_trace, return_address);
    }

    fn printUserPanicMessage(writer: anytype, msg: []const u8) !void {
        if (msg.len != 0) {
            try writer.writeAll("\nPANIC - ");

            try writer.writeAll(msg);

            if (msg[msg.len - 1] != '\n') {
                try writer.writeByte('\n');
            }
        } else {
            try writer.writeAll("\nPANIC\n");
        }
    }

    fn printErrorAndCurrentStackTrace(
        writer: anytype,
        error_return_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) !void {
        const symbol_source = SymbolSource.load();

        if (error_return_trace) |trace| {
            if (trace.index != 0) {
                try printStackTrace(writer, trace, symbol_source);
            }
        }

        try printCurrentBackTrace(writer, return_address, symbol_source);
    }

    fn printCurrentBackTrace(
        writer: anytype,
        return_address: usize,
        symbol_source: ?SymbolSource,
    ) !void {
        var stack_iter: std.debug.StackIterator = .init(return_address, @frameAddress());

        while (stack_iter.next()) |address| {
            try printSourceAtAddress(writer, address, symbol_source);
        }
    }

    fn printStackTrace(
        writer: anytype,
        stack_trace: *const std.builtin.StackTrace,
        symbol_source: ?SymbolSource,
    ) !void {
        var frame_index: usize = 0;
        var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);

        var first_addr_opt: ?usize = null;
        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
        }) {
            const return_address = stack_trace.instruction_addresses[frame_index];
            if (first_addr_opt == null) first_addr_opt = return_address;

            try printSourceAtAddress(writer, return_address, symbol_source);
        }
    }

    const indent = "  ";

    fn printSourceAtAddress(writer: anytype, address: usize, opt_symbol_source: ?SymbolSource) !void {
        if (address == 0) return;

        if (address < arch.paging.higher_half_start.value) {
            try writer.writeAll(comptime indent ++ "0x");
            try std.fmt.formatInt(
                address,
                16,
                .lower,
                .{},
                writer,
            );
            try writer.writeAll(" - address is not in the higher half so must be userspace\n");
            return;
        }

        const opt_kernel_virtual_offset = if (kernel.mem.globals.virtual_offset) |offset|
            offset.value
        else
            null;

        // we can't use `VirtualAddress` here as it is possible this subtraction results in a non-canonical address
        const kernel_source_address = address - (opt_kernel_virtual_offset orelse 0);

        const symbol = blk: {
            const symbol_source = opt_symbol_source orelse break :blk null;
            break :blk symbol_source.getSymbol(kernel_source_address);
        } orelse {
            try writer.writeAll(comptime indent ++ "0x");
            try std.fmt.formatInt(
                kernel_source_address,
                16,
                .lower,
                .{},
                writer,
            );

            if (opt_kernel_virtual_offset == null) {
                try writer.writeAll(" - ??? (address may be incorrect)\n");
            } else {
                try writer.writeAll(" - ???\n");
            }

            return;
        };

        try printSymbol(writer, symbol, opt_kernel_virtual_offset == null);
    }

    fn printSymbol(writer: anytype, symbol: SymbolSource.Symbol, kernel_virtual_offset_is_null: bool) !void {
        try writer.writeAll(indent);

        // kernel/setup.zig:43:15 in setup
        // ^^^^^^
        try writer.writeAll(symbol.directory);

        // kernel/setup.zig:43:15 in setup
        //       ^
        try writer.writeByte('/');

        // kernel/setup.zig:43:15 in setup
        //        ^^^^^^^^^
        try writer.writeAll(symbol.file_name);

        // kernel/setup.zig:43:15 in setup
        //                 ^
        try writer.writeByte(':');

        // kernel/setup.zig:43:15 in setup
        //                  ^^
        try std.fmt.formatInt(
            symbol.line,
            10,
            .lower,
            .{},
            writer,
        );

        // kernel/setup.zig:43:15 in setup
        //                    ^
        try writer.writeByte(':');

        // kernel/setup.zig:43:15 in setup
        //                     ^^
        try std.fmt.formatInt(
            symbol.column,
            10,
            .lower,
            .{},
            writer,
        );

        // kernel/setup.zig:43:15 in setup
        //                       ^^^^
        try writer.writeAll(" in ");

        // kernel/setup.zig:43:15 in setup
        //                           ^^^^^
        try writer.writeAll(symbol.name);

        if (kernel_virtual_offset_is_null) {
            try writer.writeAll(" (address and symbol may be incorrect)");
        }

        const line = switch (symbol.line_source) {
            .source => |s| s,
            .no_matching_file => {
                try writer.writeAll(comptime "\n" ++ (indent ** 2));
                try writer.writeAll("no such file in embedded source files\n\n");
                return;
            },
            .no_such_line => {
                try writer.writeAll(comptime "\n" ++ (indent ** 2));
                try writer.writeAll("no such line in file?\n");
                return;
            },
            .name_too_long => |file_name_buffer_len| {
                try writer.writeAll(comptime "\n" ++ (indent ** 2));
                try writer.print("file name exceeds {} bytes! '{s}/{s}'\n", .{
                    file_name_buffer_len,
                    symbol.directory,
                    symbol.file_name,
                });
                return;
            },
        };

        // trim any blank spaces at the beginning of the line that are present in the source file
        var blank_spaces: usize = 0;
        while (blank_spaces < line.len and line[blank_spaces] == ' ') {
            blank_spaces += 1;
        }

        try writer.writeByte('\n');
        try writer.writeAll(comptime indent ** 2);

        //     core.panic("some message");
        //     ^^^^^^^^^^^^^^^^^^^^^^^^^^^
        try writer.writeAll(line[blank_spaces..]);

        try writer.writeAll(comptime "\n" ++ (indent ** 2));

        try writer.writeByteNTimes(' ', symbol.column - 1 - blank_spaces);

        try writer.writeAll("^\n");
    }
};

const SymbolSource = struct {
    const sdf = @import("sdf");

    string_table: sdf.StringTable,
    file_table: sdf.FileTable,
    location_lookup: sdf.LocationLookup,
    location_program: sdf.LocationProgram,

    pub fn load() ?SymbolSource {
        const sdf_slice = sdfSlice() catch return null;

        var sdf_fbs = std.io.fixedBufferStream(sdf_slice);

        const header = sdf.Header.read(sdf_fbs.reader()) catch return null;

        return .{
            .string_table = header.stringTable(sdf_slice),
            .file_table = header.fileTable(sdf_slice),
            .location_lookup = header.locationLookup(sdf_slice),
            .location_program = header.locationProgram(sdf_slice),
        };
    }

    pub fn getSymbol(self: SymbolSource, address: usize) ?Symbol {
        const start_state = self.location_lookup.getStartState(address) catch return null;

        const location = self.location_program.getLocation(start_state, address) catch return null;

        const file = self.file_table.getFile(location.file_index) orelse return null;

        const file_name = self.string_table.getString(file.file_offset);
        const directory = self.string_table.getString(file.directory_offset);

        const line_source: Symbol.LineSource = line_source: {
            const file_contents = blk: {
                var file_name_buffer: [512]u8 = undefined;

                const full_file_path = std.fmt.bufPrint(
                    &file_name_buffer,
                    "{s}/{s}",
                    .{ directory, file_name },
                ) catch break :line_source .{ .name_too_long = file_name_buffer.len };

                break :blk embedded_source_files.get(full_file_path) orelse {
                    break :line_source .no_matching_file;
                };
            };

            const line = findTargetLine(file_contents, location.line) orelse {
                break :line_source .no_such_line;
            };

            break :line_source .{ .source = line };
        };

        return .{
            .name = self.string_table.getString(location.symbol_offset),
            .directory = directory,
            .file_name = file_name,
            .line = location.line,
            .column = location.column,

            .line_source = line_source,
        };
    }

    pub const Symbol = struct {
        name: []const u8,
        directory: []const u8,
        file_name: []const u8,
        line: u64,
        column: u64,

        line_source: LineSource,

        pub const LineSource = union(enum) {
            source: []const u8,
            no_matching_file,
            no_such_line,
            name_too_long: usize,
        };
    };

    /// Finds the target line in the given file contents.
    ///
    /// Returns the line contents if found, otherwise returns null.
    fn findTargetLine(file_contents: []const u8, target_line_number: usize) ?[]const u8 {
        var line_iter = std.mem.splitScalar(u8, file_contents, '\n');
        var line_index: u64 = 1;

        while (line_iter.next()) |line| : (line_index += 1) {
            if (line_index != target_line_number) continue;
            return line;
        }

        return null;
    }

    const embedded_source_files: std.StaticStringMap([]const u8) = .initComptime(embedded_source_files: {
        @setEvalBranchQuota(1_000_000);

        const embedded_source_files_import = @import("embedded_source_files");

        var array: [embedded_source_files_import.file_paths.len]struct {
            []const u8,
            []const u8,
        } = undefined;

        for (embedded_source_files_import.file_paths, 0..) |name, i| {
            array[i] = .{ name, @embedFile(name) };
        }
        break :embedded_source_files array[0..];
    });
};

pub fn sdfSlice() ![]const u8 {
    const static = struct {
        const sdf = @import("sdf");

        var opt_sdf_slice: ?[]const u8 = null;
        extern const __sdf_start: u8;
    };

    if (static.opt_sdf_slice) |s| return s;

    const ptr: [*]const u8 = @ptrCast(&static.__sdf_start);
    var fbs = std.io.fixedBufferStream(ptr[0..@sizeOf(static.sdf.Header)]);

    const header = try static.sdf.Header.read(fbs.reader());

    const slice = ptr[0..header.total_size_of_sdf_data];

    static.opt_sdf_slice = slice;
    return slice;
}

/// Zig panic interface.
pub const Panic = struct {
    pub const call = zigPanic;

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "sentinel mismatch: expected {any}, found {any}", .{
            expected, found,
        });
    }

    pub fn unwrapError(error_return_trace: ?*std.builtin.StackTrace, err: anyerror) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(error_return_trace, @returnAddress(), "attempt to unwrap error: {s}", .{@errorName(err)});
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "index out of bounds: index {d}, len {d}", .{ index, len });
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "start index {d} is larger than end index {d}", .{ start, end });
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        @branchHint(.cold);
        std.debug.panicExtra(null, @returnAddress(), "access of union field '{s}' while field '{s}' is active", .{
            @tagName(accessed), @tagName(active),
        });
    }

    pub const messages = std.debug.SimplePanic.messages;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
