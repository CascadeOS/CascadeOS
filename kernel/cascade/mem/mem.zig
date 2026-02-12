// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const Process = cascade.user.Process;
const core = @import("core");

pub const AddressSpace = @import("address_space/AddressSpace.zig");
pub const cache = @import("cache.zig");
pub const FlushRequest = @import("FlushRequest.zig");
pub const heap = @import("heap.zig");
pub const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
pub const MapType = @import("MapType.zig");
pub const PhysicalPage = @import("PhysicalPage.zig");
pub const resource_arena = @import("resource_arena.zig");

const log = cascade.debug.log.scoped(.mem);

pub inline fn kernelRegions() *KernelMemoryRegion.List {
    return &globals.regions;
}

pub inline fn kernelPageTable() arch.paging.PageTable {
    return globals.kernel_page_table;
}

pub inline fn kernelAddressSpace() *AddressSpace {
    return &globals.kernel_address_space;
}

/// Maps a single page to a physical page.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_address` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapSinglePage(
    page_table: arch.paging.PageTable,
    virtual_address: cascade.VirtualAddress,
    physical_page: PhysicalPage.Index,
    map_type: MapType,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_address.aligned(arch.paging.standard_page_size_alignment));
    }

    try page_table.mapSinglePage(
        virtual_address,
        physical_page,
        map_type,
        physical_page_allocator,
    );
}

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeAndBackWithPhysicalPages(
    page_table: arch.paging.PageTable,
    virtual_range: cascade.VirtualRange,
    map_type: MapType,
    flush_target: cascade.Context,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_range.address.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(virtual_range.size.aligned(arch.paging.standard_page_size_alignment));
    }

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer {
        // Unmap all pages that have been mapped.

        var unmap_batch: VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(.{
            .address = virtual_range.address,
            .size = virtual_range.address.difference(current_virtual_address),
        });

        unmap(
            page_table,
            &unmap_batch,
            flush_target,
            .free,
            top_level_decision,
            physical_page_allocator,
        );
    }

    // TODO: this can be optimized by implementing `arch.paging.mapRangeAndBackWithPhysicalPages`
    //       this one is not as obviously good as the other TODO optimizations in this file as every arch will have to do
    //       the same physical page allocation and errdefer deallocation

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        const physical_page = try physical_page_allocator.allocate();
        errdefer {
            var deallocate_page_list: PhysicalPage.List = .{};
            deallocate_page_list.prepend(physical_page);
            physical_page_allocator.deallocate(deallocate_page_list);
        }

        try page_table.mapSinglePage(
            current_virtual_address,
            physical_page,
            map_type,
            physical_page_allocator,
        );

        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
    }
}

/// Maps a virtual address range to a physical range using the standard page size.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `physical_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `physical_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be equal to `physical_range.size`
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeToPhysicalRange(
    page_table: arch.paging.PageTable,
    virtual_range: cascade.VirtualRange,
    physical_range: cascade.PhysicalRange,
    map_type: MapType,
    flush_target: cascade.Context,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_range.address.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(virtual_range.size.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(physical_range.address.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(physical_range.size.aligned(arch.paging.standard_page_size_alignment));
        std.debug.assert(virtual_range.size.equal(physical_range.size));
    }

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer { // unmap all pages that have been mapped
        var unmap_batch: VirtualRangeBatch = .{};
        unmap_batch.appendMergeIfFull(.{
            .address = virtual_range.address,
            .size = virtual_range.address.difference(current_virtual_address),
        });

        unmap(
            page_table,
            &unmap_batch,
            flush_target,
            .keep,
            top_level_decision,
            physical_page_allocator,
        );
    }

    // TODO: this can be optimized by implementing `arch.paging.PageTable.mapRange`

    var current_physical_address = physical_range.address;

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        try page_table.mapSinglePage(
            current_virtual_address,
            .fromAddress(current_physical_address),
            map_type,
            physical_page_allocator,
        );

        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
        current_physical_address.moveForwardInPlace(arch.paging.standard_page_size);
    }
}

/// Unmaps all ranges in the given batch.
///
/// Performs TLB shootdown.
pub fn unmap(
    page_table: arch.paging.PageTable,
    unmap_batch: *const VirtualRangeBatch,
    flush_target: cascade.Context,
    backing_page_decision: core.CleanupDecision,
    top_level_decision: core.CleanupDecision,
    physical_page_allocator: PhysicalPage.Allocator,
) void {
    var deallocate_page_list: PhysicalPage.List = .{};
    var flush_batch: VirtualRangeBatch = .{};

    for (unmap_batch.ranges.constSlice()) |range| {
        page_table.unmap(
            range,
            backing_page_decision,
            top_level_decision,
            &flush_batch,
            &deallocate_page_list,
        );

        if (flush_batch.full()) {
            @branchHint(.unlikely);

            var request: FlushRequest = .{
                .batch = &flush_batch,
                .flush_target = flush_target,
            };

            request.submitAndWait();

            flush_batch.clear();
        }
    }

    if (flush_batch.ranges.len != 0) {
        var request: FlushRequest = .{
            .batch = &flush_batch,
            .flush_target = flush_target,
        };

        request.submitAndWait();
    }

    physical_page_allocator.deallocate(deallocate_page_list);
}

/// Changes the protection of all the ranges in the given batch.
///
/// Only modifies the pages that are actually mapped.
///
/// Performs TLB shootdown if required.
pub fn changeProtection(
    page_table: arch.paging.PageTable,
    change_proection_batch: *const ChangeProtectionBatch,
    flush_target: cascade.Context,
    new_map_type: cascade.mem.MapType,
) void {
    var flush_batch: VirtualRangeBatch = .{};

    for (change_proection_batch.ranges.constSlice()) |range| {
        page_table.changeProtection(
            range.virtual_range,
            range.previous_map_type,
            new_map_type,
            &flush_batch,
        );

        if (flush_batch.full()) {
            @branchHint(.unlikely);

            var request: FlushRequest = .{
                .batch = &flush_batch,
                .flush_target = flush_target,
            };

            request.submitAndWait();

            flush_batch.clear();
        }
    }

    if (flush_batch.ranges.len != 0) {
        var request: FlushRequest = .{
            .batch = &flush_batch,
            .flush_target = flush_target,
        };

        request.submitAndWait();
    }
}

/// Executed upon page fault.
pub fn onPageFault(
    page_fault_details: PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    const current_task: Task.Current = .get();
    current_task.decrementInterruptDisable();

    switch (page_fault_details.faulting_context) {
        .kernel => onKernelPageFault(page_fault_details, interrupt_frame),
        .user => {
            const process: *cascade.user.Process = .from(current_task.task);
            process.address_space.handlePageFault(page_fault_details) catch |err| std.debug.panic(
                "user page fault failed: {t}\n{f}",
                .{ err, page_fault_details },
            );
        },
    }
}

fn onKernelPageFault(
    page_fault_details: PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    switch (page_fault_details.faulting_address.getType()) {
        .user => {
            const process: *Process = blk: {
                const current_task: Task.Current = .get();

                break :blk switch (current_task.task.type) {
                    .kernel => {
                        @branchHint(.cold);
                        cascade.debug.interruptSourcePanic(
                            interrupt_frame,
                            "kernel page fault in user memory range\n{f}",
                            .{page_fault_details},
                        );
                        unreachable;
                    },
                    .user => .from(current_task.task),
                };
            };

            if (!page_fault_details.faulting_context.kernel.access_to_user_memory_enabled) {
                @branchHint(.cold);

                cascade.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel accessed user memory\n{f}",
                    .{page_fault_details},
                );
            }

            process.address_space.handlePageFault(page_fault_details) catch |err|
                cascade.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel page fault in user memory failed: {t}\n{f}",
                    .{ err, page_fault_details },
                );
        },
        .kernel => {
            const region_type = globals.regions.containingAddress(page_fault_details.faulting_address.toKernel()) orelse {
                @branchHint(.cold);

                cascade.debug.interruptSourcePanic(
                    interrupt_frame,
                    "kernel page fault outside of any kernel region\n{f}",
                    .{page_fault_details},
                );
            };

            switch (region_type) {
                .kernel_address_space => {
                    @branchHint(.likely);
                    globals.kernel_address_space.handlePageFault(page_fault_details) catch |err| switch (err) {
                        error.OutOfMemory => std.debug.panic(
                            "no memory available to handle page fault in kernel address space\n{f}",
                            .{page_fault_details},
                        ),
                        else => |e| cascade.debug.interruptSourcePanic(
                            interrupt_frame,
                            "failed to handle page fault in kernel address space: {t}\n{f}",
                            .{ e, page_fault_details },
                        ),
                    };
                },
                else => {
                    @branchHint(.cold);

                    cascade.debug.interruptSourcePanic(
                        interrupt_frame,
                        "kernel page fault in '{t}'\n{f}",
                        .{ region_type, page_fault_details },
                    );
                },
            }
        },
        .invalid => {
            @branchHint(.cold);

            cascade.debug.interruptSourcePanic(
                interrupt_frame,
                "kernel page fault with invalid address\n{f}",
                .{page_fault_details},
            );
        },
    }
}

pub const PageFaultDetails = struct {
    faulting_address: cascade.VirtualAddress,
    access_type: AccessType,
    fault_type: FaultType,

    /// The context that the fault was triggered from.
    ///
    /// This is not necessarily the same as the context of the task that triggered the fault as a user task may have
    /// triggered the fault while running in kernelspace.
    faulting_context: FaultingContext,

    pub const FaultingContext = union(cascade.Context.Type) {
        kernel: struct {
            access_to_user_memory_enabled: bool,
        },
        user,
    };

    pub const AccessType = enum {
        read,
        write,
        execute,
    };

    pub const FaultType = enum {
        /// Either the page was not present or the mapping is invalid.
        invalid,

        /// The access was not permitted by the page protection.
        protection,
    };

    pub fn print(details: PageFaultDetails, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("PageFaultDetails{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("faulting_address: {f},\n", .{details.faulting_address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("access_type: {t},\n", .{details.access_type});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("fault_type: {t},\n", .{details.fault_type});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("faulting_context: {t},\n", .{details.faulting_context});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        details: PageFaultDetails,
        writer: *std.Io.Writer,
    ) !void {
        return details.print(writer, 0);
    }
};

pub const MapError = error{
    AlreadyMapped,

    /// This is used to surface errors from the underlying paging implementation that are architecture specific.
    MappingNotValid,
} || PhysicalPage.Allocator.AllocateError;

/// A batch of virtual ranges.
///
/// Attempts to merge adjacent ranges if they are reasonably close together see
/// `cascade.config.virtual_range_batching_seperation_to_merge_over`.
pub const VirtualRangeBatch = struct {
    ranges: core.containers.BoundedArray(
        cascade.VirtualRange,
        cascade.config.mem.virtual_ranges_to_batch,
    ) = .{},

    /// Appends a virtual range to the batch.
    ///
    /// If full then always merges with the last range.
    ///
    /// **REQUIREMENTS**:
    /// - Each subsequent range must be greater than or equal to the previous range.
    /// - `range.address` must be greater than or equal to the end of the last range in the batch
    /// - `range.address` must be aligned to `arch.paging.standard_page_size`
    /// - `range.size` must be aligned to `arch.paging.standard_page_size`
    pub fn appendMergeIfFull(batch: *VirtualRangeBatch, range: cascade.VirtualRange) void {
        if (core.is_debug) {
            std.debug.assert(range.address.aligned(arch.paging.standard_page_size_alignment));
            std.debug.assert(range.size.aligned(arch.paging.standard_page_size_alignment));
        }

        switch (batch.ranges.len) {
            0 => {
                @branchHint(.unlikely);
                batch.ranges.appendAssumeCapacity(range);
            },
            cascade.config.mem.virtual_ranges_to_batch => {
                // we have hit the limit of virtual ranges to batch together so we always merge with the last range
                const last: *cascade.VirtualRange = &batch.ranges.slice()[cascade.config.mem.virtual_ranges_to_batch - 1];

                if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

                last.size.addInPlace(last.after().difference(range.address));
                last.size.addInPlace(range.size);
            },
            else => |len| {
                @branchHint(.likely);
                const last: *cascade.VirtualRange = &batch.ranges.slice()[len - 1];

                if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

                const seperation_size = last.after().difference(range.address);

                if (seperation_size.lessThanOrEqual(cascade.config.mem.virtual_range_batching_merge_distance)) {
                    last.size.addInPlace(seperation_size);
                    last.size.addInPlace(range.size);
                } else {
                    batch.ranges.appendAssumeCapacity(range);
                }
            },
        }
    }

    /// Appends a virtual range to the batch.
    ///
    /// Returns `false` if the batch is full and the range could not be appended.
    ///
    /// **REQUIREMENTS**:
    /// - Each subsequent range must be greater than or equal to the previous range.
    /// - `range.address` must be greater than or equal to the end of the last range in the batch
    /// - `range.address` must be aligned to `arch.paging.standard_page_size`
    /// - `range.size` must be aligned to `arch.paging.standard_page_size`
    pub fn append(batch: *VirtualRangeBatch, range: cascade.VirtualRange) bool {
        if (core.is_debug) {
            std.debug.assert(range.address.aligned(arch.paging.standard_page_size_alignment));
            std.debug.assert(range.size.aligned(arch.paging.standard_page_size_alignment));
        }

        const len = batch.ranges.len;

        if (len == 0) {
            @branchHint(.unlikely);
            batch.ranges.appendAssumeCapacity(range);
            return true;
        }

        const last: *cascade.VirtualRange = &batch.ranges.slice()[len - 1];

        if (core.is_debug) std.debug.assert(range.address.greaterThanOrEqual(last.after()));

        const seperation_size = last.after().difference(range.address);

        if (seperation_size.lessThanOrEqual(cascade.config.mem.virtual_range_batching_merge_distance)) {
            last.size.addInPlace(seperation_size);
            last.size.addInPlace(range.size);
            return true;
        }

        if (batch.full()) {
            @branchHint(.cold);
            return false;
        }

        batch.ranges.appendAssumeCapacity(range);
        return true;
    }

    pub fn full(batch: *VirtualRangeBatch) bool {
        return batch.ranges.len == cascade.config.mem.virtual_ranges_to_batch;
    }

    pub fn clear(batch: *VirtualRangeBatch) void {
        batch.ranges.clear();
    }
};

/// A batch of virtual ranges with their current map type.
///
/// Attempts to merge adjacent ranges if they have the same map type and are reasonably close together see
/// `cascade.config.virtual_range_batching_seperation_to_merge_over`.
pub const ChangeProtectionBatch = struct {
    ranges: core.containers.BoundedArray(
        VirtualRangeWithMapType,
        cascade.config.mem.virtual_ranges_to_batch,
    ) = .{},

    pub const VirtualRangeWithMapType = struct {
        virtual_range: cascade.VirtualRange,
        previous_map_type: MapType,
    };

    /// Appends a virtual range to the batch.
    ///
    /// **REQUIREMENTS**:
    /// - `range.virtual_range.address` must be greater than or equal to the end of the last range in the batch
    /// - `range.virtual_range.address` must be aligned to `arch.paging.standard_page_size`
    /// - `range.virtual_range.size` must be aligned to `arch.paging.standard_page_size`
    pub fn append(batch: *ChangeProtectionBatch, range: VirtualRangeWithMapType) bool {
        if (core.is_debug) {
            std.debug.assert(range.virtual_range.address.aligned(arch.paging.standard_page_size_alignment));
            std.debug.assert(range.virtual_range.size.aligned(arch.paging.standard_page_size_alignment));
        }

        const len = batch.ranges.len;

        if (len == 0) {
            @branchHint(.unlikely);
            batch.ranges.appendAssumeCapacity(range);
            return true;
        }

        const last: *VirtualRangeWithMapType = &batch.ranges.slice()[len - 1];

        if (core.is_debug) std.debug.assert(range.virtual_range.address.greaterThanOrEqual(last.virtual_range.after()));

        const seperation_size = last.virtual_range.after().difference(range.virtual_range.address);

        if (seperation_size.lessThanOrEqual(cascade.config.mem.virtual_range_batching_merge_distance) and
            last.previous_map_type.equal(range.previous_map_type))
        {
            last.virtual_range.size.addInPlace(seperation_size);
            last.virtual_range.size.addInPlace(range.virtual_range.size);
            return true;
        }

        if (batch.full()) {
            @branchHint(.cold);
            return false;
        }

        batch.ranges.appendAssumeCapacity(range);
        return true;
    }

    pub fn full(batch: *ChangeProtectionBatch) bool {
        return batch.ranges.len == cascade.config.mem.virtual_ranges_to_batch;
    }

    pub fn clear(batch: *ChangeProtectionBatch) void {
        batch.ranges.clear();
    }
};

pub const globals = struct {
    /// The kernel page table.
    ///
    /// All other page tables start as a copy of this one.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var kernel_page_table: arch.paging.PageTable = undefined;

    /// The kernel address space.
    ///
    /// Used for file caches, loaning memory from userspace, etc.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var kernel_address_space: AddressSpace = undefined;

    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    var virtual_base_address: cascade.KernelVirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    pub var kernel_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    pub var direct_map: cascade.KernelVirtualRange = undefined;

    /// The layout of the memory regions of the cascade.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var regions: KernelMemoryRegion.List = .{};
};

pub const init = struct {
    const boot = @import("boot");
    const init_log = cascade.debug.log.scoped(.mem_init);

    /// Determine the kernels various offsets and the direct map early in the boot process.
    pub fn determineEarlyMemoryLayout() void {
        const base_address = boot.kernelBaseAddress() orelse @panic("no kernel base address");
        globals.virtual_base_address = base_address.virtual;

        const kernel_virtual_offset = core.Size.from(
            base_address.virtual.value - cascade.config.mem.kernel_base_address.value,
            .byte,
        );
        globals.kernel_virtual_offset = kernel_virtual_offset;

        init_globals.kernel_physical_to_virtual_offset = core.Size.from(
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
            direct_map_size.alignForwardInPlace(arch.paging.largest_page_size_alignment);

            break :direct_map_size direct_map_size;
        };

        globals.direct_map = .from(
            boot.directMapAddress() orelse @panic("direct map address not provided"),
            direct_map_size,
        );
    }

    pub fn logEarlyMemoryLayout() void {
        if (!init_log.levelEnabled(.debug)) return;

        init_log.debug("kernel memory offsets:", .{});

        init_log.debug("  virtual base address:       {f}", .{globals.virtual_base_address});
        init_log.debug("  virtual offset:             0x{x:0>16}", .{globals.kernel_virtual_offset.value});
        init_log.debug("  physical to virtual:        0x{x:0>16}", .{init_globals.kernel_physical_to_virtual_offset.value});
        init_log.debug("  direct map:                 {f}", .{globals.direct_map});
    }

    pub fn initializeMemorySystem() !void {
        if (init_log.levelEnabled(.debug)) {
            var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");
            init_log.debug("bootloader provided memory map:", .{});
            while (memory_iter.next()) |entry| {
                init_log.debug("\t{f}", .{entry});
            }
        }

        init_log.debug("building kernel memory layout", .{});
        buildMemoryLayout();

        init_log.debug("building kernel page table", .{});
        globals.kernel_page_table = buildAndLoadKernelPageTable();

        init_log.debug("initializing physical memory", .{});
        PhysicalPage.init.initializePhysicalMemory(globals.regions.find(.pages).?.range);

        init_log.debug("initializing caches", .{});
        try cache.init.initializeCaches();
        try resource_arena.init.initializeCaches();
        try AddressSpace.AnonymousMap.init.initializeCaches();
        try AddressSpace.AnonymousPage.init.initializeCaches();
        try AddressSpace.Entry.init.initializeCaches();

        init_log.debug("initializing kernel and special heap", .{});
        try heap.init.initializeHeaps(&globals.regions);

        init_log.debug("initializing kernel address space", .{});
        try globals.kernel_address_space.init(
            .{
                .name = try .fromSlice("kernel"),
                .range = globals.regions.find(.kernel_address_space).?.range.toVirtualRange(),
                .page_table = globals.kernel_page_table,
                .context = .kernel,
            },
        );
    }

    fn buildMemoryLayout() void {
        const kernel_regions = &globals.regions;

        registerKernelSections(kernel_regions);
        registerDirectMap(kernel_regions);
        registerHeaps(kernel_regions);
        registerPages(kernel_regions);

        kernel_regions.sort();

        if (init_log.levelEnabled(.debug)) {
            init_log.debug("kernel memory layout:", .{});

            for (kernel_regions.constSlice()) |region| {
                init_log.debug("\t{f}", .{region});
            }
        }
    }

    fn registerKernelSections(kernel_regions: *KernelMemoryRegion.List) void {
        const linker_symbols = struct {
            extern const __text_start: u8;
            extern const __text_end: u8;
            extern const __rodata_start: u8;
            extern const __rodata_end: u8;
            extern const __data_start: u8;
            extern const __data_end: u8;
        };

        const sdf_slice = cascade.debug.sdfSlice() catch &.{};
        const sdf_range: cascade.KernelVirtualRange = .fromSlice(u8, sdf_slice);

        const sections: []const struct {
            cascade.KernelVirtualAddress,
            cascade.KernelVirtualAddress,
            KernelMemoryRegion.Type,
        } = &.{
            .{
                .from(@intFromPtr(&linker_symbols.__text_start)),
                .from(@intFromPtr(&linker_symbols.__text_end)),
                .executable_section,
            },
            .{
                .from(@intFromPtr(&linker_symbols.__rodata_start)),
                .from(@intFromPtr(&linker_symbols.__rodata_end)),
                .readonly_section,
            },
            .{
                .from(@intFromPtr(&linker_symbols.__data_start)),
                .from(@intFromPtr(&linker_symbols.__data_end)),
                .writeable_section,
            },
            .{
                sdf_range.address,
                sdf_range.after(),
                .sdf_section,
            },
        };

        for (sections) |section| {
            const start_address = section[0];
            const end_address = section[1];
            const region_type = section[2];

            if (core.is_debug) std.debug.assert(end_address.greaterThan(start_address));

            const virtual_range: cascade.KernelVirtualRange = .from(
                start_address,
                core.Size.from(end_address.value - start_address.value, .byte)
                    .alignForward(arch.paging.standard_page_size_alignment),
            );

            kernel_regions.append(.{
                .range = virtual_range,
                .type = region_type,
            });
        }
    }

    fn registerDirectMap(kernel_regions: *KernelMemoryRegion.List) void {
        const direct_map = globals.direct_map;

        // does the direct map range overlap a pre-existing region?
        for (kernel_regions.constSlice()) |region| {
            if (region.range.anyOverlap(direct_map)) {
                std.debug.panic("direct map overlaps region: {f}", .{region});
            }
        }

        kernel_regions.append(.{
            .range = direct_map,
            .type = .direct_map,
        });
    }

    fn registerHeaps(kernel_regions: *KernelMemoryRegion.List) void {
        const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();
        const size_of_top_level_alignment = size_of_top_level.toAlignment();

        const kernel_heap_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level_alignment,
        ) orelse
            @panic("no space in kernel memory layout for the kernel heap");

        kernel_regions.append(.{
            .range = kernel_heap_range,
            .type = .kernel_heap,
        });

        const special_heap_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level_alignment,
        ) orelse
            @panic("no space in kernel memory layout for the special heap");

        kernel_regions.append(.{
            .range = special_heap_range,
            .type = .special_heap,
        });

        const kernel_stacks_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level_alignment,
        ) orelse
            @panic("no space in kernel memory layout for the kernel stacks");

        kernel_regions.append(.{
            .range = kernel_stacks_range,
            .type = .kernel_stacks,
        });

        const kernel_address_space_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level_alignment,
        ) orelse
            @panic("no space in kernel memory layout for the kernel address space");

        kernel_regions.append(.{
            .range = kernel_address_space_range,
            .type = .kernel_address_space,
        });
    }

    fn registerPages(kernel_regions: *KernelMemoryRegion.List) void {
        const total_number_of_pages = blk: {
            var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

            var last_page: cascade.PhysicalAddress = .zero;

            while (memory_iter.next()) |entry| {
                last_page = entry.range.last();
            }

            break :blk @intFromEnum(PhysicalPage.Index.fromAddress(last_page)) + 1;
        };

        const pages_range = kernel_regions.findFreeRange(
            core.Size.of(PhysicalPage)
                .multiplyScalar(total_number_of_pages)
                .alignForward(arch.paging.standard_page_size_alignment),
            arch.paging.standard_page_size_alignment,
        ) orelse @panic("no space in kernel memory layout for the pages array");

        kernel_regions.append(.{
            .range = pages_range,
            .type = .pages,
        });
    }

    fn buildAndLoadKernelPageTable() arch.paging.PageTable {
        const kernel_page_table: arch.paging.PageTable = .create(
            PhysicalPage.init.bootstrap_allocator.allocate() catch unreachable,
        );

        for (globals.regions.constSlice()) |region| {
            init_log.debug("mapping '{t}' into the kernel page table", .{region.type});

            switch (region.type) {
                .direct_map,
                => arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    kernel_page_table,
                    region.range.toVirtualRange(),
                    .from(.zero, region.range.size),
                    .{
                        .type = .kernel,
                        .protection = .read_write,
                    },
                    PhysicalPage.init.bootstrap_allocator,
                ) catch |err| std.debug.panic("failed to map {f}: {t}", .{ region, err }),

                .writeable_section,
                .readonly_section,
                .executable_section,
                .sdf_section,
                => arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    kernel_page_table,
                    region.range.toVirtualRange(),
                    .from(
                        .from(region.range.address.value - init_globals.kernel_physical_to_virtual_offset.value),
                        region.range.size,
                    ),
                    switch (region.type) {
                        .executable_section => .{ .type = .kernel, .protection = .execute },
                        .readonly_section, .sdf_section => .{ .type = .kernel, .protection = .read },
                        .writeable_section => .{ .type = .kernel, .protection = .read_write },
                        else => unreachable,
                    },
                    PhysicalPage.init.bootstrap_allocator,
                ) catch |err| std.debug.panic("failed to map {f}: {t}", .{ region, err }),

                .kernel_heap,
                .kernel_stacks,
                .special_heap,
                .kernel_address_space,
                => arch.paging.init.fillTopLevel(
                    kernel_page_table,
                    region.range.toVirtualRange(),
                    PhysicalPage.init.bootstrap_allocator,
                ) catch |err| std.debug.panic("failed to map {f}: {t}", .{ region, err }),

                .pages,
                => PhysicalPage.init.mapPagesArray(
                    kernel_page_table,
                    region.range,
                ) catch |err| std.debug.panic("failed to map {f}: {t}", .{ region, err }),
            }
        }

        init_log.debug("loading kernel page table", .{});
        kernel_page_table.load();

        return kernel_page_table;
    }

    const init_globals = struct {
        /// Offset from the virtual address of kernel sections to the physical address of the section.
        ///
        /// Initialized during `init.determineEarlyMemoryLayout`.
        var kernel_physical_to_virtual_offset: core.Size = undefined;
    };
};
