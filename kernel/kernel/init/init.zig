// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const kernel = @import("kernel");
const Task = kernel.Task;
const core = @import("core");

pub const Output = @import("output/Output.zig");

const log = kernel.debug.log.scoped(.init);

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    kernel.time.init.tryCaptureStandardWallclockStartTime();

    // we need basic memory layout information to be able to panic
    kernel.mem.init.determineEarlyMemoryLayout();

    try constructAndLoadBootstrapExecutorAndTask();

    // now that we have a executor and task we can panic in a meaningful way
    kernel.debug.setPanicMode(.single_executor_init_panic);

    kernel.mem.phys.init.initializeBootstrapFrameAllocator();

    // TODO: ensure all physical memory regions are mapped in the bootloader provided page table here, this would allow
    // us to switch to latter limine revisions and also allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    try kernel.acpi.init.earlyInitialize();

    Output.registerOutputs();

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");
    try Output.writer.flush();

    kernel.mem.init.logEarlyMemoryLayout();

    try kernel.acpi.init.logAcpiTables();

    log.debug("initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    arch.init.captureEarlySystemInformation();

    log.debug("configuring per-executor system features with early system information", .{});
    arch.init.configurePerExecutorSystemFeatures();

    log.debug("initializing memory system", .{});
    try kernel.mem.init.initializeMemorySystem();

    log.debug("remapping init outputs", .{});
    try Output.remapOutputs();

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation(switch (arch.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        .arm, .riscv => .{},
    });

    log.debug("configuring per-executor system features with full system information", .{});
    arch.init.configurePerExecutorSystemFeatures();

    log.debug("configuring global system features", .{});
    arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try kernel.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try arch.interrupts.init.initializeInterruptRouting();

    log.debug("initializing tasks", .{});
    try Task.init.initializeTasks();

    log.debug("initializing user processes and threads", .{});
    try kernel.user.init.initialize();

    log.debug("initializing kernel executors", .{});
    const executors, const new_executor = try createExecutors();
    kernel.Executor.init.setExecutors(executors);

    // ensure the executor is re-loaded before we change panic and log modes
    arch.init.initExecutor(new_executor);
    new_executor.setCurrentTask(new_executor._current_task);

    // TODO: non-bootstrap executors have not yet had a chance to set their current tasks, so this is too early to switch panic mode
    kernel.debug.setPanicMode(.init_panic);
    kernel.debug.log.setLogMode(.init_log);

    if (executors.len > 1) {
        log.debug("booting non-bootstrap executors", .{});
        try bootNonBootstrapExecutors();
    }

    try initStage2(new_executor);
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(executor: *kernel.Executor) !noreturn {
    arch.interrupts.disable(); // some executors don't have interrupts disabled on load

    kernel.mem.kernelPageTable().load();
    arch.init.initExecutor(executor);
    executor.setCurrentTask(executor._current_task);

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures();

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.scheduler.per_executor_interrupt_period);

    try arch.scheduling.callNoSave(
        &executor._current_task.stack,
        .prepare(
            initStage3,
            .{},
        ),
    );
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors.
///
/// All executors are using their init task's stack.
fn initStage3() !noreturn {
    if (Stage3Barrier.start()) {
        log.debug("loading standard interrupt handlers", .{});
        arch.interrupts.init.loadStandardInterruptHandlers();

        log.debug("creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *Task = try .createKernelTask(
                .{
                    .name = try .fromSlice("init stage 4"),
                    .entry = .prepare(initStage4, .{}),
                },
            );

            const scheduler_handle: Task.SchedulerHandle = .get();
            defer scheduler_handle.unlock();

            scheduler_handle.queueTask(init_stage4_task);
        }

        Stage3Barrier.complete();
    }

    const scheduler_handle: Task.SchedulerHandle = .get();
    scheduler_handle.drop();
    unreachable;
}

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
fn initStage4() !void {
    log.debug("initializing PCI ECAM", .{});
    try kernel.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try kernel.acpi.init.initialize();

    Output.lock.lock();
    defer Output.lock.unlock();
    try kernel.time.init.printInitializationTime(Output.writer);
    try Output.writer.flush();
}

fn constructAndLoadBootstrapExecutorAndTask() !void {
    const static = struct {
        var bootstrap_init_task: Task = undefined;
        var bootstrap_executor: kernel.Executor = .{
            .id = @enumFromInt(0),
            ._current_task = undefined, // set by `setCurrentTask`
            .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
            .scheduler_task = undefined, // not used
        };
    };

    try Task.init.initializeBootstrapInitTask(
        &static.bootstrap_init_task,
        &static.bootstrap_executor,
    );

    arch.init.prepareBootstrapExecutor(
        &static.bootstrap_executor,
        boot.bootstrapArchitectureProcessorId(),
    );
    arch.init.initExecutor(&static.bootstrap_executor);
    static.bootstrap_executor.setCurrentTask(&static.bootstrap_init_task);

    kernel.Executor.init.setExecutors(@ptrCast(&static.bootstrap_executor));
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors() !struct { []kernel.Executor, *kernel.Executor } {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > kernel.config.executor.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), kernel.config.executor.maximum_number_of_executors },
        );
    }

    log.debug("initializing {} executors", .{descriptors.count()});

    const executors = try kernel.mem.heap.allocator.alloc(kernel.Executor, descriptors.count());

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();
    var opt_bootstrap_executor: ?*kernel.Executor = null;

    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &executors[i];

        executor.* = .{
            .id = @enumFromInt(i),
            .arch_specific = undefined, // set by `arch.init.prepareExecutor`
            ._current_task = undefined, // set below by `Task.init.createAndAssignInitTask`
            .scheduler_task = undefined, // set below by `Task.init.initializeSchedulerTask`
        };

        try Task.init.createAndAssignInitTask(executor);
        try Task.init.initializeSchedulerTask(&executor.scheduler_task, executor);

        arch.init.prepareExecutor(
            executor,
            desc.architectureProcessorId(),
        );

        if (desc.architectureProcessorId() == bootstrap_architecture_processor_id) {
            opt_bootstrap_executor = executor;
        }
    }

    return .{ executors, opt_bootstrap_executor.? };
}

fn bootNonBootstrapExecutors() !void {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;
    var i: u32 = 0;

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();

    while (descriptors.next()) |desc| : (i += 1) {
        if (desc.architectureProcessorId() == bootstrap_architecture_processor_id) continue;

        desc.boot(
            &kernel.Executor.executors()[i],
            struct {
                fn bootFn(inner_executor: *anyopaque) !noreturn {
                    try initStage2(@ptrCast(@alignCast(inner_executor)));
                }
            }.bootFn,
        );
    }
}

const Stage3Barrier = struct {
    var number_of_executors_ready: std.atomic.Value(usize) = .init(0);
    var stage3_complete = std.atomic.Value(bool).init(false);

    /// Returns true is the current executor is selected to run stage 3.
    ///
    /// All other executors are blocked until the stage 3 executor signals that it has completed.
    fn start() bool {
        const stage3_executor = number_of_executors_ready.fetchAdd(1, .acq_rel) == 0;

        if (stage3_executor) {
            // wait for all executors to signal that they are ready for stage 3 to occur
            while (number_of_executors_ready.load(.acquire) != (kernel.Executor.executors().len)) {
                arch.spinLoopHint();
            }
        } else {
            // wait for the stage 3 executor to signal that init stage 3 has completed.
            while (!stage3_complete.load(.acquire)) {
                arch.spinLoopHint();
            }
        }

        return stage3_executor;
    }

    /// Signal that init stage 3 has completed.
    ///
    /// Called by the stage 3 executor only.
    fn complete() void {
        _ = stage3_complete.store(true, .release);
    }
};
