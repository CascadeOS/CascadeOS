// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const heap = @import("heap.zig");
pub const phys = @import("phys.zig");

pub const AddressSpace = @import("address_space/AddressSpace.zig");
pub const cache = @import("cache.zig");
pub const MapType = @import("MapType.zig");
pub const FlushRequest = @import("FlushRequest.zig");
pub const ResourceArena = @import("ResourceArena.zig");
pub const Page = @import("Page.zig");

pub const MapError = error{
    AlreadyMapped,

    /// This is used to surface errors from the underlying paging implementation that are architecture specific.
    MappingNotValid,
} || phys.FrameAllocator.AllocateError;

/// Maps a single page to a physical frame.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
/// - `map_type.protection` must not be `.none`
pub fn mapSinglePage(
    page_table: kernel.arch.paging.PageTable,
    virtual_address: core.VirtualAddress,
    physical_frame: phys.Frame,
    map_type: MapType,
    keep_top_level: bool,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_address.isAligned(kernel.arch.paging.standard_page_size));

    try kernel.arch.paging.map(
        page_table,
        virtual_address,
        physical_frame,
        map_type,
        keep_top_level,
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
    current_task: *kernel.Task,
    page_table: kernel.arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    map_type: MapType,
    flush_target: kernel.Context,
    keep_top_level: bool,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));

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
            true,
            flush_target,
            keep_top_level,
            physical_frame_allocator,
        );
    }

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        const physical_frame = try physical_frame_allocator.allocate();
        errdefer {
            var deallocate_frame_list: phys.FrameList = .{};
            deallocate_frame_list.push(physical_frame);
            physical_frame_allocator.deallocate(deallocate_frame_list);
        }

        try kernel.arch.paging.map(
            page_table,
            current_virtual_address,
            physical_frame,
            map_type,
            keep_top_level,
            physical_frame_allocator,
        );

        current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
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
    current_task: *kernel.Task,
    page_table: kernel.arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    physical_range: core.PhysicalRange,
    map_type: MapType,
    flush_target: kernel.Context,
    keep_top_level: bool,
    physical_frame_allocator: phys.FrameAllocator,
) MapError!void {
    std.debug.assert(map_type.protection != .none);
    std.debug.assert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(physical_range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(physical_range.size.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.equal(physical_range.size));

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
            false,
            flush_target,
            keep_top_level,
            physical_frame_allocator,
        );
    }

    var current_physical_address = physical_range.address;

    while (current_virtual_address.lessThanOrEqual(last_virtual_address)) {
        try kernel.arch.paging.map(
            page_table,
            current_virtual_address,
            .fromAddress(current_physical_address),
            map_type,
            keep_top_level,
            physical_frame_allocator,
        );

        current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
        current_physical_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
    }
}

/// Unmaps a single page.
///
/// Performs TLB shootdown, prefer to use `unmapRange` instead.
///
/// **REQUIREMENTS**:
/// - `virtual_address` must be aligned to `arch.paging.standard_page_size`
pub fn unmapSinglePage(
    current_task: *kernel.Task,
    page_table: kernel.arch.paging.PageTable,
    virtual_address: core.VirtualAddress,
    free_backing_pages: bool,
    flush_target: kernel.Mode,
    keep_top_level: bool,
    physical_frame_allocator: phys.FrameAllocator,
) void {
    std.debug.assert(virtual_address.isAligned(kernel.arch.paging.standard_page_size));

    var deallocate_frame_list: phys.FrameList = .{};

    kernel.arch.paging.unmap(
        page_table,
        virtual_address,
        free_backing_pages,
        keep_top_level,
        &deallocate_frame_list,
    );

    var request: FlushRequest = .{
        .range = .fromAddr(virtual_address, kernel.arch.paging.standard_page_size),
        .flush_target = flush_target,
    };

    request.submitAndWait(current_task);

    physical_frame_allocator.deallocate(deallocate_frame_list);
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn unmapRange(
    current_task: *kernel.Task,
    page_table: kernel.arch.paging.PageTable,
    virtual_range: core.VirtualRange,
    free_backing_pages: bool,
    flush_target: kernel.Context,
    keep_top_level: bool,
    physical_frame_allocator: phys.FrameAllocator,
) void {
    std.debug.assert(virtual_range.address.isAligned(kernel.arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(kernel.arch.paging.standard_page_size));

    var deallocate_frame_list: phys.FrameList = .{};

    const last_virtual_address = virtual_range.last();
    var current_virtual_address = virtual_range.address;

    while (current_virtual_address.lessThan(last_virtual_address)) {
        kernel.arch.paging.unmap(
            page_table,
            current_virtual_address,
            free_backing_pages,
            keep_top_level,
            &deallocate_frame_list,
        );
        current_virtual_address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
    }

    var request: FlushRequest = .{
        .range = virtual_range,
        .flush_target = flush_target,
    };

    request.submitAndWait(current_task);

    physical_frame_allocator.deallocate(deallocate_frame_list);
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

pub fn onKernelPageFault(current_task: *kernel.Task, page_fault_details: PageFaultDetails) void {
    if (page_fault_details.faulting_address.lessThan(kernel.arch.paging.higher_half_start)) {
        @branchHint(.cold);
        std.debug.panic("kernel page fault in lower half\n{}", .{page_fault_details});
    }

    const region_type = kernelRegionContainingAddress(page_fault_details.faulting_address) orelse {
        @branchHint(.cold);
        std.debug.panic("kernel page fault outside of any kernel region\n{}", .{page_fault_details});
    };

    switch (region_type) {
        .pageable_kernel_address_space => {
            @branchHint(.likely);
            globals.kernel_pageable_address_space.handlePageFault(current_task, page_fault_details) catch |err|
                std.debug.panic(
                    "failed to handle page fault in pageable kernel address space: {s}\n{}",
                    .{ @errorName(err), page_fault_details },
                );
        },
        else => {
            @branchHint(.cold);
            std.debug.panic(
                "kernel page fault in '{s}'\n{}",
                .{ @tagName(region_type), page_fault_details },
            );
        },
    }
}

pub const PageFaultDetails = struct {
    faulting_address: core.VirtualAddress,
    access_type: AccessType,
    fault_type: FaultType,
    context: kernel.Context,

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

    pub fn print(details: PageFaultDetails, writer: std.io.AnyWriter, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("PageFaultDetails{\n");

        try writer.writeByteNTimes(' ', new_indent);
        try writer.writeAll("faulting_address: ");
        try details.faulting_address.print(writer, new_indent);
        try writer.writeAll(",\n");

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("access_type: {s},\n", .{@tagName(details.access_type)});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("fault_type: {s},\n", .{@tagName(details.fault_type)});

        try writer.writeByteNTimes(' ', new_indent);
        try writer.print("context: {s},\n", .{@tagName(details.context)});

        try writer.writeByteNTimes(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        details: PageFaultDetails,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return if (@TypeOf(writer) == std.io.AnyWriter)
            PageFaultDetails.print(details, writer, 0)
        else
            PageFaultDetails.print(details, writer.any(), 0);
    }
};

fn kernelRegionContainingAddress(address: core.VirtualAddress) ?KernelMemoryRegion.Type {
    for (globals.regions.constSlice()) |region| {
        if (region.range.containsAddress(address)) return region.type;
    }
    return null;
}

pub const globals = struct {
    /// The core page table.
    ///
    /// All other page tables start as a copy of this one.
    ///
    /// Initialized during `init.buildCorePageTable`.
    pub var core_page_table: kernel.arch.paging.PageTable = undefined;

    /// The kernel pageable address space.
    ///
    /// Used for pageable kernel memory like file caches and for loaning memory from and to user space.
    ///
    /// Initialized during `init.initializeMemorySystem`.
    pub var kernel_pageable_address_space: kernel.mem.AddressSpace = undefined;

    /// The virtual base address that the kernel was loaded at.
    ///
    /// Initialized during `init.earlyDetermineOffsets`.
    var virtual_base_address: core.VirtualAddress = undefined;

    /// The offset from the requested ELF virtual base address to the address that the kernel was actually loaded at.
    ///
    /// Initialized during `init.earlyDetermineOffsets`.
    pub var virtual_offset: core.Size = undefined;

    /// Offset from the virtual address of kernel sections to the physical address of the section.
    ///
    /// Initialized during `init.earlyDetermineOffsets`.
    pub var physical_to_virtual_offset: core.Size = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Initialized during `init.earlyDetermineOffsets`.
    var direct_map: core.VirtualRange = undefined;

    /// Provides an identity mapping between virtual and physical addresses.
    ///
    /// Caching is disabled for this mapping.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    var non_cached_direct_map: core.VirtualRange = undefined;

    /// The layout of the memory regions of the kernel.
    ///
    /// Initialized during `init.buildMemoryLayout`.
    var regions: Regions = undefined;

    const Regions = std.BoundedArray(
        KernelMemoryRegion,
        std.meta.tags(KernelMemoryRegion.Type).len,
    );
};

pub const init = struct {
    pub fn initializeMemorySystem(current_task: *kernel.Task) !void {
        init_log.debug("initializing bootstrap physical frame allocator", .{});
        phys.init.initializeBootstrapFrameAllocator();

        const number_of_usable_pages, const number_of_usable_regions = numberOfUsablePagesAndRegions();

        init_log.debug("building kernel memory layout", .{});
        const result = buildMemoryLayout(number_of_usable_pages, number_of_usable_regions);

        init_log.debug("building core page table", .{});
        buildAndLoadCorePageTable(current_task);

        init_log.debug("initializing physical memory", .{});
        phys.init.initializePhysicalMemory(number_of_usable_pages, number_of_usable_regions, result.pages_range);

        init_log.debug("initializing caches", .{});
        try ResourceArena.global_init.initializeCache();
        try cache.init.initializeCaches();
        try AddressSpace.global_init.initializeCaches();

        init_log.debug("initializing kernel and special heap", .{});
        try heap.init.initializeHeaps(current_task, result.heap_range, result.special_heap_range);

        init_log.debug("initializing task stacks and cache", .{});
        try kernel.Task.init.initializeTaskStacksAndCache(current_task, result.stacks_range);

        init_log.debug("initializing pageable kernel address space", .{});
        try globals.kernel_pageable_address_space.init(
            current_task,
            .{
                .name = try .fromSlice("pageable_kernel"),
                .range = result.pageable_kernel_address_space_range,
                .page_table = globals.core_page_table,
                .context = .kernel,
            },
        );
    }

    fn numberOfUsablePagesAndRegions() struct { usize, usize } {
        var memory_iter = kernel.boot.memoryMap(.forward) catch @panic("no memory map");

        var number_of_usable_pages: usize = 0;
        var number_of_usable_regions: usize = 0;

        while (memory_iter.next()) |entry| {
            if (!entry.type.isUsable()) continue;
            if (entry.range.size.value == 0) continue;

            number_of_usable_regions += 1;

            number_of_usable_pages += std.math.divExact(
                usize,
                entry.range.size.value,
                kernel.arch.paging.standard_page_size.value,
            ) catch std.debug.panic(
                "memory map entry size is not a multiple of page size: {}",
                .{entry},
            );
        }

        return .{ number_of_usable_pages, number_of_usable_regions };
    }

    const MemoryLayoutResult = struct {
        pages_range: core.VirtualRange,
        heap_range: core.VirtualRange,
        special_heap_range: core.VirtualRange,
        stacks_range: core.VirtualRange,

        pageable_kernel_address_space_range: core.VirtualRange,
    };

    fn buildMemoryLayout(number_of_usable_pages: usize, number_of_usable_regions: usize) MemoryLayoutResult {
        registerKernelSections();
        registerDirectMaps();
        const heaps = registerHeaps();
        const pages_range = registerPages(number_of_usable_pages, number_of_usable_regions);

        sortKernelMemoryRegions();

        if (init_log.levelEnabled(.debug)) {
            init_log.debug("kernel memory layout:", .{});

            for (globals.regions.constSlice()) |region| {
                init_log.debug("\t{}", .{region});
            }
        }

        return .{
            .pages_range = pages_range,
            .heap_range = heaps.kernel_heap_range,
            .special_heap_range = heaps.special_heap_range,
            .stacks_range = heaps.kernel_stacks_range,

            .pageable_kernel_address_space_range = heaps.pageable_kernel_address_space_range,
        };
    }

    fn registerKernelSections() void {
        const linker_symbols = struct {
            extern const __text_start: u8;
            extern const __text_end: u8;
            extern const __rodata_start: u8;
            extern const __rodata_end: u8;
            extern const __data_start: u8;
            extern const __data_end: u8;
        };

        const sdf_slice = kernel.debug.sdfSlice() catch &.{};
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

            std.debug.assert(end_address.greaterThan(start_address));

            const virtual_range: core.VirtualRange = .fromAddr(
                start_address,
                core.Size.from(end_address.value - start_address.value, .byte)
                    .alignForward(kernel.arch.paging.standard_page_size),
            );

            globals.regions.appendAssumeCapacity(.{
                .range = virtual_range,
                .type = region_type,
            });
        }
    }

    fn registerDirectMaps() void {
        const direct_map = globals.direct_map;

        // does the direct map range overlap a pre-existing region?
        for (globals.regions.constSlice()) |region| {
            if (region.range.fullyContainsRange(direct_map)) {
                std.debug.panic("direct map overlaps region: {}", .{region});
                return error.DirectMapOverlapsRegion;
            }
        }

        globals.regions.appendAssumeCapacity(.{
            .range = direct_map,
            .type = .direct_map,
        });

        const non_cached_direct_map = findFreeRange(
            direct_map.size,
            kernel.arch.paging.largest_page_size,
        ) orelse @panic("no free range for non-cached direct map");

        globals.non_cached_direct_map = non_cached_direct_map;

        globals.regions.appendAssumeCapacity(.{
            .range = non_cached_direct_map,
            .type = .non_cached_direct_map,
        });
    }

    const RegisterHeapsResult = struct {
        kernel_heap_range: core.VirtualRange,
        special_heap_range: core.VirtualRange,
        kernel_stacks_range: core.VirtualRange,

        pageable_kernel_address_space_range: core.VirtualRange,
    };

    fn registerHeaps() RegisterHeapsResult {
        const size_of_top_level = kernel.arch.paging.init.sizeOfTopLevelEntry();

        const kernel_heap_range = findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the kernel heap");

        globals.regions.appendAssumeCapacity(.{
            .range = kernel_heap_range,
            .type = .kernel_heap,
        });

        const special_heap_range = findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the special heap");

        globals.regions.appendAssumeCapacity(.{
            .range = special_heap_range,
            .type = .special_heap,
        });

        const kernel_stacks_range = findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the kernel stacks");

        globals.regions.appendAssumeCapacity(.{
            .range = kernel_stacks_range,
            .type = .kernel_stacks,
        });

        const pageable_kernel_address_space_range = findFreeRange(
            size_of_top_level,
            size_of_top_level,
        ) orelse
            @panic("no space in kernel memory layout for the pageable kernel address space");

        globals.regions.appendAssumeCapacity(.{
            .range = pageable_kernel_address_space_range,
            .type = .pageable_kernel_address_space,
        });

        return .{
            .kernel_heap_range = kernel_heap_range,
            .special_heap_range = special_heap_range,
            .kernel_stacks_range = kernel_stacks_range,

            .pageable_kernel_address_space_range = pageable_kernel_address_space_range,
        };
    }

    fn registerPages(number_of_usable_pages: usize, number_of_usable_regions: usize) core.VirtualRange {
        std.debug.assert(@alignOf(Page.Region) <= kernel.arch.paging.standard_page_size.value);

        const size_of_regions = core.Size.of(Page.Region)
            .multiplyScalar(number_of_usable_regions);

        const size_of_pages = core.Size.of(Page)
            .multiplyScalar(number_of_usable_pages);

        const range_size =
            size_of_regions
                .alignForward(.from(@alignOf(Page), .byte))
                .add(size_of_pages)
                .alignForward(kernel.arch.paging.standard_page_size);

        const pages_range = findFreeRange(
            range_size,
            kernel.arch.paging.standard_page_size,
        ) orelse @panic("no space in kernel memory layout for the pages array");

        globals.regions.appendAssumeCapacity(.{
            .range = pages_range,
            .type = .pages,
        });

        return pages_range;
    }

    fn buildAndLoadCorePageTable(current_task: *kernel.Task) void {
        globals.core_page_table = kernel.arch.paging.PageTable.create(
            phys.init.bootstrap_allocator.allocate() catch unreachable,
        );

        for (globals.regions.constSlice()) |region| {
            init_log.debug("mapping '{s}' into the core page table", .{@tagName(region.type)});

            const map_info = region.mapInfo();

            switch (map_info) {
                .top_level => kernel.arch.paging.init.fillTopLevel(
                    globals.core_page_table,
                    region.range,
                    phys.init.bootstrap_allocator,
                ) catch |err| {
                    std.debug.panic("failed to fill top level for {}: {s}", .{ region, @errorName(err) });
                },
                .full => |full| kernel.arch.paging.init.mapToPhysicalRangeAllPageSizes(
                    globals.core_page_table,
                    region.range,
                    full.physical_range,
                    full.map_type,
                    phys.init.bootstrap_allocator,
                ) catch |err| {
                    std.debug.panic("failed to full map {}: {s}", .{ region, @errorName(err) });
                },
                .back_with_frames => |map_type| {
                    mapRangeAndBackWithPhysicalFrames(
                        current_task,
                        globals.core_page_table,
                        region.range,
                        map_type,
                        .kernel,
                        true,
                        phys.init.bootstrap_allocator,
                    ) catch |err| {
                        std.debug.panic("failed to back with frames {}: {s}", .{ region, @errorName(err) });
                    };
                },
            }
        }

        init_log.debug("loading core page table", .{});
        globals.core_page_table.load();
    }

    /// Determine various offsets used by the kernel early in the boot process.
    pub fn earlyDetermineOffsets() void {
        const base_address = kernel.boot.kernelBaseAddress() orelse
            @panic("no kernel base address");

        globals.virtual_base_address = base_address.virtual;

        globals.virtual_offset = core.Size.from(
            base_address.virtual.value - kernel.config.kernel_base_address.value,
            .byte,
        );

        globals.physical_to_virtual_offset = core.Size.from(
            base_address.virtual.value - base_address.physical.value,
            .byte,
        );

        const direct_map_size = direct_map_size: {
            const last_memory_map_entry = last_memory_map_entry: {
                var memory_map_iterator = kernel.boot.memoryMap(.backward) catch @panic("no memory map");
                break :last_memory_map_entry memory_map_iterator.next() orelse @panic("no memory map entries");
            };

            var direct_map_size = core.Size.from(last_memory_map_entry.range.last().value, .byte);

            // We ensure that the lowest 4GiB are always mapped.
            const four_gib = core.Size.from(4, .gib);
            if (direct_map_size.lessThan(four_gib)) direct_map_size = four_gib;

            // We align the length of the direct map to `largest_page_size` to allow large pages to be used for the mapping.
            direct_map_size.alignForwardInPlace(kernel.arch.paging.largest_page_size);

            break :direct_map_size direct_map_size;
        };

        globals.direct_map = core.VirtualRange.fromAddr(
            kernel.boot.directMapAddress() orelse @panic("direct map address not provided"),
            direct_map_size,
        );
    }

    pub fn logEarlyOffsets() void {
        if (!init_log.levelEnabled(.debug)) return;

        init_log.debug("kernel memory offsets:", .{});

        init_log.debug("  virtual base address:       {}", .{globals.virtual_base_address});
        init_log.debug("  virtual offset:             0x{x:0>16}", .{globals.virtual_offset.value});
        init_log.debug("  physical to virtual offset: 0x{x:0>16}", .{globals.physical_to_virtual_offset.value});
    }

    fn sortKernelMemoryRegions() void {
        std.mem.sort(KernelMemoryRegion, globals.regions.slice(), {}, struct {
            fn lessThanFn(context: void, region: KernelMemoryRegion, other_region: KernelMemoryRegion) bool {
                _ = context;
                return region.range.address.lessThan(other_region.range.address);
            }
        }.lessThanFn);
    }

    fn findFreeRange(size: core.Size, alignment: core.Size) ?core.VirtualRange {
        // needs the regions to be sorted
        sortKernelMemoryRegions();

        const regions = globals.regions.constSlice();

        var current_address = kernel.arch.paging.higher_half_start;
        current_address.alignForwardInPlace(alignment);

        var i: usize = 0;

        while (true) {
            const region = if (i < regions.len) regions[i] else {
                const size_of_free_range = core.Size.from(
                    (kernel.arch.paging.largest_higher_half_virtual_address.value) - current_address.value,
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

    const init_log = kernel.debug.log.scoped(.init_mem);
};

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const KernelMemoryRegion = @import("KernelMemoryRegion.zig");
const log = kernel.debug.log.scoped(.mem);
