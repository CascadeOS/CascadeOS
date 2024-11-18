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
    try earlyPartialMemoryLayout();

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
    arch.init.initInterrupts(&handleInterrupt);

    log.debug("building memory layout", .{});
    try buildMemoryLayout();

    log.debug("initializing ACPI tables", .{});
    try initializeACPITables();

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation();

    log.debug("configuring global system features", .{});
    try arch.init.configureGlobalSystemFeatures();

    log.debug("initializing physical memory", .{});
    try initializePMM(&globals.pmm);

    log.debug("initializing virtual memory", .{});
    try initializeVirtualMemory(&globals.pmm, &globals.memory_layout);

    log.debug("initializing time", .{});
    try time.initializeTime();

    log.debug("initializing executors", .{});
    try initializeExecutors(&globals.pmm, &globals.stack_allocator);

    try initStage3(kernel.getExecutor(.bootstrap));
    core.panic("`init.initStage3` returned", null);
}

/// Stage 3 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage3(executor: *kernel.Executor) !noreturn {
    kernel.vmm.core_page_table.load();
    arch.init.loadExecutor(executor);

    log.debug("configuring per-executor system features on {}", .{executor.id});
    arch.init.configurePerExecutorSystemFeatures(executor);

    log.debug("configuring local interrupt controller on {}", .{executor.id});
    arch.init.initLocalInterruptController();

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

        arch.init.early_output_writer.print("initialization complete - time since boot: {}\n", .{
            kernel.time.wallclock.elapsed(@enumFromInt(0), kernel.time.wallclock.read()),
        }) catch {};

        barrier.executorReady();
    } else {
        barrier.executorReady();
        barrier.waitForAll();
    }

    const interrupt_exclusion = kernel.sync.assertInterruptExclusion(true);

    const held = kernel.scheduler.lockScheduler(interrupt_exclusion);
    kernel.scheduler.yield(held, .drop);

    core.panic("scheduler returned to init", null);
}

/// The log implementation during init.
pub fn handleLog(level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    var exclusion = kernel.sync.acquireInterruptExclusion();
    defer exclusion.release();

    var held = globals.early_output_lock.lock(exclusion);
    defer held.unlock();

    arch.init.writeToEarlyOutput(level_and_scope);
    arch.init.early_output_writer.print(fmt, args) catch {};
}

/// The interrupt handler during init.
fn handleInterrupt(
    context: arch.interrupts.InterruptContext,
    _: kernel.sync.InterruptExclusion,
) noreturn {
    core.panicFmt("unexpected interrupt with context:\n{}", .{context}, null);
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

/// Ensures that the kernel base address, virtual offset and the direct map are set up.
///
/// Called very early so cannot log.
fn earlyPartialMemoryLayout() !void {
    const base_address = boot.kernelBaseAddress() orelse return error.NoKernelBaseAddress;
    kernel.memory_layout.globals.virtual_base_address = base_address.virtual;

    kernel.memory_layout.globals.virtual_offset = core.Size.from(
        base_address.virtual.value - kernel.config.kernel_base_address.value,
        .byte,
    );

    kernel.memory_layout.globals.physical_to_virtual_offset = core.Size.from(
        base_address.virtual.value - base_address.physical.value,
        .byte,
    );

    const direct_map_size = direct_map_size: {
        const last_memory_map_entry = last_memory_map_entry: {
            var memory_map_iterator = boot.memoryMap(.backward) orelse return error.NoMemoryMap;
            break :last_memory_map_entry memory_map_iterator.next() orelse return error.NoMemoryMapEntries;
        };

        var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

        // We ensure that the lowest 4GiB are always mapped.
        const four_gib = core.Size.from(4, .gib);
        if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

        // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
        direct_map_size.alignForwardInPlace(arch.paging.largest_page_size);

        break :direct_map_size direct_map_size;
    };

    kernel.memory_layout.globals.direct_map = core.VirtualRange.fromAddr(
        boot.directMapAddress() orelse return error.DirectMapAddressNotProvided,
        direct_map_size,
    );
}

fn buildMemoryLayout() !void {
    const memory_layout = blk: {
        globals.memory_layout = .{
            .regions = &kernel.memory_layout.globals.regions,
        };
        break :blk &globals.memory_layout;
    };

    log.debug("registering kernel sections", .{});
    try registerKernelSections(memory_layout);
    log.debug("registering direct maps", .{});
    try registerDirectMaps(memory_layout);
    log.debug("registering heaps", .{});
    const kernel_stacks_range = try registerHeaps(memory_layout);

    globals.stack_allocator = .{ .kernel_stacks_heap_range = kernel_stacks_range };

    if (log.levelEnabled(.debug)) {
        log.debug("kernel memory layout:", .{});

        for (memory_layout.regions.constSlice()) |region| {
            log.debug("\t{}", .{region});
        }
    }
}

fn registerKernelSections(memory_layout: *MemoryLayout) !void {
    const linker_symbols = struct {
        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    const sdf_slice = try kernel.debug.sdfSlice();
    const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

    const sections: []const struct {
        core.VirtualAddress,
        core.VirtualAddress,
        kernel.memory_layout.Region.Type,
    } = &.{
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__text_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__text_end),
            .executable_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__rodata_end),
            .readonly_section,
        },
        .{
            core.VirtualAddress.fromPtr(&linker_symbols.__data_start),
            core.VirtualAddress.fromPtr(&linker_symbols.__data_end),
            .writeable_section,
        },
        .{
            sdf_range.address,
            sdf_range.endBound(),
            .sdf_section,
        },
    };

    for (sections) |section| {
        const start_address = section[0];
        const end_address = section[1];
        const region_type = section[2];

        std.debug.assert(end_address.greaterThan(start_address));

        const virtual_range: core.VirtualRange = .fromAddr(
            start_address,
            core.Size.from(end_address.value - start_address.value, .byte)
                .alignForward(arch.paging.standard_page_size),
        );

        try memory_layout.append(.{
            .range = virtual_range,
            .type = region_type,
            .operation = .full_map,
        });
    }
}

fn registerDirectMaps(memory_layout: *MemoryLayout) !void {
    const direct_map = kernel.memory_layout.globals.direct_map;

    // does the direct map range overlap a pre-existing region?
    for (memory_layout.regions.constSlice()) |region| {
        if (region.range.containsRange(direct_map)) {
            log.err(
                \\direct map overlaps another memory region:
                \\  direct map: {}
                \\  other region: {}
            , .{ direct_map, region });

            return error.DirectMapOverlapsRegion;
        }
    }

    try memory_layout.append(.{
        .range = direct_map,
        .type = .direct_map,
        .operation = .full_map,
    });

    const non_cached_direct_map = memory_layout.findFreeRange(
        direct_map.size,
        arch.paging.largest_page_size,
    ) orelse return error.NoFreeRangeForDirectMap;

    kernel.memory_layout.globals.non_cached_direct_map = non_cached_direct_map;

    try memory_layout.append(.{
        .range = non_cached_direct_map,
        .type = .non_cached_direct_map,
        .operation = .full_map,
    });
}

fn registerHeaps(memory_layout: *MemoryLayout) !core.VirtualRange {
    const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();

    const kernel_stacks_range = memory_layout.findFreeRange(size_of_top_level, size_of_top_level) orelse
        core.panic("no space in kernel memory layout for the kernel stacks", null);

    try memory_layout.append(.{
        .range = kernel_stacks_range,
        .type = .kernel_stacks,
        .operation = .top_level_map,
    });

    return kernel_stacks_range;
}

fn initializeACPITables() !void {
    const rsdp_address = boot.rsdp() orelse return error.RSDPNotProvided;

    const rsdp = switch (rsdp_address) {
        .physical => |addr| kernel.memory_layout.directMapFromPhysical(addr).toPtr(*const acpi.RSDP),
        .virtual => |addr| addr.toPtr(*const acpi.RSDP),
    };
    if (!rsdp.isValid()) return error.InvalidRSDP;

    const sdt_header = kernel.memory_layout.directMapFromPhysical(rsdp.sdtAddress()).toPtr(*const acpi.SharedHeader);

    if (!sdt_header.isValid()) return error.InvalidSDT;

    if (log.levelEnabled(.debug)) {
        var iter = acpi.tableIterator(
            sdt_header,
            kernel.memory_layout.directMapFromPhysical,
        );

        log.debug("ACPI tables:", .{});

        while (iter.next()) |table| {
            if (table.isValid()) {
                log.debug("  {s}", .{table.signatureAsString()});
            } else {
                log.debug("  {s} - INVALID", .{table.signatureAsString()});
            }
        }
    }

    kernel.acpi.globals.sdt_header = sdt_header;
}

fn initializePMM(pmm: *PMM) !void {
    var iter = boot.memoryMap(.forward) orelse return error.NoMemoryMap;

    var ranges: PMM.Ranges = .{};

    var total_memory: core.Size = .zero;
    var free_memory: core.Size = .zero;
    var reserved_memory: core.Size = .zero;
    var reclaimable_memory: core.Size = .zero;
    var unavailable_memory: core.Size = .zero;

    while (iter.next()) |entry| {
        total_memory.addInPlace(entry.range.size);

        switch (entry.type) {
            .free => {
                free_memory.addInPlace(entry.range.size);
                try ranges.append(entry.range);
            },
            .in_use => {},
            .reserved => reserved_memory.addInPlace(entry.range.size),
            .bootloader_reclaimable, .acpi_reclaimable => reclaimable_memory.addInPlace(entry.range.size),
            .unusable, .unknown => unavailable_memory.addInPlace(entry.range.size),
        }
    }

    pmm.* = .{
        .free_ranges = ranges,
        .total_memory = total_memory,
        .free_memory = free_memory,
        .reserved_memory = reserved_memory,
        .reclaimable_memory = reclaimable_memory,
        .unavailable_memory = unavailable_memory,
    };

    log.debug("total memory:         {}", .{total_memory});
    log.debug("  free memory:        {}", .{free_memory});
    log.debug("  used memory:        {}", .{pmm.usedMemory()});
    log.debug("  reserved memory:    {}", .{reserved_memory});
    log.debug("  reclaimable memory: {}", .{reclaimable_memory});
    log.debug("  unavailable memory: {}", .{unavailable_memory});
}

fn initializeVirtualMemory(pmm: *PMM, memory_layout: *const MemoryLayout) !void {
    log.debug("building core page table", .{});

    kernel.vmm.core_page_table = arch.paging.PageTable.create(try pmm.allocateContiguousPages(arch.paging.PageTable.page_table_size));

    for (memory_layout.regions.constSlice()) |region| {
        switch (region.operation) {
            .full_map => {
                const physical_range = switch (region.type) {
                    .direct_map, .non_cached_direct_map => core.PhysicalRange.fromAddr(core.PhysicalAddress.zero, region.range.size),
                    .executable_section, .readonly_section, .sdf_section, .writeable_section => core.PhysicalRange.fromAddr(
                        core.PhysicalAddress.fromInt(
                            region.range.address.value - kernel.memory_layout.globals.physical_to_virtual_offset.value,
                        ),
                        region.range.size,
                    ),
                    .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                };

                const map_type: kernel.vmm.MapType = switch (region.type) {
                    .executable_section => .{ .executable = true, .global = true },
                    .readonly_section, .sdf_section => .{ .global = true },
                    .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                    .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
                    .kernel_stacks => core.panic("kernel stack region is full mapped", null),
                };

                arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    kernel.vmm.core_page_table,
                    region.range,
                    physical_range,
                    map_type,
                    AllocatePageContext{ .pmm = pmm },
                    AllocatePageContext.allocatePage,
                );
            },
            .top_level_map => arch.paging.init.fillTopLevel(
                kernel.vmm.core_page_table,
                region.range,
                .{ .global = true, .writeable = true },
                AllocatePageContext{ .pmm = pmm },
                AllocatePageContext.allocatePage,
            ),
        }
    }

    kernel.vmm.core_page_table.load();
}

/// Initialize the per executor data structures for all executors including the bootstrap executor.
///
/// Also wakes the non-bootstrap executors and jumps them to `initStage3`.
fn initializeExecutors(pmm: *PMM, stack_allocator: *StackAllocator) !void {
    try allocateAndPrepareExecutors(pmm, stack_allocator);
    try bootNonBootstrapExecutors();
}

fn allocateAndPrepareExecutors(pmm: *PMM, stack_allocator: *StackAllocator) !void {
    const KernelStackContext = struct {
        pmm: *PMM,
        stack_allocator: *StackAllocator,

        fn allocateKernelStack(context: *@This()) !kernel.Stack {
            // TODO: we will eventually need a proper stack allocator, especically if we want guard pages

            const physical_range = try context.pmm.allocateContiguousPages(kernel.config.kernel_stack_size);
            const stack = context.stack_allocator.allocate();

            arch.paging.init.mapToPhysicalRangeAllPageSizes(
                kernel.vmm.core_page_table,
                stack.usable_range,
                physical_range,
                .{ .global = true, .writeable = true },
                AllocatePageContext{ .pmm = context.pmm },
                AllocatePageContext.allocatePage,
            );

            return stack;
        }
    };

    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    const executors = try pmm.allocateContiguousSlice(kernel.Executor, descriptors.count());

    var kernel_stack_context: KernelStackContext = .{
        .pmm = pmm,
        .stack_allocator = stack_allocator,
    };

    var i: u32 = 0;
    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);
        log.debug("initializing executor {}", .{id});

        executor.* = .{
            .id = id,
            .scheduler_stack = try kernel_stack_context.allocateKernelStack(),
            .arch = undefined, // set by `arch.init.prepareExecutor`
        };

        arch.init.prepareExecutor(
            executor,
            &kernel_stack_context,
            KernelStackContext.allocateKernelStack,
        );
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

const AllocatePageContext = struct {
    pmm: *PMM,

    fn allocatePage(context: @This()) !core.PhysicalRange {
        return context.pmm.allocateContiguousPages(arch.paging.standard_page_size) catch return error.OutOfPhysicalMemory;
    }
};

const globals = struct {
    var bootstrap_executor: kernel.Executor = .{
        .id = .bootstrap,
        .scheduler_stack = undefined, // never used
        .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
    };
    var pmm: PMM = undefined; // set by `initializePMM`
    var memory_layout: MemoryLayout = undefined; // set by `buildMemoryLayout`
    var stack_allocator: StackAllocator = undefined; // set by `buildMemoryLayout`
    var early_output_lock: kernel.sync.TicketSpinLock = .{};
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);
const acpi = @import("acpi");
const MemoryLayout = @import("MemoryLayout.zig");
const StackAllocator = @import("StackAllocator.zig");
const PMM = @import("PMM.zig");
