// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

const Output = @This();

writeFn: *const fn (context: *anyopaque, str: []const u8) void,

/// Called to allow the output to remap itself into the non-cached direct map or special heap after they have been
/// initialized.
remapFn: *const fn (context: *anyopaque, current_task: *kernel.Task) anyerror!void,

context: *anyopaque,

/// Writes the given string to all init outputs.
pub fn write(str: []const u8) void {
    for (globals.outputs.constSlice()) |output| {
        output.writeFn(output.context, str);
    }
}

pub const writer = std.io.Writer(
    void,
    error{},
    struct {
        fn writeFn(_: void, bytes: []const u8) error{}!usize {
            write(bytes);
            return bytes.len;
        }
    }.writeFn,
){ .context = {} };

pub fn registerOutput(output: Output) void {
    globals.outputs.append(output) catch {
        @panic("exceeded maximum number of init outputs");
    };
}

/// Allow init outputs to remap themselves into the non-cached direct map or special heap.
pub fn remapOutputs(current_task: *kernel.Task) !void {
    for (globals.outputs.constSlice()) |output| {
        try output.remapFn(output.context, current_task);
    }
}

pub const globals = struct {
    pub var lock: kernel.sync.TicketSpinLock = .{};

    var outputs: std.BoundedArray(
        Output,
        kernel.config.maximum_number_of_init_outputs,
    ) = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
