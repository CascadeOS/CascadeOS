// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Signal end of interrupt.
pub inline fn eoi() void {
    globals.lapic.eoi();
}

/// Send a panic IPI to all other executors.
pub fn sendPanicIPI() void {
    var icr = globals.lapic.readInterruptCommandRegister();

    icr = .{
        .vector = .non_maskable_interrupt,
        .delivery_mode = .nmi,
        .destination_mode = .physical,
        .level = .assert,
        .trigger_mode = .edge,
        .destination_shorthand = .all_excluding_self,
        .destination_field = .{ .x2apic = 0 },
    };

    globals.lapic.writeInterruptCommandRegister(icr);
}

/// Send a flush IPI to the given executor.
pub fn sendFlushIPI(executor: *kernel.Executor) void {
    var icr = globals.lapic.readInterruptCommandRegister();

    icr = .{
        .vector = x64.interrupts.Interrupt.flush_request.toInterruptVector(),
        .delivery_mode = .fixed,
        .destination_mode = .physical,
        .level = .assert,
        .trigger_mode = .edge,
        .destination_shorthand = .no_shorthand,
        .destination_field = undefined, // set below
    };

    switch (globals.lapic) {
        .xapic => icr.destination_field = .{ .xapic = .{
            .destination = @intCast(executor.arch.apic_id),
        } },
        .x2apic => icr.destination_field = .{ .x2apic = executor.arch.apic_id },
    }

    globals.lapic.writeInterruptCommandRegister(icr);
}

const globals = struct {
    /// Initialized in `init.captureApicInformation`.
    var lapic: lib_x64.LAPIC = .{
        // FIXME: must be initialized to the `xapic` variant to prevent a zig bug in `init.captureApicInformation`
        .xapic = undefined,
    };

    /// The duration of a tick in femptoseconds.
    ///
    /// Initalized in `init.initializeLapicTimer[Calibrate]`
    var tick_duration_fs: u64 = undefined;
};

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const kernel.acpi.tables.FADT,
        madt: *const kernel.acpi.tables.MADT,
        x2apic_enabled: bool,
    ) void {
        if (x2apic_enabled) {
            globals.lapic = .x2apic;
        } else {
            // FIXME: if this is changed to union initialization then zig panics
            //        assigning directly to the xapic field is safe as `lapic` is initialized to a dummy xapic value
            globals.lapic.xapic = kernel.mem.nonCachedDirectMapFromPhysical(
                core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address),
            ).toPtr([*]volatile u8);
        }

        init_log.debug("lapic in mode: {s}", .{@tagName(globals.lapic)});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            @panic("physical destination mode is forced");
        }
    }

    pub fn initApicOnCurrentExecutor() void {
        globals.lapic.writeSupriousInterruptRegister(.{
            .apic_enable = true,
            .spurious_vector = x64.interrupts.Interrupt.spurious_interrupt.toInterruptVector(),
        });

        // TODO: task priority
        // TODO: error interrupt
    }

    pub fn registerTimeSource(candidate_time_sources: *kernel.time.init.CandidateTimeSources) void {
        candidate_time_sources.addTimeSource(.{
            .name = "lapic",
            .priority = 150,
            .initialization = if (x64.info.lapic_base_tick_duration_fs != null)
                .{ .simple = initializeLapicTimer }
            else
                .{ .calibration_required = initializeLapicTimerCalibrate },
            .per_executor_periodic = .{
                .enableInterruptFn = perExecutorPeriodicEnableInterrupt,
            },
        });
    }

    const divide_configuration: lib_x64.LAPIC.DivideConfigurationRegister = .@"2";

    fn initializeLapicTimer() void {
        std.debug.assert(x64.info.lapic_base_tick_duration_fs != null);

        globals.tick_duration_fs = x64.info.lapic_base_tick_duration_fs.? * divide_configuration.toInt();
        init_log.debug("tick duration (fs) from cpuid: {}", .{globals.tick_duration_fs});
    }

    fn initializeLapicTimerCalibrate(
        reference_counter: kernel.time.init.ReferenceCounter,
    ) void {
        globals.lapic.writeDivideConfigurationRegister(divide_configuration);

        globals.lapic.writeLVTTimerRegister(.{
            .vector = .debug, // interrupt is masked so it doesnt matter what the vector is set to
            .timer_mode = .oneshot,
            .masked = true,
        });

        // warmup
        {
            const warmup_duration = core.Duration.from(1, .millisecond);
            const number_of_warmups = 5;

            var total_warmup_ticks: u64 = 0;

            for (0..number_of_warmups) |_| {
                reference_counter.prepareToWaitFor(warmup_duration);

                globals.lapic.writeInitialCountRegister(std.math.maxInt(u32));
                reference_counter.waitFor(warmup_duration);
                const end = globals.lapic.readCurrentCountRegister();
                globals.lapic.writeInitialCountRegister(0);

                total_warmup_ticks += std.math.maxInt(u32) - end;
            }

            std.mem.doNotOptimizeAway(&total_warmup_ticks);
        }

        const sample_duration = core.Duration.from(5, .millisecond);
        const number_of_samples = 5;
        var total_ticks: u64 = 0;

        for (0..number_of_samples) |_| {
            reference_counter.prepareToWaitFor(sample_duration);

            globals.lapic.writeInitialCountRegister(std.math.maxInt(u32));
            reference_counter.waitFor(sample_duration);
            const end = globals.lapic.readCurrentCountRegister();
            globals.lapic.writeInitialCountRegister(0);

            total_ticks += std.math.maxInt(u32) - end;
        }

        const average_ticks = total_ticks / number_of_samples;

        globals.tick_duration_fs = (sample_duration.value * kernel.time.fs_per_ns) / average_ticks;
        init_log.debug("tick duration (fs) using reference counter: {}", .{globals.tick_duration_fs});
    }

    fn perExecutorPeriodicEnableInterrupt(period: core.Duration) void {
        globals.lapic.writeInitialCountRegister(0);
        globals.lapic.writeDivideConfigurationRegister(divide_configuration);

        globals.lapic.writeLVTTimerRegister(.{
            .vector = x64.interrupts.Interrupt.per_executor_periodic.toInterruptVector(),
            .timer_mode = .periodic,
            .masked = false,
        });

        const ticks = std.math.cast(
            u32,
            (period.value * kernel.time.fs_per_ns) / globals.tick_duration_fs,
        ) orelse @panic("period is too long");

        globals.lapic.writeInitialCountRegister(ticks);
    }

    const init_log = kernel.debug.log.scoped(.init_apic);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("x64");
