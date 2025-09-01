// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const heap = @import("heap.zig");
pub const phys = @import("phys.zig");

pub const AddressSpace = @import("address_space/AddressSpace.zig");
pub const cache = @import("cache.zig");
pub const FlushRequest = @import("FlushRequest.zig");
pub const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
pub const MapType = @import("MapType.zig");
pub const Page = @import("Page.zig");
pub const resource_arena = @import("resource_arena.zig");

/// Maps a single page to a physical frame.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
/// - `map_type.protection` must not be `.none`
pub fn mapSinglePage(
    context: *cascade.Context,
    page_table: arch.paging.PageTable,
    virtual_address: core.VirtualAddress,
    physical_frame: phys.Frame,
    map_type: MapType,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_address.isAligned(arch.paging.standard_page_size));

    try arch.paging.mapSinglePage(
        context,
        page_table,
        virtual_address,
        physical_frame,
        map_type,
        physical_frame_allocator,
    );
}

/// Maps a virtual range using the standard page size.
///
/// Physical frames are allocated for each page in the virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
/// - `map_type.protection` must not be `.none`
pub fn mapRangeAndBackWithPhysicalFrames(
    context: *cascade.Context,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    map_type: MapType,
    flush_target: cascade.Environment,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer {
        // Unmap all pages that have been mapped.
        unmapRange(
            context,
            page_table,
            .{
                .address = virtual_range.address,
                .size = .from(current_virtual_address.value - virtual_range.address.value, .byte),
            },
            flush_target,
            .free,
            top_level_decision,
            physical_frame_allocator,
        );
    }

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        const physical_frame = try physical_frame_allocator.allocate(context);
        errdefer {
            var deallocate_frame_list: phys.FrameList = .{};
            deallocate_frame_list.push(physical_frame);
            physical_frame_allocator.deallocate(context, deallocate_frame_list);
        }

        try arch.paging.mapSinglePage(
            context,
            page_table,
            current_virtual_address,
            physical_frame,
            map_type,
            physical_frame_allocator,
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
/// - `map_type.protection` must not be `.none`
pub fn mapRangeToPhysicalRange(
    context: *cascade.Context,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
    flush_target: cascade.Environment,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.equal(physical_range.size));

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer {
        // Unmap all pages that have been mapped.
        unmapRange(
            context,
            page_table,
            .{
                .address = virtual_range.address,
                .size = .from(current_virtual_address.value - virtual_range.address.value, .byte),
            },
            flush_target,
            .keep,
            top_level_decision,
            physical_frame_allocator,
        );
    }

    var current_physical_address = physical_range.address;

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        try arch.paging.mapSinglePage(
            context,
            page_table,
            current_virtual_address,
            .fromAddress(current_physical_address),
            map_type,
            physical_frame_allocator,
        );

        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
        current_physical_address.moveForwardInPlace(arch.paging.standard_page_size);
    }
}

/// Unmaps a single page.
///
/// Performs TLB shootdown, prefer to use `unmapRange` instead.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
pub fn unmapSinglePage(
    context: *cascade.Context,
    page_table: arch.paging.PageTable,
    virtual_address: core.VirtualAddress,
    backing_pages: core.CleanupDecision,
    flush_target: cascade.Environment,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) void {
    std.debug.assert(virtual_address.isAligned(arch.paging.standard_page_size));

    var deallocate_frame_list: phys.FrameList = .{};

    arch.paging.unmapSinglePage(
        page_table,
        virtual_address,
        backing_pages,
        top_level_decision,
        &deallocate_frame_list,
    );

    var request: FlushRequest = .{
        .range = .fromAddr(virtual_address, arch.paging.standard_page_size),
        .flush_target = flush_target,
    };

    request.submitAndWait(context);

    physical_frame_allocator.deallocate(deallocate_frame_list);
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn unmapRange(
    context: *cascade.Context,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    flush_target: cascade.Environment,
    backing_page_decision: core.CleanupDecision,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) void {
    std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    var deallocate_frame_list: phys.FrameList = .{};

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    while (current_virtual_address.lessThan(last_virtual_address)) {
        arch.paging.unmapSinglePage(
            page_table,
            current_virtual_address,
            backing_page_decision,
            top_level_decision,
            &deallocate_frame_list,
        );
        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
    }

    var request: FlushRequest = .{
        .range = virtual_range,
        .flush_target = flush_target,
    };

    request.submitAndWait(context);

    physical_frame_allocator.deallocate(context, deallocate_frame_list);
}

/// Returns the virtual address corresponding to this physical address in the direct map.
pub fn directMapFromPhysical(physical_address: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = physical_address.value + globals.direct_map.address.value };
}

/// Returns the virtual address corresponding to this physical address in the non-cached direct map.
pub fn nonCachedDirectMapFromPhysical(physical_address: core.PhysicalAddress) core.VirtualAddress {
    return .{ .value = physical_address.value + globals.non_cached_direct_map.address.value };
}

/// Returns a virtual range corresponding to this physical range in the direct map.
pub fn directMapFromPhysicalRange(physical_range: core.PhysicalRange) core.VirtualRange {
    return .{
        .address = directMapFromPhysical(physical_range.address),
        .size = physical_range.size,
    };
}

/// Returns the physical address of the given virtual address if it is in the direct map.
pub fn physicalFromDirectMap(virtual_address: core.VirtualAddress) error{AddressNotInDirectMap}!core.PhysicalAddress {
    if (globals.direct_map.containsAddress(virtual_address)) {
        return .{ .value = virtual_address.value - globals.direct_map.address.value };
    }
    return error.AddressNotInDirectMap;
}

/// Returns the physical range of the given direct map virtual range.
pub fn physicalRangeFromDirectMap(virtual_range: core.VirtualRange) error{AddressNotInDirectMap}!core.PhysicalRange {
    if (globals.direct_map.fullyContainsRange(virtual_range)) {
        return .{
            .address = .fromInt(virtual_range.address.value - globals.direct_map.address.value),
            .size = virtual_range.size,
        };
    }
    return error.AddressNotInDirectMap;
}

/// Returns the physical address of the given kernel ELF section virtual address.
///
/// It is the caller's responsibility to ensure that the given virtual address is in the kernel ELF sections.
pub fn physicalFromKernelSectionUnsafe(virtual_address: core.VirtualAddress) core.PhysicalAddress {
    return .{ .value = virtual_address.value - globals.physical_to_virtual_offset.value };
}

pub fn onKernelPageFault(
    context: *cascade.Context,
    page_fault_details: PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    if (page_fault_details.faulting_address.lessThan(arch.paging.higher_half_start)) {
        @branchHint(.cold);

        cascade.debug.interruptSourcePanic(
            context,
            interrupt_frame,
            "kernel page fault in lower half\n{f}",
            .{page_fault_details},
        );
    }

    const region_type = globals.regions.containingAddress(page_fault_details.faulting_address) orelse {
        @branchHint(.cold);

        cascade.debug.interruptSourcePanic(
            context,
            interrupt_frame,
            "kernel page fault outside of any kernel region\n{f}",
            .{page_fault_details},
        );
    };

    switch (region_type) {
        .pageable_kernel_address_space => {
            @branchHint(.likely);
            globals.kernel_pageable_address_space.handlePageFault(context, page_fault_details) catch |err| switch (err) {
                error.NoMemory => std.debug.panic(
                    "no memory available to handle page fault in pageable kernel address space\n{f}",
                    .{page_fault_details},
                ),
                else => |e| cascade.debug.interruptSourcePanic(
                    context,
                    interrupt_frame,
                    "failed to handle page fault in pageable kernel address space: {t}\n{f}",
                    .{ e, page_fault_details },
                ),
            };
        },
        else => {
            @branchHint(.cold);

            cascade.debug.interruptSourcePanic(
                context,
                interrupt_frame,
                "kernel page fault in '{t}'\n{f}",
                .{ region_type, page_fault_details },
            );
        },
    }
}

pub const PageFaultDetails = struct {
    faulting_address: core.VirtualAddress,
    access_type: AccessType,
    fault_type: FaultType,

    /// The environment that the fault was triggered from.
    ///
    /// This is not necessarily the same as the environment of the task that triggered the fault as a user task may have
    /// triggered the fault while running in kernel mode.
    environment: cascade.Environment,

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
        try writer.print("environment: {t},\n", .{details.environment});

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
} || phys.FrameAllocator.AllocateError;

pub const globals = struct {
    /// The core page table.
    ///
    /// All other page tables start as a copy of this one.
    ///
    /// Initialized during `init.buildCorePageTable`.
    pub var core_page_table: arch.paging.PageTable = undefined;

    /// The kernel pageable address space.
    ///
    /// Used for pageable kernel memory like file caches and for loaning memory from and to user space.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    pub var kernel_pageable_address_space: cascade.mem.AddressSpace = undefined;

    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.setEarlyOffsets`.
    var virtual_base_address: core.VirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.setEarlyOffsets`.
    pub var virtual_offset: core.Size = undefined;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.setEarlyOffsets`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.setEarlyOffsets`.
    pub var direct_map: core.VirtualRange = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var non_cached_direct_map: core.VirtualRange = undefined;

    /// The layout of the memory regions of the cascade.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var regions: KernelMemoryRegion.List = undefined;
};

pub const initialization = struct {
    const MemorySystemInitializationData = struct {
        number_of_usable_pages: usize,
        number_of_usable_regions: usize,

        free_physical_regions: []const init.mem.phys.FreePhysicalRegion,
        kernel_regions: *KernelMemoryRegion.List,
        memory_map: []const init.exports.boot.MemoryMapEntry,

        core_page_table: arch.paging.PageTable,
    };

    pub fn initializeMemorySystem(context: *cascade.Context, initialization_data: MemorySystemInitializationData) !void {
        globals.non_cached_direct_map = initialization_data.kernel_regions.find(.non_cached_direct_map).?.range;
        globals.regions = initialization_data.kernel_regions.*;
        globals.core_page_table = initialization_data.core_page_table;

        init_log.debug(context, "initializing physical memory", .{});
        phys.initialization.initializePhysicalMemory(
            context,
            initialization_data.number_of_usable_pages,
            initialization_data.number_of_usable_regions,
            initialization_data.kernel_regions,
            initialization_data.memory_map,
            initialization_data.free_physical_regions,
        );

        init_log.debug(context, "initializing caches", .{});
        try resource_arena.global_init.initializeCache(context);
        try cache.init.initializeCaches(context);
        try AddressSpace.global_init.initializeCaches(context);

        init_log.debug(context, "initializing kernel and special heap", .{});
        try heap.init.initializeHeaps(context, initialization_data.kernel_regions);

        init_log.debug(context, "initializing tasks", .{});
        try cascade.Task.init.initializeTasks(context, initialization_data.kernel_regions);

        init_log.debug(context, "initializing processes", .{});
        try cascade.Process.init.initializeProcesses(context);

        init_log.debug(context, "initializing pageable kernel address space", .{});
        try globals.kernel_pageable_address_space.init(
            context,
            .{
                .name = try .fromSlice("pageable_kernel"),
                .range = initialization_data.kernel_regions.find(.pageable_kernel_address_space).?.range,
                .page_table = globals.core_page_table,
                .environment = .kernel,
            },
        );
    }

    pub const EarlyMemoryLayout = struct {
        /// The virtual base address that the kernel was loaded at.
        virtual_base_address: core.VirtualAddress,
        /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
        virtual_offset: core.Size,
        /// Offset from the virtual address of kernel sections to the physical address of the section.
        physical_to_virtual_offset: core.Size,
        /// Provides an identity mapping between virtual and physical addresses.
        direct_map: core.VirtualRange,
    };

    /// Set the kernels various offsets and the direct map early in the boot process.
    pub fn setEarlyMemoryLayout(early_memory_layout: EarlyMemoryLayout) void {
        globals.virtual_base_address = early_memory_layout.virtual_base_address;
        globals.virtual_offset = early_memory_layout.virtual_offset;
        globals.physical_to_virtual_offset = early_memory_layout.physical_to_virtual_offset;
        globals.direct_map = early_memory_layout.direct_map;
    }

    const init_log = cascade.debug.log.scoped(.init_mem);
};

const arch = @import("arch");
const init = @import("init");
const cascade = @import("cascade");

const core = @import("core");

const log = cascade.debug.log.scoped(.mem);
const std = @import("std");
