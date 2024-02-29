// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.tsc);

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeTsc[Calibrate]`

fn wallClockRead() u64 {
    return readTsc();
}

fn wallClockElapsed(value1: u64, value2: u64) core.Duration {
    const number_of_ticks = value2 - value1;
    return core.Duration.from((number_of_ticks * tick_duration_fs) / kernel.time.fs_per_ns, .nanosecond);
}

pub const init = struct {
    pub fn registerTimeSource() void {
        if (!shouldUseTsc()) return;

        kernel.time.init.addTimeSource(.{
            .name = "tsc",
            .priority = 200,
            .initialization = if (x86_64.arch_info.tsc_tick_duration_fs != null)
                .{ .simple = initializeTsc }
            else
                .{ .calibration_required = initializeTscCalibrate },
            .reference_counter = if (x86_64.arch_info.tsc_tick_duration_fs != null)
                .{
                    .prepareToWaitForFn = referenceCounterPrepareToWaitFor,
                    .waitForFn = referenceCounterWaitFor,
                }
            else
                null,
            .wallclock = .{
                .readFn = wallClockRead,
                .elapsedFn = wallClockElapsed,
            },
        });
    }

    fn initializeTsc() void {
        core.debugAssert(shouldUseTsc());
        core.debugAssert(x86_64.arch_info.tsc_tick_duration_fs != null);

        tick_duration_fs = x86_64.arch_info.tsc_tick_duration_fs.?;
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
            kernel.arch.spinLoopHint();
        }
    }

    fn shouldUseTsc() bool {
        return x86_64.arch_info.rdtscp and (x86_64.arch_info.invariant_tsc or kernel.info.hypervisor == .tcg);
    }
};

inline fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtscp"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        :
        : "ecx"
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}
