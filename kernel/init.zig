// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

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
        .id = @enumFromInt(0),
        ._name = kernel.Task.Name.fromSlice("bootstrap init") catch unreachable,
        .state = undefined, // set after declaration of `bootstrap_executor`
        .stack = undefined, // never used
        .interrupt_disable_count = .init(1), // interrupts are enabled by default
    };

    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .current_task = &bootstrap_init_task,
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
        .idle_task = undefined, // never used
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

    log.debug("configuring per-executor system features on {}", .{executor.id});
    kernel.arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller on {}", .{executor.id});
    kernel.arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {}", .{executor.id});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.per_executor_interrupt_period);

    try kernel.arch.scheduling.callOneArgs(
        null,
        current_task.stack,
        current_task,
        struct {
            fn initStage3Wrapper(inner_current_task: *kernel.Task) callconv(.C) noreturn {
                initStage3(inner_current_task) catch |err| {
                    core.panicFmt(
                        "unhandled error: {s}",
                        .{@errorName(err)},
                        @errorReturnTrace(),
                    );
                };
            }
        }.initStage3Wrapper,
    );
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using their init task's stack.
fn initStage3(current_task: *kernel.Task) !noreturn {
    const executor = current_task.state.running;

    if (executor.id == .bootstrap) {
        Barrier.waitForOthers();

        log.debug("initializing PCI ECAM", .{});
        try kernel.pci.init.initializeECAM();

        log.debug("initializing ACPI", .{});
        try kernel.acpi.init.initialize();

        try kernel.acpi.init.finializeInitialization();

        // as others are waiting, we can safely print
        kernel.arch.init.early_output_writer.print("initialization complete - time since boot: {}\n", .{
            kernel.time.wallclock.elapsed(.zero, kernel.time.wallclock.read()),
        }) catch {};
    }

    Barrier.executorReady();
    Barrier.waitForAll();

    if (true) core.panic("NOT IMPLEMENTED", null);

    current_task.decrementInterruptDisable();
}

fn createExecutors() ![]kernel.Executor {
    const current_task = kernel.Task.getCurrent();

    var descriptors = kernel.boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    log.debug("initializing {} executors", .{descriptors.count()});

    // TODO: these init tasks need to be freed after initialization
    const init_tasks = try kernel.heap.allocator.alloc(kernel.Task, descriptors.count());
    const executors = try kernel.heap.allocator.alloc(kernel.Executor, descriptors.count());

    var i: u32 = 0;
    var task_id: u32 = 1; // `1` as `0` is the bootstrap task

    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);

        const init_task = &init_tasks[i];

        init_task.* = .{
            .id = @enumFromInt(task_id),
            ._name = .{}, // set below
            .state = .{ .running = executor },
            .stack = try kernel.Stack.createStack(current_task),
        };
        task_id += 1;

        try init_task._name.writer().print("init {}", .{i});

        executor.* = .{
            .id = id,
            .arch = undefined, // set by `arch.init.prepareExecutor`
            .current_task = init_task,
            .idle_task = .{
                .id = @enumFromInt(task_id),
                ._name = .{}, // set below
                .state = .ready,
                .stack = try kernel.Stack.createStack(current_task),
                .is_idle_task = true,
            },
        };
        task_id += 1;

        try executor.idle_task._name.writer().print("idle {}", .{i});

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

const Barrier = struct {
    var executor_count = std.atomic.Value(usize).init(0);

    fn executorReady() void {
        _ = executor_count.fetchAdd(1, .release);
    }

    fn waitForOthers() void {
        while (executor_count.load(.acquire) != (kernel.executors.len - 1)) {
            kernel.arch.spinLoopHint();
        }
    }

    fn waitForAll() void {
        while (executor_count.load(.acquire) != kernel.executors.len) {
            kernel.arch.spinLoopHint();
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init);
