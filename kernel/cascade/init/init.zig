// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const boot = @import("boot");
const core = @import("core");
const cascade = @import("cascade");
const Task = cascade.Task;

pub const Output = @import("output/Output.zig");

const log = cascade.debug.log.scoped(.init);

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    cascade.time.init.tryCaptureStandardWallclockStartTime();

    // we need basic memory layout information to be able to panic
    cascade.mem.init.determineEarlyMemoryLayout();

    try constructAndLoadBootstrapExecutorAndTask();

    // now that we have a executor and task we can panic in a meaningful way
    cascade.debug.setPanicMode(.single_executor_init_panic);

    cascade.mem.PhysicalPage.init.initializeBootstrapAllocator();

    // TODO: ensure all physical memory regions are mapped in the bootloader provided page table here, this would allow
    // us to switch to latter limine revisions and also allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    try cascade.acpi.init.earlyInitialize();

    Output.registerOutputsNoMemorySystem();

    cascade.mem.init.logEarlyMemoryLayout();

    try cascade.acpi.init.logAcpiTables();

    log.debug("initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    arch.init.captureEarlySystemInformation();

    log.debug("configuring per-executor system features with early system information", .{});
    arch.init.configurePerExecutorSystemFeatures();

    log.debug("initializing memory system", .{});
    try cascade.mem.init.initializeMemorySystem();

    Output.registerOutputsWithMemorySystem();

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
    try cascade.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try arch.interrupts.init.initializeInterruptRouting();

    log.debug("initializing tasks", .{});
    try Task.init.initializeTasks();

    log.debug("initializing user processes and threads", .{});
    try cascade.user.init.initialize();

    log.debug("initializing kernel executors", .{});
    const executors, const new_executor = try createExecutors();
    cascade.Executor.init.setExecutors(executors);

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
fn initStage2(executor: *cascade.Executor) !noreturn {
    const static = struct {
        var stage2_barrier: StageBarrier = .{};
    };

    arch.interrupts.disable(); // some executors don't have interrupts disabled on load

    cascade.mem.kernelPageTable().load();
    arch.init.initExecutor(executor);
    executor.setCurrentTask(executor._current_task);

    if (static.stage2_barrier.start()) {
        cascade.debug.setPanicMode(.init_panic);
        cascade.debug.log.setLogMode(.init_log);

        static.stage2_barrier.complete();
    }

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures();

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    cascade.time.per_executor_periodic.enableInterrupt(cascade.config.scheduler.per_executor_interrupt_period);

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
    const static = struct {
        var stage3_barrier: StageBarrier = .{};
    };

    if (static.stage3_barrier.start()) {
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

        static.stage3_barrier.complete();
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
    try cascade.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try cascade.acpi.init.initialize();

    log.debug("starting first user process", .{});
    const hello_world_process: *cascade.user.Process = try .create(.{ .name = try .fromSlice("hello world") });
    defer hello_world_process.decrementReferenceCount();

    const hello_world_main_thread = try hello_world_process.createThread(
        .{ .entry = .prepare(loadHelloWorld, .{}) },
    );

    const scheduler_handle: Task.SchedulerHandle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&hello_world_main_thread.task);

    Output.lock.lock();
    defer Output.lock.unlock();
    try cascade.time.init.printInitializationTime(Output.writer);
    try Output.writer.flush();
}

fn constructAndLoadBootstrapExecutorAndTask() !void {
    const static = struct {
        var bootstrap_init_task: Task = undefined;
        var bootstrap_executor: cascade.Executor = .{
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

    cascade.Executor.init.setExecutors(@ptrCast(&static.bootstrap_executor));
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors() !struct { []cascade.Executor, *cascade.Executor } {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > cascade.config.executor.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), cascade.config.executor.maximum_number_of_executors },
        );
    }

    log.debug("initializing {} executors", .{descriptors.count()});

    const executors = try cascade.mem.heap.allocator.alloc(cascade.Executor, descriptors.count());

    const bootstrap_architecture_processor_id = boot.bootstrapArchitectureProcessorId();
    var opt_bootstrap_executor: ?*cascade.Executor = null;

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
            &cascade.Executor.executors()[i],
            struct {
                fn bootFn(inner_executor: *anyopaque) !noreturn {
                    try initStage2(@ptrCast(@alignCast(inner_executor)));
                }
            }.bootFn,
        );
    }
}

const StageBarrier = struct {
    number_of_executors_ready: std.atomic.Value(usize) = .init(0),
    stage_complete: std.atomic.Value(bool) = .init(false),

    /// Returns true if the current executor is selected to run the stage.
    ///
    /// All other executors are blocked until the stage executor signals that it has completed.
    fn start(barrier: *StageBarrier) bool {
        const stage_executor = barrier.number_of_executors_ready.fetchAdd(1, .acq_rel) == 0;

        if (stage_executor) {
            // wait for all executors to signal that they are ready for the stage to occur
            const number_of_executors = cascade.Executor.executors().len;
            while (barrier.number_of_executors_ready.load(.acquire) != number_of_executors) {
                arch.spinLoopHint();
            }
        } else {
            // wait for the stage executor to signal that the stage has completed
            while (!barrier.stage_complete.load(.acquire)) {
                arch.spinLoopHint();
            }
        }

        return stage_executor;
    }

    /// Signal that the stage has completed.
    ///
    /// Called by the stage executor only.
    fn complete(barrier: *StageBarrier) void {
        _ = barrier.stage_complete.store(true, .release);
    }
};

fn loadHelloWorld() !void {
    const hello_world_elf = @embedFile("hello_world");

    const current_task: Task.Current = .get();
    const process: *cascade.user.Process = .from(current_task.task);

    const header = try cascade.user.elf.Header.parse(hello_world_elf);

    const entry_point = blk: {
        const possible_entry_point: cascade.VirtualAddress = .from(header.entry);
        if (possible_entry_point.getType() != .user) return error.InvalidEntryPoint;
        break :blk possible_entry_point.toUser();
    };

    const program_header_table: []const u8 = blk: {
        const program_header_table_location = header.programHeaderTableLocation();
        break :blk hello_world_elf[program_header_table_location.base..][0..program_header_table_location.length];
    };

    var iter = header.loadableRegionIterator(program_header_table);

    // map all loadable segments read write - this allows the address space to merge the entries
    // TODO: this only makes sense for an embedded program, not if it is loaded from disk
    while (try iter.next()) |loadable_region| {
        _ = try process.address_space.map(.{
            .base = loadable_region.virtual_range.address.toVirtualAddress(),
            .size = loadable_region.virtual_range.size,
            .protection = .read_write,
            .type = .zero_fill,
        });
    }

    // copy the regions from the elf into the address space
    {
        current_task.incrementEnableAccessToUserMemory();
        defer current_task.decrementEnableAccessToUserMemory();

        iter.reset();

        while (try iter.next()) |loadable_region| {
            if (loadable_region.source_length == 0) continue;

            const mapped_slice = loadable_region.virtual_range.byteSlice();

            @memcpy(
                mapped_slice[loadable_region.destination_offset..][0..loadable_region.source_length],
                hello_world_elf[loadable_region.source_base..][0..loadable_region.source_length],
            );
        }
    }

    iter.reset();

    // change each regions protections as per the elf
    while (try iter.next()) |loadable_region| {
        if (loadable_region.protection == .read_write) continue;

        try process.address_space.changeProtection(
            loadable_region.virtual_range.toVirtualRange(),
            .{
                .both = .{
                    .protection = loadable_region.protection,
                    .max_protection = loadable_region.protection,
                },
            },
        );
    }

    const user_stack = try process.address_space.map(.{
        .size = .from(64, .kib),
        .protection = .read_write,
        .type = .zero_fill,
    });

    arch.user.enterUserspace(.{
        .entry_point = entry_point,
        .stack_pointer = user_stack.toUser().after(),
    });
}
