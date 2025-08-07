// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .interrupts = .{
        .disableAndHalt = arm.interrupts.disableInterruptsAndHalt,
        .areEnabled = arm.interrupts.areEnabled,
        .enable = arm.interrupts.enableInterrupts,
        .disable = arm.interrupts.disableInterrupts,

        .init = .{},
    },

    .paging = .{
        .init = .{},
    },

    .scheduling = .{},

    .io = .{},

    .init = .{
        .getStandardWallclockStartTime = arm.init.getStandardWallclockStartTime,
        .tryGetSerialOutput = arm.init.tryGetSerialOutput,
        .prepareBootstrapExecutor = arm.init.prepareBootstrapExecutor,
        .loadExecutor = arm.init.loadExecutor,
    },
};

pub const decls: arch.Decls = .{
    .PerExecutor = arm.PerExecutor,

    .interrupts = .{
        .Interrupt = arm.interrupts.Interrupt,
        .InterruptFrame = arm.interrupts.InterruptFrame,
    },

    .paging = .{
        .standard_page_size = arm.paging.all_page_sizes[0],
        .largest_page_size = arm.paging.all_page_sizes[arm.paging.all_page_sizes.len - 1],
        .lower_half_size = arm.paging.lower_half_size,
        .higher_half_start = arm.paging.higher_half_start,
        .PageTable = arm.paging.PageTable,
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

const arm = @import("arm.zig");

const core = @import("core");
const std = @import("std");
