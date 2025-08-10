// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const devicetree = @import("devicetree.zig");
pub const Output = @import("output/Output.zig");

/// Stage 1 of kernel initialization, entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function, using the bootloader provided stack.
pub fn initStage1() !noreturn {
    kernel.time.init.tryCaptureStandardWallclockStartTime();

    // we need the direct map to be available as early as possible
    kernel.mem.initialization.setEarlyOffsets(determineEarlyOffsets());

    // TODO: initialize the bootstrap frame allocator here then ensure all physical memory regions are mapped in the
    //       bootloader provided memory map, this would allow us to switch to latter limine revisions and also
    //       allow us to support unusual systems with MMIO above 4GiB

    // initialize ACPI tables early to allow discovery of debug output mechanisms
    if (boot.rsdp()) |rsdp_address| {
        try kernel.acpi.init.earlyInitialize(rsdp_address);
    }

    Output.registerOutputs();

    try Output.writer.writeAll(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");
    try Output.writer.flush();

    // log the offset determined by `kernel.mem.init.earlyDetermineOffsets`
    kernel.mem.initialization.logEarlyOffsets();

    try kernel.acpi.init.logAcpiTables();

    var bootstrap_init_task: kernel.Task = undefined;
    var current_task = &bootstrap_init_task;

    var bootstrap_executor_backing: kernel.Executor = .{
        .id = @enumFromInt(0),
        .current_task = current_task,
        .arch_specific = undefined, // set by `arch.init.prepareBootstrapExecutor`
        .scheduler_task = undefined, // not used
    };
    var bootstrap_executor = &bootstrap_executor_backing;

    try kernel.Task.init.initializeBootstrapInitTask(&bootstrap_init_task, bootstrap_executor);

    kernel.globals.executors = @as([*]kernel.Executor, @ptrCast(bootstrap_executor))[0..1];

    log.debug("loading bootstrap executor", .{});
    arch.init.prepareBootstrapExecutor(
        bootstrap_executor,
        boot.bootstrapArchitectureProcessorId(),
    );
    arch.init.loadExecutor(bootstrap_executor);

    log.debug("initializing early interrupts", .{});
    arch.interrupts.init.initializeEarlyInterrupts();

    log.debug("capturing early system information", .{});
    arch.init.captureEarlySystemInformation();

    log.debug("configuring per-executor system features", .{});
    arch.init.configurePerExecutorSystemFeatures(bootstrap_executor);

    log.debug("initializing memory system", .{});
    try kernel.mem.initialization.initializeMemorySystem(current_task, try collectMemorySystemInputs());

    log.debug("remapping init outputs", .{});
    try Output.remapOutputs(current_task);

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation(switch (arch.current_arch) {
        .x64 => .{ .x2apic_enabled = boot.x2apicEnabled() },
        else => .{},
    });

    log.debug("configuring global system features", .{});
    arch.init.configureGlobalSystemFeatures();

    log.debug("initializing time", .{});
    try kernel.time.init.initializeTime();

    log.debug("initializing interrupt routing", .{});
    try arch.interrupts.init.initializeInterruptRouting(current_task);

    log.debug("initializing kernel executors", .{});
    const executors, bootstrap_executor = try createExecutors();
    kernel.globals.executors = executors;
    current_task = bootstrap_executor.current_task;

    // ensure the bootstrap executor is re-loaded before we change panic and log modes
    arch.init.loadExecutor(bootstrap_executor);

    kernel.debug.setPanicMode(.init_panic);
    kernel.debug.log.setLogMode(.init_log);

    log.debug("booting non-bootstrap executors", .{});
    try bootNonBootstrapExecutors();

    try initStage2(current_task, true);
    unreachable;
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(current_task: *kernel.Task, is_bootstrap_executor: bool) !noreturn {
    arch.interrupts.disable(); // some executors don't have interrupts disabled on load

    kernel.mem.globals.core_page_table.load();
    const executor = current_task.state.running;
    arch.init.loadExecutor(executor);

    log.debug("configuring per-executor system features on {f}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller on {f}", .{executor.id});
    arch.init.initLocalInterruptController();

    log.debug("enabling per-executor interrupt on {f}", .{executor.id});
    kernel.time.per_executor_periodic.enableInterrupt(kernel.config.per_executor_interrupt_period);

    try arch.scheduling.callTwoArgs(
        null,
        current_task.stack,
        @intFromPtr(current_task),
        @intFromBool(is_bootstrap_executor),
        struct {
            fn initStage3Wrapper(
                inner_current_task_addr: usize,
                inner_is_bootstrap_executor: usize,
            ) callconv(.c) noreturn {
                initStage3(
                    @ptrFromInt(inner_current_task_addr),
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
fn initStage3(current_task: *kernel.Task, bootstrap_executor: bool) !noreturn {
    if (bootstrap_executor) {
        Stage3Barrier.waitForAllNonBootstrapExecutors();

        log.debug("loading standard interrupt handlers", .{});
        arch.interrupts.init.loadStandardInterruptHandlers();

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

/// Determine various offsets used by the kernel early in the boot process.
pub fn determineEarlyOffsets() kernel.mem.initialization.EarlyOffsets {
    const base_address = boot.kernelBaseAddress() orelse @panic("no kernel base address");

    const virtual_offset = core.Size.from(
        base_address.virtual.value - kernel.config.kernel_base_address.value,
        .byte,
    );

    const physical_to_virtual_offset = core.Size.from(
        base_address.virtual.value - base_address.physical.value,
        .byte,
    );

    const direct_map_size = direct_map_size: {
        const last_memory_map_entry = last_memory_map_entry: {
            var memory_map_iterator = boot.memoryMap(.backward) catch @panic("no memory map");
            break :last_memory_map_entry memory_map_iterator.next() orelse @panic("no memory map entries");
        };

        var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

        // We ensure that the lowest 4GiB are always mapped.
        const four_gib = core.Size.from(4, .gib);
        if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        direct_map_size.alignForwardInPlace(arch.paging.largest_page_size);

        break :direct_map_size direct_map_size;
    };

    const direct_map = core.VirtualRange.fromAddr(
        boot.directMapAddress() orelse @panic("direct map address not provided"),
        direct_map_size,
    );

    return .{
        .virtual_base_address = base_address.virtual,
        .virtual_offset = virtual_offset,
        .physical_to_virtual_offset = physical_to_virtual_offset,
        .direct_map = direct_map,
    };
}

pub fn collectMemorySystemInputs() !kernel.mem.initialization.MemorySystemInputs {
    const static = struct {
        var memory_map: core.containers.BoundedArray(
            exports.MemoryMapEntry,
            kernel.config.maximum_number_of_memory_map_entries,
        ) = .{};
    };

    var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

    var number_of_usable_pages: usize = 0;
    var number_of_usable_regions: usize = 0;

    while (memory_iter.next()) |entry| {
        try static.memory_map.append(entry);

        if (!entry.type.isUsable()) continue;
        if (entry.range.size.value == 0) continue;

        number_of_usable_regions += 1;

        number_of_usable_pages += std.math.divExact(
            usize,
            entry.range.size.value,
            arch.paging.standard_page_size.value,
        ) catch std.debug.panic(
            "memory map entry size is not a multiple of page size: {f}",
            .{entry},
        );
    }

    return .{
        .number_of_usable_pages = number_of_usable_pages,
        .number_of_usable_regions = number_of_usable_regions,
        .memory_map = static.memory_map.constSlice(),
    };
}

/// Creates an executor for each CPU.
///
/// Returns the slice of executors and the bootstrap executor.
fn createExecutors() !struct { []kernel.Executor, *kernel.Executor } {
    const current_task = kernel.Task.getCurrent();

    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    if (descriptors.count() > kernel.config.maximum_number_of_executors) {
        std.debug.panic(
            "number of executors '{d}' exceeds maximum '{d}'",
            .{ descriptors.count(), kernel.config.maximum_number_of_executors },
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
            .current_task = undefined, // set below by `Task.init.createAndAssignInitTask`
            .scheduler_task = undefined, // set below by `Task.init.initializeSchedulerTask`
        };

        try kernel.Task.init.createAndAssignInitTask(current_task, executor);
        try kernel.Task.init.initializeSchedulerTask(current_task, &executor.scheduler_task, executor);

        arch.init.prepareExecutor(
            executor,
            desc.architectureProcessorId(),
            current_task,
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
            kernel.globals.executors[i].current_task,
            struct {
                fn bootFn(user_data: *anyopaque) noreturn {
                    initStage2(
                        @ptrCast(@alignCast(user_data)),
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
        while (non_bootstrap_executors_ready.load(.acquire) != (kernel.globals.executors.len - 1)) {
            arch.spinLoopHint();
        }
    }
};

/// Exports the arch API needed by the boot component.
///
/// And the boot API needed by the kernel component.
pub const exports = struct {
    pub const current_arch = arch.current_arch;
    pub const disableAndHalt = arch.interrupts.disableAndHalt;

    pub const MemoryMapEntry = boot.MemoryMap.Entry;
};

comptime {
    @import("boot").exportEntryPoints();
}

const arch = @import("arch");
const boot = @import("boot");
const kernel = @import("kernel");

const core = @import("core");
const log = kernel.debug.log.scoped(.init);
const std = @import("std");
