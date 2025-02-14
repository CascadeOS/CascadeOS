// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

// [IA-PC HPET Specification Link](https://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)

const globals = struct {
    var hpet: lib_x64.Hpet = undefined; // Initalized during `initializeHPET`

    /// The duration of a tick in femptoseconds.
    var tick_duration_fs: u64 = undefined; // Initalized during `initializeHPET`

    var number_of_timers_minus_one: u5 = undefined; // Initalized during `initializeHPET`
};

pub const init = struct {
    pub fn registerTimeSource(candidate_time_sources: *kernel.time.init.CandidateTimeSources) void {
        const acpi_table = kernel.acpi.getTable(kernel.acpi.tables.HPET, 0) orelse return;
        acpi_table.deinit();

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
        globals.hpet = .{ .base = getHpetBase() };
        init_log.debug("using hpet: {}", .{globals.hpet});

        const general_capabilities = globals.hpet.readGeneralCapabilitiesAndIDRegister();

        init_log.debug("counter is 64-bit: {}", .{general_capabilities.counter_is_64bit});

        globals.number_of_timers_minus_one = general_capabilities.number_of_timers_minus_one;

        globals.tick_duration_fs = general_capabilities.counter_tick_period_fs;
        init_log.debug("tick duration (fs): {}", .{globals.tick_duration_fs});

        var general_configuration = globals.hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        general_configuration.legacy_routing_enable = false;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);

        globals.hpet.writeCounterRegister(0);
    }

    fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
        _ = duration;

        var general_configuration = globals.hpet.readGeneralConfigurationRegister();
        general_configuration.enable = false;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);

        globals.hpet.writeCounterRegister(0);

        general_configuration.enable = true;
        globals.hpet.writeGeneralConfigurationRegister(general_configuration);
    }

    fn referenceCounterWaitFor(duration: core.Duration) void {
        const duration_ticks = ((duration.value * kernel.time.fs_per_ns) / globals.tick_duration_fs);

        const current_value = globals.hpet.readCounterRegister();

        const target_value = current_value + duration_ticks;

        while (globals.hpet.readCounterRegister() < target_value) {
            kernel.arch.spinLoopHint();
        }
    }

    fn getHpetBase() [*]volatile u64 {
        const acpi_table = kernel.acpi.getTable(kernel.acpi.tables.HPET, 0) orelse {
            // the table is known to exist as it is checked in `registerTimeSource`
            @panic("hpet table missing");
        };
        defer acpi_table.deinit();

        const hpet_table = acpi_table.table;

        if (hpet_table.base_address.address_space != .memory) @panic("HPET base address is not memory mapped");

        return kernel.vmm
            .nonCachedDirectMapFromPhysical(core.PhysicalAddress.fromInt(hpet_table.base_address.address))
            .toPtr([*]volatile u64);
    }

    const init_log = kernel.debug.log.scoped(.init_hpet);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
const Tick = kernel.time.wallclock.Tick;
