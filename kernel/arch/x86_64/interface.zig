// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const x86_64 = @import("x86_64.zig");

pub const ArchProcessor = x86_64.ArchProcessor;

pub const getProcessor = x86_64.getProcessor;
pub const earlyGetProcessor = x86_64.earlyGetProcessor;
pub const spinLoopHint = x86_64.pause;
pub const halt = x86_64.halt;

pub const init = struct {
    pub const EarlyOutputWriter = x86_64.init.EarlyOutputWriter;
    pub const setupEarlyOutput = x86_64.init.setupEarlyOutput;
    pub const getEarlyOutputWriter = x86_64.init.getEarlyOutputWriter;

    pub const prepareBootstrapProcessor = x86_64.init.prepareBootstrapProcessor;
    pub const prepareProcessor = x86_64.init.prepareProcessor;
    pub const loadProcessor = x86_64.init.loadProcessor;
    pub const earlyArchInitialization = x86_64.init.earlyArchInitialization;
    pub const captureSystemInformation = x86_64.init.captureSystemInformation;
    pub const configureGlobalSystemFeatures = x86_64.init.configureGlobalSystemFeatures;
    pub const initLocalInterruptController = x86_64.apic.init.initApicOnProcessor;
    pub const registerArchitecturalTimeSources = x86_64.init.registerArchitecturalTimeSources;
    pub const configureSystemFeaturesForCurrentProcessor = x86_64.init.configureSystemFeaturesForCurrentProcessor;
};

pub const paging = struct {
    pub const PageTable = x86_64.PageTable;
    pub const higher_half = x86_64.paging.higher_half;
    pub const standard_page_size = x86_64.PageTable.small_page_size;

    pub const largestPageSize = x86_64.paging.largestPageSize;
    pub const allocatePageTable = x86_64.paging.allocatePageTable;
    pub const mapToPhysicalRangeAllPageSizes = x86_64.paging.mapToPhysicalRangeAllPageSizes;
    pub const switchToPageTable = x86_64.paging.switchToPageTable;
    pub const mapToPhysicalRange = x86_64.paging.mapToPhysicalRange;
    pub const unmap = x86_64.paging.unmap;

    pub const init = struct {
        pub const getTopLevelRangeAndFillFirstLevel = x86_64.paging.init.getTopLevelRangeAndFillFirstLevel;
    };
};

pub const interrupts = struct {
    pub const interruptsEnabled = x86_64.interruptsEnabled;
    pub const enableInterrupts = x86_64.enableInterrupts;
    pub const disableInterrupts = x86_64.disableInterrupts;
    pub const disableInterruptsAndHalt = x86_64.disableInterruptsAndHalt;

    pub const setTaskPriority = x86_64.apic.setTaskPriority;
    pub const panicInterruptOtherCores = x86_64.apic.panicInterruptOtherCores;
};

pub const scheduling = struct {
    pub const changeStackAndReturn = x86_64.scheduling.changeStackAndReturn;
    pub const switchToIdle = x86_64.scheduling.switchToIdle;
    pub const switchToThreadFromIdle = x86_64.scheduling.switchToThreadFromIdle;
    pub const switchToThreadFromThread = x86_64.scheduling.switchToThreadFromThread;
};
