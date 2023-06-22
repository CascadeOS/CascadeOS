// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = kernel.arch;
const paging = kernel.arch.paging;
const PageTable = paging.PageTable;

const log = kernel.log.scoped(.vmm);

var kernel_root_page_table: *PageTable = undefined;
var heap_range: kernel.VirtRange = undefined;

pub fn init() void {
    log.debug("allocating kernel root page table", .{});
    kernel_root_page_table = paging.allocatePageTable() catch core.panic("unable to allocate physical page for root page table");

    // the below functions setup the mappings in `kernel_root_page_table` and also register each region in
    // the kernel memory layout

    identityMaps() catch |err| {
        core.panicFmt("failed to map identity maps: {s}", .{@errorName(err)});
    };

    mapKernelSections() catch |err| {
        core.panicFmt("failed to map kernel sections: {s}", .{@errorName(err)});
    };

    log.debug("preparing kernel heap", .{});
    heap_range = kernel.arch.paging.getHeapRangeAndFillFirstLevel(kernel_root_page_table) catch |err| {
        core.panicFmt("failed to find range for the kernel heap: {s}", .{@errorName(err)});
    };
    registerKernelMemoryRegion(.{ .range = heap_range, .type = .kernel_heap });
    log.debug("kernel heap: {}", .{heap_range});

    // now that the kernel memory layout is populated we sort it from lowest address to highest
    std.mem.sort(MemoryRegion, kernel_memory_layout[0..kernel_memory_layout_count], {}, struct {
        fn lessThanFn(context: void, self: MemoryRegion, other: MemoryRegion) bool {
            _ = context;
            return self.range.addr.lessThan(other.range.addr);
        }
    }.lessThanFn);

    log.debug("switching to kernel page table", .{});
    paging.switchToPageTable(kernel_root_page_table);

    if (log.levelEnabled(.debug)) {
        log.debug("kernel memory regions:", .{});
        for (kernel_memory_layout[0..kernel_memory_layout_count]) |region| {
            log.debug("\t{}", .{region});
        }
    }
}

pub const MapType = struct {
    user: bool = false,
    global: bool = false,
    writeable: bool = false,
    executable: bool = false,
    no_cache: bool = false,

    pub fn format(
        value: MapType,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;

        try writer.writeAll("MapType{ ");

        const buffer: []const u8 = &.{
            if (value.user) 'U' else 'K',
            if (value.writeable) 'W' else 'R',
            if (value.executable) 'X' else '-',
            if (value.global) 'G' else '-',
            if (value.no_cache) 'C' else '-',
        };

        try writer.writeAll(buffer);
        try writer.writeAll(" }");
    }
};

pub fn mapRange(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: MapType,
) !void {
    std.debug.assert(virtual_range.addr.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.addr.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.equal(virtual_range.size));

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

pub fn mapRangeUseAllPageSizes(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: MapType,
) !void {
    std.debug.assert(virtual_range.addr.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.addr.isAligned(arch.paging.standard_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.standard_page_size));
    std.debug.assert(virtual_range.size.equal(virtual_range.size));

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

pub const MemoryRegion = struct {
    range: kernel.VirtRange,
    type: Type,

    pub const Type = enum {
        kernel_writeable_section,
        kernel_readonly_section,
        kernel_executable_section,
        direct_map,
        non_cached_direct_map,
        kernel_heap,
    };

    pub fn print(region: MemoryRegion, writer: anytype) !void {
        try writer.writeAll("MemoryRegion{ 0x");
        try std.fmt.formatInt(region.range.addr.value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);
        try writer.writeAll(" - 0x");
        try std.fmt.formatInt(region.range.end().value, 16, .lower, .{ .width = 16, .fill = '0' }, writer);

        try writer.writeAll(" ");
        try writer.writeAll(@tagName(region.type));
        try writer.writeAll(" }");
    }

    pub fn format(
        region: MemoryRegion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        return print(region, writer);
    }
};

// currently the kernel has exactly 6 memory regions: 3 elf sections, 2 direct maps and the heap
var kernel_memory_layout: [6]MemoryRegion = undefined;
var kernel_memory_layout_count: usize = 0;

fn registerKernelMemoryRegion(region: MemoryRegion) void {
    kernel_memory_layout[kernel_memory_layout_count] = region;
    kernel_memory_layout_count += 1;
}

fn identityMaps() !void {
    const physical_range = kernel.PhysRange.fromAddr(kernel.PhysAddr.zero, kernel.info.direct_map.size);

    log.debug("identity mapping the direct map", .{});

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        kernel.info.direct_map,
        physical_range,
        .{ .writeable = true, .global = true },
    );
    registerKernelMemoryRegion(.{ .range = kernel.info.direct_map, .type = .direct_map });

    log.debug("identity mapping the non-cached direct map", .{});

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        kernel.info.non_cached_direct_map,
        physical_range,
        .{ .writeable = true, .no_cache = true, .global = true },
    );
    registerKernelMemoryRegion(.{ .range = kernel.info.non_cached_direct_map, .type = .non_cached_direct_map });
}

const linker_symbols = struct {
    extern const __text_start: u8;
    extern const __text_end: u8;
    extern const __rodata_start: u8;
    extern const __rodata_end: u8;
    extern const __data_start: u8;
    extern const __data_end: u8;
};

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

fn mapSection(start: usize, end: usize, map_type: MapType, region_type: MemoryRegion.Type) !void {
    std.debug.assert(end > start);

    const virt_addr = kernel.VirtAddr.fromInt(start);

    const virtual_range = kernel.VirtRange.fromAddr(
        virt_addr,
        core.Size.from(end - start, .byte).alignForward(paging.standard_page_size),
    );
    std.debug.assert(virtual_range.size.isAligned(paging.standard_page_size));

    const phys_addr = kernel.PhysAddr.fromInt(virt_addr.value - kernel.info.kernel_virtual_offset_from_physical.bytes);

    const physical_range = kernel.PhysRange.fromAddr(phys_addr, virtual_range.size);

    try mapRangeUseAllPageSizes(
        kernel_root_page_table,
        virtual_range,
        physical_range,
        map_type,
    );

    registerKernelMemoryRegion(.{ .range = virtual_range, .type = region_type });
}
