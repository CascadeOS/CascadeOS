// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const arm = @import("arm.zig");

pub const functions: arch.Functions = .{
    .executor = .{
        .current = .{
            .spinLoopHint = arm.Executor.current.spinLoopHint,
            .halt = arm.Executor.current.halt,
            .disableInterruptsAndHalt = arm.Executor.current.disableInterruptsAndHalt,
            .interruptsEnabled = arm.Executor.current.interruptsEnabled,
            .enableInterrupts = arm.Executor.current.enableInterrupts,
            .disableInterrupts = arm.Executor.current.disableInterrupts,
        },

        .init = .{
            .prepareBootstrap = arm.Executor.init.prepareBootstrap,
            .initialize = arm.Executor.init.initialize,
        },
    },

    .interrupt = .{
        .frame = .{},

        .external = .{},

        .init = .{},
    },

    .page_table = .{
        .init = .{},
    },

    .thread = .{
        .current = .{},

        .init = .{},
    },

    .syscall_frame = .{},

    .task = .{
        .initialize = arm.Task.initialize,
        .getCurrent = arm.Task.getCurrent,
        .setCurrent = arm.Task.setCurrent,
    },

    .pci = .{},

    .port = .{},

    .init = .{
        .getStandardWallclockStartTime = arm.init.getStandardWallclockStartTime,
        .tryGetSerialOutput = arm.init.tryGetSerialOutput,
    },
};

const size_of_canonical_region: core.Size = .from(256, .tib);

pub const decls: arch.Decls = .{
    .kernel_memory_range = .from(
        cascade.VirtualAddress.from(0xffff000000000000),
        size_of_canonical_region
            // exclude the last page of memory, this prevents boundary conditions
            .subtract(arm.PageTable.small_page_size),
    ),

    .user_memory_range = .from(
        cascade.VirtualAddress.zero.moveForward(arm.PageTable.small_page_size),
        size_of_canonical_region
            // exclude the first page of memory so that a null pointer is not a valid user address
            .subtract(arm.PageTable.small_page_size)
            // exclude the last page of memory, this prevents boundary conditions
            .subtract(arm.PageTable.small_page_size),
    ),

    .cfi_prevent_unwinding =
    \\.cfi_sections .debug_frame
    \\.cfi_undefined lr
    \\
    ,

    .Executor = arm.Executor,

    .ExecutorId = arm.Executor.Id,

    .Interrupt = arm.Interrupt,

    .InterruptFrame = arm.Interrupt.Frame,

    .ExternalInterrupt = arm.Interrupt.External,

    .PageTable = arm.PageTable,

    .standard_page_size = arm.PageTable.small_page_size,

    .largest_page_size = arm.PageTable.large_page_size,

    .Thread = arm.Thread,

    .SyscallFrame = arm.syscall.Frame,

    .Task = arm.Task,

    .Port = enum(u0) { _ },

    .CaptureSystemInformationOptions = arm.init.CaptureSystemInformationOptions,
};
