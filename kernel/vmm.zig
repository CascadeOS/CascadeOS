// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const KernelMemoryLayout = @import("vmm/KernelMemoryLayout.zig");
pub const MapType = @import("vmm/MapType.zig");
pub const MemoryRegion = @import("vmm/MemoryRegion.zig");

const arch = kernel.arch;
const paging = kernel.arch.paging;
const PageTable = paging.PageTable;

const log = kernel.log.scoped(.virt_mm);

pub var kernel_page_table: *arch.paging.PageTable = undefined;
pub var memory_layout: KernelMemoryLayout = .{};

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
pub fn mapRange(page_table: *PageTable, virtual_range: kernel.VirtualRange, map_type: MapType) !void {
    core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    const virtual_range_end = virtual_range.end();
    var current_virtual_range = kernel.VirtualRange.fromAddr(virtual_range.address, kernel.arch.paging.standard_page_size);

    errdefer {
        // Unmap all pages that have been mapped.
        while (current_virtual_range.address.greaterThanOrEqual(virtual_range.address)) {
            kernel.vmm.unmap(page_table, current_virtual_range);
            current_virtual_range.address.moveBackwardInPlace(kernel.arch.paging.standard_page_size);
        }
    }

    // Map all pages that were allocated.
    while (!current_virtual_range.address.equal(virtual_range_end)) {
        const physical_range = kernel.pmm.allocatePage() orelse return error.OutOfMemory;

        try kernel.vmm.mapToPhysicalRange(
            page_table,
            current_virtual_range,
            physical_range,
            map_type,
        );

        current_virtual_range.address.moveForwardInPlace(kernel.arch.paging.standard_page_size);
    }
}

/// Maps a virtual address range to a physical range using the standard page size.
pub fn mapToPhysicalRange(
    page_table: *PageTable,
    virtual_range: kernel.VirtualRange,
    physical_range: kernel.PhysicalRange,
    map_type: MapType,
) !void {
    core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    core.debugAssert(physical_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(physical_range.size.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.equal(virtual_range.size));

    log.debug(
        "mapping: {} to {} with type: {}",
        .{ virtual_range, physical_range, map_type },
    );

    return kernel.arch.paging.mapToPhysicalRange(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `kernel.arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `kernel.arch.paging.standard_page_size`
pub fn unmap(
    page_table: *PageTable,
    virtual_range: kernel.VirtualRange,
) void {
    core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    log.debug("unmapping: {}", .{virtual_range});

    return kernel.arch.paging.unmap(page_table, virtual_range);
}

pub const init = struct {
    pub fn initVmm() void {
        log.debug("allocating kernel root page table", .{});
        kernel_page_table = paging.allocatePageTable() catch
            core.panic("unable to allocate physical page for root page table");

        // the below functions setup the mappings in `kernel_root_page_table` and also register each region in
        // the kernel memory layout

        mapDirectMaps() catch |err| {
            core.panicFmt("failed to map direct maps: {s}", .{@errorName(err)});
        };

        mapKernelSections() catch |err| {
            core.panicFmt("failed to map kernel sections: {s}", .{@errorName(err)});
        };

        prepareKernelHeap() catch |err| {
            core.panicFmt("failed to prepare kernel heap: {s}", .{@errorName(err)});
        };

        prepareKernelStacks() catch |err| {
            core.panicFmt("failed to prepare kernel stacks: {s}", .{@errorName(err)});
        };

        log.debug("switching to kernel page table", .{});
        paging.switchToPageTable(kernel_page_table);

        log.debug("kernel memory regions:", .{});

        for (memory_layout.layout.slice()) |region| {
            log.debug("\t{}", .{region});
        }
    }

    fn prepareKernelHeap() !void {
        log.debug("preparing kernel heap", .{});

        const kernel_heap_range = try kernel.arch.paging.getTopLevelRangeAndFillFirstLevel(kernel_page_table);

        try kernel.heap.init.initHeap(kernel_heap_range);

        memory_layout.registerRegion(.{ .range = kernel_heap_range, .type = .heap });

        log.debug("kernel heap: {}", .{kernel_heap_range});
    }

    fn prepareKernelStacks() !void {
        log.debug("preparing kernel stacks", .{});

        const kernel_stacks_range = try kernel.arch.paging.getTopLevelRangeAndFillFirstLevel(kernel_page_table);

        try kernel.Stack.init.initStacks(kernel_stacks_range);

        memory_layout.registerRegion(.{ .range = kernel_stacks_range, .type = .stacks });

        log.debug("kernel stacks: {}", .{kernel_stacks_range});
    }

    /// Maps a virtual address range to a physical address range using all available page sizes.
    fn mapToPhysicalRangeAllPageSizes(
        page_table: *PageTable,
        virtual_range: kernel.VirtualRange,
        physical_range: kernel.PhysicalRange,
        map_type: MapType,
    ) !void {
        core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));
        core.debugAssert(physical_range.address.isAligned(arch.paging.standard_page_size));
        core.debugAssert(physical_range.size.isAligned(arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.equal(virtual_range.size));

        log.debug(
            "mapping: {} to {} with type: {}",
            .{ virtual_range, physical_range, map_type },
        );

        return kernel.arch.paging.mapToPhysicalRangeAllPageSizes(
            page_table,
            virtual_range,
            physical_range,
            map_type,
        );
    }

    /// Maps the direct maps.
    fn mapDirectMaps() !void {
        const direct_map_physical_range = kernel.PhysicalRange.fromAddr(kernel.PhysicalAddress.zero, kernel.info.direct_map.size);

        log.debug("mapping the direct map", .{});

        try mapToPhysicalRangeAllPageSizes(
            kernel_page_table,
            kernel.info.direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = kernel.info.direct_map, .type = .direct_map });

        log.debug("mapping the non-cached direct map", .{});

        try mapToPhysicalRangeAllPageSizes(
            kernel_page_table,
            kernel.info.non_cached_direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .no_cache = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = kernel.info.non_cached_direct_map, .type = .non_cached_direct_map });
    }

    const linker_symbols = struct {
        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    /// Maps the kernel sections.
    fn mapKernelSections() !void {
        log.debug("mapping .text section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__text_start),
            @intFromPtr(&linker_symbols.__text_end),
            .{ .executable = true, .global = true },
            .executable_section,
        );

        log.debug("mapping .rodata section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__rodata_start),
            @intFromPtr(&linker_symbols.__rodata_end),
            .{ .global = true },
            .readonly_section,
        );

        log.debug("mapping .data section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__data_start),
            @intFromPtr(&linker_symbols.__data_end),
            .{ .writeable = true, .global = true },
            .writeable_section,
        );
    }

    /// Maps a section.
    fn mapSection(
        section_start: usize,
        section_end: usize,
        map_type: MapType,
        region_type: KernelMemoryLayout.KernelMemoryRegion.Type,
    ) !void {
        core.assert(section_end > section_start);

        const virt_address = kernel.VirtualAddress.fromInt(section_start);

        const virtual_range = kernel.VirtualRange.fromAddr(
            virt_address,
            core.Size
                .from(section_end - section_start, .byte)
                .alignForward(paging.standard_page_size),
        );
        core.assert(virtual_range.size.isAligned(paging.standard_page_size));

        const phys_address = kernel.PhysicalAddress.fromInt(
            virt_address.value - kernel.info.kernel_physical_to_virtual_offset.bytes,
        );

        const physical_range = kernel.PhysicalRange.fromAddr(phys_address, virtual_range.size);

        try mapToPhysicalRangeAllPageSizes(
            kernel_page_table,
            virtual_range,
            physical_range,
            map_type,
        );

        memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
    }
};
