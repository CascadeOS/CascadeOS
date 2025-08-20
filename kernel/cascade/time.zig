// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const wallclock = struct {
    /// This is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub const Tick = enum(u64) {
        zero = 0,

        _,
    };

    /// Read the wallclock value.
    pub inline fn read() Tick {
        return globals.readFn();
    }

    /// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub inline fn elapsed(value1: Tick, value2: Tick) core.Duration {
        return globals.elapsedFn(value1, value2);
    }

    const globals = struct {
        var readFn: *const fn () Tick = undefined;
        var elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration = undefined;
    };
};

pub const per_executor_periodic = struct {
    /// Enables a per-executor scheduler interrupt to be delivered every `period`.
    pub inline fn enableInterrupt(period: core.Duration) void {
        return globals.enableInterruptFn(period);
    }

    const globals = struct {
        var enableInterruptFn: *const fn (period: core.Duration) void = undefined;
    };
};

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const init = struct {
    pub fn setTimeImplementations(time_implementations: TimeImplementations) void {
        wallclock.globals.readFn = time_implementations.wallclockReadFn;
        wallclock.globals.elapsedFn = time_implementations.wallclockElapsedFn;
        per_executor_periodic.globals.enableInterruptFn = time_implementations.perExecutorPeriodicEnableInterruptFn;
    }

    pub const TimeImplementations = struct {
        wallclockReadFn: *const fn () wallclock.Tick,
        wallclockElapsedFn: *const fn (value1: wallclock.Tick, value2: wallclock.Tick) core.Duration,

        perExecutorPeriodicEnableInterruptFn: *const fn (period: core.Duration) void,
    };
};

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const std = @import("std");
