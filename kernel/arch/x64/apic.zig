// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const acpi = @import("acpi");
const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const x64 = @import("x64.zig");

const log = kernel.log.scoped(.apic);

/// Signal end of interrupt.
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
}

/// Initialized in `init.captureApicInformation`.
var lapic: x64.LAPIC = .{
    .xapic = @ptrFromInt(1), // FIXME: initialized with a dummy value to prevent a zig bug in `init.captureApicInformation`
};

/// The duration of a tick in femptoseconds.
///
/// Initalized in `init.initializeLapicTimer[Calibrate]`
var tick_duration_fs: u64 = undefined;

pub const init = struct {
    pub fn captureApicInformation(
        fadt: *const acpi.FADT,
        madt: *const acpi.MADT,
    ) void {
        if (kernel.boot.x2apicEnabled()) {
            lapic = .x2apic;
        } else {
            lapic.xapic = kernel.vmm
                .nonCachedDirectMapFromPhysical(core.PhysicalAddress.fromInt(madt.local_interrupt_controller_address))
                .toPtr([*]volatile u8);
        }

        log.debug("lapic detected: {}", .{lapic});

        if (fadt.fixed_feature_flags.FORCE_APIC_PHYSICAL_DESTINATION_MODE) {
            core.panic("physical destination mode is forced", null);
        }
    }

    pub fn initApicOnProcessor(_: *kernel.Cpu) void {
        lapic.writeSupriousInterruptRegister(.{
            .apic_enable = true,
            .spurious_vector = x64.interrupts.Interrupt.spurious_interrupt.toInterruptVector(),
        });

        setTaskPriority(.idle);

        // TODO: error interrupt
    }

    pub fn registerTimeSource() void {
        kernel.time.init.addTimeSource(.{
            .name = "lapic",
            .priority = 150,
            .initialization = if (x64.info.lapic_base_tick_duration_fs != null)
                .{ .simple = initializeLapicTimer }
            else
                .{ .calibration_required = initializeLapicTimerCalibrate },
            .per_core_periodic = .{ .enableSchedulerInterruptFn = perCorePeriodicEnableSchedulerInterrupt },
        });
    }

    const divide_configuration: x64.LAPIC.DivideConfigurationRegister = .@"2";

    fn initializeLapicTimer() void {
        std.debug.assert(x64.info.lapic_base_tick_duration_fs != null);

        tick_duration_fs = x64.info.lapic_base_tick_duration_fs.? * divide_configuration.toInt();
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
            .vector = x64.interrupts.Interrupt.scheduler.toInterruptVector(),
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
