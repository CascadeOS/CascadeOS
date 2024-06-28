// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arm64 = @import("arm64.zig");

pub const ArchCpu = struct {};

pub const getCpu = arm64.getCpu;
pub const spinLoopHint = arm64.isb;
pub const halt = arm64.halt;

pub const init = struct {
    pub const EarlyOutputWriter = struct {};

    pub const setupEarlyOutput = arm64.init.setupEarlyOutput;
    pub const getEarlyOutput = arm64.init.getEarlyOutput;
    pub const initInterrupts = arm64.interrupts.init.initInterrupts;
    pub const prepareBootstrapCpu = arm64.init.prepareBootstrapCpu;
    pub const loadCpu = arm64.init.loadCpu;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = arm64.disableInterruptsAndHalt;
    pub const interruptsEnabled = arm64.interruptsEnabled;
    pub const disableInterrupts = arm64.disableInterrupts;
    pub const enableInterrupts = arm64.enableInterrupts;
};

pub const paging = struct {
    pub const small_page_size = core.Size.from(4, .kib);
    pub const medium_page_size = core.Size.from(2, .mib);
    pub const large_page_size = core.Size.from(1, .gib);

    pub const standard_page_size = small_page_size;

    pub const all_page_sizes = &.{
        small_page_size,
        medium_page_size,
        large_page_size,
    };
    pub const largest_higher_half_virtual_address = core.VirtualAddress.fromInt(0xffffffffffffffff);
    pub const PageTable = struct {};

    pub const higher_half = core.VirtualAddress.fromInt(0xffff800000000000);

    pub const init = struct {};
};

pub const scheduling = struct {};
