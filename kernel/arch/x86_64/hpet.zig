// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const acpi = @import("acpi");

const log = kernel.debug.log.scoped(.hpet);

// Initalized during `initializeHPET`
var hpet: x86_64.Hpet = undefined;

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

// Initalized during `initializeHPET`
var number_of_timers_minus_one: u5 = undefined;

pub const init = struct {
    pub fn registerTimeSource() void {
        if (kernel.acpi.init.getTable(acpi.HPET) == null) return;

        kernel.time.init.addTimeSource(.{
            .name = "hpet",
            .priority = 100,
            .initialization = .{ .simple = initializeHPET },
            .reference_counter = .{
                .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
                .waitForFn = referenceCounterWaitFor,
            },
        });
    }

    fn initializeHPET() void {
        hpet = .{ .base = getHpetBase() };
        log.debug("using hpet: {}", .{hpet});

        const general_capabilities = hpet.readGeneralCapabilitiesAndIDRegister();

        if (general_capabilities.counter_is_64bit) {
            log.debug("counter is 64-bit", .{});
        } else {
            core.panic("HPET counter is not 64-bit");
        }

        number_of_timers_minus_one = general_capabilities.number_of_timers_minus_one;

        tick_duration_fs = general_capabilities.counter_tick_period_fs;
        log.debug("tick duration (fs): {}", .{tick_duration_fs});

        var general_configuration = hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        general_configuration.legacy_routing_enable = false;
        hpet.writeGeneralConfigurationRegister(general_configuration);

        hpet.writeCounterRegister(0);
    }

    fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
        _ = duration;

        var general_configuration = hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        hpet.writeGeneralConfigurationRegister(general_configuration);

        hpet.writeCounterRegister(0);

        general_configuration.enable = true;
        hpet.writeGeneralConfigurationRegister(general_configuration);
    }

    fn referenceCounterWaitFor(duration: core.Duration) void {
        const current_value = hpet.readCounterRegister();

        const target_value = current_value + ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

        while (hpet.readCounterRegister() < target_value) {
            kernel.arch.spinLoopHint();
        }
    }

    fn getHpetBase() [*]volatile u64 {
        const description_table = kernel.acpi.init.getTable(acpi.HPET) orelse unreachable;

        if (description_table.base_address.address_space != .memory) core.panic("HPET base address is not memory mapped");

        return kernel
            .nonCachedDirectMapFromPhysical(core.PhysicalAddress.fromInt(description_table.base_address.address))
            .toPtr([*]volatile u64);
    }
};
