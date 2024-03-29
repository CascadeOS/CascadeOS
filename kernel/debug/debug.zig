// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const symbols = @import("symbols.zig");

pub const log = @import("log.zig");

var panicked_processor = std.atomic.Value(kernel.Processor.Id).init(.none);

var panic_impl: *const fn ([]const u8, ?*const std.builtin.StackTrace, usize) void = init.earlyPanicImpl;

pub fn hasAProcessorPanicked() bool {
    return panicked_processor.load(.acquire) != .none;
}

/// Entry point from the Zig language upon a panic.
pub fn panic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address_opt: ?usize,
) noreturn {
    @setCold(true);
    kernel.arch.interrupts.disableInterrupts();

    const return_address = return_address_opt orelse @returnAddress();

    panic_impl(msg, stack_trace, return_address);

    kernel.arch.interrupts.disableInterruptsAndHalt();
}

/// Panic implementation used when the kernel is fully initialized and running.
fn panicImpl(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const processor = kernel.arch.getProcessor();

    if (panicked_processor.cmpxchgStrong(
        .none,
        processor.id,
        .acq_rel,
        .acquire,
    )) |unexpected_processor| {
        if (unexpected_processor != processor.id) return;

        // we have already panicked on this processor.

        const have_lock = kernel.arch.init.EarlyOutput.lock._processor_id == processor.id;
        if (!have_lock) _ = kernel.arch.init.EarlyOutput.lock.lock();

        const writer = kernel.arch.init.getEarlyOutputNoLock() orelse return;

        writer.writeAll("\nPANIC IN PANIC on processor ") catch unreachable;

        processor.id.print(writer) catch unreachable;

        printUserPanicMessage(writer, msg);

        printErrorAndCurrentStackTrace(writer, stack_trace, return_address);

        return;
    }

    // TODO: We need to move off of the early output writer in the main panic impl.
    const early_output = kernel.arch.init.getEarlyOutput() orelse return;

    kernel.arch.interrupts.panicInterruptOtherCores();

    early_output.writer.writeAll("\nPANIC on processor ") catch unreachable;

    processor.id.print(early_output.writer) catch unreachable;

    printUserPanicMessage(early_output.writer, msg);

    printErrorAndCurrentStackTrace(early_output.writer, stack_trace, return_address);
}

fn printStackTrace(
    writer: anytype,
    stack_trace: *const std.builtin.StackTrace,
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

        printSourceAtAddress(writer, return_address);
    }
}

fn printCurrentBackTrace(
    writer: anytype,
    return_address: usize,
) void {
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

    var kernel_virtual_slide_is_null: bool = false;
    const kernel_virtual_slide = if (kernel.info.kernel_virtual_slide) |slide| slide.value else blk: {
        kernel_virtual_slide_is_null = true;
        break :blk 0;
    };

    // we can't use `VirtualAddress` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel_virtual_slide;

    const symbol = symbols.getSymbol(kernel_source_address) orelse {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            kernel_source_address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;

        if (kernel_virtual_slide_is_null) {
            writer.writeAll(" - ??? (address may be incorrect)\n") catch unreachable;
        } else {
            writer.writeAll(" - ???\n") catch unreachable;
        }

        return;
    };

    printSymbol(writer, symbol, kernel_virtual_slide_is_null);
}

fn printSymbol(writer: anytype, symbol: symbols.Symbol, kernel_virtual_slide_is_null: bool) void {
    writer.writeAll(indent) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    // ^^^^^^
    writer.writeAll(symbol.directory) catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //       ^
    writer.writeByte('/') catch unreachable;

    // kernel/setup.zig:43:15 in setup
    //        ^^^^^^^^^
    writer.writeAll(symbol.file) catch unreachable;

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

    if (kernel_virtual_slide_is_null) {
        writer.writeAll(" (address and symbol may be incorrect)") catch unreachable;
    }

    const file_contents = blk: {
        var file_name_buffer: [512]u8 = undefined;

        const file_name = std.fmt.bufPrint(
            &file_name_buffer,
            "{s}/{s}",
            .{ symbol.directory, symbol.file },
        ) catch {
            // failed to format file name
            writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
            writer.print("file name exceeds {} bytes! '{s}/{s}'\n", .{
                file_name_buffer.len,
                symbol.directory,
                symbol.file,
            }) catch unreachable;
            return;
        };

        break :blk embedded_source_files.get(file_name) orelse {
            // no matching file found
            writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
            writer.writeAll("no such file in embedded source files\n\n") catch unreachable;
            return;
        };
    };

    const line = findTargetLine(file_contents, symbol.line) orelse {
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

    writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;

    writer.writeByteNTimes(' ', symbol.column - 1 - blank_spaces) catch unreachable;

    writer.writeAll("^\n") catch unreachable;
}

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

const embedded_source_files = std.ComptimeStringMap([]const u8, embedded_source_files: {
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

fn printUserPanicMessage(writer: anytype, msg: []const u8) void {
    if (msg.len != 0) {
        writer.writeAll(" - ") catch unreachable;

        writer.writeAll(msg) catch unreachable;

        if (msg[msg.len - 1] != '\n') {
            writer.writeByte('\n') catch unreachable;
        }
    } else {
        writer.writeByte('\n') catch unreachable;
    }
}

fn printErrorAndCurrentStackTrace(writer: anytype, stack_trace: ?*const std.builtin.StackTrace, return_address: usize) void {
    symbols.loadSymbols();

    // error return trace
    if (stack_trace) |trace| {
        if (trace.index != 0) {
            printStackTrace(writer, trace);
        }
    }

    printCurrentBackTrace(writer, return_address);
}

pub const init = struct {
    pub fn switchToMainPanicImpl() void {
        panic_impl = panicImpl;
    }

    /// Panic implementation used before the kernel is fully initialized and running.
    fn earlyPanicImpl(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        const processor = kernel.arch.earlyGetProcessor() orelse {
            const writer = kernel.arch.init.getEarlyOutputNoLock() orelse return;

            writer.writeAll("\nPANIC - before processor loaded") catch unreachable;

            printUserPanicMessage(writer, msg);

            printErrorAndCurrentStackTrace(writer, stack_trace, return_address);

            return;
        };

        if (panicked_processor.cmpxchgStrong(
            .none,
            processor.id,
            .acq_rel,
            .acquire,
        )) |unexpected_processor| {
            if (unexpected_processor != processor.id) return;

            // we have already panicked on this processor.

            const have_lock = kernel.arch.init.EarlyOutput.lock._processor_id == processor.id;
            if (!have_lock) _ = kernel.arch.init.EarlyOutput.lock.lock();

            const writer = kernel.arch.init.getEarlyOutputNoLock() orelse return;

            writer.writeAll("\nPANIC IN PANIC on processor ") catch unreachable;

            processor.id.print(writer) catch unreachable;

            printUserPanicMessage(writer, msg);

            printErrorAndCurrentStackTrace(writer, stack_trace, return_address);

            return;
        }

        const early_output = kernel.arch.init.getEarlyOutput() orelse return;

        early_output.writer.writeAll("\nPANIC on processor ") catch unreachable;

        processor.id.print(early_output.writer) catch unreachable;

        printUserPanicMessage(early_output.writer, msg);

        printErrorAndCurrentStackTrace(early_output.writer, stack_trace, return_address);
    }
};
