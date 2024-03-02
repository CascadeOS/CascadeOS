// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const acpi = @import("acpi");
const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.apic);

/// The local APIC pointer used when in xAPIC mode.
///
/// Initialized in `x86_64.init.captureMADTInformation`.
var lapic: x86_64.LAPIC = undefined;

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeLapicTimer[Calibrate]`

pub inline fn eoi() void {
    lapic.eoi();
}

/// Set the task priority to the given priority.
pub fn setTaskPriority(priority: kernel.scheduler.Priority) void {
    // Set the TPR `priority_class` to 2 as that is the lowest priority that does not overlap with
    // exceptions/PIC interrupts.
    lapic.writeTaskPriorityRegister(.{
        .priority_sub_class = @intFromEnum(priority),
        .priority_class = 2,
    });

    log.debug("set task priority to: {s}", .{@tagName(priority)});
}

pub fn panicInterruptOtherCores() void {
    lapic.writeInterruptCommandRegister(.{
        .vector = undefined, // overriden by `delivery_mode`
        .delivery_mode = .nmi,
        .destination_mode = .logical,
        .level = .assert,
        .trigger_mode = .edge,
        .destination_shorthand = .all_excluding_self,
        .destination_field = undefined, // destination shorthand is set
    });
}

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const acpi.FADT,
        madt: *const acpi.MADT,
    ) void {
        lapic = if (kernel.boot.x2apicEnabled())
            .x2apic
        else
            .{
                .xapic = kernel.nonCachedDirectMapFromPhysical(
                    core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address),
                ).toPtr([*]volatile u8),
            };

        log.debug("lapic detected: {}", .{lapic});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced");
        }
    }

    pub fn initApicOnProcessor(_: *kernel.Processor) void {
        setTaskPriority(.idle);

        // TODO: Error interrupt

        lapic.writeSupriousInterruptRegister(.{
            .apic_enable = true,
            .spurious_vector = x86_64.interrupts.Interrupt.spurious_interrupt.toInterruptVector(),
        });
    }

    pub fn registerTimeSource() void {
        kernel.time.init.addTimeSource(.{
            .name = "lapic",
            .priority = 150,
            .initialization = if (x86_64.arch_info.lapic_base_tick_duration_fs != null)
                .{ .simple = initializeLapicTimer }
            else
                .{ .calibration_required = initializeLapicTimerCalibrate },
            .per_core_periodic = .{ .enableSchedulerInterruptFn = perCorePeriodicEnableSchedulerInterrupt },
        });
    }

    const divide_configuration: x86_64.LAPIC.DivideConfigurationRegister = .@"2";

    fn initializeLapicTimer() void {
        core.debugAssert(x86_64.arch_info.lapic_base_tick_duration_fs != null);

        tick_duration_fs = x86_64.arch_info.lapic_base_tick_duration_fs.? * divide_configuration.toInt();
        log.debug("tick duration (fs) from cpuid: {}", .{tick_duration_fs});
    }

    fn initializeLapicTimerCalibrate(
        reference_counter: kernel.time.init.ReferenceCounter,
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

    fn perCorePeriodicEnableSchedulerInterrupt(period: core.Duration) void {
        lapic.writeInitialCountRegister(0);
        lapic.writeDivideConfigurationRegister(divide_configuration);

        lapic.writeLVTTimerRegister(.{
            .vector = x86_64.interrupts.Interrupt.scheduler.toInterruptVector(),
            .timer_mode = .periodic,
            .masked = false,
        });

        const ticks = std.math.cast(
            u32,
            (period.value * kernel.time.fs_per_ns) / tick_duration_fs,
        ) orelse core.panic("period is too long");
        lapic.writeInitialCountRegister(ticks);
    }
};
