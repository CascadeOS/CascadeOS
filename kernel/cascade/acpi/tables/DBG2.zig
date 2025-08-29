// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// [Microsoft Debug Port Table 2 (DBG2)](https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/bringup/acpi-debug-port-table.md)
pub const DBG2 = extern struct {
    header: acpi.tables.SharedHeader align(1),

    /// Offset, in bytes, from the beginning of this table to the first Debug Device Information structure entry.
    offset_of_debug_device_info: u32,

    /// Indicates the number of Debug Device Information structure entries.
    number_of_debug_device_info: u32,

    pub const SIGNATURE_STRING = "DBG2";

    pub fn debugDevices(dbg2: *const DBG2) DebugDeviceIterator {
        const base: [*]const u8 = @ptrCast(dbg2);
        return .{
            .current = @ptrCast(@alignCast(base + dbg2.offset_of_debug_device_info)),
            .index = 0,
            .count = dbg2.number_of_debug_device_info,
        };
    }

    pub const DebugDevice = extern struct {
        /// Revision of the Debug Device Information structure. For this version of the specification, this must be 0.
        revision: u8,

        /// Length, in bytes, of this structure, including NamespaceString and OEMData.
        length: u16 align(1),

        /// Number of generic address registers in use.
        number_of_generic_address_registers: u8,

        /// Length, in bytes, of NamespaceString, including NUL characters.
        namespace_string_length: u16,

        /// Offset, in bytes, from the beginning of this structure to the field NamespaceString[].
        ///
        /// This value must be valid because this string must be present.
        namespace_string_offset: u16,

        /// Length, in bytes, of the OEM data block.
        oem_data_length: u16,

        /// Offset, in bytes, to the field OemData[] from the beginning of this structure.
        ///
        /// This value will be 0 if no OEM data is present.
        oem_data_offset: u16,

        /// Debug port type for this debug device.
        port_type: PortType.Raw,

        /// Debug port subtype for this debug device.
        port_subtype: u16,

        _: u16,

        /// Offset, in bytes, from beginning of this structure to the field BaseaddressRegister[].
        base_address_register_offset: u16,

        /// Offset, in bytes, from beginning of this structure to the field AddressSize[].
        address_size_offset: u16,

        pub fn portType(debug_device: *align(1) const DebugDevice) PortType {
            return switch (debug_device.port_type) {
                .serial => .{ .serial = @enumFromInt(debug_device.port_subtype) },
                .@"1394" => .{ .@"1394" = @enumFromInt(debug_device.port_subtype) },
                .usb => .{ .usb = @enumFromInt(debug_device.port_subtype) },
                .net => .{ .net = @enumFromInt(debug_device.port_subtype) },
            };
        }

        /// NUL-terminated ASCII string to uniquely identify this device.
        ///
        /// This string consists of a fully qualified reference to the object that represents this device in the ACPI
        /// namespace.
        ///
        /// If no namespace device exists, NamespaceString[] must only contain a single '.' (ASCII period) character.
        pub fn namespaceString(debug_device: *align(1) const DebugDevice) [:0]const u8 {
            const ptr: [*]const u8 = @ptrCast(debug_device);
            return ptr[debug_device.namespace_string_offset..][0 .. debug_device.namespace_string_length - 1 :0];
        }

        /// Optional, variable-length OEM-specific data.
        pub fn oemData(debug_device: *align(1) const DebugDevice) ?[]const u8 {
            if (debug_device.oem_data_length == 0) return null;

            const ptr: [*]const u8 = @ptrCast(debug_device);
            return ptr[debug_device.oem_data_offset..][0..debug_device.oem_data_length];
        }

        pub fn addresses(debug_device: *align(1) const DebugDevice) AddressIterator {
            const base: [*]const u8 = @ptrCast(debug_device);
            const address_ptr: [*]align(1) const acpi.Address = @ptrCast(@alignCast(base + debug_device.base_address_register_offset));
            const address_size_ptr: [*]align(1) const u32 = @ptrCast(@alignCast(base + debug_device.address_size_offset));

            return .{
                .addresses = address_ptr[0..debug_device.number_of_generic_address_registers],
                .address_size = address_size_ptr[0..debug_device.number_of_generic_address_registers],
                .index = 0,
            };
        }

        pub const PortType = union(Raw) {
            serial: SerialSubType,
            @"1394": @"1394SubType",
            usb: UsbSubType,
            net: cascade.pci.VendorID,

            pub const Raw = enum(u16) {
                serial = 0x8000,
                @"1394" = 0x8001,
                usb = 0x8002,
                net = 0x8003,
            };

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

            pub const @"1394SubType" = enum(u16) {
                /// IEEE1394 Standard Host Controller Interface
                IEEE1394 = 0x0000,
            };

            pub const UsbSubType = enum(u16) {
                /// XHCI-compliant controller with debug interface
                XHCI = 0x0000,
                /// EHCI-compliant controller with debug interface
                EHCI = 0x0001,
            };

            pub fn format(port_type: PortType, writer: *std.Io.Writer) !void {
                switch (port_type) {
                    .serial => |subtype| try writer.print(
                        "PortType{{ serial: {t} }}",
                        .{subtype},
                    ),
                    .@"1394" => |subtype| try writer.print(
                        "PortType{{ 1394: {t} }}",
                        .{subtype},
                    ),
                    .usb => |subtype| try writer.print(
                        "PortType{{ usb: {t} }}",
                        .{subtype},
                    ),
                    .net => |vendor_id| try writer.print(
                        "{{ net: {f} }}",
                        .{vendor_id},
                    ),
                }
            }
        };

        pub const Address = struct {
            address: acpi.Address,
            size: u32,
        };

        pub const AddressIterator = struct {
            addresses: []align(1) const acpi.Address,
            address_size: []align(1) const u32,

            index: usize,

            pub fn next(address_iterator: *AddressIterator) ?Address {
                if (address_iterator.index >= address_iterator.addresses.len) return null;
                defer address_iterator.index += 1;

                return .{
                    .address = address_iterator.addresses[address_iterator.index],
                    .size = address_iterator.address_size[address_iterator.index],
                };
            }
        };

        pub fn print(debug_device: *align(1) const DebugDevice, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("DebugDevice{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("namespace_string: {s},\n", .{debug_device.namespaceString()});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("port_type: {},\n", .{debug_device.portType()});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(debug_device: *align(1) const DebugDevice, writer: *std.Io.Writer) !void {
            return debug_device.print(writer, 0);
        }

        comptime {
            core.testing.expectSize(DebugDevice, 22);
        }
    };

    pub const DebugDeviceIterator = struct {
        current: *align(1) const DebugDevice,
        index: usize,
        count: usize,

        pub fn next(debug_device_iterator: *DebugDeviceIterator) ?*align(1) const DebugDevice {
            if (debug_device_iterator.index >= debug_device_iterator.count) return null;

            debug_device_iterator.index += 1;

            const current = debug_device_iterator.current;

            const ptr: [*]const u8 = @ptrCast(current);
            debug_device_iterator.current = @ptrCast(@alignCast(ptr + current.length));

            return current;
        }
    };

    pub fn print(dbg2: *const DBG2, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("DBG2{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("offset_of_debug_device_info: {d},\n", .{dbg2.offset_of_debug_device_info});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("number_of_debug_device_info: {d},\n", .{dbg2.number_of_debug_device_info});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(dbg2: *const DBG2, writer: *std.Io.Writer) !void {
        return dbg2.print(writer, 0);
    }

    comptime {
        core.testing.expectSize(DBG2, 44);
    }

    pub const init = struct {
        pub fn tryGetSerialOutput() ?uart.Uart {
            const dbg2 = AcpiTable.get(0) orelse return null;
            defer dbg2.deinit();

            var devices: cascade.acpi.tables.DBG2.DebugDeviceIterator = dbg2.table.debugDevices();

            while (devices.next()) |device| {
                const address = blk: {
                    var addresses = device.addresses();
                    const first_address = addresses.next() orelse continue;
                    break :blk first_address.address;
                };

                switch (device.portType()) {
                    .serial => |subtype| switch (subtype) {
                        .@"16550", .@"16550-GAS" => {
                            switch (address.address_space) {
                                .memory => return .{
                                    .memory_16550 = (uart.Memory16550.create(
                                        cascade.mem.directMapFromPhysical(
                                            .fromInt(address.address),
                                        ).toPtr([*]volatile u8),
                                        null,
                                    ) catch unreachable) orelse continue,
                                },
                                .io => return .{
                                    .io_port_16550 = (uart.IoPort16550.create(
                                        @intCast(address.address),
                                        null,
                                    ) catch unreachable) orelse continue,
                                },
                                else => {},
                            }
                        },
                        .@"16450" => {
                            switch (address.address_space) {
                                .memory => return .{
                                    .memory_16450 = (uart.Memory16450.create(
                                        cascade.mem.directMapFromPhysical(
                                            .fromInt(address.address),
                                        ).toPtr([*]volatile u8),
                                        null,
                                    ) catch unreachable) orelse continue,
                                },
                                .io => return .{
                                    .io_port_16450 = (uart.IoPort16450.create(
                                        @intCast(address.address),
                                        null,
                                    ) catch unreachable) orelse continue,
                                },
                                else => {},
                            }
                        },
                        .ArmPL011 => {
                            std.debug.assert(address.address_space == .memory);
                            std.debug.assert(address.access_size == .dword);

                            return .{
                                .pl011 = (uart.PL011.create(
                                    cascade.mem.directMapFromPhysical(
                                        .fromInt(address.address),
                                    ).toPtr([*]volatile u32),
                                    null,
                                ) catch unreachable) orelse continue,
                            };
                        },
                        else => {}, // TODO: implement other serial subtypes
                    },
                    else => {}, // TODO: implement other port types
                }
            }

            return null;
        }

        const AcpiTable = cascade.exports.acpi.AcpiTable(cascade.acpi.tables.DBG2);
        const uart = @import("init").Output.uart;
        const log = cascade.debug.log.scoped(.init_output);
    };
};

const cascade = @import("cascade");

const acpi = cascade.acpi;
const core = @import("core");
const std = @import("std");
