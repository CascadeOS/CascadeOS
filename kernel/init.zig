// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

var bootstrap_cpu: kernel.Cpu = .{
    .id = .bootstrap,
    .scheduler_stack = undefined, // set at the beginning of `initStage1`
    .arch = undefined, // set by `arch.init.prepareBootstrapCpu`
};

var bootstrap_scheduler_stack: [kernel.config.kernel_stack_size.value]u8 align(16) = undefined;

const log = kernel.log.scoped(.init);

/// Entry point from bootloader specific code.
///
/// Only the bootstrap cpu executes this function.
pub fn initStage1() !noreturn {
    // get output up and running as soon as possible
    kernel.arch.init.setupEarlyOutput();

    bootstrap_cpu.scheduler_stack = kernel.Stack.fromRange(
        core.VirtualRange.fromSlice(u8, &bootstrap_scheduler_stack),
        core.VirtualRange.fromSlice(u8, &bootstrap_scheduler_stack),
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

    log.debug("build kernel memory layout", .{});
    try kernel.vmm.init.buildMemoryLayout();

    log.debug("initializing ACPI tables", .{});
    kernel.acpi.init.initializeACPITables();

    log.debug("capturing system information", .{});
    try kernel.arch.init.captureSystemInformation();

    log.debug("preparing physical memory management", .{});
    try kernel.pmm.init.initPmm();

    log.debug("preparing virtual memory management", .{});
    try kernel.vmm.init.initVmm();

    log.debug("initializing kernel heaps", .{});
    try kernel.heap.init.initHeaps();

    log.debug("configuring global system features", .{});
    kernel.arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    kernel.time.init.initTime();

    log.debug("initializing cpus", .{});
    kernel.system.init.initializeCpus(initStage2);

    initStage2(kernel.system.getCpu(.bootstrap));
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using the bootloader provided stack.
fn initStage2(cpu: *kernel.Cpu) noreturn {
    kernel.vmm.switchToPageTable(kernel.vmm.kernel_page_table);
    kernel.arch.init.loadCpu(cpu);

    log.debug("configuring cpu-local system features", .{});
    kernel.arch.init.configureSystemFeaturesForCurrentCpu(cpu);

    log.debug("configuring local interrupt controller", .{});
    kernel.arch.init.initLocalInterruptController(cpu);

    log.debug("initializing scheduler", .{});
    kernel.scheduler.init.initScheduler();

    kernel.arch.scheduling.callZeroArgs(null, cpu.scheduler_stack, initStage3) catch |err| {
        core.panicFmt("unable to call initStage3: {s}", .{@errorName(err)});
    };
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all cpus, including the bootstrap cpu.
///
/// All cpus are using a normal kernel stack.
fn initStage3() callconv(.C) noreturn {
    const interrupt_exclusion = kernel.sync.assertInterruptExclusion();

    log.debug("entering scheduler on {}", .{interrupt_exclusion.cpu});
    const scheduler_held = kernel.scheduler.acquireScheduler();

    interrupt_exclusion.release();

    kernel.scheduler.yield(scheduler_held, .drop);
    unreachable;
}
