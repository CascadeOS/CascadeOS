// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub const Uart = union(enum) {
    io_port_16550: IoPort16550,
    memory_16550: Memory16550,
    io_port_16450: IoPort16450,
    memory_16450: Memory16450,

    old_uart: OldUart, // TODO: implement other UARTs - arm PL011 first

    pub fn output(self: *Uart) kernel.init.Output {
        switch (self.*) {
            inline else => |*uart| return uart.output(),
        }
    }
};

pub const IoPort16550 = Uart16X50(.io_port, true);
pub const Memory16550 = Uart16X50(.memory, true);
pub const IoPort16450 = Uart16X50(.io_port, false);
pub const Memory16450 = Uart16X50(.memory, false);

/// A basic write only 16550/16450 UART.
///
/// Assumes the UART clock is 115200 Hz matching the PC serial port clock.
///
/// Always sets 8 bits, no parity, one stop bit and disables interrupts.
///
/// [PC16550D Universal Asynchronous Receiver/Transmitter with FIFOs](https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf)
fn Uart16X50(comptime mode: enum { memory, io_port }, comptime fifo: bool) type {
    return struct {
        write_register: AddressT,
        line_status_register: AddressT,

        const Self = @This();

        pub const AddressT = switch (mode) {
            .memory => [*]volatile u8,
            .io_port => u16,
        };

        pub fn init(base: AddressT, baud: ?Baud) Baud.DivisorError!?Self {
            // write to scratch register to check if the UART is connected
            writeRegister(base + @intFromEnum(RegisterOffset.scratch), 0xBA);

            // if the scratch register is not `0xBA` then the UART is not connected
            if (readRegister(base + @intFromEnum(RegisterOffset.scratch)) != 0xBA) return null;

            // disable UART
            writeRegister(
                base + @intFromEnum(RegisterOffset.modem_control),
                @bitCast(ModemControlRegister{
                    .dtr = false,
                    .rts = false,
                    .out1 = false,
                    .out2 = false,
                    .loopback = false,
                }),
            );

            // disable interrupts
            writeRegister(
                base + @intFromEnum(RegisterOffset.interrupt_enable),
                @bitCast(InterruptEnableRegister{
                    .received_data_available = false,
                    .transmit_holding_register_empty = false,
                    .receive_line_status = false,
                    .modem_status = false,
                }),
            );

            // set baudrate
            if (baud) |b| {
                writeRegister(
                    base + @intFromEnum(RegisterOffset.line_control),
                    @bitCast(LineControlRegister{
                        .word_length = .@"8",
                        .stop_bits = .@"1",
                        .parity = false,
                        .even_parity = false,
                        .stick_parity = false,
                        .set_break = false,
                        .divisor_latch_access = true,
                    }),
                );

                const divisor = try b.integerDivisor();

                writeRegister(
                    base + @intFromEnum(RegisterOffset.divisor_latch_lsb),
                    @truncate(divisor),
                );
                writeRegister(
                    base + @intFromEnum(RegisterOffset.divisor_latch_msb),
                    @truncate(divisor >> 8),
                );
            }

            // 8 bits, no parity, one stop bit
            writeRegister(
                base + @intFromEnum(RegisterOffset.line_control),
                @bitCast(LineControlRegister{
                    .word_length = .@"8",
                    .stop_bits = .@"1",
                    .parity = false,
                    .even_parity = false,
                    .stick_parity = false,
                    .set_break = false,
                    .divisor_latch_access = false,
                }),
            );

            if (fifo) {
                // enable FIFO
                writeRegister(
                    base + @intFromEnum(RegisterOffset.fifo_control),
                    @bitCast(FIFOControlRegister{
                        .enable_fifo = true,
                        .clear_receive_fifo = true,
                        .clear_transmit_fifo = true,
                        .rxrdy_txrdy = false,
                        .trigger_level = .@"1",
                    }),
                );
            }

            // enable UART with loopback
            writeRegister(
                base + @intFromEnum(RegisterOffset.modem_control),
                @bitCast(ModemControlRegister{
                    .dtr = true,
                    .rts = true,
                    .out1 = true,
                    .out2 = true,
                    .loopback = true,
                }),
            );

            // send `0xAE` to the UART
            writeRegister(base, 0xAE);

            // check that the `0xAE` was received due to loopback
            if (readRegister(base) != 0xAE) return null;

            // disable loopback
            writeRegister(
                base + @intFromEnum(RegisterOffset.modem_control),
                @bitCast(ModemControlRegister{
                    .dtr = true,
                    .rts = true,
                    .out1 = true,
                    .out2 = true,
                    .loopback = false,
                }),
            );

            return .{
                .write_register = base,
                .line_status_register = base + @intFromEnum(RegisterOffset.line_status),
            };
        }

        fn writeSlice(self: Self, str: []const u8) void {
            if (fifo) {
                var i: usize = 0;

                var last_byte_carridge_return = false;

                while (i < str.len) {
                    self.waitForOutputReady();

                    // FIFO is empty meaning we can write 16 bytes
                    var bytes_to_write = @min(str.len - i, 16);

                    while (bytes_to_write > 0) {
                        const byte = str[i];

                        switch (byte) {
                            '\r' => {
                                @branchHint(.unlikely);
                                last_byte_carridge_return = true;
                            },
                            '\n' => {
                                @branchHint(.unlikely);

                                if (!last_byte_carridge_return) {
                                    @branchHint(.likely);

                                    writeRegister(self.write_register, '\r');
                                    bytes_to_write -= 1;

                                    if (bytes_to_write == 0) {
                                        @branchHint(.unlikely);

                                        last_byte_carridge_return = true;

                                        break;
                                    }
                                }

                                last_byte_carridge_return = false;
                            },
                            else => {
                                @branchHint(.likely);
                                last_byte_carridge_return = false;
                            },
                        }

                        writeRegister(self.write_register, byte);
                        bytes_to_write -= 1;
                        i += 1;
                    }
                }
            } else {
                for (0..str.len) |i| {
                    const byte = str[i];

                    if (byte == '\n') {
                        @branchHint(.unlikely);

                        if (i != 0 and str[i - 1] != '\r') {
                            @branchHint(.likely);
                            self.waitForOutputReady();
                            writeRegister(self.write_register, '\r');
                        }
                    }

                    self.waitForOutputReady();
                    writeRegister(self.write_register, byte);
                }
            }
        }

        pub fn output(self: *Self) kernel.init.Output {
            return .{
                .writeFn = struct {
                    fn writeFn(context: *anyopaque, str: []const u8) void {
                        const uart: *Self = @ptrCast(@alignCast(context));
                        uart.writeSlice(str);
                    }
                }.writeFn,
                .remapFn = struct {
                    fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                        switch (mode) {
                            .io_port => {},
                            .memory => {
                                const uart: *Self = @ptrCast(@alignCast(context));
                                const write_register_physical_address = try kernel.vmm.physicalFromDirectMap(
                                    .fromPtr(@volatileCast(uart.write_register)),
                                );
                                uart.write_register = kernel.vmm
                                    .nonCachedDirectMapFromPhysical(write_register_physical_address)
                                    .toPtr([*]volatile u8);
                                uart.line_status_register = uart.write_register + @intFromEnum(RegisterOffset.line_status);
                            },
                        }
                    }
                }.remapFn,
                .context = self,
            };
        }

        inline fn waitForOutputReady(self: Self) void {
            while (true) {
                const line_status: LineStatusRegister = @bitCast(readRegister(self.line_status_register));
                if (line_status.transmitter_holding_register_empty) break;
                // TODO: should there be a spinloop hint here?
            }
        }

        inline fn writeRegister(target: AddressT, byte: u8) void {
            switch (mode) {
                .io_port => kernel.arch.io.writePort(u8, target, byte) catch unreachable,
                .memory => target[0] = byte,
            }
        }

        inline fn readRegister(target: AddressT) u8 {
            return switch (mode) {
                .io_port => kernel.arch.io.readPort(u8, target) catch unreachable,
                .memory => target[0],
            };
        }

        const RegisterOffset = enum(u3) {
            read_write_divisor_latch_lsb = 0,
            interrupt_enable_divisor_latch_msb = 1,
            interrupt_identification_fifo_control = 2,
            line_control = 3,
            modem_control = 4,
            line_status = 5,
            modem_status = 6,
            scratch = 7,

            pub const read: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const write: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const divisor_latch_lsb: RegisterOffset = .read_write_divisor_latch_lsb;
            pub const interrupt_enable: RegisterOffset = .interrupt_enable_divisor_latch_msb;
            pub const divisor_latch_msb: RegisterOffset = .interrupt_enable_divisor_latch_msb;
            pub const interrupt_identification: RegisterOffset = .interrupt_identification_fifo_control;
            pub const fifo_control: RegisterOffset = .interrupt_identification_fifo_control;
        };

        const InterruptEnableRegister = packed struct(u8) {
            received_data_available: bool,
            transmit_holding_register_empty: bool,
            receive_line_status: bool,
            modem_status: bool,

            _reserved: u4 = 0,
        };

        const LineControlRegister = packed struct(u8) {
            word_length: WordLength,
            stop_bits: StopBits,
            parity: bool,
            even_parity: bool,
            stick_parity: bool,
            set_break: bool,
            divisor_latch_access: bool,

            pub const WordLength = enum(u2) {
                @"5" = 0b00,
                @"6" = 0b01,
                @"7" = 0b10,
                @"8" = 0b11,
            };

            pub const StopBits = enum(u1) {
                /// One stop bit is generated in the transmitted data.
                @"1" = 0,

                /// When 5-bit word length is selected one and a half stop bits are generated.
                ///
                /// When either a 6-, 7-, or 8-bit word length is selected, two stop bits are generated.
                @"1.5 / 2" = 1,
            };
        };

        const FIFOControlRegister = packed struct(u8) {
            enable_fifo: bool,
            clear_receive_fifo: bool,
            clear_transmit_fifo: bool,
            rxrdy_txrdy: bool,
            _reserved: u2 = 0,
            trigger_level: TriggerLevel,

            pub const TriggerLevel = enum(u2) {
                @"1" = 0b00,
                @"4" = 0b01,
                @"8" = 0b10,
                @"14" = 0b11,
            };
        };

        const ModemControlRegister = packed struct(u8) {
            dtr: bool,
            rts: bool,
            out1: bool,
            out2: bool,
            loopback: bool,
            _reserved: u3 = 0,
        };

        const LineStatusRegister = packed struct(u8) {
            data_ready: bool,
            overrun_error: bool,
            parity_error: bool,
            framing_error: bool,
            break_interrupt: bool,
            transmitter_holding_register_empty: bool,
            transmitter_empty: bool,
            _: u1,
        };
    };
}

pub const Baud = struct {
    /// The clock frequency of the UART in Hz.
    ///
    /// Cannot be zero.
    clock_frequency: Frequency,

    /// The baud rate of the UART in bits per second.
    ///
    /// Cannot be zero.
    baud_rate: BaudRate,

    exact: bool = true,

    pub const BaudRate = enum(u64) {
        @"115200" = 115200,
        @"57600" = 57600,
        @"19200" = 19200,
        @"9600" = 9600,
        _,
    };

    pub const Frequency = enum(u64) {
        @"1.8432 MHz" = 1843200,
        _,
    };

    pub const DivisorError = error{
        BaudDivisorTooLarge,
        BaudDivisorNotExact,
    };

    pub fn integerDivisor(self: Baud) DivisorError!u16 {
        const baud_rate = @intFromEnum(self.baud_rate);
        const clock_frequency = @intFromEnum(self.clock_frequency);

        std.debug.assert(baud_rate != 0);
        std.debug.assert(clock_frequency != 0);

        const divisor = if (self.exact)
            std.math.divExact(
                u64,
                clock_frequency,
                baud_rate * 16,
            ) catch |err| switch (err) {
                error.UnexpectedRemainder => return error.BaudDivisorNotExact,
                error.DivisionByZero => unreachable,
            }
        else
            clock_frequency / (baud_rate * 16);

        return std.math.cast(u16, divisor) orelse return error.BaudDivisorTooLarge;
    }
};

/// A basic write only UART.
///
/// TODO: a write only implementation compatible with Arm PL011
pub const OldUart = struct {
    ptr: *volatile u8,

    pub fn init(address: core.VirtualAddress) OldUart {
        return .{
            .ptr = address.toPtr(*volatile u8),
        };
    }

    pub fn output(self: *OldUart) kernel.init.Output {
        return .{
            .writeFn = struct {
                fn writeFn(context: *anyopaque, str: []const u8) void {
                    const uart: *OldUart = @ptrCast(@alignCast(context));
                    for (0..str.len) |i| {
                        const byte = str[i];

                        if (byte == '\n') {
                            @branchHint(.unlikely);

                            if (i != 0 and str[i - 1] != '\r') {
                                @branchHint(.likely);
                                uart.ptr.* = '\r';
                            }
                        }

                        uart.ptr.* = byte;
                    }
                }
            }.writeFn,
            .remapFn = struct {
                fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                    const uart: *OldUart = @ptrCast(@alignCast(context));
                    const physical_address = try kernel.vmm.physicalFromDirectMap(.fromPtr(@volatileCast(uart.ptr)));
                    uart.ptr = kernel.vmm.nonCachedDirectMapFromPhysical(physical_address).toPtr(*volatile u8);
                }
            }.remapFn,
            .context = self,
        };
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
