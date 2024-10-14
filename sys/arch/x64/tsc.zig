// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn registerTimeSource(candidate_time_sources: *init_time.CandidateTimeSources) void {
    if (!shouldUseTsc()) return;

    candidate_time_sources.addTimeSource(.{
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

        .wallclock = .{
            .readFn = readTsc,
            .elapsedFn = wallClockElapsed,
        },
    });
}

fn initializeTsc() void {
    std.debug.assert(shouldUseTsc());
    std.debug.assert(x64.info.tsc_tick_duration_fs != null);

    tick_duration_fs = x64.info.tsc_tick_duration_fs.?;
}

fn initializeTscCalibrate(
    reference_counter: init_time.ReferenceCounter,
) void {
    std.debug.assert(shouldUseTsc());

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
        lib_x64.instructions.pause();
    }
}

fn wallClockElapsed(value1: u64, value2: u64) core.Duration {
    const number_of_ticks = value2 - value1;
    return core.Duration.from((number_of_ticks * tick_duration_fs) / kernel.time.fs_per_ns, .nanosecond);
}

fn shouldUseTsc() bool {
    return x64.info.cpu_id.invariant_tsc or x64.info.cpu_id.hypervisor == .tcg;
}

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeTsc[Calibrate]`

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const log = kernel.log.scoped(.tsc);
const init_time = @import("init").time;
const readTsc = lib_x64.instructions.readTsc;
