// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !void {
    // we need the direct map to be available as early as possible
    try kernel.vmm.init.buildMemoryLayout();

    kernel.arch.init.setupEarlyOutput();

    kernel.debug.setPanicMode(.single_executor_init_panic);
    kernel.log.setLogMode(.single_executor_init_log);

    kernel.arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    kernel.vmm.init.logMemoryLayout();

    var bootstrap_init_task: kernel.Task = .{
        ._name = kernel.Task.Name.fromSlice("bootstrap init") catch unreachable,
        .state = undefined, // set after declaration of `bootstrap_executor`
        .stack = undefined, // never used
        .interrupt_disable_count = .init(1), // interrupts are enabled by default
    };

    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .current_task = &bootstrap_init_task,
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
    };

    bootstrap_init_task.state = .{ .running = &bootstrap_executor };

    kernel.executors = @as([*]kernel.Executor, @ptrCast(&bootstrap_executor))[0..1];

    log.debug("loading bootstrap executor", .{});
    kernel.arch.init.prepareBootstrapExecutor(&bootstrap_executor);
    kernel.arch.init.loadExecutor(&bootstrap_executor);

    log.debug("initializing interrupts", .{});
    kernel.arch.init.initializeInterrupts();

    log.debug("capturing early system information", .{});
    try kernel.arch.init.captureEarlySystemInformation();

    log.debug("configuring per-executor system features", .{});
    kernel.arch.init.configurePerExecutorSystemFeatures(&bootstrap_executor);

    log.debug("initializing physical memory", .{});
    try kernel.pmm.init.initializePhysicalMemory();

    log.debug("building core page table", .{});
    try kernel.vmm.init.buildCorePageTable();

    log.debug("loading core page table", .{});
    kernel.vmm.globals.core_page_table.load();

    log.debug("initializing ACPI tables", .{});
    try kernel.acpi.init.initializeACPITables();

    log.debug("capturing system information", .{});
    try kernel.arch.init.captureSystemInformation(switch (kernel.config.cascade_target) {
        .x64 => .{ .x2apic_enabled = kernel.boot.x2apicEnabled() },
        else => .{},
    });

    log.debug("configuring global system features", .{});
    try kernel.arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try kernel.time.init.initializeTime();

    kernel.debug.setPanicMode(.init_panic);
    core.panic("NOT IMPLEMENTED", null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.log.scoped(.init);
