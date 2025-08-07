// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .interrupts = .{
        .disableAndHalt = riscv.interrupts.disableInterruptsAndHalt,
        .areEnabled = riscv.interrupts.areEnabled,
        .enable = riscv.interrupts.enableInterrupts,
        .disable = riscv.interrupts.disableInterrupts,

        .init = .{},
    },

    .paging = .{
        .init = .{},
    },

    .scheduling = .{},

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = riscv.init.getStandardWallclockStartTime,
        .tryGetSerialOutput = riscv.init.tryGetSerialOutput,
        .prepareBootstrapExecutor = riscv.init.prepareBootstrapExecutor,
        .loadExecutor = riscv.init.loadExecutor,
    },
};

pub const decls: arch.Decls = .{
    .PerExecutor = riscv.PerExecutor,

    .interrupts = .{
        .Interrupt = riscv.interrupts.Interrupt,
        .InterruptFrame = riscv.interrupts.InterruptFrame,
    },

    .paging = .{
        .standard_page_size = riscv.paging.all_page_sizes[0],
        .largest_page_size = riscv.paging.all_page_sizes[riscv.paging.all_page_sizes.len - 1],
        .lower_half_size = riscv.paging.lower_half_size,
        .higher_half_start = riscv.paging.higher_half_start,
        .PageTable = riscv.paging.PageTable,
    },

    .io = .{
        .Port = enum(u64) { _ },
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
