// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)

pub const init = struct {
    pub fn registerTimeSource(candidate_time_sources: *init_time.CandidateTimeSources) void {
        if (kernel.acpi.getTable(acpi.HPET, 0) == null) return;

        candidate_time_sources.addTimeSource(.{
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
            core.panic("HPET counter is not 64-bit", null);
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
        const duration_ticks = ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

        const current_value = hpet.readCounterRegister();

        const target_value = current_value + duration_ticks;

        while (hpet.readCounterRegister() < target_value) {
            arch.spinLoopHint();
        }
    }

    fn getHpetBase() [*]volatile u64 {
        const description_table = kernel.acpi.getTable(acpi.HPET, 0) orelse {
            // the table is known to exist as it is checked in `registerTimeSource`
            core.panic("hpet table missing", null);
        };

        if (description_table.base_address.address_space != .memory) core.panic("HPET base address is not memory mapped", null);

        return kernel.memory_layout
            .nonCachedDirectMapFromPhysical(core.PhysicalAddress.fromInt(description_table.base_address.address))
            .toPtr([*]volatile u64);
    }
};

var hpet: lib_x64.Hpet = undefined; // Initalized during `initializeHPET`

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

var number_of_timers_minus_one: u5 = undefined; // Initalized during `initializeHPET`

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const log = kernel.log.scoped(.hpet);
const init_time = @import("init").time;
const Tick = kernel.time.wallclock.Tick;
const arch = @import("arch");
const acpi = @import("acpi");
