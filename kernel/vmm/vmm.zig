// SPDX-License-Identifier: MIT

const arch = kernel.arch;
const core = @import("core");
const heap = kernel.heap;
const info = kernel.info;
const kernel = @import("kernel");
const PageTable = paging.PageTable;
const paging = arch.paging;
const PhysicalAddress = kernel.PhysicalAddress;
const PhysicalRange = kernel.PhysicalRange;
const pmm = kernel.pmm;
const Stack = kernel.Stack;
const std = @import("std");
const VirtualAddress = kernel.VirtualAddress;
const VirtualRange = kernel.VirtualRange;
const vmm = kernel.vmm;

pub const KernelMemoryLayout = @import("KernelMemoryLayout.zig");
pub const MapType = @import("MapType.zig");
pub const MemoryRegion = @import("MemoryRegion.zig");

const log = kernel.log.scoped(.virt_mm);

pub var memory_layout: KernelMemoryLayout = .{};

/// Maps a virtual range using the standard page size.
///
/// Physical pages are allocated for each page in the virtual range.
pub fn mapRange(page_table: *PageTable, virtual_range: VirtualRange, map_type: MapType) !void {
    core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    const virtual_range_end = virtual_range.end();
    var current_virtual_range = VirtualRange.fromAddr(virtual_range.address, arch.paging.standard_page_size);

    errdefer {
        // Unmap all pages that have been mapped.
        while (current_virtual_range.address.greaterThanOrEqual(virtual_range.address)) {
            vmm.unmap(page_table, current_virtual_range);
            current_virtual_range.address.moveBackwardInPlace(arch.paging.standard_page_size);
        }
    }

    // Map all pages that were allocated.
    while (!current_virtual_range.address.equal(virtual_range_end)) {
        const physical_range = pmm.allocatePage() orelse return error.OutOfMemory;

        try vmm.mapToPhysicalRange(
            page_table,
            current_virtual_range,
            physical_range,
            map_type,
        );

        current_virtual_range.address.moveForwardInPlace(arch.paging.standard_page_size);
    }
}

/// Maps a virtual address range to a physical range using the standard page size.
pub fn mapToPhysicalRange(
    page_table: *PageTable,
    virtual_range: VirtualRange,
    physical_range: PhysicalRange,
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

    return arch.paging.mapToPhysicalRange(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

/// Unmaps a virtual range.
///
/// **REQUIREMENTS**:
/// - `virtual_range.address` must be aligned to `arch.paging.standard_page_size`
/// - `virtual_range.size` must be aligned to `arch.paging.standard_page_size`
pub fn unmap(
    page_table: *PageTable,
    virtual_range: VirtualRange,
) void {
    core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
    core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));

    log.debug("unmapping: {}", .{virtual_range});

    return arch.paging.unmap(page_table, virtual_range);
}

pub const init = struct {
    pub fn initVmm() linksection(info.init_code) void {
        log.debug("populating kernel page table", .{});
        arch.paging.initPageTable(&kernel.kernel_process.page_table);

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
        paging.switchToPageTable(&kernel.kernel_process.page_table);

        log.debug("kernel memory regions:", .{});

        for (memory_layout.layout.slice()) |region| {
            log.debug("\t{}", .{region});
        }
    }

    fn prepareKernelHeap() linksection(info.init_code) !void {
        log.debug("preparing kernel heap", .{});

        const kernel_heap_range = try arch.paging.getTopLevelRangeAndFillFirstLevel(
            &kernel.kernel_process.page_table,
        );

        try heap.init.initHeap(kernel_heap_range);

        memory_layout.registerRegion(.{ .range = kernel_heap_range, .type = .heap });

        log.debug("kernel heap: {}", .{kernel_heap_range});
    }

    fn prepareKernelStacks() linksection(info.init_code) !void {
        log.debug("preparing kernel stacks", .{});

        const kernel_stacks_range = try arch.paging.getTopLevelRangeAndFillFirstLevel(
            &kernel.kernel_process.page_table,
        );

        try Stack.init.initStacks(kernel_stacks_range);

        memory_layout.registerRegion(.{ .range = kernel_stacks_range, .type = .stacks });

        log.debug("kernel stacks: {}", .{kernel_stacks_range});
    }

    /// Maps a virtual address range to a physical address range using all available page sizes.
    fn mapToPhysicalRangeAllPageSizes(
        page_table: *PageTable,
        virtual_range: VirtualRange,
        physical_range: PhysicalRange,
        map_type: MapType,
    ) linksection(info.init_code) !void {
        core.debugAssert(virtual_range.address.isAligned(arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.isAligned(arch.paging.standard_page_size));
        core.debugAssert(physical_range.address.isAligned(arch.paging.standard_page_size));
        core.debugAssert(physical_range.size.isAligned(arch.paging.standard_page_size));
        core.debugAssert(virtual_range.size.equal(virtual_range.size));

        log.debug(
            "mapping: {} to {} with type: {}",
            .{ virtual_range, physical_range, map_type },
        );

        return arch.paging.mapToPhysicalRangeAllPageSizes(
            page_table,
            virtual_range,
            physical_range,
            map_type,
        );
    }

    /// Maps the direct maps.
    fn mapDirectMaps() linksection(info.init_code) !void {
        const direct_map_physical_range = PhysicalRange.fromAddr(PhysicalAddress.zero, info.direct_map.size);

        log.debug("mapping the direct map", .{});

        try mapToPhysicalRangeAllPageSizes(
            &kernel.kernel_process.page_table,
            info.direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = info.direct_map, .type = .direct_map });

        log.debug("mapping the non-cached direct map", .{});

        try mapToPhysicalRangeAllPageSizes(
            &kernel.kernel_process.page_table,
            info.non_cached_direct_map,
            direct_map_physical_range,
            .{ .writeable = true, .no_cache = true, .global = true },
        );
        memory_layout.registerRegion(.{ .range = info.non_cached_direct_map, .type = .non_cached_direct_map });
    }

    const linker_symbols = struct {
        extern const __init_text_start: u8;
        extern const __init_text_end: u8;
        extern const __init_data_start: u8;
        extern const __init_data_end: u8;

        extern const __text_start: u8;
        extern const __text_end: u8;
        extern const __rodata_start: u8;
        extern const __rodata_end: u8;
        extern const __data_start: u8;
        extern const __data_end: u8;
    };

    /// Maps the kernel sections.
    fn mapKernelSections() linksection(info.init_code) !void {
        log.debug("mapping .init_text section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__init_text_start),
            @intFromPtr(&linker_symbols.__init_text_end),
            .{ .executable = true },
            .init_executable_section,
        );

        log.debug("mapping .init_data section", .{});
        try mapSection(
            @intFromPtr(&linker_symbols.__init_data_start),
            @intFromPtr(&linker_symbols.__init_data_end),
            .{ .writeable = true },
            .init_writeable_section,
        );

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

    /// Unmaps the init only kernel sections.
    pub fn unmapInitOnlyKernelSections() void {
        log.debug("unmapping .init_text section", .{});
        unmapSectionType(.init_executable_section);

        log.debug("unmapping .init_data section", .{});
        unmapSectionType(.init_writeable_section);
    }

    /// Maps a section.
    fn mapSection(
        section_start: usize,
        section_end: usize,
        map_type: MapType,
        region_type: KernelMemoryLayout.KernelMemoryRegion.Type,
    ) linksection(info.init_code) !void {
        if (section_start == section_end) return;

        core.assert(section_end > section_start);

        const virt_address = VirtualAddress.fromInt(section_start);

        const virtual_range = VirtualRange.fromAddr(
            virt_address,
            core.Size
                .from(section_end - section_start, .byte)
                .alignForward(paging.standard_page_size),
        );
        core.assert(virtual_range.size.isAligned(paging.standard_page_size));

        const phys_address = PhysicalAddress.fromInt(
            virt_address.value - info.kernel_physical_to_virtual_offset.bytes,
        );

        const physical_range = PhysicalRange.fromAddr(phys_address, virtual_range.size);

        try mapToPhysicalRangeAllPageSizes(
            &kernel.kernel_process.page_table,
            virtual_range,
            physical_range,
            map_type,
        );

        memory_layout.registerRegion(.{ .range = virtual_range, .type = region_type });
    }

    /// Unmaps all kernel sections of the given type.
    ///
    /// Also removes the region from the memory layout.
    fn unmapSectionType(
        region_type: KernelMemoryLayout.KernelMemoryRegion.Type,
    ) void {
        var i: usize = 0;

        while (i < memory_layout.layout.len) {
            const region = memory_layout.layout.get(i);
            if (region.type != region_type) {
                i += 1;
                continue;
            }

            unmap(&kernel.kernel_process.page_table, region.range);

            _ = memory_layout.layout.swapRemove(i);
        }
    }
};
