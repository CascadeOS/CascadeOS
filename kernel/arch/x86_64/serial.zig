// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");
const x86_64 = @import("x86_64.zig");

const writeU8 = x86_64.port.writeU8;
const readU8 = x86_64.port.readU8;
const OUTPUT_READY: u8 = 1 << 5;

// TODO: Make this a proper driver
pub const SerialPort = struct {
    z_data_port: u16,
    z_line_status_port: u16,

    /// Initialize the serial port at `com_port` with the baud rate `baud_rate`
    pub fn init(com_port: COMPort, baud_rate: BaudRate) SerialPort {
        // FIXME: Check if the port exists by writing to then reading the scratch register `data_port_number + 7`

        const data_port_number = com_port.toPort();

        // Disable interrupts
        writeU8(data_port_number + 1, 0x00);

        // Set Baudrate
        writeU8(data_port_number + 3, 0x80);
        writeU8(data_port_number, baud_rate.toDivisor());
        writeU8(data_port_number + 1, 0x00);

        // 8 bits, no parity, one stop bit
        writeU8(data_port_number + 3, 0x03);

        // Enable FIFO
        writeU8(data_port_number + 2, 0xC7);

        // Mark data terminal ready
        writeU8(data_port_number + 4, 0x0B);

        // Enable interupts
        writeU8(data_port_number + 1, 0x01);

        return .{
            .z_data_port = data_port_number,
            .z_line_status_port = data_port_number + 5,
        };
    }

    fn waitForOutputReady(self: SerialPort) void {
        while (readU8(self.z_line_status_port) & OUTPUT_READY == 0) {
            x86_64.pause();
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
            // TODO: Should we be checking for `\n` and emitting a `\r` first?
            writeU8(self.z_data_port, char);
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
