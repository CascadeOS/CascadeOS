// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

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
    pci_device_id: kernel.pci.DeviceID,

    /// Designates the Vendor ID of a PCI device that contains a UART to be used as a headless port.
    ///
    /// Must be 0xFFFF if it is not a PCI device.
    pci_vendor_id: kernel.pci.VendorID,

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
    pub fn namespaceString(self: *const SPCR) ?[:0]const u8 {
        if (self.header.revision < 4) return null;

        const ptr: [*]const u8 = @ptrCast(self);
        const null_ptr: [*:0]const u8 = @ptrCast(ptr + self.namespace_string_offset);
        return std.mem.sliceTo(null_ptr, 0);
    }

    pub const SIGNATURE_STRING = "SPCR";

    pub const Type = extern union {
        revision_1: Revision1,
        revision_2_or_higher: SerialSubType,

        pub const Revision1 = enum(u8) {
            /// Full 16550 interface
            @"16550" = 0,
            /// Full 16450 interface (must also accept writing to the 16550 FCR register)
            @"16450" = 1,
        };

        /// [Debug port types and subtypes](https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/bringup/acpi-debug-port-table.md#table-3-debug-port-types-and-subtypes)
        pub const SerialSubType = enum(u16) {
            /// Fully 16550-compatible
            @"16550" = 0x0000,
            /// 16550 subset compatible with DBGP Revision 1
            @"16450" = 0x0001,
            /// MAX311xE SPI UART
            MAX311xE = 0x0002,
            /// Arm PL011 UART
            ArmPL011 = 0x0003,
            /// MSM8x60 (e.g. 8960)
            MSM8x60 = 0x0004,
            /// Nvidia 16550
            Nvidia16550 = 0x0005,
            /// TI OMAP
            TI_OMAP = 0x0006,
            /// APM88xxxx
            APM88xxxx = 0x0008,
            /// MSM8974
            MSM8974 = 0x0009,
            /// SAM5250
            SAM5250 = 0x000A,
            /// Intel USIF
            IntelUSIF = 0x000B,
            /// i.MX 6
            @"i.MX6" = 0x000C,
            /// (deprecated) Arm SBSA (2.x only) Generic UART supporting only 32-bit accesses
            ArmSBSA32bit = 0x000D,
            /// Arm SBSA Generic UART
            ArmSBSA = 0x000E,
            /// Arm DCC
            ArmDCC = 0x000F,
            /// BCM2835
            BCM2835 = 0x0010,
            /// SDM845 with clock rate of 1.8432 MHz
            SDM845_18432 = 0x0011,
            /// 16550-compatible with parameters defined in Generic Address Structure
            @"16550-GAS" = 0x0012,
            /// SDM845 with clock rate of 7.372 MHz
            SDM845_7372 = 0x0013,
            /// Intel LPSS
            IntelLPSS = 0x0014,
            /// RISC-V SBI console (any supported SBI mechanism)
            RISCVSBI = 0x0015,
        };

        comptime {
            core.testing.expectSize(@This(), @sizeOf(u16));
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

    comptime {
        core.testing.expectSize(@This(), 88);
    }
};

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = kernel.acpi;
