// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var bootstrap_cpu: kernel.Cpu = .{
    .id = .bootstrap,
    .interrupt_disable_count = 1, // interrupts start disabled
    .idle_stack = undefined, // set at the beginning of `earlyInit`
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

var bootstrap_idle_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn earlyInit() !void {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    bootstrap_cpu.idle_stack = kernel.Stack.fromRange(
        core.VirtualRange.fromSlice(u8, &bootstrap_idle_stack),
        core.VirtualRange.fromSlice(u8, &bootstrap_idle_stack),
    );
    kernel.arch.init.prepareBootstrapCpu(&bootstrap_cpu);
    kernel.arch.init.loadCpu(&bootstrap_cpu);

    // ensure any interrupts are handled
    kernel.arch.init.initInterrupts();

    // now that early output is ready, we can switch to the init panic
    kernel.debug.init.loadInitPanic();

    if (kernel.arch.init.getEarlyOutput()) |early_output| {
        early_output.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n") catch {};
    }

    log.debug("capturing system information", .{});
    try kernel.vmm.init.buildMemoryLayout();
    try kernel.arch.init.captureSystemInformation();

    log.debug("preparing physical memory management", .{});
    try kernel.pmm.init.initPmm();

    log.debug("preparing virtual memory management", .{});
    try kernel.vmm.init.initVmm();
}
