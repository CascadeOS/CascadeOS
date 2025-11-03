// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

pub const Output = @import("output/Output.zig");

const log = cascade.debug.log.scoped(.init);

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    cascade.time.init.tryCaptureStandardWallclockStartTime();

    // we need basic memory layout information to be able to panic
    cascade.mem.init.determineEarlyMemoryLayout();

    var current_task = try constructBootstrapTask();

    // now that we have a current_task we can panic in a meaningful way
    cascade.debug.setPanicMode(.single_executor_init_panic);

    cascade.mem.phys.init.initializeBootstrapFrameAllocator(current_task);

    // TODO: ensure all physical memory regions are mapped in the bootloader provided page table here, this would allow
    // us to switch to latter limine revisions and also allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    try cascade.acpi.init.earlyInitialize();

    Output.registerOutputs(current_task);

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ cascade.config.cascade_version ++ "\n");
    try Output.writer.flush();

    cascade.mem.init.logEarlyMemoryLayout(current_task);

    try cascade.acpi.init.logAcpiTables(current_task);

    log.debug(current_task, "initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts(current_task);

    log.debug(current_task, "capturing early system information", .{});
    arch.init.captureEarlySystemInformation(current_task);

    log.debug(current_task, "configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(current_task);

    log.debug(current_task, "initializing memory system", .{});
    try cascade.mem.init.initializeMemorySystem(current_task);

    log.debug(current_task, "remapping init outputs", .{});
    try Output.remapOutputs(current_task);

    log.debug(current_task, "capturing system information", .{});
    try arch.init.captureSystemInformation(current_task, switch (arch.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        else => .{},
    });

    log.debug(current_task, "configuring global system features", .{});
    arch.init.configureGlobalSystemFeatures(current_task);

    log.debug(current_task, "initializing time", .{});
    try cascade.time.init.initializeTime(current_task);

    log.debug(current_task, "initializing interrupt routing", .{});
    try arch.interrupts.init.initializeInterruptRouting(current_task);

    log.debug(current_task, "initializing kernel executors", .{});
    const executors, const new_bootstrap_executor = try createExecutors(current_task);
    cascade.Executor.init.setExecutors(executors);
    current_task = new_bootstrap_executor.current_task;

    // ensure the bootstrap executor is re-loaded before we change panic and log modes
    arch.init.loadExecutor(current_task);

    cascade.debug.setPanicMode(.init_panic);
    cascade.debug.log.setLogMode(.init_log);

    if (executors.len > 1) {
        log.debug(current_task, "booting non-bootstrap executors", .{});
        try bootNonBootstrapExecutors();
    }

    try initStage2(current_task);
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(current_task: *Task) !noreturn {
    arch.interrupts.disable(); // some executors don't have interrupts disabled on load

    cascade.mem.kernelPageTable().load(current_task);
    const executor = current_task.known_executor.?;
    arch.init.loadExecutor(current_task);

    log.debug(current_task, "configuring per-executor system features on {f}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures(current_task);

    log.debug(current_task, "configuring local interrupt controller on {f}", .{executor.id});
    arch.init.initLocalInterruptController(current_task);

    log.debug(current_task, "enabling per-executor interrupt on {f}", .{executor.id});
    cascade.time.per_executor_periodic.enableInterrupt(cascade.config.per_executor_interrupt_period);

    try arch.scheduling.callNoSave(
        current_task.stack,
        initStage3,
        .{current_task},
    );
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors.
///
/// All executors are using their init task's stack.
fn initStage3(current_task: *Task) !noreturn {
    if (Stage3Barrier.start()) {
        log.debug(current_task, "loading standard interrupt handlers", .{});
        arch.interrupts.init.loadStandardInterruptHandlers(current_task);

        log.debug(current_task, "creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *Task = try .createKernelTask(current_task, .{
                .name = try .fromSlice("init stage 4"),
                .function = initStage4,
            });

            Task.Scheduler.lockScheduler(current_task);
            defer Task.Scheduler.unlockScheduler(current_task);

            Task.Scheduler.queueTask(current_task, init_stage4_task);
        }

        Stage3Barrier.complete();
    }

    Task.Scheduler.lockScheduler(current_task);
    current_task.drop();
    unreachable;
}

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
fn initStage4(current_task: *Task, _: usize, _: usize) !void {
    log.debug(current_task, "initializing PCI ECAM", .{});
    try cascade.pci.init.initializeECAM(current_task);

    log.debug(current_task, "initializing ACPI", .{});
    try cascade.acpi.init.initialize(current_task);

    Output.lock.lock(current_task);
    defer Output.lock.unlock(current_task);
    try cascade.time.init.printInitializationTime(Output.writer);
    try Output.writer.flush();
}

fn constructBootstrapTask() !*Task {
    const static = struct {
        var bootstrap_init_task: Task = undefined;
        var bootstrap_executor: cascade.Executor = .{
            .id = @enumFromInt(0),
            .current_task = &bootstrap_init_task,
            .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
            .scheduler_task = undefined, // not used
        };
    };

    try Task.init.initializeBootstrapInitTask(
        &static.bootstrap_init_task,
        &static.bootstrap_executor,
    );
    const current_task = &static.bootstrap_init_task;

    arch.init.prepareBootstrapExecutor(
        current_task,
        boot.bootstrapArchitectureProcessorId(),
    );
    arch.init.loadExecutor(current_task);

    cascade.Executor.init.setExecutors(@ptrCast(&static.bootstrap_executor));

    return current_task;
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors(current_task: *Task) !struct { []cascade.Executor, *cascade.Executor } {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > cascade.config.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), cascade.config.maximum_number_of_executors },
        );
    }

    log.debug(current_task, "initializing {} executors", .{descriptors.count()});

    const executors = try cascade.mem.heap.allocator.alloc(cascade.Executor, descriptors.count());

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();
    var opt_bootstrap_executor: ?*cascade.Executor = null;

    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &executors[i];

        executor.* = .{
            .id = @enumFromInt(i),
            .arch_specific = undefined, // set by `arch.init.prepareExecutor`
            .current_task = undefined, // set below by `Task.init.createAndAssignInitTask`
            .scheduler_task = undefined, // set below by `Task.init.initializeSchedulerTask`
        };

        try Task.init.createAndAssignInitTask(current_task, executor);
        try Task.init.initializeSchedulerTask(current_task, &executor.scheduler_task, executor);

        arch.init.prepareExecutor(
            current_task,
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
            cascade.Executor.executors()[i].current_task,
            struct {
                fn bootFn(inner_current_task: *anyopaque) !noreturn {
                    try initStage2(@ptrCast(@alignCast(inner_current_task)));
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
            while (number_of_executors_ready.load(.acquire) != (cascade.Executor.executors().len)) {
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
