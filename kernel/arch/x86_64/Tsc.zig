// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const x86_64 = @import("x86_64.zig");

const log = kernel.debug.log.scoped(.tsc);

const Tsc = @This();

/// The duration of a tick in picoseconds.
var tick_duration_ps: u64 = undefined; // Initalized during `initializeTsc`

pub fn readCounter() u64 {
    return readTsc();
}

pub fn elapsed(value1: u64, value2: u64) core.Duration {
    const number_of_ticks = value2 - value1;
    return core.Duration.from((number_of_ticks * tick_duration_ps) / kernel.time.ps_per_ns, .nanosecond);
}

pub const init = struct {
    pub fn initializeTsc(
        reference_time_source: kernel.time.init.ReferenceCounterTimeSource,
    ) linksection(kernel.info.init_code) void {
        core.debugAssert(x86_64.arch_info.invariant_tsc);
        core.debugAssert(x86_64.arch_info.rdtscp);

        const reference_duration = core.Duration.from(15, .millisecond);

        reference_time_source.prepareToWaitFor(reference_duration);

        const start = readTsc();
        reference_time_source.waitFor(reference_duration);
        const end = readTsc();

        tick_duration_ps = (reference_duration.value * kernel.time.ps_per_ns) / (end - start);
        log.debug("tick duration (ps): {}", .{tick_duration_ps});
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
