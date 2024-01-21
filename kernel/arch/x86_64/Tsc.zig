// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.tsc);

const Tsc = @This();

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeTsc`

fn readCounter() u64 {
    return readTsc();
}

fn elapsed(value1: u64, value2: u64) core.Duration {
    const number_of_ticks = value2 - value1;
    return core.Duration.from((number_of_ticks * tick_duration_fs) / kernel.time.fs_per_ns, .nanosecond);
}

pub const init = struct {
    pub fn registerTimeSource() linksection(kernel.info.init_code) void {
        if (!x86_64.arch_info.invariant_tsc) return;

        kernel.time.init.addTimeSource(.{
            .name = "tsc",
            .priority = 200,
            .per_core = true,
            .initialization = if (x86_64.arch_info.tsc_tick_duration_fs != null)
                .{ .simple = initializeTsc }
            else
                .{ .calibration_required = initializeTscCalibrate },
            .reference_counter = if (x86_64.arch_info.tsc_tick_duration_fs != null)
                .{
                    .prepareToWaitForFn = prepareToWaitFor,
                    .waitForFn = waitFor,
                }
            else
                null,
            .wallclock = .{
                .readCounterFn = readCounter,
                .elapsedFn = elapsed,
            },
        });
    }

    fn initializeTsc() linksection(kernel.info.init_code) void {
        core.debugAssert(x86_64.arch_info.tsc_tick_duration_fs != null);
        core.debugAssert(x86_64.arch_info.invariant_tsc);
        core.debugAssert(x86_64.arch_info.rdtscp);

        tick_duration_fs = x86_64.arch_info.tsc_tick_duration_fs.?;
        log.debug("tick duration (fs) from cpuid: {}", .{tick_duration_fs});
    }

    fn initializeTscCalibrate(
        reference_time_source: kernel.time.init.ReferenceCounterTimeSource,
    ) linksection(kernel.info.init_code) void {
        core.debugAssert(x86_64.arch_info.invariant_tsc);
        core.debugAssert(x86_64.arch_info.rdtscp);

        const reference_duration = core.Duration.from(15, .millisecond);

        reference_time_source.prepareToWaitFor(reference_duration);

        const start = readTsc();
        reference_time_source.waitFor(reference_duration);
        const end = readTsc();

        tick_duration_fs = (reference_duration.value * kernel.time.fs_per_ns) / (end - start);
        log.debug("tick duration (fs) using reference counter: {}", .{tick_duration_fs});
    }

    fn prepareToWaitFor(duration: core.Duration) linksection(kernel.info.init_code) void {
        _ = duration;
    }

    fn waitFor(duration: core.Duration) linksection(kernel.info.init_code) void {
        const current_value = readTsc();

        const target_value = current_value + ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

        while (readTsc() < target_value) {
            kernel.arch.spinLoopHint();
        }
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
