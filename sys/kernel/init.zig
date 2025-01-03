// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
///
/// The bootstrap executor is not initialized upon entry to this function so any features
/// requiring an initialized executor (like logging) must be avoided until initialization has been performed.
pub fn initStage1() !noreturn {
    // as the executor is not yet initialized, we can't log

    // we want the direct map to be available as early as possible
    try kernel.mem.init.earlyPartialMemoryLayout();

    arch.init.setupEarlyOutput();

    // now that early output is ready, we can provide a very simple panic implementation
    kernel.debug.panic_impl = struct {
        fn simplePanic(
            msg: []const u8,
            error_return_trace: ?*const std.builtin.StackTrace,
            return_address: usize,
        ) void {
            arch.interrupts.disableInterrupts();

            kernel.debug.formatting.printPanic(
                arch.init.early_output_writer,
                msg,
                error_return_trace,
                return_address,
            ) catch {};
        }
    }.simplePanic;

    arch.init.writeToEarlyOutput(
        comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n",
    );

    var bootstrap_init_task: kernel.Task = .{
        ._name = kernel.Task.Name.fromSlice("init bootstrap") catch unreachable,
        .state = undefined, // set after declaration of `bootstrap_executor`
        .stack = undefined, // never used
        .is_idle_task = false,
    };

    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .idle_task = undefined, // never used
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
        .current_task = &bootstrap_init_task,
        .interrupt_disable_count = 1, // interrupts start disabled
    };

    bootstrap_init_task.state = .{ .running = &bootstrap_executor };

    kernel.executors = @as([*]kernel.Executor, @ptrCast(&bootstrap_executor))[0..1];

    arch.init.prepareBootstrapExecutor(&bootstrap_executor);
    arch.init.loadExecutor(&bootstrap_executor);

    // now that the executor is loaded we can switch to the full init panic implementation and start logging
    kernel.debug.panic_impl = handlePanic;

    log.debug("bootstrap executor initialized", .{});

    try initStage2(&bootstrap_init_task);
    core.panic("`init.initStage2` returned", null);
}

/// Stage 2 of kernel initialization.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
fn initStage2(current_task: *kernel.Task) !noreturn {
    log.debug("initializing interrupts", .{});
    arch.init.initInterrupts();

    log.debug("building memory layout", .{});
    try kernel.mem.init.buildMemoryLayout();

    log.debug("initializing ACPI tables", .{});
    try kernel.acpi.init.initializeACPITables();

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation(switch (cascade_target) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        else => .{},
    });

    log.debug("configuring global system features", .{});
    try arch.init.configureGlobalSystemFeatures();

    log.debug("initializing physical memory", .{});
    try kernel.mem.physical.init.initializePhysicalMemory();

    log.debug("building core page table", .{});
    try kernel.mem.init.buildCorePageTable();

    log.debug("initializing kernel heap", .{});
    try kernel.mem.heap.init.initializeHeap(current_task);

    log.debug("initializing kernel stacks", .{});
    try kernel.Stack.init.initializeStacks(current_task);

    log.debug("initializing time", .{});
    try kernel.time.init.initializeTime();

    log.debug("initializing executors", .{});
    try initializeExecutors(current_task);

    try initStage3(kernel.getExecutor(.bootstrap).current_task);
    core.panic("`init.initStage3` returned", null);
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage3(current_task: *kernel.Task) !noreturn {
    kernel.mem.globals.core_page_table.load();
    const executor = current_task.state.running;

    arch.init.loadExecutor(executor);

    log.debug("configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller", .{});
    arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt", .{});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.per_executor_interrupt_period);

    try arch.scheduling.callOneArgs(
        null,
        current_task.stack,
        current_task,
        initStage4,
    );
    core.panic("`init.initStage4` returned", null);
}

/// Stage 4 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using their init task's stack.
fn initStage4(current_task: *kernel.Task) callconv(.c) noreturn {
    const barrier = struct {
        var executor_count = std.atomic.Value(usize).init(0);

        fn executorReady() void {
            _ = executor_count.fetchAdd(1, .monotonic);
        }

        fn waitForOthers() void {
            while (executor_count.load(.monotonic) != (kernel.executors.len - 1)) {
                arch.spinLoopHint();
            }
        }

        fn waitForAll() void {
            while (executor_count.load(.monotonic) != kernel.executors.len) {
                arch.spinLoopHint();
            }
        }
    };
    const executor = current_task.state.running;

    if (executor.id == .bootstrap) {
        barrier.waitForOthers();

        log.debug("loading standard interrupt handlers", .{});
        arch.init.loadStandardInterruptHandlers();

        arch.init.early_output_writer.print("initialization complete - time since boot: {}\n", .{
            kernel.time.wallclock.elapsed(@enumFromInt(0), kernel.time.wallclock.read()),
        }) catch {};
    }

    barrier.executorReady();
    barrier.waitForAll();

    _ = kernel.scheduler.lock(current_task);
    kernel.scheduler.yield(current_task, .drop);

    core.panic("scheduler returned to init", null);
}

/// The log implementation during init.
pub fn handleLog(current_task: *kernel.Task, level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    const incremented = current_task.incrementInterruptDisable();
    defer if (incremented) current_task.decrementInterruptDisable();

    globals.early_output_lock.lock(current_task);
    defer globals.early_output_lock.unlock(current_task);

    current_task.format("{}", .{}, arch.init.early_output_writer) catch {};
    arch.init.writeToEarlyOutput(level_and_scope);
    arch.init.early_output_writer.print(fmt, args) catch {};
}

/// The panic implementation during init.
///
/// Handles nested panics and multiple executors (only one panics at a time any others block).
///
/// This function expects that `arch.init.loadExecutor` has been called on the current executor.
fn handlePanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const static = struct {
        var panicking_executor = std.atomic.Value(kernel.Executor.Id).init(.none);
        var nested_panic_count = std.atomic.Value(usize).init(0);
    };

    arch.interrupts.disableInterrupts();

    const executor = arch.rawGetCurrentExecutor();

    executor.interrupt_disable_count += 1;
    executor.panicked.store(true, .release);

    if (static.panicking_executor.cmpxchgStrong(
        .none,
        executor.id,
        .acq_rel,
        .acquire,
    )) |panicking_executor_id| {
        if (panicking_executor_id != executor.id) return; // another executor is panicking
    }

    guarantee_exclusive_early_output_access: {
        globals.early_output_lock.poison();

        while (true) {
            const current_holder_id = @atomicLoad(
                kernel.Executor.Id,
                &globals.early_output_lock.current_holder,
                .acquire,
            );

            if (current_holder_id == executor.id) {
                // we already have the lock
                break :guarantee_exclusive_early_output_access;
            }

            if (current_holder_id == .none) {
                // the lock is poisoned, so we can just subsume control of the lock
                break :guarantee_exclusive_early_output_access;
            }

            const current_holder = kernel.getExecutor(current_holder_id);

            if (current_holder.panicked.load(.acquire)) {
                // the current holder has panicked but as we are the one panicking
                // we can just subsume control of the lock
                break :guarantee_exclusive_early_output_access;
            }

            arch.spinLoopHint();
        }
    }

    switch (static.nested_panic_count.fetchAdd(1, .acq_rel)) {
        0 => { // on first panic attempt to print the full panic message
            kernel.debug.formatting.printPanic(
                arch.init.early_output_writer,
                msg,
                error_return_trace,
                return_address,
            ) catch {};
        },
        1 => { // on second panic print a shorter message using only `writeToEarlyOutput`
            arch.init.writeToEarlyOutput("\nPANIC IN PANIC\n");
        },
        else => {}, // don't trigger any more panics
    }
}

/// Initialize the per executor data structures for all executors including the bootstrap executor.
///
/// Also wakes the non-bootstrap executors and jumps them to `initStage3`.
fn initializeExecutors(current_task: *kernel.Task) !void {
    try allocateAndPrepareExecutors(current_task);
    try bootNonBootstrapExecutors();
}

fn allocateAndPrepareExecutors(current_task: *kernel.Task) !void {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    globals.init_tasks = try kernel.mem.heap.allocator.alloc(kernel.Task, descriptors.count());

    const executors = try kernel.mem.heap.allocator.alloc(kernel.Executor, descriptors.count());

    var i: u32 = 0;
    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);
        log.debug("initializing {}", .{id});

        const init_task = &globals.init_tasks[i];

        init_task.* = .{
            ._name = .{}, // set below
            .state = .{ .running = executor },
            .stack = try kernel.Stack.createStack(current_task),
            .is_idle_task = false,
        };

        try init_task._name.writer().print("init {}", .{i});

        executor.* = .{
            .id = id,
            .arch = undefined, // set by `arch.init.prepareExecutor`
            .current_task = init_task,
            .interrupt_disable_count = 1, // interrupts start disabled
            .idle_task = .{
                ._name = .{}, // set below
                .state = .ready,
                .stack = try kernel.Stack.createStack(current_task),
                .is_idle_task = true,
            },
        };

        try executor.idle_task._name.writer().print("idle {}", .{i});

        arch.init.prepareExecutor(executor, current_task);
    }

    kernel.executors = executors;
}

fn bootNonBootstrapExecutors() !void {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;
    var i: u32 = 0;

    while (descriptors.next()) |desc| : (i += 1) {
        const executor = &kernel.executors[i];
        if (executor.id == .bootstrap) continue;

        desc.boot(
            executor.current_task,
            struct {
                fn bootFn(user_data: *anyopaque) noreturn {
                    initStage3(@as(*kernel.Task, @ptrCast(@alignCast(user_data)))) catch |err| {
                        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
                    };
                    core.panic("`init.initStage3` returned", null);
                }
            }.bootFn,
        );
    }
}

const globals = struct {
    var early_output_lock: kernel.sync.TicketSpinLock = .{};

    var init_tasks: []kernel.Task = undefined; // set by `allocateAndPrepareExecutors`
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);
const cascade_target = @import("cascade_target").arch;
const containers = @import("containers");
