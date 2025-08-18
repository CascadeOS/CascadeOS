// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .getCurrentExecutor = struct {
        inline fn getCurrentExecutor() *kernel.Executor {
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
            fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
                return @enumFromInt(riscv.instructions.readTime());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(context: *kernel.Task.Context) ?arch.init.InitOutput {
                if (riscv.sbi_debug_console.detect()) {
                    log.debug(context, "using sbi debug console for serial output", .{});
                    return .{
                        .output = riscv.sbi_debug_console.output,
                        .preference = .use,
                    };
                }

                return null;
            }

            const log = kernel.debug.log.scoped(.init_riscv);
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                context: *kernel.Task.Context,
                architecture_processor_id: u64,
            ) void {
                context.executor.?.arch_specific = .{
                    .hartid = @intCast(architecture_processor_id),
                };
            }
        }.prepareBootstrapExecutor,

        .loadExecutor = struct {
            fn loadExecutor(context: *kernel.Task.Context) void {
                riscv.registers.SupervisorScratch.write(@intFromPtr(context.executor.?));
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

const arch = @import("arch");
const kernel = @import("kernel");

const riscv = @import("riscv.zig");

const core = @import("core");
const std = @import("std");
