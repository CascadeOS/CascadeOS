// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

pub fn getFunction(address: Address) ?*PciFunction {
    for (globals.ecams) |ecam| {
        if (ecam.segment_group != address.segment) continue;
        if (ecam.start_bus < address.bus or address.bus >= ecam.end_bus) continue;

        const bus_offset = address.bus - ecam.start_bus;

        if (ecam.buses[bus_offset].devices[address.device].functions[address.function]) |*function| {
            return function;
        }

        return null;
    }

    return null;
}

pub const Address = extern struct {
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,

    pub fn print(id: Address, writer: std.io.AnyWriter, indent: usize) !void {
        _ = indent;

        try writer.print("Address({x:0>4}:{x:0>2}:{x:0>2}:{x:0>1})", .{
            id.segment,
            id.bus,
            id.device,
            id.function,
        });
    }

    pub inline fn format(
        id: Address,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            Address.print(id, writer, 0)
        else
            Address.print(id, writer.any(), 0);
    }
};

pub const ConfigurationSpace = extern struct {
    /// Identifies the manufacturer of the device.
    ///
    /// Where valid IDs are allocated by [PCI-SIG](https://pcisig.com/membership/member-companies) to ensure uniqueness
    /// and 0xFFFF is an invalid value that will be returned on read accesses to Configuration Space registers of
    /// non-existent devices.
    vendor_id: VendorID,

    /// Identifies the particular device.
    ///
    /// Where valid IDs are allocated by the vendor.
    device_id: DeviceID,

    /// Provides control over a device's ability to generate and respond to PCI cycles.
    ///
    /// Where the only functionality guaranteed to be supported by all devices is, when a `.zero` is written to this
    /// register, the device is disconnected from the PCI bus for all accesses except Configuration Space access.
    command: Command,

    /// A register used to record status information for PCI bus related events.
    status: Status,

    /// Specifies a revision identifier for a particular device.
    ///
    /// Where valid IDs are allocated by the vendor.
    revision_id: u8,

    /// Specifies a register-level programming interface the device has, if it has any at all.
    prog_if: u8,

    /// Specifies the specific function the device performs.
    subclass: u8,

    /// Specifies the type of function the device performs.
    class_code: u8,

    /// Specifies the system cache line size in 32-bit units.
    ///
    /// A device can limit the number of cacheline sizes it can support, if a unsupported value is written to this
    /// field, the device will behave as if a value of 0 was written.
    cache_line_size: u8,

    /// Specifies the latency timer in units of PCI bus clocks.
    latency_timer: u8,

    /// Identifies the layout of the rest of the header.
    ///
    /// If bit 7 of this register is set, the device has multiple functions; otherwise, it is a single function device
    header_type: HeaderTypeField,

    /// Represents that status and allows control of a devices BIST (built-in self test).
    bist: BIST,

    specific: extern union {
        generic: Generic,
        pci_to_pci_bridge: PciToPciBridge,
    },

    pub const Command = packed struct(u16) {
        /// If set to `true` the device can respond to I/O Space accesses; otherwise, the device's response is disabled.
        io_space: bool,
        /// If set to `true` the device can respond to Memory Space accesses; otherwise, the device's response is disabled.
        memory_space: bool,
        /// If set to `true` the device can behave as a bus master; otherwise, the device can not generate PCI accesses.
        bus_master: bool,
        /// If set to `true` the device can monitor Special Cycle operations; otherwise, the device will ignore them.
        special_cycles: bool,
        /// If set to `true` the device can generate the Memory Write and Invalidate command; otherwise, the Memory
        /// Write command must be used.
        memory_write_and_invalidate: bool,
        /// If set to `true` the device does not respond to palette register writes and will snoop the data; otherwise,
        /// the device will trate palette write accesses like all other accesses.
        vga_palette_snoop: bool,
        /// If set to `true` the device will take its normal action when a parity error is detected; otherwise, when an
        /// error is detected, the device will set bit 15 of the Status register (Detected Parity Error Status Bit), but
        /// will not assert the PERR# (Parity Error) pin and will continue operation as normal.
        parity_error_response: bool,
        /// As of revision 3.0 of the PCI local bus specification this bit is hardwired to 0.
        _reserved: u1,
        /// If set to `true` the SERR# driver is enabled; otherwise, the driver is disabled.
        serr_enable: bool,
        /// If set to `true` indicates a device is allowed to generate fast back-to-back transactions; otherwise, fast
        /// back-to-back transactions are only allowed to the same agent.
        fast_back_to_back: bool,
        /// If set to `true` the assertion of the devices INTx# signal is disabled; otherwise, assertion of the signal
        /// is enabled.
        interrupt_disable: bool,
        _reserved11_15: u5,

        pub const zero: Command = @bitCast(@as(u16, 0));
    };

    pub const Status = packed struct(u16) {
        _reserved0_2: u3,

        /// Represents the state of the device's INTx# signal.
        ///
        /// If set to `true` and bit 10 of the Command register (Interrupt Disable bit) is set to `false` the signal
        /// will be asserted; otherwise, the signal will be ignored.
        interrupt_status: bool,

        /// If set to `true` the device implements the pointer for a New Capabilities Linked list at offset 0x34;
        /// otherwise, the linked list is not available.
        capabilities_list: bool,

        /// If set to `true` the device is capable of running at 66 MHz; otherwise, the device runs at 33 MHz.
        @"66mhz_capable": bool,

        /// As of revision 3.0 of the PCI Local Bus specification this bit is reserved.
        _reserved6: u1,

        /// If set to `true` the device can accept fast back-to-back transactions that are not from the same agent;
        /// otherwise, transactions can only be accepted from the same agent.
        fast_back_to_back_capable: bool,

        /// This bit is set to `true` when the following conditions are met.
        ///
        /// The bus agent asserted PERR# on a read or observed an assertion of PERR# on a write, the agent setting the
        /// bit acted as the bus master for the operation in which the error occurred, and bit 6 of the Command register
        /// (Parity Error Response bit) is set to `true`.
        master_data_parity_error: bool,

        /// Read only bits that represent the slowest time that a device will assert DEVSEL# for any bus command except
        /// Configuration Space read and writes.
        ///
        /// Where a value of 0x0 represents fast timing, a value of 0x1 represents medium timing, and a value of 0x2
        /// represents slow timing.
        devsel_timing: u2,

        /// This bit will be set to `true` whenever a target device terminates a transaction with Target-Abort.
        signaled_target_abort: bool,

        /// This bit will be set to `true`, by a master device, whenever its transaction is terminated with Target-Abort.
        received_target_abort: bool,

        /// This bit will be set to `true`, by a master device, whenever its transaction (except for Special Cycle
        /// transactions) is terminated with Master-Abort.
        recieved_master_abort: bool,

        /// This bit will be set to `true` whenever the device asserts SERR#.
        signaled_system_error: bool,

        /// This bit will be set to `true` whenever the device detects a parity error, even if parity error handling is
        /// disabled.
        detected_parity_error: bool,
    };

    pub const HeaderTypeField = packed struct {
        header_type: HeaderType,

        multi_function: bool,

        pub const HeaderType = enum(u7) {
            general = 0x00,
            pci_to_pci_bridge = 0x01,

            _,
        };
    };

    pub const BIST = packed struct(u8) {
        /// Will return 0, after BIST execution, if the test completed successfully.
        completion_code: u4,

        _reserved4_5: u2,

        /// When set to `true` the BIST is invoked.
        ///
        /// This bit is reset when BIST completes.
        ///
        /// If BIST does not complete after 2 seconds the device should be failed by system software.
        start_bist: bool,

        /// Will return `true` the device supports BIST.
        bist_capable: bool,
    };

    pub const Generic = extern struct {
        bar0: u32,
        bar1: u32,
        bar2: u32,
        bar3: u32,
        bar4: u32,
        bar5: u32,

        /// Points to the Card Information Structure and is used by devices that share silicon between CardBus and PCI.
        cardbus_cis_pointer: u32,

        subsystem_vendor_id: u16,

        subsystem_id: u16,

        expansion_rom_base_address: u32,

        /// Points (i.e. an offset into this function's configuration space) to a linked list of new capabilities
        /// implemented by the device.
        ///
        /// Used if `Status.capabilities_list` is set to `true`.
        ///
        /// The bottom two bits are reserved and should be masked before the Pointer is used to access the Configuration
        /// Space.
        capabilities_pointer: u8,

        _reserved1: u8,
        _reserved2: u16,
        _reserved3: u32,

        /// Specifies which input of the system interrupt controllers the device's interrupt pin is connected to and is
        /// implemented by any device that makes use of an interrupt pin.
        ///
        /// For the x86 architecture this register corresponds to the PIC IRQ numbers 0-15 (and not I/O APIC IRQ
        /// numbers) and a value of 0xFF defines no connection.
        interrupt_line: u8,

        /// Specifies which interrupt pin the device uses.
        interrupt_pin: InterruptPin,

        /// A read-only register that specifies the burst period length, in 1/4 microsecond units, that the device
        /// needs (assuming a 33 MHz clock rate).
        min_grant: u8,

        /// A read-only register that specifies how often the device needs access to the PCI bus (in 1/4 microsecond
        /// units).
        max_latency: u8,

        pub const InterruptPin = enum(u8) {
            @"INTA#" = 0x1,
            @"INTB#" = 0x2,
            @"INTC#" = 0x3,
            @"INTD#" = 0x4,

            none = 0x0,
        };

        comptime {
            core.testing.expectSize(@This(), 0x30);
        }
    };

    pub const PciToPciBridge = extern struct {};

    comptime {
        core.testing.expectSize(@This(), 0x40);
    }
};

pub const VendorID = enum(u16) {
    none = 0xFFFF,

    _,

    pub fn print(id: VendorID, writer: std.io.AnyWriter, indent: usize) !void {
        // VendorID(id)

        _ = indent;

        try writer.writeAll("VendorID(0x");
        try std.fmt.formatInt(@intFromEnum(id), 16, .upper, .{}, writer);
        try writer.writeByte(')');
    }

    pub inline fn format(
        id: VendorID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            VendorID.print(id, writer, 0)
        else
            VendorID.print(id, writer.any(), 0);
    }
};

pub const DeviceID = enum(u16) {
    _,

    pub fn print(id: DeviceID, writer: std.io.AnyWriter, indent: usize) !void {
        // DeviceID(id)

        _ = indent;

        try writer.writeAll("DeviceID(0x");
        try std.fmt.formatInt(@intFromEnum(id), 16, .upper, .{}, writer);
        try writer.writeByte(')');
    }

    pub inline fn format(
        id: DeviceID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            DeviceID.print(id, writer, 0)
        else
            DeviceID.print(id, writer.any(), 0);
    }
};

// if this gets larger, we need to change the `PciDevice.functions` field to a pointer
pub const PciFunction = struct {
    function: u8,

    config_space_address: core.VirtualAddress,

    /// The PCI device this function belongs to.
    device: *PciDevice,
};

const PciDevice = struct {
    device: u8,

    config_space_address: core.VirtualAddress,

    functions: [FUNCTIONS_PER_DEVICE]?PciFunction, // make this a pointer if `PciFunction` gets larger

    /// The PCI bus this device belongs to.
    bus: *PciBus,
};

const PciBus = struct {
    bus: u8,

    config_space_address: core.VirtualAddress,

    devices: [DEVICES_PER_BUS]PciDevice,

    /// The ECAM this bus belongs to.
    ecam: *ECAM,
};

const ECAM = struct {
    ecam_number: u8,

    config_space_address: core.VirtualAddress,

    segment_group: u16,
    start_bus: u8,
    end_bus: u8,

    buses: []PciBus,
};

const globals = struct {
    var ecams: []ECAM = undefined;
};

pub const init = struct {
    pub fn initializeECAM() !void {
        init_log.debug("building PCI buses", .{});
        try initializeBuses();

        init_log.debug("scanning PCI buses for functions:", .{});
        for (globals.ecams) |ecam| {
            for (ecam.buses) |*bus| {
                for (&bus.devices) |*device| {
                    scanDevice(device, .{
                        .segment = ecam.segment_group,
                        .bus = bus.bus,
                        .device = device.device,
                        .function = 0,
                    });
                }
            }
        }
    }

    fn initializeBuses() !void {
        const acpi_table = kernel.acpi.getTable(acpi.MCFG, 0) orelse return error.MCFGNotPresent;
        defer acpi_table.deinit();
        const mcfg = acpi_table.table;

        const base_allocations = mcfg.baseAllocations();

        var ecams: std.ArrayList(ECAM) = try .initCapacity(kernel.heap.allocator, base_allocations.len);
        defer ecams.deinit();

        for (mcfg.baseAllocations(), 0..) |base_allocation, ecam_i| {
            const ecam = try ecams.addOne();
            ecam.* = .{
                .ecam_number = @intCast(ecam_i),
                .start_bus = base_allocation.start_pci_bus,
                .end_bus = base_allocation.end_pci_bus,
                .segment_group = base_allocation.segment_group,
                .config_space_address = kernel.vmm.nonCachedDirectMapFromPhysical(base_allocation.base_address),

                .buses = undefined, // set below
            };

            init_log.debug("found ECAM - segment group: {} - start bus: {} - end bus: {}", .{
                ecam.segment_group,
                ecam.start_bus,
                ecam.end_bus,
            });

            ecam.buses = try kernel.heap.allocator.alloc(PciBus, @as(usize, ecam.end_bus) - ecam.start_bus + 1);
            errdefer kernel.heap.allocator.free(ecam.buses);

            for (ecam.buses, 0..) |*bus, bus_i| {
                bus.* = .{
                    .bus = @intCast(ecam.start_bus + bus_i),
                    .config_space_address = ecam.config_space_address.moveForward(.from(bus_i << 20, .byte)),
                    .ecam = ecam,
                    .devices = undefined, // set below
                };

                for (&bus.devices, 0..) |*device, device_i| {
                    device.* = .{
                        .device = @intCast(device_i),
                        .config_space_address = bus.config_space_address.moveForward(.from(device_i << 15, .byte)),
                        .bus = bus,
                        .functions = @splat(null),
                    };
                }
            }
        }

        globals.ecams = try ecams.toOwnedSlice();
    }

    fn scanDevice(device: *PciDevice, address: Address) void {
        const function = address.function;

        const config_space_address = device.config_space_address.moveForward(
            .from(@as(usize, function) << 12, .byte),
        );

        const config_space = config_space_address.toPtr(*volatile ConfigurationSpace);

        if (config_space.vendor_id == .none) return;

        device.functions[function] = .{
            .function = @intCast(function),
            .config_space_address = config_space_address,
            .device = device,
        };

        init_log.debug("  {} - {} - {}", .{
            address,
            config_space.vendor_id,
            config_space.device_id,
        });

        if (function == 0 and config_space.header_type.multi_function) {
            for (1..FUNCTIONS_PER_DEVICE) |i| {
                var new_address = address;
                new_address.function = @intCast(i);
                scanDevice(device, new_address);
            }
        }

        if (config_space.header_type.header_type == .pci_to_pci_bridge) {
            init_log.warn("encountered PCI-to-PCI bridge - not implemented", .{});
        }
    }

    const init_log = kernel.debug.log.scoped(.init_pci);
};

const DEVICES_PER_BUS = 32;
const FUNCTIONS_PER_DEVICE = 8;

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const acpi = @import("acpi");
