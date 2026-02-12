// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;
const addr = cascade.addr;

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
            fn initializeTaskArchSpecific(_: *cascade.Task) void {}
        }.initializeTaskArchSpecific,

        .getCurrentTask = struct {
            inline fn getCurrentTask() *cascade.Task {
                return @ptrFromInt(riscv.registers.SupervisorScratch.read());
            }
        }.getCurrentTask,
        .setCurrentTask = struct {
            inline fn setCurrentTask(task: *cascade.Task) void {
                riscv.registers.SupervisorScratch.write(@intFromPtr(task));
            }
        }.setCurrentTask,
    },

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = struct {
            fn getStandardWallclockStartTime() cascade.time.wallclock.Tick {
                return @enumFromInt(riscv.instructions.readTime());
            }
        }.getStandardWallclockStartTime,

        .tryGetSerialOutput = struct {
            fn tryGetSerialOutput(memory_system_available: bool) ?arch.init.InitOutput {
                _ = memory_system_available;

                if (riscv.sbi_debug_console.detect()) {
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
                executor: *cascade.Executor,
                architecture_processor_id: u64,
            ) void {
                executor.arch_specific = .{
                    .hartid = @intCast(architecture_processor_id),
                };
            }
        }.prepareBootstrapExecutor,

        .initExecutor = struct {
            fn initExecutor(
                executor: *cascade.Executor,
            ) void {
                _ = executor;
            }
        }.initExecutor,
    },
};

const standard_page_size: core.Size = .from(4, .kib);
const half_address_space_size: core.Size = .from(128, .tib);

pub const decls: arch.Decls = .{
    .PerExecutor = struct { hartid: u32 },

    .interrupts = .{
        .Interrupt = enum(u0) { _ },
        .InterruptFrame = extern struct {},
    },

    .paging = .{
        // TODO: most of these values are copied from the x64, so all of them need to be checked
        .standard_page_size = standard_page_size,
        .largest_page_size = .from(1, .gib),
        .kernel_memory_range = .from(
            .from(0xffff800000000000),
            half_address_space_size,
        ),
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
        .user_memory_range = .from(
            addr.Virtual.zero.moveForward(standard_page_size),
            half_address_space_size.subtract(standard_page_size),
        ),
    },

    .io = .{
        .Port = enum(u0) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = struct {},
    },
};
