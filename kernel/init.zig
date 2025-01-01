// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    // we need the direct map to be available as early as possible
    try kernel.vmm.init.determineOffsets();

    kernel.arch.init.setupEarlyOutput();

    kernel.debug.setPanicMode(.single_executor_init_panic);
    kernel.debug.log.setLogMode(.single_executor_init_log);

    kernel.arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

    kernel.vmm.init.logOffsets();

    var bootstrap_init_task: kernel.Task = .{
        ._name = kernel.Task.Name.fromSlice("bootstrap init") catch unreachable,
        .state = undefined, // set after declaration of `bootstrap_executor`
        .stack = undefined, // never used
        .interrupt_disable_count = .init(1), // interrupts are enabled by default
        .is_idle_task = false,
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

    log.debug("building memory layout", .{});
    try kernel.vmm.init.buildMemoryLayout();

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

    log.debug("initializing kernel heap", .{});
    try kernel.heap.init.initializeHeap();

    log.debug("initializing kernel stacks", .{});
    try kernel.Stack.init.initializeStacks();

    log.debug("initializing kernel executors", .{});
    kernel.executors = try createExecutors();

    // ensure the bootstrap executor is re-loaded before we change panic and log modes
    kernel.arch.init.loadExecutor(kernel.getExecutor(.bootstrap));

    kernel.debug.setPanicMode(.init_panic);
    kernel.debug.log.setLogMode(.init_log);

    log.debug("booting non-bootstrap executors", .{});
    try bootNonBootstrapExecutors();

    try initStage2(kernel.Task.getCurrent());
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(current_task: *kernel.Task) !noreturn {
    kernel.vmm.globals.core_page_table.load();
    const executor = current_task.state.running;
    kernel.arch.init.loadExecutor(executor);

    core.panic("NOT IMPLEMENTED", null);
}

fn createExecutors() ![]kernel.Executor {
    const current_task = kernel.Task.getCurrent();

    var descriptors = kernel.boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    log.debug("initializing {} executors", .{descriptors.count()});

    // TODO: these init tasks need to be freed after initialization
    const init_tasks = try kernel.heap.allocator.alloc(kernel.Task, descriptors.count());
    const executors = try kernel.heap.allocator.alloc(kernel.Executor, descriptors.count());

    var i: u32 = 0;
    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);

        const init_task = &init_tasks[i];

        init_task.* = .{
            ._name = .{}, // set below
            .state = .{ .running = executor },
            .stack = try kernel.Stack.createStack(current_task),
            .is_idle_task = false,
            .interrupt_disable_count = .init(1), // interrupts start disabled
        };

        try init_task._name.writer().print("init {}", .{i});

        executor.* = .{
            .id = id,
            .arch = undefined, // set by `arch.init.prepareExecutor`
            .current_task = init_task,
        };

        kernel.arch.init.prepareExecutor(executor, current_task);
    }

    return executors;
}

fn bootNonBootstrapExecutors() !void {
    var descriptors = kernel.boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;
    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &kernel.executors[i];
        if (executor.id == .bootstrap) continue;

        desc.boot(
            executor.current_task,
            struct {
                fn bootFn(user_data: *anyopaque) noreturn {
                    initStage2(@as(*kernel.Task, @ptrCast(@alignCast(user_data)))) catch |err| {
                        core.panicFmt(
                            "unhandled error: {s}",
                            .{@errorName(err)},
                            @errorReturnTrace(),
                        );
                    };
                }
            }.bootFn,
        );
    }
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init);
