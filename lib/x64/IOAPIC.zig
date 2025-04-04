// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const IOAPIC = @This();

ioregsel: *volatile u8,
iowin: *volatile u32,

/// The global system interrupt number where this I/O APIC's interrupt inputs start.
gsi_base: u32,

number_of_redirection_entries: u8,

pub fn init(base_address: core.VirtualAddress, gsi_base: u32) IOAPIC {
    var ioapic: IOAPIC = .{
        .ioregsel = base_address.toPtr(*volatile u8),
        .iowin = base_address.moveForward(.from(0x10, .byte)).toPtr(*volatile u32),
        .gsi_base = gsi_base,
        .number_of_redirection_entries = undefined,
    };

    const version: VersionRegister = .read(ioapic);
    ioapic.number_of_redirection_entries = version.max_redirection_entry + 1;

    return ioapic;
}

pub fn apicId(self: IOAPIC) u4 {
    const register: IdentificationRegister = .read(self);
    return register.ioapic_id;
}

pub const RedirectionTableError = error{
    InvalidIndex,
};

pub fn setRedirectionTableEntry(
    self: IOAPIC,
    index: u8,
    interrupt_vector: x64.InterruptVector,
    delivery_mode: DeliveryMode,
    destination: Destination,
    pin_polarity: Polarity,
    trigger_mode: TriggerMode,
    mask: bool,
) RedirectionTableError!void {
    if (index >= self.number_of_redirection_entries) return error.InvalidIndex;

    var register: RedirectionTableRegister = .read(self, index);

    register.interrupt_vector = interrupt_vector;
    register.delivery_mode = delivery_mode;
    switch (destination) {
        .physical => |physical| {
            register.destination_mode = .physical;
            register.destination = physical;
        },
        .logical => |logical| {
            register.destination_mode = .logical;
            register.destination = logical;
        },
    }
    register.pin_polarity = pin_polarity;
    register.trigger_mode = trigger_mode;
    register.mask = mask;

    register.write(self, index);
}

pub fn setRedirectionEntryMask(
    self: IOAPIC,
    index: u8,
    mask: bool,
) RedirectionTableError!void {
    if (index >= self.number_of_redirection_entries) return error.InvalidIndex;

    var register: RedirectionTableRegister = .read(self, index);
    register.mask = mask;
    register.write(self, index);
}

const RedirectionTableRegister = packed struct(u64) {
    interrupt_vector: x64.InterruptVector,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: DeliveryStatus,
    pin_polarity: Polarity,
    remote_irr: u1,
    trigger_mode: TriggerMode,
    mask: bool,
    _reserved17_55: u39,
    destination: u8,

    const base_register_offset: u8 = 0x10;

    fn read(ioapic: IOAPIC, index: u8) RedirectionTableRegister {
        const offset = base_register_offset + (index * 2);

        const backing: u64 = ioapic.readRegister(offset) |
            @as(u64, ioapic.readRegister(offset + 1)) << 32;

        return @bitCast(backing);
    }

    fn write(self: RedirectionTableRegister, ioapic: IOAPIC, index: u8) void {
        const offset = base_register_offset + (index * 2);

        const value: u64 = @bitCast(self);

        ioapic.writeRegister(offset, @truncate(value));
        ioapic.writeRegister(offset + 1, @truncate(value >> 32));
    }

    const DestinationMode = enum(u1) {
        physical = 0,
        logical = 1,
    };

    const DeliveryStatus = x64.LAPIC.DeliveryStatus;
};

pub const Destination = union(enum) {
    /// ACPI ID of the destination processor.
    physical: u4,

    /// Set of destination processors.
    logical: u8,
};

pub const Polarity = enum(u1) {
    active_high = 0,
    active_low = 1,
};

pub const TriggerMode = x64.LAPIC.TriggerMode;
pub const DeliveryMode = x64.LAPIC.DeliveryMode;

/// IOAPICID - IOAPIC IDENTIFICATION REGISTER
///
/// This register contains the 4-bit APIC ID.
///
/// The ID serves as a physical name of the IOAPIC. All APIC devices using the APIC bus should have a unique APIC
/// ID. The APIC bus arbitration ID for the I/O unit is also writtten during a write to the APICID Register
/// (same data is loaded into both). This register must be programmed with the correct ID value before using the
/// IOAPIC for message transmission.
const IdentificationRegister = packed struct(u32) {
    _reserved0_23: u24,

    ioapic_id: u4,

    _reserved28_31: u4,

    pub fn read(ioapic: IOAPIC) IdentificationRegister {
        return @bitCast(ioapic.readRegister(0));
    }
};

/// IOAPICVER - IOAPIC VERSION REGISTER
///
/// The IOAPIC Version Register identifies the APIC hardware version.
///
/// Software can use this to provide compatibility between different APIC implementations and their versions.
/// In addition, this register provides the maximum number of entries in the I/O Redirection Table.
const VersionRegister = packed struct(u32) {
    /// The IOAPIC version.
    version: u8,

    _reserved8_15: u8,

    /// The number of I/O redirection table entries minus 1.
    max_redirection_entry: u8,

    _reserved24_31: u8,

    pub fn read(ioapic: IOAPIC) VersionRegister {
        return @bitCast(ioapic.readRegister(1));
    }
};

inline fn readRegister(ioapic: IOAPIC, offset: u8) u32 {
    ioapic.ioregsel.* = offset;
    return ioapic.iowin.*;
}

inline fn writeRegister(ioapic: IOAPIC, offset: u8, value: u32) void {
    ioapic.ioregsel.* = offset;
    ioapic.iowin.* = value;
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const core = @import("core");

const x64 = @import("x64");
