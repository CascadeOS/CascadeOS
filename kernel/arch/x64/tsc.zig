// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

inline fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

const globals = struct {
    /// The duration of a tick in femptoseconds.
    ///
    /// Initalized during `initializeTsc[Calibrate]`
    var tick_duration_fs: u64 = undefined;
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.tsc_init);

    // Read current wallclock time from the standard wallclock source of the current architecture.
    ///
    /// For example on x86_64 this is the TSC.
    pub fn getStandardWallclockStartTime() cascade.time.wallclock.Tick {
        return @enumFromInt(readTsc());
    }

    pub fn registerTimeSource(candidate_time_sources: *cascade.time.init.CandidateTimeSources) void {
        if (!shouldUseTsc()) return;

        candidate_time_sources.addTimeSource(.{
            .name = "tsc",
            .priority = 200,

            .initialization = if (x64.info.tsc_tick_duration_fs != null)
                .{
                    .simple = struct {
                        fn simple() void {
                            std.debug.assert(shouldUseTsc());

                            const tsc_tick_duration_fs = x64.info.tsc_tick_duration_fs orelse @panic("tsc tick duration not captured");

                            globals.tick_duration_fs = tsc_tick_duration_fs;
                            init_log.debug(
                                "tick duration (fs): {}",
                                .{tsc_tick_duration_fs},
                            );
                        }
                    }.simple,
                }
            else
                .{ .calibration_required = initializeTscCalibrate },

            .reference_counter = if (x64.info.tsc_tick_duration_fs != null)
                .{
                    .prepareToWaitForFn = struct {
                        fn prepareToWaitForFn(duration: core.Duration) void {
                            _ = duration;
                        }
                    }.prepareToWaitForFn,
                    .waitForFn = struct {
                        fn waitForFn(duration: core.Duration) void {
                            const current_value = readTsc();

                            const target_value = current_value +
                                ((duration.value * cascade.time.fs_per_ns) / globals.tick_duration_fs);

                            while (readTsc() < target_value) {}
                        }
                    }.waitForFn,
                }
            else
                null,

            .wallclock = .{
                .readFn = struct {
                    fn readFn() cascade.time.wallclock.Tick {
                        return @enumFromInt(readTsc());
                    }
                }.readFn,
                .elapsedFn = struct {
                    fn elapsedFn(
                        value1: cascade.time.wallclock.Tick,
                        value2: cascade.time.wallclock.Tick,
                    ) core.Duration {
                        const number_of_ticks = @intFromEnum(value2) - @intFromEnum(value1);
                        return core.Duration.from((number_of_ticks * globals.tick_duration_fs) / cascade.time.fs_per_ns, .nanosecond);
                    }
                }.elapsedFn,
                .standard_wallclock_source = true,
            },
        });
    }

    fn initializeTscCalibrate(reference_counter: cascade.time.init.ReferenceCounter) void {
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

        globals.tick_duration_fs = (sample_duration.value * cascade.time.fs_per_ns) / average_ticks;
        init_log.debug("tick duration (fs) using reference counter: {}", .{globals.tick_duration_fs});
    }

    fn shouldUseTsc() bool {
        return x64.info.cpu_id.invariant_tsc or x64.info.cpu_id.hypervisor == .tcg;
    }
};
