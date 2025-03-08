// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Output = @This();

writeFn: *const fn (context: *anyopaque, str: []const u8) void,

/// Called to allow the output to remap itself into the non-cached direct map or special heap after they have been
/// initialized.
remapFn: *const fn (context: *anyopaque, current_task: *kernel.Task) anyerror!void,

context: *anyopaque,

pub const writer = std.io.GenericWriter(
    void,
    error{},
    struct {
        fn writeFn(_: void, bytes: []const u8) error{}!usize {
            if (globals.framebuffer_output) |output| output.writeFn(output.context, bytes);
            if (globals.serial_output) |output| output.writeFn(output.context, bytes);
            return bytes.len;
        }
    }.writeFn,
){ .context = {} };

/// Allow outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs(current_task: *kernel.Task) !void {
    if (globals.framebuffer_output) |output| try output.remapFn(output.context, current_task);
    if (globals.serial_output) |output| try output.remapFn(output.context, current_task);
}

pub fn registerOutputs() void {
    if (@import("framebuffer.zig").tryGetFramebufferOutput()) |output| {
        globals.framebuffer_output = output;
    }

    if (kernel.arch.init.tryGetSerialOutput()) |output| {
        globals.serial_output = output;
    }
}

pub fn tryGetSerialOutputFromAcpiTables() ?kernel.init.Output {
    const static = struct {
        var init_output_uart: uart.Uart = undefined;
    };

    blk: {
        if (kernel.acpi.tables.SPCR.init.tryGetSerialOutput()) |output_uart| {
            static.init_output_uart = output_uart;
            break :blk;
        }

        if (kernel.acpi.tables.DBG2.init.tryGetSerialOutput()) |output_uart| {
            static.init_output_uart = output_uart;
            break :blk;
        }

        return null;
    }

    return static.init_output_uart.output();
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

    var framebuffer_output: ?Output = null;
    var serial_output: ?Output = null;
};

pub const uart = @import("uart.zig");

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init_output);
