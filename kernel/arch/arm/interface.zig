// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const arm = @import("arm.zig");

pub const functions: arch.Functions = .{
    .spinLoopHint = arm.instructions.isb,
    .halt = arm.instructions.halt,

    .interrupts = .{
        .disableAndHalt = arm.instructions.disableInterruptsAndHalt,
        .areEnabled = arm.instructions.interruptsEnabled,
        .enable = arm.instructions.enableInterrupts,
        .disable = arm.instructions.disableInterrupts,

        .init = .{},
    },

    .paging = .{
        .init = .{},
    },

    .user = .{
        .init = .{},
    },

    .scheduling = .{
        .initializeTaskArchSpecific = struct {
            fn initializeTaskArchSpecific(_: *kernel.Task) void {}
        }.initializeTaskArchSpecific,

        .getCurrentTask = struct {
            inline fn getCurrentTask() *kernel.Task {
                return @ptrFromInt(arm.registers.TPIDR_EL1.read());
            }
        }.getCurrentTask,
        .setCurrentTask = struct {
            inline fn setCurrentTask(task: *kernel.Task) void {
                arm.registers.TPIDR_EL1.write(@intFromPtr(task));
            }
        }.setCurrentTask,
    },

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
                return @enumFromInt(arm.instructions.readPhysicalCount()); // TODO: should this be virtual count?
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput() ?arch.init.InitOutput {
                return null;
            }
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                executor: *kernel.Executor,
                architecture_processor_id: u64,
            ) void {
                executor.arch_specific = .{
                    .mpidr = architecture_processor_id,
                };
            }
        }.prepareBootstrapExecutor,

        .initExecutor = struct {
            fn initExecutor(
                executor: *kernel.Executor,
            ) void {
                _ = executor;
            }
        }.initExecutor,
    },
};

pub const decls: arch.Decls = .{
    .PerExecutor = struct { mpidr: u64 },

    .interrupts = .{
        .Interrupt = enum(u0) { _ },
        .InterruptFrame = extern struct {},
    },

    .paging = .{
        // TODO: most of these values are copied from the x64, so all of them need to be checked
        .standard_page_size = .from(4, .kib),
        .largest_page_size = .from(1, .gib),
        .lower_half_size = .from(128, .tib),
        .higher_half_start = .fromInt(0xffff800000000000),
        .PageTable = extern struct {},
    },

    .scheduling = .{
        .PerTask = struct {},
        .cfi_prevent_unwinding =
        \\.cfi_sections .debug_frame
        \\.cfi_undefined lr
        \\
        ,
    },

    .user = .{
        .PerThread = struct {},
        .SyscallFrame = struct {},
    },

    .io = .{
        .Port = enum(u0) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = struct {},
    },
};
