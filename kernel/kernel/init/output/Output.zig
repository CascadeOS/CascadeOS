// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const devicetree = @import("../devicetree.zig");
pub const uart = @import("uart.zig");

const log = kernel.debug.log.scoped(.output_init);

const Output = @This();

name: Name,

writeFn: *const fn (state: *anyopaque, str: []const u8) void,

splatFn: *const fn (state: *anyopaque, str: []const u8, splat: usize) void,

state: *anyopaque,

pub const Name = core.containers.BoundedArray(u8, 32);

pub const writer = &globals.writer;
pub const lock = &globals.lock;

const cascade_starting_message: []const u8 = "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n";

/// Called before the memory system is initialized so anything that needs heap allocation or the special heap cannot be initialized yet.
pub fn registerOutputsNoMemorySystem() void {
    globals.serial_output = getSerialOutput(false);
    if (globals.serial_output) |serial_output| serial_output.writeFn(serial_output.state, cascade_starting_message);

    globals.graphical_output = @import("framebuffer.zig").tryGetFramebufferOutput(false);
    if (globals.graphical_output) |*graphical_output| graphical_output.writeFn(graphical_output.state, cascade_starting_message);

    if (log.levelEnabled(.debug)) {
        if (globals.graphical_output) |*output| log.debug(
            "before memory system - selected graphical output: {s}",
            .{output.name.constSlice()},
        );

        if (globals.serial_output) |*output| log.debug(
            "before memory system - selected serial output: {s}",
            .{output.name.constSlice()},
        );
    }
}

/// Called after the memory system is initialized.
///
/// Only attempts to initialize a serial or graphical output if an output of each type has not already been initialized.
pub fn registerOutputsWithMemorySystem() void {
    if (globals.serial_output == null) {
        globals.serial_output = getSerialOutput(true);
        if (globals.serial_output) |serial_output| serial_output.writeFn(serial_output.state, cascade_starting_message);
    }

    if (globals.graphical_output == null) {
        globals.graphical_output = @import("framebuffer.zig").tryGetFramebufferOutput(true);
        if (globals.graphical_output) |*graphical_output| graphical_output.writeFn(graphical_output.state, cascade_starting_message);
    }

    if (log.levelEnabled(.debug)) {
        const graphical_output: ?*const Output = if (globals.graphical_output) |*output| output else null;
        const serial_output: ?*const Output = if (globals.serial_output) |*output| output else null;

        if (graphical_output != null or serial_output != null) {
            if (graphical_output) |output|
                log.debug("selected graphical output: {s}", .{output.name.constSlice()})
            else
                log.debug("no graphical output selected", .{});

            if (serial_output) |output|
                log.debug("selected serial output: {s}", .{output.name.constSlice()})
            else
                log.debug("no serial output selected", .{});
        } else log.debug("no output selected", .{});
    }
}

fn getSerialOutput(memory_system_available: bool) ?Output {
    if (arch.init.tryGetSerialOutput(memory_system_available)) |output| {
        return switch (output.preference) {
            .use => output.output,
            .prefer_generic => if (tryGetSerialOutputFromGenericSources(memory_system_available)) |generic_output|
                generic_output
            else
                output.output,
        };
    }

    return tryGetSerialOutputFromGenericSources(memory_system_available);
}

/// Attempt to get some form of init output from generic sources, like ACPI tables or device tree.
fn tryGetSerialOutputFromGenericSources(memory_system_available: bool) ?kernel.init.Output {
    const static = struct {
        var init_output_uart: uart.Uart = undefined;
    };

    blk: {
        if (kernel.acpi.tables.SPCR.init.tryGetSerialOutput(memory_system_available)) |output_uart| {
            log.debug("got serial output from SPCR", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        if (kernel.acpi.tables.DBG2.init.tryGetSerialOutput(memory_system_available)) |output_uart| {
            log.debug("got serial output from DBG2", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        if (devicetree.tryGetSerialOutput(memory_system_available)) |output_uart| {
            log.debug("got serial output from device tree", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        return null;
    }

    return static.init_output_uart.output();
}

fn writeToOutputs(str: []const u8) void {
    if (globals.graphical_output) |*output| output.writeFn(output.state, str);
    if (globals.serial_output) |*output| output.writeFn(output.state, str);
}

fn splatToOutputs(str: []const u8, splat: usize) void {
    if (globals.graphical_output) |*output| output.splatFn(output.state, str, splat);
    if (globals.serial_output) |*output| output.splatFn(output.state, str, splat);
}

/// Replaces `\n' with `\r\n'.
pub fn writeWithCarridgeReturns(
    context: anytype,
    comptime writeFn: fn (context: @TypeOf(context), str: []const u8) void,
    full_str: []const u8,
) void {
    var str = full_str;

    while (str.len != 0) {
        const index_of_newline = std.mem.indexOfScalar(u8, str, '\n') orelse {
            writeFn(context, str);
            return;
        };

        writeFn(context, str[0..index_of_newline]);
        writeFn(context, "\r\n");
        str = str[index_of_newline + 1 ..];
    }
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};

    var graphical_output: ?Output = null;
    var serial_output: ?Output = null;

    var writer_buffer: [arch.paging.standard_page_size.value]u8 = undefined;

    var writer: std.Io.Writer = .{
        .buffer = &globals.writer_buffer,
        .vtable = &.{
            .drain = struct {
                fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                    // TODO: is this even correct? the new writer interface is a bit confusing

                    if (w.end != 0) {
                        writeToOutputs(w.buffered());
                        w.end = 0;
                    }

                    var written: usize = 0;

                    for (data[0 .. data.len - 1]) |slice| {
                        if (slice.len == 0) continue;
                        writeToOutputs(slice);
                        written += slice.len;
                    }

                    const last_data = data[data.len - 1];
                    if (last_data.len != 0) {
                        splatToOutputs(last_data, splat);
                        written += last_data.len * splat;
                    }

                    return written;
                }
            }.drain,
        },
    };
};
