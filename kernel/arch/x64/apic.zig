// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const acpi = @import("acpi");
const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.apic);

/// Initialized in `init.captureApicInformation`.
var lapic: x64.LAPIC = .{
    .xapic = @ptrFromInt(1), // FIXME: initialized with a dummy value to prevent a zig bug in `init.captureApicInformation`
};

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const acpi.FADT,
        madt: *const acpi.MADT,
    ) void {
        if (kernel.boot.x2apicEnabled()) {
            lapic = .x2apic;
        } else {
            // TODO: non cached direct map
            lapic.xapic = kernel.vmm
                .directMapFromPhysical(core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address))
                .toPtr([*]volatile u8);
        }

        log.debug("lapic detected: {}", .{lapic});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced");
        }
    }
};
