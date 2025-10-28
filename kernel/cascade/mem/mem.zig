// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

pub const AddressSpace = @import("address_space/AddressSpace.zig");
pub const cache = @import("cache.zig");
pub const FlushRequest = @import("FlushRequest.zig");
pub const heap = @import("heap.zig");
pub const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
pub const MapType = @import("MapType.zig");
pub const Page = @import("Page.zig");
pub const phys = @import("phys.zig");
pub const resource_arena = @import("resource_arena.zig");

const log = cascade.debug.log.scoped(.mem);

/// Maps a single page to a physical frame.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_address` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapSinglePage(
    current_task: *cascade.Task,
    page_table: arch.paging.PageTable,
    virtual_address: core.VirtualAddress,
    physical_frame: phys.Frame,
    map_type: MapType,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_address.isAligned(arch.paging.standard_page_size));
    }

    // TODO: replace with `mapRangeToPhysicalRange`

    try arch.paging.mapSinglePage(
        current_task,
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
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeAndBackWithPhysicalFrames(
    current_task: *cascade.Task,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    map_type: MapType,
    flush_target: cascade.Environment,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    }

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer {
        // Unmap all pages that have been mapped.
        unmapRange(
            current_task,
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

    // TODO: this can be optimized by implementing `arch.paging.mapRangeAndBackWithPhysicalFrames`
    //       this one is not as obviously good as the other TODO optimizations in this file as every arch will have to do
    //       the same physical frame allocation and errdefer deallocation

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        const physical_frame = try physical_frame_allocator.allocate(current_task);
        errdefer {
            var deallocate_frame_list: phys.FrameList = .{};
            deallocate_frame_list.push(physical_frame);
            physical_frame_allocator.deallocate(current_task, deallocate_frame_list);
        }

        try arch.paging.mapSinglePage(
            current_task,
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
/// - `virtual_range` must not already be mapped
/// - `map_type.protection` must not be `.none`
pub fn mapRangeToPhysicalRange(
    current_task: *cascade.Task,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
    flush_target: cascade.Environment,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    if (core.is_debug) {
        std.debug.assert(map_type.protection != .none);
        std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
        std.debug.assert(physical_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.equal(physical_range.size));
    }

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    errdefer {
        // Unmap all pages that have been mapped.
        unmapRange(
            current_task,
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

    // TODO: this can be optimized by implementing `arch.paging.mapRange`

    var current_physical_address = physical_range.address;

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        try arch.paging.mapSinglePage(
            current_task,
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

/// Unmaps a virtual range.
///
/// Only unmaps the pages in the range that are actually mapped.
///
/// Performs TLB shootdown.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn unmapRange(
    current_task: *cascade.Task,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    flush_target: cascade.Environment,
    backing_page_decision: core.CleanupDecision,
    top_level_decision: core.CleanupDecision,
    physical_frame_allocator: phys.FrameAllocator,
) void {
    if (core.is_debug) {
        std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    }

    var deallocate_frame_list: phys.FrameList = .{};

    // TODO: this can be optimized by implementing `arch.paging.unmapRange`

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

    // TODO: once `arch.paging.unmapRange` is implemented it can return the actual range unmapped and we can use that
    //       for the flush instead of the entire virtual range

    var request: FlushRequest = .{
        .range = virtual_range,
        .flush_target = flush_target,
    };

    request.submitAndWait(current_task);

    physical_frame_allocator.deallocate(current_task, deallocate_frame_list);
}

/// Changes the protection of the given virtual range.
///
/// Only modifies the pages in the range that are actually mapped.
///
/// Performs TLB shootdown if required.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn changeProtection(
    current_task: *cascade.Task,
    page_table: arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    flush_target: cascade.Environment,
    map_type: cascade.mem.MapType,
) void {
    if (core.is_debug) {
        std.debug.assert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    }

    // TODO: this can be optimized by implementing `arch.paging.changeProtection`

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    while (current_virtual_address.lessThan(last_virtual_address)) {
        arch.paging.changeSinglePageProtection(
            page_table,
            current_virtual_address,
            map_type,
        );
        current_virtual_address.moveForwardInPlace(arch.paging.standard_page_size);
    }

    // TODO: once `arch.paging.changeProtection` is implemented it can return the actual range modified and we can use
    //       that for the flush instead of the entire virtual range

    var request: FlushRequest = .{
        .range = virtual_range,
        .flush_target = flush_target,
    };

    request.submitAndWait(current_task);
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
    current_task: *cascade.Task,
    page_fault_details: PageFaultDetails,
    interrupt_frame: arch.interrupts.InterruptFrame,
) void {
    if (page_fault_details.faulting_address.lessThan(arch.paging.higher_half_start)) {
        @branchHint(.cold);

        const process = switch (current_task.type) {
            .kernel => {
                @branchHint(.cold);
                cascade.debug.interruptSourcePanic(
                    current_task,
                    interrupt_frame,
                    "kernel page fault in lower half\n{f}",
                    .{page_fault_details},
                );
            },
            .user => current_task.toThread().process,
        };

        if (!page_fault_details.faulting_environment.kernel.access_to_user_memory_enabled) {
            @branchHint(.cold);

            cascade.debug.interruptSourcePanic(
                current_task,
                interrupt_frame,
                "kernel accessed user memory\n{f}",
                .{page_fault_details},
            );
        }

        process.address_space.handlePageFault(
            current_task,
            page_fault_details,
        ) catch |err|
            cascade.debug.interruptSourcePanic(
                current_task,
                interrupt_frame,
                "kernel page fault in user memory failed: {t}\n{f}",
                .{ err, page_fault_details },
            );

        return;
    }

    const region_type = globals.regions.containingAddress(page_fault_details.faulting_address) orelse {
        @branchHint(.cold);

        cascade.debug.interruptSourcePanic(
            current_task,
            interrupt_frame,
            "kernel page fault outside of any kernel region\n{f}",
            .{page_fault_details},
        );
    };

    switch (region_type) {
        .pageable_kernel_address_space => {
            @branchHint(.likely);
            globals.kernel_pageable_address_space.handlePageFault(current_task, page_fault_details) catch |err| switch (err) {
                error.OutOfMemory => std.debug.panic(
                    "no memory available to handle page fault in pageable kernel address space\n{f}",
                    .{page_fault_details},
                ),
                else => |e| cascade.debug.interruptSourcePanic(
                    current_task,
                    interrupt_frame,
                    "failed to handle page fault in pageable kernel address space: {t}\n{f}",
                    .{ e, page_fault_details },
                ),
            };
        },
        else => {
            @branchHint(.cold);

            cascade.debug.interruptSourcePanic(
                current_task,
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
    faulting_environment: FaultingEnvironment,

    pub const FaultingEnvironment = union(cascade.Environment.Type) {
        kernel: struct {
            access_to_user_memory_enabled: bool,
        },
        user: *cascade.Process,
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
        try writer.print("faulting_environment: {t},\n", .{details.faulting_environment});

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
    pub var kernel_pageable_address_space: AddressSpace = undefined;

    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    var virtual_base_address: core.VirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    pub var virtual_offset: core.Size = undefined;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.determineEarlyMemoryLayout`.
    var direct_map: core.VirtualRange = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    var non_cached_direct_map: core.VirtualRange = undefined;

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

        const virtual_offset = core.Size.from(
            base_address.virtual.value - cascade.config.kernel_base_address.value,
            .byte,
        );
        globals.virtual_offset = virtual_offset;

        globals.physical_to_virtual_offset = core.Size.from(
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

        globals.direct_map = core.VirtualRange.fromAddr(
            boot.directMapAddress() orelse @panic("direct map address not provided"),
            direct_map_size,
        );
    }

    pub fn logEarlyMemoryLayout(current_task: *cascade.Task) void {
        if (!init_log.levelEnabled(.debug)) return;

        init_log.debug(current_task, "kernel memory offsets:", .{});

        init_log.debug(current_task, "  virtual base address:       {f}", .{globals.virtual_base_address});
        init_log.debug(current_task, "  virtual offset:             0x{x:0>16}", .{globals.virtual_offset.value});
        init_log.debug(current_task, "  physical to virtual offset: 0x{x:0>16}", .{globals.physical_to_virtual_offset.value});
        init_log.debug(current_task, "  direct map:                 {f}", .{globals.direct_map});
    }

    pub fn initializeMemorySystem(current_task: *cascade.Task) !void {
        var memory_map: MemoryMap = .{};

        const number_of_usable_pages, const number_of_usable_regions = try fillMemoryMap(
            current_task,
            &memory_map,
        );

        const kernel_regions = &globals.regions;

        init_log.debug(current_task, "building kernel memory layout", .{});
        buildMemoryLayout(
            current_task,
            number_of_usable_pages,
            number_of_usable_regions,
            kernel_regions,
        );
        globals.non_cached_direct_map = kernel_regions.find(.non_cached_direct_map).?.range;

        init_log.debug(current_task, "building core page table", .{});
        globals.core_page_table = buildAndLoadCorePageTable(
            current_task,
            kernel_regions,
        );

        init_log.debug(current_task, "initializing physical memory", .{});
        phys.init.initializePhysicalMemory(
            current_task,
            number_of_usable_pages,
            number_of_usable_regions,
            kernel_regions.find(.pages).?.range,
            memory_map.constSlice(),
        );

        init_log.debug(current_task, "initializing caches", .{});
        try cache.init.initializeCaches(current_task);
        try resource_arena.init.initializeCaches(current_task);
        try AddressSpace.AnonymousMap.init.initializeCaches(current_task);
        try AddressSpace.AnonymousPage.init.initializeCaches(current_task);
        try AddressSpace.Entry.init.initializeCaches(current_task);

        init_log.debug(current_task, "initializing kernel and special heap", .{});
        try heap.init.initializeHeaps(current_task, kernel_regions);

        init_log.debug(current_task, "initializing tasks", .{});
        try cascade.Task.init.initializeTasks(current_task, kernel_regions);

        init_log.debug(current_task, "initializing processes", .{});
        try cascade.Process.init.initializeProcesses(current_task);

        init_log.debug(current_task, "initializing pageable kernel address space", .{});
        try globals.kernel_pageable_address_space.init(
            current_task,
            .{
                .name = try .fromSlice("pageable_kernel"),
                .range = kernel_regions.find(.pageable_kernel_address_space).?.range,
                .page_table = globals.core_page_table,
                .environment = .kernel,
            },
        );
    }

    fn fillMemoryMap(current_task: *cascade.Task, memory_map: *MemoryMap) !struct { usize, usize } {
        var memory_iter = boot.memoryMap(.forward) catch @panic("no memory map");

        var number_of_usable_pages: usize = 0;
        var number_of_usable_regions: usize = 0;

        init_log.debug(current_task, "bootloader provided memory map:", .{});

        while (memory_iter.next()) |entry| {
            init_log.debug(current_task, "\t{f}", .{entry});

            try memory_map.append(entry);

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

        init_log.debug(current_task, "usable pages in memory map: {d}", .{number_of_usable_pages});
        init_log.debug(current_task, "usable regions in memory map: {d}", .{number_of_usable_regions});

        return .{ number_of_usable_pages, number_of_usable_regions };
    }

    fn buildMemoryLayout(
        current_task: *cascade.Task,
        number_of_usable_pages: usize,
        number_of_usable_regions: usize,
        kernel_regions: *KernelMemoryRegion.List,
    ) void {
        registerKernelSections(kernel_regions);
        registerDirectMaps(kernel_regions);
        registerHeaps(kernel_regions);
        registerPages(kernel_regions, number_of_usable_pages, number_of_usable_regions);

        kernel_regions.sort();

        if (init_log.levelEnabled(.debug)) {
            init_log.debug(current_task, "kernel memory layout:", .{});

            for (kernel_regions.constSlice()) |region| {
                init_log.debug(current_task, "\t{f}", .{region});
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
        const sdf_range = core.VirtualRange.fromSlice(u8, sdf_slice);

        const sections: []const struct {
            core.VirtualAddress,
            core.VirtualAddress,
            KernelMemoryRegion.Type,
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

            if (core.is_debug) std.debug.assert(end_address.greaterThan(start_address));

            const virtual_range: core.VirtualRange = .fromAddr(
                start_address,
                core.Size.from(end_address.value - start_address.value, .byte)
                    .alignForward(arch.paging.standard_page_size),
            );

            if (virtual_range.containsAddress(.undefined_address)) {
                std.debug.panic("kernel section {t} overlaps with the undefined address", .{region_type});
            }

            kernel_regions.append(.{
                .range = virtual_range,
                .type = region_type,
            });
        }
    }

    fn registerDirectMaps(kernel_regions: *KernelMemoryRegion.List) void {
        const direct_map = globals.direct_map;

        // does the direct map range overlap a pre-existing region?
        for (kernel_regions.constSlice()) |region| {
            if (region.range.anyOverlap(direct_map)) {
                std.debug.panic("direct map overlaps region: {f}", .{region});
            }
        }

        if (direct_map.containsAddress(.undefined_address)) {
            std.debug.panic("direct map overlaps with the undefined address", .{});
        }

        kernel_regions.append(.{
            .range = direct_map,
            .type = .direct_map,
        });

        const non_cached_direct_map = kernel_regions.findFreeRange(
            direct_map.size,
            arch.paging.largest_page_size,
        ) orelse @panic("no free range for non-cached direct map");

        kernel_regions.append(.{
            .range = non_cached_direct_map,
            .type = .non_cached_direct_map,
        });
    }

    fn registerHeaps(kernel_regions: *KernelMemoryRegion.List) void {
        const size_of_top_level = arch.paging.init.sizeOfTopLevelEntry();

        const kernel_heap_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the kernel heap");

        kernel_regions.append(.{
            .range = kernel_heap_range,
            .type = .kernel_heap,
        });

        const special_heap_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the special heap");

        kernel_regions.append(.{
            .range = special_heap_range,
            .type = .special_heap,
        });

        const kernel_stacks_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the kernel stacks");

        kernel_regions.append(.{
            .range = kernel_stacks_range,
            .type = .kernel_stacks,
        });

        const pageable_kernel_address_space_range = kernel_regions.findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the pageable kernel address space");

        kernel_regions.append(.{
            .range = pageable_kernel_address_space_range,
            .type = .pageable_kernel_address_space,
        });
    }

    fn registerPages(
        kernel_regions: *KernelMemoryRegion.List,
        number_of_usable_pages: usize,
        number_of_usable_regions: usize,
    ) void {
        if (core.is_debug) std.debug.assert(@alignOf(Page.Region) <= arch.paging.standard_page_size.value);

        const size_of_regions = core.Size.of(Page.Region)
            .multiplyScalar(number_of_usable_regions);

        const size_of_pages = core.Size.of(Page)
            .multiplyScalar(number_of_usable_pages);

        const range_size =
            size_of_regions
                .alignForward(.from(@alignOf(Page), .byte))
                .add(size_of_pages)
                .alignForward(arch.paging.standard_page_size);

        const pages_range = kernel_regions.findFreeRange(
            range_size,
            arch.paging.standard_page_size,
        ) orelse @panic("no space in kernel memory layout for the pages array");

        kernel_regions.append(.{
            .range = pages_range,
            .type = .pages,
        });
    }

    fn buildAndLoadCorePageTable(
        current_task: *cascade.Task,
        kernel_regions: *KernelMemoryRegion.List,
    ) arch.paging.PageTable {
        const core_page_table = arch.paging.PageTable.create(
            phys.init.bootstrap_allocator.allocate(current_task) catch unreachable,
        );

        for (kernel_regions.constSlice()) |region| {
            init_log.debug(current_task, "mapping '{t}' into the core page table", .{region.type});

            const map_info = region.mapInfo();

            switch (map_info) {
                .top_level => arch.paging.init.fillTopLevel(
                    current_task,
                    core_page_table,
                    region.range,
                    phys.init.bootstrap_allocator,
                ) catch |err| {
                    std.debug.panic("failed to fill top level for {f}: {t}", .{ region, err });
                },
                .full => |full| arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    current_task,
                    core_page_table,
                    region.range,
                    full.physical_range,
                    full.map_type,
                    phys.init.bootstrap_allocator,
                ) catch |err| {
                    std.debug.panic("failed to full map {f}: {t}", .{ region, err });
                },
                .back_with_frames => |map_type| {
                    mapRangeAndBackWithPhysicalFrames(
                        current_task,
                        core_page_table,
                        region.range,
                        map_type,
                        .kernel,
                        .keep,
                        phys.init.bootstrap_allocator,
                    ) catch |err| {
                        std.debug.panic("failed to back with frames {f}: {t}", .{ region, err });
                    };
                },
            }
        }

        init_log.debug(current_task, "loading core page table", .{});
        core_page_table.load();

        return core_page_table;
    }

    const MemoryMap = core.containers.BoundedArray(
        boot.MemoryMap.Entry,
        cascade.config.maximum_number_of_memory_map_entries,
    );
};
