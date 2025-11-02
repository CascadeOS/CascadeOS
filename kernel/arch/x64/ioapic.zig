// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

pub fn routeInterrupt(
    interrupt: u8,
    vector: x64.interrupts.Interrupt,
) arch.interrupts.Interrupt.RouteError!void {
    const mapping = getMapping(interrupt);
    const ioapic = getIOAPIC(mapping.gsi) catch return error.UnableToRouteExternalInterrupt;

    ioapic.setRedirectionTableEntry(
        @intCast(mapping.gsi - ioapic.gsi_base),
        vector,
        .fixed,
        .{ .physical = 0 }, // TODO: support routing to other/multiple processors
        mapping.polarity,
        mapping.trigger_mode,
        false,
    ) catch |err| {
        // TODO: return error
        std.debug.panic("failed to route interrupt {}: {t}", .{ interrupt, err });
    };
}

fn getMapping(interrupt: u8) SourceOverride {
    return globals.source_overrides[interrupt] orelse .{
        .gsi = interrupt,
        .polarity = .active_high,
        .trigger_mode = .edge,
    };
}

fn getIOAPIC(gsi: u32) !IOAPIC {
    for (globals.io_apics.constSlice()) |io_apic| {
        if (gsi >= io_apic.gsi_base and gsi < (io_apic.gsi_base + io_apic.number_of_redirection_entries)) {
            return io_apic;
        }
    }
    return error.NoIOAPICForGSI;
}

const SourceOverride = struct {
    gsi: u32,
    polarity: IOAPIC.Polarity,
    trigger_mode: IOAPIC.TriggerMode,

    fn fromMADT(source_override: cascade.acpi.tables.MADT.InterruptControllerEntry.InterruptSourceOverride) SourceOverride {
        const polarity: IOAPIC.Polarity = switch (source_override.flags.polarity) {
            .conforms => .active_high,
            .active_high => .active_high,
            .active_low => .active_low,
            else => std.debug.panic(
                "unsupported polarity: {}",
                .{source_override.flags.polarity},
            ),
        };

        const trigger_mode: IOAPIC.TriggerMode = switch (source_override.flags.trigger_mode) {
            .conforms => .edge,
            .edge_triggered => .edge,
            .level_triggered => .level,
            else => std.debug.panic(
                "unsupported trigger mode: {}",
                .{source_override.flags.trigger_mode},
            ),
        };

        return .{
            .gsi = source_override.global_system_interrupt,
            .polarity = polarity,
            .trigger_mode = trigger_mode,
        };
    }

    pub inline fn format(
        id: SourceOverride,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("SourceOverride{{ .gsi = {d}, .polarity = {t}, .trigger_mode = {t} }}", .{
            id.gsi,
            id.polarity,
            id.trigger_mode,
        });
    }
};

const globals = struct {
    var io_apics: core.containers.BoundedArray(IOAPIC, x64.config.maximum_number_of_io_apics) = .{};
    var source_overrides: [x64.paging.PageTable.number_of_entries]?SourceOverride = @splat(null);
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.ioapic_init);

    pub fn captureMADTInformation(current_task: *Task, madt: *const cascade.acpi.tables.MADT) !void {
        var iter = madt.iterate();

        while (iter.next()) |entry| {
            switch (entry.entry_type) {
                .io_apic => {
                    const io_apic_data = entry.specific.io_apic;

                    const address = cascade.mem.nonCachedDirectMapFromPhysical(.fromInt(io_apic_data.ioapic_address));
                    const ioapic = IOAPIC.init(address, io_apic_data.global_system_interrupt_base);

                    init_log.debug(current_task, "found ioapic for gsi {}-{}", .{
                        ioapic.gsi_base,
                        ioapic.gsi_base + ioapic.number_of_redirection_entries,
                    });

                    try globals.io_apics.append(ioapic);
                },
                .interrupt_source_override => {
                    const madt_iso = entry.specific.interrupt_source_override;
                    const source_override: SourceOverride = .fromMADT(madt_iso);
                    globals.source_overrides[madt_iso.source] = source_override;
                    init_log.debug(current_task, "found irq {} has {f}", .{ madt_iso.source, source_override });
                },
                else => continue,
            }
        }

        // sort the io apics by gsi base
        std.mem.sort(
            IOAPIC,
            globals.io_apics.slice(),
            {},
            struct {
                fn lessThan(_: void, lhs: IOAPIC, rhs: IOAPIC) bool {
                    return lhs.gsi_base < rhs.gsi_base;
                }
            }.lessThan,
        );
    }
};

const IOAPIC = struct {
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

    pub fn apicId(ioapic: IOAPIC) u4 {
        const register: IdentificationRegister = .read(ioapic);
        return register.ioapic_id;
    }

    pub const RedirectionTableError = error{
        InvalidIndex,
    };

    pub fn setRedirectionTableEntry(
        ioapic: IOAPIC,
        index: u8,
        interrupt_vector: x64.interrupts.Interrupt,
        delivery_mode: DeliveryMode,
        destination: Destination,
        pin_polarity: Polarity,
        trigger_mode: TriggerMode,
        mask: bool,
    ) RedirectionTableError!void {
        if (index >= ioapic.number_of_redirection_entries) return error.InvalidIndex;

        var register: RedirectionTableRegister = .read(ioapic, index);

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

        register.write(ioapic, index);
    }

    pub fn setRedirectionEntryMask(
        ioapic: IOAPIC,
        index: u8,
        mask: bool,
    ) RedirectionTableError!void {
        if (index >= ioapic.number_of_redirection_entries) return error.InvalidIndex;

        var register: RedirectionTableRegister = .read(ioapic, index);
        register.mask = mask;
        register.write(ioapic, index);
    }

    const RedirectionTableRegister = packed struct(u64) {
        interrupt_vector: x64.interrupts.Interrupt,
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

        fn write(redirection_table_register: RedirectionTableRegister, ioapic: IOAPIC, index: u8) void {
            const offset = base_register_offset + (index * 2);

            const value: u64 = @bitCast(redirection_table_register);

            ioapic.writeRegister(offset, @truncate(value));
            ioapic.writeRegister(offset + 1, @truncate(value >> 32));
        }

        const DestinationMode = enum(u1) {
            physical = 0,
            logical = 1,
        };

        const DeliveryStatus = x64.apic.LAPIC.DeliveryStatus;
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

    pub const TriggerMode = x64.apic.LAPIC.TriggerMode;
    pub const DeliveryMode = x64.apic.LAPIC.DeliveryMode;

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
};
