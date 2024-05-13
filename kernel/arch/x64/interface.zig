// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

pub const ArchCpu = x64.ArchCpu;

pub const spinLoopHint = x64.pause;
pub const halt = x64.halt;

pub const init = struct {
    pub const EarlyOutputWriter = x64.SerialPort.Writer;

    pub const setupEarlyOutput = x64.init.setupEarlyOutput;
    pub const getEarlyOutput = x64.init.getEarlyOutput;
    pub const initInterrupts = x64.interrupts.init.initIdt;
    pub const prepareBootstrapCpu = x64.init.prepareBootstrapCpu;
    pub const loadCpu = x64.init.loadCpu;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = x64.disableInterruptsAndHalt;
};

pub const paging = struct {
    pub const standard_page_size = x64.PageTable.small_page_size;
    pub const higher_half = x64.paging.higher_half;
};
