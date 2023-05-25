// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const aarch64 = @import("aarch64/aarch64.zig");
pub const x86_64 = @import("x86_64/x86_64.zig");

comptime {
    // ensure any architecture specific code is referenced
    _ = current;
}

const current = switch (kernel.info.arch) {
    .x86_64 => x86_64,
    .aarch64 => aarch64,
};

pub const PhysAddr = extern struct {
    value: usize,

    pub const zero: PhysAddr = .{ .value = 0 };
};

pub const VirtAddr = extern struct {
    value: usize,

    pub const zero: VirtAddr = .{ .value = 0 };
};

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

    /// Initialize the architecture specific registers and structures into the state required for early setup.
    /// One of the requirements of this function is to ensure that any exceptions/faults that occur are correctly handled.
    ///
    /// For example, on x86_64 this should setup a GDT, TSS and IDT then install a simple exception handler on every vector.
    pub inline fn earlyArchInitialization() void {
        current.setup.earlyArchInitialization();
    }
};

/// Disable interrupts and put the CPU to sleep.
pub inline fn disableInterruptsAndHalt() noreturn {
    current.instructions.disableInterruptsAndHalt();
}
