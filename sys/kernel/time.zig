// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const wallclock = struct {
    /// Read the wallclock value.
    ///
    /// The value returned is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub inline fn read() u64 {
        return globals.readFn();
    }

    /// Returns the number of nanoseconds between `value1` and `value2`, where `value2` occurs after `value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub inline fn elapsed(value1: u64, value2: u64) core.Duration {
        return globals.elapsedFn(value1, value2);
    }

    pub const globals = struct {
        // Initialized during `init.time.configureWallclockTimeSource`.
        pub var readFn: *const fn () u64 = undefined;
        // Initialized during `init.time.configureWallclockTimeSource`.
        pub var elapsedFn: *const fn (value1: u64, value2: u64) core.Duration = undefined;
    };
};

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
