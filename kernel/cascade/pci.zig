// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

/// Returns a `Function` representing the PCI function at 'address'.
pub fn getFunction(address: Address) ?*Function {
    for (globals.ecams) |ecam| {
        if (ecam.segment_group != address.segment) continue;
        if (ecam.start_bus < address.bus or address.bus >= ecam.end_bus) continue;

        const bus_offset: usize = address.bus - ecam.start_bus;

        const config_space_offset: usize = bus_offset << 20 |
            @as(usize, address.device) << 15 |
            @as(usize, address.function) << 12;

        std.debug.assert(ecam.config_space.size.value >= config_space_offset + @sizeOf(Function));

        return ecam.config_space.address
            .moveForward(.from(config_space_offset, .byte))
            .toPtr(*Function);
    }

    return null;
}

pub const Address = extern struct {
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,

    pub inline fn format(
        id: Address,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("Address({x:0>4}:{x:0>2}:{x:0>2}:{x:0>1})", .{
            id.segment,
            id.bus,
            id.device,
            id.function,
        });
    }
};

pub const VendorID = enum(u16) {
    none = 0xFFFF,

    _,

    pub inline fn format(id: VendorID, writer: *std.Io.Writer) !void {
        return try writer.print("VendorID(0x{x:0>4})", .{@intFromEnum(id)});
    }
};

pub const DeviceID = enum(u16) {
    _,

    pub inline fn format(id: DeviceID, writer: *std.Io.Writer) !void {
        try writer.print("DeviceID(0x{x:0>4})", .{@intFromEnum(id)});
    }
};

pub const Function = extern struct {
    full_configuration_space: [enhanced_configuration_space_size.value]u8 align(enhanced_configuration_space_size.value),

    pub const enhanced_configuration_space_size: core.Size = .from(4096, .byte);

    pub inline fn read(function: *const Function, comptime T: type, offset: usize) T {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return arch.io.readPci(
            T,
            cascade.KernelVirtualAddress.fromPtr(function).moveForward(size_offset),
        );
    }

    pub inline fn write(function: *Function, comptime T: type, offset: usize, value: T) void {
        const size_offset: core.Size = .from(offset, .byte);

        if (core.is_debug) {
            std.debug.assert(size_offset.aligned(.of(T)));
            std.debug.assert(enhanced_configuration_space_size.greaterThanOrEqual(size_offset.add(.of(T))));
        }

        return arch.io.writePci(
            T,
            cascade.KernelVirtualAddress.fromPtr(function).moveForward(size_offset),
            value,
        );
    }

    comptime {
        core.testing.expectSize(Function, enhanced_configuration_space_size);
    }
};

pub const ECAM = struct {
    segment_group: u16,
    start_bus: u8,
    end_bus: u8,
    config_space: cascade.KernelVirtualRange,
};

const DEVICES_PER_BUS = 32;
const FUNCTIONS_PER_DEVICE = 8;

const globals = struct {
    /// All ECAMs in the system.
    ///
    /// Set by `init.initializeECAM`.
    var ecams: []ECAM = &.{};
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.pci_init);
    const MCFGAcpiTable = cascade.acpi.init.AcpiTable(cascade.acpi.tables.MCFG);

    /// Initializes the PCI ECAM.
    ///
    /// No-op if no MCFG table is found.
    pub fn initializeECAM() !void {
        const mcfg_acpi_table = MCFGAcpiTable.get(0) orelse {
            init_log.warn("no MCFG table found - skipping PCI ECAM initialization", .{});
            return;
        };
        defer mcfg_acpi_table.deinit();
        const mcfg = mcfg_acpi_table.table;

        const base_allocations = mcfg.baseAllocations();

        var ecams: std.ArrayList(ECAM) = try .initCapacity(cascade.mem.heap.allocator, base_allocations.len);
        defer ecams.deinit(cascade.mem.heap.allocator);
        errdefer for (ecams.items) |ecam| cascade.mem.heap.deallocateSpecial(ecam.config_space);

        for (mcfg.baseAllocations()) |base_allocation| {
            const ecam = ecams.addOneAssumeCapacity();

            const number_of_buses = base_allocation.end_pci_bus - base_allocation.start_pci_bus;

            const ecam_config_space_physical_range: cascade.PhysicalRange = .from(
                base_allocation.base_address,
                Function.enhanced_configuration_space_size
                    .multiplyScalar(FUNCTIONS_PER_DEVICE)
                    .multiplyScalar(DEVICES_PER_BUS)
                    .multiplyScalar(number_of_buses),
            );

            ecam.* = .{
                .start_bus = base_allocation.start_pci_bus,
                .end_bus = base_allocation.end_pci_bus,
                .segment_group = base_allocation.segment_group,
                .config_space = try cascade.mem.heap.allocateSpecial(
                    .{
                        .physical_range = ecam_config_space_physical_range,
                        .protection = .{ .read = true, .write = true },
                        .cache = .uncached,
                    },
                ),
            };

            init_log.debug("found ECAM - segment group: {} - start bus: {} - end bus: {} @ {f}", .{
                ecam.segment_group,
                ecam.start_bus,
                ecam.end_bus,
                ecam_config_space_physical_range,
            });
        }

        globals.ecams = try ecams.toOwnedSlice(cascade.mem.heap.allocator);
    }
};
