// SPDX-License-Identifier: MIT

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const arch = kernel.arch;
const paging = kernel.arch.paging;
const PageTable = paging.PageTable;

const log = kernel.log.scoped(.vmm);

var kernel_root_page_table: *PageTable = undefined;

pub fn init() void {
    log.debug("allocating kernel root page table", .{});
    kernel_root_page_table = paging.allocatePageTable() catch core.panic("unable to allocate physical page for root page table");

    identityMaps() catch |err| {
        core.panicFmt("failed to map identity maps: {s}", .{@errorName(err)});
    };

    mapKernelSections() catch |err| {
        core.panicFmt("failed to map kernel sections: {s}", .{@errorName(err)});
    };

    log.debug("switching to kernel page table", .{});
    paging.switchToPageTable(kernel_root_page_table);
}

fn identityMaps() !void {
    const physical_range = kernel.PhysRange.fromAddr(kernel.PhysAddr.zero, kernel.info.direct_map.size);

    log.debug("identity mapping the direct map", .{});

    try mapRegion(
        kernel_root_page_table,
        kernel.info.direct_map,
        physical_range,
        .{ .writeable = true, .global = true },
    );

    log.debug("identity mapping the non-cached direct map", .{});

    try kernel.vmm.mapRegion(
        kernel_root_page_table,
        kernel.info.non_cached_direct_map,
        physical_range,
        .{ .writeable = true, .no_cache = true, .global = true },
    );
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
        @ptrToInt(&linker_symbols.__text_start),
        @ptrToInt(&linker_symbols.__text_end),
        .{ .executable = true, .global = true },
    );

    log.debug("mapping .rodata section", .{});
    try mapSection(
        @ptrToInt(&linker_symbols.__rodata_start),
        @ptrToInt(&linker_symbols.__rodata_end),
        .{ .global = true },
    );

    log.debug("mapping .data section", .{});
    try mapSection(
        @ptrToInt(&linker_symbols.__data_start),
        @ptrToInt(&linker_symbols.__data_end),
        .{ .writeable = true, .global = true },
    );
}

fn mapSection(start: usize, end: usize, map_type: MapType) !void {
    std.debug.assert(end > start);

    const virt_addr = kernel.VirtAddr.fromInt(start);

    const virtual_range = kernel.VirtRange.fromAddr(
        virt_addr,
        core.Size.from(end - start, .byte),
    );
    std.debug.assert(virtual_range.size.isAligned(paging.smallest_page_size));

    const phys_addr = kernel.PhysAddr.fromInt(virt_addr.value - kernel.info.kernel_section_offset.bytes);

    const physical_range = kernel.PhysRange.fromAddr(phys_addr, virtual_range.size);

    try mapRegion(
        kernel_root_page_table,
        virtual_range,
        physical_range,
        map_type,
    );
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

        var buffer: [5]u8 = undefined;
        var i: usize = 0;

        buffer[i] = if (value.user) 'U' else 'K';
        i += 1;

        buffer[i] = if (value.writeable) 'W' else 'E';
        i += 1;

        if (value.executable) {
            buffer[i] = 'X';
            i += 1;
        }

        if (value.global) {
            buffer[i] = 'G';
            i += 1;
        }

        if (value.no_cache) {
            buffer[i] = 'C';
            i += 1;
        }

        try writer.writeAll(buffer[0..i]);
        try writer.writeAll(" }");
    }
};

pub fn mapRegion(
    page_table: *PageTable,
    virtual_range: kernel.VirtRange,
    physical_range: kernel.PhysRange,
    map_type: MapType,
) !void {
    std.debug.assert(virtual_range.addr.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(virtual_range.size.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(physical_range.addr.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(physical_range.size.isAligned(arch.paging.smallest_page_size));
    std.debug.assert(virtual_range.size.equal(virtual_range.size));

    log.debug(
        "mapping: {} to {} with type: {}",
        .{ virtual_range, physical_range, map_type },
    );

    return kernel.arch.paging.mapRegionUseAllPageSizes(
        page_table,
        virtual_range,
        physical_range,
        map_type,
    );
}
