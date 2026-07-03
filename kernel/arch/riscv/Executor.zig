// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const cascade = @import("cascade");
const core = @import("core");
const std = @import("std");

const riscv = @import("riscv.zig");

const Executor = @This();

hartid: Id,

pub inline fn from(executor: *cascade.Executor) *Executor {
    return &executor.arch_specific.arch_specific;
}

pub const Id = enum(u64) {
    _,
};

pub const current = struct {
    /// Hint to the CPU that we are in a spin loop.
    pub inline fn spinLoopHint() void {
        asm volatile ("pause");
    }

    /// Halt the current executor.
    pub fn halt() void {
        asm volatile ("wfi");
    }

    /// Disable interrupts on the current executor and halt.
    pub inline fn disableInterruptsAndHalt() noreturn {
        while (true) {
            riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
            asm volatile ("wfi");
        }
    }

    /// Are interrupts enabled on the current executor.
    pub fn interruptsEnabled() bool {
        const sstatus = riscv.registers.SupervisorStatus.read();
        return sstatus.sie;
    }

    /// Enable interrupts on the current executor.
    pub fn enableInterrupts() void {
        riscv.registers.SupervisorStatus.csr.setBitsImmediate(0b10);
    }

    /// Disable interrupts on the current executor.
    pub fn disableInterrupts() void {
        riscv.registers.SupervisorStatus.csr.clearBitsImmediate(0b10);
    }
};

pub const init = struct {
    /// Prepares this executor as the bootstrap executor.
    pub fn prepareBootstrap(
        executor: *cascade.Executor,
        id: Id,
    ) void {
        const riscv_executor: *Executor = .from(executor);
        riscv_executor.* = .{
            .hartid = id,
        };
    }

    /// Initialize the current executor.
    pub fn initialize(
        executor: *cascade.Executor,
    ) void {
        _ = executor;
    }
};
