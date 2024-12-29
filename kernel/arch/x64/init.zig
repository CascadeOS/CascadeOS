// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Attempt to set up some form of early output.
pub fn setupEarlyOutput() void {
    for (std.meta.tags(SerialPort.COMPort)) |com_port| {
        if (SerialPort.init(com_port, .Baud115200)) |serial_port| {
            globals.opt_early_output_serial_port = serial_port;
            return;
        }
    }
}

/// Write to early output.
///
/// Cannot fail, any errors are ignored.
pub fn writeToEarlyOutput(bytes: []const u8) void {
    if (globals.opt_early_output_serial_port) |early_output_serial_port| {
        early_output_serial_port.write(bytes);
    }
}

/// Prepares the provided `Executor` for the bootstrap executor.
pub fn prepareBootstrapExecutor(
    bootstrap_executor: *kernel.Executor,
) callconv(core.inline_in_non_debug) void {
    const static = struct {
        var bootstrap_double_fault_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
        var bootstrap_non_maskable_interrupt_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;
    };

    bootstrap_executor.arch = .{
        .double_fault_stack = .fromRange(
            .fromSlice(u8, &static.bootstrap_double_fault_stack),
            .fromSlice(u8, &static.bootstrap_double_fault_stack),
        ),
        .non_maskable_interrupt_stack = .fromRange(
            .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
            .fromSlice(u8, &static.bootstrap_non_maskable_interrupt_stack),
        ),
    };

    bootstrap_executor.arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.double_fault),
        bootstrap_executor.arch.double_fault_stack.stack_pointer,
    );
    bootstrap_executor.arch.tss.setInterruptStack(
        @intFromEnum(x64.interrupts.InterruptStackSelector.non_maskable_interrupt),
        bootstrap_executor.arch.non_maskable_interrupt_stack.stack_pointer,
    );
}

/// Load the provided `Executor` as the current executor.
pub fn loadExecutor(executor: *kernel.Executor) void {
    executor.arch.gdt.load();
    executor.arch.gdt.setTss(&executor.arch.tss);

    x64.interrupts.init.loadIdt();

    lib_x64.registers.KERNEL_GS_BASE.write(@intFromPtr(executor));
}

pub const initializeInterrupts = x64.interrupts.init.initializeInterrupts;

const globals = struct {
    var opt_early_output_serial_port: ?SerialPort = null;
};

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
                @branchHint(.unlikely);
                self.writeByte('\r');
            }

            self.writeByte(byte);
        }
    }

    inline fn writeByte(self: SerialPort, byte: u8) void {
        // wait for output ready
        while (portReadU8(self._line_status_port) & OUTPUT_READY == 0) {
            lib_x64.instructions.pause();
        }
        portWriteU8(self._data_port, byte);
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
const lib_x64 = @import("x64");
