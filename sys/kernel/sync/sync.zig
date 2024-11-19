// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const Mutex = @import("Mutex.zig");
pub const TicketSpinLock = @import("TicketSpinLock.zig");
pub const WaitQueue = @import("WaitQueue.zig");

/// Acquire interrupt exclusion.
pub fn acquireInterruptExclusion() InterruptExclusion {
    const enabled = arch.interrupts.areEnabled();

    if (enabled) arch.interrupts.disableInterrupts();

    return .{ .enable_on_release = enabled };
}

pub fn assertInterruptExclusion(enable_on_release: bool) InterruptExclusion {
    std.debug.assert(!arch.interrupts.areEnabled());

    return .{ .enable_on_release = enable_on_release };
}

pub const InterruptExclusion = struct {
    enable_on_release: bool,

    pub fn release(self: *InterruptExclusion) void {
        self.validate();

        if (self.enable_on_release) arch.interrupts.enableInterrupts();
        self.enable_on_release = false;
    }

    pub fn validate(_: InterruptExclusion) void {
        std.debug.assert(!arch.interrupts.areEnabled()); // TODO: debug assert
    }

    pub fn getCurrentExecutor(self: InterruptExclusion) *kernel.Executor {
        self.validate();

        return arch.rawGetCurrentExecutor();
    }
};

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");
const arch = @import("arch");
