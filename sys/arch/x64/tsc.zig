// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const init = struct {
    pub fn registerTimeSource(candidate_time_sources: *init_time.CandidateTimeSources) void {
        if (!shouldUseTsc()) return;

        candidate_time_sources.addTimeSource(.{
            .name = "tsc",
            .priority = 200,

            .initialization = if (x64.info.tsc_tick_duration_fs != null)
                .{
                    .simple = struct {
                        fn simple() void {
                            std.debug.assert(shouldUseTsc());
                            std.debug.assert(x64.info.tsc_tick_duration_fs != null);

                            tick_duration_fs = x64.info.tsc_tick_duration_fs.?;
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

                            const target_value = current_value + ((duration.value * kernel.time.fs_per_ns) / tick_duration_fs);

                            while (readTsc() < target_value) {
                                lib_x64.instructions.pause();
                            }
                        }
                    }.waitForFn,
                }
            else
                null,

            .wallclock = .{
                .readFn = struct {
                    fn readFn() Tick {
                        return @enumFromInt(readTsc());
                    }
                }.readFn,
                .elapsedFn = struct {
                    fn elapsedFn(value1: Tick, value2: Tick) core.Duration {
                        const number_of_ticks = @intFromEnum(value2) - @intFromEnum(value1);
                        return core.Duration.from((number_of_ticks * tick_duration_fs) / kernel.time.fs_per_ns, .nanosecond);
                    }
                }.elapsedFn,
            },
        });
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

    fn shouldUseTsc() bool {
        return x64.info.cpu_id.invariant_tsc or x64.info.cpu_id.hypervisor == .tcg;
    }
};

/// The duration of a tick in femptoseconds.
var tick_duration_fs: u64 = undefined; // Initalized during `initializeTsc[Calibrate]`

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const x64 = @import("x64.zig");
const lib_x64 = @import("lib_x64");
const log = kernel.log.scoped(.tsc);
const readTsc = lib_x64.instructions.readTsc;
const init_time = @import("init").time;
const Tick = kernel.time.wallclock.Tick;
