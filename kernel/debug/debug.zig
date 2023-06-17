// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const symbol_map = @import("symbol_map.zig");

pub const PanicState = enum(u8) {
    no_op = 0,
    simple = 1,
    full = 2,
};

var state: PanicState = .no_op;

/// Switches the panic state to the given state.
/// Panics if the new state is less than the current state.
pub fn switchTo(new_state: PanicState) void {
    if (@enumToInt(state) < @enumToInt(new_state)) {
        state = new_state;
        return;
    }

    core.panicFmt("cannot switch to {s} panic from {s} panic", .{ @tagName(new_state), @tagName(state) });
}

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @setCold(true);
    kernel.arch.interrupts.disableInterrupts();
    symbol_map.loadSymbols();

    switch (state) {
        .no_op => {},
        .simple => simplePanic(msg, stack_trace, ret_addr),
        .full => panicImpl(msg, stack_trace, ret_addr),
    }

    kernel.arch.interrupts.disableInterruptsAndHalt();
}

/// Prints the panic message to the early output writer.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) void {
    const writer = kernel.arch.setup.getEarlyOutputWriter();

    writer.print("\nPANIC: {s}\n\n", .{msg}) catch unreachable;

    // error return trace
    if (stack_trace) |trace| {
        dumpStackTrace(writer, trace);
    }

    printCurrentBackTrace(writer, ret_addr orelse @returnAddress());
}

/// Prints the panic message, stack trace, and registers.
fn panicImpl(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) void {
    // TODO: Implement `panicImpl` https://github.com/CascadeOS/CascadeOS/issues/16
    simplePanic(msg, stack_trace, ret_addr);
}

fn dumpStackTrace(writer: anytype, stack_trace: *const std.builtin.StackTrace) void {
    var frame_index: usize = 0;
    var frames_left: usize = std.math.min(stack_trace.index, stack_trace.instruction_addresses.len);

    var opt_first_addr: ?usize = null;
    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        if (opt_first_addr == null) opt_first_addr = return_address;

        printSourceAtAddress(writer, return_address);
    }
}

fn printCurrentBackTrace(writer: anytype, return_address: usize) void {
    var stack_iter = std.debug.StackIterator.init(return_address, @frameAddress());

    while (stack_iter.next()) |address| {
        printSourceAtAddress(writer, address);
    }
}

const indent = "  ";

fn printSourceAtAddress(writer: anytype, address: usize) void {
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

    // we can't use `VirtAddr` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel.info.kernel_offset_from_base.bytes;

    if (kernel_source_address < kernel.info.kernel_base_address.value) {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - address is not a kernel code address\n") catch unreachable;
        return;
    }

    if (symbol_map.getSymbol(kernel_source_address)) |symbol| {
        writer.writeAll(indent) catch unreachable;

        if (symbol.location) |location| {
            writer.writeAll(location.file_name) catch unreachable;
            writer.writeByte(':') catch unreachable;
            std.fmt.formatInt(
                location.line,
                10,
                .lower,
                .{},
                writer,
            ) catch unreachable;

            if (location.column) |column| {
                writer.writeByte(':') catch unreachable;
                std.fmt.formatInt(
                    column,
                    10,
                    .lower,
                    .{},
                    writer,
                ) catch unreachable;
            }

            writer.writeAll(" in ") catch unreachable;
            writer.writeAll(symbol.name) catch unreachable;

            if (!location.is_line_expected_to_be_precise) {
                writer.writeAll(" (symbols line information is inprecise)") catch unreachable;
            }

            writer.writeByte('\n') catch unreachable;

            if (embedded_source_files.get(location.file_name)) |file_contents| embed_blk: {
                writer.writeAll(comptime indent ** 2) catch unreachable;

                var blank_spaces_trimmed_from_line: usize = 0;

                const line = line: {
                    var line_iter = std.mem.split(u8, file_contents, "\n");
                    var row: u64 = 1;
                    while (line_iter.next()) |line| {
                        if (row == location.line) {
                            var first_non_empty_column: usize = 0;

                            while (first_non_empty_column < line.len and line[first_non_empty_column] == ' ') {
                                first_non_empty_column += 1;
                            }

                            blank_spaces_trimmed_from_line = first_non_empty_column;
                            break :line line[first_non_empty_column..];
                        }
                        row += 1;
                    }
                    // no matching line found
                    writer.writeAll("no such line in file?\n") catch unreachable;
                    break :embed_blk;
                };

                writer.writeAll(line) catch unreachable;

                if (location.column) |column| {
                    writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
                    writer.writeByteNTimes(' ', column - 1 - blank_spaces_trimmed_from_line) catch unreachable;

                    writer.writeAll("^\n") catch unreachable;
                } else {
                    writer.writeAll("\n\n") catch unreachable;
                }
            }
        } else {
            writer.writeAll(symbol.name) catch unreachable;
            writer.writeAll(" - ???\n") catch unreachable;
        }
    } else {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            kernel_source_address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - ???\n") catch unreachable;
    }
}

const embedded_source_files = std.ComptimeStringMap([]const u8, embedded_source_files: {
    const embedded_source_files_import = @import("embedded_source_files");

    var array: [embedded_source_files_import.file_paths.len]struct {
        []const u8,
        []const u8,
    } = undefined;

    inline for (embedded_source_files_import.file_paths, 0..) |name, i| {
        array[i] = .{ name, @embedFile(name) };
    }
    break :embedded_source_files array[0..];
});
