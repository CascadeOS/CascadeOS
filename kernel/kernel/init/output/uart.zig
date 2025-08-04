// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const Uart = union(enum) {
    io_port_16550: IoPort16550,
    memory_16550: Memory16550,
    io_port_16450: IoPort16450,
    memory_16450: Memory16450,

    pl011: PL011,

    pub fn output(uart: *Uart) kernel.init.Output {
        switch (uart.*) {
            inline else => |*u| return u.output(),
        }
    }
};

pub const IoPort16550 = Uart16X50(.io_port, .enabled);
pub const Memory16550 = Uart16X50(.memory, .enabled);
pub const IoPort16450 = Uart16X50(.io_port, .disabled);
pub const Memory16450 = Uart16X50(.memory, .disabled);

/// A basic write only 16550/16450 UART.
///
/// Assumes the UART clock is 115200 Hz matching the PC serial port clock.
///
/// Always sets 8 bits, no parity, one stop bit and disables interrupts.
///
/// [UART 16550](https://caro.su/msx/ocm_de1/16550.pdf)
/// [PC16550D Universal Asynchronous Receiver/Transmitter with FIFOs](https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf)
fn Uart16X50(comptime mode: enum { memory, io_port }, comptime fifo_mode: enum { disabled, enabled }) type {
    return struct {
        write_register: AddressT,
        line_status_register: AddressT,

        const UartT = @This();

        pub const AddressT = switch (mode) {
            .memory => [*]volatile u8,
            .io_port => u16,
        };

        pub fn init(base: AddressT, baud: ?Baud) Baud.DivisorError!?UartT {
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

            if (fifo_mode == .enabled) {
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
                .write_register = base + @intFromEnum(RegisterOffset.write),
                .line_status_register = base + @intFromEnum(RegisterOffset.line_status),
            };
        }

        fn writeSlice(uart: UartT, str: []const u8) void {
            if (fifo_mode == .enabled) {
                var i: usize = 0;

                var last_byte_carridge_return = false;

                while (i < str.len) {
                    uart.waitForOutputReady();

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

                                    writeRegister(uart.write_register, '\r');
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

                        writeRegister(uart.write_register, byte);
                        bytes_to_write -= 1;
                        i += 1;
                    }
                }
            } else {
                for (0..str.len) |i| {
                    const byte = str[i];

                    if (byte == '\n') {
                        @branchHint(.unlikely);

                        const newline_first_or_only = str.len == 1 or i == 0;

                        if (newline_first_or_only or str[i - 1] != '\r') {
                            @branchHint(.likely);
                            uart.waitForOutputReady();
                            writeRegister(uart.write_register, '\r');
                        }
                    }

                    uart.waitForOutputReady();
                    writeRegister(uart.write_register, byte);
                }
            }
        }

        pub fn output(uart: *UartT) kernel.init.Output {
            return .{
                .writeFn = struct {
                    fn writeFn(context: *anyopaque, str: []const u8) void {
                        const inner_uart: *UartT = @ptrCast(@alignCast(context));
                        inner_uart.writeSlice(str);
                    }
                }.writeFn,
                .splatFn = struct {
                    fn splatFn(context: *anyopaque, str: []const u8, splat: usize) void {
                        const inner_uart: *UartT = @ptrCast(@alignCast(context));
                        for (0..splat) |_| inner_uart.writeSlice(str);
                    }
                }.splatFn,
                .remapFn = struct {
                    fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                        switch (mode) {
                            .io_port => {},
                            .memory => {
                                const inner_uart: *UartT = @ptrCast(@alignCast(context));
                                const write_register_physical_address = try kernel.mem.physicalFromDirectMap(
                                    .fromPtr(@volatileCast(inner_uart.write_register)),
                                );
                                inner_uart.write_register = kernel.mem
                                    .nonCachedDirectMapFromPhysical(write_register_physical_address)
                                    .toPtr([*]volatile u8);
                                inner_uart.line_status_register = inner_uart.write_register + @intFromEnum(RegisterOffset.line_status);
                            },
                        }
                    }
                }.remapFn,
                .context = uart,
            };
        }

        inline fn waitForOutputReady(uart: UartT) void {
            while (true) {
                const line_status: LineStatusRegister = @bitCast(readRegister(uart.line_status_register));
                if (line_status.transmitter_holding_register_empty) return;
                // TODO: should there be a spinloop hint here?
            }
        }

        inline fn writeRegister(target: AddressT, byte: u8) void {
            switch (mode) {
                .io_port => arch.io.writePort(u8, target, byte) catch unreachable,
                .memory => target[0] = byte,
            }
        }

        inline fn readRegister(target: AddressT) u8 {
            return switch (mode) {
                .io_port => arch.io.readPort(u8, target) catch unreachable,
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

/// A basic write only PrimeCell PL011 UART.
///
/// 24 Mhz?
///
/// [Technical Reference Manual](https://developer.arm.com/documentation/ddi0183/latest/)
pub const PL011 = struct {
    write_register: [*]volatile u32,
    flag_register: [*]volatile u32,

    pub fn init(base: [*]volatile u32, baud: ?Baud) Baud.DivisorError!?PL011 {
        const identification =
            readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification3)) << 24 |
            readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification2)) << 16 |
            readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification1)) << 8 |
            readRegister(base + @intFromEnum(RegisterOffset.PrimeCellIdentification0));

        if (identification != 0xB105F00D) return null;

        // disable UART
        {
            var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
            control.enable = false;
            control.transmit_enable = false;
            control.receive_enable = false;
            writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
        }

        // disable interrupts
        {
            var interrupt_mask: InterruptMaskRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.InterruptMask)));
            interrupt_mask.masks = 0;
            writeRegister(base + @intFromEnum(RegisterOffset.InterruptMask), @bitCast(interrupt_mask));
        }

        // set baudrate
        if (baud) |b| {
            const divisor = try b.fractionalDivisor();

            writeRegister(
                base + @intFromEnum(RegisterOffset.IntegerBaudRate),
                @bitCast(IntegerBaudRateRegister{
                    .integer = divisor.integer,
                }),
            );
            writeRegister(
                base + @intFromEnum(RegisterOffset.FractionalBaudRate),
                @bitCast(FractionalBaudRateRegister{
                    .fractional = divisor.fractional,
                }),
            );
        }

        // 8 bits, no parity, one stop bit
        {
            var line_control: LineControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.LineControl)));
            line_control.word_length = .@"8";
            line_control.two_stop_bits = false;
            line_control.parity = false;
            line_control.enable_fifo = false; // clear fifo
            writeRegister(base + @intFromEnum(RegisterOffset.LineControl), @bitCast(line_control));

            line_control.enable_fifo = true; // enable fifo
            writeRegister(base + @intFromEnum(RegisterOffset.LineControl), @bitCast(line_control));
        }

        // enable UART with loopback
        {
            var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
            control.enable = true;
            control.loopback = true;
            control.transmit_enable = true;
            writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
        }

        // send `\r` to the UART
        writeRegister(base + @intFromEnum(RegisterOffset.Write), '\r');

        // check that the `\r` was received due to loopback
        if (readRegister(base + @intFromEnum(RegisterOffset.Read)) != '\r') return null;

        // disable loopback
        {
            var control: ControlRegister = @bitCast(readRegister(base + @intFromEnum(RegisterOffset.Control)));
            control.loopback = false;
            writeRegister(base + @intFromEnum(RegisterOffset.Control), @bitCast(control));
        }

        return .{
            .write_register = base + @intFromEnum(RegisterOffset.Write),
            .flag_register = base + @intFromEnum(RegisterOffset.Flag),
        };
    }

    fn writeSlice(pl011: PL011, str: []const u8) void {
        var i: usize = 0;

        var last_byte_carridge_return = false;

        while (i < str.len) {
            pl011.waitForOutputReady();

            // FIFO is empty meaning we can write 32 bytes
            var bytes_to_write = @min(str.len - i, 32);

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

                            writeRegister(pl011.write_register, '\r');
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

                writeRegister(pl011.write_register, byte);
                bytes_to_write -= 1;
                i += 1;
            }
        }
    }

    pub fn output(pl011: *PL011) kernel.init.Output {
        return .{
            .writeFn = struct {
                fn writeFn(context: *anyopaque, str: []const u8) void {
                    const uart: *PL011 = @ptrCast(@alignCast(context));
                    uart.writeSlice(str);
                }
            }.writeFn,
            .splatFn = struct {
                fn splatFn(context: *anyopaque, str: []const u8, splat: usize) void {
                    const uart: *PL011 = @ptrCast(@alignCast(context));
                    for (0..splat) |_| uart.writeSlice(str);
                }
            }.splatFn,
            .remapFn = struct {
                fn remapFn(context: *anyopaque, _: *kernel.Task) anyerror!void {
                    const uart: *PL011 = @ptrCast(@alignCast(context));
                    const write_register_physical_address = try kernel.mem.physicalFromDirectMap(
                        .fromPtr(@volatileCast(uart.write_register)),
                    );
                    uart.write_register = kernel.mem
                        .nonCachedDirectMapFromPhysical(write_register_physical_address)
                        .toPtr([*]volatile u32);
                    uart.flag_register = uart.write_register + @intFromEnum(RegisterOffset.Flag);
                }
            }.remapFn,
            .context = pl011,
        };
    }

    inline fn waitForOutputReady(pl011: PL011) void {
        while (true) {
            const flags: FlagRegister = @bitCast(readRegister(pl011.flag_register));
            if (flags.transmit_fifo_empty) return;
            // TODO: should there be a spinloop hint here?
        }
    }

    inline fn writeRegister(target: [*]volatile u32, value: u32) void {
        target[0] = value;
    }

    inline fn readRegister(target: [*]volatile u32) u32 {
        return target[0];
    }

    const RegisterOffset = enum(usize) {
        ReadWrite = 0x000 / 4,
        Flag = 0x018 / 4,
        IntegerBaudRate = 0x024 / 4,
        FractionalBaudRate = 0x028 / 4,
        LineControl = 0x02c / 4,
        Control = 0x030 / 4,
        InterruptMask = 0x038 / 4,
        PrimeCellIdentification0 = 0xFF0 / 4,
        PrimeCellIdentification1 = 0xFF4 / 4,
        PrimeCellIdentification2 = 0xFF8 / 4,
        PrimeCellIdentification3 = 0xFFC / 4,

        pub const Read: RegisterOffset = .ReadWrite;
        pub const Write: RegisterOffset = .ReadWrite;
    };

    const ControlRegister = packed struct(u32) {
        enable: bool,

        _1: u6,

        loopback: bool,

        transmit_enable: bool,
        receive_enable: bool,

        _2: u22,
    };

    const InterruptMaskRegister = packed struct(u32) {
        masks: u10,
        _: u22,
    };

    const LineControlRegister = packed struct(u32) {
        _1: u1,
        parity: bool,
        _2: u1,
        two_stop_bits: bool,
        enable_fifo: bool,
        word_length: WordLength,
        _3: u25,

        pub const WordLength = enum(u2) {
            @"5" = 0b00,
            @"6" = 0b01,
            @"7" = 0b10,
            @"8" = 0b11,
        };
    };

    const IntegerBaudRateRegister = packed struct(u32) {
        integer: u16,
        _: u16 = 0,
    };

    const FractionalBaudRateRegister = packed struct(u32) {
        fractional: u6,
        _: u26 = 0,
    };

    const FlagRegister = packed struct(u32) {
        _1: u7,

        transmit_fifo_empty: bool,

        _2: u24,
    };
};

pub const Baud = struct {
    /// The clock frequency of the UART in Hz.
    ///
    /// Cannot be zero.
    clock_frequency: Frequency,

    /// The baud rate of the UART in bits per second.
    ///
    /// Cannot be zero.
    baud_rate: BaudRate,

    pub const BaudRate = enum(u64) {
        @"115200" = 115200,
        @"57600" = 57600,
        @"19200" = 19200,
        @"9600" = 9600,
        _,
    };

    pub const Frequency = enum(u64) {
        @"1.8432 MHz" = 1843200,
        @"3.6864 MHz" = 3686400,
        @"24 MHz" = 24000000,
        _,
    };

    pub const DivisorError = error{
        DivisorTooLarge,
    };

    pub fn integerDivisor(baud: Baud) DivisorError!u16 {
        const baud_rate = @intFromEnum(baud.baud_rate);
        const clock_frequency = @intFromEnum(baud.clock_frequency);

        std.debug.assert(baud_rate != 0);
        std.debug.assert(clock_frequency != 0);

        const divisor = clock_frequency / (baud_rate * 16);
        return std.math.cast(u16, divisor) orelse return error.DivisorTooLarge;
    }

    pub const Fractional = packed struct(u22) {
        fractional: u6,
        integer: u16,
    };

    pub fn fractionalDivisor(baud: Baud) DivisorError!Fractional {
        const baud_rate = @intFromEnum(baud.baud_rate);
        const clock_frequency = @intFromEnum(baud.clock_frequency);

        std.debug.assert(baud_rate != 0);
        std.debug.assert(clock_frequency != 0);

        const divisor = (64 * clock_frequency) / (baud_rate * 16);
        return @bitCast(std.math.cast(u22, divisor) orelse return error.DivisorTooLarge);
    }
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const std = @import("std");
