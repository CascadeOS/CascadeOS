// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const acpi.FADT,
        madt: *const acpi.MADT,
    ) void {
        if (boot.x2apicEnabled()) {
            lapic = .x2apic;
        } else {
            // FIXME: if this is changed to union initialization then zig panics
            //        assigning directly to the xapic field is safe as `lapic` is initialized to a dummy xapic value
            lapic.xapic = kernel.memory_layout.nonCachedDirectMapFromPhysical(
                core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address),
            ).toPtr([*]volatile u8);
        }

        log.debug("lapic detected: {}", .{lapic});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced", null);
        }
    }
};

/// Initialized in `init.captureApicInformation`.
var lapic: lib_x64.LAPIC = .{
    // FIXME: must be initialized with a dummy value to prevent a zig bug in `init.captureApicInformation`
    .xapic = @ptrFromInt(1),
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const log = kernel.log.scoped(.apic);
const arch = @import("arch");
const acpi = @import("acpi");
const boot = @import("boot");
