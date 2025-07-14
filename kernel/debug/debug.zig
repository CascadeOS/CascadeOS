// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const log = @import("log.zig");

pub fn interruptSourcePanic(
    interrupt_frame: kernel.arch.interrupts.InterruptFrame,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    @branchHint(.cold);

    const size = 0x1000;
    const trunc_msg = "(msg truncated)";
    var buf: [size + trunc_msg.len]u8 = undefined;
    var bw: std.Io.Writer = .fixed(buf[0..size]);
    // a minor annoyance with this is that it will result in the NoSpaceLeft
    // error being part of the @panic stack trace (but that error should
    // only happen rarely)
    const msg = if (bw.print(format, args)) |_| bw.buffered() else |_| blk: {
        @memcpy(buf[size..], trunc_msg);
        break :blk &buf;
    };

    panicDispatch(
        msg,
        .{ .interrupt = interrupt_frame },
    );
}

/// Entry point from the Zig language upon a panic.
fn zigPanic(
    msg: []const u8,
    return_address_opt: ?usize,
) noreturn {
    @branchHint(.cold);
    panicDispatch(
        msg,
        .{ .normal = .{
            .return_address = return_address_opt orelse @returnAddress(),
            .error_return_trace = @errorReturnTrace(),
        } },
    );
}

const PanicType = union(enum) {
    normal: struct {
        return_address: usize,
        error_return_trace: ?*const std.builtin.StackTrace,
    },
    interrupt: kernel.arch.interrupts.InterruptFrame,
};

fn panicDispatch(msg: []const u8, panic_type: PanicType) noreturn {
    @branchHint(.cold);

    kernel.arch.interrupts.disableInterrupts();

    switch (globals.panic_mode) {
        .single_executor_init_panic => singleExecutorInitPanic(msg, panic_type),
        .init_panic => initPanic(msg, panic_type),
    }

    kernel.arch.interrupts.disableInterruptsAndHalt();
}

fn singleExecutorInitPanic(
    msg: []const u8,
    panic_type: PanicType,
) void {
    const static = struct {
        var nested_panic_count: usize = 0;
    };

    kernel.init.Output.globals.lock.poison();

    const nested_panic_count = static.nested_panic_count;
    static.nested_panic_count += 1;

    switch (nested_panic_count) {
        // on first panic attempt to print the full panic message
        0 => formatting.printPanic(kernel.init.Output.writer, msg, panic_type) catch {},
        // on second panic print a shorter message
        1 => kernel.init.Output.writer.writeAll("\nPANIC IN PANIC\n") catch {},
        // don't trigger any more panics
        else => return,
    }

    kernel.init.Output.writer.flush() catch {};
}

fn initPanic(
    msg: []const u8,
    panic_type: PanicType,
) void {
    const static = struct {
        var nested_panic_count: usize = 0;
    };

    const executor = kernel.arch.rawGetCurrentExecutor();

    if (globals.panicking_executor.cmpxchgStrong(
        .none,
        executor.id,
        .acq_rel,
        .acquire,
    )) |panicking_executor_id| {
        if (panicking_executor_id != executor.id) return; // another executor is panicking
    }

    kernel.init.Output.globals.lock.poison();
    kernel.arch.interrupts.sendPanicIPI();

    const nested_panic_count = static.nested_panic_count;
    static.nested_panic_count += 1;

    switch (nested_panic_count) {
        // on first panic attempt to print the full panic message
        0 => formatting.printPanic(kernel.init.Output.writer, msg, panic_type) catch {},
        // on second panic print a shorter message
        1 => kernel.init.Output.writer.writeAll("\nPANIC IN PANIC\n") catch {},
        // don't trigger any more panics
        else => return,
    }

    kernel.init.Output.writer.flush() catch {};
}

const formatting = struct {
    pub fn printPanic(
        writer: *std.Io.Writer,
        msg: []const u8,
        panic_type: PanicType,
    ) !void {
        try printUserPanicMessage(writer, msg);
        switch (panic_type) {
            .normal => |normal| try printErrorAndCurrentStackTrace(
                writer,
                normal.error_return_trace,
                normal.return_address,
            ),
            .interrupt => |interrupt| try printInterruptError(writer, interrupt),
        }
    }

    fn printUserPanicMessage(writer: *std.Io.Writer, msg: []const u8) !void {
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

    fn printInterruptError(
        writer: *std.Io.Writer,
        interrupt_frame: kernel.arch.interrupts.InterruptFrame,
    ) !void {
        const symbol_source = SymbolSource.load();

        try printSourceAtAddress(
            writer,
            interrupt_frame.instructionPointer(),
            symbol_source,
        );

        var stack_iter = interrupt_frame.createStackIterator();

        while (stack_iter.next()) |address| {
            try printSourceAtAddress(writer, address, symbol_source);
        }
    }

    fn printErrorAndCurrentStackTrace(
        writer: *std.Io.Writer,
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
        writer: *std.Io.Writer,
        return_address: usize,
        symbol_source: ?SymbolSource,
    ) !void {
        var stack_iter: std.debug.StackIterator = .init(return_address, @frameAddress());

        while (stack_iter.next()) |address| {
            try printSourceAtAddress(writer, address, symbol_source);
        }
    }

    fn printStackTrace(
        writer: *std.Io.Writer,
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

    fn printSourceAtAddress(writer: *std.Io.Writer, address: usize, opt_symbol_source: ?SymbolSource) !void {
        if (address == 0) return;

        if (address < kernel.arch.paging.higher_half_start.value) {
            try writer.print(
                comptime indent ++ "0x{x:0>16} - address is not in the higher half so must be userspace\n",
                .{address},
            );
            return;
        }

        // we can't use `VirtualAddress` here as it is possible this subtraction results in a non-canonical address
        const kernel_source_address = address - kernel.mem.globals.virtual_offset.value;

        const symbol = blk: {
            const symbol_source = opt_symbol_source orelse break :blk null;
            break :blk symbol_source.getSymbol(kernel_source_address);
        } orelse {
            try writer.print(comptime indent ++ "0x{x:0>16} - ???\n", .{kernel_source_address});
            return;
        };

        try printSymbol(writer, symbol);
    }

    fn printSymbol(writer: *std.Io.Writer, symbol: SymbolSource.Symbol) !void {
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
        try writer.printInt(symbol.line, 10, .lower, .{});

        // kernel/setup.zig:43:15 in setup
        //                    ^
        try writer.writeByte(':');

        // kernel/setup.zig:43:15 in setup
        //                     ^^
        try writer.printInt(
            symbol.column,
            10,
            .lower,
            .{},
        );

        // kernel/setup.zig:43:15 in setup
        //                       ^^^^
        try writer.writeAll(" in ");

        // kernel/setup.zig:43:15 in setup
        //                           ^^^^^
        try writer.writeAll(symbol.name);

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

        //     @panic("some message");
        //     ^^^^^^^^^^^^^^^^^^^^^^^^^^^
        try writer.writeAll(line[blank_spaces..]);

        try writer.writeAll(comptime "\n" ++ (indent ** 2));

        try writer.splatByteAll(' ', symbol.column - 1 - blank_spaces);

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

        const header = blk: {
            var reader = std.Io.Reader.fixed(sdf_slice);
            break :blk sdf.Header.read(&reader) catch return null;
        };

        return .{
            .string_table = header.stringTable(sdf_slice),
            .file_table = header.fileTable(sdf_slice),
            .location_lookup = header.locationLookup(sdf_slice),
            .location_program = header.locationProgram(sdf_slice),
        };
    }

    pub fn getSymbol(symbol_source: SymbolSource, address: usize) ?Symbol {
        const start_state = symbol_source.location_lookup.getStartState(address) catch return null;

        const location = symbol_source.location_program.getLocation(start_state, address) catch return null;

        const file = symbol_source.file_table.getFile(location.file_index) orelse return null;

        const file_name = symbol_source.string_table.getString(file.file_offset);
        const directory = symbol_source.string_table.getString(file.directory_offset);

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
            .name = symbol_source.string_table.getString(location.symbol_offset),
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

    const header = blk: {
        var reader = std.Io.Reader.fixed(ptr[0..@sizeOf(static.sdf.Header)]);
        break :blk try static.sdf.Header.read(&reader);
    };

    const slice = ptr[0..header.total_size_of_sdf_data];

    static.opt_sdf_slice = slice;
    return slice;
}

/// The panic mode the kernel is in.
///
/// The kernel will move through each mode in order as initialization is performed.
///
/// No modes will be skipped and must be in strict increasing order.
pub const PanicMode = enum(u8) {
    /// Panic will print using init output with no locking.
    ///
    /// Does not support multiple executors.
    single_executor_init_panic,

    /// Panic will print using init output, poisons the init output lock.
    ///
    /// Supports multiple executors.
    init_panic,
};

pub fn setPanicMode(mode: PanicMode) void {
    if (@intFromEnum(globals.panic_mode) + 1 != @intFromEnum(mode)) {
        std.debug.panic(
            "invalid panic mode transition '{t}' -> '{t}'",
            .{ globals.panic_mode, mode },
        );
    }

    globals.panic_mode = mode;
}

pub const panic_interface = std.debug.FullPanic(zigPanic);

pub const globals = struct {
    /// The executor that is currently panicking.
    ///
    /// Public to allow other executors to check after receiving a panic IPI.
    pub var panicking_executor: std.atomic.Value(kernel.Executor.Id) = .init(.none);

    var panic_mode: PanicMode = .single_executor_init_panic;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
