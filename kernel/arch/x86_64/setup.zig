// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

const limine = kernel.spec.limine;

var serial_port: x86_64.serial.SerialPort = undefined;

fn setup() void {
    // we try to get output up and running as soon as possible.
    serial_port = x86_64.serial.SerialPort.init(.COM1, .Baud115200);

    // print starting message
    serial_port.writer().writeAll(comptime "starting CircuitOS " ++ kernel.info.version ++ "\n") catch unreachable;

    const log = kernel.log.scoped(.setup);

    // now that we have basic output functionality, switch the panic implementation to use it
    log.info("loading simplified panic handler", .{});
    kernel.setPanicFunction(simplePanic);

    @panic("UNIMPLEMENTED"); // TODO: implement initial system setup
}

/// Prints the panic message then disables interrupts and halts.
fn simplePanic(
    msg: []const u8,
    stack_trace: ?*const std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = ret_addr;
    _ = stack_trace;

    serial_port.writer().print("\nPANIC: {s}\n", .{msg}) catch unreachable;

    while (true) {
        x86_64.instructions.disableInterruptsAndHalt();
    }
}

/// Logging function for early boot only.
pub fn earlyLogFn(
    comptime scope: @Type(.EnumLiteral),
    comptime message_level: kernel.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = serial_port.writer();

    const scopeAndLevelText = comptime kernel.log.formatScopeAndLevel(message_level, scope);
    writer.writeAll(scopeAndLevelText) catch unreachable;

    const user_fmt = comptime if (format.len != 0 and format[format.len - 1] == '\n') format else format ++ "\n";
    writer.print(user_fmt, args) catch unreachable;
}

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, setup, .{});
    @panic("setup returned");
}
