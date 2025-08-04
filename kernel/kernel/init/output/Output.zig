// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const Output = @This();

writeFn: *const fn (context: *anyopaque, str: []const u8) void,

splatFn: *const fn (context: *anyopaque, str: []const u8, splat: usize) void,

/// Called to allow the output to remap itself into the non-cached direct map or special heap after they have been
/// initialized.
remapFn: *const fn (context: *anyopaque, current_task: *kernel.Task) anyerror!void,

context: *anyopaque,

pub const writer = &globals.writer;

/// Allow outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs(current_task: *kernel.Task) !void {
    if (globals.framebuffer_output) |output| try output.remapFn(output.context, current_task);
    if (globals.serial_output) |output| try output.remapFn(output.context, current_task);
}

pub fn registerOutputs() void {
    if (@import("framebuffer.zig").tryGetFramebufferOutput()) |output| {
        globals.framebuffer_output = output;
    }

    if (arch.init.tryGetSerialOutput()) |output| {
        globals.serial_output = output;
    }
}

/// Attempt to get some form of init output from generic sources, like ACPI tables or device tree.
pub fn tryGetSerialOutputFromGenericSources() ?kernel.init.Output {
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

        if (kernel.init.devicetree.tryGetSerialOutput()) |output_uart| {
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
        output.writeFn(output.context, str);
    }
    if (globals.serial_output) |output| {
        output.writeFn(output.context, str);
    }
}

fn splatToOutputs(str: []const u8, splat: usize) void {
    if (globals.framebuffer_output) |output| {
        output.splatFn(output.context, str, splat);
    }
    if (globals.serial_output) |output| {
        output.splatFn(output.context, str, splat);
    }
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

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

pub const uart = @import("uart.zig");

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.init_output);
const std = @import("std");
