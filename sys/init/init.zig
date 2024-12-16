// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const time = @import("time.zig");

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

    kernel.executors = @as([*]kernel.Executor, @ptrCast(&globals.bootstrap_executor))[0..1];
    arch.init.prepareBootstrapExecutor(&globals.bootstrap_executor);
    arch.init.loadExecutor(&globals.bootstrap_executor);

    // now that the executor is loaded we can switch to the full init panic implementation and start logging
    kernel.debug.panic_impl = handlePanic;

    log.debug("bootstrap executor initialized", .{});

    try initStage2();
    core.panic("`init.initStage2` returned", null);
}

/// Stage 2 of kernel initialization.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
fn initStage2() !noreturn {
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

    log.debug("initializing virtual memory", .{});
    try initializeVirtualMemory();

    log.debug("initializing time", .{});
    try time.initializeTime();

    log.debug("initializing executors", .{});
    try initializeExecutors();

    try initStage3(kernel.getExecutor(.bootstrap));
    core.panic("`init.initStage3` returned", null);
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage3(executor: *kernel.Executor) !noreturn {
    // we can't log until we load the executor

    kernel.mem.globals.core_page_table.load();
    arch.init.loadExecutor(executor);

    log.debug("configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller", .{});
    arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt", .{});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.per_executor_interrupt_period);

    try arch.scheduling.callOneArgs(
        null,
        executor.scheduler_stack,
        executor,
        initStage4,
    );
    core.panic("`init.initStage4` returned", null);
}

/// Stage 4 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using their `scheduler_stack`.
fn initStage4(executor: *kernel.Executor) callconv(.c) noreturn {
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

    const interrupt_exclusion = kernel.sync.assertInterruptExclusion(true);
    const held = kernel.scheduler.lockScheduler(&interrupt_exclusion);
    kernel.scheduler.yield(held, .drop);

    core.panic("scheduler returned to init", null);
}

/// The log implementation during init.
pub fn handleLog(level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    var exclusion = kernel.sync.acquireInterruptExclusion();
    defer exclusion.release();

    var held = globals.early_output_lock.lock(&exclusion);
    defer held.unlock();

    // TODO: make the log output look nicer
    exclusion.getCurrentExecutor().format("", .{}, arch.init.early_output_writer) catch {};
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

    const executor = arch.rawGetCurrentExecutor();
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

fn initializeVirtualMemory() !void {
    log.debug("building core page table", .{});
    try buildCorePageTable();
    log.debug("initializing resource arenas and kernel heap", .{});
    try initializeResourceArenasAndHeap();
}

fn buildCorePageTable() !void {
    kernel.mem.globals.core_page_table = arch.paging.PageTable.create(
        try kernel.mem.physical.allocatePage(),
    );

    for (kernel.mem.globals.regions.constSlice()) |region| {
        switch (region.operation) {
            .full_map => {
                const physical_range = switch (region.type) {
                    .direct_map, .non_cached_direct_map => core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, region.range.size),
                    .executable_section, .readonly_section, .sdf_section, .writeable_section => core.PhysicalRange.fromAddr(
                        core.PhysicalAddress.fromInt(
                            region.range.address.value - kernel.mem.globals.physical_to_virtual_offset.value,
                        ),
                        region.range.size,
                    ),
                    .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                    .kernel_heap => core.panic("kernel heap region is full mapped", null),
                };

                const map_type: kernel.mem.MapType = switch (region.type) {
                    .executable_section => .{ .executable = true, .global = true },
                    .readonly_section, .sdf_section => .{ .global = true },
                    .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                    .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
                    .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                    .kernel_heap => core.panic("kernel heap region is full mapped", null),
                };

                arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    kernel.mem.globals.core_page_table,
                    region.range,
                    physical_range,
                    map_type,
                );
            },
            .top_level_map => arch.paging.init.fillTopLevel(
                kernel.mem.globals.core_page_table,
                region.range,
                .{ .global = true, .writeable = true },
            ),
        }
    }

    kernel.mem.globals.core_page_table.load();
}

fn initializeResourceArenasAndHeap() !void {
    kernel.mem.ResourceArena.globals.populateUnusedTags();

    try kernel.mem.ResourceArena.globals.tag_arena.init(
        "tags",
        arch.paging.standard_page_size.value,
        .{
            .populator = true,
            .source = .{ .arena = &kernel.mem.heap.globals.heap_arena },
        },
    );

    // heap
    {
        try kernel.mem.heap.globals.heap_address_space_arena.init(
            "heap_address_space",
            arch.paging.standard_page_size.value,
            .{ .populator = true },
        );

        try kernel.mem.heap.globals.heap_arena.init(
            "heap",
            arch.paging.standard_page_size.value,
            .{
                .populator = true,
                .source = .{
                    .arena = &kernel.mem.heap.globals.heap_address_space_arena,
                    .import = kernel.mem.heap._heapArenaImport,
                    .release = kernel.mem.heap._heapArenaRelease,
                },
            },
        );

        const heap_range = kernel.mem.getKernelRegion(.kernel_heap) orelse
            core.panic("no kernel heap", null);

        kernel.mem.heap.globals.heap_address_space_arena.addSpan(
            heap_range.address.value,
            heap_range.size.value,
        ) catch |err| {
            core.panicFmt(
                "failed to add heap range to `heap_address_space_arena`: {s}",
                .{@errorName(err)},
                @errorReturnTrace(),
            );
        };
    }

    // stacks
    {
        try kernel.Stack.globals.stack_arena.init(
            "stacks",
            arch.paging.standard_page_size.value,
            .{},
        );

        const stacks_range = kernel.mem.getKernelRegion(.kernel_stacks) orelse
            core.panic("no kernel stacks", null);

        kernel.Stack.globals.stack_arena.addSpan(
            stacks_range.address.value,
            stacks_range.size.value,
        ) catch |err| {
            core.panicFmt(
                "failed to add stack range to `stack_arena`: {s}",
                .{@errorName(err)},
                @errorReturnTrace(),
            );
        };
    }
}

/// Initialize the per executor data structures for all executors including the bootstrap executor.
///
/// Also wakes the non-bootstrap executors and jumps them to `initStage3`.
fn initializeExecutors() !void {
    try allocateAndPrepareExecutors();
    try bootNonBootstrapExecutors();
}

fn allocateAndPrepareExecutors() !void {
    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    const executors = try kernel.mem.heap.allocator.alloc(kernel.Executor, descriptors.count());

    var i: u32 = 0;
    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);
        log.debug("initializing {}", .{id});

        executor.* = .{
            .id = id,
            .scheduler_stack = try kernel.Stack.createStack(),
            .arch = undefined, // set by `arch.init.prepareExecutor`
        };

        if (id == .bootstrap) {
            globals.init_task.stack = executor.scheduler_stack;
            executor.current_task = &globals.init_task;
        }

        arch.init.prepareExecutor(executor);
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
            executor,
            struct {
                fn bootFn(user_data: *anyopaque) noreturn {
                    initStage3(@as(*kernel.Executor, @ptrCast(@alignCast(user_data)))) catch |err| {
                        core.panicFmt("unhandled error: {s}", .{@errorName(err)}, @errorReturnTrace());
                    };
                    core.panic("`init.initStage3` returned", null);
                }
            }.bootFn,
        );
    }
}

const globals = struct {
    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .scheduler_stack = undefined, // never used
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
        .current_task = &init_task,
    };

    var init_task: kernel.Task = .{
        ._name = kernel.Task.Name.fromSlice("init") catch unreachable,
        .state = .running,
        .stack = undefined, // never used, until it is set by `allocateAndPrepareExecutors`
    };

    var early_output_lock: kernel.sync.TicketSpinLock = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);
const acpi = @import("acpi");
const cascade_target = @import("cascade_target").arch;
const containers = @import("containers");
