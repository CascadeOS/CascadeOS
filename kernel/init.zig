// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var bootstrap_cpu: kernel.Cpu = .{
    .id = .bootstrap,
    .interrupt_disable_count = 1, // interrupts start disabled
    .idle_stack = undefined, // set at the beginning of `initStage1`
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

var bootstrap_idle_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !void {
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

    initStage2(&bootstrap_cpu);
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using the bootloader provided stack.
fn initStage2(cpu: *kernel.Cpu) noreturn {
    kernel.vmm.switchToKernelPageTable();
    kernel.arch.init.loadCpu(cpu);

    const idle_stack_pointer = cpu.idle_stack.pushReturnAddressWithoutChangingPointer(
        core.VirtualAddress.fromPtr(&initStage3),
    ) catch unreachable; // the idle stack is big enough to hold one return address

    log.debug("leaving bootloader provided stack", .{});
    kernel.arch.scheduling.changeStackAndReturn(idle_stack_pointer);
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using a normal kernel stack.
fn initStage3() noreturn {
    const cpu = kernel.arch.rawGetCpu(); // we know interrupts are disabled and we are not going to be preempted
    core.debugAssert(cpu.interrupt_disable_count == 1);

    core.panic("TODO: enter scheduler");
}
