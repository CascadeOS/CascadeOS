// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

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
    cascade.time.init.captureStartTime();

    // we need basic memory layout information to be able to panic
    const early_memory_layout = cascade.mem.init.determineEarlyMemoryLayout();

    try loadBootstrapExecutorAndTask();

    // now that we have an executor and task we can panic in a meaningful way
    cascade.debug.setPanicMode(.single_executor_init_panic);

    cascade.mem.PhysicalPage.init.initializeBootstrapAllocator();

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    const acpi_tables = try cascade.acpi.init.earlyInitialize();

    Output.registerOutputs(.early);

    // no that we have basic output we can log the early memory layout and ACPI tables
    early_memory_layout.log();
    try acpi_tables.log();

    log.debug("initializing early interrupts", .{});
    arch.Interrupt.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    const capture_system_information_options: arch.init.CaptureSystemInformationOptions = switch (arch.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        .arm, .riscv => .{},
    };
    try arch.init.captureSystemInformation(.early, capture_system_information_options);

    log.debug("configuring per-executor system features with early system information", .{});
    arch.Executor.init.configurePerExecutorSystemFeatures();

    log.debug("initializing memory system", .{});
    try cascade.mem.init.initializeMemorySystem();

    // now the memory system is initialized we can attempt to register outputs again
    Output.registerOutputs(.full);

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation(.full, capture_system_information_options);

    log.debug("configuring per-executor system features with full system information", .{});
    arch.Executor.init.configurePerExecutorSystemFeatures();

    log.debug("configuring global system features", .{});
    arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try cascade.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try arch.Interrupt.init.initializeInterruptRouting();

    log.debug("initializing tasks", .{});
    try cascade.Task.init.initializeTasks();

    log.debug("initializing user processes and threads", .{});
    try cascade.user.init.initialize();

    log.debug("initializing kernel executors", .{});
    const executors, const new_bootstrap_executor = try createExecutors();
    cascade.Executor.init.setExecutors(executors);

    if (executors.len > 1) {
        log.debug("booting non-bootstrap executors", .{});
        try bootNonBootstrapExecutors();
    }

    try initStage2(new_bootstrap_executor);
    comptime unreachable;
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

    arch.Executor.current.disableInterrupts(); // some executors don't have interrupts disabled on load

    cascade.mem.kernelPageTable().load();
    arch.Executor.init.initialize(executor);
    executor.setCurrentTask(executor._current_task);

    if (static.stage2_barrier.start()) {
        cascade.debug.setPanicMode(.init_panic);
        cascade.debug.log.setLogMode(.init_log);

        static.stage2_barrier.complete();
    }

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    arch.Executor.init.configurePerExecutorSystemFeatures();

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    arch.Executor.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    cascade.time.per_executor_periodic.enableInterrupt(cascade.config.scheduler.per_executor_interrupt_period);

    try arch.Task.callNoSave(
        &executor._current_task.stack,
        &core.TypeErasedCall.prepare(
            initStage3,
            .{},
        ),
    );
    comptime unreachable;
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
        arch.Interrupt.init.loadStandardInterruptHandlers();

        log.debug("creating and scheduling init stage 4 task", .{});
        {
            const init_stage4_task: *cascade.Task = try .createKernelTask(
                .{
                    .name = try .fromSlice("init stage 4"),
                    .entry = &core.TypeErasedCall.prepare(initStage4, .{}),
                },
            );

            const scheduler_handle: cascade.Task.Scheduler.Handle = .get();
            defer scheduler_handle.unlock();

            scheduler_handle.queueTask(init_stage4_task);
        }

        static.stage3_barrier.complete();
    }

    const scheduler_handle: cascade.Task.Scheduler.Handle = .get();
    scheduler_handle.terminate();
    comptime unreachable;
}

/// Stage 4 of kernel initialization.
///
/// This function is executed in a fully scheduled kernel task with interrupts enabled.
fn initStage4() !void {
    log.debug("initializing PCI ECAM", .{});
    try cascade.pci.init.initializeECAM();

    log.debug("initializing ACPI", .{});
    try cascade.acpi.init.initialize();

    try cascade.time.init.printInitializationTime();

    log.debug("starting first user process", .{});
    const hello_world_process: *cascade.user.Process = try .create(
        .{ .name = try .fromSlice("hello world") },
    );
    defer hello_world_process.decrementReferenceCount();

    const hello_world_main_thread = try hello_world_process.createThread(
        .{ .entry = &core.TypeErasedCall.prepare(loadHelloWorld, .{}) },
    );

    const scheduler_handle: cascade.Task.Scheduler.Handle = .get();
    defer scheduler_handle.unlock();
    scheduler_handle.queueTask(&hello_world_main_thread.task);
}

fn loadBootstrapExecutorAndTask() !void {
    const static = struct {
        var bootstrap_init_task: cascade.Task = undefined;
        var bootstrap_executor: cascade.Executor = .{
            .id = .bootstrap,
            ._current_task = undefined, // set by `setCurrentTask`
            .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
            .scheduler = undefined, // not used
        };
    };

    try cascade.Task.init.initializeBootstrapInitTask(
        &static.bootstrap_init_task,
        &static.bootstrap_executor,
    );

    arch.Executor.init.prepareBootstrap(
        &static.bootstrap_executor,
        boot.bootstrapArchitectureProcessorId(),
    );
    arch.Executor.init.initialize(&static.bootstrap_executor);

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
            .scheduler = .{
                .task = undefined, // set below by `Task.init.initializeSchedulerTask`
            },
        };

        try cascade.Task.init.createAndAssignInitTask(executor);
        try cascade.Task.init.initializeSchedulerTask(&executor.scheduler.task, executor);

        arch.Executor.init.prepare(
            executor,
            desc.architectureProcessorId(),
        );

        if (desc.architectureProcessorId() == bootstrap_architecture_processor_id) {
            opt_bootstrap_executor = executor;
        }
    }

    return .{ executors, opt_bootstrap_executor orelse @panic("unable to determine bootstrap executor") };
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
                arch.Executor.current.spinLoopHint();
            }
        } else {
            // wait for the stage executor to signal that the stage has completed
            while (!barrier.stage_complete.load(.acquire)) {
                arch.Executor.current.spinLoopHint();
            }
        }

        return stage_executor;
    }

    /// Signal that the stage has completed.
    ///
    /// Called by the stage executor only.
    fn complete(barrier: *StageBarrier) void {
        barrier.stage_complete.store(true, .release);
    }
};

fn loadHelloWorld() !void {
    const hello_world_elf: cascade.KernelVirtualRange = .fromSlice(u8, @embedFile("hello_world"));

    const current_task: cascade.Task.Current = .get();
    const thread: *cascade.user.Thread = .from(current_task.task);
    const address_space = &thread.process.address_space;

    const header = try cascade.user.elf.Header.parse(hello_world_elf);

    const entry_point = switch (header.entry.tagged()) {
        .user => |user| user,
        else => return error.InvalidEntryPoint,
    };

    const program_header_table = blk: {
        const program_header_table_location = header.programHeaderTableLocation();
        break :blk hello_world_elf.subslice(program_header_table_location.offset, program_header_table_location.size);
    };

    // map all loadable segments read write - this allows the address space to merge the entries
    // TODO: this only makes sense for an embedded program, not if it is loaded from disk
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            _ = try address_space.map(.{
                .base = loadable_region.virtual_range.address,
                .size = loadable_region.virtual_range.size,
                .protection = .{ .read = true, .write = true },
                .max_protection = .all,
                .type = .zero_fill,
            });
        }
    }

    // copy the regions from the elf into the address space
    {
        const source_range = hello_world_elf.toVirtualRange();

        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            try cascade.mem.safe.memcpy(.{
                .destination = loadable_region.virtual_range.subslice(
                    loadable_region.destination_offset,
                    loadable_region.source_length,
                ),
                .source = source_range.subslice(
                    loadable_region.source_base,
                    loadable_region.source_length,
                ),
            });
        }
    }

    // change each regions protections as per the elf
    {
        var iter = header.loadableRegionIterator(program_header_table);

        while (try iter.next()) |loadable_region| {
            try address_space.changeProtection(
                loadable_region.virtual_range,
                .{
                    .both = .{
                        .protection = loadable_region.protection,
                        .max_protection = loadable_region.protection,
                    },
                },
            );
        }
    }

    try thread.start(entry_point);
    comptime unreachable;
}
