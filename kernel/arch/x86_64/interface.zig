// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const x86_64 = @import("x86_64.zig");

pub const ArchCpu = struct {};

pub const spinLoopHint = x86_64.pause;

pub const getCpu = x86_64.getCpu;

pub const init = struct {
    pub const EarlyOutputWriter = x86_64.SerialPort.Writer;

    pub const setupEarlyOutput = x86_64.init.setupEarlyOutput;
    pub const getEarlyOutput = x86_64.init.getEarlyOutput;
    pub const loadCpu = x86_64.init.loadCpu;
};

pub const interrupts = struct {
    pub const disableInterruptsAndHalt = x86_64.disableInterruptsAndHalt;
    pub const disableInterrupts = x86_64.disableInterrupts;
};
