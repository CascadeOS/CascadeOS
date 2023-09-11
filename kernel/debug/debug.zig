// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const symbol_map = @import("symbol_map.zig");

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @setCold(true);
    kernel.arch.interrupts.disableInterrupts();

    const loaded_symbols = if (symbol_map.loadSymbols()) true else |_| false;

    const return_address = return_address_opt orelse @returnAddress();

    // TODO: call `panicImpl` if the kernel is ready
    simplePanic(msg, stack_trace, return_address, loaded_symbols);

    kernel.arch.interrupts.disableInterruptsAndHalt();
}

/// Prints the panic message to the early output writer.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: usize,
    loaded_symbols: bool,
) void {
    const writer = kernel.arch.setup.getEarlyOutputWriter() orelse return;

    if (loaded_symbols) {
        writer.print("\nPANIC: {s}\n\n", .{msg}) catch unreachable;
    } else {
        writer.print("\nPANIC(no symbols loaded): {s}\n\n", .{msg}) catch unreachable;
    }

    // error return trace
    if (stack_trace) |trace| {
        printStackTrace(writer, trace);
    }

    printCurrentBackTrace(writer, ret_addr);
}

/// Prints the panic message, stack trace, and registers.
fn panicImpl(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: usize,
    loaded_symbols: bool,
) void {
    // TODO: Implement `panicImpl` https://github.com/CascadeOS/CascadeOS/issues/16
    simplePanic(msg, stack_trace, ret_addr, loaded_symbols);
}

fn printStackTrace(writer: anytype, stack_trace: *const std.builtin.StackTrace) void {
    var frame_index: usize = 0;
    var frames_left: usize = @min(stack_trace.index, stack_trace.instruction_addresses.len);

    var first_addr_opt: ?usize = null;
    while (frames_left != 0) : ({
        frames_left -= 1;
        frame_index = (frame_index + 1) % stack_trace.instruction_addresses.len;
    }) {
        const return_address = stack_trace.instruction_addresses[frame_index];
        if (first_addr_opt == null) first_addr_opt = return_address;

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

/// Prints the source code location for the given address.
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

    // we can't use `VirtualAddress` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel.info.kernel_virtual_slide.bytes;

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

    const symbol = symbol_map.getSymbol(kernel_source_address) orelse {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            kernel_source_address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - failed to find address in debug info\n") catch unreachable;

        return;
    };

    printSymbol(writer, symbol);
}

/// Prints the symbol information for the given symbol.
fn printSymbol(writer: anytype, symbol: symbol_map.Symbol) void {
    writer.writeAll(indent) catch unreachable;

    const location = symbol.location orelse {
        if (symbol.name) |name| {
            // setup - ???
            // ^^^^^
            writer.writeAll(name) catch unreachable;

            // setup - ???
            //      ^^^^^^
            writer.writeAll(" - ???\n") catch unreachable;
        } else {
            // ??? - ???
            // ^^^^^^^^^
            writer.writeAll("??? - ???\n") catch unreachable;
        }

        return;
    };

    // kernel/setup.zig:43:15 in setup
    // ^^^^^^^^^^^^^^^^
    writer.writeAll(location.file_name) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                 ^
    writer.writeByte(':') catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //                  ^^
    std.fmt.formatInt(
        location.line,
        10,
        .lower,
        .{},
        writer,
    ) catch unreachable;

    if (location.column) |column| {
        // kernel/setup.zig:43:15 in setup
        //                    ^
        writer.writeByte(':') catch unreachable;

        // kernel/setup.zig:43:15 in setup
        //                     ^^
        std.fmt.formatInt(
            column,
            10,
            .lower,
            .{},
            writer,
        ) catch unreachable;
    }

    // kernel/setup.zig:43:15 in setup
    //                       ^^^^
    writer.writeAll(" in ") catch unreachable;

    if (symbol.name) |name| {
        // kernel/setup.zig:43:15 in setup
        //                           ^^^^^
        writer.writeAll(name) catch unreachable;
    } else {
        // kernel/setup.zig:43:15 in ???
        //                           ^^^
        writer.writeAll("???") catch unreachable;
    }

    if (!location.is_line_expected_to_be_precise) {
        // kernel/setup.zig:43:15 in setup (symbols line information is inprecise)
        //                                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        writer.writeAll(" (symbols line information is inprecise)") catch unreachable;
    }

    const file_contents = embedded_source_files.get(location.file_name) orelse return;

    const line = findTargetLine(file_contents, location.line) orelse {
        // no matching line found
        writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
        writer.writeAll("no such line in file?\n") catch unreachable;
        return;
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

    if (location.column) |column| {
        writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;

        writer.writeByteNTimes(' ', column - 1 - blank_spaces) catch unreachable;

        writer.writeAll("^\n") catch unreachable;
    } else {
        writer.writeAll("\n\n") catch unreachable;
    }
}

/// Finds the target line in the given file contents.
///
/// Returns the line contents if found, otherwise returns null.
fn findTargetLine(file_contents: []const u8, target_line_number: usize) ?[]const u8 {
    var line_iter = std.mem.split(u8, file_contents, "\n");
    var line_index: u64 = 1;

    while (line_iter.next()) |line| : (line_index += 1) {
        if (line_index != target_line_number) continue;
        return line;
    }

    return null;
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
