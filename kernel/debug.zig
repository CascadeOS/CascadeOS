// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

/// Entry point from the Zig language upon a panic.
pub fn zigPanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @setCold(true);

    panic_impl(
        msg,
        stack_trace,
        return_address_opt orelse @returnAddress(),
    );

    while (true) {
        kernel.arch.interrupts.disableInterruptsAndHalt();
    }
}

fn printUserPanicMessage(writer: std.io.AnyWriter, msg: []const u8) void {
    if (msg.len != 0) {
        writer.writeAll("\nPANIC - ") catch unreachable;

        writer.writeAll(msg) catch unreachable;

        if (msg[msg.len - 1] != '\n') {
            writer.writeByte('\n') catch unreachable;
        }
    } else {
        writer.writeAll("\nPANIC\n") catch unreachable;
    }
}

fn printErrorAndCurrentStackTrace(
    writer: std.io.AnyWriter,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const symbol_source = SymbolSource.load();

    // error return trace
    if (stack_trace) |trace| {
        if (trace.index != 0) {
            printStackTrace(writer, trace, symbol_source);
        }
    }

    printCurrentBackTrace(writer, return_address, symbol_source);
}

fn printCurrentBackTrace(
    writer: std.io.AnyWriter,
    return_address: usize,
    symbol_source: ?SymbolSource,
) void {
    var stack_iter = std.debug.StackIterator.init(return_address, @frameAddress());

    while (stack_iter.next()) |address| {
        printSourceAtAddress(writer, address, symbol_source);
    }
}

fn printStackTrace(
    writer: std.io.AnyWriter,
    stack_trace: *const std.builtin.StackTrace,
    symbol_source: ?SymbolSource,
) void {
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);

    var first_addr_opt: ?usize = null;
    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        if (first_addr_opt == null) first_addr_opt = return_address;

        printSourceAtAddress(writer, return_address, symbol_source);
    }
}

const indent = "  ";

fn printSourceAtAddress(writer: std.io.AnyWriter, address: usize, opt_symbol_source: ?SymbolSource) void {
    if (address == 0) return;

    if (address < kernel.arch.paging.higher_half.value) {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - address is not in the higher half so must be userspace\n") catch unreachable;
        return;
    }

    var kernel_virtual_offset_is_null: bool = false;
    const kernel_virtual_offset = if (kernel.vmm.memory_layout.virtual_offset) |offset| offset.value else blk: {
        kernel_virtual_offset_is_null = true;
        break :blk 0;
    };

    // we can't use `VirtualAddress` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel_virtual_offset;

    const symbol = blk: {
        const symbol_source = opt_symbol_source orelse break :blk null;
        break :blk symbol_source.getSymbol(kernel_source_address);
    } orelse {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            kernel_source_address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;

        if (kernel_virtual_offset_is_null) {
            writer.writeAll(" - ??? (address may be incorrect)\n") catch unreachable;
        } else {
            writer.writeAll(" - ???\n") catch unreachable;
        }

        return;
    };

    printSymbol(writer, symbol, kernel_virtual_offset_is_null);
}

fn printSymbol(writer: std.io.AnyWriter, symbol: SymbolSource.Symbol, kernel_virtual_offset_is_null: bool) void {
    writer.writeAll(indent) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    // ^^^^^^
    writer.writeAll(symbol.directory) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //       ^
    writer.writeByte('/') catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //        ^^^^^^^^^
    writer.writeAll(symbol.file_name) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                 ^
    writer.writeByte(':') catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                  ^^
    std.fmt.formatInt(
        symbol.line,
        10,
        .lower,
        .{},
        writer,
    ) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                    ^
    writer.writeByte(':') catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                     ^^
    std.fmt.formatInt(
        symbol.column,
        10,
        .lower,
        .{},
        writer,
    ) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                       ^^^^
    writer.writeAll(" in ") catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                           ^^^^^
    writer.writeAll(symbol.name) catch unreachable;

    if (kernel_virtual_offset_is_null) {
        writer.writeAll(" (address and symbol may be incorrect)") catch unreachable;
    }

    const line = switch (symbol.line_source) {
        .source => |s| s,
        .no_matching_file => {
            writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
            writer.writeAll("no such file in embedded source files\n\n") catch unreachable;
            return;
        },
        .no_such_line => {
            writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
            writer.writeAll("no such line in file?\n") catch unreachable;
            return;
        },
        .name_too_long => |file_name_buffer_len| {
            writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
            writer.print("file name exceeds {} bytes! '{s}/{s}'\n", .{
                file_name_buffer_len,
                symbol.directory,
                symbol.file_name,
            }) catch unreachable;
            return;
        },
    };

    // trim any blank spaces at the beginning of the line that are present in the source file
    var blank_spaces: usize = 0;
    while (blank_spaces < line.len and line[blank_spaces] == ' ') {
        blank_spaces += 1;
    }

    writer.writeByte('\n') catch unreachable;
    writer.writeAll(comptime indent ** 2) catch unreachable;

    //     core.panic("some message");
    //     ^^^^^^^^^^^^^^^^^^^^^^^^^^^
    writer.writeAll(line[blank_spaces..]) catch unreachable;

    writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;

    writer.writeByteNTimes(' ', symbol.column - 1 - blank_spaces) catch unreachable;

    writer.writeAll("^\n") catch unreachable;
}

pub fn sdfSlice() []const u8 {
    const static = struct {
        const sdf = @import("sdf");

        var opt_sdf_slice: ?[]const u8 = null;
        extern const __sdf_start: u8;
    };

    if (static.opt_sdf_slice) |s| return s;

    const ptr: [*]const u8 = @ptrCast(&static.__sdf_start);
    var fbs = std.io.fixedBufferStream(ptr[0..@sizeOf(static.sdf.Header)]);

    const header = static.sdf.Header.read(fbs.reader()) catch core.panic("SDF data is invalid", @errorReturnTrace());

    const slice = ptr[0..header.total_size_of_sdf_data];

    static.opt_sdf_slice = slice;
    return slice;
}

const SymbolSource = struct {
    const sdf = @import("sdf");

    string_table: sdf.StringTable,
    file_table: sdf.FileTable,
    location_lookup: sdf.LocationLookup,
    location_program: sdf.LocationProgram,

    pub fn load() ?SymbolSource {
        const sdf_slice = sdfSlice();

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

    const embedded_source_files = std.StaticStringMap([]const u8).initComptime(embedded_source_files: {
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

var panic_impl: *const fn (
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void = init.noOpPanic;

var panicked_cpu = std.atomic.Value(kernel.Cpu.Id).init(.none);

pub fn hasACpuPanicked() bool {
    return panicked_cpu.load(.acquire) != .none;
}

pub const init = struct {
    pub fn loadInitPanic() void {
        panic_impl = initPanicImpl;
    }

    /// Panic handler during kernel init.
    ///
    /// As this is set as the panic impl after the bootstrap cpu is loaded, it can use `kerenel.arch.rawGetCpu()` safely.
    fn initPanicImpl(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        const cpu = kernel.arch.rawGetCpu();

        if (panicked_cpu.cmpxchgStrong(
            .none,
            cpu.id,
            .acq_rel,
            .acquire,
        )) |unexpected_cpu| {
            if (unexpected_cpu != cpu.id) return;

            // we have already panicked on this cpu.

            const have_lock = @atomicLoad(kernel.Cpu.Id, &kernel.arch.init.EarlyOutput.lock.current_holder, .acquire) == cpu.id;

            const opt_held = if (!have_lock) kernel.arch.init.EarlyOutput.lock.acquire() else null;
            defer if (opt_held) |held| held.release();

            const writer = kernel.arch.init.getEarlyOutputNoLock() orelse return;

            writer.writeAll("\nPANIC IN PANIC on cpu ") catch unreachable;

            cpu.id.print(writer, 0) catch unreachable;

            printUserPanicMessage(writer, msg);
            printErrorAndCurrentStackTrace(writer, stack_trace, return_address);

            return;
        }

        const early_output = kernel.arch.init.getEarlyOutput() orelse return;
        defer early_output.deinit();

        early_output.writer.writeAll("\nPANIC on cpu ") catch unreachable;

        cpu.id.print(early_output.writer, 0) catch unreachable;

        printUserPanicMessage(early_output.writer, msg);
        printErrorAndCurrentStackTrace(early_output.writer, stack_trace, return_address);
    }

    fn noOpPanic(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        _ = msg;
        _ = stack_trace;
        _ = return_address;
    }
};
