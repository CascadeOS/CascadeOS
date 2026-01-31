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

/// Called to allow the output to remap itself into the non-cached direct map or special heap after they have been
/// initialized.
remapFn: *const fn (state: *anyopaque) anyerror!void,

state: *anyopaque,

pub const Name = core.containers.BoundedArray(u8, 32);

pub const writer = &globals.writer;
pub const lock = &globals.lock;

/// Allow outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs() !void {
    if (globals.framebuffer_output) |output| try output.remapFn(output.state);
    if (globals.serial_output) |output| try output.remapFn(output.state);
}

pub fn registerOutputs() void {
    if (@import("framebuffer.zig").tryGetFramebufferOutput()) |output| {
        globals.framebuffer_output = output;
    }

    if (arch.init.tryGetSerialOutput()) |output| {
        switch (output.preference) {
            .use => globals.serial_output = output.output,
            .prefer_generic => {
                if (tryGetSerialOutputFromGenericSources()) |generic_output|
                    globals.serial_output = generic_output
                else
                    globals.serial_output = output.output;
            },
        }
    } else globals.serial_output = tryGetSerialOutputFromGenericSources();
}

pub fn logSelectedOutputs() void {
    if (!log.levelEnabled(.debug)) return;

    const framebuffer_output: ?*const Output = if (globals.framebuffer_output) |*output| output else null;
    const serial_output: ?*const Output = if (globals.serial_output) |*output| output else null;

    if (framebuffer_output != null or serial_output != null) {
        if (framebuffer_output) |output|
            log.debug("selected graphical output: {s}", .{output.name.constSlice()})
        else
            log.debug("no graphical output selected", .{});

        if (serial_output) |output|
            log.debug("selected serial output: {s}", .{output.name.constSlice()})
        else
            log.debug("no serial output selected", .{});
    } else log.debug("no output selected", .{});
}

/// Attempt to get some form of init output from generic sources, like ACPI tables or device tree.
fn tryGetSerialOutputFromGenericSources() ?kernel.init.Output {
    const static = struct {
        var init_output_uart: uart.Uart = undefined;
    };

    blk: {
        if (kernel.acpi.tables.SPCR.init.tryGetSerialOutput()) |output_uart| {
            log.debug("got serial output from SPCR", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        if (kernel.acpi.tables.DBG2.init.tryGetSerialOutput()) |output_uart| {
            log.debug("got serial output from DBG2", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        if (devicetree.tryGetSerialOutput()) |output_uart| {
            log.debug("got serial output from device tree", .{});

            static.init_output_uart = output_uart;
            break :blk;
        }

        return null;
    }

    return static.init_output_uart.output();
}

fn writeToOutputs(str: []const u8) void {
    if (globals.framebuffer_output) |output| {
        output.writeFn(output.state, str);
    }
    if (globals.serial_output) |output| {
        output.writeFn(output.state, str);
    }
}

fn splatToOutputs(str: []const u8, splat: usize) void {
    if (globals.framebuffer_output) |output| {
        output.splatFn(output.state, str, splat);
    }
    if (globals.serial_output) |output| {
        output.splatFn(output.state, str, splat);
    }
}

const globals = struct {
    var lock: kernel.sync.TicketSpinLock = .{};

    var framebuffer_output: ?Output = null;
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
