// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const symbols = @import("symbols.zig");

var panic_impl: *const fn ([]const u8, ?*const std.builtin.StackTrace, usize) void = init.earlyPanicImpl;

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
    // TODO: Implement `panicImpl` https://github.com/CascadeOS/CascadeOS/issues/16
    init.earlyPanicImpl(msg, stack_trace, return_address);
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
    // TODO: Use DWARF frame unwinding - https://github.com/CascadeOS/CascadeOS/issues/62

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

    // TODO: Inform the user if this is null.
    const kernel_virtual_slide = if (kernel.info.kernel_virtual_slide) |slide| slide.bytes else 0;

    // we can't use `VirtualAddress` here as it is possible this subtract results in a non-canonical address
    const kernel_source_address = address - kernel_virtual_slide;

    // TODO: This is not a sufficent check for this situation, `vmm.kernel_memory_layout` should be used if possible
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

    const symbol = symbols.getSymbol(kernel_source_address) orelse {
        writer.writeAll(comptime indent ++ "0x") catch unreachable;
        std.fmt.formatInt(
            kernel_source_address,
            16,
            .lower,
            .{},
            writer,
        ) catch unreachable;
        writer.writeAll(" - ???\n") catch unreachable;
        return;
    };

    printSymbol(writer, symbol);
}

fn printSymbol(writer: anytype, symbol: symbols.Symbol) void {
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

    const file_contents = embedded_source_files.get(location.file_name) orelse {
        // no matching file found
        writer.writeAll(comptime "\n" ++ (indent ** 2)) catch unreachable;
        writer.writeAll("no such file in embedded source files\n\n") catch unreachable;
        return;
    };

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
    var line_iter = std.mem.splitScalar(u8, file_contents, '\n');
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

pub const init = struct {
    var panic_lock: kernel.sync.SpinLock = .{};

    /// Panic implementation used before the kernel is fully initialized and running.
    fn earlyPanicImpl(
        msg: []const u8,
        stack_trace: ?*const std.builtin.StackTrace,
        return_address: usize,
    ) void {
        const writer = kernel.arch.init.getEarlyOutputWriter() orelse return;

        const processor = kernel.arch.getProcessor();

        if (processor.panicked) {
            const lock_held = panic_lock._processor_plus_one == processor.id + 1;
            if (!lock_held) _ = panic_lock.lock();

            // TODO: Can we do something better when we panic in a panic?
            writer.writeAll("\nPANIC IN PANIC on processor ") catch unreachable;

            std.fmt.formatInt(
                processor.id,
                10,
                .lower,
                .{ .width = 2, .fill = '0' }, // TODO: What should the width be?
                writer,
            ) catch unreachable;

            writer.writeByte('\n') catch unreachable;

            if (lock_held) {
                // we need to unlock the panic lock or other panicking processors will be deadlocked
                panic_lock.unsafeUnlock();
            }

            return;
        }

        processor.panicked = true;

        const held = panic_lock.lock();
        defer held.unlock();

        // panic message
        {
            writer.writeAll("\nPANIC on processor ") catch unreachable;

            std.fmt.formatInt(
                processor.id,
                10,
                .lower,
                .{ .width = 2, .fill = '0' }, // TODO: What should the width be?
                writer,
            ) catch unreachable;

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

        symbols.loadSymbols();

        // error return trace
        if (stack_trace) |trace| {
            if (trace.index != 0) {
                printStackTrace(writer, trace);
            }
        }

        printCurrentBackTrace(writer, return_address);
    }
};
