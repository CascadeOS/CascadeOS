// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

const riscv = @import("riscv.zig");

pub const functions: arch.Functions = .{
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

    .user = .{
        .init = .{},
    },

    .scheduling = .{
        .initializeTaskArchSpecific = struct {
            fn initializeTaskArchSpecific(_: *kernel.Task) void {}
        }.initializeTaskArchSpecific,

        .getCurrentTask = struct {
            inline fn getCurrentTask() *kernel.Task {
                return @ptrFromInt(riscv.registers.SupervisorScratch.read());
            }
        }.getCurrentTask,
        .setCurrentTask = struct {
            inline fn setCurrentTask(task: *kernel.Task) void {
                riscv.registers.SupervisorScratch.write(@intFromPtr(task));
            }
        }.setCurrentTask,
    },

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() kernel.time.wallclock.Tick {
                return @enumFromInt(riscv.instructions.readTime());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput() ?arch.init.InitOutput {
                if (riscv.sbi_debug_console.detect()) {
                    log.debug("using sbi debug console for serial output", .{});
                    return .{
                        .output = riscv.sbi_debug_console.output,
                        .preference = .use,
                    };
                }

                return null;
            }

            const log = kernel.debug.log.scoped(.riscv_init);
        }.tryGetSerialOutput,

        .prepareBootstrapExecutor = struct {
            fn prepareBootstrapExecutor(
                executor: *kernel.Executor,
                architecture_processor_id: u64,
            ) void {
                executor.arch_specific = .{
                    .hartid = @intCast(architecture_processor_id),
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

    .scheduling = .{
        .PerTask = struct {},
        .cfi_prevent_unwinding =
        \\.cfi_sections .debug_frame
        \\.cfi_undefined ra
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
