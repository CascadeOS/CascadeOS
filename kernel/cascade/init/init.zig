// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");
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

    var context = try constructBootstrapContext();

    // now that we have a context we can panic in a meaningful way
    cascade.debug.setPanicMode(.single_executor_init_panic);

    cascade.mem.phys.init.initializeBootstrapFrameAllocator(context);

    // TODO: ensure all physical memory regions are mapped in the bootloader provided page table here, this would allow
    // us to switch to latter limine revisions and also allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    try cascade.acpi.init.earlyInitialize();

    Output.registerOutputs(context);

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ cascade.config.cascade_version ++ "\n");
    try Output.writer.flush();

    cascade.mem.init.logEarlyMemoryLayout(context);

    try cascade.acpi.init.logAcpiTables(context);

    log.debug(context, "initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts();

    log.debug(context, "capturing early system information", .{});
    arch.init.captureEarlySystemInformation(context);

    log.debug(context, "configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(context);

    log.debug(context, "initializing memory system", .{});
    try cascade.mem.init.initializeMemorySystem(context);

    log.debug(context, "remapping init outputs", .{});
    try Output.remapOutputs(context);

    log.debug(context, "capturing system information", .{});
    try arch.init.captureSystemInformation(context, switch (arch.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        else => .{},
    });

    log.debug(context, "configuring global system features", .{});
    arch.init.configureGlobalSystemFeatures(context);

    log.debug(context, "initializing time", .{});
    try cascade.time.init.initializeTime(context);

    log.debug(context, "initializing interrupt routing", .{});
    try arch.interrupts.init.initializeInterruptRouting(context);

    log.debug(context, "initializing kernel executors", .{});
    const executors, const new_bootstrap_executor = try createExecutors(context);
    cascade.globals.executors = executors;
    context = &new_bootstrap_executor.current_task.context;

    // ensure the bootstrap executor is re-loaded before we change panic and log modes
    arch.init.loadExecutor(context);

    cascade.debug.setPanicMode(.init_panic);
    cascade.debug.log.setLogMode(.init_log);

    if (executors.len > 1) {
        log.debug(context, "booting non-bootstrap executors", .{});
        try bootNonBootstrapExecutors();
    }

    try initStage2(context);
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(context: *cascade.Task.Context) !noreturn {
    arch.interrupts.disable(); // some executors don't have interrupts disabled on load

    cascade.mem.globals.core_page_table.load();
    const executor = context.executor.?;
    arch.init.loadExecutor(context);

    log.debug(context, "configuring per-executor system features on {f}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures(context);

    log.debug(context, "configuring local interrupt controller on {f}", .{executor.id});
    arch.init.initLocalInterruptController();

    log.debug(context, "enabling per-executor interrupt on {f}", .{executor.id});
    cascade.time.per_executor_periodic.enableInterrupt(cascade.config.per_executor_interrupt_period);

    try arch.scheduling.callOneArg(
        null,
        context.task().stack,
        @intFromPtr(context),
        struct {
            fn initStage3Wrapper(inner_context_addr: usize) callconv(.c) noreturn {
                initStage3(@ptrFromInt(inner_context_addr)) catch |err| {
                    std.debug.panic("unhandled error: {t}", .{err});
                };
            }
        }.initStage3Wrapper,
    );
    unreachable;
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors.
///
/// All executors are using their init task's stack.
fn initStage3(context: *cascade.Task.Context) !noreturn {
    if (Stage3Barrier.start()) {
        log.debug(context, "loading standard interrupt handlers", .{});
        arch.interrupts.init.loadStandardInterruptHandlers();

        log.debug(context, "creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *cascade.Task = try .createKernelTask(context, .{
                .name = try .fromSlice("init stage 4"),
                .function = initStage4,
            });

            cascade.scheduler.lockScheduler(context);
            defer cascade.scheduler.unlockScheduler(context);

            cascade.scheduler.queueTask(context, init_stage4_task);
        }

        Stage3Barrier.complete();
    }

    cascade.scheduler.lockScheduler(context);
    context.drop();
    unreachable;
}

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
fn initStage4(context: *cascade.Task.Context, _: usize, _: usize) !void {
    log.debug(context, "initializing PCI ECAM", .{});
    try cascade.pci.init.initializeECAM(context);

    log.debug(context, "initializing ACPI", .{});
    try cascade.acpi.init.initialize(context);

    Output.globals.lock.lock(context);
    defer Output.globals.lock.unlock(context);
    try cascade.time.init.printInitializationTime(Output.writer);
    try Output.writer.flush();
}

fn constructBootstrapContext() !*cascade.Task.Context {
    const static = struct {
        var bootstrap_init_task: cascade.Task = undefined;
        var bootstrap_executor: cascade.Executor = .{
            .id = @enumFromInt(0),
            .current_task = &bootstrap_init_task,
            .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
            .scheduler_task = undefined, // not used
        };
    };

    const context = try cascade.Task.init.initializeBootstrapInitTask(
        &static.bootstrap_init_task,
        &static.bootstrap_executor,
    );

    arch.init.prepareBootstrapExecutor(
        context,
        boot.bootstrapArchitectureProcessorId(),
    );
    arch.init.loadExecutor(context);

    cascade.globals.executors = @ptrCast(&static.bootstrap_executor);

    return context;
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors(context: *cascade.Task.Context) !struct { []cascade.Executor, *cascade.Executor } {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > cascade.config.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), cascade.config.maximum_number_of_executors },
        );
    }

    log.debug(context, "initializing {} executors", .{descriptors.count()});

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

        try cascade.Task.init.createAndAssignInitTask(context, executor);
        try cascade.Task.init.initializeSchedulerTask(context, &executor.scheduler_task, executor);

        arch.init.prepareExecutor(
            context,
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
            &cascade.globals.executors[i].current_task.context,
            struct {
                fn bootFn(inner_context: *anyopaque) !noreturn {
                    try initStage2(@ptrCast(@alignCast(inner_context)));
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
            while (number_of_executors_ready.load(.acquire) != (cascade.globals.executors.len)) {
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
