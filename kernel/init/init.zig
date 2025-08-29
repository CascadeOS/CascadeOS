// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    time.tryCaptureStandardWallclockStartTime();

    // we need the direct map to be available as early as possible
    const early_memory_layout = mem.determineEarlyMemoryLayout();

    var context = try constructBootstrapContext();

    mem.initializeBootstrapFrameAllocator(context);

    // TODO: ensure all physical memory regions are mapped in the bootloader provided page table here, this would allow
    // us to switch to latter limine revisions and also allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    try acpi.earlyInitialize();

    Output.registerOutputs(context);

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ cascade.config.cascade_version ++ "\n");
    try Output.writer.flush();

    mem.logEarlyMemoryLayout(context, early_memory_layout);

    try acpi.logAcpiTables(context);

    log.debug(context, "initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts();

    log.debug(context, "capturing early system information", .{});
    arch.init.captureEarlySystemInformation(context);

    log.debug(context, "configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(context);

    log.debug(context, "initializing memory system", .{});
    try mem.initializeMemorySystem(context);

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
    try time.initializeTime(context);

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

    log.debug(context, "booting non-bootstrap executors", .{});
    try bootNonBootstrapExecutors();

    try initStage2(context, true);
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(context: *cascade.Context, is_bootstrap_executor: bool) !noreturn {
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

    try arch.scheduling.callTwoArgs(
        null,
        context.task().stack,
        @intFromPtr(context),
        @intFromBool(is_bootstrap_executor),
        struct {
            fn initStage3Wrapper(
                inner_context_addr: usize,
                inner_is_bootstrap_executor: usize,
            ) callconv(.c) noreturn {
                initStage3(
                    @ptrFromInt(inner_context_addr),
                    inner_is_bootstrap_executor != 0,
                ) catch |err| {
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
fn initStage3(context: *cascade.Context, bootstrap_executor: bool) !noreturn {
    if (bootstrap_executor) {
        Stage3Barrier.waitForAllNonBootstrapExecutors();

        log.debug(context, "loading standard interrupt handlers", .{});
        arch.interrupts.init.loadStandardInterruptHandlers();

        log.debug(context, "creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *cascade.Task = try .createKernelTask(context, .{
                .name = try .fromSlice("init stage 4"),
                .start_function = struct {
                    fn initStage4Wrapper(inner_context: *cascade.Context, _: usize, _: usize) noreturn {
                        initStage4(inner_context) catch |err| {
                            std.debug.panic("unhandled error: {t}", .{err});
                        };
                    }
                }.initStage4Wrapper,
                .arg1 = undefined,
                .arg2 = undefined,
                .kernel_task_type = .normal,
            });

            cascade.scheduler.lockScheduler(context);
            defer cascade.scheduler.unlockScheduler(context);

            cascade.scheduler.queueTask(context, init_stage4_task);
        }

        Stage3Barrier.stage3Complete();
    } else {
        Stage3Barrier.nonBootstrapExecutorReady();
        Stage3Barrier.waitForStage3Completion();
    }

    cascade.scheduler.lockScheduler(context);
    context.drop();
    unreachable;
}

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
fn initStage4(context: *cascade.Context) !noreturn {
    log.debug(context, "initializing PCI ECAM", .{});
    try cascade.pci.init.initializeECAM(context);

    log.debug(context, "initializing ACPI", .{});
    try acpi.initialize(context);

    {
        Output.globals.lock.lock(context);
        defer Output.globals.lock.unlock(context);
        try time.printInitializationTime(Output.writer);
        try Output.writer.flush();
    }

    cascade.scheduler.lockScheduler(context);
    context.drop();
    unreachable;
}

fn constructBootstrapContext() !*cascade.Context {
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
fn createExecutors(context: *cascade.Context) !struct { []cascade.Executor, *cascade.Executor } {
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
                fn bootFn(inner_context: *anyopaque) noreturn {
                    initStage2(
                        @ptrCast(@alignCast(inner_context)),
                        false,
                    ) catch |err| {
                        std.debug.panic("unhandled error: {t}", .{err});
                    };
                }
            }.bootFn,
        );
    }
}

const Stage3Barrier = struct {
    var non_bootstrap_executors_ready = std.atomic.Value(usize).init(0);
    var stage3_complete = std.atomic.Value(bool).init(false);

    /// Signal that the current executor has completed initialization.
    fn nonBootstrapExecutorReady() void {
        _ = non_bootstrap_executors_ready.fetchAdd(1, .release);
    }

    /// Signal that init stage 3 has completed.
    ///
    /// Called by the bootstrap executor only.
    fn stage3Complete() void {
        _ = stage3_complete.store(true, .release);
    }

    /// Wait for the bootstrap executor to signal that init stage 3 has completed.
    fn waitForStage3Completion() void {
        while (!stage3_complete.load(.acquire)) {
            arch.spinLoopHint();
        }
    }

    /// Wait for all other executors to signal that they have completed initialization.
    ///
    /// Called by the bootstrap executor only.
    fn waitForAllNonBootstrapExecutors() void {
        while (non_bootstrap_executors_ready.load(.acquire) != (cascade.globals.executors.len - 1)) {
            arch.spinLoopHint();
        }
    }
};

/// Exports APIs across components.
///
/// Exports:
///  - arch API needed by the boot component
///  - boot API needed by the cascade component
pub const exports = struct {
    pub const arch = struct {
        pub const current_arch = @import("arch").current_arch;
        pub const disableAndHalt = @import("arch").interrupts.disableAndHalt;
    };

    pub const boot = struct {
        pub const MemoryMapEntry = @import("boot").MemoryMap.Entry;
    };
};

pub const acpi = @import("acpi.zig");
pub const mem = @import("mem/mem.zig");
pub const time = @import("time.zig");
pub const Output = @import("output/Output.zig");

comptime {
    @import("boot").exportEntryPoints();
}

const arch = @import("arch");
const boot = @import("boot");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.init);
const std = @import("std");
