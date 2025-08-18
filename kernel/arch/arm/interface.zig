// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .getCurrentExecutor = struct {
        inline fn getCurrentExecutor() *kernel.Executor {
            return @ptrFromInt(arm.registers.TPIDR_EL1.read());
        }
    }.getCurrentExecutor,

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

    .scheduling = .{},

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
                return @enumFromInt(arm.instructions.readPhysicalCount()); // TODO: should this be virtual count?
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(_: *kernel.Context) ?arch.init.InitOutput {
                return null;
            }
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                context: *kernel.Context,
                architecture_processor_id: u64,
            ) void {
                context.executor.?.arch_specific = .{
                    .mpidr = architecture_processor_id,
                };
            }
        }.prepareBootstrapExecutor,

        .loadExecutor = struct {
            fn loadExecutor(context: *kernel.Context) void {
                arm.registers.TPIDR_EL1.write(@intFromPtr(context.executor.?));
            }
        }.loadExecutor,
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

    .io = .{
        .Port = enum(u0) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = struct {},
    },
};

const arch = @import("arch");
const kernel = @import("kernel");

const arm = @import("arm.zig");

const core = @import("core");
const std = @import("std");
