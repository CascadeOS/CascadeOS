// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const riscv = @import("riscv.zig");

pub const ArchCpu = struct {};

pub const getCpu = riscv.getCpu;
pub const spinLoopHint = riscv.pause;
pub const halt = riscv.halt;

pub const init = struct {
    pub const EarlyOutputWriter = struct {};

    pub const setupEarlyOutput = riscv.init.setupEarlyOutput;
    pub const getEarlyOutput = riscv.init.getEarlyOutput;
    pub const initInterrupts = riscv.interrupts.init.initInterrupts;
    pub const prepareBootstrapCpu = riscv.init.prepareBootstrapCpu;
    pub const loadCpu = riscv.init.loadCpu;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = riscv.disableInterruptsAndHalt;
    pub const interruptsEnabled = riscv.interruptsEnabled;
    pub const disableInterrupts = riscv.disableInterrupts;
    pub const enableInterrupts = riscv.enableInterrupts;
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
