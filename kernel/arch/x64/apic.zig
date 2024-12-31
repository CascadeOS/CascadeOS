// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const globals = struct {
    /// Initialized in `init.captureApicInformation`.
    var lapic: lib_x64.LAPIC = .{
        // FIXME: must be initialized to the `xapic` variant to prevent a zig bug in `init.captureApicInformation`
        .xapic = undefined,
    };
};

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const acpi.FADT,
        madt: *const acpi.MADT,
        x2apic_enabled: bool,
    ) void {
        if (x2apic_enabled) {
            globals.lapic = .x2apic;
        } else {
            // FIXME: if this is changed to union initialization then zig panics
            //        assigning directly to the xapic field is safe as `lapic` is initialized to a dummy xapic value
            globals.lapic.xapic = kernel.vmm.nonCachedDirectMapFromPhysical(
                core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address),
            ).toPtr([*]volatile u8);
        }

        init_log.debug("lapic in mode: {s}", .{@tagName(globals.lapic)});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced", null);
        }
    }

    const init_log = kernel.debug.log.scoped(.init_x64_apic);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const acpi = @import("acpi");
