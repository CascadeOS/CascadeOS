// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
///
/// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
/// meaning this function is not expected to ever be called.
///
/// This function is required to disable interrupts and halt execution at a minimum but may perform any additional
/// debugging and error output if possible.
pub fn unknownBootloaderEntryPoint() callconv(.Naked) noreturn {
    @call(.always_inline, arch.interrupts.disableInterruptsAndHalt, .{});
    unreachable;
}

var opt_early_output_serial_port: ?SerialPort = null;

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    for (std.meta.tags(SerialPort.COMPort)) |com_port| {
        if (SerialPort.init(com_port, .Baud115200)) |serial_port| {
            opt_early_output_serial_port = serial_port;
            return;
        }
    }
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (opt_early_output_serial_port) |early_output_serial_port| {
        early_output_serial_port.write(bytes);
    }
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) void {
    _ = bootstrap_executor;
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
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

    /// Init the serial port at `com_port` with the baud rate `baud_rate`.
    ///
    /// Returns `null` if either the serial port is not connected or is faulty.
    pub fn init(com_port: COMPort, baud_rate: BaudRate) ?SerialPort {
        const data_port_number = @intFromEnum(com_port);

        // write to the scratch register to check if the serial port is connected
        portWriteU8(data_port_number + 7, 0xBA);

        // if the scratch register is not `0xBA` then the serial port is not connected
        if (portReadU8(data_port_number + 7) != 0xBA) return null;

        // disable interrupts
        portWriteU8(data_port_number + 1, 0x00);

        // set baudrate
        portWriteU8(data_port_number + 3, 0x80);
        portWriteU8(data_port_number, @intFromEnum(baud_rate));
        portWriteU8(data_port_number + 1, 0x00);

        // 8 bits, no parity, one stop bit
        portWriteU8(data_port_number + 3, 0x03);

        // enable FIFO
        portWriteU8(data_port_number + 2, 0xC7);

        // mark data terminal ready
        portWriteU8(data_port_number + 4, 0x0B);

        // enable loopback
        portWriteU8(data_port_number + 4, 0x1E);

        // send `0xAE` to the serial port
        portWriteU8(data_port_number, 0xAE);

        // check that the `0xAE` was received due to loopback
        if (portReadU8(data_port_number) != 0xAE) return null;

        // disable loopback
        portWriteU8(data_port_number + 4, 0x0F);

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
const arch = @import("arch");
