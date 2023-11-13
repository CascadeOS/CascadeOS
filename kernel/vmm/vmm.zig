// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

pub const MapType = @import("MapType.zig");
pub const MemoryRegion = @import("MemoryRegion.zig");

const arch = kernel.arch;
const paging = kernel.arch.paging;
const PageTable = paging.PageTable;

const log = kernel.log.scoped(.virt_mm);

var kernel_root_page_table: *PageTable = undefined;
var heap_range: kernel.VirtualRange = undefined;

var initalized = false;

pub fn init() void {
    log.debug("allocating kernel root page table", .{});
    kernel_root_page_table = paging.allocatePageTable() catch
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

    // now that the kernel memory layout is populated we sort it
    sortKernelMemoryLayout();

    log.debug("switching to kernel page table", .{});
    paging.switchToPageTable(kernel_root_page_table);

    log.debug("kernel memory regions:", .{});

    for (kernel_memory_layout.slice()) |region| {
        log.debug("\t{}", .{region});
    }

    initalized = true;
}

/// Maps a virtual address range to a physical address range using the standard page size.
fn mapRange(
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

    return kernel.arch.paging.mapRange(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

/// Maps a virtual address range to a physical address range using all available page sizes.
fn mapRangeUseAllPageSizes(
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

    return kernel.arch.paging.mapRangeUseAllPageSizes(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}

// currently the kernel has exactly 6 memory regions: 3 elf sections, 2 direct maps and the heap
var kernel_memory_layout: std.BoundedArray(KernelMemoryRegion, 6) = .{};

const KernelMemoryRegion = struct {
    range: kernel.VirtualRange,
    region_type: RegionType,

    pub const RegionType = enum {
        kernel_writeable_section,
        kernel_readonly_section,
        kernel_executable_section,
        direct_map,
        non_cached_direct_map,
        kernel_heap,
    };
};

/// Registers a kernel memory region.
fn registerKernelMemoryRegion(region: KernelMemoryRegion) void {
    kernel_memory_layout.append(region) catch unreachable;
}

/// Sorts the kernel memory layout from lowest to highest address.
fn sortKernelMemoryLayout() void {
    std.mem.sort(KernelMemoryRegion, kernel_memory_layout.slice(), {}, struct {
        fn lessThanFn(context: void, self: KernelMemoryRegion, other: KernelMemoryRegion) bool {
            _ = context;
            return self.range.address.lessThan(other.range.address);
        }
    }.lessThanFn);
}

/// Maps the direct maps.
fn mapDirectMaps() !void {
    const direct_map_physical_range = kernel.PhysicalRange.fromAddr(kernel.PhysicalAddress.zero, kernel.info.direct_map.size);

    log.debug("mapping the direct map", .{});

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        kernel.info.direct_map,
        direct_map_physical_range,
        .{ .writeable = true, .global = true },
    );
    registerKernelMemoryRegion(.{ .range = kernel.info.direct_map, .region_type = .direct_map });

    log.debug("mapping the non-cached direct map", .{});

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        kernel.info.non_cached_direct_map,
        direct_map_physical_range,
        .{ .writeable = true, .no_cache = true, .global = true },
    );
    registerKernelMemoryRegion(.{ .range = kernel.info.non_cached_direct_map, .region_type = .non_cached_direct_map });
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
        .kernel_executable_section,
    );

    log.debug("mapping .rodata section", .{});
    try mapSection(
        @intFromPtr(&linker_symbols.__rodata_start),
        @intFromPtr(&linker_symbols.__rodata_end),
        .{ .global = true },
        .kernel_readonly_section,
    );

    log.debug("mapping .data section", .{});
    try mapSection(
        @intFromPtr(&linker_symbols.__data_start),
        @intFromPtr(&linker_symbols.__data_end),
        .{ .writeable = true, .global = true },
        .kernel_writeable_section,
    );
}

/// Prepares the kernel heap.
fn prepareKernelHeap() !void {
    log.debug("preparing kernel heap", .{});
    heap_range = try kernel.arch.paging.getHeapRangeAndFillFirstLevel(kernel_root_page_table);
    registerKernelMemoryRegion(.{ .range = heap_range, .region_type = .kernel_heap });
    log.debug("kernel heap: {}", .{heap_range});
}

/// Maps a section.
fn mapSection(
    section_start: usize,
    section_end: usize,
    map_type: MapType,
    region_type: KernelMemoryRegion.RegionType,
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

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        virtual_range,
        physical_range,
        map_type,
    );

    registerKernelMemoryRegion(.{ .range = virtual_range, .region_type = region_type });
}