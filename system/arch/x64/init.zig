// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const EarlyOutputWriter = SerialPort.Writer;

var opt_early_output_serial_port: ?SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    // TODO: check each COM port in turn rather than assuming COM1 is available.
    opt_early_output_serial_port = SerialPort.init(.COM1, .Baud115200);
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub inline fn writeToEarlyOutput(bytes: []const u8) void {
    if (opt_early_output_serial_port) |early_output_serial_port| {
        early_output_serial_port.write(bytes);
    }
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub inline fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    _ = bootstrap_executor;
}

/// Load the provided `Executor` as the current executor.
pub inline fn loadExecutor(executor: *kernel.Executor) void {
    executor.arch.gdt.load();

    // TODO: set double fault, nmi and privilege stacks in the TSS

    executor.arch.gdt.setTss(&executor.arch.tss);

    // TODO: load the IDT

    lib_x64.registers.KERNEL_GS_BASE.write(@intFromPtr(executor));
}

/// A *very* basic write only serial port.
const SerialPort = struct {
    _data_port: u16,
    _line_status_port: u16,

    /// Init the serial port at `com_port` with the baud rate `baud_rate`
    pub fn init(com_port: COMPort, baud_rate: BaudRate) SerialPort {
        const data_port_number = @intFromEnum(com_port);

        // Disable interrupts
        portWriteU8(data_port_number + 1, 0x00);

        // Set Baudrate
        portWriteU8(data_port_number + 3, 0x80);
        portWriteU8(data_port_number, @intFromEnum(baud_rate));
        portWriteU8(data_port_number + 1, 0x00);

        // 8 bits, no parity, one stop bit
        portWriteU8(data_port_number + 3, 0x03);

        // Enable FIFO
        portWriteU8(data_port_number + 2, 0xC7);

        // Mark data terminal ready
        portWriteU8(data_port_number + 4, 0x0B);

        // Enable interupts
        portWriteU8(data_port_number + 1, 0x01);

        return .{
            ._data_port = data_port_number,
            ._line_status_port = data_port_number + 5,
        };
    }

    /// Write to the serial port.
    pub fn write(self: SerialPort, bytes: []const u8) void {
        var previous_byte: u8 = 0;

        for (bytes) |byte| {
            defer previous_byte = byte;

            if (byte == '\n' and previous_byte != '\r') {
                // TODO: per branch cold
                self.waitForOutputReady();
                portWriteU8(self._data_port, '\r');
            }

            self.waitForOutputReady();
            portWriteU8(self._data_port, byte);
        }
    }

    fn waitForOutputReady(self: SerialPort) void {
        while (portReadU8(self._line_status_port) & OUTPUT_READY == 0) {
            lib_x64.instructions.pause();
        }
    }

    pub const COMPort = enum(u16) {
        COM1 = 0x3F8,
        COM2 = 0x2F8,
        COM3 = 0x3E8,
        COM4 = 0x2E8,
    };

    pub const BaudRate = enum(u8) {
        Baud115200 = 1,
        Baud57600 = 2,
        Baud38400 = 3,
        Baud28800 = 4,
    };

    const portReadU8 = lib_x64.instructions.portReadU8;
    const portWriteU8 = lib_x64.instructions.portWriteU8;
    const OUTPUT_READY: u8 = 1 << 5;
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
