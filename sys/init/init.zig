// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub const time = @import("time.zig");

/// Entry point from bootloader specific code.
///
/// Only the bootstrap executor executes this function.
pub fn initStage1() !noreturn {
    { // as the bootstrap executor has not been initialized yet, we can't log in this block
        try earlyBuildMemoryLayout();

        // get output up and running as soon as possible
        arch.init.setupEarlyOutput();
        arch.init.writeToEarlyOutput(comptime "starting CascadeOS " ++ kernel.config.cascade_version ++ "\n");

        // now that early output is ready, we can switch to the single executor panic
        kernel.debug.panic_impl = singleExecutorPanic;

        kernel.executors = @as([*]kernel.Executor, @ptrCast(&bootstrap_executor))[0..1];
        arch.init.prepareBootstrapExecutor(&bootstrap_executor);
        arch.init.loadExecutor(&bootstrap_executor);

        // now that the bootstrap executor is ready, we can log
        log.debug("bootstrap executor initialized", .{});
    }

    log.debug("initializing interrupts", .{});
    arch.init.initInterrupts(&handleInterrupt);

    log.debug("building memory layout", .{});
    try finishBuildMemoryLayout();

    log.debug("initializing ACPI tables", .{});
    try initializeACPITables();

    log.debug("capturing system information", .{});
    try arch.init.captureSystemInformation();

    log.debug("configuring global system features", .{});
    try arch.init.configureGlobalSystemFeatures();

    log.debug("initializing physical memory", .{});
    try initializePhysicalMemory();

    log.debug("initializing virtual memory", .{});
    try initializeVirtualMemory();

    log.debug("initializing time", .{});
    try time.initializeTime();

    log.debug("initializing executors", .{});
    try initializeExecutors();

    initStage2(kernel.getExecutor(.bootstrap));
    core.panic("`init.initStage2` returned", null);
}

/// Stage 2 of kernel initialization.
///
/// This function is executed by all executors, including the bootstrap executor.
///
/// All executors are using the bootloader provided stack.
fn initStage2(executor: *kernel.Executor) noreturn {
    kernel.vmm.core_page_table.load();
    arch.init.loadExecutor(executor);

    if (executor.id != .bootstrap) arch.interrupts.disableInterruptsAndHalt(); // park non-bootstrap

    log.info("initialization complete - duration: {}", .{
        kernel.time.wallclock.elapsed(@enumFromInt(0), kernel.time.wallclock.read()),
    });

    core.panic("NOT IMPLEMENTED", null);
}

/// The log implementation during init.
pub fn initLogImpl(level_and_scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    const static = struct {
        var lock: kernel.sync.TicketSpinLock = .{};
    };

    static.lock.lock();
    defer static.lock.unlock();

    arch.init.writeToEarlyOutput(level_and_scope);
    arch.init.early_output_writer.print(fmt, args) catch unreachable;
}

/// The interrupt handler during init.
fn handleInterrupt(_: arch.interrupts.InterruptContext) noreturn {
    core.panic("unexpected interrupt", null);
}

fn singleExecutorPanic(
    msg: []const u8,
    error_return_trace: ?*const std.builtin.StackTrace,
    return_address: usize,
) void {
    const static = struct {
        var nested_panic_count: std.atomic.Value(usize) = .init(0);
    };

    switch (static.nested_panic_count.fetchAdd(1, .acq_rel)) {
        0 => { // on first panic attempt to print the full panic message
            kernel.debug.formatting.printPanic(
                arch.init.early_output_writer,
                msg,
                error_return_trace,
                return_address,
            ) catch unreachable;
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
fn earlyBuildMemoryLayout() !void {
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

fn finishBuildMemoryLayout() !void {
    log.debug("registering kernel sections", .{});
    try registerKernelSections();
    log.debug("registering direct maps", .{});
    try registerDirectMaps();
    log.debug("registering heaps", .{});
    try registerHeaps();

    sortMemoryLayout();

    if (log.levelEnabled(.debug)) {
        log.debug("kernel memory layout:", .{});

        for (kernel.memory_layout.globals.layout.constSlice()) |region| {
            log.debug("\t{}", .{region});
        }
    }
}

/// Sorts the kernel memory layout from lowest to highest address.
fn sortMemoryLayout() void {
    std.mem.sort(kernel.memory_layout.Region, kernel.memory_layout.globals.layout.slice(), {}, struct {
        fn lessThanFn(context: void, region: kernel.memory_layout.Region, other_region: kernel.memory_layout.Region) bool {
            _ = context;
            return region.range.address.lessThan(other_region.range.address);
        }
    }.lessThanFn);
}

/// Registers the kernel sections in the memory layout.
fn registerKernelSections() !void {
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

        try kernel.memory_layout.globals.layout.append(.{
            .range = virtual_range,
            .type = region_type,
            .operation = .full_map,
        });
    }
}

fn registerDirectMaps() !void {
    const direct_map = kernel.memory_layout.globals.direct_map;

    // does the direct map range overlap a pre-existing region?
    for (kernel.memory_layout.globals.layout.constSlice()) |region| {
        if (region.range.containsRange(direct_map)) {
            log.err(
                \\direct map overlaps another memory region:
                \\  direct map: {}
                \\  other region: {}
            , .{ direct_map, region });

            return error.DirectMapOverlapsRegion;
        }
    }

    try kernel.memory_layout.globals.layout.append(.{
        .range = direct_map,
        .type = .direct_map,
        .operation = .full_map,
    });

    const non_cached_direct_map = findFreeKernelMemoryRange(
        direct_map.size,
        arch.paging.largest_page_size,
    ) orelse return error.NoFreeRangeForDirectMap;

    kernel.memory_layout.globals.non_cached_direct_map = non_cached_direct_map;

    try kernel.memory_layout.globals.layout.append(.{
        .range = non_cached_direct_map,
        .type = .non_cached_direct_map,
        .operation = .full_map,
    });
}

fn registerHeaps() !void {
    const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();

    const kernel_stacks_range = findFreeKernelMemoryRange(size_of_top_level, size_of_top_level) orelse
        core.panic("no space in kernel memory layout for the kernel stacks", null);

    try kernel.memory_layout.globals.layout.append(.{
        .range = kernel_stacks_range,
        .type = .kernel_stacks,
        .operation = .top_level_map,
    });
    StackAllocator.instance = .{ .kernel_stacks_heap_range = kernel_stacks_range };
}

fn findFreeKernelMemoryRange(size: core.Size, alignment: core.Size) ?core.VirtualRange {
    sortMemoryLayout();

    const layout = &kernel.memory_layout.globals.layout;

    const regions = layout.constSlice();

    var current_address = arch.paging.higher_half_start;
    current_address.alignForwardInPlace(alignment);

    var i: usize = 0;

    while (true) {
        const region = if (i < layout.len) regions[i] else {
            const size_of_free_range = core.Size.from(
                (arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
                .byte,
            );

            if (size_of_free_range.lessThan(size)) return null;

            return core.VirtualRange.fromAddr(current_address, size);
        };

        const region_address = region.range.address;

        if (region_address.lessThanOrEqual(current_address)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        const size_of_free_range = core.Size.from(
            (region_address.value - 1) - current_address.value,
            .byte,
        );

        if (size_of_free_range.lessThan(size)) {
            current_address = region.range.endBound();
            current_address.alignForwardInPlace(alignment);
            i += 1;
            continue;
        }

        return core.VirtualRange.fromAddr(current_address, size);
    }
}

fn initializeACPITables() !void {
    const rsdp_address = boot.rsdp() orelse return error.RSDPNotProvided;
    const rsdp = rsdp_address.toPtr(*const acpi.RSDP);

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

fn initializePhysicalMemory() !void {
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

    PMM.instance = .{
        .free_ranges = ranges,
        .total_memory = total_memory,
        .free_memory = free_memory,
        .reserved_memory = reserved_memory,
        .reclaimable_memory = reclaimable_memory,
        .unavailable_memory = unavailable_memory,
    };

    log.debug("total memory:         {}", .{total_memory});
    log.debug("  free memory:        {}", .{free_memory});
    log.debug("  used memory:        {}", .{PMM.instance.usedMemory()});
    log.debug("  reserved memory:    {}", .{reserved_memory});
    log.debug("  reclaimable memory: {}", .{reclaimable_memory});
    log.debug("  unavailable memory: {}", .{unavailable_memory});
}

const AllocatePageContext = struct {
    pmm: *PMM,

    fn allocatePage(context: @This()) !core.PhysicalRange {
        return context.pmm.allocateContiguousPages(arch.paging.standard_page_size) catch return error.OutOfPhysicalMemory;
    }
};

fn initializeVirtualMemory() !void {
    log.debug("building core page table", .{});

    kernel.vmm.core_page_table = arch.paging.PageTable.create(try PMM.instance.allocateContiguousPages(arch.paging.PageTable.page_table_size));

    for (kernel.memory_layout.globals.layout.constSlice()) |region| {
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
                    .kernel_stacks => unreachable, // never full mapped
                };

                const map_type: kernel.vmm.MapType = switch (region.type) {
                    .executable_section => .{ .executable = true, .global = true },
                    .readonly_section, .sdf_section => .{ .global = true },
                    .writeable_section, .direct_map => .{ .writeable = true, .global = true },
                    .non_cached_direct_map => .{ .writeable = true, .global = true, .no_cache = true },
                    .kernel_stacks => unreachable, // never full mapped
                };

                arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    kernel.vmm.core_page_table,
                    region.range,
                    physical_range,
                    map_type,
                    AllocatePageContext{ .pmm = &PMM.instance },
                    AllocatePageContext.allocatePage,
                );
            },
            .top_level_map => arch.paging.init.fillTopLevel(
                kernel.vmm.core_page_table,
                region.range,
                .{ .global = true, .writeable = true },
                AllocatePageContext{ .pmm = &PMM.instance },
                AllocatePageContext.allocatePage,
            ),
        }
    }

    kernel.vmm.core_page_table.load();
}

/// Initialize the per executor data structures for all executors including the bootstrap executor.
///
/// Also wakes the non-bootstrap executors and jumps them to `initStage2`.
fn initializeExecutors() !void {
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
                AllocatePageContext{ .pmm = &PMM.instance },
                AllocatePageContext.allocatePage,
            );

            return stack;
        }
    };

    var descriptors = boot.cpuDescriptors() orelse return error.NoSMPFromBootloader;

    const executors = try PMM.instance.allocateContigousSlice(kernel.Executor, descriptors.count());

    var kernel_stack_context: KernelStackContext = .{
        .pmm = &PMM.instance,
        .stack_allocator = &StackAllocator.instance,
    };

    var i: u32 = 0;
    while (descriptors.next()) |desc| : (i += 1) {
        if (i == 0) std.debug.assert(desc.processorId() == 0);

        const executor = &executors[i];
        const id: kernel.Executor.Id = @enumFromInt(i);
        log.debug("initializing executor {}", .{id});

        executor.* = .{
            .id = id,
            .arch = undefined, // set by `arch.init.prepareExecutor`
        };

        arch.init.prepareExecutor(
            executor,
            &kernel_stack_context,
            KernelStackContext.allocateKernelStack,
        );

        if (executor.id != .bootstrap) {
            desc.boot(
                executor,
                struct {
                    fn bootFn(user_data: *anyopaque) noreturn {
                        initStage2(@as(*kernel.Executor, @ptrCast(@alignCast(user_data))));
                        core.panic("`init.initStage2` returned", null);
                    }
                }.bootFn,
            );
        }
    }

    // TODO: pass the remaining free range from `StackAllocator` to the main stack allocator
}

var bootstrap_executor: kernel.Executor = .{
    .id = .bootstrap,
    .arch = undefined, // set by `arch.init.prepareBootstrapExecutor`
};

const StackAllocator = struct {
    kernel_stacks_heap_range: core.VirtualRange,

    var instance: StackAllocator = undefined; // set by `registerHeaps`

    fn allocate(self: *StackAllocator) kernel.Stack {
        const full_range: core.VirtualRange = core.VirtualRange.fromAddr(
            self.kernel_stacks_heap_range.address,
            kernel.config.kernel_stack_size.add(arch.paging.standard_page_size), // extra page for guard page
        );

        const usable_range: core.VirtualRange = blk: {
            var range = full_range;
            range.size.subtractInPlace(arch.paging.standard_page_size);
            break :blk range;
        };

        self.kernel_stacks_heap_range.moveForwardInPlace(full_range.size);
        self.kernel_stacks_heap_range.size.subtractInPlace(full_range.size);

        return kernel.Stack.fromRange(full_range, usable_range);
    }
};

/// A simple physical memory manager.
///
/// Only supports allocating a single `arch.paging.standard_page_size` sized page with no support for freeing.
const PMM = struct {
    free_ranges: Ranges,
    total_memory: core.Size,
    free_memory: core.Size,
    reserved_memory: core.Size,
    reclaimable_memory: core.Size,
    unavailable_memory: core.Size,

    var instance: PMM = undefined; // set by `initializePhysicalMemory`

    pub const Ranges = std.BoundedArray(core.PhysicalRange, 16);

    pub fn usedMemory(self: *const PMM) core.Size {
        return self.total_memory
            .subtract(self.free_memory)
            .subtract(self.reserved_memory)
            .subtract(self.reclaimable_memory)
            .subtract(self.unavailable_memory);
    }

    pub fn allocateContigousSlice(
        self: *PMM,
        comptime T: type,
        count: usize,
    ) ![]T {
        const size = core.Size.of(T).multiplyScalar(count);
        const physical_range = try self.allocateContiguousPages(size);
        const virtual_range = kernel.memory_layout.directMapFromPhysicalRange(physical_range);
        return virtual_range.toSliceRelaxed(T);
    }

    /// Allocate contiguous physical pages.
    ///
    /// The allocation is rounded up to the next page.
    pub fn allocateContiguousPages(
        self: *PMM,
        requested_size: core.Size,
    ) error{InsufficentContiguousPhysicalMemory}!core.PhysicalRange {
        if (requested_size.value == 0) core.panic("non-zero size required", null);

        const size = requested_size.alignForward(arch.paging.standard_page_size);

        const ranges: []core.PhysicalRange = self.free_ranges.slice();

        for (ranges, 0..) |*range, i| {
            if (range.size.lessThan(size)) continue;

            // found a range with enough space for the allocation

            const allocated_range = core.PhysicalRange.fromAddr(range.address, size);

            range.size.subtractInPlace(size);

            if (range.size.value == 0) {
                // the range is now empty, so remove it from `free_ranges`
                _ = self.free_ranges.swapRemove(i);
            } else {
                range.address.moveForwardInPlace(size);
            }

            return allocated_range;
        }

        return error.InsufficentContiguousPhysicalMemory;
    }
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const boot = @import("boot");
const arch = @import("arch");
const log = kernel.log.scoped(.init);
const acpi = @import("acpi");
