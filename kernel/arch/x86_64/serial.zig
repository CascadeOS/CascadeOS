// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

const portReadU8 = x86_64.instructions.portReadU8;
const portWriteU8 = x86_64.instructions.portWriteU8;

const OUTPUT_READY: u8 = 1 << 5;

// TODO: Implement a proper serial port driver

pub const SerialPort = struct {
    z_data_port: u16,
    z_line_status_port: u16,

    /// Initialize the serial port at `com_port` with the baud rate `baud_rate`
    pub fn init(com_port: COMPort, baud_rate: BaudRate) SerialPort {
        // FIXME: Check if the serial port exists before using it.
        // Writing to then reading the scratch register `data_port_number + 7` should return the same value.

        const data_port_number = com_port.toPort();

        // Disable interrupts
        portWriteU8(data_port_number + 1, 0x00);

        // Set Baudrate
        portWriteU8(data_port_number + 3, 0x80);
        portWriteU8(data_port_number, baud_rate.toDivisor());
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
            .z_data_port = data_port_number,
            .z_line_status_port = data_port_number + 5,
        };
    }

    fn waitForOutputReady(self: SerialPort) void {
        while (portReadU8(self.z_line_status_port) & OUTPUT_READY == 0) {
            x86_64.instructions.pause();
        }
    }

    pub const Writer = std.io.Writer(SerialPort, error{}, writerImpl);
    pub inline fn writer(self: SerialPort) Writer {
        return .{ .context = self };
    }

    /// The impl function driving the `std.io.Writer`
    fn writerImpl(self: SerialPort, bytes: []const u8) error{}!usize {
        for (bytes) |char| {
            self.waitForOutputReady();
            // TODO: Does a serial port need `\r` before `\n`?
            portWriteU8(self.z_data_port, char);
        }
        return bytes.len;
    }
};

pub const COMPort = enum {
    COM1,
    COM2,
    COM3,
    COM4,

    inline fn toPort(com_port: COMPort) u16 {
        return switch (com_port) {
            .COM1 => 0x3F8,
            .COM2 => 0x2F8,
            .COM3 => 0x3E8,
            .COM4 => 0x2E8,
        };
    }
};

pub const BaudRate = enum {
    Baud115200,
    Baud57600,
    Baud38400,
    Baud28800,

    inline fn toDivisor(baud_rate: BaudRate) u8 {
        return switch (baud_rate) {
            .Baud115200 => 1,
            .Baud57600 => 2,
            .Baud38400 => 3,
            .Baud28800 => 4,
        };
    }
};
