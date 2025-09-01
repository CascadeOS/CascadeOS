// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub fn initializeECAM(context: *cascade.Context) !void {
    const acpi_table = AcpiTable.get(0) orelse return error.MCFGNotPresent;
    defer acpi_table.deinit();
    const mcfg = acpi_table.table;

    const base_allocations = mcfg.baseAllocations();

    var ecams: std.ArrayList(cascade.pci.ECAM) = try .initCapacity(cascade.mem.heap.allocator, base_allocations.len);
    defer ecams.deinit(cascade.mem.heap.allocator);

    for (mcfg.baseAllocations()) |base_allocation| {
        const ecam = ecams.addOneAssumeCapacity();
        ecam.* = .{
            .start_bus = base_allocation.start_pci_bus,
            .end_bus = base_allocation.end_pci_bus,
            .segment_group = base_allocation.segment_group,
            .config_space_address = cascade.mem.nonCachedDirectMapFromPhysical(base_allocation.base_address),
        };

        log.debug(context, "found ECAM - segment group: {} - start bus: {} - end bus: {} @ {f}", .{
            ecam.segment_group,
            ecam.start_bus,
            ecam.end_bus,
            base_allocation.base_address,
        });
    }

    cascade.pci.init.setECAMs(try ecams.toOwnedSlice(cascade.mem.heap.allocator));
}

const AcpiTable = init.acpi.AcpiTable(cascade.acpi.tables.MCFG);

const arch = @import("arch");
const cascade = @import("cascade");
const init = @import("init");

const core = @import("core");
const log = cascade.debug.log.scoped(.init_pci);
const std = @import("std");
