// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x86_64 = @import("x86_64.zig");

pub const ArchCpu = x86_64.ArchCpu;

pub const spinLoopHint = x86_64.pause;

pub const getCpu = x86_64.getCpu;

pub const init = struct {
    pub const EarlyOutputWriter = x86_64.SerialPort.Writer;

    pub const setupEarlyOutput = x86_64.init.setupEarlyOutput;
    pub const getEarlyOutput = x86_64.init.getEarlyOutput;

    pub const initInterrupts = x86_64.interrupts.init.initIdt;

    pub const prepareBootstrapCpu = x86_64.init.prepareBootstrapCpu;
    pub const loadCpu = x86_64.init.loadCpu;

    pub const captureSystemInformation = x86_64.init.captureSystemInformation;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = x86_64.disableInterruptsAndHalt;
    pub const disableInterrupts = x86_64.disableInterrupts;
};

pub const paging = struct {
    pub const standard_page_size = x86_64.PageTable.small_page_size;
    pub const all_page_sizes = &.{
        x86_64.PageTable.small_page_size,
        x86_64.PageTable.medium_page_size,
        x86_64.PageTable.large_page_size,
    };

    pub const higher_half = core.VirtualAddress.fromInt(0xffff800000000000);

    pub const PageTable = x86_64.PageTable;
};
