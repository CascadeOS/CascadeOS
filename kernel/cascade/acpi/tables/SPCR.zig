// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const cascade = @import("cascade");
const acpi = cascade.acpi;
const core = @import("core");

/// [Serial Port Console Redirection Table](https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/serports/serial-port-console-redirection-table.md)
pub const SPCR = extern struct {
    header: acpi.tables.SharedHeader align(1),

    /// Indicates the type of the register interface.
    interface_type: Type,

    _reserved: u16,

    /// The base address of the Serial Port register set described using the ACPI Generic Address Structure, or 0 if
    /// console redirection is disabled.
    base_address: acpi.Address,

    /// Interrupt type(s) used by the UART.
    ///
    /// Platforms with both a dual-8259 and an I/O APIC or I/O SAPIC must set the `pic` bit and the corresponding
    /// Global System Interrupt bit (e.g. a system that supported 8259 and SAPIC would be 5).
    interrupt_type: InterruptType,

    /// The PC-AT-compatible IRQ used by the UART:
    ///  - 2-7, 9-12, 14-15 = Valid IRQs respectively
    ///  - 0-1, 8, 13, 16-255 = Reserved
    ///
    /// Valid only if `interrupt_type.pic` is `true`.
    irq: u8,

    /// The Global System Interrupt (GSIV) used by the UART.
    ///
    /// Not valid if Bit[1:7] of the `interrupt_type` field is 0.
    ///
    /// If `interrupt_type.armh_gic` is `true` then an Arm GIC interrupt controller is used.
    /// Arm GIC SGI and PPI interrupts cannot be used for the UART, so it is forbidden for this field to be set to any
    /// value in {0, ..., 31} or in {1056, ..., 1119}.
    global_system_interrupt: u32 align(2),

    /// The baud rate the BIOS used for redirection.
    configured_baud_rate: BaudRate,

    parity: Parity,

    stop_bits: StopBits,

    flow_control: FlowControl,

    terminal_type: TerminalType,

    /// Language which the BIOS was redirecting. Must be 0.
    language: u8,

    /// Designates the Device ID of a PCI device that contains a UART to be used as a headless port.
    ///
    /// Must be 0xFFFF if it is not a PCI device.
    pci_device_id: cascade.pci.DeviceID,

    /// Designates the Vendor ID of a PCI device that contains a UART to be used as a headless port.
    ///
    /// Must be 0xFFFF if it is not a PCI device.
    pci_vendor_id: cascade.pci.VendorID,

    /// PCI Bus Number if table describes a PCI device.
    ///
    /// Must be 0x00 if it is not a PCI device.
    pci_bus_number: u8,

    /// PCI Device Number if table describes a PCI device.
    ///
    /// Must be 0x00 if it is not a PCI device.
    pci_device_number: u8,

    /// PCI Function Number if table describes a PCI device.
    ///
    /// Must be 0x00 if it is not a PCI device.
    pci_function_number: u8,

    /// PCI Compatibility flags bitmask. Should be zero by default.
    pci_flags: PCIFlags align(1),

    /// PCI segment number.
    ///
    /// For systems with fewer than 255 PCI buses, this number must be 0.
    pci_segment_number: u8,

    /// For Revision 2 or lower:
    ///  - Must be 0.
    ///
    /// For Revision 3 or higher:
    ///  - Zero, indicating that the UART clock frequency is indeterminate.
    ///  - A non-zero value indicating the UART clock frequency in Hz.
    ///
    /// This field is only present in revision 3 or higher.
    uart_clock_frequency: u32,

    /// Contains a specific non-zero baud rate which overrides the value of the Configured Baud Rate field.
    ///
    /// If this field is zero or not present, Configured Baud Rate is used.
    ///
    /// The Configured Baud Rate field has existed as a single-byte field since the creation of the SPCR table and is
    /// widely supported by operating systems. However, because it is an enumeration, it is limited in its ability to
    /// precisely describe non-traditional baud rates, such as those used by high speed UARTs. Thus, the Precise Baud
    /// Rate field was added to enable firmware to provide supporting operating systems a DWORD value which describes a
    /// specific baud rate (e.g. 1500000).
    ///
    /// When the Precise Baud Rate field contains a non-zero value, the Configured Baud Rate field shall be zero.
    ///
    /// This field is only present in revision 4 or higher.
    precise_baud_rate: u32,

    /// Length, in bytes, of the namespace string, including NUL characters.
    ///
    /// This field is only present in revision 4 or higher.
    namespace_string_length: u16,

    /// Offset, in bytes, from the beginning of this structure to the namespace string.
    ///
    /// This value must be valid because this string must be present.
    ///
    /// This field is only present in revision 4 or higher.
    namespace_string_offset: u16,

    /// NUL-terminated ASCII string to uniquely identify this device.
    ///
    /// This string consists of a fully qualified reference to the object that represents this device in the ACPI
    /// namespace.
    ///
    /// If no namespace device exists, must only contain a single '.' (ASCII period) character.
    ///
    /// This field is only present in revision 4 or higher will return `null` if the revision is lower than 4.
    pub fn namespaceString(spcr: *const SPCR) ?[:0]const u8 {
        if (spcr.header.revision < 4) return null;

        const ptr: [*]const u8 = @ptrCast(spcr);
        const null_ptr: [*:0]const u8 = @ptrCast(ptr + spcr.namespace_string_offset);
        return std.mem.sliceTo(null_ptr, 0);
    }

    pub fn pciAddress(spcr: *const SPCR) ?cascade.pci.Address {
        if (spcr.pci_vendor_id == .none) {
            // FIXME: SPCR says if device id is 0xFFFF then it is not present but the PCI spec does not say that it is
            //        not a valid device ID
            return null;
        }

        return .{
            .segment = spcr.pci_segment_number,
            .bus = spcr.pci_bus_number,
            .device = spcr.pci_device_number,
            .function = spcr.pci_function_number,
        };
    }

    pub const SIGNATURE_STRING = "SPCR";

    pub const Type = extern union {
        revision_1: Revision1,
        revision_2_or_higher: acpi.tables.DBG2.DebugDevice.PortType.SerialSubType,

        pub const Revision1 = enum(u8) {
            /// Full 16550 interface
            @"16550" = 0,
            /// Full 16450 interface (must also accept writing to the 16550 FCR register)
            @"16450" = 1,
        };

        comptime {
            core.testing.expectSize(Type, @sizeOf(u16));
        }
    };

    pub const InterruptType = packed struct(u8) {
        /// PC-AT-compatible dual-8259 IRQ interrupt
        pic: bool,
        /// I/O APIC interrupt (Global System Interrupt)
        ioapic: bool,
        /// I/O SAPIC interrupt (Global System Interrupt)
        iosapic: bool,
        /// ARMH GIC interrupt (Global System Interrupt)
        armh_gic: bool,
        /// RISC-V PLIC/APLIC interrupt (Global System Interrupt)
        riscv_plic: bool,

        _: u3,

        pub fn hasIrq(interrupt_type: InterruptType) bool {
            return interrupt_type.pic;
        }

        pub fn hasGlobalSystemInterrupt(interrupt_type: InterruptType) bool {
            return interrupt_type.ioapic or interrupt_type.iosapic or interrupt_type.armh_gic or interrupt_type.riscv_plic;
        }

        pub fn print(interrupt_type: InterruptType, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("InterruptType{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("pic: {},\n", .{interrupt_type.pic});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("ioapic: {},\n", .{interrupt_type.ioapic});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("iosapic: {},\n", .{interrupt_type.iosapic});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("armh_gic: {},\n", .{interrupt_type.armh_gic});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("riscv_plic: {},\n", .{interrupt_type.riscv_plic});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(interrupt_type: InterruptType, writer: *std.Io.Writer) !void {
            return interrupt_type.print(writer, 0);
        }
    };

    pub const BaudRate = enum(u8) {
        /// As is, operating system relies on the current configuration of serial port until the full featured driver
        /// will be initialized.
        as_is = 0,
        @"9600" = 3,
        @"19200" = 4,
        @"57600" = 6,
        @"115200" = 7,
    };

    pub const Parity = enum(u8) {
        none = 0,
    };

    pub const StopBits = enum(u8) {
        @"1" = 1,
    };

    pub const FlowControl = packed struct(u8) {
        /// DCD required for transmit
        dcd: bool,
        /// RTS/CTS hardware flow control
        rts_cts: bool,
        /// XON/XOFF software control
        xon_xoff: bool,

        _reserved: u5,

        pub fn print(flow_control: FlowControl, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("FlowControl{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("dcd: {},\n", .{flow_control.dcd});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("rts_cts: {},\n", .{flow_control.rts_cts});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("xon_xoff: {},\n", .{flow_control.xon_xoff});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(flow_control: FlowControl, writer: *std.Io.Writer) !void {
            return flow_control.print(writer, 0);
        }
    };

    pub const TerminalType = enum(u8) {
        vt100 = 0,
        /// Extended VT100 (VT100+)
        extended_vt100 = 1,
        vt_utf8 = 2,
        ansi = 3,
    };

    pub const PCIFlags = packed struct(u32) {
        /// Operating System should NOT suppress PNP device enumeration or disable power management for this device.
        ///
        /// Must be 0 if it is not a PCI device.
        dont_suppress_enumeration_or_perform_power_management: bool,

        _: u31,
    };

    pub fn print(spcr: *const SPCR, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        const revision = spcr.header.revision;

        try writer.writeAll("SPCR{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("revision: {},\n", .{revision});

        try writer.splatByteAll(' ', new_indent);
        if (revision < 2) {
            try writer.print("interface_type: {t},\n", .{spcr.interface_type.revision_1});
        } else {
            try writer.print("interface_type: {t},\n", .{spcr.interface_type.revision_2_or_higher});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("base_address: ");
        try spcr.base_address.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("interrupt_type: ");
        try spcr.interrupt_type.print(writer, new_indent);
        try writer.writeAll(",\n");

        if (spcr.interrupt_type.hasIrq()) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("irq: {},\n", .{spcr.irq});
        }

        if (spcr.interrupt_type.hasGlobalSystemInterrupt()) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("global_system_interrupt: {},\n", .{spcr.global_system_interrupt});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("configured_baud_rate: {t},\n", .{spcr.configured_baud_rate});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("flow_control: ");
        try spcr.flow_control.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("terminal_type: {t},\n", .{spcr.terminal_type});

        if (spcr.pciAddress()) |pci_address| {
            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("pci_address: ");
            try pci_address.print(writer, new_indent);
            try writer.writeAll(",\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print(
                "pci_flags.dont_suppress_enumeration_or_perform_power_management: {}\n",
                .{spcr.pci_flags.dont_suppress_enumeration_or_perform_power_management},
            );
        }

        if (revision >= 3) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("uart_clock_frequency: {},\n", .{spcr.uart_clock_frequency});
        }

        if (revision >= 4) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("precise_baud_rate: {},\n", .{spcr.precise_baud_rate});

            if (spcr.namespaceString()) |namespace_string| {
                try writer.splatByteAll(' ', new_indent);
                try writer.print("namespace_string: {s},\n", .{namespace_string});
            } else {
                try writer.splatByteAll(' ', new_indent);
                try writer.print("namespace_string: null,\n", .{});
            }
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(spcr: *const SPCR, writer: *std.Io.Writer) !void {
        return spcr.print(writer, 0);
    }

    comptime {
        core.testing.expectSize(SPCR, 88);
    }

    pub const init = struct {
        pub fn tryGetSerialOutput(current_task: *cascade.Task) ?uart.Uart {
            const output_uart = tryGetSerialOutputInner() catch |err| switch (err) {
                error.DivisorTooLarge => {
                    log.warn(current_task, "baud divisor from SPCR too large", .{});
                    return null;
                },
            } orelse return null;

            return output_uart;
        }

        fn tryGetSerialOutputInner() uart.Baud.DivisorError!?uart.Uart {
            const spcr = AcpiTable.get(0) orelse return null;
            defer spcr.deinit();

            const baud_rate: ?uart.Baud.BaudRate = switch (spcr.table.configured_baud_rate) {
                .as_is => null,
                .@"9600" => .@"9600",
                .@"19200" => .@"19200",
                .@"57600" => .@"57600",
                .@"115200" => .@"115200",
            };

            if (spcr.table.header.revision < 2) {
                switch (spcr.table.interface_type.revision_1) {
                    .@"16550" => {
                        const baud: ?uart.Baud = if (baud_rate) |br| .{
                            .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                            .baud_rate = br,
                        } else null;

                        switch (spcr.table.base_address.address_space) {
                            .memory => return .{
                                .memory_16550 = try uart.Memory16550.create(
                                    cascade.mem.directMapFromPhysical(
                                        .fromInt(spcr.table.base_address.address),
                                    ).toPtr([*]volatile u8),
                                    baud,
                                ) orelse return null,
                            },
                            .io => return .{
                                .io_port_16550 = try uart.IoPort16550.create(
                                    @intCast(spcr.table.base_address.address),
                                    baud,
                                ) orelse return null,
                            },
                            else => return null,
                        }
                    },
                    .@"16450" => {
                        const baud: ?uart.Baud = if (baud_rate) |br| .{
                            .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                            .baud_rate = br,
                        } else null;

                        switch (spcr.table.base_address.address_space) {
                            .memory => return .{
                                .memory_16450 = try uart.Memory16450.create(
                                    cascade.mem.directMapFromPhysical(
                                        .fromInt(spcr.table.base_address.address),
                                    ).toPtr([*]volatile u8),
                                    baud,
                                ) orelse return null,
                            },
                            .io => return .{
                                .io_port_16450 = try uart.IoPort16450.create(
                                    @intCast(spcr.table.base_address.address),
                                    baud,
                                ) orelse return null,
                            },
                            else => return null,
                        }
                    },
                }
            }

            switch (spcr.table.interface_type.revision_2_or_higher) {
                .@"16550", .@"16550-GAS" => {
                    const baud: ?uart.Baud = if (baud_rate) |br| .{
                        .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                        .baud_rate = br,
                    } else null;

                    switch (spcr.table.base_address.address_space) {
                        .memory => return .{
                            .memory_16550 = try uart.Memory16550.create(
                                cascade.mem.directMapFromPhysical(
                                    .fromInt(spcr.table.base_address.address),
                                ).toPtr([*]volatile u8),
                                baud,
                            ) orelse return null,
                        },
                        .io => return .{
                            .io_port_16550 = try uart.IoPort16550.create(
                                @intCast(spcr.table.base_address.address),
                                baud,
                            ) orelse return null,
                        },
                        else => return null,
                    }
                },
                .@"16450" => {
                    const baud: ?uart.Baud = if (baud_rate) |br| .{
                        .clock_frequency = .@"1.8432 MHz", // TODO: we assume the clock frequency is 1.8432 MHz
                        .baud_rate = br,
                    } else null;

                    switch (spcr.table.base_address.address_space) {
                        .memory => return .{
                            .memory_16450 = try uart.Memory16450.create(
                                cascade.mem.directMapFromPhysical(
                                    .fromInt(spcr.table.base_address.address),
                                ).toPtr([*]volatile u8),
                                baud,
                            ) orelse return null,
                        },
                        .io => return .{
                            .io_port_16450 = try uart.IoPort16450.create(
                                @intCast(spcr.table.base_address.address),
                                baud,
                            ) orelse return null,
                        },
                        else => return null,
                    }
                },
                .ArmPL011 => {
                    const baud: ?uart.Baud = if (baud_rate) |br| .{
                        .clock_frequency = .@"24 MHz", // TODO: we assume the clock frequency is 24 MHz
                        .baud_rate = br,
                    } else null;

                    if (core.is_debug) {
                        std.debug.assert(spcr.table.base_address.address_space == .memory);
                        std.debug.assert(spcr.table.base_address.access_size == .dword);
                    }

                    return .{
                        .pl011 = try uart.PL011.create(
                            cascade.mem.directMapFromPhysical(
                                .fromInt(spcr.table.base_address.address),
                            ).toPtr([*]volatile u32),
                            baud,
                        ) orelse return null,
                    };
                },
                else => return null, // TODO: implement other UARTs
            }
        }

        const AcpiTable = cascade.acpi.init.AcpiTable(cascade.acpi.tables.SPCR);
        const uart = cascade.init.Output.uart;
        const log = cascade.debug.log.scoped(.output_init);
    };
};
