// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var bootstrap_cpu: kernel.Cpu = .{
    .id = .bootstrap,
    .interrupt_disable_count = 1, // interrupts start disabled
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn earlyInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // ensure any interrupts are handled
    kernel.arch.init.initInterrupts();

    // now that early output is ready, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n") catch {};
    }

    try kernel.vmm.init.buildEarlyMemoryLayout();
    try kernel.arch.init.captureSystemInformation();

    try kernel.pmm.init.initPmm();
}
