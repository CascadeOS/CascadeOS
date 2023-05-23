// SPDX-License-Identifier: MIT

const std = @import("std");
const kernel = @import("root");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

const current = switch (kernel.info.arch) {
    .x86_64 => x86_64,
    .aarch64 => aarch64,
};

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

/// Functionality that is intended to be used during system setup only.
pub const setup = struct {
    /// Attempt to set up some form of early output.
    pub inline fn setupEarlyOutput() void {
        current.setup.setupEarlyOutput();
    }

    pub const EarlyOutputWriter = current.setup.EarlyOutputWriter;

    /// Acquire a `std.io.Writer` for the early output setup by `setupEarlyOutput`.
    pub inline fn getEarlyOutputWriter() EarlyOutputWriter {
        return current.setup.getEarlyOutputWriter();
    }
};

/// Disable interrupts and put the CPU to sleep.
pub inline fn disableInterruptsAndHalt() noreturn {
    current.instructions.disableInterruptsAndHalt();
}
