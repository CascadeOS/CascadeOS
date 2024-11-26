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

    pub fn initApicOnCurrentExecutor() void {
        lapic.writeSupriousInterruptRegister(.{
            .apic_enable = true,
            .spurious_vector = x64.interrupts.Interrupt.spurious_interrupt.toInterruptVector(),
        });

        // TODO: task priority
        // TODO: error interrupt
    }

    pub fn registerTimeSource(candidate_time_sources: *init_time.CandidateTimeSources) void {
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

        tick_duration_fs = x64.info.lapic_base_tick_duration_fs.? * divide_configuration.toInt();
        log.debug("tick duration (fs) from cpuid: {}", .{tick_duration_fs});
    }

    fn initializeLapicTimerCalibrate(
        reference_counter: init_time.ReferenceCounter,
    ) void {
        lapic.writeDivideConfigurationRegister(divide_configuration);

        lapic.writeLVTTimerRegister(.{
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

                lapic.writeInitialCountRegister(std.math.maxInt(u32));
                reference_counter.waitFor(warmup_duration);
                const end = lapic.readCurrentCountRegister();
                lapic.writeInitialCountRegister(0);

                total_warmup_ticks += std.math.maxInt(u32) - end;
            }

            std.mem.doNotOptimizeAway(&total_warmup_ticks);
        }

        const sample_duration = core.Duration.from(5, .millisecond);
        const number_of_samples = 5;
        var total_ticks: u64 = 0;

        for (0..number_of_samples) |_| {
            reference_counter.prepareToWaitFor(sample_duration);

            lapic.writeInitialCountRegister(std.math.maxInt(u32));
            reference_counter.waitFor(sample_duration);
            const end = lapic.readCurrentCountRegister();
            lapic.writeInitialCountRegister(0);

            total_ticks += std.math.maxInt(u32) - end;
        }

        const average_ticks = total_ticks / number_of_samples;

        tick_duration_fs = (sample_duration.value * kernel.time.fs_per_ns) / average_ticks;
        log.debug("tick duration (fs) using reference counter: {}", .{tick_duration_fs});
    }

    fn perExecutorPeriodicEnableInterrupt(period: core.Duration) void {
        lapic.writeInitialCountRegister(0);
        lapic.writeDivideConfigurationRegister(divide_configuration);

        lapic.writeLVTTimerRegister(.{
            .vector = x64.interrupts.Interrupt.per_executor_periodic.toInterruptVector(),
            .timer_mode = .periodic,
            .masked = false,
        });

        const ticks = std.math.cast(
            u32,
            (period.value * kernel.time.fs_per_ns) / tick_duration_fs,
        ) orelse core.panic("period is too long", null);

        lapic.writeInitialCountRegister(ticks);
    }
};

/// The duration of a tick in femptoseconds.
///
/// Initalized in `init.initializeLapicTimer[Calibrate]`
var tick_duration_fs: u64 = undefined;

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
const init_time = @import("init").time;
