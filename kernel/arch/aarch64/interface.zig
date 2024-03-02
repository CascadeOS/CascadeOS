// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const aarch64 = @import("aarch64.zig");

pub const ArchProcessor = aarch64.ArchProcessor;

pub const getProcessor = aarch64.getProcessor;
pub const earlyGetProcessor = aarch64.earlyGetProcessor;
pub const spinLoopHint = aarch64.spinLoopHint;

pub const init = struct {
    pub const EarlyOutputWriter = aarch64.init.EarlyOutputWriter;
    pub const setupEarlyOutput = aarch64.init.setupEarlyOutput;
    pub const getEarlyOutputWriter = aarch64.init.getEarlyOutputWriter;

    pub const prepareBootstrapProcessor = aarch64.init.prepareBootstrapProcessor;
    pub const prepareProcessor = aarch64.init.prepareProcessor;
    pub const loadProcessor = aarch64.init.loadProcessor;
};

pub const paging = struct {
    pub const PageTable = aarch64.paging.PageTable;
    pub const higher_half = aarch64.paging.higher_half;
    pub const standard_page_size = aarch64.paging.small_page_size;

    pub const largestPageSize = aarch64.paging.largestPageSize;

    pub const init = struct {};
};

pub const interrupts = struct {
    pub const interruptsEnabled = aarch64.interrupts.interruptsEnabled;
    pub const enableInterrupts = aarch64.interrupts.enableInterrupts;
    pub const disableInterrupts = aarch64.interrupts.disableInterrupts;
    pub const disableInterruptsAndHalt = aarch64.interrupts.disableInterruptsAndHalt;
};

pub const scheduling = struct {};
