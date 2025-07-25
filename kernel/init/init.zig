// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    kernel.time.init.tryCaptureStandardWallclockStartTime();

    // we need the direct map to be available as early as possible
    kernel.mem.init.earlyDetermineOffsets();

    // TODO: initialize the bootstrap frame allocator here then ensure all physical memory regions are mapped in the
    //       bootloader provided memory map, this would allow us to switch to latter limine revisions and also
    //       allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    kernel.acpi.init.initializeACPITables();

    Output.registerOutputs();

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");
    try Output.writer.flush();

    // log the offset determined by `kernel.mem.init.earlyDetermineOffsets`
    kernel.mem.init.logEarlyOffsets();

    try kernel.acpi.init.logAcpiTables();

    var bootstrap_init_task: kernel.Task = undefined;

    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .current_task = &bootstrap_init_task,
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
        .utility_task = undefined, // never used
    };

    try kernel.Task.init.initializeBootstrapInitTask(&bootstrap_init_task, &bootstrap_executor);

    kernel.executors = @as([*]kernel.Executor, @ptrCast(&bootstrap_executor))[0..1];

    log.debug("loading bootstrap executor", .{});
    kernel.arch.init.prepareBootstrapExecutor(
        &bootstrap_executor,
        kernel.boot.bootstrapArchitectureProcessorId(),
    );
    kernel.arch.init.loadExecutor(&bootstrap_executor);

    log.debug("initializing early interrupts", .{});
    kernel.arch.interrupts.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    kernel.arch.init.captureEarlySystemInformation();

    log.debug("configuring per-executor system features", .{});
    kernel.arch.init.configurePerExecutorSystemFeatures(&bootstrap_executor);

    log.debug("initializing memory system", .{});
    try kernel.mem.init.initializeMemorySystem(&bootstrap_init_task);

    log.debug("remapping init outputs", .{});
    try Output.remapOutputs(&bootstrap_init_task);

    log.debug("capturing system information", .{});
    try kernel.arch.init.captureSystemInformation(switch (kernel.config.cascade_arch) {
        .x64 => .{ .x2apic_enabled = kernel.boot.x2apicEnabled() },
        else => .{},
    });

    log.debug("configuring global system features", .{});
    try kernel.arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try kernel.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try kernel.arch.interrupts.init.initializeInterruptRouting(&bootstrap_init_task);

    log.debug("initializing kernel executors", .{});
    kernel.executors = try createExecutors();

    // ensure the bootstrap executor is re-loaded before we change panic and log modes
    kernel.arch.init.loadExecutor(kernel.getExecutor(.bootstrap));

    kernel.debug.setPanicMode(.init_panic);
    kernel.debug.log.setLogMode(.init_log);

    log.debug("booting non-bootstrap executors", .{});
    try bootNonBootstrapExecutors();

    try initStage2(kernel.Task.getCurrent());
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(current_task: *kernel.Task) !noreturn {
    kernel.mem.globals.core_page_table.load();
    const executor = current_task.state.running;
    kernel.arch.init.loadExecutor(executor);

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    kernel.arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    kernel.arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.per_executor_interrupt_period);

    try kernel.arch.scheduling.callOneArgs(
        null,
        current_task.stack,
        @intFromPtr(current_task),
        struct {
            fn initStage3Wrapper(inner_current_task_addr: usize) callconv(.c) noreturn {
                initStage3(@ptrFromInt(inner_current_task_addr)) catch |err| {
                    std.debug.panic("unhandled error: {t}", .{err});
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
        Stage3Barrier.waitForAllNonBootstrapExecutors();

        log.debug("loading standard interrupt handlers", .{});
        kernel.arch.interrupts.init.loadStandardInterruptHandlers();

        log.debug("creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *kernel.Task = try .createKernelTask(current_task, .{
                .name = try .fromSlice("init stage 4"),
                .start_function = struct {
                    fn initStage4Wrapper(inner_current_task: *kernel.Task, _: usize, _: usize) noreturn {
                        initStage4(inner_current_task) catch |err| {
                            std.debug.panic("unhandled error: {t}", .{err});
                        };
                    }
                }.initStage4Wrapper,
                .arg1 = undefined,
                .arg2 = undefined,
            });

            kernel.scheduler.lockScheduler(current_task);
            defer kernel.scheduler.unlockScheduler(current_task);

            kernel.scheduler.queueTask(current_task, init_stage4_task);
        }

        Stage3Barrier.stage3Complete();
    } else {
        Stage3Barrier.nonBootstrapExecutorReady();
        Stage3Barrier.waitForStage3Completion();
    }

    _ = kernel.scheduler.lockScheduler(current_task);
    current_task.drop();
    unreachable;
}

fn initStage4(current_task: *kernel.Task) !noreturn {
    log.debug("initializing PCI ECAM", .{});
    try kernel.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try kernel.acpi.init.initialize();

    try kernel.acpi.init.finializeInitialization();

    {
        Output.globals.lock.lock(current_task);
        defer Output.globals.lock.unlock(current_task);

        try Output.writer.print(
            "initialization complete - time since kernel start: {f} - time since system start: {f}\n",
            .{
                kernel.time.wallclock.elapsed(
                    kernel.time.wallclock.kernel_start,
                    kernel.time.wallclock.read(),
                ),
                kernel.time.wallclock.elapsed(
                    .zero,
                    kernel.time.wallclock.read(),
                ),
            },
        );
        try Output.writer.flush();
    }

    _ = kernel.scheduler.lockScheduler(current_task);
    current_task.drop();
    unreachable;
}

fn createExecutors() ![]kernel.Executor {
    const current_task = kernel.Task.getCurrent();

    var descriptors = kernel.boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > kernel.config.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), kernel.config.maximum_number_of_executors },
        );
    }

    log.debug("initializing {} executors", .{descriptors.count()});

    const executors = try kernel.mem.heap.allocator.alloc(kernel.Executor, descriptors.count());

    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &executors[i];

        executor.* = .{
            .id = @enumFromInt(i),
            .arch = undefined, // set by `arch.init.prepareExecutor`
            .current_task = undefined, // set below by `Task.init.createAndAssignInitTask`
            .utility_task = undefined, // set below by `Task.init.initializeUtilityTask`
        };

        try kernel.Task.init.createAndAssignInitTask(current_task, executor);
        try kernel.Task.init.initializeUtilityTask(current_task, &executor.utility_task, executor);

        kernel.arch.init.prepareExecutor(
            executor,
            desc.architectureProcessorId(),
            current_task,
        );
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
                    initStage2(@ptrCast(@alignCast(user_data))) catch |err| {
                        std.debug.panic("unhandled error: {t}", .{err});
                    };
                }
            }.bootFn,
        );
    }
}

pub const devicetree = @import("devicetree.zig");
pub const Output = @import("output/Output.zig");

const Stage3Barrier = struct {
    var non_bootstrap_executors_ready = std.atomic.Value(usize).init(0);
    var stage3_complete = std.atomic.Value(bool).init(false);

    /// Signal that the current executor has completed initialization.
    fn nonBootstrapExecutorReady() void {
        std.debug.assert(kernel.Task.getCurrent().state.running.id != .bootstrap);
        _ = non_bootstrap_executors_ready.fetchAdd(1, .release);
    }

    /// Signal that init stage 3 has completed.
    ///
    /// Called by the bootstrap executor only.
    fn stage3Complete() void {
        std.debug.assert(kernel.Task.getCurrent().state.running.id == .bootstrap);
        _ = stage3_complete.store(true, .release);
    }

    /// Wait for the bootstrap executor to signal that init stage 3 has completed.
    fn waitForStage3Completion() void {
        std.debug.assert(kernel.Task.getCurrent().state.running.id != .bootstrap);
        while (!stage3_complete.load(.acquire)) {
            kernel.arch.spinLoopHint();
        }
    }

    /// Wait for all other executors to signal that they have completed initialization.
    ///
    /// Called by the bootstrap executor only.
    fn waitForAllNonBootstrapExecutors() void {
        std.debug.assert(kernel.Task.getCurrent().state.running.id == .bootstrap);
        while (non_bootstrap_executors_ready.load(.acquire) != (kernel.executors.len - 1)) {
            kernel.arch.spinLoopHint();
        }
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const log = kernel.debug.log.scoped(.init);
