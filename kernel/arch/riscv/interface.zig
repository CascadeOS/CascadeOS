// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const riscv = @import("riscv.zig");

pub const functions: arch.Functions = .{
    .getCurrentExecutor = struct {
        inline fn getCurrentExecutor() *cascade.Executor {
            return @ptrFromInt(riscv.registers.SupervisorScratch.read());
        }
    }.getCurrentExecutor,

    .spinLoopHint = riscv.instructions.pause,

    .halt = riscv.instructions.halt,

    .interrupts = .{
        .disableAndHalt = riscv.instructions.disableInterruptsAndHalt,
        .areEnabled = riscv.instructions.interruptsEnabled,
        .enable = riscv.instructions.enableInterrupts,
        .disable = riscv.instructions.disableInterrupts,

        .init = .{},
    },

    .paging = .{
        .init = .{},
    },

    .scheduling = .{},

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() cascade.time.wallclock.Tick {
                return @enumFromInt(riscv.instructions.readTime());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(current_task: Task.Current) ?arch.init.InitOutput {
                if (riscv.sbi_debug_console.detect()) {
                    log.debug(current_task, "using sbi debug console for serial output", .{});
                    return .{
                        .output = riscv.sbi_debug_console.output,
                        .preference = .use,
                    };
                }

                return null;
            }

            const log = cascade.debug.log.scoped(.riscv_init);
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                current_task: Task.Current,
                architecture_processor_id: u64,
            ) void {
                current_task.knownExecutor().arch_specific = .{
                    .hartid = @intCast(architecture_processor_id),
                };
            }
        }.prepareBootstrapExecutor,

        .loadExecutor = struct {
            fn loadExecutor(current_task: Task.Current) void {
                riscv.registers.SupervisorScratch.write(@intFromPtr(current_task.knownExecutor()));
            }
        }.loadExecutor,
    },
};

pub const decls: arch.Decls = .{
    .PerExecutor = struct { hartid: u32 },

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
