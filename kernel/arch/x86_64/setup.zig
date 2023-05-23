// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

const limine = kernel.spec.limine;
const log = kernel.log.scoped(.setup_x86_64);

/// Entry point.
export fn _start() callconv(.Naked) noreturn {
    @call(.never_inline, kernel.setup.setup, .{});
    kernel.utils.panic("setup returned");
}

pub const EarlyOutputWriter = x86_64.serial.SerialPort.Writer;
var early_output_serial_port: x86_64.serial.SerialPort = undefined;

pub fn setupEarlyOutput() void {
    early_output_serial_port = x86_64.serial.SerialPort.init(.COM1, .Baud115200);
}

pub inline fn getEarlyOutputWriter() x86_64.serial.SerialPort.Writer {
    return early_output_serial_port.writer();
}

pub fn earlyArchInitialization() void {
    kernel.utils.panic("UNIMPLEMENTED `earlyArchInitialization`"); // TODO: Implement `earlyArchInitialization`.
}
