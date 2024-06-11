// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x64 = @import("x64.zig");

const readTsc = x64.readTsc;

const log = kernel.log.scoped(.tsc);

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeTsc[Calibrate]`

pub const init = struct {
    pub fn registerTimeSource() void {
        if (!shouldUseTsc()) return;

        kernel.time.init.addTimeSource(.{
            .name = "tsc",
            .priority = 200,

            .initialization = if (x64.info.tsc_tick_duration_fs != null)
                .{ .simple = initializeTsc }
            else
                .{ .calibration_required = initializeTscCalibrate },

            .reference_counter = if (x64.info.tsc_tick_duration_fs != null)
                .{
                    .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
                    .waitForFn = referenceCounterWaitFor,
                }
            else
                null,
        });
    }

    fn initializeTsc() void {
        core.debugAssert(shouldUseTsc());
        core.debugAssert(x64.info.tsc_tick_duration_fs != null);

        tick_duration_fs = x64.info.tsc_tick_duration_fs.?;
        log.debug("tick duration (fs) from cpuid: {}", .{tick_duration_fs});
    }

    fn initializeTscCalibrate(
        reference_counter: kernel.time.init.ReferenceCounter,
    ) void {
        core.debugAssert(shouldUseTsc());

        // warmup
        {
            const warmup_duration = core.Duration.from(1, .millisecond);
            const number_of_warmups = 5;

            var total_warmup_ticks: u64 = 0;

            for (0..number_of_warmups) |_| {
                reference_counter.prepareToWaitFor(warmup_duration);

                const start = readTsc();
                reference_counter.waitFor(warmup_duration);
                const end = readTsc();

                total_warmup_ticks += end - start;
            }

            std.mem.doNotOptimizeAway(&total_warmup_ticks);
        }

        const sample_duration = core.Duration.from(5, .millisecond);
        const number_of_samples = 5;
        var total_ticks: u64 = 0;

        for (0..number_of_samples) |_| {
            reference_counter.prepareToWaitFor(sample_duration);

            const start = readTsc();
            reference_counter.waitFor(sample_duration);
            const end = readTsc();

            total_ticks += end - start;
        }

        const average_ticks = total_ticks / number_of_samples;

        tick_duration_fs = (sample_duration.value * kernel.time.fs_per_ns) / average_ticks;
        log.debug("tick duration (fs) using reference counter: {}", .{tick_duration_fs});
    }

    fn referenceCounterPrepareToWaitFor(duration: core.Duration) void {
        _ = duration;
    }

    fn referenceCounterWaitFor(duration: core.Duration) void {
        const current_value = readTsc();

        const target_value = current_value + ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

        while (readTsc() < target_value) {
            x64.pause();
        }
    }

    fn shouldUseTsc() bool {
        return x64.cpu_id.invariant_tsc or x64.cpu_id.hypervisor == .tcg;
    }
};
