// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

pub const ArchCpu = x64.ArchCpu;

pub const spinLoopHint = x64.pause;
pub const getCpu = x64.getCpu;
pub const halt = x64.halt;

pub const init = struct {
    pub const EarlyOutputWriter = x64.SerialPort.Writer;

    pub const setupEarlyOutput = x64.init.setupEarlyOutput;
    pub const getEarlyOutput = x64.init.getEarlyOutput;

    pub const initInterrupts = x64.interrupts.init.initIdt;

    pub const prepareBootstrapCpu = x64.init.prepareBootstrapCpu;
    pub const loadCpu = x64.init.loadCpu;

    pub const captureSystemInformation = x64.init.captureSystemInformation;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = x64.disableInterruptsAndHalt;
    pub const interruptsEnabled = x64.interruptsEnabled;
    pub const disableInterrupts = x64.disableInterrupts;
    pub const enableInterrupts = x64.enableInterrupts;
};

pub const paging = struct {
    pub const standard_page_size = x64.PageTable.small_page_size;
    pub const all_page_sizes = &.{
        x64.PageTable.small_page_size,
        x64.PageTable.medium_page_size,
        x64.PageTable.large_page_size,
    };

    pub const higher_half = x64.paging.higher_half;

    pub const PageTable = x64.PageTable;

    pub const allocatePageTable = x64.paging.allocatePageTable;
    pub const switchToPageTable = x64.paging.switchToPageTable;
    pub const mapToPhysicalRange = x64.paging.mapToPhysicalRange;
    pub const unmapRange = x64.paging.unmapRange;

    pub const init = struct {
        pub const mapToPhysicalRangeAllPageSizes = x64.paging.init.mapToPhysicalRangeAllPageSizes;
        pub const getTopLevelRangeAndFillFirstLevel = x64.paging.init.getTopLevelRangeAndFillFirstLevel;
    };
};

pub const scheduling = struct {
    pub const changeStackAndReturn = x64.scheduling.changeStackAndReturn;
    pub const switchToIdle = x64.scheduling.switchToIdle;
    pub const switchToThreadFromIdle = x64.scheduling.switchToThreadFromIdle;
};
