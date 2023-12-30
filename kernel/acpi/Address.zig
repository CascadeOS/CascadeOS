// SPDX-License-Identifier: MIT

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

pub const Address = extern struct {
    /// The address space where the data structure or register exists.
    address_space_id: AddressSpace,

    /// The size in bits of the given register.
    register_bit_width: u8,

    /// The bit offset of the given register at the given address
    register_bit_offset: u8,

    /// Specifies access size.
    ///
    /// Unless otherwise defined by the Address Space ID.
    access_size: AccessSize,

    address: u64 align(4),

    pub const AddressSpace = enum(u8) {
        /// The 64-bit physical memory address (relative to the processor) of the register.
        ///
        /// 32-bit plat-forms must have the high DWORD set to 0.
        memory = 0x0,

        /// The 64-bit I/O address (relative to the processor) of the register.
        ///
        /// 32-bit platforms must have the high DWORD set to 0
        io = 0x1,

        /// PCI Configuration space addresses must be confined to devices on PCI Segment Group 0, bus 0.
        /// This restriction exists to accommodate access to fixed hardware prior to PCI bus enumeration.
        ///
        /// The format of addresses are defined as follows:
        ///
        /// Word Location Description
        ///
        /// Highest Word Reserved (must be 0)
        ///
        /// — PCI Device number on bus 0
        ///
        /// — PCI Function number
        ///
        /// Longest Word Offset in the configuration space header
        ///
        /// For example: Offset 23h of Function 2 on device 7 on bus 0 segment 0 would be represented as: 0x0000000700020023.
        pci = 0x2,

        embedded_controller = 0x3,
        smbus = 0x4,
        cmos = 0x5,

        /// PciBarTarget is used to locate a MMIO register on a PCI device BAR space.
        ///
        /// PCI Configuration space addresses must be confined to devices on a host bus, i.e any bus returned by a _BBN object.
        /// This restriction exists to accommodate access to fixed hardware prior to PCI bus enumeration.
        ///
        /// The format of the Address field for this type of address is:
        ///  - Bits [63:56] – PCI Segment
        ///  - Bits [55:48] – PCI Bus
        ///  - Bits [47:43] – PCI Device
        ///  - Bits [42:40] – PCI Function
        ///  - Bits [39:37] – BAR index#
        ///  - Bits [36:0] – Offset from BAR in DWORDs
        pcibar = 0x6,

        ipmi = 0x7,
        general_purpose_io = 0x8,
        generic_serial_bus = 0x9,
        platform_communications_channel = 0xA,
        platform_runtime_mechanism = 0xB,

        /// Use of GAS fields other than Address_Space_ID is specified by the CPU manufacturer.
        ///
        /// The use of functional fixed hardware carries with it a reliance on OS specific software that must be considered.
        ///
        /// OEMs should consult OS vendors to ensure that specific functional fixed hardware interfaces are supported by specific operating systems.
        functional_fixed_hardware = 0x7F,

        _,
    };

    pub const AccessSize = enum(u8) {
        undefined = 0,
        byte = 1,
        word = 2,
        dword = 3,
        qword = 4,
    };

    comptime {
        core.testing.expectSize(@This(), @sizeOf(u64) + @sizeOf(u8) * 4);
    }
};