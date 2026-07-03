// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const riscv = @import("riscv.zig");

pub const functions: arch.Functions = .{
    .executor = .{
        .current = .{
            .spinLoopHint = riscv.Executor.current.spinLoopHint,
            .halt = riscv.Executor.current.halt,
            .disableInterruptsAndHalt = riscv.Executor.current.disableInterruptsAndHalt,
            .interruptsEnabled = riscv.Executor.current.interruptsEnabled,
            .enableInterrupts = riscv.Executor.current.enableInterrupts,
            .disableInterrupts = riscv.Executor.current.disableInterrupts,
        },

        .init = .{
            .prepareBootstrap = riscv.Executor.init.prepareBootstrap,
            .initialize = riscv.Executor.init.initialize,
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
        .initialize = riscv.Task.initialize,
        .getCurrent = riscv.Task.getCurrent,
        .setCurrent = riscv.Task.setCurrent,
    },

    .pci = .{},

    .port = .{},

    .init = .{
        .getStandardWallclockStartTime = riscv.init.getStandardWallclockStartTime,
        .tryGetSerialOutput = riscv.init.tryGetSerialOutput,
    },
};

const size_of_canonical_region: core.Size = .from(128, .tib);

pub const decls: arch.Decls = .{
    .kernel_memory_range = .from(
        cascade.VirtualAddress.from(0xffff800000000000),
        size_of_canonical_region
            // exclude the last page of memory, this prevents boundary conditions
            .subtract(riscv.PageTable.small_page_size),
    ),

    .user_memory_range = .from(
        cascade.VirtualAddress.zero.moveForward(riscv.PageTable.small_page_size),
        size_of_canonical_region
            // exclude the first page of memory so that a null pointer is not a valid user address
            .subtract(riscv.PageTable.small_page_size)
            // exclude the last page of memory, this prevents boundary conditions
            .subtract(riscv.PageTable.small_page_size),
    ),

    .cfi_prevent_unwinding =
    \\.cfi_sections .debug_frame
    \\.cfi_undefined ra
    \\
    ,

    .Executor = riscv.Executor,

    .ExecutorId = riscv.Executor.Id,

    .Interrupt = riscv.Interrupt,

    .InterruptFrame = riscv.Interrupt.Frame,

    .ExternalInterrupt = riscv.Interrupt.External,

    .PageTable = riscv.PageTable,

    .standard_page_size = riscv.PageTable.small_page_size,

    .largest_page_size = riscv.PageTable.large_page_size,

    .Thread = riscv.Thread,

    .SyscallFrame = riscv.syscall.Frame,

    .Task = riscv.Task,

    .Port = enum(u0) { _ },

    .CaptureSystemInformationOptions = riscv.init.CaptureSystemInformationOptions,
};
