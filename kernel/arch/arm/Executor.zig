// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const arm = @import("arm.zig");

const Executor = @This();

mpidr: Id,

pub inline fn from(executor: *cascade.Executor) *Executor {
    return &executor.arch_specific.arch_specific;
}

pub const Id = enum(u64) {
    _,
};

pub const current = struct {
    /// Issue an architecture specific hint to the current executor that we are spinning in a loop.
    pub inline fn spinLoopHint() void {
        asm volatile ("isb");
    }

    /// Halt the current executor.
    pub fn halt() void {
        asm volatile ("wfe");
    }

    /// Disable interrupts on the current executor and halt.
    pub inline fn disableInterruptsAndHalt() noreturn {
        while (true) {
            asm volatile (
                \\msr DAIFSet, #0b1111
                \\wfe
            );
        }
    }

    /// Are interrupts enabled on the current executor.
    pub fn interruptsEnabled() bool {
        const daif = asm ("mrs %[daif], DAIF"
            : [daif] "=r" (-> u64),
        );
        const mask: u64 = 0b1111000000;
        return (daif & mask) == 0;
    }

    /// Enable interrupts on the current executor.
    pub fn enableInterrupts() void {
        asm volatile ("msr DAIFClr, #0b1111;");
    }

    /// Disable interrupts on the current executor.
    pub fn disableInterrupts() void {
        asm volatile ("msr DAIFSet, #0b1111");
    }
};

pub const init = struct {
    /// Prepares this executor as the bootstrap executor.
    pub fn prepareBootstrap(executor: *cascade.Executor, id: Id) void {
        const arm_executor: *Executor = .from(executor);
        arm_executor.* = .{
            .mpidr = id,
        };
    }

    /// Initialize the current executor.
    pub fn initialize(
        executor: *cascade.Executor,
    ) void {
        _ = executor;
    }
};
